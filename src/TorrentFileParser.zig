const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const utils = @import("utils.zig");
const bp = @import("bp");
const http = @import("net/http.zig");
const fsm = @import("fsm.zig");
const Config = @import("Config.zig");

const data = @import("bp/data.zig");
const TorrentFile = data.TorrentFile;
const TorrentSchema = data.TorrentSchema;
const Torrent = data.Torrent;
const TrackerResponseSchema = data.TrackerResponseSchema;
const TrackerResponse = data.TrackerResponse;

const TorrentFileParser = @This();

var buf_torrent_file: [:0]const u8 = undefined;

pub var torrentFile: TorrentFile = undefined;
pub var hash: [20]u8 = undefined;

pub var torrent: Torrent = undefined;

var buf_tracker_response: []const u8 = undefined;

pub var trackerResponse: TrackerResponse = undefined;

pub fn readTorrent() !void {
    buf_torrent_file = try utils.readFileZ(Ctx.a, Ctx.io, "debian-12.9.0-amd64-netinst.iso.torrent");
    errdefer Ctx.a.free(buf_torrent_file);

    var parser: bp.Parser = undefined;

    // Parse Torrent File
    parser = bp.Parser.init(buf_torrent_file);
    try parser.parseDict(data.TorrentFileSchema, &torrentFile);

    std.crypto.hash.Sha1.hash(torrentFile.info, &hash, .{});

    // Parse Torrent
    parser = bp.Parser.init(torrentFile.info);
    try parser.parseDict(TorrentSchema, &torrent);

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
