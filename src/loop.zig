const std = @import("std");
const utils = @import("utils.zig");
const tcp = @import("net/tcp.zig");

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BUFFER_SIZE = 16 * 1024;

const TIMEOUT_MS: c_int = 2000;
const N_CONNS: u16 = 8;

const Event = enum {
    SOCKET,
    CONNECT,
    SEND,
    RECV,
    CLOSE,
};

const State = enum {
    Off,
    CreatingSocket,
    ConnectingToPeer,
    SendingHandshake,
    SendingInterestedMsg,
    ExpectingHandshake,
    ExpectingBitfieldMsg,
    ExpectingUnChokeMsg,
    AskingForPieces,
    Downloading,
    ClosingConnection,
    ShuttingDown,
};

const Ctx = struct {
    fd: i32,
    err: linux.E,
    event: Event,
    state: State,
    isChoked: bool,
    peer: tcp.Peer,
    peer_bf: []const u8,
    buffer: []u8,
};

pub fn startDownloading(ally: std.mem.Allocator, info_hash: *const [20]u8, peers_bytes: []const u8) !void {
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

    var peers: tcp.PeersIterator = try tcp.PeersIterator.init(peers_bytes);

    var clients: [N_CONNS]Ctx = undefined;

    const buffers: []u8 = try ally.alloc(u8, @as(usize, @intCast(N_CONNS)) * BUFFER_SIZE);
    defer {
        ally.free(buffers);
        for (&clients) |*ctx| {
            ally.free(ctx.peer_bf);
            ctx.peer_bf = &.{};
        }
    }

    const n_conns: u16 = for (0..N_CONNS) |i| {
        const peer: tcp.Peer = peers.next() orelse {
            std.debug.print("Total number of peers reached. Starting {} connections.\n", .{i});
            break @intCast(i);
        };

        clients[i] = Ctx{
            .fd = -1,
            .err = .SUCCESS,
            .event = .SOCKET,
            .state = .CreatingSocket,
            .isChoked = true,
            .peer = peer,
            .peer_bf = &.{},
            .buffer = buffers[i .. i + BUFFER_SIZE],
        };

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
            const ctx: *Ctx = @ptrFromInt(cqe.user_data);

            const err: linux.E = cqe.err();
            ctx.err = err;

            switch (ctx.event) {
                .SOCKET => switch (err) {
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
                        ctx.state = .ConnectingToPeer;
                        _ = try ring.connect(@intFromPtr(ctx), fd, &addr.any, addr.getOsSockLen());
                    },

                    else => {
                        std.debug.print("Creation of socket with error {s}\n", .{@tagName(err)});
                        pending -= 1;
                    },
                },

                .CONNECT => switch (err) {
                    .SUCCESS => {
                        std.debug.print("Connected to fd {} @ {}, sending handshake...\n", .{ ctx.fd, ctx.peer });

                        ctx.event = .SEND;
                        ctx.state = .SendingHandshake;
                        _ = try ring.send(@intFromPtr(ctx), ctx.fd, handshake, 0);
                    },

                    .CONNREFUSED, .TIMEDOUT, .HOSTUNREACH => blk: {
                        std.debug.print(
                            "Connection with fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        const peer: tcp.Peer = peers.next() orelse {
                            ctx.event = .CLOSE;
                            ctx.state = .ShuttingDown;
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
                        ctx.state = .ConnectingToPeer;
                        _ = try ring.connect(@intFromPtr(ctx), ctx.fd, &addr.any, addr.getOsSockLen());
                    },

                    else => {
                        std.debug.print(
                            "Connection with fd {} @ {} returned error {s}. Closing fd {[0]}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        ctx.state = .ClosingConnection;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .SEND => switch (err) {
                    .SUCCESS => switch (ctx.state) {
                        .SendingHandshake => {
                            ctx.event = .RECV;
                            ctx.state = .ExpectingHandshake;
                            _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);
                        },

                        .SendingInterestedMsg => {
                            ctx.event = .RECV;
                            ctx.state = .ExpectingBitfieldMsg;
                            _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);
                        },

                        else => |state| try debugState(state),
                    },

                    else => {
                        std.debug.print(
                            "Send to fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        ctx.state = .ClosingConnection;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .RECV => switch (err) {
                    .SUCCESS => {
                        const n_read: usize = @intCast(cqe.res);
                        const recvd_bytes: []const u8 = ctx.buffer[0..n_read];

                        std.debug.print(
                            "Received {} bytes from fd {} @ {}: {any}.\n",
                            .{ n_read, ctx.fd, ctx.peer, recvd_bytes },
                        );

                        switch (ctx.state) {
                            .ExpectingHandshake => blk: {
                                const isAnsPositive: bool = tcp.validateAnswer(recvd_bytes, info_hash);

                                std.debug.print("Valid ans: {}\n", .{isAnsPositive});

                                if (!isAnsPositive) {
                                    ctx.event = .CLOSE;
                                    ctx.state = .ClosingConnection;
                                    _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                    break :blk;
                                }

                                const hs_len: usize = hs.len();

                                if (n_read <= hs_len) {
                                    std.debug.print("No more bytes left. Asking for more.\n", .{});

                                    const msg = tcp.Msg.interested();
                                    var bytes: [msg.len()]u8 = undefined;
                                    try msg.serialize(&bytes);
                                    std.debug.print(
                                        "Sending interested msg to fd {} @ {}: {any}.\n",
                                        .{ ctx.fd, ctx.peer, bytes },
                                    );

                                    ctx.event = .SEND;
                                    ctx.state = .SendingInterestedMsg;
                                    _ = try ring.send(@intFromPtr(ctx), ctx.fd, &bytes, 0);

                                    break :blk;
                                }

                                var offset: usize = hs_len;
                                var bytes: []const u8 = ctx.buffer[offset..n_read];
                                var msg_length: u32 = tcp.Msg.decodeLengthPrefix(bytes[0..4]);

                                if (msg_length == 0) {
                                    // Received keep-alive msg

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingBitfieldMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                if (bytes.len >= msg_length + 4) {
                                    std.debug.print("There are more bytes.\n", .{});

                                    const msg = tcp.Msg.decode(ally, bytes) catch |e| switch (e) {
                                        error.UnknownMsgId => {
                                            std.debug.print("Message Id {} not recognized.\n", .{bytes[4]});

                                            ctx.event = .CLOSE;
                                            ctx.state = .ClosingConnection;
                                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                            break :blk;
                                        },

                                        else => return e,
                                    };
                                    defer if (msg.id != .Bitfield) ally.free(msg.payload);

                                    std.debug.print("msg: {}\n", .{msg});

                                    if (msg.id == .Bitfield) {
                                        ally.free(ctx.peer_bf);
                                        ctx.peer_bf = msg.payload;
                                    }
                                }

                                offset += @intCast(msg_length + 4);

                                if (offset >= n_read) {
                                    std.debug.print(
                                        "No more bytes left. Waiting for unchoke msg from fd {} @ {}...\n",
                                        .{ ctx.fd, ctx.peer },
                                    );

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingUnChokeMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                bytes = ctx.buffer[offset..n_read];
                                msg_length = tcp.Msg.decodeLengthPrefix(bytes[0..4]);

                                if (msg_length == 0) {
                                    // Received keep-alive msg

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingUnChokeMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                if (bytes.len >= msg_length + 4) {
                                    std.debug.print("There are more bytes.\n", .{});

                                    const msg = tcp.Msg.decode(ally, bytes) catch |e| switch (e) {
                                        error.UnknownMsgId => {
                                            std.debug.print("Message Id {} not recognized.\n", .{bytes[4]});

                                            ctx.event = .CLOSE;
                                            ctx.state = .ClosingConnection;
                                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                            break :blk;
                                        },

                                        else => return e,
                                    };
                                    defer ally.free(msg.payload);

                                    std.debug.print("msg: {}\n", .{msg});
                                }

                                ctx.event = .CLOSE;
                                ctx.state = .ClosingConnection;
                                _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                            },

                            .ExpectingBitfieldMsg => blk: {
                                var offset: usize = 0;
                                var bytes: []const u8 = ctx.buffer[offset..n_read];
                                var msg_length: u32 = tcp.Msg.decodeLengthPrefix(bytes[0..4]);

                                if (msg_length == 0) {
                                    // Received keep-alive msg

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingBitfieldMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                if (bytes.len >= msg_length + 4) {
                                    std.debug.print("There are more bytes.\n", .{});

                                    const msg = tcp.Msg.decode(ally, bytes) catch |e| switch (e) {
                                        error.UnknownMsgId => {
                                            std.debug.print("Message Id {} not recognized.\n", .{bytes[4]});

                                            ctx.event = .CLOSE;
                                            ctx.state = .ClosingConnection;
                                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                            break :blk;
                                        },

                                        else => return e,
                                    };
                                    defer if (msg.id != .Bitfield) ally.free(msg.payload);

                                    std.debug.print("msg: {}\n", .{msg});

                                    if (msg.id == .Bitfield) {
                                        ally.free(ctx.peer_bf);
                                        ctx.peer_bf = msg.payload;
                                    }
                                }

                                offset += @intCast(msg_length + 4);

                                if (offset >= n_read) {
                                    std.debug.print(
                                        "No more bytes left. Waiting for unchoke msg from fd {} @ {}...\n",
                                        .{ ctx.fd, ctx.peer },
                                    );

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingUnChokeMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                bytes = ctx.buffer[offset..n_read];
                                msg_length = tcp.Msg.decodeLengthPrefix(bytes[0..4]);

                                if (msg_length == 0) {
                                    // Received keep-alive msg

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingUnChokeMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :blk;
                                }

                                if (bytes.len >= msg_length + 4) {
                                    std.debug.print("There are more bytes.\n", .{});

                                    const msg = tcp.Msg.decode(ally, bytes) catch |e| switch (e) {
                                        error.UnknownMsgId => {
                                            std.debug.print("Message Id {} not recognized.\n", .{bytes[4]});

                                            ctx.event = .CLOSE;
                                            ctx.state = .ClosingConnection;
                                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                            break :blk;
                                        },

                                        else => return e,
                                    };
                                    defer ally.free(msg.payload);

                                    std.debug.print("msg: {}\n", .{msg});
                                }

                                ctx.event = .CLOSE;
                                ctx.state = .ClosingConnection;
                                _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                            },

                            .ExpectingUnChokeMsg => blk: {
                                const msg = tcp.Msg.decode(ally, recvd_bytes) catch |e| switch (e) {
                                    error.UnknownMsgId => {
                                        std.debug.print("Message Id {} not recognized.\n", .{recvd_bytes[4]});

                                        ctx.event = .CLOSE;
                                        ctx.state = .ClosingConnection;
                                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                        break :blk;
                                    },

                                    else => return e,
                                };
                                defer ally.free(msg.payload);

                                std.debug.print("msg: {}\n", .{msg});

                                ctx.event = .CLOSE;
                                ctx.state = .ClosingConnection;
                                _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                            },

                            else => |state| try debugState(state),
                        }
                    },

                    else => {
                        std.debug.print(
                            "Recv from fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        ctx.state = .ClosingConnection;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .CLOSE => blk: {
                    switch (err) {
                        .SUCCESS => std.debug.print(
                            "Closed fd {} @ {}.\n",
                            .{ ctx.fd, ctx.peer },
                        ),

                        else => std.debug.print(
                            "Close fd {} @ {} returned error {s}.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }

                    if (ctx.state == .ShuttingDown) {
                        ctx.state = .Off;
                        pending -= 1;
                        break :blk;
                    }

                    const peer: tcp.Peer = peers.next() orelse {
                        ctx.state = .Off;
                        pending -= 1;
                        break :blk;
                    };

                    ctx.fd = -1;
                    ctx.peer = peer;
                    ctx.event = .SOCKET;
                    ctx.state = .CreatingSocket;

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

fn debugState(state: State) error{InvalidState}!void {
    std.debug.print("Invalid State: {s}\n", .{@tagName(state)});
    return error.InvalidState;
}

fn printInfo(T: type) void {
    std.debug.print("{s} size: {}, align: {}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}

test "prueba" {
    printInfo(Event);
    printInfo(State);
    printInfo(tcp.Peer);
    printInfo(Ctx);
}
