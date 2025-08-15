const toml = @import("toml.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const std = @import("std");

test "toml" {
    const t = try toml.Toml.init(std.testing.allocator);
    defer t.deinit();
}

test "parser" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_file("test/test_hard.toml");
    defer toml_data.deinit();
}

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
    const t = toml_data.get_table();
    try std.testing.expect(std.mem.eql(u8, t.get("\"127.0.0.1\"").?.string, "value"));
    try std.testing.expect(
        std.mem.eql(u8, t.get("\"\"").?.string, t.get("''").?.string),
    );
    try std.testing.expect(t.get("site").?.get("\"google.com\"").?.bool == true);
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("fruit").?.get("name").?.string,
        t.get("fruit").?.get("flavor").?.string,
    ));
    try std.testing.expect(std.mem.eql(u8, t.get("3").?.get("14159").?.string, "pi"));
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

test "boolean" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ bool1 = true
        \\ bool2 = false
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(t.get("bool1").?.bool == true);
    try std.testing.expect(t.get("bool2").?.bool == false);
}

test "datetime" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ odt1 = 1979-05-27T07:32:00Z
        \\ odt2 = 1979-05-27T00:32:00-07:00
        \\ odt3 = 1979-05-27T00:32:00.999999-07:00
        \\ odt4 = 1979-05-27 07:32:00Z
        \\ ldt1 = 1979-05-27T07:32:00
        \\ ldt2 = 1979-05-27T00:32:00.999999
        \\ ld1 = 1979-05-27
        \\ lt1 = 07:32:00
        \\ lt2 = 00:32:00.999999
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(std.meta.eql(t.get("odt1").?.datetime, types.DateTime{
        .date = .{
            .day = 27,
            .month = 5,
            .year = 1979,
        },
        .time = .{
            .hour = 7,
            .minute = 32,
            .second = 0,
        },
        .offset_minutes = 0,
    }));
    try std.testing.expect(t.get("odt2").?.datetime.offset_minutes == -7 * 60);
    try std.testing.expect(t.get("odt3").?.datetime.time.nanosecond == 999999000);
    try std.testing.expect(
        std.meta.eql(t.get("odt1").?.datetime, t.get("odt4").?.datetime),
    );
    try std.testing.expect(
        std.meta.eql(t.get("odt4").?.datetime.date, t.get("ldt1").?.datetime.date),
    );
    try std.testing.expect(
        std.meta.eql(t.get("odt4").?.datetime.time, t.get("ldt1").?.datetime.time),
    );
    try std.testing.expect(t.get("ldt1").?.datetime.offset_minutes == null);
    try std.testing.expect(t.get("ldt2").?.datetime.time.nanosecond == 999999000);
    try std.testing.expect(std.meta.eql(t.get("ld1").?.date, types.Date{
        .day = 27,
        .month = 5,
        .year = 1979,
    }));
    try std.testing.expect(
        std.meta.eql(t.get("lt1").?.time, t.get("odt1").?.datetime.time),
    );
    try std.testing.expect(
        std.meta.eql(t.get("lt2").?.time, t.get("ldt2").?.datetime.time),
    );
}

test "array" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ integers = [ 1, 2, 3 ]
        \\ colors = [ "red", "yellow", "green" ]
        \\ nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
        \\ nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
        \\ string_array = [ "all", 'strings', """are the same""", '''type''' ]
        \\ numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
        \\ contributors = [
        \\   "Foo Bar <foo@example.com>",
        \\   { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }
        \\ ]
        \\ integers2 = [
        \\   1, 2, 3
        \\ ]
        \\ integers3 = [
        \\   1,
        \\   2, # this is ok
        \\ ]
        \\ empty = []
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(t.get("integers").?.array.items.len == 3);
    try std.testing.expect(
        t.get("nested_arrays_of_ints").?.array.items[1].array.items[1].int == 4,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("nested_mixed_array").?.array.items[1].array.items[1].string,
        "b",
    ));
    try std.testing.expect(
        std.mem.eql(u8, t.get("string_array").?.array.items[2].string, "are the same"),
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("contributors").?.array.items[1].get("url").?.string,
        "https://example.com/bazqux",
    ));
    try std.testing.expect(
        t.get("integers").?.array.items.len == t.get("integers2").?.array.items.len,
    );
    try std.testing.expect(t.get("integers3").?.array.items.len == 2);
    try std.testing.expect(t.get("empty").?.array.items.len == 0);
}

