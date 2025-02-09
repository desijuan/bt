const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("parser.zig");
const tf = @import("torrent_file.zig");
const net = @import("net.zig");

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
    var hash_str: [60]u8 = undefined;

    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});

    for (hash, 0..) |n, i|
        _ = try std.fmt.bufPrint(hash_str[3 * i .. 3 * (i + 1)], "%{X:0>2}", .{n});

    torrentFile.info_hash = &hash_str;

    std.debug.print("\n Torrent File:\n", .{});
    try torrentFile.print();

    std.debug.print("\n", .{});

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

    // Request Peers

    const body = try net.requestPeers(allocator, .{
        .announce = torrentFile.announce,
        .peer_id = "%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14",
        .info_hash = torrentFile.info_hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = torrentInfo.length,
    });
    defer allocator.free(body);

    var response = tf.TrackerResponse{
        .interval = 0,
        .peers = &.{},
    };

    var reqBodyParser = Parser.init(body);
    try reqBodyParser.parseDict(tf.TrackerResponse, &response);

    response.print();

    std.debug.print("\n", .{});
}
