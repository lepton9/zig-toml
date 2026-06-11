const std = @import("std");
const types = @import("types.zig");
const tab = @import("table.zig");
const encode = @import("encode.zig");
pub const TomlHashMap = tab.TomlHashMap;
pub const TomlTable = tab.TomlTable;
pub const TomlArray = std.ArrayList(TomlValue);

pub fn deinitTomlArray(array: *TomlArray, allocator: std.mem.Allocator) void {
    for (array.items) |*item| {
        item.deinit(allocator);
    }
    array.deinit(allocator);
}

pub const Toml = struct {
    table: TomlValue,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Toml {
        const t = try allocator.create(Toml);
        t.* = .{
            .table = .{ .table = TomlTable.init(.root, .explicit) },
            .alloc = allocator,
        };
        return t;
    }

    pub fn deinit(self: *Toml) void {
        self.table.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Get the root TomlTable.
    pub fn getTable(self: *Toml) *TomlTable {
        return &self.table.table;
    }

    /// Convert the parsed Toml to JSON string.
    pub fn toJson(self: *const Toml) ![]const u8 {
        return try self.table.toJson(self.alloc);
    }

    /// Convert the parsed Toml to TOML string.
    pub fn toToml(self: *Toml) ![]const u8 {
        return try self.table.toToml(self.alloc);
    }

    pub fn toJsonWithTypes(self: *const Toml) ![]const u8 {
        return try self.table.toJsonWithTypes(self.alloc);
    }
};

pub const TomlValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    date: types.Date,
    time: types.Time,
    datetime: types.DateTime,
    array: TomlArray,
    table: TomlTable,

    pub fn deinit(self: *TomlValue, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |str| alloc.free(str),
            .array => |*array| deinitTomlArray(array, alloc),
            .table => |*table| table.deinit(alloc),
            else => {},
        }
    }

    pub fn get(self: *const TomlValue, key: []const u8) ?TomlValue {
        if (self.* == TomlValue.table) {
            return self.table.get(key);
        }
        return null;
    }

    pub fn getPtr(self: *const TomlValue, key: []const u8) ?*TomlValue {
        if (self.* == TomlValue.table) {
            return self.table.getPtr(key);
        }
        return null;
    }

    pub fn getEntry(
        self: *const TomlValue,
        key: []const u8,
    ) ?TomlHashMap.Entry {
        if (self.* == TomlValue.table) {
            return self.table.getEntry(key);
        }
        return null;
    }

    pub fn put(
        self: *TomlValue,
        key: []const u8,
        value: TomlValue,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.* == TomlValue.table) {
            return self.table.put(key, value, allocator);
        }
        return error.NotATable;
    }

    pub fn toToml(self: *TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var toml_str = try encode.TomlEncoder.init(allocator);
        errdefer toml_str.deinit();
        try toml_str.toToml(self, null);
        return toml_str.toOwned();
    }

    pub fn toJson(self: *const TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var json = try encode.JsonEncoder.init(allocator, false);
        errdefer json.deinit();
        var indent: usize = 0;
        try json.toJson(self, &indent);
        return json.toOwned();
    }

    pub fn toJsonWithTypes(self: *const TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var json = try encode.JsonEncoder.init(allocator, true);
        errdefer json.deinit();
        var indent: usize = 0;
        try json.toJson(self, &indent);
        return json.toOwned();
    }
};
