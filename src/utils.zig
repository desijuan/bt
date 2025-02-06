const std = @import("std");

const FileBufferedReader = std.io.BufferedReader(4096, std.fs.File.Reader);

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file: std.fs.File = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        std.log.err("Error opening file: {s}", .{path});
        return err;
    };
    defer file.close();

    var file_br: FileBufferedReader = std.io.bufferedReader(file.reader());
    const reader: FileBufferedReader.Reader = file_br.reader();

    const size: u64 = try file.getEndPos();
    const buffer: []u8 = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const nread: usize = try reader.readAll(buffer);
    if (nread != size) return error.ReadError;

    return buffer;
}
