//! Decoding a backend message: the tag dispatch, and one row of a result.
//!
//! The dispatch is the first thing a client pays per message and it happens
//! once per row, so it belongs in the suite even though the body decode is
//! most of the work.
//!
//! The input is sixty-four different rows rather than one repeated: a single
//! constant body lets the optimizer hoist the whole decode out of the loop, and
//! the first version of this benchmark reported a nanosecond for sixty-four of
//! them.

const std = @import("std");

const testingx = @import("testingx");
const pg = @import("pg");

const count = 64;
/// A one-column row: the count, a length, and the value.
const body_len = 2 + 4 + 26;
const payload = body_len - 2 - 4;

const bodies: [count * body_len]u8 = blk: {
    @setEvalBranchQuota(4_000);
    var bytes: [count * body_len]u8 = undefined;
    for (0..count) |i| {
        const at = i * body_len;
        std.mem.writeInt(u16, bytes[at..][0..2], 1, .big);
        std.mem.writeInt(i32, bytes[at + 2 ..][0..4], payload, .big);
        for (0..payload) |j| bytes[at + 6 + j] = @intCast('a' + (i + j) % 26);
    }
    break :blk bytes;
};

pub fn benchmarkDecode(b: *testingx.B) !void {
    const bytes = b.blackBox(&bodies);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (0..count) |i| {
            const body = bytes[i * body_len ..][0..body_len];
            const message = try pg.backend.Message.decode('D', body);
            sink +%= message.data_row.columns;
        }
    }
    _ = b.blackBox(sink);
}
