const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("bencode/parser.zig");
const bencode_data = @import("bencode/data.zig");
const http = @import("net/http.zig");
const tcp = @import("net/tcp.zig");

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const TorrentFile = bencode_data.TorrentFile;
const TorrentInfo = bencode_data.TorrentInfo;
const TrackerResponse = bencode_data.TrackerResponse;

const BUFFER_SIZE = 512;

const TIMEOUT_MS: c_int = 2000;
const N_CONNS: u16 = 8;

const Event = enum {
    SOCKET,
    CONNECT,
    SEND,
    RECV,
    CLOSE,
    CLOSE_LAST,
};

const Ctx = struct {
    event: Event,
    fd: i32,
    peer: tcp.Peer,
    buffer: ?[]u8,

    fn freeBuffer(self: *Ctx, allocator: std.mem.Allocator) void {
        if (self.buffer) |buffer| {
            allocator.free(buffer);
            self.buffer = null;
        }
    }
};

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

    var torrentFileParser = Parser.init(file_buffer);
    try torrentFileParser.parseDict(TorrentFile, &torrentFile);

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

    var torrentInfoParser = Parser.init(torrentFile.info);
    try torrentInfoParser.parseDict(TorrentInfo, &torrentInfo);

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

    var resBodyParser = Parser.init(body);
    try resBodyParser.parseDict(TrackerResponse, &trackerResponse);

    trackerResponse.print();

    std.debug.print("\n", .{});

    // Download from Peers

    // if (trackerResponse.peers.len % 6 != 0) return error.MalformedPeersList;
    // const n_conns: u16 = @as(u16, @intCast(trackerResponse.peers.len / 6));

    const entries: u16 = try std.math.ceilPowerOfTwo(u16, 4 * N_CONNS);

    var ring: IoUring = try IoUring.init(entries, 0);
    defer ring.deinit();

    const hs = tcp.Handshake{
        .info_hash = torrentFile.info_hash,
        .peer_id = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 },
    };

    const handshake: []const u8 = try hs.serialize(gpa);
    defer gpa.free(handshake);

    std.debug.print("handshake: {any}\n\n", .{handshake});

    var peers: tcp.PeersIterator = try tcp.PeersIterator.init(trackerResponse.peers);
    var ctxs_array: [N_CONNS]Ctx = undefined;

    for (0..N_CONNS) |n| {
        const peer: tcp.Peer = peers.next() orelse
            return error.NoPeersLeft;

        const buffer: []u8 = try gpa.alloc(u8, BUFFER_SIZE);

        ctxs_array[n] = Ctx{
            .event = .SOCKET,
            .fd = -1,
            .peer = peer,
            .buffer = buffer,
        };

        _ = try ring.socket(
            @intFromPtr(&ctxs_array[n]),
            linux.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
            0,
        );
    }

    var pending: i32 = N_CONNS;
    while (pending > 0) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const ctx: *Ctx = @ptrFromInt(cqe.user_data);

            switch (ctx.event) {
                .SOCKET => switch (cqe.err()) {
                    .SUCCESS => {
                        const fd: i32 = cqe.res;
                        ctx.fd = fd;

                        std.debug.print("Connecting fd {} @ {}\n", .{ fd, ctx.peer });

                        try posix.setsockopt(
                            fd,
                            posix.IPPROTO.TCP,
                            posix.TCP.USER_TIMEOUT,
                            std.mem.asBytes(&TIMEOUT_MS),
                        );

                        const addr: std.net.Address = ctx.peer.address();

                        ctx.event = .CONNECT;
                        _ = try ring.connect(@intFromPtr(ctx), fd, &addr.any, addr.getOsSockLen());
                    },

                    else => |err| {
                        pending -= 1;
                        ctx.freeBuffer(gpa);

                        std.debug.print(
                            "Creation of socket for peer {} failed with error {s}\n",
                            .{ ctx.peer, @tagName(err) },
                        );
                    },
                },

                .CONNECT => switch (cqe.err()) {
                    .SUCCESS => {
                        std.debug.print("Connected to fd {} @ {}, sending handshake...\n", .{ ctx.fd, ctx.peer });

                        ctx.event = .SEND;
                        _ = try ring.send(@intFromPtr(ctx), ctx.fd, handshake, 0);
                    },

                    .CONNREFUSED, .TIMEDOUT, .HOSTUNREACH => |err| blk: {
                        std.debug.print(
                            "Connection with fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        const peer: tcp.Peer = peers.next() orelse {
                            ctx.event = .CLOSE_LAST;
                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                            break :blk;
                        };

                        ctx.peer = peer;

                        std.debug.print(
                            "Attempting another peer: fd {} @ {}...\n",
                            .{ ctx.fd, peer },
                        );

                        const addr: std.net.Address = peer.address();

                        ctx.event = .CONNECT;
                        _ = try ring.connect(@intFromPtr(ctx), ctx.fd, &addr.any, addr.getOsSockLen());
                    },

                    else => |err| {
                        std.debug.print(
                            "Connection with fd {} @ {} returned error {s}. Closing fd {[0]}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .SEND => switch (cqe.err()) {
                    .SUCCESS => {
                        ctx.event = .RECV;
                        _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer.? }, 0);
                    },

                    else => |err| {
                        std.debug.print(
                            "Send to fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .RECV => {
                    switch (cqe.err()) {
                        .SUCCESS => blk: {
                            const n_read: usize = @intCast(cqe.res);
                            const ans: []const u8 = ctx.buffer.?[0..n_read];

                            std.debug.print(
                                "Received {} bytes from fd {} @ {}: {any}\n",
                                .{ n_read, ctx.fd, ctx.peer, ans },
                            );

                            const isAnsPositive: bool = tcp.validateAnswer(ans, torrentFile.info_hash);

                            std.debug.print("Valid ans: {}\n", .{isAnsPositive});

                            if (!isAnsPositive) break :blk;

                            if (n_read > hs.len())
                                std.debug.print("There are more bytes.\n", .{})
                            else
                                std.debug.print("No more bytes left.\n", .{});
                        },

                        else => |err| std.debug.print(
                            "Recv from fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }

                    ctx.event = .CLOSE;
                    _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                },

                .CLOSE => blk: {
                    const peer: tcp.Peer = peers.next() orelse {
                        pending -= 1;
                        ctx.freeBuffer(gpa);

                        switch (cqe.err()) {
                            .SUCCESS => std.debug.print(
                                "Closed fd {} @ {}\n",
                                .{ ctx.fd, ctx.peer },
                            ),

                            else => |err| std.debug.print(
                                "Close fd {} @ {} returned error {s}\n",
                                .{ ctx.fd, ctx.peer, @tagName(err) },
                            ),
                        }

                        break :blk;
                    };

                    ctx.fd = -1;
                    ctx.peer = peer;
                    ctx.event = .SOCKET;

                    _ = try ring.socket(
                        @intFromPtr(ctx),
                        linux.AF.INET,
                        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
                        posix.IPPROTO.TCP,
                        0,
                    );
                },

                .CLOSE_LAST => {
                    pending -= 1;
                    ctx.freeBuffer(gpa);

                    switch (cqe.err()) {
                        .SUCCESS => std.debug.print(
                            "Closed fd {} @ {}\n",
                            .{ ctx.fd, ctx.peer },
                        ),

                        else => |err| std.debug.print(
                            "Close fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }
                },
            }
        }
    }

    std.debug.print("\nAll done!\n", .{});
}
