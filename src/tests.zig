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
        defer p.deinit(); // Ensure parser is deinitialized on error
        switch (err) {
            parser.ParseError.NotImplemented => std.log.err("Not Implemented\n", .{}),
            else => std.log.err("{}\n", .{err}),
        }
        return;
    };

    defer toml_data.deinit();
    toml_data.table.print();
}
