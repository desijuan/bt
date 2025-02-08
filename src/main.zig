const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const buffer: []const u8 = try utils.readFile(
        allocator,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer allocator.free(buffer);

    var parser = Parser.init(buffer);

    var torrentFile = Parser.TorrentFile{
        .announce = &.{},
        .comment = &.{},
        .created_by = &.{},
        .name = &.{},
        .pieces = &.{},
        .url_list = &.{},
        .creation_date = 0,
        .length = 0,
        .piece_length = 0,
    };

    try parser.parseDict(&torrentFile);

    try torrentFile.print();
}
