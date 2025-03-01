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

const Peer = struct {
    ip: [4]u8,
    port: u16,

    fn address(self: Peer) std.net.Address {
        return std.net.Address.initIp4(self.ip, self.port);
    }

    pub fn format(
        self: Peer,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(
            out_stream,
            "{}.{}.{}.{}:{}",
            .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port },
        );
    }
};

const RecvData = struct {
    fd: i32,
    buffer: []u8,
};

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
    peer: Peer,
    buffer: ?[]const u8,

    fn freeBuffer(self: *Ctx, allocator: std.mem.Allocator) void {
        if (self.buffer) |buffer| {
            allocator.free(buffer);
            self.buffer = null;
        }
    }
};

const EventPool = std.heap.MemoryPool(Event);

const MsgId = enum(u8) {
    Choke = 0,
    Unchoke = 1,
    Interested = 2,
    NotInterested = 3,
    Have = 4,
    Bitfield = 5,
    Request = 6,
    Piece = 7,
    Cancel = 8,
};

const Msg = struct {
    id: MsgId,
    payload: []const u8,
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

    if (trackerResponse.peers.len % 6 != 0) return error.MalformedPeersList;
    // const n_conns: u16 = @as(u16, @intCast(trackerResponse.peers.len / 6));
    const n_conns: u16 = 8;

    const entries: u16 = try std.math.ceilPowerOfTwo(u16, 4 * n_conns);

    var ring: IoUring = try IoUring.init(entries, 0);
    defer ring.deinit();

    var ctxs_array: [n_conns]Ctx = undefined;

    // Download from Peers

    const handshake: []const u8 = try std.fmt.allocPrint(
        gpa,
        "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00{s}{s}",
        .{ torrentFile.info_hash, "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14" },
    );
    defer gpa.free(handshake);

    std.debug.print("Creating sockets...\n\n", .{});

    for (0..n_conns) |n| {
        const peers: []const u8 = trackerResponse.peers;
        const i = n * 6;

        const peer = Peer{
            .ip = peers[i .. i + 4][0..4].*,
            .port = (@as(u16, peers[i + 4]) << 8) | @as(u16, peers[i + 5]),
        };

        ctxs_array[n] = Ctx{
            .event = .SOCKET,
            .fd = -1,
            .peer = peer,
            .buffer = null,
        };

        _ = try ring.socket(
            @intFromPtr(&ctxs_array[n]),
            linux.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
            0,
        );
    }

    _ = try ring.submit_and_wait(n_conns);

    while (ring.cq_ready() > 0) {
        const cqe: linux.io_uring_cqe = try ring.copy_cqe();
        const ctx: *Ctx = @ptrFromInt(cqe.user_data);

        switch (ctx.event) {
            .SOCKET => switch (cqe.err()) {
                .SUCCESS => {
                    const fd: i32 = cqe.res;
                    ctx.fd = fd;

                    const addr: std.net.Address = ctx.peer.address();

                    std.debug.print("fd {d:>2} @ {}\n", .{ @as(u16, @intCast(fd)), addr });

                    ctx.event = .CONNECT;

                    _ = try ring.connect(@intFromPtr(ctx), fd, &addr.any, addr.getOsSockLen());
                },

                else => |err| {
                    std.debug.print(
                        "Create socket for peer {} failed with error {s}\n",
                        .{ ctx.peer, @tagName(err) },
                    );
                },
            },

            else => return error.UnexepectedEvent,
        }
    }

    std.debug.print("\nConnecting to peers...\n\n", .{});

    var n: i32 = n_conns;
    while (n > 0) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) : (n -= 1) {
            const cqe: linux.io_uring_cqe = try ring.copy_cqe();
            const ctx: *Ctx = @ptrFromInt(cqe.user_data);

            switch (ctx.event) {
                .SOCKET => return error.UnexepectedEvent,

                .CONNECT => switch (cqe.err()) {
                    .SUCCESS => {
                        std.debug.print("Connected to fd {} @ {}, sending handshake...\n", .{ ctx.fd, ctx.peer });

                        ctx.event = .SEND;
                        _ = try ring.send(@intFromPtr(ctx), ctx.fd, handshake, 0);

                        n += 1;
                    },

                    else => |err| {
                        std.debug.print(
                            "Connection with fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                        n += 1;
                    },
                },

                .SEND => switch (cqe.err()) {
                    .SUCCESS => {
                        const buffer: []u8 = try gpa.alloc(u8, BUFFER_SIZE);

                        ctx.event = .RECV;
                        ctx.buffer = buffer;

                        _ = try ring.recv(@intFromPtr(ctx), ctx.fd, .{ .buffer = buffer }, 0);

                        n += 1;
                    },

                    else => |err| {
                        std.debug.print(
                            "Send to fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        );

                        ctx.event = .CLOSE;
                        _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                        n += 1;
                    },
                },

                .RECV => {
                    switch (cqe.err()) {
                        .SUCCESS => {
                            const n_read: usize = @intCast(cqe.res);
                            const ans: []const u8 = ctx.buffer.?[0..n_read];

                            std.debug.print(
                                "Received {} bytes from fd {} @ {}: '{any}'\n",
                                .{ n_read, ctx.fd, ctx.peer, ans },
                            );

                            std.debug.print("Valid: {}\n", .{tcp.validateAnswer(ans, torrentFile.info_hash)});
                        },

                        else => |err| std.debug.print(
                            "Recv from fd {} @ {} returned error {s}\n",
                            .{ ctx.fd, ctx.peer, @tagName(err) },
                        ),
                    }

                    ctx.freeBuffer(gpa);

                    ctx.event = .CLOSE;
                    _ = try ring.close(@intFromPtr(ctx), ctx.fd);

                    n += 1;
                },

                .CLOSE => {
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

                    if (ctx.buffer) |buffer| {
                        gpa.free(buffer);
                        ctx.buffer = null;
                    }
                },
            }
        }
    }

    std.debug.print("\nAll done!\n", .{});
}
