//! A cursor over the bytes of one message body.
//!
//! A body is a sequence of typed fields in the order the protocol documents
//! them, so a parser is a run of takes. Every take is bounds checked against
//! what is left, and a body that ends early is an error rather than a zero or
//! a slice into the next message.
//!
//! The reader borrows the body. Nothing here allocates or copies, so a field
//! value points into the buffer the message arrived in.

const std = @import("std");
const testing = std.testing;

const readInt = @import("mem.zig").readInt;

pub const Reader = struct {
    bytes: []const u8,

    /// Offset of the next unread byte. A body is under 1 GiB, because the
    /// frame length is.
    at: u32,

    pub const Error = error{
        /// The body ended before the field did.
        Truncated,
    };

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .at = 0 };
    }

    /// The bytes not yet taken.
    pub fn rest(self: Reader) []const u8 {
        return self.bytes[self.at..];
    }

    pub fn atEnd(self: Reader) bool {
        return self.at == self.bytes.len;
    }

    /// The next byte, without taking it.
    pub fn peek(self: Reader) ?u8 {
        return if (self.atEnd()) null else self.bytes[self.at];
    }

    /// `n` bytes, borrowed from the body.
    pub fn take(self: *Reader, n: u32) Error![]const u8 {
        if (self.rest().len < n) return error.Truncated;
        const bytes = self.bytes[self.at..][0..n];
        self.at += n;
        return bytes;
    }

    /// One integer of any width, big-endian.
    pub fn takeInt(self: *Reader, comptime T: type) Error!T {
        const bits = @typeInfo(T).int.bits;
        const bytes = try self.take(@divExact(bits, 8));
        return readInt(T, bytes[0..@divExact(bits, 8)]);
    }

    /// A null-terminated string, without the terminator.
    ///
    /// The protocol calls this a `String`. It is not UTF-8 validated here: the
    /// bytes are what the server sent.
    pub fn takeString(self: *Reader) Error![]const u8 {
        const rest_bytes = self.rest();
        const nul = std.mem.findScalar(u8, rest_bytes, 0) orelse return error.Truncated;

        const start: u32 = self.at;
        const end: u32 = @intCast(start + nul);
        self.at = end + 1;
        return self.bytes[start..end];
    }
};

test "integers come out big-endian at every width" {
    const body = [_]u8{ 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3 };
    var r = Reader.init(&body);

    try testing.expectEqual(@as(u16, 1), try r.takeInt(u16));
    try testing.expectEqual(@as(u32, 2), try r.takeInt(u32));
    try testing.expectEqual(@as(u64, 3), try r.takeInt(u64));
    try testing.expect(r.atEnd());
}

test "a signed length can be negative" {
    // Bind and DataRow use -1 to mean a NULL value, so the reader must not
    // narrow the field to unsigned on the way out.
    const body = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    var r = Reader.init(&body);
    try testing.expectEqual(@as(i32, -1), try r.takeInt(i32));
}

test "taking more than is left is an error, not a short slice" {
    var r = Reader.init("abc");
    try testing.expectError(error.Truncated, r.take(4));
    // The failed take leaves the cursor alone.
    try testing.expectEqualStrings("abc", try r.take(3));
    try testing.expectError(error.Truncated, r.take(1));
}

test "take zero is allowed at the end" {
    var r = Reader.init("");
    try testing.expectEqual(@as(usize, 0), (try r.take(0)).len);
    try testing.expect(r.atEnd());
    try testing.expectEqual(@as(?u8, null), r.peek());
}

test "a string ends at its null and the null is consumed" {
    var r = Reader.init("postgres\x00db\x00");
    try testing.expectEqualStrings("postgres", try r.takeString());
    try testing.expectEqualStrings("db", try r.takeString());
    try testing.expect(r.atEnd());
}

test "a string with no null is truncated" {
    var r = Reader.init("postgres");
    try testing.expectError(error.Truncated, r.takeString());
}

test "an empty string is a string" {
    var r = Reader.init("\x00");
    try testing.expectEqualStrings("", try r.takeString());
    try testing.expect(r.atEnd());
}

test "values point into the body" {
    const body = [_]u8{ 'x', 0 };
    var r = Reader.init(&body);
    const value = try r.takeString();
    try testing.expectEqual(@intFromPtr(&body), @intFromPtr(value.ptr));
}
