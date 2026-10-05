const std = @import("std");

const Ip4Address = std.Io.net.Ip4Address;

const Ctx = @import("../Ctx.zig");

pub const Assignee = struct {
    client: u32,
    peer: Ip4Address,
};

pub const State = union(enum) {
    Pending,
    Assigned: Assignee,
    Complete: Assignee,
};

const PieceStorage = @This();

pieces: []State,

pub fn new(n_pieces: u32) error{OutOfMemory}!PieceStorage {
    const pieces: []State = try Ctx.a.alloc(State, n_pieces);
    @memset(pieces, .Pending);
    return PieceStorage{ .pieces = pieces };
}

pub fn deinit(self: *PieceStorage) void {
    Ctx.a.free(self.pieces);
    self.pieces = &.{};
}

pub fn pieceState(self: PieceStorage, i: u32) error{IndexOutOfBounds}!State {
    if (i >= self.pieces.len) return error.IndexOutOfBounds;
    return self.pieces[i];
}

pub const AssignError = error{ IndexOutOfBounds, PieceAssigned, PieceComplete };

pub fn assign(self: *PieceStorage, i: u32, me: Assignee) AssignError!void {
    if (i >= self.pieces.len) return error.IndexOutOfBounds;
    return switch (self.pieces[i]) {
        .Pending => {
            self.pieces[i] = State{ .Assigned = me };
        },
        .Assigned => error.PieceAssigned,
        .Complete => error.PieceComplete,
    };
}

pub fn release(
    self: *PieceStorage,
    i: u32,
    me: Assignee,
) error{ IndexOutOfBounds, PiecePending, PieceComplete, WrongClient, WrongPeer }!void {
    if (i >= self.pieces.len) return error.IndexOutOfBounds;
    return switch (self.pieces[i]) {
        .Pending => error.PiecePending,

        .Assigned => |a| if (a.client != me.client)
            error.WrongClient
        else if (a.peer != me.peer)
            error.WrongPeer
        else {
            self.pieces[i] = State{.Pending};
        },

        .Complete => error.PieceComplete,
    };
}

pub fn complete(
    self: *PieceStorage,
    i: u32,
    me: Assignee,
) error{ IndexOutOfBounds, PiecePending, PieceComplete }!void {
    if (i >= self.pieces.len) return error.IndexOutOfBounds;
    return switch (self.pieces[i]) {
        .Pending => error.PiecePending,

        .Assigned => |a| if (a.client != me.client)
            error.WrongClient
        else if (a.peer != me.peer)
            error.WrongPeer
        else {
            self.pieces[i] = State{ .Completed = me };
        },

        .Complete => error.PieceComplete,
    };
}
