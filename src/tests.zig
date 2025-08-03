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
