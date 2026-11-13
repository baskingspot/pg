//! Writing a message: a tag, a length that counts itself, and a body.
//!
//! `stdx.wire.Writer(.big)` does the fields. This adds the two things a
//! protocol message needs on top: the length is known only after the body, and
//! the body is written field by field in the order the docs give, with no
//! arithmetic at the call site.
//!
//! A message that never varies is built at comptime by running its encoder and
//! measuring the result, so the constant and the encoder cannot disagree.

const std = @import("std");
const testing = std.testing;

const frontend = @import("frontend.zig");
const messages = @import("messages.zig");
const wire = @import("wire.zig");
const writeInt = @import("mem.zig").writeInt;

pub const Error = error{NoSpaceLeft};

/// A buffer, the message being written into it, and where that message began.
///
/// One encoder writes as many messages as fit, one after another. The buffer
/// belongs to the caller and never moves, which is what makes the length
/// backfill in `finish` safe.
pub const Encoder = struct {
    writer: wire.Writer,
    /// Where the current message began.
    at: u32,
    /// How many bytes sit before the length field: one for a tag, none in the
    /// startup phase.
    header: u1,

    pub const init: Encoder = .{ .writer = .empty, .at = 0, .header = 1 };

    pub fn reset(self: *Encoder, buffer: []u8) void {
        self.* = .{ .writer = .init(buffer), .at = 0, .header = 1 };
    }

    /// Start a frontend message: the tag, then four bytes of length to fill
    /// later.
    pub fn start(self: *Encoder, tag: messages.Frontend) Error!void {
        try self.begin(@backingInt(tag));
    }

    /// Start a backend message. The same layout, on the other side of the
    /// connection.
    pub fn startBackend(self: *Encoder, tag: messages.Backend) Error!void {
        try self.begin(@backingInt(tag));
    }

    /// Start a message from before the tagged phase, where a length comes
    /// first and there is no tag byte.
    pub fn startUntagged(self: *Encoder) Error!void {
        self.at = @intCast(self.writer.end);
        self.header = 0;
        _ = try self.writer.reserve(4);
    }

    fn begin(self: *Encoder, tag: u8) Error!void {
        self.at = @intCast(self.writer.end);
        self.header = 1;
        try self.writer.append(u8, tag);
        _ = try self.writer.reserve(4);
    }

    /// Fill in the length and hand back the bytes of this message only.
    ///
    /// The length counts itself and the body but not the tag, so a message
    /// with an empty body declares 4.
    pub fn finish(self: *Encoder) []const u8 {
        const end = self.writer.end;
        const at = self.at;
        const length: u32 = @intCast(end - at - self.header);
        writeInt(u32, self.writer.buffer[at + self.header ..][0..4], length);
        return self.writer.buffer[at..end];
    }

    /// Raw bytes, for a body field that is already in wire form.
    pub fn bytes(self: *Encoder, value: []const u8) Error!void {
        try self.writer.appendSlice(value);
    }

    /// A `String`: the bytes, then a zero. The protocol has no length field
    /// for it, so a zero inside the value is not representable.
    pub fn string(self: *Encoder, value: []const u8) Error!void {
        try self.writer.appendSlice(value);
        try self.writer.append(u8, 0);
    }

    pub fn int(self: *Encoder, comptime T: type, value: T) Error!void {
        try self.writer.append(T, value);
    }
};

/// How many bytes a frontend message takes, by encoding it.
///
/// The scratch buffer is a bound on what can be a comptime constant rather
/// than a protocol limit; a message a caller assembles at runtime is written
/// straight into the caller's buffer.
fn encodedLen(comptime message: frontend.Message) u32 {
    var scratch: [8192]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&scratch);
    _ = message.encode(&encoder) catch @compileError("message exceeds the comptime buffer");
    return @intCast(encoder.writer.end);
}

/// A frontend message's bytes, built at comptime.
///
/// The parameter is the union rather than `anytype` so a call site can name
/// the arm: `build(.{ .query = .{ .sql = "select 1" } })`.
pub fn build(comptime message: frontend.Message) [encodedLen(message)]u8 {
    var bytes: [encodedLen(message)]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&bytes);
    _ = message.encode(&encoder) catch unreachable;
    return bytes;
}

test "the length counts itself and the body, not the tag" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    try encoder.start(.sync);
    const message = encoder.finish();

    try testing.expectEqualSlices(u8, &.{ 'S', 0, 0, 0, 4 }, message);
}

test "one encoder writes messages back to back" {
    var buffer: [64]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    try encoder.start(.sync);
    const first = encoder.finish();

    try encoder.start(.flush);
    const second = encoder.finish();

    try testing.expectEqualSlices(u8, &.{ 'S', 0, 0, 0, 4 }, first);
    try testing.expectEqualSlices(u8, &.{ 'H', 0, 0, 0, 4 }, second);
    try testing.expectEqual(@as(usize, 10), encoder.writer.end);
}

test "a body that does not fit is an error, not a partial message" {
    var buffer: [6]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    try encoder.start(.query);
    try testing.expectError(error.NoSpaceLeft, encoder.string("select 1"));
}

test "a string is the bytes and a zero" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    try encoder.start(.query);
    try encoder.string("select 1");
    const message = encoder.finish();

    try testing.expectEqualStrings("Q\x00\x00\x00\x0dselect 1\x00", message);
}
