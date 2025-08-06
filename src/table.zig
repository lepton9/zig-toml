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
};

const TableOrigin = enum {
    implicit,
    explicit,
};

pub const TomlTable = struct {
    table: std.StringHashMap(toml.TomlValue),
    origin: TableOrigin,
    is_inline: bool = false,

    pub fn init(allocator: std.mem.Allocator, origin: TableOrigin) TomlTable {
        return .{
            .table = std.StringHashMap(toml.TomlValue).init(allocator),
            .origin = origin,
        };
    }

    pub fn init_inline(allocator: std.mem.Allocator) TomlTable {
        var table = init(allocator, .explicit);
        table.is_inline = true;
        return table;
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

    pub fn create_table(
        root: *TomlTable,
        key_parts: []const []const u8,
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
                if (i == key_parts.len - 1 and current.origin == .explicit)
                    return TableError.TableRedefinition;
                current.origin = .explicit;
                if (current.is_inline) return TableError.ImmutableInlineTable;
            } else {
                const k = try allocator.dupe(u8, key);
                const e = try current.table.getOrPut(k);
                e.value_ptr.* = toml.TomlValue{ .table = TomlTable.init(
                    allocator,
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
                if (current.is_inline) return TableError.ImmutableInlineTable;
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
                const new_table = TomlTable.init(allocator, .implicit);
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
            .implicit,
            alloc,
        );
        const entry = try current.table.getOrPut(key);
        if (entry.found_existing) {
            if (entry.value_ptr.* != .table)
                return TableError.DuplicateKeyValuePair;
            if (entry.value_ptr.table.is_inline)
                return TableError.ImmutableInlineTable;
        }
        entry.value_ptr.* = value;
        entry.key_ptr.* = key;
    }
};
