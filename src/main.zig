const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("parser.zig");
const tf = @import("torrent_file.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const buffer: []const u8 = try utils.readFile(
        allocator,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer allocator.free(buffer);

    var torrentFileParser = Parser.init(buffer);

    var torrentFile = tf.TorrentFile{
        .creation_date = 0,
        .announce = &.{},
        .comment = &.{},
        .created_by = &.{},
        .info = &.{},
        .url_list = &.{},
    };

    try torrentFileParser.parseDict(tf.TorrentFile, &torrentFile);

    std.debug.print("\n Torrent File:\n", .{});
    try torrentFile.print();

    var torrentInfo = tf.TorrentInfo{
        .length = 0,
        .piece_length = 0,
        .name = &.{},
        .pieces = &.{},
    };

    var torrentInfoParser = Parser.init(torrentFile.info);

    try torrentInfoParser.parseDict(tf.TorrentInfo, &torrentInfo);

    std.debug.print("\n Torrent Info:\n", .{});
    torrentInfo.print();

    std.debug.print("\n", .{});
}
