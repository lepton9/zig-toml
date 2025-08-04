const std = @import("std");
const types = @import("types.zig");

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
        var json = std.ArrayList(u8).init(allocator);
        errdefer json.deinit();
        var indent: usize = 0;
        try self.jsonify(&json, &indent);
        return json.toOwnedSlice();
    }

    fn jsonify(self: *const TomlValue, json: *std.ArrayList(u8), indent: *usize) anyerror!void {
        switch (self.*) {
            .string => |v| try string_to_json(v, json),
            .int => |v| try int_to_json(v, json),
            .float => |v| try float_to_json(v, json),
            .bool => |v| try bool_to_json(v, json),
            .date => |v| try date_to_json(v, json),
            .time => |v| try time_to_json(v, json),
            .datetime => |v| try datetime_to_json(v, json),
            .array => |v| try array_to_json(v, json, indent),
            .table => |v| try table_to_json(v, json, indent),
        }
    }
};

fn string_to_json(value: []const u8, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "\"{s}\"", .{value}));
}

fn int_to_json(value: i64, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{value}));
}

fn float_to_json(value: f64, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{value}));
}

fn bool_to_json(value: bool, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "{}", .{value}));
}

fn date_to_json(value: types.Date, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(
        &buffer,
        "{:0>4}-{:0>2}-{:0>2}",
        .{ value.year, value.month, value.day },
    ));
}

fn time_to_json(value: types.Time, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "{:0>2}:{:0>2}:{:0>2}.{}", .{
        value.hour,
        value.minute,
        value.second,
        value.nanosecond,
    }));
}

fn datetime_to_json(value: types.DateTime, json: *std.ArrayList(u8)) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice(try std.fmt.bufPrint(&buffer, "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}", .{
        value.date.year,
        value.date.month,
        value.date.day,
        value.time.hour,
        value.time.minute,
        value.time.second,
        value.time.nanosecond,
    }));
}

fn array_to_json(value: TomlArray, json: *std.ArrayList(u8), indent: *usize) !void {
    try json.append('[');
    for (value.items, 0..) |e, i| {
        try e.jsonify(json, indent);
        if (i < value.items.len - 1) {
            try json.appendSlice(", ");
        }
    }
    try json.append(']');
}

fn table_to_json(value: TomlTable, json: *std.ArrayList(u8), indent: *usize) !void {
    var buffer: [256]u8 = undefined;
    try json.appendSlice("{\n");
    var it = value.iterator();
    const n = value.count();
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
}
