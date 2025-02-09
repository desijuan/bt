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

    // Parse Torrent File

    var torrentFile = tf.TorrentFile{
        .creation_date = 0,
        .announce = &.{},
        .comment = &.{},
        .created_by = &.{},
        .info = &.{},
        .info_hash = &.{},
        .url_list = &.{},
    };

    var torrentFileParser = Parser.init(buffer);
    try torrentFileParser.parseDict(tf.TorrentFile, &torrentFile);

    var hash: [20]u8 = undefined;
    var hash_str: [40]u8 = undefined;

    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});

    for (hash, 0..) |n, i|
        _ = try std.fmt.bufPrint(hash_str[2 * i .. 2 * i + 2], "{x:0>2}", .{n});

    torrentFile.info_hash = &hash_str;

    std.debug.print("\n Torrent File:\n", .{});
    try torrentFile.print();

    // Parse Torrent Info

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
