const std = @import("std");
const types = @import("types.zig");

pub const TomlTable = std.StringHashMap(TomlValue);

pub const TomlValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    date: types.Date,
    time: types.Time,
    datetime: types.DateTime,
    array: std.ArrayList(TomlValue),
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

    pub fn print(self: *const TomlValue) void {
        switch (self.*) {
            .string => |v| std.debug.print("\"{s}\"", .{v}),
            .int => |v| std.debug.print("{}", .{v}),
            .float => |v| std.debug.print("{}", .{v}),
            .bool => |v| std.debug.print("{}", .{v}),
            .array => |ar| {
                std.debug.print("[", .{});
                for (ar.items) |e| {
                    e.print();
                    std.debug.print(",", .{});
                }
                std.debug.print("]", .{});
            },
            .table => |tab| {
                std.debug.print("{{", .{});
                var it = tab.iterator();
                while (it.next()) |e| {
                    std.debug.print("{s}:", .{e.key_ptr.*});
                    e.value_ptr.print();
                    std.debug.print(",", .{});
                }
                std.debug.print("}}", .{});
            },
        }
    }
};

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
        return self.table.value();
    }
};
