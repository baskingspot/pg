//! PostgreSQL message framing: a tag byte, a big-endian int32 length, and a
//! body.
//!
//! The length counts itself and the body but not the tag, so a message with an
//! empty body declares 4 and occupies 5 bytes. It must be at least 4, and the
//! server refuses anything of 1 GiB or more.
//!
//! The decoder never holds a body. It reports a header, then hands back body
//! bytes in the runs the caller feeds it, so a `DataRow` larger than the read
//! buffer costs nothing. A message with an empty body reports its header and
//! then one `.body` with `complete`, which consumes nothing: drive the loop on
//! `inMessage` as well as on unread bytes.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

const readInt = @import("mem.zig").readInt;

/// The largest message the protocol allows. The server's cap is below 2^30
/// bytes, and a length near 2^31 would overflow the arithmetic that windows a
/// body.
pub const max_length: u32 = 1 << 30;

/// A parsed header.
pub const Header = struct {
    /// The tag byte. Which enum it belongs to depends on who sent the message,
    /// so the decoder leaves it raw: `messages.Backend.fromByte`.
    tag: u8,

    /// The whole message after the tag, including these four bytes.
    length: u32,

    /// The bytes between the length and the next tag.
    pub fn bodyLength(self: Header) u32 {
        assert(self.length >= 4);
        return self.length - 4;
    }
};

pub const Error = error{
    /// A length below 4 counts less than the field that holds it.
    InvalidLength,
    /// A length of 1 GiB or more.
    MessageTooLong,
};

/// Finds message boundaries in a stream, in place.
pub const Decoder = struct {
    /// The tag, then the four length bytes, collected across however many
    /// reads it takes.
    bytes: [5]u8,
    filled: u3,

    /// Body bytes still owed to the current message.
    remaining: u32,
    in_message: bool,

    pub const init: Decoder = .{
        .bytes = undefined,
        .filled = 0,
        .remaining = 0,
        .in_message = false,
    };

    pub const Step = struct {
        /// Bytes taken from the input the caller passed. Never more than the
        /// header it completes or the body bytes it still owes, and a message
        /// is capped at 1 GiB, so `u32` covers it on every target.
        consumed: u32,
        event: Event,
    };

    pub const Event = union(enum) {
        /// A header. The body is still in the stream.
        header: Header,
        /// A run of body bytes was consumed. Always at least one byte.
        /// `complete` marks the last of the message, after which the next
        /// event is a header.
        body: bool,
        /// No progress: the input ran out. Always consumes nothing.
        more,
    };

    /// Drop a partial message. For a connection that is being torn down: an
    /// error from `next` leaves the decoder positioned at the bad header, and
    /// nothing useful can continue from there.
    pub fn reset(self: *Decoder) void {
        self.* = .init;
    }

    /// Take as much of `data` as the current message needs.
    ///
    /// At most one event per call. Every event but `.more` consumes at least
    /// one byte, so `.more` is the only time a caller loops without progress.
    pub fn next(self: *Decoder, data: []const u8) Error!Step {
        return if (self.in_message) self.skip(data) else self.collect(data);
    }

    fn collect(self: *Decoder, data: []const u8) Error!Step {
        const want: u32 = 5 - @as(u32, self.filled);
        const take: u32 = @intCast(@min(want, data.len));
        @memcpy(self.bytes[self.filled..][0..take], data[0..take]);
        self.filled += @intCast(take);

        if (self.filled < 5) return .{ .consumed = take, .event = .more };

        const length = readInt(u32, self.bytes[1..5]);
        self.filled = 0;
        if (length < 4) return error.InvalidLength;
        if (length > max_length) return error.MessageTooLong;

        self.remaining = length - 4;
        self.in_message = true;
        return .{
            .consumed = take,
            .event = .{ .header = .{ .tag = self.bytes[0], .length = length } },
        };
    }

    fn skip(self: *Decoder, data: []const u8) Step {
        const take: u32 = @intCast(@min(self.remaining, data.len));

        // An empty body ends on the next call even with nothing to feed it,
        // which is how a five-byte message reports its end. Body bytes that
        // are still owed need input, and saying so is what stops the caller's
        // loop from spinning.
        if (take == 0 and self.remaining != 0) return .{ .consumed = 0, .event = .more };

        self.remaining -= take;

        const complete = self.remaining == 0;
        if (complete) self.* = .init;
        return .{ .consumed = take, .event = .{ .body = complete } };
    }
};

/// Drive the decoder over a buffer and record how it split it.
const Slice = struct {
    tag: u8,
    length: u32,
    body: u32,
};

