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

const BUFFER_LENGTH = 512;

const Peer = struct {
    ip: [4]u8,
    port: u16,

    fn address(self: Peer) std.net.Address {
        return std.net.Address.initIp4(self.ip, self.port);
    }
};

const RecvData = struct {
    fd: i32,
    buffer: []u8,
};

const Event = union(enum) {
    SOCKET: Peer,
    CONNECT: i32,
    SEND: i32,
    RECV: RecvData,
    CLOSE: i32,
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
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var eventPool = EventPool.init(allocator);
    defer eventPool.deinit();

    const buffer: []const u8 = try utils.readFile(
        allocator,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer allocator.free(buffer);

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

    var torrentFileParser = Parser.init(buffer);
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

    const body = try http.requestPeers(allocator, .{
        .announce = torrentFile.announce,
        .peer_id = peer_id,
        .info_hash = torrentFile.info_hash,
        .port = 6882,
        .uploaded = 0,
        .downloaded = 0,
        .compact = 1,
        .left = torrentInfo.length,
    });
    defer allocator.free(body);

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

    // Download from Peers

    const handshake: []const u8 = try std.fmt.allocPrint(
        allocator,
        "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00{s}{s}",
        .{ torrentFile.info_hash, "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14" },
    );
    defer allocator.free(handshake);

    std.debug.print("Creating sockets...\n\n", .{});

    for (0..n_conns) |n| {
        const peers: []const u8 = trackerResponse.peers;
        const i = n * 6;

        const peer = Peer{
            .ip = peers[i .. i + 4][0..4].*,
            .port = (@as(u16, peers[i + 4]) << 8) | @as(u16, peers[i + 5]),
        };

        const event: *Event = try eventPool.create();
        event.* = Event{ .SOCKET = peer };

        _ = try ring.socket(
            @intFromPtr(event),
            linux.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
            0,
        );
    }

    _ = try ring.submit_and_wait(n_conns);

    while (ring.cq_ready() > 0) {
        const cqe: linux.io_uring_cqe = try ring.copy_cqe();
        const event: *Event = @ptrFromInt(cqe.user_data);

        switch (event.*) {
            .SOCKET => |peer| switch (cqe.err()) {
                .SUCCESS => {
                    const fd: i32 = cqe.res;
                    const addr: std.net.Address = peer.address();

                    std.debug.print("fd {d:>2} @ {}\n", .{ @as(u16, @intCast(fd)), addr });

                    event.* = Event{ .CONNECT = fd };

                    _ = try ring.connect(@intFromPtr(event), fd, &addr.any, addr.getOsSockLen());
                },

                else => |err| {
                    std.debug.print(
                        "Creation of socket for peer {} failed with error {s}\n",
                        .{ peer.address(), @tagName(err) },
                    );
                    eventPool.destroy(event);
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
            const event: *Event = @ptrFromInt(cqe.user_data);

            switch (event.*) {
                .SOCKET => return error.UnexepectedEvent,

                .CONNECT => |fd| switch (cqe.err()) {
                    .SUCCESS => {
                        std.debug.print("Connected to fd {}, sending handshake...\n", .{fd});

                        event.* = Event{ .SEND = fd };
                        _ = try ring.send(@intFromPtr(event), fd, handshake, 0);

                        n += 1;
                    },

                    else => |err| {
                        std.debug.print(
                            "Connection with fd {} returned error {s}\n",
                            .{ fd, @tagName(err) },
                        );

                        event.* = Event{ .CLOSE = fd };
                        _ = try ring.close(@intFromPtr(event), fd);

                        n += 1;
                    },
                },

                .SEND => |fd| {
                    const recv_buffer: []u8 = try allocator.alloc(u8, BUFFER_LENGTH);

                    event.* = Event{
                        .RECV = RecvData{ .fd = fd, .buffer = recv_buffer },
                    };

                    _ = try ring.recv(@intFromPtr(event), fd, .{ .buffer = recv_buffer }, 0);

                    n += 1;
                },

                .RECV => |data| {
                    switch (cqe.err()) {
                        .SUCCESS => {
                            const n_read: usize = @intCast(cqe.res);
                            std.debug.print(
                                "Received {} bytes from fd {}: '{any}'\n",
                                .{ n_read, data.fd, data.buffer[0..n_read] },
                            );
                        },

                        else => |err| std.debug.print(
                            "Recv from fd {} returned error {s}\n",
                            .{ data.fd, @tagName(err) },
                        ),
                    }

                    allocator.free(data.buffer);

                    event.* = Event{ .CLOSE = data.fd };
                    _ = try ring.close(@intFromPtr(event), data.fd);

                    n += 1;
                },

                .CLOSE => |fd| {
                    std.debug.print("Closed fd {}\n", .{fd});
                    eventPool.destroy(event);
                },
            }
        }
    }

    std.debug.print("\nAll done!\n", .{});
}
