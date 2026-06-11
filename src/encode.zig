const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

/// Encode TOML values to `std.json.Value`.
pub fn tomlValueToJsonValue(
    allocator: std.mem.Allocator,
    value: *const toml.TomlValue,
) std.mem.Allocator.Error!std.json.Value {
    return switch (value.*) {
        .string => |s| std.json.Value{ .string = s },
        .int => |i| std.json.Value{ .integer = i },
        .float => |f| std.json.Value{ .float = f },
        .bool => |b| std.json.Value{ .bool = b },
        .date => |d| std.json.Value{ .string = try formatDate(allocator, d) },
        .time => |t| std.json.Value{ .string = try formatTime(allocator, t) },
        .datetime => |dt| std.json.Value{ .string = try formatDateTime(allocator, dt) },
        .array => |*a| blk: {
            var arr = try std.json.Array.initCapacity(allocator, a.items.len);
            for (a.items) |*item| {
                arr.appendAssumeCapacity(try tomlValueToJsonValue(allocator, item));
            }
            break :blk std.json.Value{ .array = arr };
        },
        .table => |*t| try tomlTableToJsonValue(allocator, t),
    };
}

pub fn tomlTableToJsonValue(
    allocator: std.mem.Allocator,
    table: *const toml.TomlTable,
) std.mem.Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);

    var it = table.table.iterator();
    while (it.next()) |entry| {
        const v = try tomlValueToJsonValue(allocator, entry.value_ptr);
        const gop = try obj.getOrPut(allocator, entry.key_ptr.*);
        gop.value_ptr.* = v;
    }

    return std.json.Value{ .object = obj };
}

/// Format Date to a string.
fn formatDate(allocator: std.mem.Allocator, d: types.Date) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{:0>4}-{:0>2}-{:0>2}",
        .{ d.year, d.month, d.day },
    );
}

/// Format Time to a string.
fn formatTime(allocator: std.mem.Allocator, t: types.Time) ![]const u8 {
    if (t.nanosecond == 0) {
        return try std.fmt.allocPrint(
            allocator,
            "{:0>2}:{:0>2}:{:0>2}",
            .{ t.hour, t.minute, t.second },
        );
    }

    var ns_buf: [16]u8 = undefined;
    const ns = std.fmt.bufPrint(&ns_buf, "{:0>9}", .{t.nanosecond}) catch unreachable;
    var end: usize = ns.len;
    while (end > 0 and ns[end - 1] == '0') end -= 1;

    return try std.fmt.allocPrint(
        allocator,
        "{:0>2}:{:0>2}:{:0>2}.{s}",
        .{ t.hour, t.minute, t.second, ns[0..end] },
    );
}

/// Format DateTime to a string.
fn formatDateTime(allocator: std.mem.Allocator, dt: types.DateTime) ![]const u8 {
    const d = dt.date;
    const t = dt.time;

    // Format fractional seconds without allocating an intermediate string.
    var frac_buf: [16]u8 = undefined;
    var frac: []const u8 = "";
    if (t.nanosecond != 0) {
        var ns_buf: [16]u8 = undefined;
        const ns_9 = std.fmt.bufPrint(&ns_buf, "{:0>9}", .{t.nanosecond}) catch unreachable;
        var end: usize = ns_9.len;
        while (end > 0 and ns_9[end - 1] == '0') end -= 1;
        frac_buf[0] = '.';
        @memcpy(frac_buf[1 .. 1 + end], ns_9[0..end]);
        frac = frac_buf[0 .. 1 + end];
    }

    if (dt.offset_minutes == null) {
        return try std.fmt.allocPrint(
            allocator,
            "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}{s}",
            .{ d.year, d.month, d.day, t.hour, t.minute, t.second, frac },
        );
    }

    const offset = dt.offset_minutes.?;
    if (offset == 0) {
        return try std.fmt.allocPrint(
            allocator,
            "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}{s}Z",
            .{ d.year, d.month, d.day, t.hour, t.minute, t.second, frac },
        );
    }

    const abs_off: i16 = @intCast(@abs(offset));
    const hours: u5 = @intCast(@divTrunc(abs_off, 60));
    const minutes: u6 = @intCast(@mod(abs_off, 60));
    const sign: u8 = if (offset >= 0) '+' else '-';

    return try std.fmt.allocPrint(
        allocator,
        "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}{s}{c}{:0>2}:{:0>2}",
        .{ d.year, d.month, d.day, t.hour, t.minute, t.second, frac, sign, hours, minutes },
    );
}

