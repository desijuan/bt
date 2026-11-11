//
// - Piece Scheduler Interface -
//
// fn assignNext(peer: Ip4Address) ?u32
//
// fn release(peer: Ip4Address, i: u32) error{ PieceNotAssigned, WrongPeer }!void
//
// fn complete(peer: Ip4Address, i: u32) error{ PieceNotAssigned, WrongPeer }!void
//
