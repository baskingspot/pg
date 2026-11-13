//! Frontend messages: the ones a client sends.
//!
//! `Message` is a union tagged by `messages.Frontend`, so the arm name and the
//! tag byte are the same fact. Each arm holds a value whose `write` emits the
//! fields in the order the docs list them; the union writes the tag and the
//! length. That is what makes it impossible for a `Query` to carry a `parse`
//! tag.
//!
//! The bytes of a message that never varies are built at comptime in `fixed`,
//! from these same writers.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const messages = @import("messages.zig");
const print = @import("print.zig");
const write = @import("write.zig");
const Encoder = write.Encoder;
const Error = write.Error;

/// The codepoints a parameter or result column can be in.
pub const Format = enum(u16) {
    text = 0,
    binary = 1,
};

/// Whether a name refers to a prepared statement or to a portal.
pub const Target = enum(u8) {
    statement = 'S',
    portal = 'P',
};

/// A value, or a SQL NULL, which is a length of -1 and no bytes.
fn writeValues(e: *Encoder, values: []const ?[]const u8) Error!void {
    for (values) |value| {
        if (value) |bytes| {
            try e.int(i32, @intCast(bytes.len));
            try e.bytes(bytes);
        } else {
            try e.int(i32, -1);
        }
    }
}

fn writeFormats(e: *Encoder, formats: []const Format) Error!void {
    for (formats) |code| try e.int(u16, @backingInt(code));
}

