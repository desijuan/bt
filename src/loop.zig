const std = @import("std");
const utils = @import("utils.zig");
const tcp = @import("net/tcp.zig");

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BLOCK_SIZE = 16 * 1024;
const MSG_BUF_SIZE = 512;
const RECV_BUF_SIZE = BLOCK_SIZE + MSG_BUF_SIZE;

const MAX_KEEPALIVES = 5;
const TIMEOUT_MS: c_int = 2000;
const N_CONNS: u16 = 1;

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
    ExpectingHandshake,
    ExpectingBitfieldMsg,
    ExpectingUnChokeMsg,
    Downloading,
    ClosingConnection,
    ShuttingDown,
};

const Ctx = struct {
    fd: i32,
    ka_cnt: u16,
    err: linux.E,
    event: Event,
    state: State,
    peer: tcp.Peer,
    peer_bf: []const u8,
    buffer: []u8,

    const Info = struct {
        fd: i32,
        ka_cnt: u16,
        err: linux.E,
        event: Event,
        state: State,
        peer: tcp.Peer,
    };

    fn info(self: Ctx) Info {
        return Info{
            .fd = self.fd,
            .ka_cnt = self.ka_cnt,
            .err = self.err,
            .event = self.event,
            .state = self.state,
            .peer = self.peer,
        };
    }
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

    const buffers: []u8 = try ally.alloc(u8, @as(usize, @intCast(N_CONNS)) * RECV_BUF_SIZE);
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
            .ka_cnt = 0,
            .err = .SUCCESS,
            .event = .SOCKET,
            .state = .CreatingSocket,
            .peer = peer,
            .peer_bf = &.{},
            .buffer = buffers[i .. i + RECV_BUF_SIZE],
        };

        _ = try ring.socket(
            @intFromPtr(&clients[i]),
            linux.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
            0,
        );
    } else N_CONNS;

    var unchokes: u32 = 0;

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
                        std.debug.print("Creation of socket failed with error {s}\n", .{@tagName(err)});
                        pending -= 1;
                    },
                },

                .CONNECT => switch (err) {
                    .SUCCESS => {
                        std.debug.print("Connected to fd {} @ {}, sending handshake...\n", .{ ctx.fd, ctx.peer });

                        ctx.event = .SEND;
                        ctx.state = .ExpectingHandshake;
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
                    .SUCCESS => {
                        ctx.event = .RECV;
                        _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);
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
                    .SUCCESS => recv: {
                        const n_read: usize = @intCast(cqe.res);
                        const data: []const u8 = ctx.buffer[0..n_read];

                        std.debug.print(
                            "Received {} bytes from fd {} @ {}: {any}.\n",
                            .{ n_read, ctx.fd, ctx.peer, data },
                        );

                        if (data.len < 4) {
                            std.debug.print(
                                "Didn't receive enough bytes. Closing fd {} @ {}.\n",
                                .{ ctx.fd, ctx.peer },
                            );

                            ctx.event = .CLOSE;
                            ctx.state = .ClosingConnection;
                            _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                            break :recv;
                        }

                        if (isKeepAliveMsg(data)) {
                            if (ctx.ka_cnt >= MAX_KEEPALIVES) {
                                std.debug.print(
                                    "Received too many keep-alive msgs from fd {} @ {}. Closing connection.\n",
                                    .{ ctx.fd, ctx.peer },
                                );

                                ctx.event = .CLOSE;
                                ctx.state = .ClosingConnection;
                                _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                break :recv;
                            }

                            std.debug.print(
                                "Received keep-alive msg from fd {} @ {}. Waiting for more bytes...\n",
                                .{ ctx.fd, ctx.peer },
                            );

                            ctx.ka_cnt += 1;

                            ctx.event = .RECV;
                            _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                            break :recv;
                        } else ctx.ka_cnt = 0;

                        var offset: usize = 0;
                        var bytes: []const u8 = data;

                        state: switch (ctx.state) {
                            .ExpectingHandshake => {
                                const isAnsPositive: bool = tcp.validateAnswer(bytes, info_hash);

                                std.debug.print("Valid ans: {}\n", .{isAnsPositive});

                                if (!isAnsPositive) {
                                    ctx.state = .ClosingConnection;
                                    continue :state .ClosingConnection;
                                }

                                offset += hs.len();
                                bytes = data[offset..];

                                if (bytes.len <= 0) {
                                    std.debug.print("No more bytes left. Asking for more.\n", .{});

                                    const msg = tcp.Msg.interested();
                                    var msg_bytes: [msg.len()]u8 = undefined;
                                    try msg.serialize(&msg_bytes);
                                    std.debug.print(
                                        "Sending interested msg to fd {} @ {}: {any}.\n",
                                        .{ ctx.fd, ctx.peer, msg_bytes },
                                    );

                                    ctx.event = .SEND;
                                    ctx.state = .ExpectingBitfieldMsg;
                                    _ = try ring.send(@intFromPtr(ctx), ctx.fd, &msg_bytes, 0);

                                    break :recv;
                                }

                                if (bytes.len < 4) {
                                    std.debug.print(
                                        "Didn't understand: {any}.\nClosing fd {} @ {}.\nctx: {any}\n",
                                        .{ bytes, ctx.fd, ctx.peer, ctx.info() },
                                    );

                                    ctx.state = .ClosingConnection;
                                    continue :state .ClosingConnection;
                                }

                                ctx.state = .ExpectingBitfieldMsg;
                                continue :state .ExpectingBitfieldMsg;
                            },

                            .ExpectingBitfieldMsg => {
                                const msg_length: u32 = tcp.Msg.decodeLengthPrefix(bytes[0..4]);

                                if (bytes.len < msg_length + 4) {
                                    std.debug.print(
                                        "Didn't understand: {any}.\nClosing fd {} @ {}.\nctx: {any}\n",
                                        .{ bytes, ctx.fd, ctx.peer, ctx.info() },
                                    );

                                    ctx.state = .ClosingConnection;
                                    continue :state .ClosingConnection;
                                }

                                const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
                                    error.UnknownMsgId => {
                                        std.debug.print(
                                            "Message Id {} not recognized in {any}.\n",
                                            .{ bytes[4], bytes[0..5] },
                                        );

                                        ctx.state = .ClosingConnection;
                                        continue :state .ClosingConnection;
                                    },

                                    else => return e,
                                };

                                std.debug.print("msg: {}\n", .{msg});

                                if (msg.id == .Bitfield) {
                                    const bitfield: []u8 = try ally.alloc(u8, msg.payload.len);
                                    @memcpy(bitfield, msg.payload);
                                    ctx.peer_bf = bitfield;
                                }

                                offset += @intCast(msg_length + 4);
                                bytes = data[offset..];

                                if (bytes.len <= 0) {
                                    std.debug.print(
                                        "No more bytes left. Waiting for unchoke msg from fd {} @ {}...\n",
                                        .{ ctx.fd, ctx.peer },
                                    );

                                    ctx.event = .RECV;
                                    ctx.state = .ExpectingUnChokeMsg;
                                    _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = ctx.buffer }, 0);

                                    break :recv;
                                }

                                if (bytes.len < 4) {
                                    std.debug.print(
                                        "Didn't understand: {any}\n. Closing fd {} @ {}.\n",
                                        .{ bytes, ctx.fd, ctx.peer },
                                    );

                                    ctx.state = .ClosingConnection;
                                    continue :state .ClosingConnection;
                                }

                                ctx.state = .ExpectingUnChokeMsg;
                                continue :state .ExpectingUnChokeMsg;
                            },

                            .ExpectingUnChokeMsg => {
                                const inMsg = tcp.Msg.decode(bytes) catch |e| switch (e) {
                                    error.UnknownMsgId => {
                                        std.debug.print("Message Id {} not recognized.\n", .{bytes[4]});

                                        ctx.state = .ClosingConnection;
                                        continue :state .ClosingConnection;
                                    },

                                    else => return e,
                                };

                                std.debug.print("msg: {}\n", .{inMsg});

                                if (inMsg.id != .Unchoke) {
                                    std.debug.print(
                                        "Hmm, was expecting an unchoke msg from {} @ {}." ++
                                            " Received instead: {}. Closing the connection.\n",
                                        .{ ctx.fd, ctx.peer, inMsg },
                                    );

                                    ctx.state = .ClosingConnection;
                                    continue :state .ClosingConnection;
                                }

                                std.debug.print(
                                    "Received unchoke msg from fd {} @ {}.\n",
                                    .{ ctx.fd, ctx.peer },
                                );

                                unchokes += 1;

                                var payload: [12]u8 = undefined;
                                const outMsg = tcp.Msg.request(0, 0, BLOCK_SIZE, &payload);
                                var msg_bytes: [17]u8 = undefined;
                                try outMsg.serialize(&msg_bytes);
                                std.debug.print(
                                    "Sending request msg to fd {} @ {}: {any}.\n",
                                    .{ ctx.fd, ctx.peer, msg_bytes },
                                );

                                ctx.event = .SEND;
                                ctx.state = .Downloading;
                                _ = try ring.send(@intFromPtr(ctx), ctx.fd, &msg_bytes, 0);

                                break :recv;
                            },

                            .Downloading => {
                                ctx.state = .ClosingConnection;
                                continue :state .ClosingConnection;
                            },

                            .ClosingConnection => {
                                std.debug.print(
                                    "Closing fd {} @ {}.\n",
                                    .{ ctx.fd, ctx.peer },
                                );

                                ctx.event = .CLOSE;
                                _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                                break :recv;
                            },

                            else => |state| try debugState(state),
                        }
                    },

                    else => {
                        std.debug.print(
                            "Recv from fd {} @ {} returned error {s}. Closing the connection.\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        ctx.state = .ClosingConnection;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);
                    },
                },

                .CLOSE => close: {
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

                    ally.free(ctx.peer_bf);
                    ctx.peer_bf = &.{};

                    if (ctx.state == .ShuttingDown) {
                        ctx.state = .Off;
                        pending -= 1;
                        break :close;
                    }

                    const peer: tcp.Peer = peers.next() orelse {
                        ctx.state = .Off;
                        pending -= 1;
                        break :close;
                    };

                    ctx.fd = -1;
                    ctx.ka_cnt = 0;
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

    std.debug.print("\nReceived a total of {} Unchokes.\n", .{unchokes});
}

inline fn isKeepAliveMsg(bytes: []const u8) bool {
    return (bytes.len >= 4 and bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0);
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

fn peerHasPiece(bitfield: []const u8, index: u32) bool {
    return bitfield[index / 8] & (1 << (7 - index % 8)) != 0;
}
