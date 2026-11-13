//! Frontend messages: the ones a client sends.
//!
//! Each message is a value with an `encode` that writes it in the order the
//! docs list the fields, so a decoder in another language can be read against
//! it. The bytes of a message that never varies are built at comptime in
//! `fixed`, from these same encoders.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const print = @import("print.zig");
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
    pub fn format(self: Query, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Query{{ .sql = {f} }}", .{print.quoted(self.sql)});
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
    pub fn format(self: Parse, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Parse{{ .statement = {f}, .sql = {f}, .types = {{", .{
            print.quoted(self.statement),
            print.quoted(self.sql),
        });
        for (self.types, 0..) |oid, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{d}", .{oid});
        }
        try writer.writeAll("} }");
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
        for (self.formats) |code| try e.int(u16, @backingInt(code));

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
        for (self.result_formats) |code| try e.int(u16, @backingInt(code));

        return e.finish();
    }
    pub fn format(self: Bind, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            "Bind{{ .portal = {f}, .statement = {f}, " ++
                ".formats = {d}, .parameters = {d}, .result_formats = {d} }}",
            .{
                print.quoted(self.portal),
                print.quoted(self.statement),
                self.formats.len,
                self.parameters.len,
                self.result_formats.len,
            },
        );
    }
};

/// Whether a name refers to a prepared statement or to a portal.
pub const Target = enum(u8) {
    statement = 'S',
    portal = 'P',
};

/// `C`. Drop a prepared statement or a portal.
pub const Close = struct {
    target: Target,
    name: []const u8 = "",

    pub fn encode(self: Close, e: *Encoder) Error![]const u8 {
        try e.start(.close);
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
        return e.finish();
    }
    pub fn format(self: Close, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Close{{ .target = .{t}, .name = {f} }}", .{
            self.target,
            print.quoted(self.name),
        });
    }
};

/// `D`. Ask for a statement's or a portal's description.
pub const Describe = struct {
    target: Target,
    name: []const u8 = "",

    pub fn encode(self: Describe, e: *Encoder) Error![]const u8 {
        try e.start(.describe);
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
        return e.finish();
    }
    pub fn format(self: Describe, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Describe{{ .target = .{t}, .name = {f} }}", .{
            self.target,
            print.quoted(self.name),
        });
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
    pub fn format(self: Execute, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Execute{{ .portal = {f}, .max_rows = {d} }}", .{
            print.quoted(self.portal),
            self.max_rows,
        });
    }
};

/// `S`. End an extended-protocol cycle; the server answers ReadyForQuery.
pub const Sync = struct {
    pub fn encode(_: Sync, e: *Encoder) Error![]const u8 {
        try e.start(.sync);
        return e.finish();
    }
    pub fn format(self: Sync, writer: *Io.Writer) Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("Sync");
    }
};

/// `H`. Ask the server to send what it has without ending the cycle.
pub const Flush = struct {
    pub fn encode(_: Flush, e: *Encoder) Error![]const u8 {
        try e.start(.flush);
        return e.finish();
    }
    pub fn format(self: Flush, writer: *Io.Writer) Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("Flush");
    }
};

/// `X`. End the session. The server sends nothing back.
pub const Terminate = struct {
    pub fn encode(_: Terminate, e: *Encoder) Error![]const u8 {
        try e.start(.terminate);
        return e.finish();
    }
    pub fn format(self: Terminate, writer: *Io.Writer) Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("Terminate");
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
    pub fn format(self: Password, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Password{{ {f} }}", .{print.blob(self.password)});
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
    pub fn format(self: CopyData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyData{{ {f} }}", .{print.blob(self.data)});
    }
};

/// `c`. The end of a copy-in stream.
pub const CopyDone = struct {
    pub fn encode(_: CopyDone, e: *Encoder) Error![]const u8 {
        try e.start(.copy_done);
        return e.finish();
    }
    pub fn format(self: CopyDone, writer: *Io.Writer) Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("CopyDone");
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
    pub fn format(self: CopyFail, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyFail{{ .reason = {f} }}", .{print.quoted(self.reason)});
    }
};

/// A frontend message, one per tag a client sends.
///
/// The union is what makes `build` strongly typed: a call site writes
/// `.query = .{ .sql = "select 1" }` and the payload type comes from the arm.
pub const Message = union(enum) {
    bind: Bind,
    close: Close,
    copy_data: CopyData,
    copy_done: CopyDone,
    copy_fail: CopyFail,
    describe: Describe,
    execute: Execute,
    flush: Flush,
    parse: Parse,
    password: Password,
    query: Query,
    sync: Sync,
    terminate: Terminate,

    pub fn encode(self: Message, e: *Encoder) Error![]const u8 {
        return switch (self) {
            inline else => |body| body.encode(e),
        };
    }

    pub fn format(self: Message, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            inline else => |body| try body.format(writer),
        }
    }
};

