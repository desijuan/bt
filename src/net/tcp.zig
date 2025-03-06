const std = @import("std");

pub const Peer = struct {
    ip: [4]u8,
    port: u16,

    pub fn address(self: Peer) std.net.Address {
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

pub const PeersIterator = struct {
    peers: []const u8,
    n: usize,

    pub fn init(peers: []const u8) error{MalformedPeersList}!PeersIterator {
        if (peers.len % 6 != 0) return error.MalformedPeersList;

        return PeersIterator{
            .peers = peers,
            .n = 0,
        };
    }

    pub fn next(self: *PeersIterator) ?Peer {
        const i = self.n * 6;

        if (i >= self.peers.len) return null;

        self.n += 1;

        return Peer{
            .ip = self.peers[i .. i + 4][0..4].*,
            .port = (@as(u16, self.peers[i + 4]) << 8) | @as(u16, self.peers[i + 5]),
        };
    }
};

pub const pstr = "BitTorrent protocol";

pub const Handshake = struct {
    pstr: []const u8 = pstr,
    reserved: *const [8]u8 = &(.{0} ** 8),
    info_hash: *const [20]u8,
    peer_id: *const [20]u8,

    pub fn len(self: Handshake) usize {
        return 1 + self.pstr.len + self.reserved.len + self.info_hash.len + self.peer_id.len;
    }

    pub fn serialize(self: Handshake, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        const str_len: usize = self.len();
        const str: []u8 = try allocator.alloc(u8, str_len);

        str[0] = @intCast(self.pstr.len);

        var offset: usize = 1;
        inline for (@typeInfo(Handshake).@"struct".fields) |field| {
            const value = @field(self, field.name);
            @memcpy(str[offset .. offset + value.len], value);
            offset += value.len;
        }

        return str;
    }
};

pub fn validateAnswer(ans: []const u8, info_hash: []const u8) bool {
    return (ans.len >= 68) and
        (ans[0] == 19) and
        (std.mem.eql(u8, pstr, ans[1..20])) and
        (std.mem.eql(u8, info_hash, ans[28..48]));
}

pub const MsgId = enum(u8) {
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

pub const Msg = struct {
    id: MsgId,
    payload: []const u8,

    pub fn len(self: Msg) usize {
        return 5 + self.payload.len;
    }

    pub fn serialize(self: Msg, bytes: []u8) error{InvalidBytes}!void {
        const bytes_len: u32 = @intCast(self.len());

        if (bytes_len != bytes.len) return error.InvalidBytes;

        std.mem.writeInt(u32, bytes[0..4], bytes_len - 4, .big);
        bytes[4] = @intFromEnum(self.id);
        @memcpy(bytes[5 .. 5 + self.payload.len], self.payload);
    }

    pub fn serializeAlloc(self: Msg, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        const bytes_len: u32 = @intCast(self.len());
        const bytes: []u8 = try allocator.alloc(u8, bytes_len);

        std.mem.writeInt(u32, bytes[0..4], bytes_len - 4, .big);
        bytes[4] = @intFromEnum(self.id);
        @memcpy(bytes[5 .. 5 + self.payload.len], self.payload);

        return bytes;
    }

    const DecodeError = error{
        InvalidBytes,
        InvalidLength,
        UnknownMsgId,
        ReceivedKeepAliveMsg,
        OutOfMemory,
    };

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Msg {
        if (bytes.len < 4) return error.InvalidBytes;

        const length_prefix: u32 = decodeLengthPrefix(bytes[0..4]);

        if (length_prefix < 0)
            return error.InvalidLength
        else if (length_prefix == 0)
            return error.ReceivedKeepAliveMsg;

        if (bytes.len < 5) return error.InvalidBytes;

        const id: u8 = bytes[4];

        if (id >= @typeInfo(MsgId).@"enum".fields.len) return error.UnknownMsgId;

        if (bytes.len < 4 + length_prefix) return error.InvalidBytes;

        const payload: []const u8 = if (length_prefix <= 1) &.{} else blk: {
            const buffer: []u8 = try allocator.alloc(u8, length_prefix - 1);
            @memcpy(buffer, bytes[5 .. 5 + length_prefix - 1]);
            break :blk buffer;
        };

        return Msg{
            .id = @enumFromInt(id),
            .payload = payload,
        };
    }

    pub inline fn decodeLengthPrefix(bytes: *const [4]u8) u32 {
        return std.mem.readInt(u32, bytes, .big);
    }

    pub fn eql(self: Msg, other: Msg) bool {
        return self.id == other.id and std.mem.eql(u8, self.payload, other.payload);
    }

    pub inline fn interested() Msg {
        return Msg{ .id = .Interested, .payload = &.{} };
    }
};

const testing = std.testing;

test "Msg.len" {
    const ally = testing.allocator;

    const chokeMsg: Msg = try Msg.decode(ally, &.{ 0, 0, 0, 1, 0 });
    defer ally.free(chokeMsg.payload);

    try testing.expectEqual(5, chokeMsg.len());
}

test "Msg.decode" {
    const ally = testing.allocator;

    const chokeMsg: Msg = try Msg.decode(ally, &.{ 0, 0, 0, 1, 0 });
    defer ally.free(chokeMsg.payload);

    try testing.expect(chokeMsg.eql(
        Msg{ .id = .Choke, .payload = &.{} },
    ));

    const haveMsg: Msg = try Msg.decode(ally, &.{ 0, 0, 0, 5, 4, 0, 0, 0, 1 });
    defer ally.free(haveMsg.payload);

    try testing.expect(haveMsg.eql(
        Msg{ .id = .Have, .payload = &.{ 0, 0, 0, 1 } },
    ));

    try testing.expectError(error.ReceivedKeepAliveMsg, Msg.decode(ally, &.{ 0, 0, 0, 0 }));
}

test "Msg.decodeLengthPrefix" {
    try std.testing.expectEqual(1, Msg.decodeLengthPrefix(&.{ 0, 0, 0, 1 }));
    try std.testing.expectEqual(317, Msg.decodeLengthPrefix(&.{ 0, 0, 1, 61 }));
}

test "Msg.serialize" {
    const msg = Msg{ .id = .Interested, .payload = &.{} };

    var bytes: [msg.len()]u8 = undefined;
    try msg.serialize(&bytes);

    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 2 }, &bytes);
}

test "Msg.serializeAlloc" {
    const ally = testing.allocator;

    const msg = Msg{ .id = .Interested, .payload = &.{} };

    const bytes: []const u8 = try msg.serializeAlloc(ally);
    defer ally.free(bytes);

    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 2 }, bytes);
}
