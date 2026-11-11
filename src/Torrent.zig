const Torrent = @This();

length: u32,
piece_length: u32,
name: []const u8,
pieces: []const u8,

pub fn pieceCnt(self: Torrent) u32 {
    return self.length / self.piece_length;
}
