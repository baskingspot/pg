//! The wire's cursor, and the one field shape `stdx.wire` does not cover.
//!
//! `stdx.wire.Reader(.big)` and `Writer(.big)` do the work: fixed-width
//! integers and enums at comptime byte order, zero-copy slices, bounds checked
//! or asserted, and a reserved slot for the length a message only knows after
//! its body is written. This file names the big-endian pair and adds the
//! null-terminated string, which is the protocol's own field type.
//!
//! `Error` is the reader's, so a parser's error set is the same whether it ran
//! out of bytes inside a take or inside a string.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const wire = @import("stdx").wire;

pub const Reader = wire.Reader(.big);
pub const Writer = wire.Writer(.big);

pub const Error = error{UnexpectedEof};

/// A null-terminated string, without the terminator.
///
/// The protocol calls this a `String`, and it appears in `ErrorResponse`,
/// `RowDescription`, `ParameterStatus`, `StartupMessage`, and the command
/// paths. The bytes are not UTF-8 validated: they are what the peer sent.
pub fn takeString(r: *Reader) Error![]const u8 {
    const nul = mem.findScalar(u8, r.remaining(), 0) orelse return error.UnexpectedEof;
    const value = try r.readSlice(nul);
    _ = try r.skip(1);
    return value;
}

/// The next byte, without taking it.
pub fn peek(r: *const Reader) ?u8 {
    const rest = r.remaining();
    return if (rest.len == 0) null else rest[0];
}

test "a string ends at its null and the null is consumed" {
    var r: Reader = .init("postgres\x00db\x00");
    try testing.expectEqualStrings("postgres", try takeString(&r));
    try testing.expectEqualStrings("db", try takeString(&r));
    try testing.expectEqual(@as(usize, 0), r.remaining().len);
}

test "a string with no null is the end of the body" {
    var r: Reader = .init("postgres");
    try testing.expectError(error.UnexpectedEof, takeString(&r));
}

test "an empty string is a string" {
    var r: Reader = .init("\x00");
    try testing.expectEqualStrings("", try takeString(&r));
    try testing.expectEqual(@as(usize, 0), r.remaining().len);
}

test "peek does not move the cursor" {
    var r: Reader = .init("Q\x00");
    try testing.expectEqual(@as(?u8, 'Q'), peek(&r));
    try testing.expectEqual(@as(?u8, 'Q'), peek(&r));
    _ = try r.skip(1);
    try testing.expectEqual(@as(?u8, 0), peek(&r));
    _ = try r.skip(1);
    try testing.expectEqual(@as(?u8, null), peek(&r));
}

test "values point into the body" {
    const body = [_]u8{ 'x', 0 };
    var r: Reader = .init(&body);
    const value = try takeString(&r);
    try testing.expectEqual(@intFromPtr(&body), @intFromPtr(value.ptr));
}

test "the reader's own shapes still hold" {
    // Not this file's job to test stdx, but a parser depends on these two
    // calls behaving, and they are the ones a message body uses.
    const body = [_]u8{ 0, 0, 0, 7, 'a', 'b', 'c', 'd', 'e', 'f', 'g' };
    var r: Reader = .init(&body);

    try testing.expectEqual(@as(u32, 7), try r.read(u32));
    try testing.expectEqualStrings("abc", try r.readSlice(3));
    try testing.expectEqualStrings("defg", r.remaining());
}
