const std = @import("std");
const toml = @import("toml.zig");

pub const ParseError = error{
    OpenFileError,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = .{ .alloc = allocator };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.alloc.destroy(self);
    }

    pub fn parse_file(self: *Parser, file_path: []const u8) !*toml.Toml {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        const buffer = try self.alloc.alloc(u8, file_size);
        defer self.alloc.free(buffer);
        _ = try file.readAll(buffer);
        return self.parse_string(buffer);
    }

    pub fn parse_string(self: *Parser, content: []const u8) !*toml.Toml {
        const toml_data = try toml.Toml.init(self.alloc);
        return toml_data;
    }
};
