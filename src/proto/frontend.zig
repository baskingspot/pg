//! Frontend messages: the ones a client sends.
//!
//! Each message is a value with an `encode` that writes it in the order the
//! docs list the fields, so a decoder in another language can be read against
//! it. The bytes of a message that never varies are built at comptime in
//! `fixed`, from these same encoders.

const std = @import("std");
const testing = std.testing;

const write = @import("write.zig");
const Encoder = write.Encoder;
const Error = write.Error;

/// The codepoints a parameter or result column can be in.
pub const Format = enum(u16) {
    text = 0,
    binary = 1,
};

/// `Q`. One or more statements, separated by semicolons, in one round trip.
pub const Query = struct {
    sql: []const u8,

    pub fn encode(self: Query, e: *Encoder) Error![]const u8 {
        try e.start(.query);
        try e.string(self.sql);
        return e.finish();
    }
};

/// `P`. Create or replace a prepared statement.
pub const Parse = struct {
    statement: []const u8 = "",
    sql: []const u8,
    /// A type OID per parameter, or none to let the server infer them. Zero
    /// means unspecified and is legal.
    types: []const u32 = &.{},

    pub fn encode(self: Parse, e: *Encoder) Error![]const u8 {
        try e.start(.parse);
        try e.string(self.statement);
        try e.string(self.sql);
        try e.int(u16, @intCast(self.types.len));
        for (self.types) |oid| try e.int(u32, oid);
        return e.finish();
    }
};

/// `B`. Bind a prepared statement to a portal, with the values.
pub const Bind = struct {
    portal: []const u8 = "",
    statement: []const u8 = "",
    /// No format codes means text for every parameter, one applies to all, and
    /// otherwise there is one per parameter.
    formats: []const Format = &.{},
    /// A null sends -1 and no bytes.
    parameters: []const ?[]const u8 = &.{},
    /// The same three shapes as `formats`, for the result columns.
    result_formats: []const Format = &.{},

    pub fn encode(self: Bind, e: *Encoder) Error![]const u8 {
        try e.start(.bind);
        try e.string(self.portal);
        try e.string(self.statement);

        try e.int(u16, @intCast(self.formats.len));
        for (self.formats) |format| try e.int(u16, @backingInt(format));

        try e.int(u16, @intCast(self.parameters.len));
        for (self.parameters) |parameter| {
            if (parameter) |bytes| {
                try e.int(i32, @intCast(bytes.len));
                try e.bytes(bytes);
            } else {
                try e.int(i32, -1);
            }
        }

        try e.int(u16, @intCast(self.result_formats.len));
        for (self.result_formats) |format| try e.int(u16, @backingInt(format));

        return e.finish();
    }
};

/// `D`. Ask for a statement's or a portal's description.
pub const Describe = struct {
    target: Target,
    name: []const u8 = "",

    pub const Target = enum(u8) {
        statement = 'S',
        portal = 'P',
    };

    pub fn encode(self: Describe, e: *Encoder) Error![]const u8 {
        try e.start(.describe);
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
        return e.finish();
    }
};

/// `E`. Run a portal, optionally for a limited number of rows.
pub const Execute = struct {
    portal: []const u8 = "",
    /// Zero means no limit.
    max_rows: u32 = 0,

    pub fn encode(self: Execute, e: *Encoder) Error![]const u8 {
        try e.start(.execute);
        try e.string(self.portal);
        try e.int(u32, self.max_rows);
        return e.finish();
    }
};

/// `S`. End an extended-protocol cycle; the server answers ReadyForQuery.
pub const Sync = struct {
    pub fn encode(_: Sync, e: *Encoder) Error![]const u8 {
        try e.start(.sync);
        return e.finish();
    }
};

/// `H`. Ask the server to send what it has without ending the cycle.
pub const Flush = struct {
    pub fn encode(_: Flush, e: *Encoder) Error![]const u8 {
        try e.start(.flush);
        return e.finish();
    }
};

/// `X`. End the session. The server sends nothing back.
pub const Terminate = struct {
    pub fn encode(_: Terminate, e: *Encoder) Error![]const u8 {
        try e.start(.terminate);
        return e.finish();
    }
};

/// `p`. A password, or an answer in the SASL conversation: the tag is the
/// same and the authentication state decides which this is.
pub const Password = struct {
    password: []const u8,

    pub fn encode(self: Password, e: *Encoder) Error![]const u8 {
        try e.start(.password);
        try e.string(self.password);
        return e.finish();
    }
};

