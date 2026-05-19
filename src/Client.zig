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
    Off,
};

const Operation = enum {
    socket,
    connect,
    send,
    recv,
    close,
    none,
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

    fn getRemainingBytes(self: RecvBuf) ?[]const u8 {
        if (self.remainingBytes() <= 0) return null;

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
send_buf: ?[]const u8,
recv_buf: RecvBuf,
piece_buf: []u8,

fn freeSendBuf(self: *Client, gpa: Allocator) void {
    gpa.free(self.send_buf.?);
    self.send_buf = null;
}

pub fn init(peer_addr: Ip4Address, recv_buf: []u8, piece_buf: []u8) Client {
    return Client{
        .fd = -1,
        .ka_cnt = 0,
        .state = .Connecting,
        .op = .socket,
        .peer = Peer.init(peer_addr),
        .piece = null,
        .send_buf = null,
        .recv_buf = RecvBuf.init(recv_buf),
        .piece_buf = piece_buf,
    };
}

pub fn deinit(self: *Client, gpa: Allocator) void {
    if (self.peer) |*peer| peer.deinit(gpa);
    if (self.send_buf) |_| self.freeSendBuf(gpa);
}

pub fn handleEvent(
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
    sw: switch (self.state) {
        .Connecting => try self.handleConnecting(gpa, ring, pending, info_hash, peers, err, res),
        .Handshaking => if (try self.handleHandshaking(gpa, ring, info_hash, err, res)) |next| continue :sw next,
        .ExpectingBitfieldMsg => try self.handleExpectingBitfieldMsg(gpa, ring, err, res),
        .ExpectingUnChokeMsg => try self.handleExpectingUnChokeMsg(gpa, ring, pieces, err, res),
        .Downloading => try self.handleDownloading(gpa, ring, err, res),
        .ClosingConnection => try self.handleClosingConnection(gpa, ring, pending, peers, err),
        .Off => return errorInvalidOp(self.state, self.op),
    }
}

fn errorInvalidOp(state: State, op: Operation) error{InvalidOperation} {
    log.err("Invalid operation {t} for state {t}.", .{ op, state });
    return error.InvalidOperation;
}

fn isKeepAliveMsg(bytes: []const u8) bool {
    return (bytes.len >= 4 and bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0);
}

fn logErrorAndQueueCloseOp(self: *Client, ring: *IoUring, err: linux.E) error{SubmissionQueueFull}!void {
    log.info(
        "{f} @ fd {d}: {t} op returned error {t}. Closing connection.",
        .{ self.peer.?.addr, self.fd, self.op, err },
    );
    try self.queueCloseOp(ring);
}

// --- Queue Ops ---

fn queueConnectOp(self: *Client, ring: *IoUring, new_state: ?State) error{SubmissionQueueFull}!void {
    if (new_state) |state| self.state = state;
    self.op = .connect;
    _ = try ring.connect(
        @intFromPtr(self),
        self.fd,
        @ptrCast(&self.peer.?.addr_in),
        @sizeOf(@TypeOf(self.peer.?.addr_in)),
    );
}

fn queueRecvOp(self: *Client, ring: *IoUring, new_state: ?State) error{SubmissionQueueFull}!void {
    if (new_state) |state| self.state = state;
    self.op = .recv;
    _ = try ring.recv(@intFromPtr(self), self.fd, .{ .buffer = self.recv_buf.buf }, 0);
}

fn queueSendOp(self: *Client, ring: *IoUring, bytes: []const u8, new_state: ?State) error{SubmissionQueueFull}!void {
    if (new_state) |state| self.state = state;
    self.send_buf = bytes;
    self.op = .send;
    _ = try ring.send(@intFromPtr(self), self.fd, self.send_buf.?, 0);
}

fn queueCloseOp(self: *Client, ring: *IoUring) error{SubmissionQueueFull}!void {
    self.state = .ClosingConnection;
    self.op = .close;
    _ = try ring.close(@intFromPtr(self), self.fd);
}

// --- Handlers ---

fn handleConnecting(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    pending: *i32,
    info_hash: *const [20]u8,
    peers: *tcp.PeersIterator,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
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

                try self.queueConnectOp(ring, null);
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

                const hs = tcp.Handshake{
                    .info_hash = info_hash,
                    .peer_id = &utils.range(1, 21), // Poner un peer_id de verdad
                };

                const handshake: []const u8 = try hs.serialize(gpa);

                try self.queueSendOp(ring, handshake, .Handshaking);
            },

            .CONNREFUSED, .TIMEDOUT, .HOSTUNREACH => {
                log.info(
                    "Connection with {f} @ fd {d} returned {t}.",
                    .{ self.peer.?.addr, self.fd, err },
                );

                const peer_addr: Ip4Address = peers.next() orelse {
                    log.info("No more peers. Shutting down.", .{});
                    try self.queueCloseOp(ring);
                    return;
                };
                self.peer = Peer.init(peer_addr);

                log.info(
                    "Attempting another peer: {f} @ fd {d}.",
                    .{ self.peer.?.addr, self.fd },
                );

                try self.queueConnectOp(ring, null);
            },

            else => try self.logErrorAndQueueCloseOp(ring, err),
        },

        else => return errorInvalidOp(self.state, self.op),
    }
}

