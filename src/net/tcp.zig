const std = @import("std");

pub fn validateAnswer(ans: []const u8, info_hash: []const u8) bool {
    return (ans.len >= 68) and
        (ans[0] == 19) and
        (std.mem.eql(u8, "BitTorrent protocol", ans[1..20])) and
        (std.mem.eql(u8, info_hash, ans[28..48]));
}
