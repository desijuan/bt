const std = @import("std");
const Parser = @import("parser.zig");

pub const TorrentFile = struct {
    pub const key_names = [6][]const u8{
        "creation date",
        "announce",
        "comment",
        "created by",
        "info",
        "url-list",
    };

    pub const field_names = [6][]const u8{
        "creation_date",
        "announce",
        "comment",
        "created_by",
        "info",
        "url_list",
    };

    pub const data_types = [6]Parser.DataType{
        .int,
        .string,
        .string,
        .string,
        .dict,
        .list,
    };

    creation_date: u32,
    announce: []const u8,
    comment: []const u8,
    created_by: []const u8,
    info: []const u8,
    url_list: []const u8,

    pub fn print(self: TorrentFile) !void {
        inline for (@typeInfo(TorrentFile).Struct.fields) |field| switch (@typeInfo(field.type)) {
            .Pointer => if (comptime std.mem.eql(u8, "info", field.name))
                std.debug.print("{s}: {s} [..]\n", .{ field.name, @field(self, field.name)[0..90] })
            else if (comptime std.mem.eql(u8, "url_list", field.name)) {
                std.debug.print("{s}:\n", .{field.name});
                try Parser.printList(@field(self, field.name));
            } else std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};

pub const TorrentInfo = struct {
    pub const key_names = [4][]const u8{
        "length",
        "piece length",
        "name",
        "pieces",
    };

    pub const field_names = [4][]const u8{
        "length",
        "piece_length",
        "name",
        "pieces",
    };

    pub const data_types = [4]Parser.DataType{
        .int,
        .int,
        .string,
        .string,
    };

    length: u32,
    piece_length: u32,
    name: []const u8,
    pieces: []const u8,

    pub fn print(self: TorrentInfo) void {
        inline for (@typeInfo(TorrentInfo).Struct.fields) |field| switch (@typeInfo(field.type)) {
            .Pointer => if (comptime std.mem.eql(u8, "pieces", field.name))
                std.debug.print("{s}: {x} [..]\n", .{ field.name, @field(self, field.name)[0..20] })
            else
                std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};
