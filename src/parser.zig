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
    InvalidTableArrayHeader,
    InvalidChar,
    InvalidEscapeValue,
    InvalidUnicode,
    KeyValueTypeOverride,
    DuplicateKeyValuePair,
    DuplicateTableHeader,
    ErrorEOF,
    ExpectedArray,
    ExpectedTable,
    ExpectedArrayOfTables,
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
                } else if (try self.try_peek() == '[') {
                    self.advance();
                    const array_key = try self.parse_table_header();
                    const parts = try split_quote_aware(array_key, '.', self.alloc);
                    defer self.alloc.free(parts);
                    if (self.consume() != ']') return ParseError.InvalidTableArrayHeader;
                    try self.parse_array_of_tables(root, parts);
                } else {
                    const header = try self.parse_table_header();
                    const parts = try split_quote_aware(header, '.', self.alloc);
                    defer self.alloc.free(parts);
                    const table = try create_table(root, parts, self.alloc);
                    self.nested = true;
                    try self.parse_table(table);
                }
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
        if (!self.advance_until_any("]")) return ParseError.ErrorEOF;
        const header = std.mem.trim(u8, self.content[start..self.index], " \t");
        self.advance();
        return header;
    }

    fn build_nested_table(
        allocator: std.mem.Allocator,
        key_parts: []const []const u8,
        value: toml.TomlValue,
    ) !toml.TomlTable {
        if (key_parts.len == 0) return ParseError.InvalidKey;
        var root = toml.TomlTable.init(allocator);
        const inner_table = blk: {
            if (key_parts.len > 1) {
                break :blk try get_or_create_table(
                    &root,
                    key_parts[0 .. key_parts.len - 1],
                    allocator,
                );
            } else {
                break :blk &root;
            }
        };
        const value_key = try interpret_key(key_parts[key_parts.len - 1]);
        const last_key = try allocator.dupe(u8, value_key);
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
                const parts = try split_quote_aware(key, '.', self.alloc);
                defer self.alloc.free(parts);
                if (parts.len > 1) {
                    const root_key = try interpret_key(parts[0]);
                    const root_key_a = try self.alloc.dupe(u8, root_key);
                    errdefer self.alloc.free(root_key_a);
                    const table = try build_nested_table(self.alloc, parts[1..], value);
                    return KeyValue{
                        .key = root_key_a,
                        .value = toml.TomlValue{ .table = table },
                    };
                } else {
                    const k = try interpret_key(parts[0]);
                    const key_a = try self.alloc.dupe(u8, k);
                    return KeyValue{ .key = key_a, .value = value };
                }
            }
            self.advance();
            self.skip_comments();
        }
        return ParseError.ErrorEOF;
    }

    fn parse_value(self: *Parser) anyerror!toml.TomlValue {
        self.skip_whitespace();
        if (self.starts_with("\"\"\"")) {
            return toml.TomlValue{ .string = try self.parse_string_value("\"\"\"") };
        } else if (self.starts_with("'''")) {
            return toml.TomlValue{ .string = try self.parse_string_value("'''") };
        } else if (self.starts_with("\"")) {
            return toml.TomlValue{ .string = try self.parse_string_value("\"") };
        } else if (self.starts_with("[")) {
            return toml.TomlValue{ .array = try self.parse_array() };
        } else if (self.starts_with("{")) {
            return toml.TomlValue{ .table = try self.parse_inline_table() };
        }
        return try self.parse_scalar();
        // return error.NotImplemented;
    }

    fn end_of_string(self: *Parser, delimiter: []const u8) bool {
        return self.starts_with(delimiter) and
            !std.mem.eql(u8, delimiter, self.peek_n(delimiter.len) orelse return false);
    }

    fn parse_string_value(self: *Parser, delimiter: []const u8) ![]const u8 {
        var output = std.ArrayList(u8).init(self.alloc);
        errdefer output.deinit();
        for (0..delimiter.len) |_| self.advance();
        const is_multiline = std.mem.eql(u8, delimiter, "\"\"\"") or
            std.mem.eql(u8, delimiter, "'''");
        if (is_multiline and self.current() == '\n') self.advance();
        while (self.current()) |c| {
            switch (c) {
                '\'', '\"' => {
                    if (self.end_of_string(delimiter)) {
                        for (0..delimiter.len) |_| self.advance();
                        return output.toOwnedSlice();
                    }
                },
                '\n', '\r' => if (!is_multiline) return ParseError.InvalidChar,
                '\\' => if (delimiter[0] == '\"') {
                    try self.parse_escaped(is_multiline, &output);
                    continue;
                },
                else => {},
            }
            try output.append(c);
            self.advance();
        }
        return ParseError.ErrorEOF;
    }

    fn parse_escaped(self: *Parser, multiline: bool, output: *std.ArrayList(u8)) !void {
        const c = self.next() orelse return ParseError.ErrorEOF;
        _ = self.next() orelse return ParseError.ErrorEOF;
        switch (c) {
            'u' => try self.parse_unicode(4, output),
            'U' => try self.parse_unicode(8, output),
            'b' => try output.append(0x08),
            'f' => try output.append(0x0c),
            't' => try output.append('\t'),
            'n' => try output.append('\n'),
            'r' => try output.append('\r'),
            '\"' => try output.append('\"'),
            '\\' => try output.append('\\'),
            '\r', '\n' => {
                if (multiline) {
                    self.skip_while_char();
                } else {
                    return ParseError.InvalidChar;
                }
            },
            else => return ParseError.InvalidEscapeValue,
        }
    }

    fn parse_unicode(self: *Parser, size: u8, output: *std.ArrayList(u8)) !void {
        if (self.index + size > self.content.len) return ParseError.ErrorEOF;
        const cp = std.fmt.parseInt(
            u21,
            self.content[self.index .. self.index + size],
            16,
        ) catch return ParseError.InvalidUnicode;
        for (0..size) |_| self.advance();
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, buf[0..]);
        try output.appendSlice(buf[0..len]);
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
            self.skip_while_char();
            if (self.current() == ',') {
                self.advance();
                self.skip_while_char();
            }
        }
        return ParseError.ErrorEOF;
    }

    fn parse_array_of_tables(
        self: *Parser,
        root: *toml.TomlTable,
        key_parts: []const []const u8,
    ) anyerror!void {
        self.nested = true;
        var array = try get_or_create_array(root, key_parts, self.alloc);
        var table_toml = toml.TomlValue{ .table = toml.TomlTable.init(self.alloc) };
        {
            errdefer table_toml.deinit(self.alloc);
            try self.parse_table(&table_toml.table);
        }
        try array.append(table_toml);

        if ((self.current() orelse return) == '[') {
            if (try self.try_peek() == '[') return;
            const array_key = self.peek_until("]") orelse return ParseError.ErrorEOF;
            const parts = try split_quote_aware(array_key[1..], '.', self.alloc);
            defer self.alloc.free(parts);
            if (std.mem.eql(u8, key_parts[0], parts[0])) {
                if (parts.len == 1) return ParseError.KeyValueTypeOverride;
                for (0..array_key.len + 1) |_| self.advance();
                const tab = blk: {
                    if (key_parts.len > 1 and std.mem.eql(u8, key_parts[1], parts[1])) {
                        if (key_parts.len == parts.len) return ParseError.ExpectedArray;
                        break :blk try get_or_create_table(&table_toml.table, parts[1..], self.alloc);
                    } else {
                        const ar = try get_or_create_array(root, key_parts[0..1], self.alloc);
                        if (ar.items.len == 0) return ParseError.ExpectedTable;
                        const last = &ar.items[ar.items.len - 1].table;
                        break :blk try get_or_create_table(last, parts[1..], self.alloc);
                    }
                };
                errdefer {
                    var it = tab.iterator();
                    while (it.next()) |e| {
                        e.value_ptr.deinit(self.alloc);
                        self.alloc.free(e.key_ptr.*);
                    }
                    tab.deinit();
                }
                self.nested = true;
                try self.parse_table(tab);
            }
        }
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
        return ParseError.ErrorEOF;
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
        } else if (try types.interpret_datetime(str)) |x| {
            return toml.TomlValue{ .datetime = x };
        } else if (try types.interpret_date(str)) |x| {
            return toml.TomlValue{ .date = x };
        } else if (try types.interpret_time(str)) |x| {
            return toml.TomlValue{ .time = x };
        }
        return ParseError.NotImplemented;
    }

    fn current(self: *const Parser) ?u8 {
        if (self.index >= self.content.len) {
            return null;
        } else {
            return self.content[self.index];
        }
    }

    fn consume(self: *Parser) ?u8 {
        defer self.advance();
        return self.current();
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

    fn starts_with(self: *Parser, prefix: []const u8) bool {
        if (self.index + prefix.len > self.content.len) return false;
        return std.mem.eql(u8, self.content[self.index .. self.index + prefix.len], prefix);
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
            if (c == '\n') {
                self.advance();
                break;
            }
            self.advance();
        }
    }

    fn skip_while_char(self: *Parser) void {
        self.skip_whitespace();
        if (self.current() == '\n') {
            self.skip_line();
            self.skip_while_char();
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

    fn next(self: *Parser) ?u8 {
        if (self.index + 1 >= self.content.len) return null;
        self.index += 1;
        return self.content[self.index];
    }

    fn try_next(self: *Parser) !u8 {
        return self.next() orelse ParseError.ErrorEOF;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.index < self.content.len - 1) self.content[self.index + 1] else null;
    }

    fn try_peek(self: *Parser) !u8 {
        return self.peek() orelse ParseError.ErrorEOF;
    }

    fn peek_n(self: *Parser, n: usize) ?[]const u8 {
        if (self.index + 1 + n > self.content.len) return null;
        return self.content[self.index + 1 .. self.index + 1 + n];
    }

    fn peek_until(self: *Parser, str: []const u8) ?[]const u8 {
        var i = self.index;
        while (i + str.len <= self.content.len) {
            if (self.content[i] == '#') {
                while (i < self.content.len and self.content[i] != '\n') {
                    i += 1;
                }
            }
            if (std.mem.eql(u8, str, self.content[i .. i + str.len]))
                return self.content[self.index..i];
            i += 1;
        }
        return null;
    }
};

