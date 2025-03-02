const std = @import("std");
const utils = @import("utils.zig");
const tcp = @import("net/tcp.zig");

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BUFFER_SIZE = 512;

const TIMEOUT_MS: c_int = 2000;
const N_CONNS: u16 = 8;

const Event = enum {
    SOCKET,
    CONNECT,
    SEND,
    RECV,
    CLOSE,
};

const Ctx = struct {
    event: Event,
    fd: i32,
    peer: tcp.Peer,
    buffer: []u8,
};

pub fn startDownloading(ally: std.mem.Allocator, info_hash: *const [20]u8, peers: []const u8) !void {
    const entries: u16 = try std.math.ceilPowerOfTwo(u16, 4 * N_CONNS);

    var ring: IoUring = try IoUring.init(entries, 0);
    defer ring.deinit();

    const hs = tcp.Handshake{
        .info_hash = info_hash,
        .peer_id = &utils.range(1, 21),
    };

    const handshake: []const u8 = try hs.serialize(ally);
    defer ally.free(handshake);

    std.debug.print("handshake: {any}\n\n", .{handshake});

    var peersIter: tcp.PeersIterator = try tcp.PeersIterator.init(peers);

    const ctxs_buffers: []u8 = try ally.alloc(u8, N_CONNS * BUFFER_SIZE);
    defer ally.free(ctxs_buffers);

    var ctxs_array: [N_CONNS]Ctx = undefined;

    const n_conns: u16 = for (0..N_CONNS) |i| {
        const peer: tcp.Peer = peersIter.next() orelse {
            std.debug.print("Total number of peers reached. Starting {} connections.\n", .{i});
            break @intCast(i);
        };

        ctxs_array[i] = Ctx{
            .event = .SOCKET,
            .fd = -1,
            .peer = peer,
            .buffer = ctxs_buffers[i .. i + BUFFER_SIZE],
        };

        _ = try ring.socket(
            @intFromPtr(&ctxs_array[i]),
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
                        std.debug.print(
                            "Creation of socket for peer {} failed with error {s}\n",
                            .{ ctx.peer, @tagName(err) },
                        );

                        pending -= 1;
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

                        const peer: tcp.Peer = peersIter.next() orelse {
                            ctx.event = .CLOSE;
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
                        _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);
                    },

                    else => |err| {
                        std.debug.print(
                            "Send to fd {} @ {} returned error {s}.\n",
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
                            const ans: []const u8 = ctx.buffer[0..n_read];

                            std.debug.print(
                                "Received {} bytes from fd {} @ {}: {any}.\n",
                                .{ n_read, ctx.fd, ctx.peer, ans },
                            );

                            const isAnsPositive: bool = tcp.validateAnswer(ans, info_hash);

                            std.debug.print("Valid ans: {}\n", .{isAnsPositive});

                            if (!isAnsPositive) break :blk;

                            const hs_len: usize = hs.len();
                            if (n_read > hs_len) {
                                std.debug.print("There are more bytes.\n", .{});
                                const msg_prefix = ctx.buffer[hs_len .. hs_len + 4][0..4];
                                const msg_length: u32 = tcp.Msg.decodeLength(msg_prefix);
                                std.debug.print("msg prefix: {any}\n", .{msg_prefix});
                                std.debug.print("msg length: {}\n", .{msg_length});
                            } else {
                                std.debug.print("No more bytes left.\n", .{});
                            }
                        },

                        else => |err| std.debug.print(
                            "Recv from fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }

                    ctx.event = .CLOSE;
                    _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                },

                .CLOSE => blk: {
                    switch (cqe.err()) {
                        .SUCCESS => std.debug.print(
                            "Closed fd {} @ {}.\n",
                            .{ ctx.fd, ctx.peer },
                        ),

                        else => |err| std.debug.print(
                            "Close fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }

                    const peer: tcp.Peer = peersIter.next() orelse {
                        pending -= 1;
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
            }
        }
    }
}
