const std = @import("std");
const log = std.log;

const Config = @import("Config.zig");
const utils = @import("utils.zig");
const bp = @import("bp");
const http = @import("net/http.zig");
const fsm = @import("fsm.zig");

const data = @import("bp/data.zig");

const TorrentFileInfo: type = data.TorrentFileInfo;
const TorrentInfo: type = data.TorrentInfo;
const TrackerResponseInfo: type = data.TrackerResponseInfo;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const config: Config = blk: {
        const config_buffer: [:0]const u8 = utils.readFileZ(gpa, io, "config.zon") catch |err| switch (err) {
            error.FileNotFound => break :blk Config{},
            else => return err,
        };
        defer gpa.free(config_buffer);

        break :blk try std.zon.parse.fromSlice(Config, gpa, config_buffer, null, .{
            .ignore_unknown_fields = true,
            .free_on_error = false,
        });
    };

    const file_buffer: [:0]const u8 = try utils.readFileZ(gpa, io, "debian-12.9.0-amd64-netinst.iso.torrent");
    defer gpa.free(file_buffer);

    // Parse Torrent File
    var parser: bp.Parser = undefined;

    parser = bp.Parser.init(file_buffer);
    var torrent_file: bp.Dto(TorrentFileInfo) = undefined;
    try parser.parseDict(TorrentFileInfo, &torrent_file);

    std.debug.print("\n\n Torrent File:\n", .{});
    try data.printTorrentFile(torrent_file);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(torrent_file.info, &hash, .{});
    std.debug.print("\n\nhash: ", .{});
    for (hash) |c| std.debug.print("{x:0>2}", .{c});
    std.debug.print("'\n", .{});

    // Parse Torrent

    parser = bp.Parser.init(torrent_file.info);
    var torrent: bp.Dto(TorrentInfo) = undefined;
    try parser.parseDict(TorrentInfo, &torrent);

    std.debug.print("\n\n Torrent Info:\n", .{});
    data.printTorrent(torrent);

    std.debug.print("\n", .{});

    if (torrent.length < 0 or torrent.@"piece length" < 0) return error.UnexepectedNegativeValue;
    const torrent_length: u32 = @intCast(torrent.length);
    const piece_length: u32 = @intCast(torrent.@"piece length");

    if (torrent_length % piece_length != 0) return error.MalfornedPiecesInfo;
    if (torrent.pieces.len % 20 != 0) return error.MalfornedPieces;
    if (torrent_length / piece_length != torrent.pieces.len / 20)
        return error.MalfornedPieces;

    // Request Peers

    const peer_id = "%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14";

    const body = try http.requestPeers(gpa, io, .{
        .announce = torrent_file.announce,
        .peer_id = peer_id,
        .info_hash = &hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = @as(u32, @intCast(torrent.length)),
    });
    defer gpa.free(body);

    parser = bp.Parser.init(body);
    var trackerResponse: bp.Dto(TrackerResponseInfo) = undefined;
    try parser.parseDict(TrackerResponseInfo, &trackerResponse);

    data.printTrackerResponse(trackerResponse);

    std.debug.print("\n", .{});

    // Download from Peers

    const torr = fsm.Torrent{
        .length = torrent_length,
        .piece_length = piece_length,
        .name = torrent.name,
        .pieces = torrent.pieces,
    };

    try fsm.startDownloading(gpa, config, torr, &hash, trackerResponse.peers);

    log.info("All done!", .{});
}

comptime { // Tests
    _ = @import("utils.zig");
    _ = @import("net/tcp.zig");
}
