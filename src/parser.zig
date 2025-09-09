const std = @import("std");
const toml = @import("toml.zig");
const types = @import("types.zig");
const KeyValue = @import("table.zig").KeyValue;

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
    InvalidStringDelimiter,
    KeyValueTypeOverride,
    DuplicateKeyValuePair,
    DuplicateTableHeader,
    RedefinitionOfTable,
    InlineDefinition,
    TrailingComma,
    ErrorEOF,
    ExpectedArray,
    ExpectedTable,
    ExpectedArrayOfTables,
};

const ErrorContext = struct {
    err: anyerror,
    index: usize,
    line_number: usize,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    content: []const u8 = undefined,
    index: usize = 0,
    error_ctx: ?ErrorContext = null,

    pub fn init(allocator: std.mem.Allocator) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = .{ .alloc = allocator };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.alloc.destroy(self);
    }

    fn make_error_context(self: *Parser, err: anyerror) void {
        self.error_ctx = ErrorContext{
            .err = err,
            .index = self.index,
            .line_number = self.cur_line_number(),
        };
    }

    pub fn get_error_context(self: *Parser) ?ErrorContext {
        return self.error_ctx;
    }

    fn cur_line_number(self: *Parser) usize {
        return std.mem.count(u8, self.content[0..self.index], "\n") + 1;
    }

    fn reset(self: *Parser) void {
        self.index = 0;
        self.error_ctx = null;
    }

    pub fn parse_file(self: *Parser, file_path: []const u8) !*toml.Toml {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        const buffer = try self.alloc.alloc(u8, file_size);
        _ = try file.readAll(buffer);
        defer self.alloc.free(buffer);
        return try self.parse_string(buffer);
    }

    pub fn parse_string(self: *Parser, content: []const u8) !*toml.Toml {
        self.reset();
        self.content = content;
        return self.parse_root() catch |err| {
            self.make_error_context(err);
            return err;
        };
    }

    fn parse_root(self: *Parser) !*toml.Toml {
        const root = try toml.Toml.init(self.alloc);
        errdefer root.deinit();
        try self.parse_table(&root.table.table);
        return root;
    }

    fn parse_table(self: *Parser, root: *toml.TomlTable) !void {
        try self.skip_while_char();
        while (self.current()) |c| {
            if (c == '[') {
                if (root.t_type != .root) {
                    break;
                } else if (try self.try_peek() == '[') {
                    self.advance();
                    const array_key = try self.parse_table_header();
                    if (self.consume() != ']') return ParseError.InvalidTableArrayHeader;
                    try self.expect_skip_line();
                    const parts = try types.split_dotted_key(array_key, self.alloc);
                    defer self.alloc.free(parts);
                    if (parts.len == 0) return ParseError.InvalidTableArrayHeader;
                    try self.parse_array_of_tables(root, parts);
                } else {
                    const header = try self.parse_table_header();
                    try self.expect_skip_line();
                    const parts = try types.split_dotted_key(header, self.alloc);
                    defer self.alloc.free(parts);
                    if (parts.len == 0) return ParseError.InvalidTableHeader;
                    const table = try root.create_table(parts, .header_t, self.alloc);
                    try self.parse_table(table);
                }
            } else {
                const kv = try self.parse_key_value();
                {
                    errdefer {
                        var value = kv.value;
                        self.alloc.free(kv.key_parts);
                        value.deinit(self.alloc);
                    }
                    try self.expect_skip_line();
                }
                try root.add_key_value(kv, self.alloc);
            }
            try self.skip_while_char();
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

    fn parse_key_value(self: *Parser) !KeyValue {
        const key_parts = try self.parse_key();
        errdefer self.alloc.free(key_parts);
        var value = try self.parse_value();
        errdefer value.deinit(self.alloc);
        if (key_parts.len == 0) return ParseError.InvalidKey;
        return KeyValue{ .key_parts = key_parts, .value = value };
    }

    fn parse_key(self: *Parser) ![]const []const u8 {
        var parts = try std.ArrayList([]const u8).initCapacity(self.alloc, 5);
        errdefer parts.deinit(self.alloc);
        var start: ?usize = null;
        self.skip_whitespace();
        while (self.current()) |c| {
            switch (c) {
                '=' => {
                    if (start) |i| {
                        try parts.append(self.alloc, std.mem.trim(u8, self.content[i..self.index], " \t"));
                    }
                    self.advance();
                    return try parts.toOwnedSlice(self.alloc);
                },
                '\"', '\'' => {
                    if (start) |_| return ParseError.InvalidKey;
                    const delim = self.content[self.index .. self.index + 1];
                    start = self.index;
                    const key_part = try self.parse_string_value(delim);
                    defer self.alloc.free(key_part);
                    self.skip_whitespace();
                },
                '.' => {
                    if (start) |i| {
                        try parts.append(self.alloc, std.mem.trim(u8, self.content[i..self.index], " \t"));
                        start = null;
                    }
                    if (parts.items.len == 0) return ParseError.InvalidKey;
                    self.advance();
                    self.skip_whitespace();
                },
                '\n' => return ParseError.InvalidKey,
                else => {
                    if (start == null) {
                        start = self.index;
                    }
                    self.advance();
                },
            }
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
        } else if (self.starts_with("'")) {
            return toml.TomlValue{ .string = try self.parse_string_value("'") };
        } else if (self.starts_with("[")) {
            return toml.TomlValue{ .array = try self.parse_array() };
        } else if (self.starts_with("{")) {
            return toml.TomlValue{ .table = try self.parse_inline_table() };
        }
        return try self.parse_scalar();
    }

    fn end_of_string(self: *Parser, delimiter: []const u8) bool {
        return self.starts_with(delimiter) and !blk: {
            break :blk std.mem.eql(
                u8,
                delimiter,
                self.peek_n(delimiter.len) orelse break :blk false,
            );
        };
    }

    fn invalid_string_delim(self: *Parser, delimiter: []const u8) bool {
        if (std.mem.eql(
            u8,
            delimiter,
            self.look_behind(delimiter.len) orelse return true,
        )) {
            return !(self.index >= delimiter.len + 1 and
                self.content[self.index - delimiter.len - 1] == '\\');
        }
        return false;
    }

    fn parse_string_value(self: *Parser, delimiter: []const u8) ![]const u8 {
        var output = try std.ArrayList(u8).initCapacity(self.alloc, 5);
        errdefer output.deinit(self.alloc);
        for (0..delimiter.len) |_| self.advance();
        const is_multiline = std.mem.eql(u8, delimiter, "\"\"\"") or
            std.mem.eql(u8, delimiter, "'''");
        if (is_multiline and (self.current() == '\n' or self.current() == '\\'))
            try self.skip_while_char();
        while (self.current()) |c| {
            switch (c) {
                '\'', '\"' => {
                    if (self.end_of_string(delimiter)) {
                        if (output.items.len > 0 and self.invalid_string_delim(delimiter))
                            return ParseError.InvalidStringDelimiter;
                        for (0..delimiter.len) |_| self.advance();
                        return output.toOwnedSlice(self.alloc);
                    }
                },
                '\n', '\r' => if (!is_multiline) return ParseError.InvalidChar,
                '\\' => if (delimiter[0] == '\"') {
                    try self.parse_escaped(is_multiline, &output);
                    continue;
                },
                else => {},
            }
            try output.append(self.alloc, c);
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
            'b' => try output.append(self.alloc, 0x08),
            'f' => try output.append(self.alloc, 0x0c),
            't' => try output.append(self.alloc, '\t'),
            'n' => try output.append(self.alloc, '\n'),
            'r' => try output.append(self.alloc, '\r'),
            '\"' => try output.append(self.alloc, '\"'),
            '\\' => try output.append(self.alloc, '\\'),
            '\r', '\n', ' ', '\t' => {
                if (multiline) {
                    try self.expect_skip_backslash(c == ' ');
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
        try output.appendSlice(self.alloc, buf[0..len]);
    }

    fn parse_array(self: *Parser) !std.ArrayList(toml.TomlValue) {
        var array = try std.ArrayList(toml.TomlValue).initCapacity(self.alloc, 5);
        errdefer toml.deinit_array(&array, self.alloc);
        self.advance();
        try self.skip_while_char();
        while (self.current()) |c| {
            if (c == ']') {
                self.advance();
                return array;
            }
            const value = try self.parse_value();
            try array.append(self.alloc, value);
            try self.skip_while_char();
            if (self.current() == ',') {
                self.advance();
                try self.skip_while_char();
            }
        }
        return ParseError.ErrorEOF;
    }

    fn parse_array_of_tables(
        self: *Parser,
        root: *toml.TomlTable,
        key_parts: []const []const u8,
    ) anyerror!void {
        var array = try root.get_or_create_array(key_parts, self.alloc);
        var table_toml = toml.TomlValue{
            .table = toml.TomlTable.init(self.alloc, .array_t, .explicit),
        };
        {
            errdefer table_toml.deinit(self.alloc);
            try self.parse_table(&table_toml.table);
        }
        try array.append(self.alloc, table_toml);

        if ((self.current() orelse return) == '[') {
            if (try self.try_peek() == '[') return;
            const array_key = self.peek_until("]") orelse return ParseError.ErrorEOF;
            const parts = try types.split_dotted_key(array_key[1..], self.alloc);
            defer self.alloc.free(parts);
            if (std.mem.eql(u8, key_parts[0], parts[0])) {
                if (parts.len == 1 and key_parts.len == 1) return ParseError.KeyValueTypeOverride;
                for (0..array_key.len + 1) |_| self.advance();
                var nested_n: u8 = 0;
                const table = blk: {
                    if (parts.len == 1) {
                        break :blk try root.get_or_create_table(parts, .array_t, .explicit, self.alloc);
                    } else {
                        const last_array = try root.get_last_array(parts[0 .. parts.len - 1], &nested_n);
                        if (last_array.items.len == 0) return ParseError.ExpectedTable;
                        const last = &last_array.items[last_array.items.len - 1].table;
                        break :blk try last.get_or_create_table(parts[nested_n..], .array_t, .explicit, self.alloc);
                    }
                };
                try self.parse_table(table);
            }
        }
    }

    fn parse_inline_table(self: *Parser) !toml.TomlTable {
        var table = toml.TomlTable.init_inline(self.alloc);
        errdefer table.deinit(self.alloc);
        var comma = false;
        self.advance();
        self.skip_whitespace();
        while (self.current()) |c| {
            if (c == '}') {
                if (comma) return ParseError.TrailingComma;
                self.advance();
                return table;
            }
            const kv = try self.parse_key_value();
            try table.add_key_value(kv, self.alloc);
            self.skip_whitespace();
            if (self.current() == ',') {
                comma = true;
                self.advance();
                self.skip_whitespace();
            } else {
                comma = false;
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
        return ParseError.InvalidValue;
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
            if (types.is_whitespace(c)) {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skip_line(self: *Parser) !void {
        while (self.current()) |c| {
            if (c == '\r') {
                const n = try self.try_next();
                if (n != '\n') return ParseError.InvalidChar;
                self.advance();
                break;
            } else if (c == '\n') {
                self.advance();
                break;
            }
            self.advance();
        }
    }

    fn expect_skip_backslash(self: *Parser, expect_newline: bool) !void {
        var newline = false;
        while (self.current()) |c| {
            if (c == '\n') {
                try self.skip_line();
                newline = true;
                continue;
            } else if (!types.is_whitespace(c)) {
                if (!newline and expect_newline) return ParseError.InvalidChar;
                return;
            }
            self.advance();
        }
    }

    fn expect_skip_line(self: *Parser) !void {
        while (self.current()) |c| {
            if (c == '\n' or c == '\r' or c == '#') {
                return try self.skip_line();
            }
            if (!types.is_whitespace(c)) return ParseError.InlineDefinition;
            self.advance();
        }
    }

    fn skip_while_char(self: *Parser) !void {
        try self.skip_comments_ws();
        const c = self.current();
        if (c == '\n' or c == '\r' or c == '#') {
            try self.skip_comments_ws();
            try self.skip_while_char();
        }
    }

    fn skip_comments_ws(self: *Parser) !void {
        self.skip_whitespace();
        while (self.current()) |c| {
            if (c == '\n' or c == '\r' or c == '#') {
                try self.skip_line();
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

    fn look_behind(self: *Parser, n: usize) ?[]const u8 {
        if (self.index - n < 0) return null;
        return self.content[self.index - n .. self.index];
    }
};

fn contains(str: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, str, c) != null;
}
