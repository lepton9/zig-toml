const std = @import("std");
const toml = @import("toml.zig");

pub const ParseError = error{
    OpenFileError,
    InvalidTableNesting,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    content: []const u8 = undefined,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = .{ .alloc = allocator };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.alloc.destroy(self);
    }

    pub fn parse_file(self: *Parser, file_path: []const u8) !*toml.Toml {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        const buffer = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(buffer);
        _ = try file.readAll(buffer);
        return self.parse_string(buffer);
    }

    pub fn parse_string(self: *Parser, content: []const u8) !*toml.Toml {
        self.content = content;
        return self.parse_root();
    }

    fn parse_root(self: *Parser) !toml.Toml {
        const root = try toml.Toml.init(self.alloc);
        self.parse_table(&root.table.table);
        return root;
    }

    fn parse_table(self: *Parser, root: *toml.TomlTable) !void {
        var current = root;
        self.skip_comments();
        while (self.current() != null) {
            self.skip_comments();
        }
    }

    pub fn current(self: *const Parser) ?u8 {
        if (self.content.len == 0) {
            return null;
        } else {
            return self.input[self.index];
        }
    }

    fn advance(self: *Parser) void {
        if (self.index < self.input.len) self.index += 1;
    }

    fn skip_whitespace(self: *Parser) void {
        while (self.current()) |c| {
            if (c == ' ' or c == '\t') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skip_line(self: *Parser) void {
        while (self.current()) |c| {
            self.advance();
            if (c == '\n') break;
        }
    }

    fn skip_comments(self: *Parser) void {
        while (self.current()) |c| {
            if (c == '#') {
                self.skip_line();
            } else if (c == '\n' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    pub fn next(self: *Parser) ?u8 {
        if (self.content.len == 0) return null;
        self.index += 1;
        if (self.index == self.content.len) return null;
        return self.content[self.index];
    }
};

// fn is_comment(line: []const u8) {
//
// }

fn get_or_create_table(
    root: *toml.TomlTable,
    path: []const u8,
    allocator: std.mem.Allocator,
) !*std.StringHashMap(toml.TomlValue) {
    var current = root;
    var parts = std.mem.tokenizeSequence(u8, path, ".");
    while (parts.next()) |part| {
        const key = std.mem.trim(u8, part, " \t");
        const entry = try current.getOrPut(key);
        if (!entry.found_existing) {
            const sub_table = toml.TomlValue.init_table(allocator);
            entry.value_ptr.* = sub_table;
            current = &entry.value_ptr.table;
        } else if (entry.value_ptr.* != .table) {
            return ParseError.InvalidTableNesting;
        } else {
            current = &entry.value_ptr.table;
        }
    }
    return current;
}
