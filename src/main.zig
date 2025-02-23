const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("bencode/parser.zig");
const bencode_data = @import("bencode/data.zig");
const http = @import("net/http.zig");
const tcp = @import("net/tcp.zig");

const IoUring = std.os.linux.IoUring;
const TorrentFile = bencode_data.TorrentFile;
const TorrentInfo = bencode_data.TorrentInfo;
const TrackerResponse = bencode_data.TrackerResponse;

const ETIME: i32 = @intFromEnum(std.os.linux.E.TIME);
const BUFFER_LENGTH = 512;

const RecvData = struct {
    fd: i32,
    buffer: []u8,
};

const Event = union(enum) {
    CONNECT: i32,
    SEND: i32,
    RECV: RecvData,
    CLOSE: i32,
};

const EventPool = std.heap.MemoryPool(Event);

const n_conns = 20;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var eventPool = EventPool.init(allocator);
    defer eventPool.deinit();

    var ring: IoUring = try IoUring.init(64, 0);
    defer ring.deinit();

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

    // Download from Peers

    const handshake: []const u8 = try std.fmt.allocPrint(
        allocator,
        "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00{s}{s}",
        .{ torrentFile.info_hash, peer_id },
    );
    defer allocator.free(handshake);

    std.debug.print("Queing requests:\n", .{});

    for (0..n_conns) |n| {
        const peer: std.net.Address = tcp.getNthPeer(n, trackerResponse.peers);

        const fd: i32 = try std.posix.socket(std.os.linux.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);

        std.debug.print("fd {} @ {}\n", .{ fd, peer });

        const event: *Event = try eventPool.create();
        event.* = Event{ .CONNECT = fd };

        const ts = std.os.linux.kernel_timespec{
            .tv_sec = 5,
            .tv_nsec = 0,
        };

        const sqe: *std.os.linux.io_uring_sqe = try ring.connect(@intFromPtr(event), fd, &peer.any, peer.getOsSockLen());
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;

        _ = try ring.link_timeout(@intFromPtr(event), &ts, 0);
    }

    std.debug.print("Submitting requests and waiting...\n", .{});

    var n: i8 = n_conns;
    while (n > 0) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) : (n -= 1) {
            const cqe: std.os.linux.io_uring_cqe = try ring.copy_cqe();
            const event: *Event = @ptrFromInt(cqe.user_data);

            switch (event.*) {
                .CONNECT => |fd| switch (cqe.res) {
                    0 => {
                        std.debug.print("Connected to fd {}, sending handshake...\n", .{fd});

                        event.* = Event{ .SEND = fd };
                        _ = try ring.send(@intFromPtr(event), fd, handshake, 0);

                        n += 1;
                    },

                    -ETIME => {
                        std.debug.print("Connection with fd {} timed out!\n", .{fd});

                        event.* = Event{ .CLOSE = fd };
                        _ = try ring.close(@intFromPtr(event), fd);

                        n += 1;
                    },

                    else => {
                        std.debug.print("There was an error with fd: {}\n", .{fd});
                        // std.debug.print("error: {s}.\n", .{@tagName(std.posix.errno(fd))});
                    },
                },

                .SEND => |fd| {
                    const recv_buffer = try allocator.alloc(u8, BUFFER_LENGTH);

                    event.* = Event{
                        .RECV = RecvData{ .fd = fd, .buffer = recv_buffer },
                    };

                    _ = try ring.recv(@intFromPtr(event), fd, .{ .buffer = recv_buffer }, 0);

                    n += 1;
                },

                .RECV => |data| {
                    if (cqe.res < 0) {
                        std.debug.print("Something went wrong reading from fd {}\n", .{data.fd});
                    } else {
                        const n_read: usize = @intCast(cqe.res);
                        std.debug.print(
                            "Received {} bytes from fd {}: '{s}'\n",
                            .{ n_read, data.fd, data.buffer[0..n_read] },
                        );
                    }

                    allocator.free(data.buffer);

                    event.* = Event{ .CLOSE = data.fd };
                    _ = try ring.close(@intFromPtr(event), data.fd);

                    n += 1;
                },

                .CLOSE => |fd| {
                    std.debug.print("Closed fd {}\n", .{fd});
                },
            }
        }
    }

    std.debug.print("All done!\n", .{});
}