fn handleHandshaking(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    info_hash: *const [20]u8,
    err: linux.E,
    res: i32,
) !?State {
    return sw: switch (self.op) {
        .send => switch (err) {
            .SUCCESS => {
                self.freeSendBuf(gpa);
                try self.queueRecvOp(ring, null);
                break :sw null;
            },

            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                break :sw null;
            },
        },

        .recv => switch (err) {
            .SUCCESS => {
                self.recv_buf.initReader(@intCast(res));
                const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse {
                    std.debug.print(
                        "Recived {d} bytes. Closing {f} @ fd {d}.\n",
                        .{ res, self.peer.?.addr, self.fd },
                    );
                    try self.queueCloseOp(ring);
                    break :sw null;
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
                    try self.queueCloseOp(ring);
                    break :sw null;
                }

                if (isKeepAliveMsg(bytes)) {
                    if (self.ka_cnt >= MAX_KEEPALIVES) {
                        log.info(
                            "Received too many keep-alive msgs from {f} @ fd {d}. Closing connection.",
                            .{ self.peer.?.addr, self.fd },
                        );
                        try self.queueCloseOp(ring);
                        break :sw null;
                    }

                    log.info(
                        "Received keep-alive msg from {f} @ fd {d}. Waiting for more bytes.",
                        .{ self.peer.?.addr, self.fd },
                    );
                    self.ka_cnt += 1;
                    try self.queueRecvOp(ring, null);
                    break :sw null;
                } else self.ka_cnt = 0;

                const ans: bool = tcp.isAnsValid(bytes, info_hash);

                log.info("Valid ans: {}\n", .{ans});
                if (!ans) {
                    try self.queueCloseOp(ring);
                    break :sw null;
                }

                if (bytes.len == 68) { // We received only the hanshake ans
                    std.debug.print("No more bytes left. Asking for more.\n", .{});

                    const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
                    std.debug.print(
                        "Sending interested msg to {f} @ fd {d}: {any}.\n",
                        .{ self.peer.?.addr, self.fd, msg_interested },
                    );
                    try self.queueSendOp(ring, msg_interested, .ExpectingBitfieldMsg);

                    break :sw null;
                }

                // If we received more bytes...

                self.recv_buf.i += 68;
                self.state = .ExpectingBitfieldMsg;
                self.op = .none;

                break :sw .ExpectingBitfieldMsg;
            },

            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                break :sw null;
            },
        },

        else => break :sw errorInvalidOp(self.state, self.op),
    };
}

