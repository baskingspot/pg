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
const wire = @import("wire.zig");
const print = @import("print.zig");
const write = @import("write.zig");
const Encoder = write.Encoder;
const Error = write.Error;
const DecodeError = wire.Error;

/// The codepoints a parameter or result column can be in.
pub const Format = enum(u16) {
    text = 0,
    binary = 1,
};

/// Whether a name refers to a prepared statement or to a portal.
///
/// Non-exhaustive for the same reason the message tags are: the byte comes off
/// the wire, and a decoder that panicked on a byte it did not expect would
/// turn a bad client into a dead server.
pub const Target = enum(u8) {
    statement = 'S',
    portal = 'P',
    _,
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

    pub fn decode(body: []const u8) DecodeError!Query {
        var reader: wire.Reader = .init(body);
        return .{ .sql = try wire.takeString(&reader) };
    }

    pub fn write(self: *const Query, e: *Encoder) Error!void {
        try e.string(self.sql);
    }

    pub fn format(self: *const Query, writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn write(self: *const Parse, e: *Encoder) Error!void {
        try e.string(self.statement);
        try e.string(self.sql);
        try e.int(u16, @intCast(self.types.len));
        for (self.types) |oid| try e.int(u32, oid);
    }

    pub fn format(self: *const Parse, writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn write(self: *const Bind, e: *Encoder) Error!void {
        try e.string(self.portal);
        try e.string(self.statement);

        try e.int(u16, @intCast(self.formats.len));
        try writeFormats(e, self.formats);

        try e.int(u16, @intCast(self.parameters.len));
        try writeValues(e, self.parameters);

        try e.int(u16, @intCast(self.result_formats.len));
        try writeFormats(e, self.result_formats);
    }

    pub fn format(self: *const Bind, writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn decode(body: []const u8) DecodeError!Close {
        var reader: wire.Reader = .init(body);
        return .{
            .target = @fromBackingInt(try reader.read(u8)),
            .name = try wire.takeString(&reader),
        };
    }

    pub fn write(self: *const Close, e: *Encoder) Error!void {
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
    }

    pub fn format(self: *const Close, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Close{{ .target = {f}, .name = {f} }}", .{
            print.tag(Target, self.target),
            print.quoted(self.name),
        });
    }
};

/// `D`. Ask for a statement's or a portal's description.
pub const Describe = struct {
    target: Target,
    name: []const u8 = "",

    pub fn decode(body: []const u8) DecodeError!Describe {
        var reader: wire.Reader = .init(body);
        return .{
            .target = @fromBackingInt(try reader.read(u8)),
            .name = try wire.takeString(&reader),
        };
    }

    pub fn write(self: *const Describe, e: *Encoder) Error!void {
        try e.int(u8, @backingInt(self.target));
        try e.string(self.name);
    }

    pub fn format(self: *const Describe, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Describe{{ .target = {f}, .name = {f} }}", .{
            print.tag(Target, self.target),
            print.quoted(self.name),
        });
    }
};