/// Messages whose bytes never vary, built by running their encoder at comptime.
pub const fixed = struct {
    pub const sync = write.build(.{ .sync = .{} });
    pub const flush = write.build(.{ .flush = .{} });
    pub const terminate = write.build(.{ .terminate = .{} });
    pub const copy_done = write.build(.{ .copy_done = .{} });

    /// Bind the unnamed portal to the unnamed statement, with no parameters
    /// and no format codes.
    pub const bind_empty = write.build(.{ .bind = .{} });

    /// Describe the unnamed portal.
    pub const describe_portal = write.build(.{ .describe = .{ .target = .portal } });

    /// Execute the unnamed portal with no row limit.
    pub const execute_portal = write.build(.{ .execute = .{} });
};

test "the comptime bytes are the runtime bytes" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const query: Query = .{ .sql = "select 1" };
    const built = write.build(.{ .query = query });
    try testing.expectEqualSlices(u8, &built, try query.encode(&encoder));
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

test "a message prints as itself" {
    try testing.expectFmt("Query{ .sql = \"select 1\" }", "{f}", .{
        Query{ .sql = "select 1" },
    });
    try testing.expectFmt("Parse{ .statement = \"\", .sql = \"select $1\", .types = {} }", "{f}", .{
        Parse{ .sql = "select $1" },
    });
    try testing.expectFmt("Parse{ .statement = \"s\", .sql = \"q\", .types = {23, 25} }", "{f}", .{
        Parse{ .statement = "s", .sql = "q", .types = &.{ 23, 25 } },
    });
    try testing.expectFmt(
        "Bind{ .portal = \"\", .statement = \"\", " ++
            ".formats = 0, .parameters = 0, .result_formats = 0 }",
        "{f}",
        .{Bind{}},
    );
    try testing.expectFmt("Close{ .target = .statement, .name = \"s\" }", "{f}", .{
        Close{ .target = .statement, .name = "s" },
    });
    try testing.expectFmt("Execute{ .portal = \"p\", .max_rows = 10 }", "{f}", .{
        Execute{ .portal = "p", .max_rows = 10 },
    });
    try testing.expectFmt("Sync", "{f}", .{Sync{}});
    try testing.expectFmt("Terminate", "{f}", .{Terminate{}});
}

test "a password and a copy stream print as a size" {
    // A log line is forever, and so is a credential in one.
    try testing.expectFmt("Password{ <7 bytes> }", "{f}", .{Password{ .password = "hunter2" }});
    try testing.expectFmt("CopyData{ <3 bytes> }", "{f}", .{CopyData{ .data = "abc" }});
}

test "the union prints as the arm it holds" {
    const message: Message = .{ .sync = .{} };
    try testing.expectFmt("Sync", "{f}", .{message});

    const query: Message = .{ .query = .{ .sql = "select 1" } };
    try testing.expectFmt("Query{ .sql = \"select 1\" }", "{f}", .{query});
}

test "the union names the arm, and the bytes follow" {
    const built = write.build(.{ .query = .{ .sql = "select 1" } });
    try testing.expectEqualSlices(u8, "Q\x00\x00\x00\x0dselect 1\x00", &built);
}

test "close names a statement or a portal" {
    var buffer: [32]u8 = undefined;
    var encoder: Encoder = .init;
    encoder.reset(&buffer);

    const close: Close = .{ .target = .statement, .name = "s" };
    try testing.expectEqualSlices(u8, "C\x00\x00\x00\x07Ss\x00", try close.encode(&encoder));
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
