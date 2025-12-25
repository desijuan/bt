const std = @import("std");
const utils = @import("utils.zig");

const bp = @import("bp");

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

    const file_buffer: []const u8 = try std.fs.cwd().readFileAlloc(
        gpa,
        "debian-12.9.0-amd64-netinst.iso.torrent",
        std.math.maxInt(usize),
    );
    defer gpa.free(file_buffer);

    // Parse Torrent File

    var parser = bp.Parser.init(file_buffer);
    var torrentFile: TorrentFile = undefined;
    try parser.parseDict(TorrentFileInfo, &torrentFile);

    std.debug.print("\n\n Torrent File:\n", .{});
    try data.printTorrentFile(torrentFile);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});
    std.debug.print("\n\nhash: ", .{});
    for (hash) |c| std.debug.print("{x:0>2}", .{c});
    std.debug.print("'\n", .{});

    // Parse Torrent

    parser = bp.Parser.init(torrentFile.info);
    var torrent: Torrent = undefined;
    try parser.parseDict(TorrentInfo, &torrent);

    std.debug.print("\n\n Torrent Info:\n", .{});
    data.printTorrent(torrent);

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

    parser = bp.Parser.init(body);
    var trackerResponse: TrackerResponse = undefined;
    try parser.parseDict(TrackerResponseInfo, &trackerResponse);

    data.printTrackerResponse(trackerResponse);

    std.debug.print("\n", .{});

    // Download from Peers

    try loop.startDownloading(gpa, &hash, trackerResponse.peers, torrent);

    std.debug.print("\nAll done!\n", .{});
}

comptime { // Tests
    _ = @import("utils.zig");
    _ = @import("net/tcp.zig");
}