fn get_or_create_array(
    root: *toml.TomlTable,
    key_parts: []const []const u8,
    allocator: std.mem.Allocator,
) anyerror!*std.ArrayList(toml.TomlValue) {
    var table = root;
    for (key_parts[0 .. key_parts.len - 1]) |part| {
        const key = try interpret_key(part);
        if (table.getEntry(key)) |entry| {
            if (entry.value_ptr.* == .table) {
                table = &entry.value_ptr.table;
            } else if (entry.value_ptr.* == .array) {
                const array: std.ArrayList(toml.TomlValue) = entry.value_ptr.array;
                if (array.items.len == 0) return ParseError.ExpectedTable;
                table = &array.items[array.items.len - 1].table;
            } else {
                return ParseError.ExpectedArray;
            }
        } else {
            const new_table = toml.TomlTable.init(allocator);
            const k = try allocator.dupe(u8, key);
            try add_key_value(
                table,
                .{ .key = k, .value = toml.TomlValue{ .table = new_table } },
                allocator,
            );
            table = &table.getEntry(k).?.value_ptr.table;
        }
    }
    const final_key = key_parts[key_parts.len - 1];
    if (table.getEntry(final_key)) |entry| {
        if (entry.value_ptr.* != .array) return ParseError.ExpectedArray;
        if (entry.value_ptr.array.items.len == 0) return ParseError.ExpectedArrayOfTables;
        for (entry.value_ptr.array.items) |elem| {
            if (elem != .table) return ParseError.ExpectedArrayOfTables;
        }
        return &entry.value_ptr.array;
    } else {
        const array = std.ArrayList(toml.TomlValue).init(allocator);
        const k = try allocator.dupe(u8, try interpret_key(final_key));
        try add_key_value(
            table,
            .{ .key = k, .value = toml.TomlValue{ .array = array } },
            allocator,
        );
        return &table.getEntry(k).?.value_ptr.array;
    }
}

