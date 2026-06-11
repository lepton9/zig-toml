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

pub const TableOrigin = enum {
    implicit,
    explicit,
};

pub const TableType = enum {
    root,
    header_t,
    array_t,
    inline_t,
    dotted_t,
};

pub const TomlHashMap = std.StringArrayHashMapUnmanaged(toml.TomlValue);

pub const TomlTable = struct {
    table: TomlHashMap,
    t_type: TableType,
    origin: TableOrigin,

    pub fn init(t_type: TableType, origin: TableOrigin) TomlTable {
        return .{ .table = .{}, .t_type = t_type, .origin = origin };
    }

    pub fn initInline() TomlTable {
        return init(.inline_t, .explicit);
    }

    pub fn deinit(self: *TomlTable, gpa: std.mem.Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(gpa);
            gpa.free(e.key_ptr.*);
        }
        self.table.deinit(gpa);
    }

    pub fn get(self: *const TomlTable, key: []const u8) ?toml.TomlValue {
        return self.table.get(types.interpretKey(key) catch return null);
    }

    pub fn getPtr(self: *const TomlTable, key: []const u8) ?*toml.TomlValue {
        return self.table.getPtr(types.interpretKey(key) catch return null);
    }

    pub fn getEntry(
        self: *const TomlTable,
        key: []const u8,
    ) ?TomlHashMap.Entry {
        return self.table.getEntry(types.interpretKey(key) catch return null);
    }

    pub fn put(
        self: *TomlTable,
        key: []const u8,
        value: toml.TomlValue,
        allocator: std.mem.Allocator,
    ) !void {
        const parts = try types.splitDottedKey(key, allocator);
        const key_value: KeyValue = .{ .key_parts = parts, .value = value };
        try self.addKeyValueOrder(key_value, allocator);
    }

    pub fn putTable(
        self: *TomlTable,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) !void {
        const parts = try types.splitDottedKey(key, allocator);
        defer allocator.free(parts);
        _ = try self.createTable(parts, .header_t, allocator);
    }

    pub fn createTable(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = types.interpretKeyAlloc(allocator, part) catch |err| switch (err) {
                types.TypeError.InvalidKey,
                types.TypeError.InvalidEscape,
                types.TypeError.InvalidUnicode,
                => return TableError.InvalidTableHeader,
                else => return err,
            };
            const entry = current.table.getEntry(key);
            if (entry) |e| {
                allocator.free(key);
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
                // `key` becomes owned by the map.
                const e = try current.table.getOrPut(allocator, key);
                e.value_ptr.* = toml.TomlValue{ .table = TomlTable.init(
                    table_type,
                    if (i == key_parts.len - 1) .explicit else .implicit,
                ) };
                e.key_ptr.* = key;
                current = &e.value_ptr.table;
            }
        }
        return current;
    }

    pub fn getOrCreateTable(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        origin_of_last: TableOrigin,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = try types.interpretKeyAlloc(allocator, part);
            const entry = try current.table.getOrPut(allocator, key);
            if (!entry.found_existing) {
                const sub_table = toml.TomlValue{ .table = TomlTable.init(
                    table_type,
                    if (i == key_parts.len - 1) origin_of_last else .implicit,
                ) };
                entry.value_ptr.* = sub_table;
                entry.key_ptr.* = key;
                current = &entry.value_ptr.table;
            } else if (entry.value_ptr.* != .table) {
                allocator.free(key);
                return TableError.InvalidTableNesting;
            } else {
                allocator.free(key);
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

    pub fn getLastArray(
        root: *TomlTable,
        key_parts: []const []const u8,
        nested_n: *u8,
    ) anyerror!*toml.TomlArray {
        nested_n.* = 0;
        var current = root;
        var last_array: ?*toml.TomlArray = null;
        for (key_parts[0..key_parts.len]) |part| {
            const key = try types.interpretKey(part);
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

    pub fn getOrCreateArray(
        root: *TomlTable,
        key_parts: []const []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!*toml.TomlArray {
        var current = root;
        for (key_parts[0 .. key_parts.len - 1]) |part| {
            const key = try types.interpretKeyAlloc(allocator, part);
            if (current.table.getEntry(key)) |entry| {
                allocator.free(key);
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
                // `key` becomes owned by the map.
                const new_table = TomlTable.init(.array_t, .implicit);
                try putKeepOrder(&current.table, key, toml.TomlValue{ .table = new_table }, allocator);
                current = &current.table.getEntry(key).?.value_ptr.table;
            }
        }
        const final_key = key_parts[key_parts.len - 1];
        const final = try types.interpretKeyAlloc(allocator, final_key);
        if (current.table.getEntry(final)) |entry| {
            allocator.free(final);
            if (entry.value_ptr.* != .array) return TableError.ExpectedArray;
            if (entry.value_ptr.array.items.len == 0) return TableError.ExpectedArrayOfTables;
            for (entry.value_ptr.array.items) |elem| {
                if (elem != .table) return TableError.ExpectedArrayOfTables;
            }
            return &entry.value_ptr.array;
        } else {
            const array = try toml.TomlArray.initCapacity(allocator, 5);
            // `final` becomes owned by the map.
            try putKeepOrder(&current.table, final, toml.TomlValue{ .array = array }, allocator);
            return &current.table.getEntry(final).?.value_ptr.array;
        }
    }

    pub fn addKeyValue(root: *TomlTable, key_value: KeyValue, alloc: std.mem.Allocator) !void {
        defer alloc.free(key_value.key_parts);
        var value = key_value.value;
        errdefer value.deinit(alloc);
        const key = try types.interpretKeyAlloc(
            alloc,
            key_value.key_parts[key_value.key_parts.len - 1],
        );
        errdefer alloc.free(key);
        var current = try root.getOrCreateTable(
            key_value.key_parts[0 .. key_value.key_parts.len - 1],
            .dotted_t,
            .implicit,
            alloc,
        );
        const entry = try current.table.getOrPut(alloc, key);
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

    fn addKeyValueOrder(
        root: *TomlTable,
        key_value: KeyValue,
        alloc: std.mem.Allocator,
    ) !void {
        defer alloc.free(key_value.key_parts);
        var value = key_value.value;
        errdefer value.deinit(alloc);
        const key = try types.interpretKeyAlloc(
            alloc,
            key_value.key_parts[key_value.key_parts.len - 1],
        );
        errdefer alloc.free(key);
        var current = try root.getOrCreateTableOrder(
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
        try putKeepOrder(&current.table, key, value, alloc);
        current.origin = .explicit;
    }

    fn getOrCreateTableOrder(
        root: *TomlTable,
        key_parts: []const []const u8,
        table_type: TableType,
        origin_of_last: TableOrigin,
        allocator: std.mem.Allocator,
    ) !*TomlTable {
        var current = root;
        for (key_parts, 0..) |part, i| {
            const key = try types.interpretKeyAlloc(allocator, part);
            const existing = current.table.getPtr(key);
            if (existing) |exist| {
                allocator.free(key);
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
                    table_type,
                    if (i == key_parts.len - 1) origin_of_last else .implicit,
                ) };
                // `key` becomes owned by the map.
                try putKeepOrder(&current.table, key, sub_table, allocator);
                current = &current.table.getPtr(key).?.table;
            }
        }
        return current;
    }
};

fn putKeepOrder(
    table: *TomlHashMap,
    key: []const u8,
    value: toml.TomlValue,
    alloc: std.mem.Allocator,
) !void {
    if (value == .table and (value.table.t_type == .header_t or value.table.t_type == .array_t)) {
        try table.put(alloc, key, value);
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
            try table.put(alloc, key, value)
        else
            try insertAt(table, i, key, value, alloc);
    }
}

fn insertAt(
    table: *TomlHashMap,
    index: usize,
    key: []const u8,
    value: toml.TomlValue,
    alloc: std.mem.Allocator,
) !void {
    try table.entries.insert(alloc, index, .{
        .hash = std.array_hash_map.hashString(key),
        .key = key,
        .value = value,
    });
    try table.reIndexContext(alloc, .{});
}
