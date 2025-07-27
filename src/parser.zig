const std = @import("std");
const toml = @import("toml.zig");

pub const ParseError = error{
    OpenFileError,
    InvalidTableNesting,
    InvalidKeyValuePair,
    InvalidTableHeader,
    DuplicateKeyValuePair,
    NotImplemented,
};

const KeyValue = struct {
    key: []const u8,
    value: toml.TomlValue,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    content: []const u8 = undefined,
    index: usize = 0,
    nested: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = .{ .alloc = allocator };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.alloc.free(self.content);
        self.alloc.destroy(self);
    }

    pub fn parse_file(self: *Parser, file_path: []const u8) !*toml.Toml {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        const buffer = try self.alloc.alloc(u8, file_size);
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
                if (self.nested) {
                    self.nested = false;
                    break;
                }
                const header = try self.parse_table_header();
                const table = try get_or_create_table(root, header, self.alloc);
                self.nested = true;
                try self.parse_table(table);
            } else {
                const kv = try self.parse_key_value();
                try add_key_value(root, kv);
            }
            self.skip_comments();
        }
    }

    fn parse_table_header(self: *Parser) ![]const u8 {
        self.advance();
        const start = self.index;
        if (!self.advance_until(']')) return ParseError.InvalidTableHeader;
        const header = self.content[start..self.index];
        self.advance();
        return header;
    }

    fn parse_key_value(self: *Parser) !KeyValue {
        const start = self.index;
        while (self.current()) |c| {
            if (c == '=') {
                const key = self.content[start..self.index];
                // TODO: handle dotted keys and add a table
                const key_a = try self.alloc.dupe(u8, key);
                self.advance();
                self.skip_whitespace();
                const value = try self.parse_value();
                return KeyValue{ .key = key_a, .value = value };
            }
            self.advance();
        }
        return ParseError.InvalidKeyValuePair;
    }

    fn starts_with(self: *Parser, prefix: []const u8) bool {
        if (self.index + prefix.len > self.content.len) return false;
        return std.mem.eql(u8, self.content[self.index .. self.index + prefix.len], prefix);
    }

    fn parse_value(self: *Parser) !toml.TomlValue {
        self.skip_whitespace();
        if (self.starts_with("\"")) {
            const str = try self.parse_regular_string("\"");
            const str_a = try self.alloc.alloc(u8, str.len);
            @memcpy(str_a, str);
            return toml.TomlValue{ .string = str_a };
        } else if (self.starts_with("[")) {
            return toml.TomlValue{ .array = try self.parse_array() };
        } else if (self.starts_with("{")) {
            return toml.TomlValue{ .table = try self.parse_inline_table() };
        }
        return try self.parse_scalar();
        // return error.NotImplemented;
    }

    fn parse_regular_string(self: *Parser, delimiter: []const u8) ![]const u8 {
        self.advance();
        const start = self.index;
        while (self.current()) |_| {
            if (self.starts_with(delimiter)) {
                const str_value = self.content[start..self.index];
                self.advance();
                return str_value;
            }
            self.advance();
        }
        return ParseError.InvalidKeyValuePair;
    }

    fn parse_array(_: *Parser) !std.ArrayList(toml.TomlValue) {
        return ParseError.NotImplemented;
    }

    fn parse_inline_table(_: *Parser) !toml.TomlTable {
        return ParseError.NotImplemented;
    }

    fn parse_scalar(self: *Parser) !toml.TomlValue {
        const start = self.index;
        _ = self.advance_until('\n');
        const str = self.content[start..self.index];
        if (interpret_int(str)) |x| {
            return toml.TomlValue{ .int = x };
        } else if (interpret_float(str)) |x| {
            return toml.TomlValue{ .float = x };
        } else if (interpret_bool(str)) |x| {
            return toml.TomlValue{ .bool = x };
        }
        return ParseError.NotImplemented;
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

    fn advance_until_any(self: *Parser, chars: []const u8) bool {
        while (self.current()) |c| {
            if (contains(chars, c)) return true;
            self.advance();
        }
        return false;
    }

    fn advance_until_delim(self: *Parser, delim: []const u8) bool {
        while (self.current()) |_| {
            if (self.starts_with(delim)) return true;
            self.advance();
        }
        return false;
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
) !*toml.TomlTable {
    var current = root;
    var parts = std.mem.tokenizeSequence(u8, path, ".");
    while (parts.next()) |part| {
        const key = std.mem.trim(u8, part, " \t");
        const entry = try current.getOrPut(key);
        if (!entry.found_existing) {
            const sub_table = toml.TomlValue.init_table(allocator);
            entry.value_ptr.* = sub_table;
            entry.key_ptr.* = try allocator.dupe(u8, key);
            current = &entry.value_ptr.table;
        } else if (entry.value_ptr.* != .table) {
            return ParseError.InvalidTableNesting;
        } else {
            current = &entry.value_ptr.table;
        }
    }
    return current;
}

fn add_key_value(root: *toml.TomlTable, key_value: KeyValue) !void {
    const entry = try root.getOrPut(key_value.key);
    if (entry.found_existing) {
        return ParseError.DuplicateKeyValuePair;
    }
    entry.value_ptr.* = key_value.value;
    entry.key_ptr.* = key_value.key;
}

fn interpret_int(str: []const u8) ?i64 {
    return std.fmt.parseInt(i64, str, 0) catch return null;
}

fn interpret_float(str: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, str) catch return null;
}

fn interpret_bool(str: []const u8) ?bool {
    if (std.mem.eql(u8, "true", str)) return true;
    if (std.mem.eql(u8, "false", str)) return false;
    return null;
}

fn contains(str: []const u8, c: u8) bool {
    for (str) |char| {
        if (char == c) return true;
    }
    return false;
}