/// TODO: Deprecated
pub const JsonEncoder = struct {
    content: std.ArrayList(u8),
    type_info: bool,
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    const default_indent = 4;

    pub fn init(allocator: std.mem.Allocator, type_info: bool) !*JsonEncoder {
        const json = try allocator.create(JsonEncoder);
        json.* = .{
            .content = .empty,
            .type_info = type_info,
            .buffer = undefined,
            .allocator = allocator,
        };
        return json;
    }

    pub fn deinit(self: *JsonEncoder) void {
        self.content.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn toOwned(self: *JsonEncoder) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice(self.allocator);
    }

    pub fn toJson(json: *JsonEncoder, value: *const toml.TomlValue, indent: *usize) anyerror!void {
        switch (value.*) {
            .string => |v| try json.stringToJson(&v),
            .int => |v| try json.intToJson(&v),
            .float => |v| try json.floatToJson(&v),
            .bool => |v| try json.boolToJson(&v),
            .date => |v| try json.dateToJson(&v),
            .time => |v| try json.timeToJson(&v),
            .datetime => |v| try json.datetimeToJson(&v),
            .array => |v| try json.arrayToJson(&v, indent),
            .table => |v| try json.tableToJson(&v, indent),
        }
    }

    fn stringToJson(json: *JsonEncoder, value: *const []const u8) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"string\", \"value\": \"{s}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(&json.buffer, "\"{s}\"", .{value.*}));
    }

    fn intToJson(json: *JsonEncoder, value: *const i64) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"integer\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn floatToJson(json: *JsonEncoder, value: *const f64) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"float\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn boolToJson(json: *JsonEncoder, value: *const bool) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"bool\", \"value\": \"{}\"}}",
                .{value.*},
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(&json.buffer, "{}", .{value.*}));
    }

    fn dateToJson(json: *JsonEncoder, value: *const types.Date) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"date-local\", \"value\": \"{:0>4}-{:0>2}-{:0>2}\"}}",
                .{ value.year, value.month, value.day },
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
            &json.buffer,
            "{:0>4}-{:0>2}-{:0>2}",
            .{ value.year, value.month, value.day },
        ));
    }

    fn timeToJson(json: *JsonEncoder, value: *const types.Time) !void {
        if (json.type_info) {
            return try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
                &json.buffer,
                "{{\"type\": \"time-local\", \"value\": \"{:0>2}:{:0>2}:{:0>2}.{}\"}}",
                .{ value.hour, value.minute, value.second, value.nanosecond },
            ));
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
            &json.buffer,
            "{:0>2}:{:0>2}:{:0>2}.{}",
            .{ value.hour, value.minute, value.second, value.nanosecond },
        ));
    }

    fn datetimeToJson(json: *JsonEncoder, value: *const types.DateTime) !void {
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
            return try json.content.appendSlice(json.allocator, datetime);
        }
        try json.content.appendSlice(json.allocator, try std.fmt.bufPrint(
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

    fn arrayToJson(json: *JsonEncoder, value: *const toml.TomlArray, indent: *usize) !void {
        try json.content.append(json.allocator, '[');
        for (value.items, 0..) |*e, i| {
            try json.toJson(e, indent);
            if (i < value.items.len - 1) {
                try json.content.appendSlice(json.allocator, ", ");
            }
        }
        try json.content.append(json.allocator, ']');
    }

    fn tableToJson(json: *JsonEncoder, value: *const toml.TomlTable, indent: *usize) !void {
        try json.content.append(json.allocator, '{');
        var it = value.table.iterator();
        const n = value.table.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            var key = e.key_ptr.*;
            try json.content.append(json.allocator, '\n');
            indent.* += JsonEncoder.default_indent;
            for (0..indent.*) |_| try json.content.append(json.allocator, ' ');
            if (json.type_info and types.isQuoted(key) and key.len > 2) {
                key = std.mem.trim(u8, key[1 .. key.len - 1], " \t");
            }
            try json.content.appendSlice(
                json.allocator,
                try std.fmt.bufPrint(&json.buffer, "\"{s}\": ", .{key}),
            );
            try json.toJson(e.value_ptr, indent);
            indent.* -= JsonEncoder.default_indent;
            if (i < n - 1) {
                i += 1;
                try json.content.append(json.allocator, ',');
            } else {
                try json.content.append(json.allocator, '\n');
                for (0..indent.*) |_| try json.content.append(json.allocator, ' ');
            }
        }
        try json.content.append(json.allocator, '}');
    }
};

