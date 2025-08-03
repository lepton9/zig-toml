const toml = @import("toml.zig");
const parser = @import("parser.zig");
const std = @import("std");

test "toml" {
    const t = try toml.Toml.init(std.testing.allocator);
    defer t.deinit();
}

test "parser" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = p.parse_file("tests/basic.toml") catch |err| {
        switch (err) {
            parser.ParseError.NotImplemented => std.log.err("Not Implemented\n", .{}),
            else => std.log.err("{}\n", .{err}),
        }
        return;
    };
    defer toml_data.deinit();
    toml_data.table.print();

test "keys" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ key = "value"
        \\ bare_key = "value"
        \\ bare-key = "value"
        \\ 1234 = "value"
        \\ "127.0.0.1" = "value"
        \\ "character encoding" = "value"
        \\ "ʎǝʞ" = "value"
        \\ 'key2' = "value"
        \\ 'quoted "value"' = "value"
        \\ "" = "blank"
        \\ '' = 'blank'
        \\ name = "Orange"
        \\ physical.color = "orange"
        \\ physical.shape = "round"
        \\ site."google.com" = true
        \\ fruit.name = "banana"
        \\ fruit. color = "yellow"
        \\ fruit . flavor = "banana"
        \\ 3.14159 = "pi"
    );
    defer toml_data.deinit();
}

test "strings" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ str = "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
        \\ str1 = "The quick brown fox jumps over the lazy dog."
        \\ str2 = """
        \\ The quick brown \
        \\ 
        \\ 
        \\   fox jumps over \
        \\     the lazy dog."""
        \\ str3 = """\
        \\        The quick brown \
        \\        fox jumps over \
        \\        the lazy dog.\
        \\        """
        \\ str4 = """Here are two quotation marks: "". Simple enough."""
        \\ str5 = """Here are three quotation marks: ""\"."""
        \\ str6 = """Here are fifteen quotation marks: ""\"""\"""\"""\"""\"."""
        \\ str7 = """"This," she said, "is just a pointless statement.""""
        \\ winpath  = 'C:\Users\nodejs\templates'
        \\ winpath2 = '\\ServerX\admin$\system32\'
        \\ quoted   = 'Tom "Dubs" Preston-Werner'
        \\ regex    = '<\i\c*\s*>'
        \\ regex2 = '''I [dw]on't need \d{2} apples'''
        \\ lines  = '''
        \\ The first newline is
        \\ trimmed in raw strings.
        \\    All other whitespace
        \\    is preserved.
        \\ '''
        \\ quot15 = '''Here are fifteen quotation marks: """""""""""""""'''
        \\ apos15 = "Here are fifteen apostrophes: '''''''''''''''"
        \\ str8 = ''''That,' she said, 'is still pointless.''''
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(std.mem.eql(u8, t.get("str1").?.string, t.get("str2").?.string));
    try std.testing.expect(std.mem.eql(u8, t.get("str2").?.string, t.get("str3").?.string));
    try std.testing.expect(std.mem.eql(u8, t.get("str6").?.string, "Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"."));
    try std.testing.expect(std.mem.eql(u8, t.get("str8").?.string, "'That,' she said, 'is still pointless.'"));
    try std.testing.expect(std.mem.eql(u8, t.get("regex").?.string, "<\\i\\c*\\s*>"));
}

test "integer" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ int1 = +99
        \\ int2 = 42
        \\ int3 = 0
        \\ int4 = -17
        \\ int5 = 1_000
        \\ int6 = 5_349_221
        \\ int7 = 53_49_221
        \\ int8 = 1_2_3_4_5
        \\ hex1 = 0xDEADBEEF
        \\ hex2 = 0xdeadbeef
        \\ hex3 = 0xdead_beef
        \\ oct1 = 0o01234567
        \\ oct2 = 0o755
        \\ bin1 = 0b11010110
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(t.get("int1").?.int == 99);
    try std.testing.expect(t.get("int3").?.int == 0);
    try std.testing.expect(t.get("int4").?.int == -17);
    try std.testing.expect(t.get("int6").?.int == 5349221);
    try std.testing.expect(t.get("int8").?.int == 12345);
    try std.testing.expect(t.get("hex1").?.int == t.get("hex2").?.int);
    try std.testing.expect(t.get("hex2").?.int == t.get("hex3").?.int);
    try std.testing.expect(t.get("oct1").?.int == 0o01234567);
    try std.testing.expect(t.get("bin1").?.int == 0b11010110);
}

test "float" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ flt1 = +1.0
        \\ flt2 = 3.1415
        \\ flt3 = -0.01
        \\ flt4 = 5e+22
        \\ flt5 = 1e06
        \\ flt6 = -2E-2
        \\ flt7 = 6.626e-34
        \\ flt8 = 224_617.445_991_228
        \\ sf1 = inf  # positive infinity
        \\ sf2 = +inf # positive infinity
        \\ sf3 = -inf # negative infinity
        \\ sf4 = nan  # actual sNaN/qNaN encoding is implementation-specific
        \\ sf5 = +nan # same as `nan`
        \\ sf6 = -nan # valid, actual encoding is implementation-specific
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(t.get("flt1").?.float == 1.0);
    try std.testing.expect(t.get("flt2").?.float == 3.1415);
    try std.testing.expect(t.get("flt3").?.float == -0.01);
    try std.testing.expect(t.get("flt4").?.float == 5e+22);
    try std.testing.expect(t.get("flt5").?.float == 1e06);
    try std.testing.expect(t.get("flt6").?.float == -2E-2);
    try std.testing.expect(t.get("flt7").?.float == 6.626e-34);
    try std.testing.expect(t.get("flt8").?.float == 224_617.445_991_228);
    try std.testing.expect(std.math.isInf(t.get("sf1").?.float));
    try std.testing.expect(std.math.isInf(t.get("sf2").?.float));
    try std.testing.expect(std.math.isInf(t.get("sf3").?.float) and t.get("sf3").?.float < 0);
    try std.testing.expect(std.math.isNan(t.get("sf4").?.float));
    try std.testing.expect(std.math.isNan(t.get("sf5").?.float));
    try std.testing.expect(std.math.isNan(t.get("sf6").?.float));
}