fn get_or_create_table(
    root: *toml.TomlTable,
    key_parts: []const []const u8,
    allocator: std.mem.Allocator,
) !*toml.TomlTable {
    var current = root;
    for (key_parts) |part| {
        const key = try interpret_key(part);
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
    key_parts: []const []const u8,
    allocator: std.mem.Allocator,
) !*toml.TomlTable {
    var current = root;
    var created = false;
    for (key_parts) |part| {
        const key = interpret_key(part) catch
            return ParseError.InvalidTableHeader;
        const entry = current.getEntry(key);
        if (entry) |e| {
            if (e.value_ptr.* != .table) return ParseError.KeyValueTypeOverride;
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

fn interpret_key(str: []const u8) ![]const u8 {
    var key = std.mem.trim(u8, str, " \t");
    if (is_quoted(key)) {
        const unquoted = std.mem.trim(u8, key[1 .. key.len - 1], " \t");
        const can_remove = unquoted.len > 0 and all(unquoted, valid_key_char);
        return if (can_remove) unquoted else key;
    } else {
        if (key.len > 0 and all(key, valid_key_char)) return key;
        return ParseError.InvalidKey;
    }
}

fn is_quoted(s: []const u8) bool {
    return (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\'')));
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

fn all(str: []const u8, func: fn (u8) bool) bool {
    for (str) |c| if (!func(c)) return false;
    return true;
}