pub const TomlEncoder = struct {
    content: std.ArrayList(u8),
    buffer: [256]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*TomlEncoder {
        const encoder = try allocator.create(TomlEncoder);
        encoder.* = .{
            .content = try std.ArrayList(u8).initCapacity(allocator, 1024),
            .buffer = undefined,
            .allocator = allocator,
        };
        return encoder;
    }

    pub fn deinit(self: *TomlEncoder) void {
        self.content.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Allocate the converted TOML string.
    pub fn toOwned(self: *TomlEncoder) ![]const u8 {
        defer self.allocator.destroy(self);
        return try self.content.toOwnedSlice(self.allocator);
    }

    /// Convert the TomlValue to TOML string.
    pub fn toToml(
        encoder: *TomlEncoder,
        value: *toml.TomlValue,
        header: ?[]const u8,
    ) anyerror!void {
        switch (value.*) {
            .string => |*v| try encoder.stringToToml(v, header),
            .int => |*v| try encoder.intToToml(v, header),
            .float => |*v| try encoder.floatToToml(v, header),
            .bool => |*v| try encoder.boolToToml(v, header),
            .date => |*v| try encoder.dateToToml(v, header),
            .time => |*v| try encoder.timeToToml(v, header),
            .datetime => |*v| try encoder.datetimeToToml(v, header),
            .array => |*v| try encoder.arrayToToml(v, header),
            .table => |*v| {
                switch (v.t_type) {
                    .inline_t => try encoder.inlineTableToToml(v, header),
                    .dotted_t => try encoder.dottedTableToToml(v, header),
                    else => try encoder.headerTableToToml(v, header),
                }
            },
        }
    }

    fn stringToToml(encoder: *TomlEncoder, value: *const []const u8, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = \"{s}\"", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "\"{s}\"", .{value.*});
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn intToToml(encoder: *TomlEncoder, value: *const i64, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn floatToToml(encoder: *TomlEncoder, value: *const f64, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn boolToToml(encoder: *TomlEncoder, value: *const bool, header: ?[]const u8) !void {
        const key = if (header) |h|
            try std.fmt.bufPrint(&encoder.buffer, "{s} = {}", .{ h, value.* })
        else
            try std.fmt.bufPrint(&encoder.buffer, "{}", .{value.*});
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn dateToToml(encoder: *TomlEncoder, value: *const types.Date, header: ?[]const u8) !void {
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
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn timeToToml(encoder: *TomlEncoder, value: *const types.Time, header: ?[]const u8) !void {
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
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn datetimeToToml(encoder: *TomlEncoder, value: *const types.DateTime, header: ?[]const u8) !void {
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
        return try encoder.content.appendSlice(encoder.allocator, key);
    }

    fn arrayToToml(encoder: *TomlEncoder, value: *toml.TomlArray, header: ?[]const u8) !void {
        if (header) |h| {
            try encoder.content.appendSlice(
                encoder.allocator,
                try std.fmt.bufPrint(&encoder.buffer, "{s} = ", .{h}),
            );
        }
        try encoder.content.append(encoder.allocator, '[');
        for (value.items, 0..) |*e, i| {
            try encoder.toToml(e, null);
            if (i < value.items.len - 1) {
                try encoder.content.appendSlice(encoder.allocator, ", ");
            }
        }
        try encoder.content.append(encoder.allocator, ']');
    }

    fn dottedTableToToml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = try std.ArrayList(u8).initCapacity(encoder.allocator, 5);
        defer header.deinit(encoder.allocator);
        if (root_key) |rk| try header.appendSlice(encoder.allocator, rk);
        var it = value.table.iterator();
        var i: usize = 0;
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (e.value_ptr.* != .table) {
                var var_key = try header.clone(encoder.allocator);
                try var_key.append(encoder.allocator, '.');
                try var_key.appendSlice(encoder.allocator, key);
                defer var_key.deinit(encoder.allocator);
                try encoder.toToml(e.value_ptr, var_key.items);
                if (i < value.table.count() - 1) try encoder.content.append(encoder.allocator, '\n');
                i += 1;
            } else {
                try header.append(encoder.allocator, '.');
                try header.appendSlice(encoder.allocator, key);
                try encoder.toToml(e.value_ptr, header.items);
            }
        }
    }

    fn inlineTableToToml(encoder: *TomlEncoder, value: *const toml.TomlTable, root_key: ?[]const u8) !void {
        if (root_key) |k| {
            try encoder.content.appendSlice(
                encoder.allocator,
                try std.fmt.bufPrint(&encoder.buffer, "{s} = ", .{k}),
            );
        }
        try encoder.content.append(encoder.allocator, '{');
        var it = value.table.iterator();
        const n = value.table.count();
        var i: u32 = 0;
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            try encoder.toToml(e.value_ptr, key);
            if (i < n - 1) {
                i += 1;
                try encoder.content.appendSlice(encoder.allocator, ", ");
            }
        }
        try encoder.content.append(encoder.allocator, '}');
    }

    fn arrayTableToToml(encoder: *TomlEncoder, value: *toml.TomlArray, header: ?[]const u8) !void {
        for (value.items) |*table| {
            try encoder.content.appendSlice(encoder.allocator, try std.fmt.bufPrint(
                &encoder.buffer,
                "\n[[{s}]]\n",
                .{header.?},
            ));
            try encoder.toToml(table, null);
        }
    }

    fn headerTableToToml(encoder: *TomlEncoder, value: *toml.TomlTable, root_key: ?[]const u8) !void {
        var header = try std.ArrayList(u8).initCapacity(encoder.allocator, 5);
        defer header.deinit(encoder.allocator);
        if (root_key) |rk| {
            try header.appendSlice(encoder.allocator, rk);
            try header.append(encoder.allocator, '.');
        }

        var it = value.table.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            var val = e.value_ptr;
            switch (val.*) {
                .table => {
                    switch (val.table.t_type) {
                        .header_t => {
                            try header.appendSlice(encoder.allocator, key);
                            if (val.table.origin == .implicit) {
                                try encoder.toToml(val, header.items);
                                header.clearAndFree(encoder.allocator);
                                continue;
                            }
                            try encoder.content.appendSlice(encoder.allocator, try std.fmt.bufPrint(
                                &encoder.buffer,
                                "\n[{s}]\n",
                                .{header.items},
                            ));
                            try encoder.toToml(val, header.items);
                            header.shrinkAndFree(encoder.allocator, header.items.len - key.len);
                        },
                        .array_t => {
                            try header.appendSlice(encoder.allocator, key);
                            try encoder.toToml(val, header.items);
                            header.shrinkAndFree(encoder.allocator, header.items.len - key.len);
                        },
                        else => {
                            try encoder.toToml(val, key);
                            try encoder.content.append(encoder.allocator, '\n');
                        },
                    }
                },
                .array => {
                    if (val.array.items.len > 0 and
                        val.array.items[0] == .table and
                        val.array.items[0].table.t_type == .array_t)
                    {
                        try header.appendSlice(encoder.allocator, key);
                        try encoder.arrayTableToToml(&val.array, header.items);
                        header.shrinkAndFree(encoder.allocator, header.items.len - key.len);
                        continue;
                    }
                    try encoder.toToml(val, key);
                    try encoder.content.append(encoder.allocator, '\n');
                },
                else => {
                    try encoder.toToml(val, key);
                    try encoder.content.append(encoder.allocator, '\n');
                },
            }
        }
    }
};
