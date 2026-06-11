const std = @import("std");
const build_options = @import("build_options");

pub const TomlVersion = enum {
    v1_0_0,
    v1_1_0,
};

pub const toml_version: TomlVersion = blk: {
    const v = build_options.toml_version;
    if (std.mem.eql(u8, v, "1.0.0") or std.mem.eql(u8, v, "1.0")) break :blk .v1_0_0;
    if (std.mem.eql(u8, v, "1.1.0") or std.mem.eql(u8, v, "1.1")) break :blk .v1_1_0;
    @compileError("Unsupported TOML version for -Dtoml-version. Use 1.0.0 or 1.1.0.");
};

pub inline fn isV1_1() bool {
    return toml_version == .v1_1_0;
}
