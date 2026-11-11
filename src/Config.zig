const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const utils = @import("utils.zig");

const Config = @This();

n_clients: u16 = 8,
max_keepalives: u16 = 8, // TODO: Usar esto
timeout_ms: c_int = 2000,

pub const ReadFromDiskError = utils.ReadFileZError || error{ParseZon};

pub fn readFromDisk(a: Allocator, io: Io) ReadFromDiskError!Config {
    const config_buffer: [:0]const u8 = utils.readFileZ(a, io, "config.zon") catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    defer a.free(config_buffer);

    return try std.zon.parse.fromSlice(Config, a, config_buffer, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    });
}