const Scan = struct {
    slices: []Slice = &.{},
    count: u32 = 0,
    ends: u32 = 0,

    fn run(self: *Scan, decoder: *Decoder, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0 or decoder.in_message) {
            const step = try decoder.next(rest);
            rest = rest[step.consumed..];

            switch (step.event) {
                .header => |header| {
                    self.slices[self.count] = .{
                        .tag = header.tag,
                        .length = header.length,
                        .body = 0,
                    };
                    self.count += 1;
                },
                .body => |complete| {
                    const slice = &self.slices[self.count - 1];
                    slice.body += step.consumed;
                    if (complete) self.ends += 1;
                },
                .more => {},
            }

            if (step.event == .more) break;
        }
    }
};

test "one message with a body" {
    // Query, length 13: the length field, then "select 1" and a null.
    const bytes = "Q\x00\x00\x00\x0dselect 1\x00";

    var decoder: Decoder = .init;
    var slices: [1]Slice = undefined;
    var scan: Scan = .{ .slices = &slices };
    try scan.run(&decoder, bytes);

    try testing.expectEqual(@as(u32, 1), scan.count);
    try testing.expectEqual(@as(u32, 1), scan.ends);
    try testing.expectEqual(@as(u8, 'Q'), slices[0].tag);
    try testing.expectEqual(@as(u32, 13), slices[0].length);
    try testing.expectEqual(@as(u32, 9), slices[0].body);
    try testing.expect(decoder.in_message == false);
}

test "an empty body still ends" {
    // Sync is five bytes: tag, length 4, nothing else. The header is the whole
    // message, and the end arrives as a second event that consumes nothing.
    var decoder: Decoder = .init;

    const sync = [_]u8{ 'S', 0, 0, 0, 4 };
    const first = try decoder.next(&sync);
    try testing.expectEqual(@as(u32, 5), first.consumed);
    try testing.expectEqual(@as(u32, 4), first.event.header.length);
    try testing.expect(decoder.in_message);

    const second = try decoder.next("");
    try testing.expectEqual(@as(u32, 0), second.consumed);
    try testing.expect(second.event.body);
    try testing.expect(decoder.in_message == false);
}

test "one byte at a time" {
    const bytes = "S\x00\x00\x00\x04Z\x00\x00\x00\x05I";

    var decoder: Decoder = .init;
    var slices: [2]Slice = undefined;
    var scan: Scan = .{ .slices = &slices };

    for (bytes, 0..) |_, i| {
        try scan.run(&decoder, bytes[i .. i + 1]);
    }

    try testing.expectEqual(@as(u32, 2), scan.count);
    try testing.expectEqual(@as(u32, 2), scan.ends);
    try testing.expectEqual(@as(u32, 4), slices[0].length);
    // ReadyForQuery carries the transaction status byte, so its body run is
    // one byte long even when it arrives separately from the header.
    try testing.expectEqual(@as(u32, 1), slices[1].body);
    try testing.expectEqual(@as(u8, 'I'), bytes[bytes.len - 1]);
}

test "a length of three is rejected" {
    var decoder: Decoder = .init;
    try testing.expectError(error.InvalidLength, decoder.next("Q\x00\x00\x00\x03"));
}

test "a length of a gigabyte is rejected" {
    var decoder: Decoder = .init;
    try testing.expectError(error.MessageTooLong, decoder.next("Q\x40\x00\x00\x01"));
}

test "the largest allowed length parses" {
    var decoder: Decoder = .init;
    const step = try decoder.next("D\x40\x00\x00\x00");
    try testing.expectEqual(max_length, step.event.header.length);
    try testing.expectEqual(@as(u32, max_length - 4), step.event.header.bodyLength());
}

test "interleaved messages in one buffer" {
    // BindComplete, then a DataRow with two columns.
    const bytes = "2\x00\x00\x00\x04" ++
        "D\x00\x00\x00\x14" ++
        "\x00\x02" ++
        "\x00\x00\x00\x03\x6f\x6e\x65" ++
        "\x00\x00\x00\x03\x74\x77\x6f";

    var decoder: Decoder = .init;
    var slices: [2]Slice = undefined;
    var scan: Scan = .{ .slices = &slices };
    try scan.run(&decoder, bytes);

    try testing.expectEqual(@as(u32, 2), scan.count);
    try testing.expectEqual(@as(u32, 2), scan.ends);
    try testing.expectEqual(@as(u32, 0), slices[0].body);
    try testing.expectEqual(@as(u32, 20 - 4), slices[1].body);
}
