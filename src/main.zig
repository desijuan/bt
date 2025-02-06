const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const buffer: []const u8 = try utils.readFile(
        allocator,
        "debian-12.9.0-amd64-netinst.iso.torrent",
    );
    defer allocator.free(buffer);

    var parser = Parser.init(buffer);

    const torrentFile = try parser.parseTorrentFile();
    try torrentFile.print();
}
