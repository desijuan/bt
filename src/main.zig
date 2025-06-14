const std = @import("std");
const utils = @import("utils.zig");

const bp = @import("bp");
const Parser = bp.Parser;

const http = @import("net/http.zig");
const loop = @import("loop.zig");

const data = @import("bp/data.zig");

const TorrentFileInfo: type = data.TorrentFileInfo;
const TorrentFile: type = bp.Dto(TorrentFileInfo);

const TorrentInfo: type = data.TorrentInfo;
const Torrent: type = bp.Dto(TorrentInfo);

const TrackerResponseInfo: type = data.TrackerResponseInfo;
const TrackerResponse: type = bp.Dto(TrackerResponseInfo);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{ .safety = true }){};
    defer _ = gpa_instance.deinit();

    const gpa = gpa_instance.allocator();

    const file_buffer: []const u8 = try utils.readFile(
        gpa,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer gpa.free(file_buffer);

    // Parse Torrent File

    var torrentFile = TorrentFile{
        .@"creation date" = 0,
        .announce = &.{},
        .comment = &.{},
        .@"created by" = &.{},
        .info = &.{},
        .@"url-list" = &.{},
    };

    var parser = Parser.init(file_buffer);
    try parser.parseDict(TorrentFileInfo, &torrentFile);

    std.debug.print("#####", .{});
    std.debug.print("\n\n Torrent File:\n", .{});
    try data.printTorrentFile(torrentFile);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});
    std.debug.print("\n\nhash: {s}\n", .{&hash});

    // Parse Torrent Info

    var torrent = Torrent{
        .length = 0,
        .@"piece length" = 0,
        .name = &.{},
        .pieces = &.{},
    };

    parser = Parser.init(torrentFile.info);
    try parser.parseDict(TorrentInfo, &torrent);

    std.debug.print("\n\n Torrent Info:\n", .{});
    data.printTorrent(torrent);

    std.debug.print("\n#####\n", .{});

    std.debug.print("\n", .{});

    if (torrent.length % torrent.@"piece length" != 0) return error.MalfornedPiecesInfo;
    if (torrent.pieces.len % 20 != 0) return error.MalfornedPieces;
    if (torrent.length / torrent.@"piece length" != torrent.pieces.len / 20)
        return error.MalfornedPieces;

    // Request Peers

    const peer_id = "%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14";

    const body = try http.requestPeers(gpa, .{
        .announce = torrentFile.announce,
        .peer_id = peer_id,
        .info_hash = &hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = torrent.length,
    });
    defer gpa.free(body);

    var trackerResponse = TrackerResponse{
        .interval = 0,
        .peers = &.{},
    };

    parser = Parser.init(body);
    try parser.parseDict(TrackerResponseInfo, &trackerResponse);

    data.printTrackerResponse(trackerResponse);

    std.debug.print("\n", .{});

    // Download from Peers

    try loop.startDownloading(gpa, &hash, trackerResponse.peers, torrent);

    std.debug.print("\nAll done!\n", .{});
}

comptime {
    _ = @import("utils.zig");
    _ = @import("net/tcp.zig");
}
