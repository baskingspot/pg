//! Turning a tag byte into a message type.
//!
//! A decoder does this once per message. Three ways to do it, on the same
//! input in the same binary, because separate runs on this machine disagree
//! with each other by more than the difference between them.

const std = @import("std");

const testingx = @import("testingx");
const pg = @import("pg");

const Backend = pg.messages.Backend;
const enums = std.enums;

/// The shipped path, through `Backend.fromByte` and its error union.
///
/// Three ways to do the conversion on the same input in one binary, 1024 bytes
/// per pass, this machine:
///
///            hit     miss
///   scan     473      686    std.enums.fromInt, a linear scan over the variants
///   arms    1185      803    a hand-written switch, which compiles to an
///                            indirect branch the predictor cannot learn
///   table    373      346    one indexed load
///
/// The table is what `fromByte` does, and `fromByte` is `inline`: as a plain
/// call it measured 1078 ns against 366, because the error union and the call
/// cost more than the lookup. Through `fromByte` on the miss input, before and
/// after the table and the inline: 1201 ns and 358 ns.
///
/// Every tag the backend can send, repeated. The hit path, and what a working
/// connection delivers.
const tags: [1024]u8 = blk: {
    @setEvalBranchQuota(2_000);
    const known = enums.values(Backend);
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @backingInt(known[i % known.len]);
    break :blk bytes;
};

/// The ASCII range, so four out of five bytes are not a tag at all. The miss
/// path, and what a corrupt frame does.
const ascii: [1024]u8 = blk: {
    @setEvalBranchQuota(2_000);
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i % 128);
    break :blk bytes;
};

fn bench(b: *testingx.B, comptime bytes: *const [1024]u8) !void {
    const input = b.blackBox(bytes);
    var sink: u32 = 0;
    while (try b.loop()) {
        for (input) |byte| {
            const tag = Backend.fromByte(byte) catch continue;
            sink +%= @backingInt(tag);
        }
    }
    _ = b.blackBox(sink);
}

pub fn benchmarkTagHit(b: *testingx.B) !void {
    try bench(b, &tags);
}

pub fn benchmarkTagMiss(b: *testingx.B) !void {
    try bench(b, &ascii);
}
