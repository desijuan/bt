const std = @import("std");
const log = std.log;

const Ctx = @import("Ctx.zig");
const App = @import("App.zig");

pub fn main(init: std.process.Init) !void {
    Ctx.a = init.gpa;
    Ctx.io = init.io;

    try App.readTorrent();
    defer App.freeTorrentFileBuffer();

    try App.printTorrentInfo();

    try App.requestPeers();
    defer App.freeTrackerResponseBuffer();

    App.printTrackerResponse();

    try App.startDownloading();

    log.info("All done!", .{});
}

comptime { // Tests
    _ = @import("utils.zig");
    _ = @import("net/tcp.zig");
}
