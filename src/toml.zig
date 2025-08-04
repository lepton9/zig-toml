const std = @import("std");
const types = @import("types.zig");
const Json = @import("json.zig").Json;

pub const TomlTable = std.StringHashMap(TomlValue);
pub const TomlArray = std.ArrayList(TomlValue);

pub const Toml = struct {
    table: TomlValue,
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Toml {
        const t = try allocator.create(Toml);
        t.* = .{ .table = TomlValue.init_table(allocator), .alloc = allocator };
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

    pub fn init_table(allocator: std.mem.Allocator) TomlValue {
        const table = TomlValue{ .table = TomlTable.init(allocator) };
        return table;
    }

    pub fn deinit(self: *TomlValue, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |str| alloc.free(str),
            .array => |*ar| {
                for (ar.items) |*item| {
                    item.deinit(alloc);
                }
                ar.deinit();
            },
            .table => |*table| {
                var it = table.iterator();
                while (it.next()) |e| {
                    e.value_ptr.deinit(alloc);
                    alloc.free(e.key_ptr.*);
                }
                table.deinit();
            },
            else => {},
        }
    }

    pub fn get(self: *const TomlValue, key: []const u8) ?TomlValue {
        if (self.* == TomlValue.table) {
            return self.table.get(types.interpret_key(key) catch return null);
        }
        return null;
    }

    pub fn get_or(self: *TomlValue, key: []const u8, default: type) type {
        const val = self.get(key);
        if (val) |v| {
            return v.value();
        }
        return default;
    }

    pub fn value(self: *TomlValue) type {
        return switch (self.*) {
            .int => self.int,
            .float => self.float,
            .bool => self.bool,
            .string => self.string,
            .array => self.array,
            .table => self.table,
        };

    pub fn to_json(self: *const TomlValue, allocator: std.mem.Allocator) ![]const u8 {
        var json = try Json.init(allocator);
        errdefer json.deinit();
        var indent: usize = 0;
        try json.jsonify(self, &indent);
        return json.to_owned();
    }
};
