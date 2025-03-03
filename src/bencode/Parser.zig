const std = @import("std");

const ParseError = std.fmt.ParseIntError;

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

pub fn parseInt(self: *Self) ParseError!u32 {
    if (self.readChar() != 'i') return error.InvalidCharacter;

    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != 'e')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != 'e') return error.InvalidCharacter;

    return n;
}

pub fn parseStr(self: *Self) ParseError![]const u8 {
    const j: usize = self.i;

    while (self.i < self.buf.len and self.peekChar() != ':')
        self.i += 1;

    const n: u32 = try std.fmt.parseInt(u32, self.buf[j..self.i], 10);

    if (self.readChar() != ':') return error.InvalidCharacter;

    const k: usize = self.i;

    self.i += n;

    return self.buf[k..self.i];
}

pub fn parseListAsStr(self: *Self) ParseError![]const u8 {
    const j: usize = self.i;

    if (self.readChar() != 'l') return error.InvalidCharacter;

    var next_char: u8 = self.peekChar();
    while (self.i < self.buf.len and next_char != 'e') : (next_char = self.peekChar())
        switch (next_char) {
            'i' => _ = try self.parseInt(),

            '1'...'9' => _ = try self.parseStr(),

            'l' => _ = try self.parseListAsStr(),

            'd' => _ = try self.parseDictAsStr(),

            else => return error.InvalidCharacter,
        };

    if (self.readChar() != 'e') return error.InvalidCharacter;

    return self.buf[j..self.i];
}

pub fn parseDictAsStr(self: *Self) ParseError![]const u8 {
    const j: usize = self.i;

    if (self.readChar() != 'd') return error.InvalidCharacter;

    var next_char: u8 = self.peekChar();
    while (self.i < self.buf.len and next_char != 'e') : (next_char = self.peekChar())
        switch (next_char) {
            'i' => _ = try self.parseInt(),

            '1'...'9' => _ = try self.parseStr(),

            'l' => _ = try self.parseListAsStr(),

            'd' => _ = try self.parseDictAsStr(),

            else => return error.InvalidCharacter,
        };

    if (self.readChar() != 'e') return error.InvalidCharacter;

    return self.buf[j..self.i];
}

pub fn parseDict(self: *Self, comptime T: type, dto: *T) ParseError!void {
    if (self.readChar() != 'd') return error.InvalidCharacter;

    while (self.i < self.buf.len and self.peekChar() != 'e') {
        const key = try self.parseStr();

        inline for (T.key_names, T.field_names, T.data_types) |name, field, data_type|
            if (std.mem.eql(u8, name, key)) {
                @field(dto, field) = switch (data_type) {
                    .int => try self.parseInt(),
                    .string => try self.parseStr(),
                    .list => try self.parseListAsStr(),
                    .dict => try self.parseDictAsStr(),
                };

                break;
            };
    }

    if (self.readChar() != 'e') return error.InvalidCharacter;
}

pub fn printList(buffer: []const u8) ParseError!void {
    var parser: Self = init(buffer);

    if (parser.readChar() != 'l') return error.InvalidCharacter;

    while (parser.i < parser.buf.len and parser.peekChar() != 'e')
        std.debug.print("\n  '{s}'", .{try parser.parseStr()});

    if (parser.readChar() != 'e') return error.InvalidCharacter;
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
