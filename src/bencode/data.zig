const std = @import("std");
const Parser = @import("parser.zig");

pub const TorrentFile = struct {
    const N = 6;

    pub const key_names = [N][]const u8{
        "creation date",
        "announce",
        "comment",
        "created by",
        "info",
        "url-list",
    };

    pub const field_names = [N][]const u8{
        "creation_date",
        "announce",
        "comment",
        "created_by",
        "info",
        "url_list",
    };

    pub const data_types = [N]Parser.DataType{
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
    info_hash: *[20]u8,
    url_list: []const u8,

    pub fn print(self: TorrentFile) !void {
        inline for (@typeInfo(TorrentFile).Struct.fields) |field| switch (@typeInfo(field.type)) {
            .Pointer => if (comptime std.mem.eql(u8, "info", field.name))
                std.debug.print("{s}: {s} [..]\n", .{ field.name, self.info[0..90] })
            else if (comptime std.mem.eql(u8, "info_hash", field.name)) {
                std.debug.print("{s}: '", .{field.name});
                for (self.info_hash.*) |c| std.debug.print("{x:0>2}", .{c});
                std.debug.print("'\n", .{});
            } else if (comptime std.mem.eql(u8, "url_list", field.name)) {
                std.debug.print("{s}:", .{field.name});
                try Parser.printList(self.url_list);
            } else std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};

pub const TorrentInfo = struct {
    const N = 4;

    pub const key_names = [N][]const u8{
        "length",
        "piece length",
        "name",
        "pieces",
    };

    pub const field_names = [N][]const u8{
        "length",
        "piece_length",
        "name",
        "pieces",
    };

    pub const data_types = [N]Parser.DataType{
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
                std.debug.print("{s}: {x} [..]\n", .{ field.name, self.pieces[0..20] })
            else
                std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};

pub const TrackerResponse = struct {
    const N = 2;

    pub const key_names = [N][]const u8{
        "interval",
        "peers",
    };

    pub const field_names = [N][]const u8{
        "interval",
        "peers",
    };

    pub const data_types = [N]Parser.DataType{
        .int,
        .string,
    };

    interval: u32,
    peers: []const u8,

    pub fn print(self: TrackerResponse) void {
        inline for (@typeInfo(TrackerResponse).Struct.fields) |field| switch (@typeInfo(field.type)) {
            .Pointer => std.debug.print("{s}: {x} [..]\n", .{ field.name, @field(self, field.name)[0..20] }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};