/// `Q`. One or more statements, separated by semicolons, in one round trip.
pub const Query = struct {
    sql: []const u8,

    pub fn write(self: Query, e: *Encoder) Error!void {
        try e.string(self.sql);
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

    pub fn write(self: Parse, e: *Encoder) Error!void {
        try e.string(self.statement);
        try e.string(self.sql);
        try e.int(u16, @intCast(self.types.len));
        for (self.types) |oid| try e.int(u32, oid);
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
    parameters: []const ?[]const u8 = &.{},
    /// The same three shapes as `formats`, for the result columns.
    result_formats: []const Format = &.{},

    pub fn write(self: Bind, e: *Encoder) Error!void {
        try e.string(self.portal);
        try e.string(self.statement);

        try e.int(u16, @intCast(self.formats.len));
        try writeFormats(e, self.formats);

        try e.int(u16, @intCast(self.parameters.len));
        try writeValues(e, self.parameters);

        try e.int(u16, @intCast(self.result_formats.len));
        try writeFormats(e, self.result_formats);
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

/// `C`. Drop a prepared statement or a portal.
pub const Close = struct {
    target: Target,
    name: []const u8 = "",

    pub fn write(self: Close, e: *Encoder) Error!void {
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
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

    pub fn write(self: Describe, e: *Encoder) Error!void {
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
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

    pub fn write(self: Execute, e: *Encoder) Error!void {
        try e.string(self.portal);
        try e.int(u32, self.max_rows);
    }

    pub fn format(self: Execute, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Execute{{ .portal = {f}, .max_rows = {d} }}", .{
            print.quoted(self.portal),
            self.max_rows,
        });
    }
};

/// `F`. Call a function directly, one round trip and no SQL. Obsolete: the
/// extended protocol replaced it, and the server still accepts it.
pub const FunctionCall = struct {
    function: u32,
    formats: []const Format = &.{},
    arguments: []const ?[]const u8 = &.{},
    result_format: Format = .text,

    pub fn write(self: FunctionCall, e: *Encoder) Error!void {
        try e.int(u32, self.function);
        try e.int(u16, @intCast(self.formats.len));
        try writeFormats(e, self.formats);
        try e.int(u16, @intCast(self.arguments.len));
        try writeValues(e, self.arguments);
        try e.int(u16, @backingInt(self.result_format));
    }

    pub fn format(self: FunctionCall, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("FunctionCall{{ .function = {d}, .arguments = {d} }}", .{
            self.function,
            self.arguments.len,
        });
    }
};

/// `H`. Ask the server to send what it has without ending the cycle.
pub const Flush = struct {
    pub fn write(_: Flush, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Flush, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Flush");
    }
};

/// `S`. End an extended-protocol cycle; the server answers ReadyForQuery.
pub const Sync = struct {
    pub fn write(_: Sync, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Sync, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Sync");
    }
};

/// `X`. End the session. The server sends nothing back.
pub const Terminate = struct {
    pub fn write(_: Terminate, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Terminate, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Terminate");
    }
};

/// `p`. A password, or an answer in the SASL conversation: the tag is the
/// same and the authentication state decides which this is.
pub const Password = struct {
    password: []const u8,

    pub fn write(self: Password, e: *Encoder) Error!void {
        try e.string(self.password);
    }

    pub fn format(self: Password, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Password{{ {f} }}", .{print.blob(self.password)});
    }
};

/// `d`. A chunk of a copy-in stream.
pub const CopyData = struct {
    data: []const u8,

    pub fn write(self: CopyData, e: *Encoder) Error!void {
        try e.bytes(self.data);
    }

    pub fn format(self: CopyData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyData{{ {f} }}", .{print.blob(self.data)});
    }
};

/// `c`. The end of a copy-in stream.
pub const CopyDone = struct {
    pub fn write(_: CopyDone, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: CopyDone, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("CopyDone");
    }
};

/// `f`. Give up on a copy-in stream, with a reason the server reports.
pub const CopyFail = struct {
    reason: []const u8,

    pub fn write(self: CopyFail, e: *Encoder) Error!void {
        try e.string(self.reason);
    }

    pub fn format(self: CopyFail, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyFail{{ .reason = {f} }}", .{print.quoted(self.reason)});
    }
};

/// A frontend message, one arm per tag a client can send.
///
/// The tag is `messages.Frontend`, so an arm's name is its wire byte and the
/// union cannot be a version of the protocol behind the enum it is tagged by.
pub const Message = union(messages.Frontend) {
    bind: Bind,
    close: Close,
    describe: Describe,
    execute: Execute,
    function_call: FunctionCall,
    flush: Flush,
    parse: Parse,
    query: Query,
    sync: Sync,
    terminate: Terminate,
    copy_data: CopyData,
    copy_done: CopyDone,
    copy_fail: CopyFail,
    password: Password,

    pub fn encode(self: Message, e: *Encoder) Error![]const u8 {
        return switch (self) {
            inline else => |body, tag| blk: {
                try e.start(tag);
                try body.write(e);
                break :blk e.finish();
            },
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

/// Encode one message into a fresh buffer and hand back its bytes.
fn encoded(message: Message, buffer: []u8) Error![]const u8 {
    var e: Encoder = .init;
    e.reset(buffer);
    return message.encode(&e);
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

/// A message with every field filled in enough to encode.
fn sample(comptime T: type) T {
    if (T == Query) return .{ .sql = "q" };
    if (T == Parse) return .{ .sql = "q" };
    if (T == Password) return .{ .password = "p" };
    if (T == CopyData) return .{ .data = "d" };
    if (T == CopyFail) return .{ .reason = "r" };
    if (T == FunctionCall) return .{ .function = 1 };
    if (T == Close) return .{ .target = .statement };
    if (T == Describe) return .{ .target = .statement };
    return .{};
}

test "the arm's name is the wire tag" {
    // The union is tagged by the protocol enum, so this is the compiler's job
    // already. The test pins that the encoder reads the tag from the union and
    // not from the body's own opinion.
    const info = @typeInfo(Message).@"union";
    inline for (info.field_names, info.field_types) |name, T| {
        var buffer: [256]u8 = undefined;
        var e: Encoder = .init;
        e.reset(&buffer);

        const message: Message = @unionInit(Message, name, sample(T));
        const bytes = try message.encode(&e);
        const expected: u8 = @backingInt(@field(messages.Frontend, name));
        try testing.expectEqual(expected, bytes[0]);
    }
}

test "the comptime bytes are the runtime bytes" {
    var buffer: [32]u8 = undefined;
    const query: Query = .{ .sql = "select 1" };
    const built = write.build(.{ .query = query });
    try testing.expectEqualSlices(u8, &built, try encoded(.{ .query = query }, &buffer));
}

test "the fixed messages are what their encoders produce" {
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
    const message = try encoded(.{ .query = .{ .sql = "select 1" } }, &buffer);
    try testing.expectEqualSlices(u8, "Q\x00\x00\x00\x0dselect 1\x00", message);
}

test "an empty statement name is one zero byte" {
    var buffer: [32]u8 = undefined;
    const message = try encoded(.{ .parse = .{ .sql = "select $1" } }, &buffer);
    try testing.expectEqualSlices(u8, "P\x00\x00\x00\x11\x00select $1\x00\x00\x00", message);
}

test "a parameter is a length and its bytes, and NULL is -1" {
    var buffer: [64]u8 = undefined;
    const message = try encoded(.{
        .bind = .{
            .statement = "s",
            .parameters = &.{ "one", null },
            .result_formats = &.{.binary},
        },
    }, &buffer);
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

    // One code means every parameter uses it, so the count is 1.
    try testing.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x0e" ++
            "\x00" ++ "\x00" ++
            "\x00\x01" ++ "\x00\x01" ++
            "\x00\x00" ++
            "\x00\x00",
        try encoded(.{ .bind = .{ .formats = &.{.binary} } }, &buffer),
    );

    // Two codes mean one per parameter, and there are none, so this is a Bind
    // the server will reject. The encoder writes what it is told.
    try testing.expectEqualSlices(
        u8,
        "B\x00\x00\x00\x10" ++
            "\x00" ++ "\x00" ++
            "\x00\x02" ++ "\x00\x00" ++ "\x00\x01" ++
            "\x00\x00" ++
            "\x00\x00",
        try encoded(.{ .bind = .{ .formats = &.{ .text, .binary } } }, &buffer),
    );
}
