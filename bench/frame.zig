//! Frame decoder benchmarks.
//!
//! The interesting number is bytes per second through the boundary finder,
//! because that is what a connection pays per read before any message body is
//! decoded. The stream is 64 `DataRow` messages of 40 bytes each: one column,
//! a 29-byte value, the shape a `SELECT` returns in bulk.

const std = @import("std");
const mem = std.mem;

const testingx = @import("testingx");
const pg = @import("pg");

/// One message: tag, length 39, one column of 29 bytes.
const row_len = 40;
const row_count = 64;

const stream: [row_len * row_count]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var bytes: [row_len * row_count]u8 = undefined;
    for (0..row_count) |i| {
        const at = i * row_len;
        bytes[at] = 'D';
        mem.writeInt(u32, bytes[at + 1 ..][0..4], 39, .big);
        mem.writeInt(u16, bytes[at + 5 ..][0..2], 1, .big);
        mem.writeInt(u32, bytes[at + 7 ..][0..4], 29, .big);
        @memset(bytes[at + 11 ..][0..29], 'x');
    }
    break :blk bytes;
};

pub fn benchmarkDecoderRows(b: *testingx.B) !void {
    const bytes = b.blackBox(&stream);
    var sink: u32 = 0;
    while (try b.loop()) {
        sink +%= try decode(bytes);
    }
    _ = b.blackBox(sink);
}

/// The same bytes through a decoder that sees them in 17-byte reads. Most
/// reads of a real connection split a header or a body, so this is the number
/// that matters more.
pub fn benchmarkDecoderSplitReads(b: *testingx.B) !void {
    const bytes = b.blackBox(&stream);
    var sink: u32 = 0;
    while (try b.loop()) {
        sink +%= try decodeChunked(bytes, 17);
    }
    _ = b.blackBox(sink);
}

/// The whole stream in one read, counting complete messages.
fn decode(bytes: []const u8) !u32 {
    var decoder: pg.frame.Decoder = .init;
    var rest = bytes;
    var complete: u32 = 0;

    while (rest.len != 0 or decoder.in_message) {
        const step = try decoder.next(rest);
        rest = rest[step.consumed..];

        switch (step.event) {
            .header => {},
            .body => |end| if (end) {
                complete += 1;
            },
            .more => break,
        }
    }
    return complete;
}

/// The same, with the input handed over `chunk` bytes at a time.
fn decodeChunked(bytes: []const u8, comptime chunk: u32) !u32 {
    var decoder: pg.frame.Decoder = .init;
    var complete: u32 = 0;
    var at: u32 = 0;

    while (at < bytes.len) {
        const end: u32 = @intCast(@min(bytes.len, at + chunk));
        var rest = bytes[at..end];

        while (rest.len != 0 or decoder.in_message) {
            const step = try decoder.next(rest);
            rest = rest[step.consumed..];

            switch (step.event) {
                .header => {},
                .body => |last| if (last) {
                    complete += 1;
                },
                .more => break,
            }
        }
        at = end;
    }
    return complete;
}
