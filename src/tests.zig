const toml = @import("toml.zig");
const parser = @import("parser.zig");
const std = @import("std");

test "toml" {
    const t = try toml.Toml.init(std.testing.allocator);
    defer t.deinit();
}

test "parser" {
    const p = try parser.Parser.init(std.testing.allocator);
    const toml_data = try p.parse_file("tests/basic.toml");
    defer toml_data.deinit();
    defer p.deinit();
}