fn handleExpectingBitfieldMsg(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .send => switch (err) {
            .SUCCESS => {
                self.freeSendBuf(gpa);
                try self.queueRecvOp(ring, null);
                return;
            },
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse return error.NoMoreBytesLeft;
    std.debug.print("remaining bytes:\n{any}\n\n", .{bytes});

    const msg_length: u32 = tcp.Msg.decodeLengthPrefix(bytes[0..4]);
    std.debug.print("msg_length: {d}\n", .{msg_length});

    if (bytes.len < msg_length + 4) {
        log.info(
            "Didn't understand: {any}.\nClosing {f} @ fd {d}.",
            .{ bytes, self.peer.?.addr, self.fd },
        );
        try self.queueCloseOp(ring);
        return;
    }

    const msg1 = tcp.Msg.decode(bytes) catch |e| switch (e) {
        error.UnknownMsgId => {
            log.info(
                "Message Id {d} not recognized in {any}.\n",
                .{ bytes[4], bytes[0..5] },
            );
            try self.queueCloseOp(ring);
            return;
        },

        else => return e,
    };

    std.debug.print("msg: {}\n\n", .{msg1});
    std.debug.print("msg len: {}\n\n", .{msg1.len()});

    if (msg1.id == .Bitfield) {
        const bitfield: []u8 = try gpa.alloc(u8, msg1.payload.len);
        @memcpy(bitfield, msg1.payload);
        self.peer.?.bf = bitfield;
    }

    self.recv_buf.i += msg1.len();

    const rem_bytes = self.recv_buf.getRemainingBytes() orelse {
        // Si no hay más bytes le mando interested
        const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
        std.debug.print(
            "Sending interested msg to {f} @ fd {d}: {any}.\n",
            .{ self.peer.?.addr, self.fd, msg_interested },
        );
        try self.queueSendOp(ring, msg_interested, .ExpectingUnChokeMsg);
        return;
    };

    log.info("rem_bytes:\n{any}\n", .{rem_bytes});

    const msg2 = tcp.Msg.decode(rem_bytes) catch |e| switch (e) {
        error.UnknownMsgId => {
            log.info("Message Id {} not recognized.", .{rem_bytes[4]});
            try self.queueCloseOp(ring);
            return;
        },

        else => return e,
    };

    std.debug.print("msg2: {}\n\n", .{msg2});

    if (msg2.id != .Unchoke) {
        log.info(
            "Hmm, was expecting an unchoke msg from {f} @ fd {d}." ++
                " Received instead: {any}.\nClosing the connection.",
            .{ self.peer.?.addr, self.fd, msg2 },
        );
        try self.queueCloseOp(ring);
        return;
    }

    log.info(
        "Received unchoke msg from {f} @ fd {d}.",
        .{ self.peer.?.addr, self.fd },
    );

    const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
    std.debug.print(
        "Sending interested msg to {f} @ fd {d}: {any}.\n",
        .{ self.peer.?.addr, self.fd, msg_interested },
    );

    try self.queueSendOp(ring, msg_interested, .ExpectingUnChokeMsg);
    return;
}

fn handleExpectingUnChokeMsg(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    pieces: *UIntStack,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .send => switch (err) {
            .SUCCESS => {
                self.freeSendBuf(gpa);
                try self.queueRecvOp(ring, null);
                return;
            },
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse return error.NoMoreBytesLeft;
    log.info("remaining bytes:\n{any}\n", .{bytes});

    const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
        error.UnknownMsgId => {
            log.info("Message Id {} not recognized.", .{bytes[4]});
            try self.queueCloseOp(ring);
            return;
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
        try self.queueCloseOp(ring);
        return;
    }

    log.info(
        "Received unchoke msg from {f} @ fd {d}.",
        .{ self.peer.?.addr, self.fd },
    );

    const piece_index: u32 = pieces.pop() orelse {
        log.info("No more pieces. Closing connection.", .{});
        try self.queueCloseOp(ring);

        // Acá debería hacer pending.* -= 1 ?

        return;
    };

    self.piece = Piece{ .index = piece_index, .i = 0 };

    var payload: [tcp.Msg.REQUEST_BYTES_LEN]u8 = undefined;
    const msg_bytes: []const u8 =
        try tcp.Msg.request(piece_index, 0, BLOCK_SIZE, &payload).serializeAlloc(gpa);
    std.debug.print(
        "Sending request msg to {f} @ fd {d}: {any}.\n",
        .{ self.peer.?.addr, self.fd, msg_bytes },
    );

    try self.queueSendOp(ring, msg_bytes, .Downloading);
    return;
}

fn handleDownloading(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .send => switch (err) {
            .SUCCESS => {
                self.freeSendBuf(gpa);
                try self.queueRecvOp(ring, null);
                return;
            },
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => return self.logErrorAndQueueCloseOp(ring, err),
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse return error.NoMoreBytesLeft;
    log.info("Downloading. Received {d} bytes:\n{any}", .{ bytes.len, bytes });

    const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
        error.UnknownMsgId => {
            log.info("Message Id {} not recognized. Closing connection", .{bytes[4]});
            try self.queueCloseOp(ring);
            return;
        },

        else => return e,
    };

    switch (msg.id) {
        .Unchoke => {
            log.info("Received unchoke msg. Waiting for more bytes.", .{});
            try self.queueRecvOp(ring, null);
            return;
        },

        else => {
            log.info("Received {t} msg.", .{msg.id});
        },
    }
}

fn handleClosingConnection(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    pending: *i32,
    peers: *tcp.PeersIterator,
    err: linux.E,
) !void {
    switch (self.op) {
        .close => switch (err) {
            .SUCCESS => {
                log.info("Successfully closed fd {d}.", .{self.fd});

                self.peer.?.deinit(gpa);

                const peer_addr: Ip4Address = peers.next() orelse {
                    self.state = .Off;
                    pending.* -= 1;
                    return;
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
    }
}
