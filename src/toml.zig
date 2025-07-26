const std = @import("std");

pub const TomlValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    array: std.ArrayList(TomlValue),
    table: std.StringHashMap(TomlValue),

    pub fn init_table(allocator: std.mem.Allocator) TomlValue {
        const table = TomlValue{ .table = std.StringHashMap(TomlValue).init(allocator) };
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
                }
                table.deinit();
            },
            else => {},
        }
    }

    pub fn get(self: *TomlValue, key: []const u8) ?TomlValue {
        if (self.* == TomlValue.table) {
            return self.table.get(key);
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
    }
};

pub const Toml = struct {
    table: TomlValue,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Toml {
        const t = try allocator.create(Toml);
        t.* = .{ .table = TomlValue.init_table(allocator), .allocator = allocator };
        return t;
    }

    pub fn deinit(self: *Toml) void {
        self.table.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
