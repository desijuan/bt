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

    pub fn serialize(self: Handshake, allocator: std.mem.Allocator) ![]const u8 {
        const str_len: usize = self.len();
        const str: []u8 = try allocator.alloc(u8, str_len);

        str[0] = @intCast(self.pstr.len);

        var offset: usize = 1;
        inline for (@typeInfo(Handshake).Struct.fields) |field| {
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

    pub fn serialize(self: Msg, allocator: std.mem.Allocator) ![]const u8 {
        const str_len: usize = self.len();
        const str: []u8 = try allocator.alloc(u8, str_len);

        std.mem.writeInt(usize, str[0..4], str_len, .big);
        str[4] = @intFromEnum(self.id);
        @memcpy(str[5 .. 5 + self.payload.len], self.payload);

        return str;
    }

    pub fn decode(str: []const u8) !Msg {
        if (str.len < 5) return error.InvalidSring;

        const length: u32 = decodeLength(str[0..4]);

        if (str.len != 4 + length) return error.InvalidSring;

        return Msg{
            .id = @enumFromInt(str[4]),
            .payload = str[5..],
        };
    }

    pub fn decodeLength(str: *const [4]u8) u32 {
        return (@as(u32, str[0]) << 24) | (@as(u32, str[1]) << 16) | (@as(u32, str[2]) << 8) | @as(u32, str[3]);
    }

    pub fn eql(self: Msg, other: Msg) bool {
        return self.id == other.id and std.mem.eql(u8, self.payload, other.payload);
    }
};

test "decode" {
    const chokeMsg: Msg = try Msg.decode(&.{ 0, 0, 0, 1, 0 });
    try std.testing.expect(chokeMsg.eql(
        Msg{ .id = .Choke, .payload = &.{} },
    ));

    const haveMsg: Msg = try Msg.decode(&.{ 0, 0, 0, 5, 4, 0, 0, 0, 1 });
    try std.testing.expect(haveMsg.eql(
        Msg{ .id = .Have, .payload = &.{ 0, 0, 0, 1 } },
    ));
}

test "decodeMsgLength" {
    try std.testing.expectEqual(1, Msg.decodeLength(&.{ 0, 0, 0, 1 }));
    try std.testing.expectEqual(317, Msg.decodeLength(&.{ 0, 0, 1, 61 }));
}