/// `d`. A chunk of a copy-in stream.
pub const CopyData = struct {
    data: []const u8,

    pub fn encode(self: CopyData, e: *Encoder) Error![]const u8 {
        try e.start(.copy_data);
        try e.bytes(self.data);
        return e.finish();
    }
};

/// `c`. The end of a copy-in stream.
pub const CopyDone = struct {
    pub fn encode(_: CopyDone, e: *Encoder) Error![]const u8 {
        try e.start(.copy_done);
        return e.finish();
    }
};

/// `f`. Give up on a copy-in stream, with a reason the server reports.
pub const CopyFail = struct {
    reason: []const u8,

    pub fn encode(self: CopyFail, e: *Encoder) Error![]const u8 {
        try e.start(.copy_fail);
        try e.string(self.reason);
        return e.finish();
    }
};

/// Messages whose bytes never vary, built by running their encoder at comptime.
pub const fixed = struct {
    pub const sync = write.build(Sync{});
    pub const flush = write.build(Flush{});
    pub const terminate = write.build(Terminate{});
    pub const copy_done = write.build(CopyDone{});

    /// Bind the unnamed portal to the unnamed statement, with no parameters
    /// and no format codes.
    pub const bind_empty = write.build(Bind{});

    /// Describe the unnamed portal.
    pub const describe_portal = write.build(Describe{ .target = .portal });

    /// Execute the unnamed portal with no row limit.
    pub const execute_portal = write.build(Execute{});
};

test "the comptime bytes are the runtime bytes" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const query: Query = .{ .sql = "select 1" };
    try testing.expectEqualSlices(u8, &write.build(query), try query.encode(&encoder));
}

test "the fixed messages are what their encoders produce" {
    // The constants come from the encoders, so this is really a check on the
    // encoders: the bytes the docs give, one constant at a time.
    try testing.expectEqualSlices(u8, &.{ 'S', 0, 0, 0, 4 }, &fixed.sync);
    try testing.expectEqualSlices(u8, &.{ 'H', 0, 0, 0, 4 }, &fixed.flush);
    try testing.expectEqualSlices(u8, &.{ 'X', 0, 0, 0, 4 }, &fixed.terminate);
    try testing.expectEqualSlices(u8, &.{ 'c', 0, 0, 0, 4 }, &fixed.copy_done);
    try testing.expectEqualSlices(
        u8,
        &.{ 'B', 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0 },
        &fixed.bind_empty,
    );
    try testing.expectEqualSlices(u8, &.{ 'D', 0, 0, 0, 6, 'P', 0 }, &fixed.describe_portal);
    try testing.expectEqualSlices(u8, &.{ 'E', 0, 0, 0, 9, 0, 0, 0, 0, 0 }, &fixed.execute_portal);
}

test "a query is a tag, a length, and the statement" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const query: Query = .{ .sql = "select 1" };
    const message = try query.encode(&encoder);
    try testing.expectEqualSlices(u8, "Q\x00\x00\x00\x0dselect 1\x00", message);
}

test "an empty statement name is one zero byte" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const parse: Parse = .{ .sql = "select $1" };
    const message = try parse.encode(&encoder);
    try testing.expectEqualSlices(
        u8,
        "P\x00\x00\x00\x11\x00select $1\x00\x00\x00",
        message,
    );
}

test "a parameter is a length and its bytes, and NULL is -1" {
    var buffer: [64]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const bind: Bind = .{
        .statement = "s",
        .parameters = &.{ "one", null },
        .result_formats = &.{.binary},
    };
    const message = try bind.encode(&encoder);
    try testing.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x1a" ++
            "\x00" ++ "s\x00" ++
            "\x00\x00" ++
            "\x00\x02" ++
            "\x00\x00\x00\x03one" ++
            "\xff\xff\xff\xff" ++
            "\x00\x01" ++ "\x00\x01",
        message,
    );
}

test "a format applies to every parameter or to each one" {
    var buffer: [64]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    // One code means every parameter uses it, so the count is 1.
    const binary: Bind = .{ .formats = &.{.binary} };
    try testing.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x0e" ++
            "\x00" ++ "\x00" ++
            "\x00\x01" ++ "\x00\x01" ++
            "\x00\x00" ++
            "\x00\x00",
        try binary.encode(&encoder),
    );

    // Two codes mean one per parameter, and there are none, so this is a Bind
    // the server will reject. The encoder writes what it is told.
    const both: Bind = .{ .formats = &.{ .text, .binary } };
    try testing.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x10" ++
            "\x00" ++ "\x00" ++
            "\x00\x02" ++ "\x00\x00" ++ "\x00\x01" ++
            "\x00\x00" ++
            "\x00\x00",
        try both.encode(&encoder),
    );
}
