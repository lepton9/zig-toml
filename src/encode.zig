const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const Encoder = struct {
    content: std.ArrayList(u8),
    type_info: bool,
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, type_info: bool) !*Encoder {
        const encoder = try allocator.create(Encoder);
        encoder.* = .{
            .content = std.ArrayList(u8).init(allocator),
            .type_info = type_info,
            .buffer = undefined,
            .allocator = allocator,
        };
        return encoder;
    }

    pub fn deinit(self: *Encoder) void {
        self.content.deinit();
        self.allocator.destroy(self);
    }

    pub fn to_owned(self: *Encoder) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice();
    }

    pub fn to_toml(encoder: *Encoder, value: *const toml.TomlValue, header: ?[]const u8) anyerror!void {
        switch (value.*) {
            .string => |v| try encoder.string_to_toml(&v),
            .int => |v| try encoder.int_to_toml(&v),
            .float => |v| try encoder.float_to_toml(&v),
            .bool => |v| try encoder.bool_to_toml(&v),
            .date => |v| try encoder.date_to_toml(&v),
            .time => |v| try encoder.time_to_toml(&v),
            .datetime => |v| try encoder.datetime_to_toml(&v),
            .array => |v| try encoder.array_to_toml(&v),
            .table => |v| {
                switch (v.t_type) {
                    .inline_t => try encoder.inline_table_to_toml(&v),
                    else => try encoder.table_to_toml(&v, header),
                }
            },
        }
    }

    pub fn string_to_toml(encoder: *Encoder, value: *const []const u8) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "\"{s}\"",
            .{value.*},
        ));
    }

    pub fn int_to_toml(encoder: *Encoder, value: *const i64) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    pub fn float_to_toml(encoder: *Encoder, value: *const f64) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    pub fn bool_to_toml(encoder: *Encoder, value: *const bool) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    pub fn date_to_toml(encoder: *Encoder, value: *const types.Date) !void {
        try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{:0>4}-{:0>2}-{:0>2}",
            .{ value.year, value.month, value.day },
        ));
    }

    pub fn time_to_toml(encoder: *Encoder, value: *const types.Time) !void {
        try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{:0>2}:{:0>2}:{:0>2}.{}",
            .{ value.hour, value.minute, value.second, value.nanosecond },
        ));
    }

    pub fn datetime_to_toml(encoder: *Encoder, value: *const types.DateTime) !void {
        try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}",
            .{
                value.date.year,
                value.date.month,
                value.date.day,
                value.time.hour,
                value.time.minute,
                value.time.second,
                value.time.nanosecond,
            },
        ));
    }

    pub fn array_to_toml(encoder: *Encoder, value: *const toml.TomlArray) !void {
        var regular_array: bool = true;
        if (value.items.len > 0 and
            value.items[0] == .table and
            value.items[0].table.t_type == .array_t)
        {
            regular_array = false;
        }
        if (regular_array) try encoder.content.append('[');
        for (value.items, 0..) |*e, i| {
            try encoder.to_toml(e, null);
            if (i < value.items.len - 1) {
                if (regular_array) try encoder.content.appendSlice(", ");
            }
        }
        if (regular_array) try encoder.content.append(']');
    }

    pub fn inline_table_to_toml(encoder: *Encoder, value: *const toml.TomlTable) !void {
        try encoder.content.append('{');
        var it = value.table.iterator();
        const n = value.table.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            try encoder.content.appendSlice(
                try std.fmt.bufPrint(&encoder.buffer, "{s} = ", .{key}),
            );
            try encoder.to_toml(e.value_ptr, null);
            if (i < n - 1) {
                i += 1;
                try encoder.content.append(',');
            }
        }
        try encoder.content.append('}');
    }

    pub fn table_to_toml(encoder: *Encoder, value: *const toml.TomlTable, root_key: ?[]const u8) !void {
        var header = std.ArrayList(u8).init(encoder.allocator);
        defer header.deinit();
        var it = value.table.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            try encoder.content.append('\n');
            const key_str = blk: {
                switch (e.value_ptr.*) {
                    .table => {
                        switch (e.value_ptr.table.t_type) {
                            .header_t, .dotted_t => {
                                if (root_key) |rk| {
                                    try header.appendSlice(rk);
                                    try header.append('.');
                                }
                            },
                            else => {},
                        }
                        try header.appendSlice(key);
                        switch (e.value_ptr.table.t_type) {
                            .header_t => {
                                break :blk try std.fmt.bufPrint(
                                    &encoder.buffer,
                                    "[{s}]",
                                    .{header.items},
                                );
                            },
                            else => {
                                break :blk try std.fmt.bufPrint(
                                    &encoder.buffer,
                                    "{s} = ",
                                    .{header.items},
                                );
                            },
                        }
                    },
                    .array => {
                        if (e.value_ptr.array.items.len > 0 and
                            e.value_ptr.array.items[0] == .table and
                            e.value_ptr.array.items[0].table.t_type == .array_t)
                        {
                            if (root_key) |rk| {
                                break :blk try std.fmt.bufPrint(
                                    &encoder.buffer,
                                    "[[{s}.{s}]]",
                                    .{ rk, key },
                                );
                            }
                            break :blk try std.fmt.bufPrint(
                                &encoder.buffer,
                                "[[{s}]]",
                                .{key},
                            );
                        } else {
                            break :blk try std.fmt.bufPrint(
                                &encoder.buffer,
                                "{s} = ",
                                .{key},
                            );
                        }
                    },
                    else => {
                        break :blk try std.fmt.bufPrint(
                            &encoder.buffer,
                            "{s} = ",
                            .{key},
                        );
                    },
                }
            };

            const header_slice = try header.toOwnedSlice();
            defer encoder.allocator.free(header_slice);
            try encoder.content.appendSlice(key_str);
            try encoder.to_toml(e.value_ptr, header_slice);
        }
    }
};
