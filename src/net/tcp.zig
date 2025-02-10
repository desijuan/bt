const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

pub fn getNthPeer(n: usize, buffer: []const u8) std.net.Address {
    const i = n * 6;

    return std.net.Address.initIp4(
        buffer[i .. i + 4][0..4].*,
        (@as(u16, buffer[i + 4]) << 8) | @as(u16, buffer[i + 5]),
    );
}

pub fn connectToAddress(address: std.net.Address) (posix.SocketError || posix.ConnectError)!std.net.Stream {
    const sockfd = posix.socket(linux.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(sockfd);

    try posix.connect(sockfd, &address.any, address.getOsSockLen());

    return std.net.Stream{ .handle = sockfd };
}
