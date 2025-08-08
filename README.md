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

pub fn main() !void {
    const p = try toml.Parser.init(std.heap.page_allocator);
    defer p.deinit();
    const toml_table = try p.parse_file("example.toml");
    defer toml_table.deinit();
}
```

