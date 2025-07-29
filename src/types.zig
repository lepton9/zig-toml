const std = @import("std");

pub const TypeError = error{
    InvalidYear,
    InvalidMonth,
    InvalidDay,
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidNanoSecond,
    InvalidTimeOffset,
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

pub fn interpret_time_offset(str: []const u8) !i16 {
    if (str.len < 6 or str[3] != ':') return TypeError.InvalidTimeOffset;
    const hour = std.fmt.parseInt(i16, str[0..3], 10) catch return TypeError.InvalidTimeOffset;
    const minutes = std.fmt.parseInt(i16, str[4..], 10) catch return TypeError.InvalidTimeOffset;
    if (hour > 11 or hour < -11 or minutes > 59) return TypeError.InvalidTimeOffset;
    return hour * 60 + std.math.sign(hour) * minutes;
}

pub fn interpret_datetime(str: []const u8) !?DateTime {
    if (str.len < 19 or (str[10] != 'T' and str[10] != ' ')) return null;
    const time_start = 11;
    const time_end = time_start + (std.mem.indexOf(u8, str[time_start..], "Z") orelse
        std.mem.indexOf(u8, str[time_start..], "+") orelse
        std.mem.indexOf(u8, str[time_start..], "-") orelse
        str.len - time_start);
    const offset = if (time_end == str.len or str[time_end] == 'Z')
        null
    else
        try interpret_time_offset(str[time_end..]);
    const dt: DateTime = .{
        .date = try interpret_date(str[0..10]) orelse return null,
        .time = try interpret_time(str[time_start..time_end]) orelse return null,
        .offset_minutes = offset,
    };
    try validate_date(dt.date);
    try validate_time(dt.time);
    return dt;
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
