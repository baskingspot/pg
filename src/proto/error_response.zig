//! `ErrorResponse` and `NoticeResponse` bodies.
//!
//! `E` and `N` carry the same body: a sequence of a field code byte and a
//! null-terminated value, ended by a zero byte. Fields can arrive in any order,
//! each at most once, and the protocol says a frontend ignores a code it does
//! not know — so this yields the raw code and leaves the meaning to the caller.
//!
//! What arrives is not necessarily one kind of failure: `NoticeResponse` is the
//! same format for a notice, a warning, or a server-side log line, and a
//! decision about which of those is fatal belongs above this layer.

const std = @import("std");
const testing = std.testing;
const atoi = @import("stdx").fmt.atoi;

const messages = @import("messages.zig");
const wire = @import("wire.zig");

pub const Field = struct {
    /// The code byte, exactly as sent. `kind` names it when this library knows
    /// it, which is not a condition for keeping it.
    code: u8,

    /// The value bytes, borrowed from the message body.
    value: []const u8,

    pub fn kind(self: Field) ?messages.ErrorField {
        return .fromByte(self.code);
    }

    /// The value as an integer, for the `P` and `L` fields.
    ///
    /// Those fields are plain decimal ASCII, so no sign and no base prefix: a
    /// `+`, a `-`, or a space is `error.InvalidCharacter`, and a value too
    /// large for `u32` is `error.Overflow`. `std.fmt.parseInt` takes all of
    /// those, which would turn a server bug into a position.
    pub fn number(self: Field) error{ InvalidCharacter, Overflow }!u32 {
        return atoi(u32, self.value);
    }
};

pub const Iterator = struct {
    reader: wire.Reader,

    pub const Error = wire.Error;

    pub fn init(body: []const u8) Iterator {
        return .{ .reader = .init(body) };
    }

    /// The next field, or null at the terminating zero.
    ///
    /// A body that runs out before the terminator is an error: the frame said
    /// there were more bytes than the field list accounts for.
    pub fn next(self: *Iterator) Error!?Field {
        const code = wire.peek(&self.reader) orelse return error.UnexpectedEof;
        _ = try self.reader.skip(1);
        if (code == 0) return null;

        return .{ .code = code, .value = try wire.takeString(&self.reader) };
    }
};

/// An `ErrorResponse` or `NoticeResponse` body.
pub fn fields(body: []const u8) Iterator {
    return .init(body);
}

test "the three fields every error has" {
    const body = "S" ++ "ERROR\x00" ++
        "C" ++ "42P01\x00" ++
        "M" ++ "relation \"x\" does not exist\x00" ++
        "\x00";
    var it = fields(body);

    const severity = (try it.next()).?;
    try testing.expectEqual(messages.ErrorField.severity, severity.kind().?);
    try testing.expectEqualStrings("ERROR", severity.value);

    const code = (try it.next()).?;
    try testing.expectEqual(messages.ErrorField.code, code.kind().?);
    try testing.expectEqualStrings("42P01", code.value);

    const message = (try it.next()).?;
    try testing.expectEqual(messages.ErrorField.message, message.kind().?);
    try testing.expectEqualStrings("relation \"x\" does not exist", message.value);

    try testing.expectEqual(@as(?Field, null), try it.next());
}

test "a code this library does not name is still a field" {
    // The registry is open past what the docs define, and dropping the field
    // would be worse than carrying a byte nobody reads.
    const body = "Z" ++ "something new\x00" ++ "\x00";
    var it = fields(body);

    const field = (try it.next()).?;
    try testing.expectEqual(@as(u8, 'Z'), field.code);
    try testing.expectEqual(@as(?messages.ErrorField, null), field.kind());
    try testing.expectEqualStrings("something new", field.value);
}

test "a position is a number, and text that is not one says so" {
    const body = "P" ++ "15\x00" ++ "M" ++ "syntax error\x00" ++ "\x00";
    var it = fields(body);

    const position = (try it.next()).?;
    try testing.expectEqual(@as(u32, 15), try position.number());

    const message = (try it.next()).?;
    try testing.expectError(error.InvalidCharacter, message.number());
}

test "the terminator alone is no fields" {
    var it = fields("\x00");
    try testing.expectEqual(@as(?Field, null), try it.next());
}

test "a body with no terminator is truncated" {
    var it = fields("S" ++ "ERROR\x00");
    _ = try it.next();
    try testing.expectError(error.UnexpectedEof, it.next());
}

test "an empty body is truncated, not empty" {
    // Every message of this kind ends with a zero byte, so zero bytes total
    // means the frame was cut short.
    var it = fields("");
    try testing.expectError(error.UnexpectedEof, it.next());
}
