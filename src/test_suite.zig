const std = @import("std");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;

const Config = struct {
    manifest_path: []const u8 = "tests/files-toml-1.0.0",
    /// Root directory for the tests.
    tests_root: []const u8 = "tests",
    /// Max number of failure reports to print.
    max_failures: usize = 20,
    /// Only include test paths that contain the filter.
    filter: ?[]const u8 = null,
    /// List of test paths to run.
    only_tests: []const []const u8 = &.{},
    /// Print extra details for each failing test.
    show: bool = false,
};

fn showFailure(cfg: Config, failures: usize) bool {
    return cfg.max_failures == 0 or failures <= cfg.max_failures;
}

fn joinPath(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ a, b });
}

fn tomlToJsonPath(allocator: std.mem.Allocator, rel_toml: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, rel_toml, ".toml")) return error.InvalidArgs;
    return try std.fmt.allocPrint(allocator, "{s}.json", .{rel_toml[0 .. rel_toml.len - 5]});
}

fn expectOkFromPath(rel_path: []const u8) ?bool {
    if (std.mem.startsWith(u8, rel_path, "valid/")) return true;
    if (std.mem.startsWith(u8, rel_path, "invalid/")) return false;
    return null;
}

const FailureDetails = struct {
    expect_ok: bool,
    parse_ok: bool,
    input: []const u8,
    err: ?anyerror = null,
    line_number: ?usize = null,
    expected_json: ?[]const u8 = null,
    actual_json: ?[]const u8 = null,
    /// Reason for the fail.
    reason: ?[]const u8 = null,
};

fn printFailureDetails(cfg: Config, full_path: []const u8, details: FailureDetails) void {
    std.debug.print("\n== FAIL {s} ==\n", .{full_path});
    if (details.reason) |r| std.debug.print("reason: {s}\n", .{r});
    if (details.parse_ok) if (details.err) |err|
        std.debug.print("error: {s}\n", .{@errorName(err)});

    std.debug.print("expected: {s}\n", .{if (details.expect_ok) "parse ok" else "parse error"});
    if (details.parse_ok) {
        std.debug.print("actual: parsed ok\n", .{});
    } else {
        const err_name = if (details.err) |e| @errorName(e) else "unknown";
        std.debug.print("actual: {s}", .{err_name});
        if (details.line_number) |ln| std.debug.print(" (line {})", .{ln});
        std.debug.print("\n", .{});
    }

    if (cfg.show) {
        std.debug.print("--- input (escaped) ---\n", .{});
        std.debug.print("{s}", .{details.input});
        std.debug.print("\n--- end input ---\n", .{});
    }
    if (cfg.show) {
        if (details.expected_json) |j| {
            std.debug.print("--- expected json ---\n", .{});
            std.debug.print("{s}", .{j});
            std.debug.print("\n--- end expected json ---\n", .{});
        } else {
            std.debug.print("--- expected json ---\n(missing)\n--- end expected json ---\n", .{});
        }
    }
    if (cfg.show) {
        if (details.actual_json) |j| {
            std.debug.print("--- actual json ---\n", .{});
            std.debug.print("{s}", .{j});
            std.debug.print("\n--- end actual json ---\n", .{});
        }
    }
}

fn parseArgs(gpa: std.mem.Allocator, args_it: *std.process.Args.Iterator) !Config {
    var cfg: Config = .{};
    var only = std.ArrayList([]const u8).empty;
    errdefer only.deinit(gpa);

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--show")) {
            cfg.show = true;
        } else if (std.mem.eql(u8, a, "--manifest")) {
            const v_z = args_it.next() orelse return error.InvalidArgs;
            cfg.manifest_path = try gpa.dupe(u8, v_z);
        } else if (std.mem.eql(u8, a, "--tests-root")) {
            const v_z = args_it.next() orelse return error.InvalidArgs;
            cfg.tests_root = try gpa.dupe(u8, v_z);
        } else if (std.mem.eql(u8, a, "--filter")) {
            const v_z = args_it.next() orelse return error.InvalidArgs;
            cfg.filter = try gpa.dupe(u8, v_z);
        } else if (std.mem.eql(u8, a, "--test")) {
            const v_z = args_it.next() orelse return error.InvalidArgs;
            try only.append(gpa, try gpa.dupe(u8, v_z));
        } else if (std.mem.eql(u8, a, "--max-failures")) {
            const v_z = args_it.next() orelse return error.InvalidArgs;
            cfg.max_failures = try std.fmt.parseInt(usize, v_z, 10);
        } else {
            return error.InvalidArgs;
        }
    }

    cfg.only_tests = try only.toOwnedSlice(gpa);
    return cfg;
}

