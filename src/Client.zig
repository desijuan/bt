const std = @import("std");
const tcp = @import("net/tcp.zig");
const fsm = @import("fsm.zig");
const utils = @import("utils.zig");

const UIntStack = fsm.UIntStack;
const BLOCK_SIZE = fsm.BLOCK_SIZE;

const Allocator = std.mem.Allocator;
const log = std.log;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const Ip4Address = std.Io.net.Ip4Address;

// TODO: Set this in a global config?
const TIMEOUT_MS: c_int = 2000;
const MAX_KEEPALIVES = 8;

const State = enum {
    Connecting,
    Handshaking,
    ExpectingBitfieldMsg,
    ExpectingUnChokeMsg,
    Downloading,
    ClosingConnection,
    Idle,
    Off,
};

const Operation = enum {
    none,
    socket,
    connect,
    send,
    recv,
    close,
};

const Peer = struct {
    addr: Ip4Address,
    addr_in: posix.sockaddr.in,
    bf: ?[]const u8 = null,

    fn init(addr: Ip4Address) Peer {
        return Peer{ .addr = addr, .addr_in = tcp.toSockAddr(addr), .bf = null };
    }

    fn deinit(self: *Peer, gpa: Allocator) void {
        if (self.bf) |bf| {
            gpa.free(bf);
            self.bf = null;
        }
    }
};

const Piece = struct {
    index: u32,
    i: u32,
};

const RecvBuf = struct {
    buf: []u8,
    i: usize,
    n_read: usize,

    fn init(buf: []u8) RecvBuf {
        return RecvBuf{ .buf = buf, .i = 0, .n_read = 0 };
    }

    fn initReader(self: *RecvBuf, n_read: usize) void {
        self.i = 0;
        self.n_read = n_read;
    }

    fn remainingBytes(self: RecvBuf) i32 {
        return @as(i32, @intCast(self.n_read)) - @as(i32, @intCast(self.i));
    }

    fn getRemainingBytes(self: RecvBuf) error{NoMoreBytesLeft}![]const u8 {
        if (self.remainingBytes() <= 0) return error.NoMoreBytesLeft;

        return self.buf[self.i..self.n_read];
    }
};

const Client = @This();

fd: i32,
ka_cnt: u16,
state: State,
op: Operation,
peer: ?Peer,
piece: ?Piece,
recv_buf: RecvBuf,
piece_buf: []u8,

pub fn init(self: *Client, peer_addr: Ip4Address, recv_buf: []u8, piece_buf: []u8) void {
    self.* = Client{
        .fd = -1,
        .ka_cnt = 0,
        .state = .Connecting,
        .op = .socket,
        .peer = Peer.init(peer_addr),
        .piece = null,
        .recv_buf = RecvBuf.init(recv_buf),
        .piece_buf = piece_buf,
    };
}

pub fn deinit(self: *Client, gpa: Allocator) void {
    if (self.peer) |*peer| peer.deinit(gpa);
}

