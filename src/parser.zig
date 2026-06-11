const std = @import("std");
const toml = @import("toml.zig");
const types = @import("types.zig");
const KeyValue = @import("table.zig").KeyValue;

pub const ParseError = error{
    OpenFileError,
    NotUTF8,
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
    gpa: std.mem.Allocator,
    content: []const u8 = undefined,
    index: usize = 0,
    error_ctx: ?ErrorContext = null,

    pub fn init(gpa: std.mem.Allocator) !*Parser {
        const parser = try gpa.create(Parser);
        parser.* = .{ .gpa = gpa };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.gpa.destroy(self);
    }

    fn makeErrorCtx(self: *Parser, err: anyerror) void {
        self.error_ctx = ErrorContext{
            .err = err,
            .index = self.index,
            .line_number = self.curLineNumber(),
        };
    }

    pub fn getErrorCtx(self: *Parser) ?ErrorContext {
        return self.error_ctx;
    }

    fn curLineNumber(self: *Parser) usize {
        return std.mem.count(u8, self.content[0..self.index], "\n") + 1;
    }

    fn reset(self: *Parser) void {
        self.index = 0;
        self.error_ctx = null;
    }

    /// Parses a TOML file from the given file path.
    pub fn parseFile(self: *Parser, io: std.Io, file_path: []const u8) !*toml.Toml {
        const cwd = std.Io.Dir.cwd();
        const buffer = try cwd.readFileAlloc(io, file_path, self.gpa, .unlimited);
        defer self.gpa.free(buffer);
        return self.parseData(buffer);
    }

    /// Parses the given content into TOML.
    pub fn parseData(self: *Parser, content: []const u8) !*toml.Toml {
        self.reset();
        self.content = content;
        return self.parseRoot() catch |err| {
            self.makeErrorCtx(err);
            return err;
        };
    }

    fn parseRoot(self: *Parser) !*toml.Toml {
        if (!std.unicode.utf8ValidateSlice(self.content)) return ParseError.NotUTF8;
        self.skipUTF8Bom();
        const root = try toml.Toml.init(self.gpa);
        errdefer root.deinit();
        try self.parseTable(&root.table.table);
        return root;
    }

    fn parseTable(self: *Parser, root: *toml.TomlTable) !void {
        try self.skipWhileChar();
        while (self.current()) |c| {
            if (c == '[') {
                if (root.t_type != .root) {
                    break;
                } else if (try self.tryPeek() == '[') {
                    self.advance();
                    const array_key = try self.parseTableHeader();
                    if (self.consume() != ']') return ParseError.InvalidTableArrayHeader;
                    try self.expectSkipLine();
                    const parts = try types.splitDottedKey(array_key, self.gpa);
                    defer self.gpa.free(parts);
                    if (parts.len == 0) return ParseError.InvalidTableArrayHeader;
                    try self.parseArrayOfTables(root, parts);
                } else {
                    const header = try self.parseTableHeader();
                    try self.expectSkipLine();
                    const parts = try types.splitDottedKey(header, self.gpa);
                    defer self.gpa.free(parts);
                    if (parts.len == 0) return ParseError.InvalidTableHeader;
                    const table = try root.createTable(parts, .header_t, self.gpa);
                    try self.parseTable(table);
                }
            } else {
                const kv = try self.parseKeyValue();
                {
                    errdefer {
                        var value = kv.value;
                        self.gpa.free(kv.key_parts);
                        value.deinit(self.gpa);
                    }
                    try self.expectSkipLine();
                }
                try root.addKeyValue(kv, self.gpa);
            }
            try self.skipWhileChar();
        }
    }

    fn parseTableHeader(self: *Parser) ![]const u8 {
        self.advance();
        const start = self.index;
        if (!self.advanceUntilAny("]")) return ParseError.ErrorEOF;
        const header = std.mem.trim(u8, self.content[start..self.index], " \t");
        self.advance();
        return header;
    }

    fn parseKeyValue(self: *Parser) !KeyValue {
        const key_parts = try self.parseKey();
        errdefer self.gpa.free(key_parts);
        var value = try self.parseValue();
        errdefer value.deinit(self.gpa);
        if (key_parts.len == 0) return ParseError.InvalidKey;
        return KeyValue{ .key_parts = key_parts, .value = value };
    }

    fn parseKey(self: *Parser) ![]const []const u8 {
        var parts = try std.ArrayList([]const u8).initCapacity(self.gpa, 5);
        errdefer parts.deinit(self.gpa);
        var start: ?usize = null;
        self.skipWhitespace();
        while (self.current()) |c| {
            switch (c) {
                '=' => {
                    if (start) |i| {
                        try parts.append(
                            self.gpa,
                            std.mem.trim(u8, self.content[i..self.index], " \t"),
                        );
                    }
                    self.advance();
                    return try parts.toOwnedSlice(self.gpa);
                },
                '\"', '\'' => {
                    if (start) |_| return ParseError.InvalidKey;
                    const delim = self.content[self.index .. self.index + 1];
                    start = self.index;
                    const key_part = try self.parseStringValue(delim);
                    defer self.gpa.free(key_part);
                    self.skipWhitespace();
                },
                '.' => {
                    if (start) |i| {
                        try parts.append(self.gpa, std.mem.trim(u8, self.content[i..self.index], " \t"));
                        start = null;
                    }
                    if (parts.items.len == 0) return ParseError.InvalidKey;
                    self.advance();
                    self.skipWhitespace();
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

    fn parseValue(self: *Parser) anyerror!toml.TomlValue {
        self.skipWhitespace();
        if (self.startsWith("\"\"\"")) {
            return toml.TomlValue{ .string = try self.parseStringValue("\"\"\"") };
        } else if (self.startsWith("'''")) {
            return toml.TomlValue{ .string = try self.parseStringValue("'''") };
        } else if (self.startsWith("\"")) {
            return toml.TomlValue{ .string = try self.parseStringValue("\"") };
        } else if (self.startsWith("'")) {
            return toml.TomlValue{ .string = try self.parseStringValue("'") };
        } else if (self.startsWith("[")) {
            return toml.TomlValue{ .array = try self.parseArray() };
        } else if (self.startsWith("{")) {
            return toml.TomlValue{ .table = try self.parseInlineTable() };
        }
        return try self.parseScalar();
    }

    fn isEndOfString(self: *Parser, delimiter: []const u8) bool {
        return self.startsWith(delimiter) and !blk: {
            break :blk std.mem.eql(
                u8,
                delimiter,
                self.peekN(delimiter.len) orelse break :blk false,
            );
        };
    }

    fn invalidStringDelim(self: *Parser, delimiter: []const u8) bool {
        if (std.mem.eql(
            u8,
            delimiter,
            self.lookBehind(delimiter.len) orelse return true,
        )) {
            return !(self.index >= delimiter.len + 1 and
                self.content[self.index - delimiter.len - 1] == '\\');
        }
        return false;
    }

    fn parseStringValue(self: *Parser, delimiter: []const u8) ![]const u8 {
        var output = try std.ArrayList(u8).initCapacity(self.gpa, 5);
        errdefer output.deinit(self.gpa);
        for (0..delimiter.len) |_| self.advance();
        const is_multiline = std.mem.eql(u8, delimiter, "\"\"\"") or
            std.mem.eql(u8, delimiter, "'''");
        if (is_multiline and (self.current() == '\n' or self.current() == '\\'))
            try self.skipWhileChar();
        while (self.current()) |c| {
            switch (c) {
                '\'', '\"' => {
                    if (self.isEndOfString(delimiter)) {
                        if (output.items.len > 0 and self.invalidStringDelim(delimiter))
                            return ParseError.InvalidStringDelimiter;
                        for (0..delimiter.len) |_| self.advance();
                        return output.toOwnedSlice(self.gpa);
                    }
                },
                '\n', '\r' => if (!is_multiline) return ParseError.InvalidChar,
                '\\' => if (delimiter[0] == '\"') {
                    try self.parseEscaped(is_multiline, &output);
                    continue;
                },
                else => {},
            }

            // Disallow unescaped control characters in strings.
            if ((c <= 0x1F or c == 0x7F) and c != '\t') {
                if (!(is_multiline and (c == '\n' or c == '\r'))) {
                    return ParseError.InvalidChar;
                }
            }

            try output.append(self.gpa, c);
            self.advance();
        }
        return ParseError.ErrorEOF;
    }

    fn parseEscaped(self: *Parser, multiline: bool, output: *std.ArrayList(u8)) !void {
        const c = self.next() orelse return ParseError.ErrorEOF;
        _ = self.next() orelse return ParseError.ErrorEOF;
        switch (c) {
            'u' => try self.parseUnicode(4, output),
            'U' => try self.parseUnicode(8, output),
            'b' => try output.append(self.gpa, 0x08),
            'f' => try output.append(self.gpa, 0x0c),
            't' => try output.append(self.gpa, '\t'),
            'n' => try output.append(self.gpa, '\n'),
            'r' => try output.append(self.gpa, '\r'),
            '\"' => try output.append(self.gpa, '\"'),
            '\\' => try output.append(self.gpa, '\\'),
            '\r', '\n', ' ', '\t' => {
                if (multiline) {
                    try self.expectSkipBackslash(c == ' ');
                } else {
                    return ParseError.InvalidChar;
                }
            },
            else => return ParseError.InvalidEscapeValue,
        }
    }

    fn parseUnicode(self: *Parser, size: u8, output: *std.ArrayList(u8)) !void {
        if (self.index + size > self.content.len) return ParseError.ErrorEOF;
        const cp = std.fmt.parseInt(
            u21,
            self.content[self.index .. self.index + size],
            16,
        ) catch return ParseError.InvalidUnicode;
        for (0..size) |_| self.advance();
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, buf[0..]) catch
            return ParseError.InvalidUnicode;
        try output.appendSlice(self.gpa, buf[0..len]);
    }

    fn parseArray(self: *Parser) !std.ArrayList(toml.TomlValue) {
        var array = try std.ArrayList(toml.TomlValue).initCapacity(self.gpa, 5);
        errdefer toml.deinitTomlArray(&array, self.gpa);
        self.advance();
        try self.skipWhileChar();
        while (self.current()) |c| {
            if (c == ']') {
                self.advance();
                return array;
            }
            const value = try self.parseValue();
            try array.append(self.gpa, value);
            try self.skipWhileChar();
            if (self.current() == ',') {
                self.advance();
                try self.skipWhileChar();
            }
        }
        return ParseError.ErrorEOF;
    }

    fn parseArrayOfTables(
        self: *Parser,
        root: *toml.TomlTable,
        key_parts: []const []const u8,
    ) anyerror!void {
        var array = try root.getOrCreateArray(key_parts, self.gpa);
        var table_toml = toml.TomlValue{
            .table = toml.TomlTable.init(.array_t, .explicit),
        };
        {
            errdefer table_toml.deinit(self.gpa);
            try self.parseTable(&table_toml.table);
        }
        try array.append(self.gpa, table_toml);

        if ((self.current() orelse return) == '[') {
            if (try self.tryPeek() == '[') return;
            const array_key = self.peekUntil("]") orelse return ParseError.ErrorEOF;
            const parts = try types.splitDottedKey(array_key[1..], self.gpa);
            defer self.gpa.free(parts);
            if (std.mem.eql(u8, key_parts[0], parts[0])) {
                if (parts.len == 1 and key_parts.len == 1) return ParseError.KeyValueTypeOverride;
                for (0..array_key.len + 1) |_| self.advance();
                var nested_n: u8 = 0;
                const table = blk: {
                    if (parts.len == 1) {
                        break :blk try root.getOrCreateTable(
                            parts,
                            .array_t,
                            .explicit,
                            self.gpa,
                        );
                    } else {
                        const last_array = try root.getLastArray(parts[0 .. parts.len - 1], &nested_n);
                        if (last_array.items.len == 0) return ParseError.ExpectedTable;
                        const last = &last_array.items[last_array.items.len - 1].table;
                        break :blk try last.getOrCreateTable(
                            parts[nested_n..],
                            .array_t,
                            .explicit,
                            self.gpa,
                        );
                    }
                };
                try self.parseTable(table);
            }
        }
    }

    fn parseInlineTable(self: *Parser) !toml.TomlTable {
        var table = toml.TomlTable.initInline();
        errdefer table.deinit(self.gpa);
        var comma = false;
        self.advance();
        self.skipWhitespace();
        while (self.current()) |c| {
            if (c == '}') {
                if (comma) return ParseError.TrailingComma;
                self.advance();
                return table;
            }
            const kv = try self.parseKeyValue();
            try table.addKeyValue(kv, self.gpa);
            self.skipWhitespace();
            if (self.current() == ',') {
                comma = true;
                self.advance();
                self.skipWhitespace();
            } else {
                comma = false;
            }
        }
        return ParseError.ErrorEOF;
    }

    fn parseScalar(self: *Parser) !toml.TomlValue {
        const start = self.index;
        _ = self.advanceUntilAny("#,]}\n");
        const str = std.mem.trim(u8, self.content[start..self.index], " \t");
        if (types.interpretInt(str)) |x| {
            return toml.TomlValue{ .int = x };
        } else if (types.interpretFloat(str)) |x| {
            return toml.TomlValue{ .float = x };
        } else if (types.interpretBool(str)) |x| {
            return toml.TomlValue{ .bool = x };
        } else if (try types.interpretDateTime(str)) |x| {
            return toml.TomlValue{ .datetime = x };
        } else if (try types.interpretDate(str)) |x| {
            return toml.TomlValue{ .date = x };
        } else if (try types.interpretTime(str)) |x| {
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

    fn advanceUntilAny(self: *Parser, chars: []const u8) bool {
        while (self.current()) |c| {
            if (contains(chars, c)) return true;
            self.advance();
        }
        return false;
    }

    fn advanceUntilDelim(self: *Parser, delim: []const u8) bool {
        while (self.current()) |_| {
            if (self.startsWith(delim)) return true;
            self.advance();
        }
        return false;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.index + prefix.len > self.content.len) return false;
        return std.mem.eql(u8, self.content[self.index .. self.index + prefix.len], prefix);
    }

    fn skipUTF8Bom(self: *Parser) void {
        if (self.index != 0) return;
        if (self.content.len < 3) return;
        if (self.content[0] == 0xEF and
            self.content[1] == 0xBB and
            self.content[2] == 0xBF)
        {
            self.index = 3;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.current()) |c| {
            if (types.isWhitespace(c)) {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skipLine(self: *Parser) !void {
        var in_comment = false;
        while (self.current()) |c| {
            if (c == '\r') {
                const n = try self.tryNext();
                if (n != '\n') return ParseError.InvalidChar;
                self.advance();
                break;
            } else if (c == '\n') {
                self.advance();
                break;
            }

            if (c == '#') {
                in_comment = true;
                self.advance();
                continue;
            }

            if (in_comment) if (((c >= 0x00 and c <= 0x08) or
                (c >= 0x0A and c <= 0x1F) or c == 0x7F))
                return ParseError.InvalidChar;

            self.advance();
        }
    }

    fn expectSkipBackslash(self: *Parser, expect_newline: bool) !void {
        var newline = false;
        while (self.current()) |c| {
            if (c == '\n') {
                try self.skipLine();
                newline = true;
                continue;
            } else if (!types.isWhitespace(c)) {
                if (!newline and expect_newline) return ParseError.InvalidChar;
                return;
            }
            self.advance();
        }
    }

    fn expectSkipLine(self: *Parser) !void {
        while (self.current()) |c| {
            if (c == '\n' or c == '\r' or c == '#') {
                return try self.skipLine();
            }
            if (!types.isWhitespace(c)) return ParseError.InlineDefinition;
            self.advance();
        }
    }

    fn skipWhileChar(self: *Parser) !void {
        try self.skipCommentsAndWhitespace();
        const c = self.current();
        if (c == '\n' or c == '\r' or c == '#') {
            try self.skipCommentsAndWhitespace();
            try self.skipWhileChar();
        }
    }

    fn skipCommentsAndWhitespace(self: *Parser) !void {
        self.skipWhitespace();
        while (self.current()) |c| {
            if (c == '\n' or c == '\r' or c == '#') {
                try self.skipLine();
            } else {
                break;
            }
        }
        self.skipWhitespace();
    }

    fn next(self: *Parser) ?u8 {
        if (self.index + 1 >= self.content.len) return null;
        self.index += 1;
        return self.content[self.index];
    }

    fn tryNext(self: *Parser) !u8 {
        return self.next() orelse ParseError.ErrorEOF;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.index < self.content.len - 1) self.content[self.index + 1] else null;
    }

    fn tryPeek(self: *Parser) !u8 {
        return self.peek() orelse ParseError.ErrorEOF;
    }

    fn peekN(self: *Parser, n: usize) ?[]const u8 {
        if (self.index + 1 + n > self.content.len) return null;
        return self.content[self.index + 1 .. self.index + 1 + n];
    }

    fn peekUntil(self: *Parser, str: []const u8) ?[]const u8 {
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

    fn lookBehind(self: *Parser, n: usize) ?[]const u8 {
        if (self.index - n < 0) return null;
        return self.content[self.index - n .. self.index];
    }
};

fn contains(str: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, str, c) != null;
}
