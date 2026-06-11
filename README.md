# zig-toml

TOML parser in Zig (supports v1.0.0 and v1.1.0)

## Usage
Add to `build.zig.zon`
```
zig fetch --save git+https://github.com/lepton9/zig-toml
```

In `build.zig`

``` zig
const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
const toml_mod = toml.module("toml");
exe.root_module.addImport("toml", toml_mod);

// Optional: select spec behavior (default: 1.0.0)
// const toml = b.dependency("toml", .{
//     .target = target,
//     .optimize = optimize,
//     .toml_version = "1.1.0",
// });
```

## Example

```zig
const toml = @import("toml");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const p = try toml.Parser.init(gpa);
    defer p.deinit();

    const toml_table = try p.parseFile(io, "example.toml");
    defer toml_table.deinit();
}
```
