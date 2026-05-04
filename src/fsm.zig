const std = @import("std");
const utils = @import("utils.zig");
const tcp = @import("net/tcp.zig");
const Client = @import("Client.zig");

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const Ip4Address = std.Io.net.Ip4Address;

pub const BLOCK_SIZE = 16 * 1024;
const MSG_BUF_SIZE = 512;
const RECV_BUF_SIZE = BLOCK_SIZE + MSG_BUF_SIZE;

const N_CONNS: u16 = 1;

pub const UIntStack = utils.Stack(u32);

pub const Torrent = struct {
    length: u32,
    piece_length: u32,
    name: []const u8,
    pieces: []const u8,
};

pub fn startDownloading(
    gpa: std.mem.Allocator,
    torrent: Torrent,
    info_hash: *const [20]u8,
    peers_bytes: []const u8,
) !void {
    const n_pieces: usize = torrent.length / torrent.piece_length;

    const stack_items: []u32 = try gpa.alloc(u32, n_pieces);
    defer gpa.free(stack_items);

    var pieces: UIntStack = UIntStack.init(stack_items);

    for (0..n_pieces) |i| try pieces.push(@intCast(n_pieces - i));

    const entries: u16 = try std.math.ceilPowerOfTwo(u16, 4 * N_CONNS);

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

    var clients: [N_CONNS]Client = undefined;

    const recv_buffers: []u8 = try gpa.alloc(u8, N_CONNS * RECV_BUF_SIZE);
    defer {
        gpa.free(recv_buffers);
        for (&clients) |*client| client.deinit(gpa);
    }

    const pieces_buffers: []u8 = try gpa.alloc(u8, N_CONNS * torrent.piece_length);
    defer gpa.free(pieces_buffers);

    const n_conns: u16 = for (0..N_CONNS) |i| {
        const peer: Ip4Address = peers.next() orelse {
            std.debug.print(
                "Total number of peers reached. Starting {d} connections.\n",
                .{i},
            );
            break @intCast(i);
        };

        clients[i].init(
            peer,
            recv_buffers[i * RECV_BUF_SIZE .. (i + 1) * RECV_BUF_SIZE],
            pieces_buffers[i * torrent.piece_length .. (i + 1) * torrent.piece_length],
        );

        _ = try ring.socket(
            @intFromPtr(&clients[i]),
            linux.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
            0,
        );
    } else N_CONNS;

    var pending: i32 = n_conns;
    while (pending > 0) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const client: *Client = @ptrFromInt(cqe.user_data);
            try client.advance(gpa, &ring, cqe.err(), cqe.res, &pending, info_hash, &peers, &pieces);
        }
    }
}
