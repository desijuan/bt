const std = @import("std");
const testing = std.testing;

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

    try testing.expectEqual(10, v.len);
    try testing.expectEqual(11, v[0]);
    try testing.expectEqual(20, v[9]);
}

pub fn Stack(comptime T: type) type {
    return struct {
        items: []T,
        i: usize,

        const Self = @This();

        pub fn init(store: []T) Self {
            return Self{
                .items = store,
                .i = 0,
            };
        }

        pub fn push(self: *Self, item: T) error{OutOfSpace}!void {
            if (self.i >= self.items.len) return error.OutOfSpace;

            self.items[self.i] = item;
            self.i += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.i <= 0) return null;

            self.i -= 1;
            return self.items[self.i];
        }
    };
}

test "UIntStack" {
    const UIntStack = Stack(u32);

    var array: [3]u32 = undefined;
    var s = UIntStack.init(&array);

    try s.push(1);
    try s.push(2);
    try s.push(3);

    try testing.expectError(error.OutOfSpace, s.push(4));
    try testing.expectEqual(3, s.pop());
    try testing.expectEqual(2, s.pop());
    try testing.expectEqual(1, s.pop());
    try testing.expectEqual(null, s.pop());
}
