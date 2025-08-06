const std = @import("std");
const types = @import("types.zig");
const Json = @import("json.zig").Json;

pub const TomlTable = @import("table.zig").TomlTable;
pub const TomlArray = std.ArrayList(TomlValue);

pub fn deinit_array(array: *TomlArray, allocator: std.mem.Allocator) void {
    for (array.items) |*item| {
        item.deinit(allocator);
    }
    array.deinit();
}

pub const Toml = struct {
    table: TomlValue,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Toml {
        const t = try allocator.create(Toml);
        t.* = .{
            .table = .{ .table = TomlTable.init(allocator, .root, .explicit) },
            .alloc = allocator,
        };
        return t;
    }

    pub fn deinit(self: *Toml) void {
        self.table.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn get_table(self: *Toml) TomlTable {
        return self.table.table;
    }

    pub fn to_json(self: *const Toml) ![]const u8 {
        return try self.table.to_json(self.alloc);
    }

    pub fn to_json_with_types(self: *const Toml) ![]const u8 {
        return try self.table.to_json_with_types(self.alloc);
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
            .array => |*array| deinit_array(array, alloc),
            .table => |*table| table.deinit(alloc),
            else => {},
        }
    }

    pub fn get(self: *const TomlValue, key: []const u8) ?TomlValue {
        if (self.* == TomlValue.table) {
            return self.table.get(types.interpret_key(key) catch return null);
        }
        return null;
    }

    pub fn to_json(self: *const TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var json = try Json.init(allocator, false);
        errdefer json.deinit();
        var indent: usize = 0;
        try json.jsonify(self, &indent);
        return json.to_owned();
    }

    pub fn to_json_with_types(self: *const TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var json = try Json.init(allocator, true);
        errdefer json.deinit();
        var indent: usize = 0;
        try json.jsonify(self, &indent);
        return json.to_owned();
    }
};