const RunItem = struct {
    path: []u8,
    expect_ok: bool,
};

const RunStats = struct {
    valid_total: usize = 0,
    invalid_total: usize = 0,
    failures: usize = 0,

    fn total(self: RunStats) usize {
        return self.valid_total + self.invalid_total;
    }
};

const TestRunner = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Scratch allocator for temporary allocations.
    arena: std.heap.ArenaAllocator,
    cwd: std.Io.Dir,

    cfg: Config,

    parser: *Parser,
    tests: std.ArrayList(RunItem) = .empty,

    fn init(proc_init: std.process.Init, cfg: Config) !TestRunner {
        return .{
            .io = proc_init.io,
            .gpa = proc_init.gpa,
            .arena = .init(proc_init.gpa),
            .cwd = .cwd(),
            .cfg = cfg,
            .parser = try .init(proc_init.gpa),
            .tests = .empty,
        };
    }

    fn deinit(self: *TestRunner) void {
        self.parser.deinit();
        self.arena.deinit();
        self.deinitTests();
    }

    fn clearTests(self: *TestRunner) void {
        for (self.tests.items) |it| self.gpa.free(it.path);
        self.tests.clearRetainingCapacity();
    }

    fn deinitTests(self: *TestRunner) void {
        self.clearTests();
        self.tests.deinit(self.gpa);
    }

    /// Allocate the expected JSON content for the TOML the given path.
    fn loadExpectedJson(self: *TestRunner, rel_toml: []const u8) ?[]u8 {
        const json_rel = tomlToJsonPath(self.gpa, rel_toml) catch return null;
        defer self.gpa.free(json_rel);
        const json_full = joinPath(self.gpa, self.cfg.tests_root, json_rel) catch return null;
        defer self.gpa.free(json_full);
        return self.cwd.readFileAlloc(self.io, json_full, self.gpa, .unlimited) catch null;
    }

    /// Compare two JSON strings for semantic equivalence.
    fn compareJson(self: *TestRunner, a: []const u8, b: []const u8) !bool {
        if (std.mem.eql(u8, a, b)) return true;
        const arena = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);

        const a_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, a, .{});
        const b_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, b, .{});
        return jsonValueEql(a_json, b_json);
    }

    /// Check if the JSON values are semantically equavalent.
    fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
        const Tag = std.meta.Tag(std.json.Value);
        const at: Tag = std.meta.activeTag(a);
        const bt: Tag = std.meta.activeTag(b);
        if (at != bt) return false;

        return switch (a) {
            .null => true,
            .bool => |av| av == b.bool,
            .integer => |av| av == b.integer,
            .float => |av| av == b.float,
            .number_string => |av| std.mem.eql(u8, av, b.number_string),
            .string => |av| std.mem.eql(u8, av, b.string),
            .array => |av| blk: {
                const bv = b.array;
                if (av.items.len != bv.items.len) break :blk false;
                for (av.items, bv.items) |ai, bi| {
                    if (!jsonValueEql(ai, bi)) break :blk false;
                }
                break :blk true;
            },
            .object => |av| blk: {
                const bv = b.object;
                if (av.count() != bv.count()) break :blk false;
                var it = av.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const b_val_ptr = bv.getPtr(key) orelse break :blk false;
                    if (!jsonValueEql(entry.value_ptr.*, b_val_ptr.*)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Collect all the tests to run.
    fn collectTests(self: *TestRunner) !void {
        self.clearTests();

        if (self.cfg.only_tests.len != 0) {
            for (self.cfg.only_tests) |test_path| {
                const expect_ok = expectOkFromPath(test_path) orelse {
                    std.debug.print(
                        "error: the test must start with 'valid/' or 'invalid/': {s}\n",
                        .{test_path},
                    );
                    return error.InvalidArgs;
                };
                try self.tests.append(self.gpa, .{
                    .path = try self.gpa.dupe(u8, test_path),
                    .expect_ok = expect_ok,
                });
            }
            return;
        }

        const manifest = self.cwd.readFileAlloc(
            self.io,
            self.cfg.manifest_path,
            self.gpa,
            .unlimited,
        ) catch |err| {
            std.debug.print(
                "error: could not read manifest '{s}': {s}\n",
                .{ self.cfg.manifest_path, @errorName(err) },
            );
            return error.InvalidArgs;
        };
        defer self.gpa.free(manifest);

        // Collect TOML file paths from the manifest
        var it = std.mem.splitScalar(u8, manifest, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (!std.mem.endsWith(u8, line, ".toml")) continue;
            if (self.cfg.filter) |f| if (std.mem.indexOf(u8, line, f) == null) continue;

            const expect_ok = expectOkFromPath(line) orelse continue;
            try self.tests.append(self.gpa, .{
                .path = try self.gpa.dupe(u8, line),
                .expect_ok = expect_ok,
            });
        }
    }

    /// Run all the collected tests.
    fn runTests(self: *TestRunner) !RunStats {
        var stats: RunStats = .{};

        for (self.tests.items) |item| {
            if (item.expect_ok) stats.valid_total += 1 else stats.invalid_total += 1;

            const full_path = try joinPath(self.gpa, self.cfg.tests_root, item.path);
            defer self.gpa.free(full_path);

            const content =
                self.cwd.readFileAlloc(self.io, full_path, self.gpa, .unlimited) catch |err| {
                    stats.failures += 1;
                    std.log.err(
                        "Failed to read test file ({s}): '{s}'",
                        .{ @errorName(err), full_path },
                    );
                    continue;
                };
            defer self.gpa.free(content);

            const parsed = self.parser.parse_string(content);
            if (item.expect_ok) {
                const expected_json = self.loadExpectedJson(item.path) orelse {
                    std.debug.print("Expected a JSON file for '{s}'\n", .{item.path});
                    continue;
                };
                defer self.gpa.free(expected_json);

                const toml = parsed catch |err| {
                    stats.failures += 1;
                    if (!showFailure(self.cfg, stats.failures)) continue;

                    const ctx = self.parser.get_error_context();
                    const line_number: ?usize = if (ctx) |c| c.line_number else null;
                    const err_to_print: anyerror = if (ctx) |c| c.err else err;

                    printFailureDetails(self.cfg, full_path, .{
                        .expect_ok = true,
                        .parse_ok = false,
                        .err = err_to_print,
                        .line_number = line_number,
                        .input = content,
                        .expected_json = expected_json,
                        .reason = "parse failed",
                    });
                    continue;
                };
                defer toml.deinit();

                const actual_json = try toml.to_json_with_types();
                defer self.gpa.free(actual_json);

                // Compare the contents
                const eql: bool, const err: ?anyerror = blk: {
                    const eql = self.compareJson(actual_json, expected_json) catch |err|
                        break :blk .{ false, err };
                    break :blk .{ eql, null };
                };
                if (eql) continue;
                stats.failures += 1;
                printFailureDetails(self.cfg, full_path, .{
                    .expect_ok = true,
                    .parse_ok = true,
                    .err = err,
                    .input = content,
                    .expected_json = expected_json,
                    .actual_json = actual_json,
                    .reason = if (err != null) "json compare error" else "json mismatch",
                });
            } else {
                const toml = parsed catch continue; // expected error
                defer toml.deinit();

                stats.failures += 1;
                if (!showFailure(self.cfg, stats.failures)) continue;

                const actual_json: ?[]const u8 = if (self.cfg.show)
                    toml.to_json_with_types() catch null
                else
                    null;
                defer if (actual_json) |s| self.gpa.free(s);

                printFailureDetails(self.cfg, full_path, .{
                    .expect_ok = false,
                    .parse_ok = true,
                    .input = content,
                    .actual_json = actual_json,
                    .reason = "expected parse error but parsed ok",
                });
            }
        }

        return stats;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();
    _ = args_it.skip(); // argv[0]

    const cfg = parseArgs(arena, &args_it) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    var runner = TestRunner.init(init, cfg) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer runner.deinit();

    runner.collectTests() catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    const stats = try runner.runTests();

    const total = stats.total();
    if (stats.failures == 0) {
        std.debug.print(
            "TOML test suite: {} / {} passed (valid {}, invalid {})\n",
            .{ total, total, stats.valid_total, stats.invalid_total },
        );
    } else {
        std.debug.print(
            "TOML test suite: {} failures out of {} tests (valid {}, invalid {})\n",
            .{ stats.failures, total, stats.valid_total, stats.invalid_total },
        );
        if (cfg.max_failures != 0 and stats.failures > cfg.max_failures) {
            std.debug.print("(showing first {} failures)\n", .{cfg.max_failures});
        }
        std.process.exit(1);
    }
}
