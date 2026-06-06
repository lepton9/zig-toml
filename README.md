# zig-toml

TOML (v1.0.0) parser in Zig

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

    const toml_table = try p.parse_file(io, "example.toml");
    defer toml_table.deinit();
}
```
