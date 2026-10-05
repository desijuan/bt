const std = @import("std");

const Ip4Address = std.Io.net.Ip4Address;

const PieceStorage = @import("PieceStorage.zig");
const Assignee = PieceStorage.Assignee;

const PieceScheduler = @This();

storage: PieceStorage,

pub fn new(n_pieces: u32) error{OutOfMemory}!PieceScheduler {
    return PieceScheduler{ .storage = try PieceStorage.new(n_pieces) };
}

pub fn deinit(self: *PieceScheduler) void {
    self.storage.deinit();
}

pub fn claimPiece(self: *PieceScheduler, client: u32, peer: Ip4Address) PieceStorage.AssignError!?u32 {
    return for (self.storage.pieces, 0..) |piece_state, i| {
        if (piece_state == .Pending) {
            try self.storage.assign(@intCast(i), Assignee{ .client = client, .peer = peer });
            break @intCast(i);
        }
    } else null;
}