test "table" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ name_inline = { first = "Tom", last = "Preston-Werner" }
        \\ point_inline = { x = 1, y = 2 }
        \\ animal_inline = { type.name = "pug" }
        \\ fruit.apple.color = "red"
        \\ fruit.apple.taste.sweet = true
        \\ [fruit1]
        \\ apple.color = "red"
        \\ apple.taste.sweet = true
        \\ [fruit2.apple.texture]
        \\ smooth = true
        \\ [table-1]
        \\ key1 = "some string"
        \\ key2 = 123
        \\ [table-2]
        \\ key1 = "another string"
        \\ key2 = 456
        \\ [dog."tater.man"]
        \\ type.name = "pug"
        \\ [a.b.c]
        \\ [ d.e.f ]          # same as [d.e.f]
        \\ [ g .  h  . i ]    # same as [g.h.i]
        \\ [ j . "ʞ" . 'l' ]
        \\ key1 = 123
        \\ [x.y.z.w]
        \\ [x]
        \\ [name]
        \\ first = "Tom"
        \\ last = "Preston-Werner"
        \\ [point]
        \\ x = 1
        \\ y = 2
        \\ [animal]
        \\ type.name = "pug"
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("fruit").?.get("apple").?.get("color").?.string,
        t.get("fruit1").?.get("apple").?.get("color").?.string,
    ));
    try std.testing.expect(
        t.get("fruit2").?.get("apple").?.get("texture").?.get("smooth").?.bool == true,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("dog").?.get("\"tater.man\"").?.get("type").?.get("name").?.string,
        "pug",
    ));
    try std.testing.expect(
        t.get("j").?.get("\"ʞ\"").?.get("'l'").?.get("key1").?.int == 123,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("name_inline").?.get("first").?.string,
        t.get("name").?.get("first").?.string,
    ));
    try std.testing.expect(
        t.get("point_inline").?.get("x").?.int == t.get("point").?.get("x").?.int,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("animal_inline").?.get("type").?.get("name").?.string,
        t.get("animal").?.get("type").?.get("name").?.string,
    ));
}

test "array_of_tables" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const toml_data = try p.parse_string(
        \\ points = [ { x = 1, y = 2, z = 3 },
        \\            { x = 7, y = 8, z = 9 },
        \\            { x = 2, y = 4, z = 8 } ]
        \\ [[products]]
        \\ name = "Hammer"
        \\ sku = 738594937
        \\ [[products]]
        \\ [[products]]
        \\ name = "Nail"
        \\ sku = 284758393
        \\ color = "gray"
        \\ [[fruits]]
        \\ name = "apple"
        \\ [fruits.physical]
        \\ color = "red"
        \\ shape = "round"
        \\ [[fruits.varieties]]
        \\ name = "red delicious"
        \\ [[fruits.varieties]]
        \\ name = "granny smith"
        \\ [[fruits]]
        \\ name = "banana"
        \\ [[fruits.varieties]]
        \\ name = "plantain"
    );
    defer toml_data.deinit();
    const t = toml_data.get_table();
    try std.testing.expect(
        t.get("products").?.array.items.len == 3,
    );
    try std.testing.expect(
        t.get("products").?.array.items[1].table.table.count() == 0,
    );
    try std.testing.expect(
        t.get("fruits").?.array.items.len == 2,
    );
    try std.testing.expect(
        t.get("fruits").?.array.items[0].table.get("varieties").?.array.items.len == 2,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("fruits").?.array.items[0].table.get("physical").?.table.get("color").?.string,
        "red",
    ));
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("fruits").?.array.items[1].table.get("varieties").?.array.items[0].table.get("name").?.string,
        "plantain",
    ));
    try std.testing.expect(
        t.get("points").?.array.items.len == 3,
    );
    try std.testing.expect(
        t.get("points").?.array.items[1].table.get("y").?.int == 8,
    );
}

