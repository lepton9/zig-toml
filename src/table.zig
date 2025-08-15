const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const KeyValue = struct {
    key_parts: []const []const u8,
    value: toml.TomlValue,
};

pub const TableError = error{
    InvalidTableNesting,
    DuplicateTableHeader,
    InvalidTableHeader,
    ImmutableInlineTable,
    DuplicateKeyValuePair,
    TableRedefinition,
    ExpectedTable,
    ExpectedArray,
    ExpectedArrayOfTables,
    KeyValueRedefinition,
};

const TableOrigin = enum {
    implicit,
    explicit,
};

const TableType = enum {
    root,
    header_t,
    array_t,
    inline_t,
    dotted_t,
};

pub const TomlHashMap = std.StringArrayHashMap(toml.TomlValue);

pub const TomlTable = struct {
    table: TomlHashMap,
    t_type: TableType,
    origin: TableOrigin,

    pub fn init(allocator: std.mem.Allocator, t_type: TableType, origin: TableOrigin) TomlTable {
        return .{
            .table = TomlHashMap.init(allocator),
            .t_type = t_type,
            .origin = origin,
        };
    }

    pub fn init_inline(allocator: std.mem.Allocator) TomlTable {
        return init(allocator, .inline_t, .explicit);
    }

    pub fn deinit(self: *TomlTable, allocator: std.mem.Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        self.table.deinit();
    }

    pub fn get(self: *const TomlTable, key: []const u8) ?toml.TomlValue {
        return self.table.get(types.interpret_key(key) catch return null);
    }

    pub fn getPtr(self: *const TomlTable, key: []const u8) ?*toml.TomlValue {
        return self.table.getPtr(types.interpret_key(key) catch return null);
    }

    pub fn getEntry(
        self: *const TomlTable,
        key: []const u8,
    ) ?TomlHashMap.Entry {
        return self.table.getEntry(types.interpret_key(key) catch return null);
    }

    pub fn put(
        self: *TomlTable,
        key: []const u8,
        value: toml.TomlValue,
        allocator: std.mem.Allocator,
    ) !void {
        const parts = try types.split_dotted_key(key, allocator);
        const key_value: KeyValue = .{ .key_parts = parts, .value = value };
        try self.add_key_value_order(key_value, allocator);
    }

    pub fn put_table(
        self: *TomlTable,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) !void {
        const parts = try types.split_dotted_key(key, allocator);
        defer allocator.free(parts);
        _ = try self.create_table(parts, .header_t, allocator);
    }

    pub fn create_table(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = types.interpret_key(part) catch
                return TableError.InvalidTableHeader;
            const entry = current.table.getEntry(key);
            if (entry) |e| {
                if (e.value_ptr.* != .table) return TableError.ExpectedTable;
                current = &e.value_ptr.table;
                if (current.t_type == .inline_t) return TableError.ImmutableInlineTable;
                if (table_type == .header_t and current.t_type != .header_t) {
                    if (!(current.t_type == .dotted_t and i < key_parts.len - 1)) {
                        return TableError.TableRedefinition;
                    }
                }
                if (i == key_parts.len - 1) {
                    if (current.origin == .explicit) return TableError.TableRedefinition;
                    current.origin = .explicit;
                }
            } else {
                const k = try allocator.dupe(u8, key);
                const e = try current.table.getOrPut(k);
                e.value_ptr.* = toml.TomlValue{ .table = TomlTable.init(
                    allocator,
                    table_type,
                    if (i == key_parts.len - 1) .explicit else .implicit,
                ) };
                e.key_ptr.* = k;
                current = &e.value_ptr.table;
            }
        }
        return current;
    }

    pub fn get_or_create_table(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        origin_of_last: TableOrigin,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = try types.interpret_key(part);
            const entry = try current.table.getOrPut(key);
            if (!entry.found_existing) {
                const sub_table = toml.TomlValue{ .table = TomlTable.init(
                    allocator,
                    table_type,
                    if (i == key_parts.len - 1) origin_of_last else .implicit,
                ) };
                entry.value_ptr.* = sub_table;
                entry.key_ptr.* = try allocator.dupe(u8, key);
                current = &entry.value_ptr.table;
            } else if (entry.value_ptr.* != .table) {
                return TableError.InvalidTableNesting;
            } else {
                current = &entry.value_ptr.table;
                if (i == key_parts.len - 1) {
                    if (current.origin == .explicit) return TableError.TableRedefinition;
                    current.origin = origin_of_last;
                }
                if (current.t_type == .header_t and table_type != .header_t)
                    return TableError.TableRedefinition;
                if (current.t_type == .inline_t) return TableError.ImmutableInlineTable;
            }
        }
        return current;
    }

    pub fn get_last_array(
        root: *TomlTable,
        key_parts: []const []const u8,
        nested_n: *u8,
    ) anyerror!*toml.TomlArray {
        nested_n.* = 0;
        var current = root;
        var last_array: ?*toml.TomlArray = null;
        for (key_parts[0..key_parts.len]) |part| {
            const key = try types.interpret_key(part);
            if (current.table.getEntry(key)) |entry| {
                if (entry.value_ptr.* == .table) {
                    current = &entry.value_ptr.table;
                    nested_n.* += 1;
                } else if (entry.value_ptr.* == .array) {
                    last_array = &entry.value_ptr.array;
                    if (last_array.?.items.len == 0) return TableError.ExpectedTable;
                    current = &last_array.?.items[last_array.?.items.len - 1].table;
                    nested_n.* += 1;
                } else break;
            } else break;
        }
        return last_array orelse TableError.ExpectedArray;
    }

    pub fn get_or_create_array(
        root: *TomlTable,
        key_parts: []const []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!*toml.TomlArray {
        var current = root;
        for (key_parts[0 .. key_parts.len - 1]) |part| {
            const key = try types.interpret_key(part);
            if (current.table.getEntry(key)) |entry| {
                if (entry.value_ptr.* == .table) {
                    current = &entry.value_ptr.table;
                } else if (entry.value_ptr.* == .array) {
                    const array: toml.TomlArray = entry.value_ptr.array;
                    if (array.items.len == 0) return TableError.ExpectedTable;
                    current = &array.items[array.items.len - 1].table;
                } else {
                    return TableError.ExpectedArray;
                }
            } else {
                const new_table = TomlTable.init(allocator, .array_t, .implicit);
                var parts = std.ArrayList([]const u8).init(allocator);
                try parts.append(key);
                try current.add_key_value(
                    .{
                        .key_parts = try parts.toOwnedSlice(),
                        .value = toml.TomlValue{ .table = new_table },
                    },
                    allocator,
                );
                current = &current.table.getEntry(key).?.value_ptr.table;
            }
        }
        const final_key = key_parts[key_parts.len - 1];
        if (current.table.getEntry(final_key)) |entry| {
            if (entry.value_ptr.* != .array) return TableError.ExpectedArray;
            if (entry.value_ptr.array.items.len == 0) return TableError.ExpectedArrayOfTables;
            for (entry.value_ptr.array.items) |elem| {
                if (elem != .table) return TableError.ExpectedArrayOfTables;
            }
            return &entry.value_ptr.array;
        } else {
            const array = toml.TomlArray.init(allocator);
            var parts = std.ArrayList([]const u8).init(allocator);
            const k = try types.interpret_key(final_key);
            try parts.append(k);
            try current.add_key_value(
                .{
                    .key_parts = try parts.toOwnedSlice(),
                    .value = toml.TomlValue{ .array = array },
                },
                allocator,
            );
            return &current.table.getEntry(k).?.value_ptr.array;
        }
    }

    pub fn add_key_value(root: *TomlTable, key_value: KeyValue, alloc: std.mem.Allocator) !void {
        defer alloc.free(key_value.key_parts);
        const key = try alloc.dupe(
            u8,
            try types.interpret_key(key_value.key_parts[key_value.key_parts.len - 1]),
        );
        var value = key_value.value;
        errdefer alloc.free(key);
        errdefer value.deinit(alloc);
        var current = try root.get_or_create_table(
            key_value.key_parts[0 .. key_value.key_parts.len - 1],
            .dotted_t,
            .implicit,
            alloc,
        );
        const entry = try current.table.getOrPut(key);
        if (entry.found_existing) {
            if (entry.value_ptr.* != .table)
                return TableError.DuplicateKeyValuePair;
            if (entry.value_ptr.table.t_type == .inline_t)
                return TableError.ImmutableInlineTable;
            return TableError.KeyValueRedefinition;
        }
        entry.value_ptr.* = value;
        entry.key_ptr.* = key;
    }

    fn add_key_value_order(root: *TomlTable, key_value: KeyValue, alloc: std.mem.Allocator) !void {
        defer alloc.free(key_value.key_parts);
        const key = try alloc.dupe(
            u8,
            try types.interpret_key(key_value.key_parts[key_value.key_parts.len - 1]),
        );
        var value = key_value.value;
        errdefer alloc.free(key);
        errdefer value.deinit(alloc);
        var current = try root.get_or_create_table_order(
            key_value.key_parts[0 .. key_value.key_parts.len - 1],
            .dotted_t,
            .implicit,
            alloc,
        );
        if (current.table.get(key)) |existing| {
            if (existing != .table)
                return TableError.DuplicateKeyValuePair;
            if (existing.table.t_type == .inline_t)
                return TableError.ImmutableInlineTable;
            return TableError.KeyValueRedefinition;
        }
        try put_keep_order(&current.table, key, value, alloc);
        current.origin = .explicit;
    }

    fn get_or_create_table_order(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        origin_of_last: TableOrigin,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = try types.interpret_key(part);
            const existing = current.table.getPtr(key);
            if (existing) |exist| {
                if (exist.* != .table) return TableError.InvalidTableNesting;
                current = &exist.table;
                if (i == key_parts.len - 1) {
                    if (origin_of_last == .explicit and current.origin == .explicit)
                        return TableError.TableRedefinition;
                    current.origin = origin_of_last;
                }
                if (current.t_type == .header_t and table_type != .header_t)
                    return TableError.TableRedefinition;
                if (current.t_type == .inline_t) return TableError.ImmutableInlineTable;
            } else {
                const sub_table = toml.TomlValue{ .table = TomlTable.init(
                    allocator,
                    table_type,
                    if (i == key_parts.len - 1) origin_of_last else .implicit,
                ) };
                const st_key = try allocator.dupe(u8, key);
                try put_keep_order(&current.table, st_key, sub_table, allocator);
                current = &current.table.getPtr(st_key).?.table;
            }
        }
        return current;
    }
};

fn put_keep_order(
    table: *TomlHashMap,
    key: []const u8,
    value: toml.TomlValue,
    alloc: std.mem.Allocator,
) !void {
    if (value == .table and (value.table.t_type == .header_t or value.table.t_type == .array_t)) {
        try table.put(key, value);
    } else {
        var it = table.iterator();
        var i: usize = 0;
        while (it.next()) |*e| {
            const val = e.value_ptr.*;
            if (val == .table and (val.table.t_type == .header_t or val.table.t_type == .array_t)) {
                break;
            }
            i += 1;
        }
        if (table.count() == 0 or i > table.count() - 1)
            try table.put(key, value)
        else
            try insert_at(table, i, key, value, alloc);
    }
}

fn insert_at(
    table: *TomlHashMap,
    index: usize,
    key: []const u8,
    value: toml.TomlValue,
    alloc: std.mem.Allocator,
) !void {
    try table.unmanaged.entries.insert(alloc, index, .{
        .hash = table.ctx.hash(key),
        .key = key,
        .value = value,
    });
    try table.reIndex();
}