/// `E`. Run a portal, optionally for a limited number of rows.
pub const Execute = struct {
    portal: []const u8 = "",
    /// Zero means no limit.
    max_rows: u32 = 0,

    pub fn decode(body: []const u8) DecodeError!Execute {
        var reader: wire.Reader = .init(body);
        return .{
            .portal = try wire.takeString(&reader),
            .max_rows = try reader.read(u32),
        };
    }

    pub fn write(self: *const Execute, e: *Encoder) Error!void {
        try e.string(self.portal);
        try e.int(u32, self.max_rows);
    }

    pub fn format(self: *const Execute, writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn write(self: *const FunctionCall, e: *Encoder) Error!void {
        try e.int(u32, self.function);
        try e.int(u16, @intCast(self.formats.len));
        try writeFormats(e, self.formats);
        try e.int(u16, @intCast(self.arguments.len));
        try writeValues(e, self.arguments);
        try e.int(u16, @backingInt(self.result_format));
    }

    pub fn format(self: *const FunctionCall, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("FunctionCall{{ .function = {d}, .arguments = {d} }}", .{
            self.function,
            self.arguments.len,
        });
    }
};

/// `H`. Ask the server to send what it has without ending the cycle.
pub const Flush = struct {
    pub fn decode(body: []const u8) DecodeError!Flush {
        if (body.len != 0) return DecodeError.UnexpectedEof;
        return .{};
    }

    pub fn write(_: Flush, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Flush, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Flush");
    }
};

/// `S`. End an extended-protocol cycle; the server answers ReadyForQuery.
pub const Sync = struct {
    pub fn decode(body: []const u8) DecodeError!Sync {
        if (body.len != 0) return DecodeError.UnexpectedEof;
        return .{};
    }

    pub fn write(_: Sync, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Sync, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Sync");
    }
};

/// `X`. End the session. The server sends nothing back.
pub const Terminate = struct {
    pub fn decode(body: []const u8) DecodeError!Terminate {
        if (body.len != 0) return DecodeError.UnexpectedEof;
        return .{};
    }

    pub fn write(_: Terminate, e: *Encoder) Error!void {
        _ = e;
    }

    pub fn format(_: Terminate, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Terminate");
    }
};

/// A `SASLInitialResponse`: the mechanism the client chose and its first
/// message.
pub const SaslInitial = struct {
    mechanism: []const u8,
    /// Null when the client sent no initial response, which the wire marks
    /// with a length of -1 rather than a zero length.
    response: ?[]const u8,

    pub fn decode(body: []const u8) DecodeError!SaslInitial {
        var reader: wire.Reader = .init(body);
        const mechanism = try wire.takeString(&reader);

        const length = try reader.read(i32);
        if (length == -1) return .{ .mechanism = mechanism, .response = null };
        if (length < 0) return DecodeError.UnexpectedEof;

        return .{
            .mechanism = mechanism,
            .response = try reader.readSlice(@intCast(length)),
        };
    }

    pub fn write(self: *const SaslInitial, e: *Encoder) Error!void {
        try e.string(self.mechanism);
        if (self.response) |response| {
            try e.int(i32, @intCast(response.len));
            try e.bytes(response);
        } else {
            try e.int(i32, -1);
        }
    }

    pub fn format(self: *const SaslInitial, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("SaslInitial{{ .mechanism = {f}, .response = {d} }}", .{
            print.quoted(self.mechanism),
            if (self.response) |response| response.len else 0,
        });
    }
};

/// `p`. The one tag four messages share. Which one this is comes from the
/// authentication conversation, not from the byte, so a writer names it.
pub const Password = union(enum) {
    /// `PasswordMessage`: the password, null-terminated.
    cleartext: []const u8,
    /// `SASLInitialResponse`.
    sasl_initial: SaslInitial,
    /// `SASLResponse`: mechanism data, with no length and no terminator.
    sasl_response: []const u8,
    /// `GSSResponse`: the same shape as a SASL response.
    gss: []const u8,

    pub fn write(self: *const Password, e: *Encoder) Error!void {
        switch (self.*) {
            .cleartext => |password| try e.string(password),
            .sasl_initial => |initial| try initial.write(e),
            .sasl_response => |data| try e.bytes(data),
            .gss => |data| try e.bytes(data),
        }
    }

    pub fn format(self: *const Password, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.*) {
            .cleartext => |password| try writer.print("Password{{ .cleartext = {f} }}", .{
                print.blob(password),
            }),
            .sasl_initial => |initial| try writer.print("Password{{ .sasl_initial = {f} }}", .{
                initial,
            }),
            .sasl_response => |data| try writer.print("Password{{ .sasl_response = {f} }}", .{
                print.blob(data),
            }),
            .gss => |data| try writer.print("Password{{ .gss = {f} }}", .{print.blob(data)}),
        }
    }
};

