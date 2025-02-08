const std = @import("std");

pub const DataType = enum(u2) {
    int,
    string,
    list,
    dict,
};

const Self = @This();

buf: []const u8,
i: usize,

pub fn init(buffer: []const u8) Self {
    return Self{
        .buf = buffer,
        .i = 0,
    };
}

pub fn parseInt(self: *Self) !u32 {
    if (self.readChar() != 'i') return error.InvalidChar;

    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != 'e')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != 'e') return error.InvalidChar;

    return n;
}

pub fn parseStr(self: *Self) ![]const u8 {
    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != ':')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != ':') return error.InvalidChar;

    const k: usize = self.i;

    self.i += n;

    return self.buf[k..self.i];
}

pub fn parseList(self: *Self) ![]const u8 {
    if (self.readChar() != 'l') return error.InvalidChar;

    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != 'e') {
        _ = try self.parseStr();
    }

    const list: []const u8 = self.buf[j..self.i];

    if (self.readChar() != 'e') return error.InvalidChar;

    return list;
}

pub fn parseDict(self: *Self, comptime T: type, dto: *T) !void {
    if (self.readChar() != 'd') return error.InvalidChar;

    while (self.i < self.buf.len and self.peekChar() != 'e') {
        const key = try self.parseStr();

        blk: inline for (T.key_names, T.field_names, T.data_types) |name, field, data_type|
            if (std.mem.eql(u8, name, key)) {
                switch (data_type) {
                    .int => @field(dto, field) = try self.parseInt(),
                    .string => @field(dto, field) = try self.parseStr(),
                    .list => @field(dto, field) = try self.parseList(),
                    .dict => try self.parseDict(T, dto),
                }

                break :blk;
            };
    }

    if (self.readChar() != 'e') return error.InvalidChar;
}

inline fn peekChar(self: Self) u8 {
    return self.buf[self.i];
}

inline fn readChar(self: *Self) u8 {
    const c: u8 = self.buf[self.i];
    self.i += 1;
    return c;
}

fn eatWhitespace(self: Self) void {
    while (self.i < self.buf.len and std.ascii.isWhitespace(self.peekChar()))
        self.i += 1;
}
