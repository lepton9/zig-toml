const std = @import("std");
const toml = @import("toml.zig");

pub const ParseError = error{
    OpenFileError,
    InvalidTableNesting,
    InvalidKeyValuePair,
    DuplicateKeyValuePair,
};

const KeyValue = struct {
    key: []const u8,
    value: toml.TomlValue,
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
        return try self.parse_string(buffer);
    }

    pub fn parse_string(self: *Parser, content: []const u8) !*toml.Toml {
        self.content = content;
        return try self.parse_root();
    }

    fn parse_root(self: *Parser) !*toml.Toml {
        const root = try toml.Toml.init(self.alloc);
        try self.parse_table(&root.table.table);
        return root;
    }

    fn parse_table(self: *Parser, root: *toml.TomlTable) !void {
        self.skip_comments();
        while (self.current()) |c| {
            if (c == '[') {
                const header = self.parse_table_header();
                const table = try get_or_create_table(root, header, self.alloc);
                var table_value = toml.TomlValue{ .table = table.* };
                try self.parse_table(&table_value.table);
            } else {
            }
            self.skip_comments();
        }
    }

    fn parse_table_header(self: *Parser) []const u8 {
        self.advance();
        const start = self.index;
        while (self.current()) |c| {
            if (c == ']') {
                const header = self.content[start..self.index];
                self.advance();
                return header;
            }
            self.advance();
        }
        return self.content[start..self.index];
    }
    fn starts_with(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos .. self.pos + prefix.len], prefix);
    }

    fn parse_value(self: *Parser) !toml.TomlValue {
        self.skip_whitespace();
    }

    pub fn current(self: *const Parser) ?u8 {
        if (self.index >= self.content.len) {
            return null;
        } else {
            return self.content[self.index];
        }
    }

    fn advance(self: *Parser) void {
        if (self.index < self.content.len) self.index += 1;
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
        self.skip_whitespace();
        while (self.current()) |c| {
            if (c == '#') {
                self.skip_line();
            } else if (c == '\n' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
        self.skip_whitespace();
    }

    pub fn next(self: *Parser) ?u8 {
        if (self.content.len == 0) return null;
        self.index += 1;
        if (self.index == self.content.len) return null;
        return self.content[self.index];
    }
};

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