/// A decoded `p` body, for the server side.
///
/// The body is kept as it arrived, because the four messages it could be are
/// told apart by the conversation rather than by the tag. The accessors are
/// how a caller who knows asks.
pub const PasswordBody = struct {
    body: []const u8,

    pub fn decode(body: []const u8) DecodeError!PasswordBody {
        return .{ .body = body };
    }

    /// `PasswordMessage`: a null-terminated password.
    pub fn cleartext(self: *const PasswordBody) DecodeError![]const u8 {
        var reader: wire.Reader = .init(self.body);
        return wire.takeString(&reader);
    }

    pub fn saslInitial(self: *const PasswordBody) DecodeError!SaslInitial {
        return SaslInitial.decode(self.body);
    }

    /// A `SASLResponse` or a `GSSResponse`, which are the bytes as sent.
    pub fn raw(self: *const PasswordBody) []const u8 {
        return self.body;
    }

    pub fn write(self: *const PasswordBody, e: *Encoder) Error!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const PasswordBody, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Password{{ {f} }}", .{print.blob(self.body)});
    }
};

/// `d`. A chunk of a copy-in stream.
pub const CopyData = struct {
    data: []const u8,

    pub fn decode(body: []const u8) DecodeError!CopyData {
        return .{ .data = body };
    }

    pub fn write(self: *const CopyData, e: *Encoder) Error!void {
        try e.bytes(self.data);
    }

    pub fn format(self: *const CopyData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyData{{ {f} }}", .{print.blob(self.data)});
    }
};

/// `c`. The end of a copy-in stream.
pub const CopyDone = struct {
    pub fn decode(body: []const u8) DecodeError!CopyDone {
        if (body.len != 0) return DecodeError.UnexpectedEof;
        return .{};
    }

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

    pub fn decode(body: []const u8) DecodeError!CopyFail {
        var reader: wire.Reader = .init(body);
        return .{ .reason = try wire.takeString(&reader) };
    }

    pub fn write(self: *const CopyFail, e: *Encoder) Error!void {
        try e.string(self.reason);
    }

    pub fn format(self: *const CopyFail, writer: *Io.Writer) Io.Writer.Error!void {
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

    pub fn encode(self: *const Message, e: *Encoder) Error![]const u8 {
        return switch (self.*) {
            inline else => |body, tag| blk: {
                try e.start(tag);
                try body.write(e);
                break :blk e.finish();
            },
        };
    }

    pub fn format(self: *const Message, writer: *Io.Writer) Io.Writer.Error!void {
        try switch (self.*) {
            inline else => |body| body.format(writer),
        };
    }
};

/// A decoded `Parse`. The type list is an iterator: a decoder cannot know how
/// many parameters fit a fixed buffer, and this layer does not allocate.
pub const ParseView = struct {
    body: []const u8,
    statement: []const u8,
    sql: []const u8,
    /// Positioned at the first type OID.
    at: wire.Reader,
    count: u16,

    pub fn decode(body: []const u8) DecodeError!ParseView {
        var reader: wire.Reader = .init(body);
        const statement = try wire.takeString(&reader);
        const sql = try wire.takeString(&reader);
        const count = try reader.read(u16);
        return .{ .body = body, .statement = statement, .sql = sql, .at = reader, .count = count };
    }

    pub fn types(self: *const ParseView) wire.U32s {
        return .{ .reader = self.at, .left = self.count };
    }

    pub fn write(self: *const ParseView, e: *Encoder) Error!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const ParseView, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Parse{{ .statement = {f}, .sql = {f}, .types = {d} }}", .{
            print.quoted(self.statement),
            print.quoted(self.sql),
            self.count,
        });
    }
};

