const std = @import("std");

pub const pstr = "BitTorrent protocol";

pub const Handshake = struct {
    pstr: []const u8 = pstr,
    reserved: *const [8]u8 = &(.{0} ** 8),
    info_hash: *const [20]u8,
    peer_id: *const [20]u8,

    pub fn serialize(self: Handshake, allocator: std.mem.Allocator) ![]const u8 {
        const str_len = 1 + self.pstr.len + self.reserved.len + self.info_hash.len + self.peer_id.len;
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
