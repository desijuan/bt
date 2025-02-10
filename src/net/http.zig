const std = @import("std");
const http = std.http;

const CONTENT_LENGTH_HEADER = "Content-Length";

const Url = struct {
    announce: []const u8,
    peer_id: []const u8,
    info_hash: []const u8,
    port: u32,
    uploaded: u32,
    downloaded: u32,
    compact: u32,
    left: u32,
};

pub fn requestPeers(allocator: std.mem.Allocator, url: Url) ![]const u8 {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri_str: []const u8 = try std.fmt.allocPrint(
        allocator,
        "{[announce]s}?port={[port]d}&peer_id={[peer_id]s}&info_hash={[info_hash]s}" ++
            "&uploaded={[uploaded]d}&downloaded={[downloaded]d}&compact={[compact]d}&left={[left]d}",
        url,
    );
    defer allocator.free(uri_str);

    const uri: std.Uri = try std.Uri.parse(uri_str);
    var buf: [4 * 1024]u8 = undefined;

    var req: http.Client.Request = try client.open(.GET, uri, .{
        .server_header_buffer = &buf,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    const res_status: http.Status = req.response.status;
    if (res_status != .ok) {
        std.log.err("Got response status \"{?s}\"", .{res_status.phrase()});
        return error.ResponseStatusNotOk;
    }

    var iter: http.HeaderIterator = req.response.iterateHeaders();
    const content_length: usize = while (iter.next()) |header| {
        if (std.mem.eql(u8, CONTENT_LENGTH_HEADER, header.name))
            break try std.fmt.parseInt(usize, header.value, 10);
    } else {
        std.log.err("No {s} header received", .{CONTENT_LENGTH_HEADER});
        return error.NoContentLength;
    };

    const body: []u8 = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

    const nread: usize = try req.readAll(body);
    if (nread != content_length) return error.ReadError;

    return body;
}
