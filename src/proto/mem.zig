//! The protocol's integer encoding: big-endian, always.
//!
//! No field in the PostgreSQL protocol is little-endian, so the endianness
//! argument `std.mem` takes is noise at every call site and a way to write a
//! length backwards once. These are that call with `.big` baked in, and the
//! buffer width derived from the type, so `writeInt(u16, ...)` takes a
//! `*[2]u8` and a mismatch fails to compile.

const std = @import("std");
const mem = std.mem;

pub inline fn writeInt(
    comptime T: type,
    buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
    value: T,
) void {
    mem.writeInt(T, buffer, value, .big);
}

pub inline fn readInt(
    comptime T: type,
    buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8,
) T {
    return mem.readInt(T, buffer, .big);
}
