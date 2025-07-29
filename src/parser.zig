const std = @import("std");
const toml = @import("toml.zig");
const types = @import("types.zig");

pub const ParseError = error{
    OpenFileError,
    InvalidTableNesting,
    InvalidValue,
    InvalidKey,
    InvalidKeyValuePair,
    InvalidTableHeader,
    DuplicateKeyValuePair,
    DuplicateTableHeader,
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
        errdefer root.deinit();
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
                const table = try create_table(root, header, self.alloc);
                self.nested = true;
                try self.parse_table(table);
            } else {
                const kv = try self.parse_key_value();
                try add_key_value(root, kv, self.alloc);
            }
            self.skip_comments();
        }
    }

    fn parse_table_header(self: *Parser) ![]const u8 {
        self.advance();
        const start = self.index;
        if (!self.advance_until_any("]")) return ParseError.InvalidTableHeader;
        const header = self.content[start..self.index];
        self.advance();
        return header;
    }

    fn build_nested_table(
        allocator: std.mem.Allocator,
        dotted_key: []const u8,
        value: toml.TomlValue,
    ) !toml.TomlTable {
        const keys = std.mem.trim(u8, dotted_key, " \t");
        if (keys.len == 0) return ParseError.InvalidKey;
        var root = toml.TomlTable.init(allocator);
        const last_dot = last_indexof_qa(keys, '.');
        const inner_table = blk: {
            if (last_dot) |ind| {
                if (ind == keys.len - 1) return ParseError.InvalidKey;
                break :blk try get_or_create_table(
                    &root,
                    keys[0..ind],
                    allocator,
                );
            } else {
                break :blk &root;
            }
        };
        const last_key = try allocator.dupe(
            u8,
            trim_key(keys[if (last_dot) |i| i + 1 else 0..]),
        );
        try add_key_value(inner_table, .{ .key = last_key, .value = value }, allocator);
        return root;
    }

    fn parse_key_value(self: *Parser) !KeyValue {
        const start = self.index;
        while (self.current()) |c| {
            if (c == '=') {
                const key = std.mem.trim(u8, self.content[start..self.index], " \t");
                self.advance();
                var value = try self.parse_value();
                errdefer value.deinit(self.alloc);
                const first_dot_ind = indexof_qa(key, '.');
                if (first_dot_ind) |i| {
                    const root_key = trim_key(key[0..i]);
                    if (root_key.len == 0) return ParseError.InvalidKey;
                    const root_key_a = try self.alloc.dupe(u8, root_key);
                    errdefer self.alloc.free(root_key_a);
                    const table = try build_nested_table(self.alloc, key[i + 1 ..], value);
                    return KeyValue{
                        .key = root_key_a,
                        .value = toml.TomlValue{ .table = table },
                    };
                } else {
                    const k = trim_key(key);
                    if (k.len == 0) return ParseError.InvalidKey;
                    const key_a = try self.alloc.dupe(u8, k);
                    return KeyValue{ .key = key_a, .value = value };
                }
            }
            self.advance();
        }
        return ParseError.InvalidKeyValuePair;
    }

    fn starts_with(self: *Parser, prefix: []const u8) bool {
        if (self.index + prefix.len > self.content.len) return false;
        return std.mem.eql(u8, self.content[self.index .. self.index + prefix.len], prefix);
    }

    fn parse_value(self: *Parser) anyerror!toml.TomlValue {
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
        return ParseError.InvalidValue;
    }

    fn parse_array(self: *Parser) !std.ArrayList(toml.TomlValue) {
        var array = std.ArrayList(toml.TomlValue).init(self.alloc);
        self.advance();
        self.skip_whitespace();
        while (self.current()) |c| {
            if (c == ']') {
                self.advance();
                return array;
            }
            const value = try self.parse_value();
            try array.append(value);
            self.skip_whitespace();
            if (self.current() == ',') {
                self.advance();
                self.skip_whitespace();
            }
        }
        return ParseError.InvalidValue;
    }

    fn parse_inline_table(self: *Parser) !toml.TomlTable {
        var table = toml.TomlTable.init(self.alloc);
        self.advance();
        self.skip_whitespace();
        while (self.current()) |c| {
            if (c == '}') {
                self.advance();
                return table;
            }
            const kv = try self.parse_key_value();
            try add_key_value(&table, kv, self.alloc);
            self.skip_whitespace();
            if (self.current() == ',') {
                self.advance();
                self.skip_whitespace();
            }
        }
        return ParseError.InvalidValue;
    }

    fn parse_scalar(self: *Parser) !toml.TomlValue {
        const start = self.index;
        _ = self.advance_until_any("#,]}\n");
        const str = std.mem.trim(u8, self.content[start..self.index], " \t");
        if (types.interpret_int(str)) |x| {
            return toml.TomlValue{ .int = x };
        } else if (types.interpret_float(str)) |x| {
            return toml.TomlValue{ .float = x };
        } else if (types.interpret_bool(str)) |x| {
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
    keys: []const u8,
    allocator: std.mem.Allocator,
) !*toml.TomlTable {
    var current = root;
    const parts = try split_quote_aware(keys, '.', allocator);
    defer allocator.free(parts);
    for (parts) |part| {
        const key = trim_key(part);
        if (key.len == 0) {
            return ParseError.InvalidKey;
        }
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

fn create_table(
    root: *toml.TomlTable,
    keys: []const u8,
    allocator: std.mem.Allocator,
) !*toml.TomlTable {
    var current = root;
    var created = false;
    const parts = try split_quote_aware(keys, '.', allocator);
    defer allocator.free(parts);
    for (parts) |part| {
        const key = trim_key(part);
        if (key.len == 0) {
            return ParseError.InvalidTableHeader;
        }
        const entry = current.getEntry(key);
        if (entry) |e| {
            if (e.value_ptr.* != .table) return ParseError.InvalidTableHeader;
            current = &e.value_ptr.table;
        } else {
            const k = try allocator.dupe(u8, key);
            const e = try current.getOrPut(k);
            e.value_ptr.* = toml.TomlValue.init_table(allocator);
            e.key_ptr.* = k;
            current = &e.value_ptr.table;
            created = true;
        }
    }
    if (!created) return ParseError.DuplicateTableHeader;
    return current;
}

fn nested_key_value(key_value: *const KeyValue) ?KeyValue {
    if (key_value.value != .table) return null;
    const table = key_value.value.table;
    var it = table.iterator();
    while (it.next()) |e| {
        return KeyValue{ .key = e.key_ptr.*, .value = e.value_ptr.* };
    }
    return null;
}

fn add_key_value(root: *toml.TomlTable, key_value: KeyValue, alloc: std.mem.Allocator) !void {
    const entry = try root.getOrPut(key_value.key);
    if (entry.found_existing) {
        if (entry.value_ptr.* == .table) {
            if (nested_key_value(&key_value)) |nested| {
                var table = key_value.value.table;
                defer table.deinit();
                defer alloc.free(key_value.key);
                return try add_key_value(&entry.value_ptr.table, nested, alloc);
            }
        }
        var value = key_value.value;
        alloc.free(key_value.key);
        value.deinit(alloc);
        return ParseError.DuplicateKeyValuePair;
    }
    entry.value_ptr.* = key_value.value;
    entry.key_ptr.* = key_value.key;
}

fn contains(str: []const u8, c: u8) bool {
    for (str) |char| {
        if (char == c) return true;
    }
    return false;
}

fn is_quoted(s: []const u8) bool {
    return (s.len >= 2 and (s[0] == '"' and s[s.len - 1] == '"' or s[0] == '\'' and s[s.len - 1] == '\''));
}

fn trim_key(key: []const u8) []const u8 {
    return strip_quotes(std.mem.trim(u8, key, " \t"));
}

fn strip_quotes(s: []const u8) []const u8 {
    if (s.len > 2 and is_quoted(s)) {
        const str = s[1 .. s.len - 1];
        if (std.mem.trim(u8, str, " \t").len == str.len) return str;
    }
    return s;
}

fn is_quote(char: u8) bool {
    return char == '"' or char == '\'';
}

fn handle_quote(quote: *?u8, c: u8) void {
    if (quote.* == null) {
        quote.* = c;
    } else if (quote.* == c) {
        quote.* = null;
    }
}

fn last_indexof_qa(str: []const u8, char: u8) ?usize {
    var quote: ?u8 = null;
    for (0..str.len) |i| {
        const c = str[str.len - 1 - i];
        if (is_quote(c)) {
            handle_quote(&quote, c);
        } else if (c == char and quote == null) {
            return str.len - 1 - i;
        }
    }
    return null;
}

fn indexof_qa(str: []const u8, char: u8) ?usize {
    var quote: ?u8 = null;
    for (str, 0..) |c, i| {
        if (is_quote(c)) {
            handle_quote(&quote, c);
        } else if (c == char and quote == null) {
            return i;
        }
    }
    return null;
}

fn split_quote_aware(
    str: []const u8,
    delim: u8,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).init(allocator);
    var start: usize = 0;
    while (indexof_qa(str[start..], delim)) |ind| {
        const part = str[start .. start + ind];
        try parts.append(std.mem.trim(u8, part, " \t"));
        start += ind + 1;
    }
    if (start < str.len) {
        try parts.append(std.mem.trim(u8, str[start..], " \t"));
    }
    return try parts.toOwnedSlice();
}

fn valid_key_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

// TODO:
fn valid_key(_: []const u8) bool {
    return false;
}
