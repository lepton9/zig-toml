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
        var json = std.ArrayList(u8).init(allocator);
        errdefer json.deinit();
        var indent: usize = 0;
        try self.jsonify(&json, &indent);
        return json.toOwnedSlice();
    }

    fn jsonify(self: *const TomlValue, json: *std.ArrayList(u8), indent: *usize) !void {
        var buffer: [256]u8 = undefined;
        switch (self.*) {
            .string => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "\"{s}\"", .{v})),
            .int => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{v})),
            .float => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{v})),
            .bool => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{v})),
            .date => |v| try json.appendSlice(try std.fmt.bufPrint(
                &buffer,
                "{:0>4}-{:0>2}-{:0>2}",
                .{ v.year, v.month, v.day },
            )),
            .time => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "{:0>2}:{:0>2}:{:0>2}.{}", .{
                v.hour,
                v.minute,
                v.second,
                v.nanosecond,
            })),
            .datetime => |v| try json.appendSlice(try std.fmt.bufPrint(&buffer, "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}", .{
                v.date.year,
                v.date.month,
                v.date.day,
                v.time.hour,
                v.time.minute,
                v.time.second,
                v.time.nanosecond,
            })),
            .array => |ar| {
                try json.append('[');
                for (ar.items, 0..) |e, i| {
                    try e.jsonify(json, indent);
                    if (i < ar.items.len - 1) {
                        try json.appendSlice(", ");
                    }
                }
                try json.append(']');
            },
            .table => |tab| {
                try json.appendSlice("{\n");
                var it = tab.iterator();
                const n = tab.count();
                var i: u32 = 0;
                while (it.next()) |e| {
                    indent.* += 2;
                    for (0..indent.*) |_| try json.append(' ');
                    try json.appendSlice(
                        try std.fmt.bufPrint(&buffer, "\"{s}\": ", .{e.key_ptr.*}),
                    );
                    try e.value_ptr.jsonify(json, indent);
                    indent.* -= 2;
                    if (i < n - 1) {
                        i += 1;
                        try json.append(',');
                    }
                    try json.append('\n');
                }
                for (0..indent.*) |_| try json.append(' ');
                try json.append('}');
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
        return self.table.table;
    }
};