/// A decoded `Bind`. Formats come in the same three shapes the encoder takes,
/// so a caller reads the count and then decides.
pub const BindView = struct {
    body: []const u8,
    portal: []const u8,
    statement: []const u8,
    /// Positioned at the first parameter format code.
    formats_at: wire.Reader,
    format_count: u16,
    /// Positioned at the first parameter value.
    values_at: wire.Reader,
    value_count: u16,
    /// Positioned at the first result format code.
    results_at: wire.Reader,
    result_count: u16,

    pub fn decode(body: []const u8) DecodeError!BindView {
        var reader: wire.Reader = .init(body);
        const portal = try wire.takeString(&reader);
        const statement = try wire.takeString(&reader);

        const format_count = try reader.read(u16);
        const formats_at = reader;
        try reader.skip(@as(usize, format_count) * 2);

        const value_count = try reader.read(u16);
        const values_at = reader;

        // Walking the values is the only way to find where the result formats
        // start, since each value carries its own length.
        var left = value_count;
        while (left != 0) : (left -= 1) {
            const length = try reader.read(i32);
            if (length == -1) continue;
            if (length < 0) return DecodeError.UnexpectedEof;
            try reader.skip(@intCast(length));
        }

        const result_count = try reader.read(u16);
        return .{
            .body = body,
            .portal = portal,
            .statement = statement,
            .formats_at = formats_at,
            .format_count = format_count,
            .values_at = values_at,
            .value_count = value_count,
            .results_at = reader,
            .result_count = result_count,
        };
    }

    pub fn formats(self: *const BindView) wire.U16s {
        return .{ .reader = self.formats_at, .left = self.format_count };
    }

    pub fn values(self: *const BindView) wire.Values {
        return .{ .reader = self.values_at, .left = self.value_count };
    }

    pub fn resultFormats(self: *const BindView) wire.U16s {
        return .{ .reader = self.results_at, .left = self.result_count };
    }

    pub fn write(self: *const BindView, e: *Encoder) Error!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const BindView, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            "Bind{{ .portal = {f}, .statement = {f}, " ++
                ".formats = {d}, .parameters = {d}, .result_formats = {d} }}",
            .{
                print.quoted(self.portal),
                print.quoted(self.statement),
                self.format_count,
                self.value_count,
                self.result_count,
            },
        );
    }
};

/// A decoded `FunctionCall`, the same shape as a decoded `Bind`.
pub const FunctionCallView = struct {
    body: []const u8,
    function: u32,
    /// Positioned at the first argument format code.
    formats_at: wire.Reader,
    format_count: u16,
    /// Positioned at the first argument value.
    values_at: wire.Reader,
    value_count: u16,
    result_format: u16,

    pub fn decode(body: []const u8) DecodeError!FunctionCallView {
        var reader: wire.Reader = .init(body);

        const function = try reader.read(u32);
        const format_count = try reader.read(u16);
        const formats_at = reader;
        try reader.skip(@as(usize, format_count) * 2);

        const value_count = try reader.read(u16);
        const values_at = reader;

        var left = value_count;
        while (left != 0) : (left -= 1) {
            const length = try reader.read(i32);
            if (length == -1) continue;
            if (length < 0) return DecodeError.UnexpectedEof;
            try reader.skip(@intCast(length));
        }

        return .{
            .body = body,
            .function = function,
            .formats_at = formats_at,
            .format_count = format_count,
            .values_at = values_at,
            .value_count = value_count,
            .result_format = try reader.read(u16),
        };
    }

    pub fn formats(self: *const FunctionCallView) wire.U16s {
        return .{ .reader = self.formats_at, .left = self.format_count };
    }

    pub fn values(self: *const FunctionCallView) wire.Values {
        return .{ .reader = self.values_at, .left = self.value_count };
    }

    pub fn write(self: *const FunctionCallView, e: *Encoder) Error!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const FunctionCallView, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("FunctionCall{{ .function = {d}, .arguments = {d} }}", .{
            self.function,
            self.value_count,
        });
    }
};

