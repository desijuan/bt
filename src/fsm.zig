const std = @import("std");
const utils = @import("utils.zig");
const Torrent = @import("Torrent.zig");
const tcp = @import("net/tcp.zig");
const Client = @import("Client.zig");
const Config = @import("Config.zig");
const PieceScheduler = @import("piece_scheduler/PieceScheduler.zig");

const log = std.log;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const Ip4Address = std.Io.net.Ip4Address;

pub const SIZE_BLOCK = 16 * 1024;
const SIZE_MSG_BUF = 512;
const SIZE_RECV_BUF = SIZE_BLOCK + SIZE_MSG_BUF;

var pieceScheduler: PieceScheduler = undefined;

pub fn startDownloading(
    gpa: std.mem.Allocator,
    config: Config,
    torrent: Torrent,
    info_hash: *const [20]u8,
    peers_bytes: []const u8,
) !void {
    const n_clients: usize = config.n_clients;

    pieceScheduler = try PieceScheduler.new(torrent.pieceCnt());
    defer pieceScheduler.deinit();

    const entries: u16 = try std.math.ceilPowerOfTwo(u16, 4 * @as(u16, @intCast(n_clients)));

    var ring: IoUring = try IoUring.init(entries, 0);
    defer ring.deinit();

    const hs = tcp.Handshake{
        .info_hash = info_hash,
        .peer_id = &utils.range(1, 21),
    };

    const handshake: []const u8 = try hs.serialize(gpa);
    defer gpa.free(handshake);

    std.debug.print("handshake: {any}\n\n", .{handshake});

    var peers: tcp.PeersIterator = try tcp.PeersIterator.init(peers_bytes);
    log.info("total peers: {d}.", .{peers.totalPeersCnt()});

    const recv_buffers: []u8 = try gpa.alloc(u8, n_clients * SIZE_RECV_BUF);
    defer gpa.free(recv_buffers);

    const pieces_buffers: []u8 = try gpa.alloc(u8, n_clients * torrent.piece_length);
    defer gpa.free(pieces_buffers);

    const clients: []Client = try gpa.alloc(Client, n_clients);
    const n_conns: u16 = for (0..n_clients) |i| {
        const peer: Ip4Address = peers.next() orelse {
            log.info("Total number of peers reached. Starting {d} connections.", .{i});
            break @intCast(i);
        };

        clients[i] = Client.init(
            @intCast(i),
            recv_buffers[i * SIZE_RECV_BUF .. (i + 1) * SIZE_RECV_BUF],
            pieces_buffers[i * torrent.piece_length .. (i + 1) * torrent.piece_length],
        );

        try clients[i].queueSocketOp(&ring, peer);
    } else @intCast(n_clients);
    defer {
        for (clients[0..n_conns]) |*client| client.deinit(gpa);
        gpa.free(clients);
    }

    var pending: i32 = n_conns;
    var unchokes: u32 = 0;
    while (pending > 0) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const client: *Client = @ptrFromInt(cqe.user_data);
            try client.handleEvent(gpa, &ring, cqe.err(), cqe.res, config.timeout_ms, &pending, &unchokes, info_hash, &peers, &pieceScheduler);
        }
    }

    log.info("Received {d} unchokes.", .{unchokes});
}