pub fn advance(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    err: linux.E,
    res: i32,
    pending: *i32,
    info_hash: *const [20]u8,
    peers: *tcp.PeersIterator,
    pieces: *UIntStack,
) !void {
    state_sw: switch (self.state) {
        .Connecting => switch (self.op) {
            .socket => switch (err) {
                .SUCCESS => {
                    self.fd = res;

                    log.info("Connecting to {f} @ fd {d}.", .{ self.peer.?.addr, self.fd });

                    try posix.setsockopt(
                        self.fd,
                        posix.IPPROTO.TCP,
                        posix.TCP.USER_TIMEOUT,
                        std.mem.asBytes(&TIMEOUT_MS),
                    );

                    self.op = .connect;
                    _ = try ring.connect(
                        @intFromPtr(self),
                        self.fd,
                        @ptrCast(&self.peer.?.addr_in),
                        @sizeOf(@TypeOf(self.peer.?.addr_in)),
                    );
                },

                else => {
                    log.err("Creation of socket failed with error {t}.", .{err});
                    pending.* -= 1;
                },
            },

            .connect => switch (err) {
                .SUCCESS => {
                    log.info(
                        "Successfully connected to {f} @ fd {d}. Sending handshake.",
                        .{ self.peer.?.addr, self.fd },
                    );

                    // TODO: Revisar esto.
                    const hs = tcp.Handshake{
                        .info_hash = info_hash,
                        .peer_id = &utils.range(1, 21),
                    };

                    // TODO: Arreglar memory leak.
                    const handshake: []const u8 = try hs.serialize(gpa);
                    errdefer gpa.free(handshake);

                    self.state = .Handshaking;
                    self.op = .send;
                    _ = try ring.send(@intFromPtr(self), self.fd, handshake, 0);
                },

                .CONNREFUSED, .TIMEDOUT, .HOSTUNREACH => err_blk: {
                    log.info(
                        "Connection with {f} @ fd {d} returned {t}.",
                        .{ self.peer.?.addr, self.fd, err },
                    );

                    const peer_addr: Ip4Address = peers.next() orelse {
                        log.info("No more peers. Shutting down.", .{});

                        self.state = .ClosingConnection;
                        self.op = .close;
                        _ = try ring.close(@intFromPtr(self), self.fd);

                        break :err_blk;
                    };
                    self.peer = Peer.init(peer_addr);

                    log.info(
                        "Attempting another peer: {f} @ fd {d}.",
                        .{ self.peer.?.addr, self.fd },
                    );

                    self.op = .connect;
                    _ = try ring.connect(
                        @intFromPtr(self),
                        self.fd,
                        @ptrCast(&self.peer.?.addr_in),
                        @sizeOf(@TypeOf(self.peer.?.addr_in)),
                    );
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            else => return errorInvalidOp(self.state, self.op),
        },

        .Handshaking => switch (self.op) {
            .send => switch (err) {
                .SUCCESS => {
                    self.op = .recv;
                    _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            .recv => switch (err) {
                .SUCCESS => recv_blk: {
                    self.recv_buf.initReader(@intCast(res));
                    const bytes: []const u8 = self.recv_buf.getRemainingBytes() catch |e| switch (e) {
                        error.NoMoreBytesLeft => {
                            std.debug.print(
                                "Recived {d} bytes. Closing {f} @ fd {d}.\n",
                                .{ res, self.peer.?.addr, self.fd },
                            );

                            self.state = .ClosingConnection;
                            self.op = .close;
                            _ = try ring.close(@intFromPtr(self), self.fd);

                            break :recv_blk;
                        },
                    };

                    log.info(
                        "Received {d} bytes from {f} @ fd {d}.",
                        .{ self.recv_buf.n_read, self.peer.?.addr, self.fd },
                    );

                    std.debug.print("bytes:\n{any}\n\n", .{bytes});

                    if (bytes.len < 4) {
                        std.debug.print(
                            "Didn't receive enough bytes. Closing {f} @ fd {d}.\n",
                            .{ self.peer.?.addr, self.fd },
                        );

                        self.state = .ClosingConnection;
                        self.op = .close;
                        _ = try ring.close(@intFromPtr(self), self.fd);

                        break :recv_blk;
                    }

                    if (isKeepAliveMsg(bytes)) {
                        if (self.ka_cnt >= MAX_KEEPALIVES) {
                            log.info(
                                "Received too many keep-alive msgs from {f} @ fd {d}. Closing connection.",
                                .{ self.peer.?.addr, self.fd },
                            );

                            self.state = .ClosingConnection;
                            self.op = .close;
                            _ = try ring.close(@intFromPtr(self), self.fd);

                            break :recv_blk;
                        }

                        log.info(
                            "Received keep-alive msg from {f} @ fd {d}. Waiting for more bytes.",
                            .{ self.peer.?.addr, self.fd },
                        );

                        self.ka_cnt += 1;

                        self.op = .recv;
                        _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);

                        break :recv_blk;
                    } else self.ka_cnt = 0;

                    const ans: bool = tcp.isAnsValid(bytes, info_hash);

                    log.info("Valid ans: {}\n", .{ans});

                    if (!ans) {
                        self.state = .ClosingConnection;
                        self.op = .close;
                        _ = try ring.close(@intFromPtr(self), self.fd);

                        break :recv_blk;
                    }

                    if (bytes.len == 68) { // We received only the hanshake ans
                        std.debug.print("No more bytes left. Asking for more.\n", .{});

                        // TODO: Fix memory issue here!
                        const msg = tcp.Msg.interested();
                        var msg_bytes: [msg.len()]u8 = undefined;
                        try msg.serialize(&msg_bytes);
                        std.debug.print(
                            "Sending interested msg to {f} @ fd {d}: {any}.\n",
                            .{ self.peer.?.addr, self.fd, msg_bytes },
                        );

                        self.state = .ExpectingBitfieldMsg;
                        self.op = .send;
                        _ = try ring.send(@intFromPtr(self), self.fd, &msg_bytes, 0);

                        break :recv_blk;
                    }

                    // If we received more bytes...

                    self.recv_buf.i += 68;
                    self.state = .ExpectingBitfieldMsg;
                    self.op = .none;

                    continue :state_sw .ExpectingBitfieldMsg;
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            else => return errorInvalidOp(self.state, self.op),
        },

        .ExpectingBitfieldMsg => switch (self.op) {
            .none => none_blk: {
                const bytes: []const u8 = try self.recv_buf.getRemainingBytes();
                std.debug.print("remaining bytes:\n{any}\n\n", .{bytes});

                const msg_length: u32 = tcp.Msg.decodeLengthPrefix(bytes[0..4]);
                std.debug.print("msg_length: {d}\n", .{msg_length});

                if (bytes.len < msg_length + 4) {
                    log.info(
                        "Didn't understand: {any}.\nClosing {f} @ fd {d}.",
                        .{ bytes, self.peer.?.addr, self.fd },
                    );

                    self.state = .ClosingConnection;
                    self.op = .close;
                    _ = try ring.close(@intFromPtr(self), self.fd);

                    break :none_blk;
                }

                const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
                    error.UnknownMsgId => {
                        log.info(
                            "Message Id {d} not recognized in {any}.\n",
                            .{ bytes[4], bytes[0..5] },
                        );

                        self.state = .ClosingConnection;
                        self.op = .close;
                        _ = try ring.close(@intFromPtr(self), self.fd);

                        break :none_blk;
                    },

                    else => return e,
                };

                std.debug.print("msg: {}\n\n", .{msg});
                std.debug.print("msg len: {}\n\n", .{msg.len()});

                if (msg.id == .Bitfield) {
                    const bitfield: []u8 = try gpa.alloc(u8, msg.payload.len);
                    @memcpy(bitfield, msg.payload);
                    self.peer.?.bf = bitfield;
                }

                self.recv_buf.i += msg.len();

                if (self.recv_buf.remainingBytes() <= 0) {
                    log.info(
                        "No more bytes left. Waiting for unchoke msg from {f} @ fd {d}.",
                        .{ self.peer.?.addr, self.fd },
                    );

                    self.op = .recv;
                    self.state = .ExpectingUnChokeMsg;
                    _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);

                    break :none_blk;
                }

                self.state = .ExpectingUnChokeMsg;
                continue :state_sw .ExpectingUnChokeMsg;
            },

            .send => switch (err) {
                .SUCCESS => {
                    self.op = .recv;
                    _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            else => return errorInvalidOp(self.state, self.op),
        },

        .ExpectingUnChokeMsg => unchoke_blk: {
            switch (self.op) {
                .recv => self.recv_buf.initReader(@intCast(res)),
                .none => {},
                else => return errorInvalidOp(self.state, self.op),
            }

            const bytes: []const u8 = try self.recv_buf.getRemainingBytes();
            log.info("remaining bytes:\n{any}\n", .{bytes});

            const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
                error.UnknownMsgId => {
                    log.info("Message Id {} not recognized.", .{bytes[4]});

                    self.state = .ClosingConnection;
                    self.op = .close;
                    _ = try ring.close(@intFromPtr(self), self.fd);

                    break :unchoke_blk;
                },

                else => return e,
            };

            std.debug.print("msg: {}\n\n", .{msg});

            if (msg.id != .Unchoke) {
                log.info(
                    "Hmm, was expecting an unchoke msg from {f} @ fd {d}." ++
                        " Received instead: {any}.\nClosing the connection.",
                    .{ self.peer.?.addr, self.fd, msg },
                );

                self.state = .ClosingConnection;
                self.op = .close;
                _ = try ring.close(@intFromPtr(self), self.fd);

                break :unchoke_blk;
            }

            log.info(
                "Received unchoke msg from {f} @ fd {d}.",
                .{ self.peer.?.addr, self.fd },
            );

            const piece_index: u32 = pieces.pop() orelse {
                log.info("No more pieces. Closing connection.", .{});

                self.state = .ClosingConnection;
                self.op = .close;
                _ = try ring.close(@intFromPtr(self), self.fd);

                // Acá debería hacer pending.* -= 1?

                break :unchoke_blk;
            };

            var payload: [12]u8 = undefined;
            const outMsg = tcp.Msg.request(piece_index, 0, BLOCK_SIZE, &payload);
            var msg_bytes: [17]u8 = undefined;
            try outMsg.serialize(&msg_bytes);
            std.debug.print(
                "Sending request msg to {f} @ fd {d}: {any}.\n",
                .{ self.peer.?.addr, self.fd, msg_bytes },
            );

            self.piece = Piece{ .index = piece_index, .i = 0 };
            self.state = .Downloading;
            self.op = .send;
            _ = try ring.send(@intFromPtr(self), self.fd, &msg_bytes, 0);
        },

        .Downloading => switch (self.op) {
            .send => switch (err) {
                .SUCCESS => {
                    self.op = .recv;
                    _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            .recv => switch (err) {
                .SUCCESS => recv_blk: {
                    self.recv_buf.initReader(@intCast(res));
                    const bytes: []const u8 = try self.recv_buf.getRemainingBytes();
                    log.info("Downloading. Received {d} bytes:\n{any}", .{ bytes.len, bytes });

                    const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
                        error.UnknownMsgId => {
                            log.info("Message Id {} not recognized.", .{bytes[4]});

                            self.state = .ClosingConnection;
                            self.op = .close;
                            _ = try ring.close(@intFromPtr(self), self.fd);

                            break :recv_blk;
                        },

                        else => return e,
                    };

                    switch (msg.id) {
                        .Unchoke => {
                            log.info("Received unchoke msg. Waiting for more bytes.", .{});

                            self.op = .recv;
                            _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);

                            break :recv_blk;
                        },

                        else => {
                            log.info("Received {t} msg.", .{msg.id});
                        },
                    }
                },

                else => try self.closeConnectionOnError(ring, err),
            },

            else => return errorInvalidOp(self.state, self.op),
        },

        .ClosingConnection => switch (self.op) {
            .close => close_blk: switch (err) {
                .SUCCESS => {
                    log.info("Successfully closed fd {d}.", .{self.fd});

                    self.peer.?.deinit(gpa);

                    const peer_addr: Ip4Address = peers.next() orelse {
                        self.state = .Off;
                        pending.* -= 1;
                        break :close_blk;
                    };

                    self.fd = -1;
                    self.ka_cnt = 0;
                    self.peer = Peer.init(peer_addr);
                    self.state = .Connecting;
                    self.op = .socket;

                    _ = try ring.socket(
                        @intFromPtr(self),
                        linux.AF.INET,
                        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
                        posix.IPPROTO.TCP,
                        0,
                    );
                },

                else => {
                    log.info("Error {t} while closing fd {d}.", .{ err, self.fd });
                    return error.ErrorOnCloseFd;
                },
            },

            else => return errorInvalidOp(self.state, self.op),
        },

        .Idle => switch (self.op) {
            else => return errorInvalidOp(self.state, self.op),
        },

        .Off => switch (self.op) {
            else => return errorInvalidOp(self.state, self.op),
        },
    }
}

fn errorInvalidOp(state: State, op: Operation) error{InvalidOperation} {
    log.err("Invalid operation {t} for state {t}.", .{ op, state });
    return error.InvalidOperation;
}

fn isKeepAliveMsg(bytes: []const u8) bool {
    return (bytes.len >= 4 and bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0);
}

fn closeConnectionOnError(self: *Client, ring: *IoUring, err: linux.E) !void {
    log.info(
        "{f} @ fd {d}: {t} op returned error {t}. Closing connection.",
        .{ self.peer.?.addr, self.fd, self.op, err },
    );

    self.state = .ClosingConnection;
    self.op = .close;
    _ = try ring.close(@intFromPtr(self), self.fd);
}
