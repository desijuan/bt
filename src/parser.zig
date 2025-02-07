const std = @import("std");

const DataType = enum {
    int,
    string,
    list,
    dict,
};

const names = [6][]const u8{
    "announce",
    "comment",
    "info",
    "length",
    "name",
    "pieces",
};

const types = [6]DataType{
    .string,
    .string,
    .dict,
    .int,
    .string,
    .string,
};

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
                while (parser.i < parser.buf.len) std.debug.print("  '{s}'\n", .{try parser.parseStr()});
            } else std.debug.print("{s}: '{s}'\n", .{ field.name, @field(self, field.name) }),

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
    var torrentFile = TorrentFile{
        .announce = &.{},
        .comment = &.{},
        .created_by = &.{},
        .name = &.{},
        .pieces = &.{},
        .url_list = &.{},
        .creation_date = 0,
        .length = 0,
        .piece_length = 0,
    };

    try self.parseDict(&torrentFile);

    return torrentFile;
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

    while (self.i < self.buf.len and self.peekChar() != 'e')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != 'e') return error.InvalidChar;

    return n;
}

fn parseStr(self: *Self) ![]const u8 {
    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != ':')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != ':') return error.InvalidChar;

    const k: usize = self.i;

    self.i += n;

    return self.buf[k..self.i];
}

fn parseList(self: *Self) ![]const u8 {
    if (self.readChar() != 'l') return error.InvalidChar;

    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != 'e') {
        _ = try self.parseStr();
    }

    const list: []const u8 = self.buf[j..self.i];

    if (self.readChar() != 'e') return error.InvalidChar;

    return list;
}

fn parseDict(self: *Self, torrentFile: *TorrentFile) !void {
    if (self.readChar() != 'd') return error.InvalidChar;

    while (self.i < self.buf.len and self.peekChar() != 'e') {
        const key = try self.parseStr();

        if (std.mem.eql(u8, "created by", key)) {
            torrentFile.created_by = try self.parseStr();
            continue;
        }

        if (std.mem.eql(u8, "creation date", key)) {
            torrentFile.creation_date = try self.parseInt();
            continue;
        }

        if (std.mem.eql(u8, "url-list", key)) {
            torrentFile.url_list = try self.parseList();
            continue;
        }

        if (std.mem.eql(u8, "piece length", key)) {
            torrentFile.piece_length = try self.parseInt();
            continue;
        }

        blk: inline for (names, types) |name, dataType|
            if (std.mem.eql(u8, name, key)) {
                switch (dataType) {
                    .int => @field(torrentFile, name) = try self.parseInt(),
                    .string => @field(torrentFile, name) = try self.parseStr(),
                    .list => @field(torrentFile, name) = try self.parseList(),
                    .dict => try self.parseDict(torrentFile),
                }

                break :blk;
            };
    }

    if (self.readChar() != 'e') return error.InvalidChar;
}

fn eatWhitespace(self: Self) void {
    while (self.i < self.buf.len and std.ascii.isWhitespace(self.peekChar()))
        self.i += 1;
}
