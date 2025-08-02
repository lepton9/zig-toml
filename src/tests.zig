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