/// A decoded frontend message: the shape a server or a proxy reads.
///
/// Three of these are views, because their lists have no fixed size. The rest
/// are the same values a client writes, since every field they carry is a
/// borrowed slice or a number.
pub const Decoded = union(messages.Frontend) {
    bind: BindView,
    close: Close,
    describe: Describe,
    execute: Execute,
    function_call: FunctionCallView,
    flush: Flush,
    parse: ParseView,
    query: Query,
    sync: Sync,
    terminate: Terminate,
    copy_data: CopyData,
    copy_done: CopyDone,
    copy_fail: CopyFail,
    password: PasswordBody,

    pub fn decode(tag: u8, body: []const u8) error{ UnexpectedEof, UnknownTag }!Decoded {
        const info = @typeInfo(Decoded).@"union";
        inline for (info.field_names, info.field_types) |name, Arm| {
            if (@backingInt(@field(messages.Frontend, name)) == tag) {
                return @unionInit(Decoded, name, try Arm.decode(body));
            }
        } else {
            @branchHint(.unlikely);
            return error.UnknownTag;
        }
    }

    pub fn encode(self: *const Decoded, e: *Encoder) Error![]const u8 {
        return switch (self.*) {
            inline else => |body, tag| blk: {
                try e.start(tag);
                try body.write(e);
                break :blk e.finish();
            },
        };
    }

    pub fn format(self: *const Decoded, writer: *Io.Writer) Io.Writer.Error!void {
        try switch (self.*) {
            inline else => |body| body.format(writer),
        };
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

test "the four messages under one tag" {
    // The tag does not say which of these it is; the conversation does.
    var buffer: [64]u8 = undefined;

    const sasl_initial: Message = .{
        .password = .{
            .sasl_initial = .{ .mechanism = "SCRAM-SHA-256", .response = "n,,n=,r=abc" },
        },
    };
    var e: Encoder = .init;
    e.reset(&buffer);
    const bytes = try sasl_initial.encode(&e);
    try testing.expectEqualSlices(
        u8,
        "p\x00\x00\x00\x21SCRAM-SHA-256\x00\x00\x00\x00\x0bn,,n=,r=abc",
        bytes,
    );

    const body = try PasswordBody.decode(bytes[5..]);
    const decoded = try body.saslInitial();
    try testing.expectEqualStrings("SCRAM-SHA-256", decoded.mechanism);
    try testing.expectEqualStrings("n,,n=,r=abc", decoded.response.?);

    // A SASL response is raw bytes with no terminator, so reading it as a
    // string would run off the end.
    const raw = try PasswordBody.decode("r=abc,s=xyz");
    try testing.expectError(error.UnexpectedEof, raw.saslInitial());
}

test "a password and a copy stream print as a size" {
    // A log line is forever, and so is a credential in one.
    try testing.expectFmt("Password{ .cleartext = <7 bytes> }", "{f}", .{
        Password{ .cleartext = "hunter2" },
    });
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
    if (T == Password) return .{ .cleartext = "p" };
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

test "a target this library does not name is carried, not refused" {
    // The byte comes off the wire, so a proxy sees whatever a client sent.
    const close = try Close.decode("X" ++ "s\x00");
    try testing.expectEqual(@as(u8, 'X'), @backingInt(close.target));
    try testing.expectFmt("Close{ .target = 88, .name = \"s\" }", "{f}", .{close});
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

test "every frontend message decodes back to its bytes" {
    // The writer and the reader are one codec: what one produces, the other
    // reads, and reading it again reproduces the same frame.
    const info = @typeInfo(Message).@"union";

    inline for (info.field_names, info.field_types) |name, T| {
        var written: [256]u8 = undefined;
        var to: Encoder = .init;
        to.reset(&written);
        const message: Message = @unionInit(Message, name, sample(T));
        const bytes = try message.encode(&to);

        const decoded = try Decoded.decode(bytes[0], bytes[5..]);

        var read: [256]u8 = undefined;
        var again: Encoder = .init;
        again.reset(&read);
        try testing.expectEqualSlices(u8, bytes, try decoded.encode(&again));
    }
}

test "a decoded bind yields its parameters" {
    var buffer: [128]u8 = undefined;
    var e: Encoder = .init;
    e.reset(&buffer);

    const message: Message = .{
        .bind = .{
            .portal = "p",
            .statement = "s",
            .formats = &.{.binary},
            .parameters = &.{ "one", null },
        },
    };
    const bytes = try message.encode(&e);

    const decoded = try Decoded.decode('B', bytes[5..]);
    try testing.expectEqualStrings("p", decoded.bind.portal);
    try testing.expectEqualStrings("s", decoded.bind.statement);

    var formats = decoded.bind.formats();
    try testing.expectEqual(@as(?u16, 1), try formats.next());
    try testing.expectEqual(@as(?u16, null), try formats.next());

    var values = decoded.bind.values();
    try testing.expectEqualStrings("one", (try values.next()).?.bytes.?);
    try testing.expectEqual(@as(?[]const u8, null), (try values.next()).?.bytes);
    try testing.expectEqual(@as(?wire.Values.Value, null), try values.next());

    var results = decoded.bind.resultFormats();
    try testing.expectEqual(@as(?u16, null), try results.next());
}
