const std = @import("std");

pub const TypeError = error{
    InvalidYear,
    InvalidMonth,
    InvalidDay,
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidNanoSecond,
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
    try validate_date(d);
    return d;
}

pub fn interpret_time(str: []const u8) !?Time {
    if (str.len < 8 or str[2] != ':' or str[5] != ':') return null;
    var t: Time = .{
        .hour = std.fmt.parseInt(u5, str[0..2], 10) catch return TypeError.InvalidHour,
        .minute = std.fmt.parseInt(u6, str[3..5], 10) catch return TypeError.InvalidMinute,
        .second = std.fmt.parseInt(u6, str[6..8], 10) catch return TypeError.InvalidSecond,
    };
    if (str.len > 8) {
        if (str[8] != '.' or str.len > 18) return TypeError.InvalidNanoSecond;
        const fraction = std.fmt.parseInt(u30, str[9..], 10) catch return TypeError.InvalidNanoSecond;
        t.nanosecond = @truncate(fraction * (1000000000 / std.math.pow(u64, 10, str.len - 9)));
    }
    try validate_time(t);
    return t;
}

fn validate_date(date: Date) TypeError!void {
    if (date.month > 12 or date.month == 0) return TypeError.InvalidMonth;
    if (date.day > 31 or date.day == 0) return TypeError.InvalidDay;
}

fn validate_time(time: Time) TypeError!void {
    if (time.hour > 23) return TypeError.InvalidHour;
    if (time.minute > 59) return TypeError.InvalidMinute;
    if (time.second > 59) return TypeError.InvalidSecond;
}
