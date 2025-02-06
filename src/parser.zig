const std = @import("std");

pub const TorrentFile = struct {
    announce: []const u8,
    comment: []const u8,
    created_by: []const u8,
    name: []const u8,
    pieces: []const u8,
    url_list: []const u8,
    creation_date: u32,
    length: u32,
    piece_length: u32,

    pub fn print(self: TorrentFile) !void {
        inline for (@typeInfo(TorrentFile).Struct.fields) |field| switch (@typeInfo(field.type)) {
            .Pointer => if (comptime std.mem.eql(u8, "pieces", field.name))
                std.debug.print("{s}: {x} [..]\n", .{ field.name, @field(self, field.name)[0..20] })
            else if (comptime std.mem.eql(u8, "url_list", field.name)) {
                std.debug.print("url-list:\n", .{});
                var parser = init(@field(self, field.name));
                while (parser.i < parser.buf.len) std.debug.print("  {s}\n", .{try parser.parseStr()});
            } else std.debug.print("{s}: {s}\n", .{ field.name, @field(self, field.name) }),

            .Int => std.debug.print("{s}: {d}\n", .{ field.name, @field(self, field.name) }),

            else => unreachable,
        };
    }
};

buf: []const u8,
i: usize,

const Self = @This();

pub fn init(buffer: []const u8) Self {
    return Self{
        .buf = buffer,
        .i = 0,
    };
}

pub fn parseTorrentFile(self: *Self) !TorrentFile {
    if (self.readChar() != 'd') return error.InvalidChar;

    if (!std.mem.eql(u8, "announce", try self.parseStr())) return error.InvalidKey;
    const announce: []const u8 = try self.parseStr();

    if (!std.mem.eql(u8, "comment", try self.parseStr())) return error.InvalidKey;
    const comment: []const u8 = try self.parseStr();

    if (!std.mem.eql(u8, "created by", try self.parseStr())) return error.InvalidKey;
    const created_by: []const u8 = try self.parseStr();

    if (!std.mem.eql(u8, "creation date", try self.parseStr())) return error.InvalidKey;
    const creation_date: u32 = try self.parseInt();

    if (!std.mem.eql(u8, "info", try self.parseStr())) return error.InvalidKey;

    if (self.readChar() != 'd') return error.InvalidChar;

    if (!std.mem.eql(u8, "length", try self.parseStr())) return error.InvalidKey;
    const length: u32 = try self.parseInt();

    if (!std.mem.eql(u8, "name", try self.parseStr())) return error.InvalidKey;
    const name: []const u8 = try self.parseStr();

    if (!std.mem.eql(u8, "piece length", try self.parseStr())) return error.InvalidKey;
    const piece_length: u32 = try self.parseInt();

    if (!std.mem.eql(u8, "pieces", try self.parseStr())) return error.InvalidKey;
    const pieces: []const u8 = try self.parseStr();

    if (self.readChar() != 'e') return error.InvalidChar;

    if (!std.mem.eql(u8, "url-list", try self.parseStr())) return error.InvalidKey;

    if (self.readChar() != 'l') return error.InvalidChar;

    const j: usize = self.i;

    while (self.peekChar() != 'e')
        _ = try self.parseStr();

    const url_list: []const u8 = self.buf[j..self.i];

    if (self.readChar() != 'e') return error.InvalidChar;
    if (self.readChar() != 'e') return error.InvalidChar;

    return TorrentFile{
        .announce = announce,
        .comment = comment,
        .created_by = created_by,
        .name = name,
        .pieces = pieces,
        .url_list = url_list,
        .creation_date = creation_date,
        .length = length,
        .piece_length = piece_length,
    };
}

inline fn peekChar(self: Self) u8 {
    return self.buf[self.i];
}

inline fn readChar(self: *Self) u8 {
    const c: u8 = self.buf[self.i];
    self.i += 1;
    return c;
}

fn parseInt(self: *Self) !u32 {
    if (self.readChar() != 'i') return error.InvalidChar;

    const j: usize = self.i;

    while (self.i <= self.buf.len and self.peekChar() != 'e')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    self.i += 1;

    return n;
}

fn parseStr(self: *Self) ![]const u8 {
    const j: usize = self.i;

    while (self.i <= self.buf.len and self.peekChar() != ':')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    const k: usize = self.i + 1;
    self.i += n + 1;

    return self.buf[k..self.i];
}

fn eatWhitespace(self: Self) void {
    while (self.i <= self.buf.len and std.ascii.isWhitespace(self.peekChar()))
        self.i += 1;
}
