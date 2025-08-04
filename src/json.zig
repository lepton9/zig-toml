const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const Json = struct {
    content: std.ArrayList(u8),
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Json {
        const json = try allocator.create(Json);
        json.* = .{
            .content = std.ArrayList(u8).init(allocator),
            .buffer = undefined,
            .allocator = allocator,
        };
        return json;
    }

    pub fn deinit(self: *Json) void {
        self.content.deinit();
        self.allocator.destroy(self);
    }

    pub fn to_owned(self: *Json) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice();
    }

    pub fn jsonify(json: *Json, value: *const toml.TomlValue, indent: *usize) anyerror!void {
        switch (value.*) {
            .string => |v| try json.string_to_json(&v),
            .int => |v| try json.int_to_json(&v),
            .float => |v| try json.float_to_json(&v),
            .bool => |v| try json.bool_to_json(&v),
            .date => |v| try json.date_to_json(&v),
            .time => |v| try json.time_to_json(&v),
            .datetime => |v| try json.datetime_to_json(&v),
            .array => |v| try json.array_to_json(&v, indent),
            .table => |v| try json.table_to_json(&v, indent),
        }
    }

    pub fn string_to_json(json: *Json, value: *const []const u8) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "\"{s}\"", .{value.*}));
    }

    pub fn int_to_json(json: *Json, value: *const i64) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    pub fn float_to_json(json: *Json, value: *const f64) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    pub fn bool_to_json(json: *Json, value: *const bool) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    pub fn date_to_json(json: *Json, value: *const types.Date) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(
            &json.buffer,
            "{:0>4}-{:0>2}-{:0>2}",
            .{ value.year, value.month, value.day },
        ));
    }

    pub fn time_to_json(json: *Json, value: *const types.Time) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{:0>2}:{:0>2}:{:0>2}.{}", .{
            value.hour,
            value.minute,
            value.second,
            value.nanosecond,
        }));
    }

    pub fn datetime_to_json(json: *Json, value: *const types.DateTime) !void {
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}", .{
            value.date.year,
            value.date.month,
            value.date.day,
            value.time.hour,
            value.time.minute,
            value.time.second,
            value.time.nanosecond,
        }));
    }

    pub fn array_to_json(json: *Json, value: *const toml.TomlArray, indent: *usize) !void {
        try json.content.append('[');
        for (value.items, 0..) |*e, i| {
            try json.jsonify(e, indent);
            if (i < value.items.len - 1) {
                try json.content.appendSlice(", ");
            }
        }
        try json.content.append(']');
    }

    pub fn table_to_json(json: *Json, value: *const toml.TomlTable, indent: *usize) !void {
        try json.content.appendSlice("{\n");
        var it = value.iterator();
        const n = value.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            indent.* += 2;
            for (0..indent.*) |_| try json.content.append(' ');
            try json.content.appendSlice(
                try std.fmt.bufPrint(&json.buffer, "\"{s}\": ", .{e.key_ptr.*}),
            );
            try json.jsonify(e.value_ptr, indent);
            indent.* -= 2;
            if (i < n - 1) {
                i += 1;
                try json.content.append(',');
            }
            try json.content.append('\n');
        }
        for (0..indent.*) |_| try json.content.append(' ');
        try json.content.append('}');
    }
};
