const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("bencode/Parser.zig");
const bencode = @import("bencode/data.zig");
const http = @import("net/http.zig");
const loop = @import("loop.zig");

const TorrentFile = bencode.TorrentFile;
const TorrentInfo = bencode.TorrentInfo;
const TrackerResponse = bencode.TrackerResponse;

pub fn main() !void {
    var gpa_inst = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa_inst.deinit();

    const gpa = gpa_inst.allocator();

    const file_buffer: []const u8 = try utils.readFile(
        gpa,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer gpa.free(file_buffer);

    // Parse Torrent File

    var hash: [20]u8 = undefined;

    var torrentFile = TorrentFile{
        .creation_date = 0,
        .announce = &.{},
        .comment = &.{},
        .created_by = &.{},
        .info = &.{},
        .info_hash = &hash,
        .url_list = &.{},
    };

    var parser = Parser.init(file_buffer);
    try parser.parseDict(TorrentFile, &torrentFile);

    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});

    std.debug.print("\n Torrent File:\n", .{});
    try torrentFile.print();

    std.debug.print("\n", .{});

    // Parse Torrent Info

    var torrentInfo = TorrentInfo{
        .length = 0,
        .piece_length = 0,
        .name = &.{},
        .pieces = &.{},
    };

    parser = Parser.init(torrentFile.info);
    try parser.parseDict(TorrentInfo, &torrentInfo);

    std.debug.print("\n Torrent Info:\n", .{});
    torrentInfo.print();

    std.debug.print("\n", .{});

    if (torrentInfo.length % torrentInfo.piece_length != 0) return error.MalfornedPiecesInfo;
    if (torrentInfo.pieces.len % 20 != 0) return error.MalfornedPieces;
    if (torrentInfo.length / torrentInfo.piece_length != torrentInfo.pieces.len / 20)
        return error.MalfornedPieces;

    // Request Peers

    const peer_id = "%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14";

    const body = try http.requestPeers(gpa, .{
        .announce = torrentFile.announce,
        .peer_id = peer_id,
        .info_hash = torrentFile.info_hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = torrentInfo.length,
    });
    defer gpa.free(body);

    var trackerResponse = TrackerResponse{
        .interval = 0,
        .peers = &.{},
    };

    parser = Parser.init(body);
    try parser.parseDict(TrackerResponse, &trackerResponse);

    trackerResponse.print();

    std.debug.print("\n", .{});

    // Download from Peers

    try loop.startDownloading(gpa, torrentFile.info_hash, trackerResponse.peers);

    std.debug.print("\nAll done!\n", .{});
}

comptime {
    _ = @import("utils.zig");
    _ = @import("net/tcp.zig");
}
