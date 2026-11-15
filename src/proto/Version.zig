//! Protocol version numbers.
//!
//! A version is four bytes on the wire: the major number, then the minor, each
//! big-endian. Protocol 3.0 is `00 03 00 00`. The decimal in the documentation
//! (196608) is those same four bytes read as one big-endian word, and it is the
//! only place that word exists — `toU32` and `fromU32` are for logging and for
//! code that already has an integer, not for the wire.
//!
//! The startup message sends this; the server answers with
//! `NegotiateProtocolVersion` when the client asks for a minor version it does
//! not support.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const readInt = @import("mem.zig").readInt;
const writeInt = @import("mem.zig").writeInt;

const Version = @This();

/// Big-endian, major then minor, exactly the four bytes on the wire.
wire: [4]u8,

/// Protocol 3.0. What a client sends when it wants the 3.0 semantics,
/// including a four-byte `BackendKeyData` key.
pub const v3_0: Version = .init(3, 0);

/// Protocol 3.2, which PostgreSQL 18 describes. `BackendKeyData` and
/// `CancelRequest` keys became 4 to 256 bytes here.
pub const v3_2: Version = .init(3, 2);

pub fn init(major_number: u16, minor_number: u16) Version {
    var wire: [4]u8 = undefined;
    writeInt(u16, wire[0..2], major_number);
    writeInt(u16, wire[2..4], minor_number);
    return .{ .wire = wire };
}

/// The wire form, for a reader that already has four bytes in hand.
pub inline fn fromBytes(wire: [4]u8) Version {
    return .{ .wire = wire };
}

pub inline fn fromU32(word: u32) Version {
    var wire: [4]u8 = undefined;
    writeInt(u32, &wire, word);
    return .{ .wire = wire };
}

pub inline fn toU32(self: Version) u32 {
    return readInt(u32, &self.wire);
}

pub inline fn major(self: Version) u16 {
    return readInt(u16, self.wire[0..2]);
}

pub inline fn minor(self: Version) u16 {
    return readInt(u16, self.wire[2..4]);
}

/// `3.0`, for a log line.
pub fn format(self: Version, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{d}.{d}", .{ self.major(), self.minor() });
}

pub inline fn eql(a: Version, b: Version) bool {
    const a_int: u32 = @bitCast(a.wire);
    const b_int: u32 = @bitCast(b.wire);
    return a_int == b_int;
}

test "the wire bytes are the version" {
    try testing.expectEqual([4]u8{ 0, 3, 0, 0 }, Version.v3_0.wire);
    try testing.expectEqual([4]u8{ 0, 3, 0, 2 }, Version.v3_2.wire);
}

test "3.0 matches the number in the documentation" {
    // "Int32(196608) The protocol version number."
    try testing.expectEqual(@as(u32, 196608), Version.v3_0.toU32());
    try testing.expectEqual(@as(u32, 196610), Version.v3_2.toU32());
    try testing.expect(Version.v3_0.eql(.fromU32(196608)));
}

test "major and minor come out of the bytes" {
    try testing.expectEqual(@as(u16, 3), Version.v3_2.major());
    try testing.expectEqual(@as(u16, 2), Version.v3_2.minor());
    try testing.expectEqual(@as(u16, 0), Version.v3_0.minor());
}

test "init and the word agree" {
    const built: Version = .init(3, 1);
    try testing.expectEqual([4]u8{ 0, 3, 0, 1 }, built.wire);
    try testing.expectEqual(@as(u32, 0x0003_0001), built.toU32());
    try testing.expectEqual(@as(u16, 3), built.major());
    try testing.expectEqual(@as(u16, 1), built.minor());
}

test "a version prints as the two numbers" {
    try testing.expectFmt("3.0", "{f}", .{Version.v3_0});
    try testing.expectFmt("3.2", "{f}", .{Version.v3_2});
    try testing.expectFmt("4.1", "{f}", .{Version.init(4, 1)});
}

test "another major version is representable" {
    // The protocol's own rule is that a version this library does not know is
    // the caller's to reject; the type does not narrow to 3.
    const v4: Version = .init(4, 0);
    try testing.expect(v4.eql(.fromBytes(.{ 0, 4, 0, 0 })));
    try testing.expect(!v4.eql(.v3_0));
}
