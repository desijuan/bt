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
    Choked,
    Downloading,
    ClosingConnection,
    ShuttingDown,
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

pub fn init(recv_buf: []u8, piece_buf: []u8) Client {
    return Client{
        .fd = -1,
        .ka_cnt = 0,
        .state = .Off,
        .op = .none,
        .peer = null,
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
    unchokes: *u32,
    info_hash: *const [20]u8,
    peers: *tcp.PeersIterator,
    pieces: *UIntStack,
) !void {
    return sw: switch (self.state) {
        .Connecting => try self.hConnecting(gpa, ring, info_hash, peers, err, res),
        .Handshaking => if (try self.hHandshaking(gpa, ring, info_hash, err, res)) |next| continue :sw next,
        .ExpectingBitfieldMsg => if (try self.hExpectingBitfieldMsg(gpa, ring, err, res)) |next| continue :sw next,
        .Choked => try self.hChoked(gpa, ring, pieces, err, res),
        .Downloading => try self.hDownloading(gpa, ring, unchokes, err, res),
        .ClosingConnection => if (try self.hClosingConnection(gpa, ring, peers, err)) |next| continue :sw next,
        .ShuttingDown => try self.hShuttingDown(gpa, pending, err),
        .Off => errorInvalidOp(self.state, self.op),
    };
}

// --- Helper fns ---

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
    try self.queueCloseOp(ring, null);
}

// --- Queue Ops ---

pub fn queueSocketOp(self: *Client, ring: *IoUring, peer_addr: Ip4Address) !void {
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
}

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

fn queueCloseOp(self: *Client, ring: *IoUring, new_state: ?State) error{SubmissionQueueFull}!void {
    self.state = if (new_state) |state| state else .ClosingConnection;
    self.op = .close;
    _ = try ring.close(@intFromPtr(self), self.fd);
}

// --- Handlers ---

fn hConnecting(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    info_hash: *const [20]u8,
    peers: *tcp.PeersIterator,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .socket => switch (err) {
            .SUCCESS => {
                self.fd = res;
                log.info("Succesfully created socket. Connecting to {f} @ fd {d}.", .{ self.peer.?.addr, self.fd });
                try posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, std.mem.asBytes(&TIMEOUT_MS));
                try self.queueConnectOp(ring, null);
                return;
            },

            else => {
                log.err("Creation of socket failed with error {t}.", .{err});
                return error.SocketCreationFailed;
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
                return;
            },

            .CONNREFUSED, .TIMEDOUT, .HOSTUNREACH => {
                log.info(
                    "Connection with {f} @ fd {d} returned {t}. Attempting another peer",
                    .{ self.peer.?.addr, self.fd, err },
                );
                const peer_addr: Ip4Address = peers.next() orelse {
                    log.info("No more peers. Closing fd {d}.", .{self.fd});
                    try self.queueCloseOp(ring, null);
                    return;
                };
                self.peer = Peer.init(peer_addr);
                log.info(
                    "Attempting peer: {f} @ fd {d}.",
                    .{ self.peer.?.addr, self.fd },
                );
                try self.queueConnectOp(ring, null);
                return;
            },

            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return;
            },
        },

        else => return errorInvalidOp(self.state, self.op),
    }
}

