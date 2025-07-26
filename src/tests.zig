const toml = @import("./toml.zig");
const std = @import("std");

test "init" {
    const t = try toml.Toml.init(std.testing.allocator);
    defer t.deinit();
}