test "encode" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    const parsed_file = try p.parse_file("test/test_easy.toml");
    defer parsed_file.deinit();
    const encoded_toml = try parsed_file.to_toml();
    defer p.alloc.free(encoded_toml);
    const parsed_encoded = try p.parse_string(encoded_toml);
    defer parsed_encoded.deinit();
    const t1 = parsed_file.get_table();
    const t2 = parsed_encoded.get_table();

    try std.testing.expect(
        std.mem.eql(u8, t1.get("title").?.string, t2.get("title").?.string),
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t1.get("owner").?.get("name").?.string,
        t2.get("owner").?.get("name").?.string,
    ));
    try std.testing.expect(
        t1.get("database").?.get("ports").?.array.items.len ==
            t2.get("database").?.get("ports").?.array.items.len,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        t1.get("database").?.get("data").?.array.items[0].array.items[0].string,
        t2.get("database").?.get("data").?.array.items[0].array.items[0].string,
    ));
    try std.testing.expect(
        t1.get("database").?.get("temp_targets").?.get("cpu").?.float ==
            t2.get("database").?.get("temp_targets").?.get("cpu").?.float,
    );
    try std.testing.expect(t1.get("servers").?.table.table.count() ==
        t2.get("servers").?.table.table.count());
}

test "adding" {
    const p = try parser.Parser.init(std.testing.allocator);
    defer p.deinit();
    var toml_t = try p.parse_string(
        \\ value = {}
        \\ [table]
        \\ int = 123
        \\ [table.subtable]
        \\ tab = {a = 1, b = [1, 2]}
        \\ [header]
        \\ [[table_array]]
        \\ a = 1
        \\ [[table_array]]
    );
    defer toml_t.deinit();
    var t = toml_t.get_table();

    try t.getPtr("table").?.put("new", .{ .int = 0 }, p.alloc);
    try t.put("added", .{ .bool = true }, p.alloc);

    const str = try p.alloc.dupe(u8, "Adding a dotted table");
    try t.put("add.table.str", .{ .string = str }, p.alloc);
    try t.put("add.table.int", .{ .int = 1 }, p.alloc);

    var array = toml.TomlArray.init(p.alloc);
    try array.append(.{ .bool = true });
    try array.append(.{ .float = 3.14 });
    try array.append(.{ .table = toml.TomlTable.init_inline(p.alloc) });
    try t.getPtr("header").?.put("array", .{ .array = array }, p.alloc);

    try t.put_table("new_table", p.alloc);
    try t.getPtr("new_table").?.put("key", .{ .int = 0 }, p.alloc);

    try t.put_table("new_table.sub_table.new", p.alloc);
    try t.getPtr("new_table").?.get("sub_table").?.getPtr("new").?.put(
        "bool",
        .{ .bool = false },
        p.alloc,
    );

    try t.put_table("new_header.table", p.alloc);
    try t.getPtr("new_header").?.put("key1", .{ .int = 1 }, p.alloc);
    try t.getPtr("new_header").?.getPtr("table").?.put("key2", .{ .int = 2 }, p.alloc);

    try std.testing.expect(t.get("value").?.table.t_type == .inline_t);
    try std.testing.expect(t.get("table").?.get("new").?.int == 0);
    try std.testing.expect(t.get("added").?.bool == true);
    try std.testing.expect(std.mem.eql(
        u8,
        t.get("add").?.get("table").?.get("str").?.string,
        "Adding a dotted table",
    ));

    try std.testing.expect(t.get("header").?.get("array").?.array.items.len == 3);
    try std.testing.expect(t.get("table_array").?.array.items.len == 2);

    try std.testing.expect(t.get("new_table").?.get("key").?.int == 0);
    try std.testing.expect(
        t.get("new_table").?.get("sub_table").?.get("new").?.get("bool").?.bool == false,
    );
    try std.testing.expect(t.get("new_header").?.get("key1").?.int == 1);
    try std.testing.expect(t.get("new_header").?.get("table").?.get("key2").?.int == 2);
}