fn hHandshaking(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    info_hash: *const [20]u8,
    err: linux.E,
    res: i32,
) !?State {
    switch (self.op) {
        .send => {
            self.freeSendBuf(gpa);
            switch (err) {
                .SUCCESS => try self.queueRecvOp(ring, null),
                else => try self.logErrorAndQueueCloseOp(ring, err),
            }
            return null;
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return null;
            },
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse {
        log.info("Received zero bytes. Closing connection with {f} fd {d}.", .{ self.peer.?.addr, self.fd });
        try self.queueCloseOp(ring, null);
        return null;
    };
    std.debug.print("bytes:\n{any}\n", .{bytes});

    if (!tcp.isAnsValid(bytes, info_hash)) {
        log.info("Invalid handshake ans. Closing fd {d}.", .{self.fd});
        try self.queueCloseOp(ring, null);
        return null;
    }
    self.recv_buf.i += 68;
    log.info("Received valid handshake ans from {f} @ fd {d}.", .{ self.peer.?.addr, self.fd });

    if (bytes.len == 68) { // We received only the hanshake ans
        const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
        log.info(
            "No more bytes left. Asking for more. Sending interested msg to {f} @ fd {d}: {any}.",
            .{ self.peer.?.addr, self.fd, msg_interested },
        );
        try self.queueSendOp(ring, msg_interested, .ExpectingBitfieldMsg);
        return null;
    }

    // If we received more bytes --> continue to ExpectingBitfieldMsg
    self.state = .ExpectingBitfieldMsg;
    self.op = .none;
    return .ExpectingBitfieldMsg;
}

fn hExpectingBitfieldMsg(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    err: linux.E,
    res: i32,
) !?State {
    switch (self.op) {
        .send => {
            self.freeSendBuf(gpa);
            switch (err) {
                .SUCCESS => try self.queueRecvOp(ring, null),
                else => try self.logErrorAndQueueCloseOp(ring, err),
            }
            return null;
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => {
                try self.logErrorAndQueueCloseOp(ring, err);
                return null;
            },
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse {
        log.info("Received zero bytes. Closing connection with {f} fd {d}.", .{ self.peer.?.addr, self.fd });
        try self.queueCloseOp(ring, null);
        return null;
    };
    std.debug.print("bytes:\n{any}\n", .{bytes});

    const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
        error.ReceivedKeepAliveMsg => {
            log.info(
                "Received keep-alive msg from {f} @ fd {d}. Waiting for more bytes.",
                .{ self.peer.?.addr, self.fd },
            );
            self.ka_cnt += 1;
            log.info("keep-alive cnt: {d}.", .{self.ka_cnt});
            try self.queueRecvOp(ring, null);
            return null;
        },

        else => {
            log.err("Error: {t}. Closing the connection.", .{e});
            try self.queueCloseOp(ring, null);
            return null;
        },
    };
    self.recv_buf.i += msg.len();
    std.debug.print("msg: {}\n", .{msg});
    std.debug.print("msg.len(): {d}\n", .{msg.len()});

    switch (msg.id) {
        .UnChoke => {
            log.info(
                "Received unchoke msg from {f} @ fd {d}.",
                .{ self.peer.?.addr, self.fd },
            );
            // Many clients send an unchoke right after the bitfield msg,
            // we respond with interested and transition to Choked,
            const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
            std.debug.print(
                "Sending interested msg to {f} @ fd {d}: {any}.\n",
                .{ self.peer.?.addr, self.fd, msg_interested },
            );
            try self.queueSendOp(ring, msg_interested, .Choked);
            return null;
        },

        .Bitfield => {
            log.info(
                "Received bitfield msg from {f} @ fd {d}.",
                .{ self.peer.?.addr, self.fd },
            );

            // Copy peers bitfield
            const bitfield: []u8 = try gpa.alloc(u8, msg.payload.len);
            @memcpy(bitfield, msg.payload);
            self.peer.?.bf = bitfield;

            // If there are more bytes
            // ---> continue
            if (self.recv_buf.remainingBytes() > 0) {
                self.op = .none;
                return self.state;
            }

            // If there are no more bytes
            // Send interested msg
            const msg_interested: []const u8 = try tcp.Msg.interested().serializeAlloc(gpa);
            log.info(
                "Sending interested msg to {f} @ fd {d}: {any}.",
                .{ self.peer.?.addr, self.fd, msg_interested },
            );
            try self.queueSendOp(ring, msg_interested, .Choked);
            return null;
        },

        else => |msg_tag| {
            log.err("Don't know how to handle msg: {t}. Closing the connection.", .{msg_tag});
            try self.queueCloseOp(ring, null);
            return null;
        },
    }
}

fn hChoked(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    pieces: *UIntStack,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .send => {
            self.freeSendBuf(gpa);
            switch (err) {
                .SUCCESS => try self.queueRecvOp(ring, null),
                else => try self.logErrorAndQueueCloseOp(ring, err),
            }
            return;
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

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse {
        log.info("Received zero bytes. Closing connection with {f} fd {d}.", .{ self.peer.?.addr, self.fd });
        try self.queueCloseOp(ring, null);
        return;
    };
    std.debug.print("bytes:\n{any}\n", .{bytes});

    const msg = tcp.Msg.decode(bytes) catch |e| switch (e) {
        error.ReceivedKeepAliveMsg => {
            log.info(
                "Received keep-alive msg from {f} @ fd {d}. Waiting for more bytes.",
                .{ self.peer.?.addr, self.fd },
            );
            self.ka_cnt += 1;
            log.info("keep-alive cnt: {d}.", .{self.ka_cnt});
            try self.queueRecvOp(ring, null);
            return;
        },

        else => {
            log.err("Error: {t}. Closing the connection.", .{e});
            try self.queueCloseOp(ring, null);
            return;
        },
    };
    self.recv_buf.i += msg.len();
    std.debug.print("msg: {}\n", .{msg});
    std.debug.print("msg.len(): {d}\n", .{msg.len()});

    switch (msg.id) {
        .UnChoke => {
            log.info(
                "Received unchoke msg from {f} @ fd {d}.",
                .{ self.peer.?.addr, self.fd },
            );
            //
            // Pop a piece from the stack
            //
            const piece_index: u32 = pieces.pop() orelse {
                log.info("No more pieces. Closing connection.", .{});
                self.state = .ShuttingDown;
                self.op = .close;
                try self.queueCloseOp(ring, .ShuttingDown);
                return;
            };
            self.piece = Piece{ .index = piece_index, .i = 0 };
            //
            // And request it
            //
            var payload: [tcp.Msg.REQUEST_BYTES_LEN]u8 = undefined;
            const msg_req: []const u8 = try tcp.Msg.request(piece_index, 0, BLOCK_SIZE, &payload).serializeAlloc(gpa);
            log.info(
                "Sending request msg to {f} @ fd {d}: {any}.",
                .{ self.peer.?.addr, self.fd, msg_req },
            );
            try self.queueSendOp(ring, msg_req, .Downloading);
            return;
        },

        else => |msg_tag| {
            log.err("Don't know how to handle msg: {t}. Closing the connection.", .{msg_tag});
            try self.queueCloseOp(ring, null);
            return;
        },
    }
}

fn hDownloading(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    unchokes: *u32,
    err: linux.E,
    res: i32,
) !void {
    switch (self.op) {
        .send => {
            self.freeSendBuf(gpa);
            switch (err) {
                .SUCCESS => try self.queueRecvOp(ring, null),
                else => try self.logErrorAndQueueCloseOp(ring, err),
            }
            return;
        },

        .recv => switch (err) {
            .SUCCESS => self.recv_buf.initReader(@intCast(res)),
            else => return self.logErrorAndQueueCloseOp(ring, err),
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    const bytes: []const u8 = self.recv_buf.getRemainingBytes() orelse {
        log.info("Received zero bytes. Closing connection with {f} fd {d}.", .{ self.peer.?.addr, self.fd });
        try self.queueCloseOp(ring, null);
        return;
    };
    log.info("Downloading. Received {d} bytes.", .{bytes.len});

    unchokes.* += 1;

    log.info("CLOSING CONNECTION (for now).", .{});
    try self.queueCloseOp(ring, null);
    return;
}

fn hClosingConnection(
    self: *Client,
    gpa: Allocator,
    ring: *IoUring,
    peers: *tcp.PeersIterator,
    err: linux.E,
) !?State {
    switch (self.op) {
        .close => switch (err) {
            .SUCCESS => {
                log.info("Successfully closed fd {d}.", .{self.fd});
                self.peer.?.deinit(gpa);

                const peer_addr: Ip4Address = peers.next() orelse {
                    log.info("No more peers. Switching off.", .{});
                    self.state = .ShuttingDown;
                    self.op = .none;
                    return .ShuttingDown;
                };

                try self.queueSocketOp(ring, peer_addr);
                return null;
            },

            else => {
                log.info("Error {t} while closing fd {d}.", .{ err, self.fd });
                return error.ErrorOnCloseFd;
            },
        },

        else => return errorInvalidOp(self.state, self.op),
    }
}

fn hShuttingDown(
    self: *Client,
    gpa: Allocator,
    pending: *i32,
    err: linux.E,
) !void {
    switch (self.op) {
        .close => switch (err) {
            .SUCCESS => {
                log.info("Successfully closed fd {d}.", .{self.fd});
                self.peer.?.deinit(gpa);
            },

            else => {
                log.info("Error {t} while closing fd {d}.", .{ err, self.fd });
                return error.ErrorOnCloseFd;
            },
        },

        .none => {},

        else => return errorInvalidOp(self.state, self.op),
    }

    pending.* -= 1;
    self.state = .Off;
    return;
}
