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
            .string => |*v| try encoder.string_to_toml(v, header),
            .int => |*v| try encoder.int_to_toml(v, header),
            .float => |*v| try encoder.float_to_toml(v, header),
            .bool => |*v| try encoder.bool_to_toml(v, header),
            .date => |*v| try encoder.date_to_toml(v, header),
            .time => |*v| try encoder.time_to_toml(v, header),
            .datetime => |*v| try encoder.datetime_to_toml(v, header),
            .array => |*v| try encoder.array_to_toml(v, header),
            .table => |*v| {
                switch (v.t_type) {
                    .inline_t => try encoder.inline_table_to_toml(v, header),
                    .dotted_t => try encoder.dotted_table_to_toml(v, header),
                    else => try encoder.header_table_to_toml(v, header),
                }
            },
        }
    }

    fn string_to_toml(encoder: *TomlEncoder, value: *const []const u8, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = \"{s}\"", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "\"{s}\"", .{value.*});
        return try encoder.content.appendSlice(key);
    }

    fn int_to_toml(encoder: *TomlEncoder, value: *const i64, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(key);
    }

    fn float_to_toml(encoder: *TomlEncoder, value: *const f64, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(key);
    }

    fn bool_to_toml(encoder: *TomlEncoder, value: *const bool, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(key);
    }

    fn date_to_toml(encoder: *TomlEncoder, value: *const types.Date, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(
                &encoder.buffer,
                "{s} = {:0>4}-{:0>2}-{:0>2}",
                .{ h, value.year, value.month, value.day },
            )
        else
            try std.fmt.bufPrint(
                &encoder.buffer,
                "{:0>4}-{:0>2}-{:0>2}",
                .{ value.year, value.month, value.day },
            );
        return try encoder.content.appendSlice(key);
    }

    fn time_to_toml(encoder: *TomlEncoder, value: *const types.Time, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(
                &encoder.buffer,
                "{s} = {:0>2}:{:0>2}:{:0>2}.{}",
                .{ h, value.hour, value.minute, value.second, value.nanosecond },
            )
        else
            try std.fmt.bufPrint(
                &encoder.buffer,
                "{:0>2}:{:0>2}:{:0>2}.{}",
                .{ value.hour, value.minute, value.second, value.nanosecond },
            );
        return try encoder.content.appendSlice(key);
    }

    fn datetime_to_toml(encoder: *TomlEncoder, value: *const types.DateTime, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(
                &encoder.buffer,
                "{s} = {:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{}",
                .{
                    h,
                    value.date.year,
                    value.date.month,
                    value.date.day,
                    value.time.hour,
                    value.time.minute,
                    value.time.second,
                    value.time.nanosecond,
                },
            )
        else
            try std.fmt.bufPrint(
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
            );
        return try encoder.content.appendSlice(key);
    }

    fn array_to_toml(encoder: *TomlEncoder, value: *toml.TomlArray, header: ?[]const u8) !void {
        if (header) |h| {
            try encoder.content.appendSlice(
                try std.fmt.bufPrint(&encoder.buffer, "{s} = ", .{h}),
            );
        }
        try encoder.content.append('[');
        for (value.items, 0..) |*e, i| {
            try encoder.to_toml(e, null);
            if (i < value.items.len - 1) {
                try encoder.content.appendSlice(", ");
            }
        }
        try encoder.content.append(']');
    }

    fn dotted_table_to_toml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = std.ArrayList(u8).init(encoder.allocator);
        defer header.deinit();
        if (root_key) |rk| try header.appendSlice(rk);
        var it = value.table.iterator();
        var i: usize = 0;
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (e.value_ptr.* != .table) {
                var var_key = try header.clone();
                try var_key.append('.');
                try var_key.appendSlice(key);
                defer var_key.deinit();
                try encoder.to_toml(e.value_ptr, var_key.items);
                if (i < value.table.count() - 1) try encoder.content.append('\n');
                i += 1;
            } else {
                try header.append('.');
                try header.appendSlice(key);
                try encoder.to_toml(e.value_ptr, header.items);
            }
        }
    }

    fn inline_table_to_toml(encoder: *TomlEncoder, value: *const toml.TomlTable, root_key: ?[]const u8) !void {
        if (root_key) |k| {
            try encoder.content.appendSlice(
                try std.fmt.bufPrint(&encoder.buffer, "{s} = ", .{k}),
            );
        }
        try encoder.content.append('{');
        var it = value.table.iterator();
        const n = value.table.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            try encoder.to_toml(e.value_ptr, key);
            if (i < n - 1) {
                i += 1;
                try encoder.content.appendSlice(", ");
            }
        }
        try encoder.content.append('}');
    }

    fn array_table_to_toml(encoder: *TomlEncoder, value: *toml.TomlArray, header: ?[]const u8) !void {
        for (value.items) |*table| {
            try encoder.content.appendSlice(try std.fmt.bufPrint(
                &encoder.buffer,
                "\n[[{s}]]\n",
                .{header.?},
            ));
            try encoder.to_toml(table, null);
        }
    }

    fn header_table_to_toml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = std.ArrayList(u8).init(encoder.allocator);
        defer header.deinit();
        if (root_key) |rk| {
            try header.appendSlice(rk);
            try header.append('.');
        }

        var it = value.table.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            var val = e.value_ptr;
            switch (val.*) {
                .table => {
                    switch (val.table.t_type) {
                        .header_t => {
                            try header.appendSlice(key);
                            if (val.table.origin == .implicit) {
                                try encoder.to_toml(val, header.items);
                                header.clearAndFree();
                                continue;
                            }
                            try encoder.content.appendSlice(try std.fmt.bufPrint(
                                &encoder.buffer,
                                "\n[{s}]\n",
                                .{header.items},
                            ));
                            try encoder.to_toml(val, header.items);
                            header.shrinkAndFree(header.items.len - key.len);
                        },
                        .array_t => {
                            try header.appendSlice(key);
                            try encoder.to_toml(val, header.items);
                            header.shrinkAndFree(header.items.len - key.len);
                        },
                        else => {
                            try encoder.to_toml(val, key);
                            try encoder.content.append('\n');
                        },
                    }
                },
                .array => {
                    if (val.array.items.len > 0 and
                        val.array.items[0] == .table and
                        val.array.items[0].table.t_type == .array_t)
                    {
                        try header.appendSlice(key);
                        try encoder.array_table_to_toml(&val.array, header.items);
                        header.shrinkAndFree(header.items.len - key.len);
                        continue;
                    }
                    try encoder.to_toml(val, key);
                    try encoder.content.append('\n');
                },
                else => {
                    try encoder.to_toml(val, key);
                    try encoder.content.append('\n');
                },
            }
        }
    }
};
