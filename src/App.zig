const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const utils = @import("utils.zig");
const bp = @import("bp");
const http = @import("net/http.zig");
const Torrent = @import("Torrent.zig");
const fsm = @import("fsm.zig");
const Config = @import("Config.zig");

const data = @import("bp/data.zig");

const App = @This();

const peer_id = "%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14";

pub var config: Config = undefined;

var buf_torrent_file: [:0]const u8 = undefined;

pub var torrentFile: data.TorrentFile = undefined;
pub var hash: [20]u8 = undefined;

pub var torrent: data.Torrent = undefined;

var buf_tracker_response: []const u8 = undefined;

pub var trackerResponse: data.TrackerResponse = undefined;

pub fn readTorrent() !void {
    config = try Config.readFromDisk(Ctx.a, Ctx.io);

    buf_torrent_file = try utils.readFileZ(Ctx.a, Ctx.io, "debian-12.9.0-amd64-netinst.iso.torrent");
    errdefer Ctx.a.free(buf_torrent_file);

    var parser: bp.Parser = undefined;

    // Parse Torrent File
    parser = bp.Parser.init(buf_torrent_file);
    try parser.parseDict(data.TorrentFileSchema, &torrentFile);

    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});

    // Parse Torrent
    parser = bp.Parser.init(torrentFile.info);
    try parser.parseDict(data.TorrentSchema, &torrent);

    if (torrent.length < 0 or torrent.@"piece length" < 0) return error.UnexepectedNegativeValue;

    const torrent_length: u32 = @intCast(torrent.length);
    const piece_length: u32 = @intCast(torrent.@"piece length");

    if (torrent_length % piece_length != 0) return error.MalfornedPiecesInfo;
    if (torrent.pieces.len % 20 != 0) return error.MalfornedPieces;
    if (torrent_length / piece_length != torrent.pieces.len / 20) return error.MalfornedPieces;
}

pub fn freeTorrentFileBuffer() void {
    Ctx.a.free(buf_torrent_file);
}

pub fn printTorrentInfo() !void {
    std.debug.print("\n Torrent File:\n", .{});
    try data.printTorrentFile(App.torrentFile);

    std.debug.print("\n\nhash: ", .{});
    for (App.hash) |c| std.debug.print("{x:0>2}", .{c});

    std.debug.print("\n\n Torrent Info:\n", .{});
    data.printTorrent(App.torrent);
}

pub fn requestPeers() !void {
    buf_tracker_response = try http.requestPeers(Ctx.a, Ctx.io, .{
        .announce = App.torrentFile.announce,
        .peer_id = peer_id,
        .info_hash = &App.hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = @as(u32, @intCast(App.torrent.length)),
    });
    errdefer Ctx.a.free(buf_tracker_response);

    var parser = bp.Parser.init(buf_tracker_response);
    try parser.parseDict(data.TrackerResponseSchema, &trackerResponse);
}

pub fn printTrackerResponse() void {
    std.debug.print("\n Tracker Response:\n", .{});
    data.printTrackerResponse(trackerResponse);
    std.debug.print("\n", .{});
}

pub fn freeTrackerResponseBuffer() void {
    Ctx.a.free(buf_tracker_response);
}

pub fn startDownloading() !void {
    try fsm.startDownloading(Ctx.a, config, Torrent{
        .length = @intCast(App.torrent.length),
        .piece_length = @intCast(App.torrent.@"piece length"),
        .name = App.torrent.name,
        .pieces = App.torrent.pieces,
    }, &hash, trackerResponse.peers);
}
