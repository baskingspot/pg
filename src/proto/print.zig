//! Printing a value for a log line or a test failure.
//!
//! A message has one useful rendering for a human, and it is not its bytes.
//! Two rules keep a debug print safe: a string is quoted and escaped so a
//! newline in a query cannot split a log line, and a value that can be huge or
//! secret prints as a size instead of its contents.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

/// Bytes as a quoted string, with the escapes `std.zig.stringEscape` makes.
pub fn quoted(bytes: []const u8) Quoted {
    return .{ .bytes = bytes };
}

pub const Quoted = struct {
    bytes: []const u8,

    pub fn format(self: *const Quoted, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeByte('"');
        try std.zig.stringEscape(self.bytes, writer);
        try writer.writeByte('"');
    }
};

/// An enum from the wire: its tag name when this library declares that tag,
/// and the number when it does not.
///
/// `{t}` on an unknown value of a non-exhaustive enum panics, and a decoder
/// can produce one from any byte, so a log line cannot use it. This is the
/// fuzzer's first find.
pub fn tag(comptime E: type, value: E) Tag(E) {
    return .{ .value = value };
}

pub fn Tag(comptime E: type) type {
    return struct {
        const Self = @This();

        value: E,

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            inline for (std.enums.values(E)) |declared| {
                if (@backingInt(declared) == @backingInt(self.value)) {
                    return writer.print(".{t}", .{declared});
                }
            }
            try writer.print("{d}", .{@backingInt(self.value)});
        }
    };
}

/// A value whose contents stay out of the line: a password, or a copy stream.
pub fn blob(bytes: []const u8) Blob {
    return .{ .len = bytes.len };
}

pub const Blob = struct {
    len: usize,

    pub fn format(self: *const Blob, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("<{d} bytes>", .{self.len});
    }
};

test "quoted escapes what would break a line" {
    try testing.expectFmt("\"a\\nb\"", "{f}", .{quoted("a\nb")});
    try testing.expectFmt("\"\"", "{f}", .{quoted("")});
    try testing.expectFmt("\"it's\"", "{f}", .{quoted("it's")});
}

test "blob prints a size" {
    try testing.expectFmt("<10 bytes>", "{f}", .{blob("0123456789")});
}
