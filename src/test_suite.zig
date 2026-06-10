const std = @import("std");
const parser_mod = @import("parser.zig");
const encode = @import("encode.zig");
const types = @import("types.zig");

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

    const TypedExpected = struct { type_name: []const u8, value: []const u8 };

    /// Tries to unwrap test JSON objects like: {"type": "...", "value": "..."}.
    fn unwrapTypedExpected(
        expected: *const std.json.Value,
    ) ?TypedExpected {
        if (expected.* != .object) return null;
        if (expected.object.count() != 2) return null;

        const t_v = expected.object.get("type") orelse return null;
        const v_v = expected.object.get("value") orelse return null;
        if (t_v != .string) return null;
        if (v_v != .string) return null;

        return .{ .type_name = t_v.string, .value = v_v.string };
    }

    /// Compare two JSON values for semantic equivalence.
    fn jsonValueEquality(actual: *const std.json.Value, expected: *const std.json.Value) bool {
        switch (actual.*) {
            .string => |s| return expected.* == .string and std.mem.eql(u8, s, expected.string),
            .integer => |i| return expected.* == .integer and i == expected.integer,
            .bool => |b| return expected.* == .bool and b == expected.bool,
            .float => |f| return switch (expected.*) {
                .float => |f2| f == f2,
                .integer => |i| f == @as(f64, @floatFromInt(i)),
                else => false,
            },
            else => return false,
        }
    }

    /// Compare JSON against expected toml-test JSON.
    fn jsonEquality(
        self: *TestRunner,
        allocator: std.mem.Allocator,
        actual: *const std.json.Value,
        expected: *const std.json.Value,
    ) anyerror!bool {
        if (unwrapTypedExpected(expected)) |tw| {
            return self.jsonEqualityTyped(allocator, actual, tw);
        }
        return self.jsonEqualityContainer(allocator, actual, expected);
    }

    /// Compare typed JSON values.
    fn jsonEqualityTyped(
        _: *TestRunner,
        allocator: std.mem.Allocator,
        actual: *const std.json.Value,
        expected: TypedExpected,
    ) anyerror!bool {
        const eql = std.mem.eql;

        if (eql(u8, expected.type_name, "string")) {
            if (actual.* != .string) return false;
            return eql(u8, actual.string, expected.value);
        }

        if (eql(u8, expected.type_name, "float")) {
            if (actual.* != .float) return false;

            if (eql(u8, expected.value, "inf") or eql(u8, expected.value, "+inf"))
                return std.math.inf(f64) == actual.float;
            if (eql(u8, expected.value, "-inf"))
                return -std.math.inf(f64) == actual.float;
            if (eql(u8, expected.value, "nan") or
                eql(u8, expected.value, "+nan") or
                eql(u8, expected.value, "-nan"))
                return std.math.isNan(actual.float);
        }

        if (eql(u8, expected.type_name, "datetime") or
            eql(u8, expected.type_name, "datetime-local") or
            eql(u8, expected.type_name, "date-local") or
            eql(u8, expected.type_name, "time-local"))
        {
            if (actual.* != .string) return false;
            if (eql(u8, expected.type_name, "date-local")) {
                const a = try types.interpret_date(actual.string) orelse return false;
                const e = try types.interpret_date(expected.value) orelse return false;
                return a.year == e.year and a.month == e.month and a.day == e.day;
            }
            if (eql(u8, expected.type_name, "time-local")) {
                const a = try types.interpret_time(actual.string) orelse return false;
                const e = try types.interpret_time(expected.value) orelse return false;
                return a.eql(e);
            }
            const a = try types.interpret_datetime(actual.string) orelse return false;
            const e = try types.interpret_datetime(expected.value) orelse return false;
            return a.eql(e);
        }

        // Handle bool/integer
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            expected.value,
            .{},
        ) catch return false;
        return jsonValueEquality(actual, &parsed);
    }

    /// Compare JSON containers like arrays and objects.
    fn jsonEqualityContainer(
        self: *TestRunner,
        allocator: std.mem.Allocator,
        actual: *const std.json.Value,
        expected: *const std.json.Value,
    ) anyerror!bool {
        switch (actual.*) {
            .array => {
                if (expected.* != .array) return false;
                const arr_actual = actual.array.items;
                const arr_expected = expected.array.items;
                if (arr_actual.len != arr_expected.len) return false;
                for (arr_actual, 0..) |a_item, i| {
                    const e_item = arr_expected[i];
                    if (!try self.jsonEquality(allocator, &a_item, &e_item)) return false;
                }
                return true;
            },
            .object => {
                if (expected.* != .object) return false;
                if (actual.object.count() != expected.object.count()) return false;
                var it = actual.object.iterator();
                while (it.next()) |entry_a| {
                    const e_val = expected.object.get(entry_a.key_ptr.*) orelse
                        return false;
                    if (!try self.jsonEquality(allocator, entry_a.value_ptr, &e_val))
                        return false;
                }
                return true;
            },
            else => return false,
        }
    }

    fn stringifyJsonValue(self: *TestRunner, value: std.json.Value) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        try std.json.Stringify.value(value, .{ .whitespace = .indent_4 }, &out.writer);
        const owned = try self.gpa.dupe(u8, out.written());
        return owned;
    }

    /// Collect all the tests to run.
    fn collectTests(self: *TestRunner) !void {
        self.clearTests();

        if (self.cfg.only_tests.len != 0) {
            for (self.cfg.only_tests) |test_path| {
                const path = blk: {
                    const path = if (std.mem.startsWith(u8, test_path, self.cfg.tests_root))
                        test_path[self.cfg.tests_root.len..]
                    else
                        test_path;
                    break :blk std.mem.trimStart(u8, path, "/");
                };
                const expect_ok = expectOkFromPath(path) orelse {
                    std.debug.print(
                        "error: the test must start with 'valid/' or 'invalid/': {s}\n",
                        .{path},
                    );
                    return error.InvalidArgs;
                };
                try self.tests.append(self.gpa, .{
                    .path = try self.gpa.dupe(u8, path),
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
                    stats.failures += 1;
                    if (!showFailure(self.cfg, stats.failures)) continue;
                    printFailureDetails(self.cfg, full_path, .{
                        .expect_ok = true,
                        .parse_ok = true,
                        .input = content,
                        .reason = "missing expected json",
                    });
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

                const arena = self.arena.allocator();
                defer _ = self.arena.reset(.retain_capacity);

                const expected_val = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected_json, .{});
                const actual_val = try encode.tomlTableToJsonValue(arena, toml.get_table());

                const eql: bool, const err: ?anyerror = blk: {
                    const eql = self.jsonEquality(arena, &actual_val, &expected_val) catch |err|
                        break :blk .{ false, err };
                    break :blk .{ eql, null };
                };
                if (eql) continue;

                stats.failures += 1;
                const actual_json: ?[]const u8 = if (self.cfg.show)
                    (self.stringifyJsonValue(actual_val) catch null)
                else
                    null;
                defer if (actual_json) |s| self.gpa.free(s);

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

                const actual_json: ?[]const u8 = if (self.cfg.show) blk: {
                    const arena = self.arena.allocator();
                    defer _ = self.arena.reset(.retain_capacity);
                    const actual_val = encode.tomlTableToJsonValue(arena, toml.get_table()) catch break :blk null;
                    break :blk self.stringifyJsonValue(actual_val) catch null;
                } else null;
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
