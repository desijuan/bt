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

pub inline fn range(comptime start: comptime_int, comptime end: comptime_int) [end - start]u8 {
    comptime {
        if (start >= end) {
            @compileError("start must be strictly less than end");
        }

        var array: [end - start]u8 = undefined;

        for (0..array.len) |i|
            array[i] = start + i;

        return array;
    }
}

test range {
    const v = range(11, 21);
    try std.testing.expectEqual(10, v.len);
    try std.testing.expectEqual(11, v[0]);
    try std.testing.expectEqual(20, v[9]);
}
