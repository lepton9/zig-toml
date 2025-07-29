const std = @import("std");

pub const TypeError = error{
    InvalidYear,
    InvalidMonth,
    InvalidDay,
};

pub const Date = struct {
    year: u16,
    month: u4,
    day: u5,
};

pub const Time = struct {
    hour: u5,
    minute: u6,
    second: u6,
    nanosecond: u30 = 0,
};

pub const DateTime = struct {
    date: Date,
    time: Time,
    offset_minutes: ?i16 = 0,
};

pub fn interpret_int(str: []const u8) ?i64 {
    return std.fmt.parseInt(i64, str, 0) catch return null;
}

pub fn interpret_float(str: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, str) catch return null;
}

pub fn interpret_bool(str: []const u8) ?bool {
    if (std.mem.eql(u8, "true", str)) return true;
    if (std.mem.eql(u8, "false", str)) return false;
    return null;
}

pub fn interpret_datetime(_: []const u8) !?DateTime {
    return null;
}

pub fn interpret_date(str: []const u8) !?Date {
    if (str.len != 10 or str[4] != '-' or str[7] != '-') return null;
    const d: Date = .{
        .year = std.fmt.parseInt(u16, str[0..4], 10) catch return TypeError.InvalidYear,
        .month = std.fmt.parseInt(u4, str[5..7], 10) catch return TypeError.InvalidMonth,
        .day = std.fmt.parseInt(u5, str[8..], 10) catch return TypeError.InvalidDay,
    };
    if (d.month > 12 or d.month == 0) return TypeError.InvalidMonth;
    if (d.day > 31 or d.day == 0) return TypeError.InvalidDay;
    return d;
}

pub fn interpret_time(_: []const u8) !?Time {
    return null;
}
