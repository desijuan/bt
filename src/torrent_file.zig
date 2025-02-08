const std = @import("std");
const Parser = @import("parser.zig");

pub const key_names = [10][]const u8{
    "announce",
    "comment",
    "created by",
    "creation date",
    "info",
    "length",
    "name",
    "piece length",
    "pieces",
    "url-list",
};

pub const field_names = [10][]const u8{
    "announce",
    "comment",
    "created_by",
    "creation_date",
    "",
    "length",
    "name",
    "piece_length",
    "pieces",
    "url_list",
};

pub const data_types = [10]Parser.DataType{
    .string,
    .string,
    .string,
    .int,
    .dict,
    .int,
    .string,
    .int,
    .string,
    .list,
};

const Self = @This();

announce: []const u8,
comment: []const u8,
created_by: []const u8,
name: []const u8,
pieces: []const u8,
url_list: []const u8,
creation_date: u32,
length: u32,
piece_length: u32,

pub fn print(self: Self) !void {
    inline for (@typeInfo(Self).Struct.fields) |field| switch (@typeInfo(field.type)) {
        .Pointer => if (comptime std.mem.eql(u8, "pieces", field.name))
            std.debug.print("{s}: {x} [..]\n", .{ field.name, @field(self, field.name)[0..20] })
        else if (comptime std.mem.eql(u8, "url_list", field.name)) {
            std.debug.print("url-list:\n", .{});
            var parser = Parser.init(@field(self, field.name));
            while (parser.i < parser.buf.len) std.debug.print("  '{s}'\n", .{try parser.parseStr()});
        } else std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

        .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

        else => unreachable,
    };
}
