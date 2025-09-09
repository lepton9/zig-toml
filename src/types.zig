const std = @import("std");

pub const TypeError = error{
    InvalidKey,
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

pub fn interpret_key(str: []const u8) ![]const u8 {
    var key = std.mem.trim(u8, str, " \t");
    if (is_quoted(key)) {
        const unquoted = std.mem.trim(u8, key[1 .. key.len - 1], " \t");
        const can_remove = unquoted.len > 0 and all(unquoted, valid_key_char);
        return if (can_remove) unquoted else key;
    } else {
        if (key.len > 0 and all(key, valid_key_char)) return key;
        return TypeError.InvalidKey;
    }
}

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
    if (hour > 23 or hour < -23 or minutes > 59) return TypeError.InvalidTimeOffset;
    return hour * 60 + std.math.sign(hour) * minutes;
}

pub fn interpret_datetime(str: []const u8) !?DateTime {
    if (str.len < 19 or (str[10] != 'T' and str[10] != 't' and str[10] != ' ')) return null;
    const time_start = 11;
    const index_z: ?usize = std.mem.indexOfAny(u8, str[time_start..], "Zz");
    const time_end = time_start + (index_z orelse
        std.mem.indexOfAny(u8, str[time_start..], "+-") orelse
        str.len - time_start);
    const offset = if (time_end == str.len)
        null
    else if (index_z) |_| 0 else try interpret_time_offset(str[time_end..]);
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

fn is_leap_year(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn validate_date(date: Date) TypeError!void {
    if (date.month > 12 or date.month == 0) return TypeError.InvalidMonth;
    const days_in_month = [_]u5{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max_days = days_in_month[date.month - 1];
    if (date.month == 2 and is_leap_year(date.year)) {
        max_days = 29;
    }
    if (date.day == 0 or date.day > max_days) return TypeError.InvalidDay;
}

fn validate_time(time: Time) TypeError!void {
    if (time.hour > 23) return TypeError.InvalidHour;
    if (time.minute > 59) return TypeError.InvalidMinute;
    if (time.second > 59) return TypeError.InvalidSecond;
}

pub fn is_quoted(s: []const u8) bool {
    return (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\'')));
}

fn valid_key_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn all(str: []const u8, func: fn (u8) bool) bool {
    for (str) |c| if (!func(c)) return false;
    return true;
}

pub fn is_quote(c: u8) bool {
    return c == '"' or c == '\'';
}

pub fn is_whitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn handle_quote(quote: *?u8, c: u8) void {
    if (quote.* == null) {
        quote.* = c;
    } else if (quote.* == c) {
        quote.* = null;
    }
}

fn last_indexof_qa(str: []const u8, char: u8) ?usize {
    var quote: ?u8 = null;
    for (0..str.len) |i| {
        const c = str[str.len - 1 - i];
        if (is_quote(c)) {
            handle_quote(&quote, c);
        } else if (c == char and quote == null) {
            return str.len - 1 - i;
        }
    }
    return null;
}

fn indexof_qa(str: []const u8, char: u8) ?usize {
    var quote: ?u8 = null;
    for (str, 0..) |c, i| {
        if (is_quote(c)) {
            handle_quote(&quote, c);
        } else if (c == char and quote == null) {
            return i;
        }
    }
    return null;
}

fn split_quote_aware(
    str: []const u8,
    delim: u8,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    var parts = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    var start: usize = 0;
    while (indexof_qa(str[start..], delim)) |ind| {
        const part = str[start .. start + ind];
        try parts.append(allocator, std.mem.trim(u8, part, " \t"));
        start += ind + 1;
    }
    if (start < str.len) {
        try parts.append(allocator, std.mem.trim(u8, str[start..], " \t"));
    }
    return try parts.toOwnedSlice(allocator);
}

pub fn split_dotted_key(
    str: []const u8,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    return try split_quote_aware(str, '.', allocator);
}
