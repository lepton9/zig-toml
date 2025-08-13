const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const JsonEncoder = struct {
    content: std.ArrayList(u8),
    type_info: bool,
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, type_info: bool) !*JsonEncoder {
        const json = try allocator.create(JsonEncoder);
        json.* = .{
            .content = std.ArrayList(u8).init(allocator),
            .type_info = type_info,
            .buffer = undefined,
            .allocator = allocator,
        };
        return json;
    }

    pub fn deinit(self: *JsonEncoder) void {
        self.content.deinit();
        self.allocator.destroy(self);
    }

    pub fn to_owned(self: *JsonEncoder) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice();
    }

    pub fn to_json(json: *JsonEncoder, value: *const toml.TomlValue, indent: *usize) anyerror!void {
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

    fn string_to_json(json: *JsonEncoder, value: *const []const u8) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"string\", \"value\": \"{s}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "\"{s}\"", .{value.*}));
    }

    fn int_to_json(json: *JsonEncoder, value: *const i64) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"integer\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn float_to_json(json: *JsonEncoder, value: *const f64) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"float\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn bool_to_json(json: *JsonEncoder, value: *const bool) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"bool\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn date_to_json(json: *JsonEncoder, value: *const types.Date) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"date-local\", \"value\": \"{:0>4}-{:0>2}-{:0>2}\"}}",
                .{ value.year, value.month, value.day },
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(
            &json.buffer,
            "{:0>4}-{:0>2}-{:0>2}",
            .{ value.year, value.month, value.day },
        ));
    }

    fn time_to_json(json: *JsonEncoder, value: *const types.Time) !void {
        if (json.type_info) {
            return try json.content.appendSlice(try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"time-local\", \"value\": \"{:0>2}:{:0>2}:{:0>2}.{}\"}}",
                .{ value.hour, value.minute, value.second, value.nanosecond },
            ));
        }
        try json.content.appendSlice(try std.fmt.bufPrint(
            &json.buffer,
            "{:0>2}:{:0>2}:{:0>2}.{}",
            .{ value.hour, value.minute, value.second, value.nanosecond },
        ));
    }

    fn datetime_to_json(json: *JsonEncoder, value: *const types.DateTime) !void {
        if (json.type_info) {
            var datetime: []u8 = undefined;
            if (value.offset_minutes) |offset| {
                var buf: [64]u8 = undefined;
                const hours: u5 = @intCast(@divTrunc(@abs(offset), 60));
                const minutes: u6 = @intCast(@mod(@abs(offset), 60));
                const offset_str = if (offset >= 0)
                    try std.fmt.bufPrint(&buf, "+{:0>2}:{:0>2}", .{ hours, minutes })
                else
                    try std.fmt.bufPrint(&buf, "-{:0>2}:{:0>2}", .{ hours, minutes });
                datetime = try std.fmt.bufPrint(
                    &json.buffer,
                    "{{\"type\": \"datetime\", \"value\": \"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}{s}\"}}",
                    .{
                        value.date.year,
                        value.date.month,
                        value.date.day,
                        value.time.hour,
                        value.time.minute,
                        value.time.second,
                        value.time.nanosecond,
                        offset_str,
                    },
                );
            } else {
                datetime = try std.fmt.bufPrint(
                    &json.buffer,
                    "{{\"type\": \"datetime-local\", \"value\": \"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}\"}}",
                    .{
                        value.date.year,
                        value.date.month,
                        value.date.day,
                        value.time.hour,
                        value.time.minute,
                        value.time.second,
                        value.time.nanosecond,
                    },
                );
            }
            return try json.content.appendSlice(datetime);
        }
        try json.content.appendSlice(try std.fmt.bufPrint(
            &json.buffer,
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

    fn array_to_json(json: *JsonEncoder, value: *const toml.TomlArray, indent: *usize) !void {
        try json.content.append('[');
        for (value.items, 0..) |*e, i| {
            try json.to_json(e, indent);
            if (i < value.items.len - 1) {
                try json.content.appendSlice(", ");
            }
        }
        try json.content.append(']');
    }

    fn table_to_json(json: *JsonEncoder, value: *const toml.TomlTable, indent: *usize) !void {
        try json.content.append('{');
        var it = value.table.iterator();
        const n = value.table.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            var key = e.key_ptr.*;
            try json.content.append('\n');
            indent.* += 2;
            for (0..indent.*) |_| try json.content.append(' ');
            if (json.type_info and types.is_quoted(key) and key.len > 2) {
                key = std.mem.trim(u8, key[1 .. key.len - 1], " \t");
            }
            try json.content.appendSlice(
                try std.fmt.bufPrint(&json.buffer, "\"{s}\": ", .{key}),
            );
            try json.to_json(e.value_ptr, indent);
            indent.* -= 2;
            if (i < n - 1) {
                i += 1;
                try json.content.append(',');
            } else {
                try json.content.append('\n');
                for (0..indent.*) |_| try json.content.append(' ');
            }
        }
        try json.content.append('}');
    }
};

pub const TomlEncoder = struct {
    content: std.ArrayList(u8),
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*TomlEncoder {
        const encoder = try allocator.create(TomlEncoder);
        encoder.* = .{
            .content = std.ArrayList(u8).init(allocator),
            .buffer = undefined,
            .allocator = allocator,
        };
        return encoder;
    }

    pub fn deinit(self: *TomlEncoder) void {
        self.content.deinit();
        self.allocator.destroy(self);
    }

    pub fn to_owned(self: *TomlEncoder) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice();
    }

    pub fn to_toml(encoder: *TomlEncoder, value: *toml.TomlValue, header: ?[]const u8) anyerror!void {
        switch (value.*) {
            .string => |v| try encoder.string_to_toml(&v),
            .int => |v| try encoder.int_to_toml(&v),
            .float => |v| try encoder.float_to_toml(&v),
            .bool => |v| try encoder.bool_to_toml(&v),
            .date => |v| try encoder.date_to_toml(&v),
            .time => |v| try encoder.time_to_toml(&v),
            .datetime => |v| try encoder.datetime_to_toml(&v),
            .array => |v| try encoder.array_to_toml(&v),
            .table => |*v| {
                switch (v.t_type) {
                    .inline_t => try encoder.inline_table_to_toml(v),
                    .dotted_t => try encoder.dotted_table_to_toml(v, header),
                    else => try encoder.table_to_toml(v, header),
                }
            },
        }
    }

    fn string_to_toml(encoder: *TomlEncoder, value: *const []const u8) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "\"{s}\"",
            .{value.*},
        ));
    }

    fn int_to_toml(encoder: *TomlEncoder, value: *const i64) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    fn float_to_toml(encoder: *TomlEncoder, value: *const f64) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    fn bool_to_toml(encoder: *TomlEncoder, value: *const bool) !void {
        return try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{}",
            .{value.*},
        ));
    }

    fn date_to_toml(encoder: *TomlEncoder, value: *const types.Date) !void {
        try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{:0>4}-{:0>2}-{:0>2}",
            .{ value.year, value.month, value.day },
        ));
    }

    fn time_to_toml(encoder: *TomlEncoder, value: *const types.Time) !void {
        try encoder.content.appendSlice(try std.fmt.bufPrint(
            &encoder.buffer,
            "{:0>2}:{:0>2}:{:0>2}.{}",
            .{ value.hour, value.minute, value.second, value.nanosecond },
        ));
    }

    fn datetime_to_toml(encoder: *TomlEncoder, value: *const types.DateTime) !void {
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

    fn array_to_toml(encoder: *TomlEncoder, value: *const toml.TomlArray) !void {
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

    fn dotted_table_to_toml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = std.ArrayList(u8).init(encoder.allocator);
        defer header.deinit();
        if (root_key) |rk| try header.appendSlice(rk);
        var it = value.table.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (e.value_ptr.* != .table) {
                try encoder.content.appendSlice(
                    try std.fmt.bufPrint(&encoder.buffer, "{s}.{s} = ", .{ header.items, key }),
                );
                try encoder.to_toml(e.value_ptr, null);
                try encoder.content.append('\n');
            } else {
                try header.append('.');
                try header.appendSlice(key);
                try encoder.to_toml(e.value_ptr, header.items);
            }
        }
    }

    fn inline_table_to_toml(encoder: *TomlEncoder, value: *const toml.TomlTable) !void {
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

    fn sort_table(toml_table: *toml.TomlTable) void {
        const sort_ctx = struct {
            values: []toml.TomlValue,
            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return (ctx.values[a_index] != .table or (ctx.values[a_index].table.t_type != .header_t)) and
                    (ctx.values[b_index] == .table and ctx.values[b_index].table.t_type == .header_t);
            }
        };
        var table = &toml_table.table;
        table.sort(sort_ctx{ .values = table.values() });
    }

    fn table_to_toml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = std.ArrayList(u8).init(encoder.allocator);
        defer header.deinit();
        sort_table(value);

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
                            // TODO:
                            .dotted_t => {
                                break :blk "";
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
