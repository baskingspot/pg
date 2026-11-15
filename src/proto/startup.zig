//! The four messages that come before the protocol has tags.
//!
//! Each is an int32 length that counts itself, then a body whose first four
//! bytes say which message this is: a protocol version for `StartupMessage`, or
//! one of three request codes. There is no tag byte and the length comes first,
//! which is why these cannot go through `frame.Decoder`.
//!
//! https://www.postgresql.org/docs/current/protocol-message-formats.html

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const print = @import("print.zig");
const version = @import("version.zig");
const wire = @import("wire.zig");
const write = @import("write.zig");

const Encoder = write.Encoder;
const Error = write.Error;
const DecodeError = wire.Error;

/// The version whose number doubles as the SSL request code: `1234` in the high
/// 16 bits, `5679` in the low.
pub const ssl_code: u32 = 80877103;

/// `1234` and `5678`.
pub const cancel_code: u32 = 80877102;

/// `1234` and `5680`.
pub const gssenc_code: u32 = 80877104;

/// The longest startup packet PostgreSQL accepts. Its backend refuses one
/// longer (`MAX_STARTUP_PACKET_LENGTH`), which is also what makes a peek at the
/// first bytes possible: a tagged message's tag in that position reads as a
/// length far past this.
pub const max_len: u32 = 10000;

/// What the first bytes of a connection say it is.
///
/// A client's first message has no tag: four bytes of length, then a version or
/// a request code. A tagged message has its tag where the length would be, and
/// those four bytes read as a length past `max_len`, so an unrecognized prefix
/// is null rather than a guess.
pub const Kind = enum {
    startup,
    ssl_request,
    gssenc_request,
    cancel_request,
};

/// The kind of message a connection is opening with, from at least eight bytes
/// of it.
pub fn peek(prefix: []const u8) ?Kind {
    const length_field = length(prefix) catch return null;
    if (prefix.len < 8) return null;
    if (length_field < 8 or length_field > max_len) return null;

    var reader: wire.Reader = .init(prefix[4..8]);
    const code = reader.read(u32) catch return null;
    return switch (code) {
        ssl_code => .ssl_request,
        gssenc_code => .gssenc_request,
        cancel_code => .cancel_request,
        else => .startup,
    };
}

/// The length of a startup-phase message, from its first four bytes.
///
/// The whole message on the wire is exactly this many bytes, from the length
/// field onward.
pub fn length(prefix: []const u8) DecodeError!u32 {
    if (prefix.len < 4) return DecodeError.UnexpectedEof;
    var reader: wire.Reader = .init(prefix);
    return reader.read(u32);
}

/// A `StartupMessage`: a version, then the parameters.
///
/// A message built by a client writes `parameters`. A message read off the
/// wire keeps the bytes it read in `body` and re-emits them, because a decoder
/// cannot build the slice without allocating and the bytes are already the
/// correct encoding.
pub const Startup = struct {
    version: version.Version = .v3_0,
    /// In any order. `user` is required by the server; everything else is a
    /// run-time parameter, and names starting with `_pq_.` are reserved for
    /// protocol extensions.
    parameters: []const Parameter = &.{},
    /// The parameter bytes as they arrived, when this came from `decode`.
    body: []const u8 = "",

    pub const Parameter = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn decode(body: []const u8) DecodeError!Startup {
        var reader: wire.Reader = .init(body);
        const code = try reader.read(u32);
        return .{
            .version = version.Version.fromU32(code),
            .body = reader.remaining(),
        };
    }

    /// The parameters, in the order the client sent them.
    pub fn sent(self: *const Startup) Parameters {
        const reader: wire.Reader = .init(self.body);
        return .{ .reader = reader };
    }

    pub fn write(self: *const Startup, e: *Encoder) Error!void {
        try e.bytes(&self.version.wire);

        if (self.body.len != 0) {
            try e.bytes(self.body);
            return;
        }

        for (self.parameters) |parameter| {
            try e.string(parameter.name);
            try e.string(parameter.value);
        }
        // A zero byte where a name would start is the end of the list.
        try e.int(u8, 0);
    }

    pub fn format(self: *const Startup, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Startup{{ .version = {f} }}", .{self.version});
    }
};

/// The parameters of a startup message, in the order sent.
pub const Parameters = struct {
    reader: wire.Reader,

    pub fn next(self: *Parameters) DecodeError!?Startup.Parameter {
        const rest = self.reader.remaining();
        if (rest.len == 0) return null;
        // A zero byte where a name would start is the end of the list.
        if (rest[0] == 0) {
            _ = try self.reader.skip(1);
            return null;
        }

        const name = try wire.takeString(&self.reader);
        const value = try wire.takeString(&self.reader);
        return .{ .name = name, .value = value };
    }
};

/// A `CancelRequest`: the key a `BackendKeyData` handed out earlier.
pub const CancelRequest = struct {
    process: u32,
    /// Four bytes at protocol 3.0, up to 256 from 3.2.
    key: []const u8,

    pub fn decode(body: []const u8) DecodeError!CancelRequest {
        var reader: wire.Reader = .init(body);
        return .{
            .process = try reader.read(u32),
            .key = reader.remaining(),
        };
    }

    pub fn write(self: *const CancelRequest, e: *Encoder) Error!void {
        try e.int(u32, self.process);
        try e.bytes(self.key);
    }

    pub fn format(self: *const CancelRequest, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CancelRequest{{ .process = {d}, .key = {f} }}", .{
            self.process,
            print.blob(self.key),
        });
    }
};

/// A message from before the tagged phase, or a request that ends the
/// connection.
pub const Message = union(enum) {
    startup: Startup,
    ssl_request,
    gssenc_request,
    cancel_request: CancelRequest,

    /// Decode one body: everything after the four-byte length.
    pub fn decode(body: []const u8) DecodeError!Message {
        var reader: wire.Reader = .init(body);
        const code = try reader.read(u32);

        return switch (code) {
            ssl_code => .ssl_request,
            gssenc_code => .gssenc_request,
            cancel_code => .{ .cancel_request = try CancelRequest.decode(reader.remaining()) },
            else => .{ .startup = try Startup.decode(body) },
        };
    }

    pub fn encode(self: *const Message, e: *Encoder) Error![]const u8 {
        switch (self.*) {
            .startup => |startup| {
                try e.startUntagged();
                try startup.write(e);
            },
            .ssl_request => {
                try e.startUntagged();
                try e.int(u32, ssl_code);
            },
            .gssenc_request => {
                try e.startUntagged();
                try e.int(u32, gssenc_code);
            },
            .cancel_request => |cancel| {
                try e.startUntagged();
                try e.int(u32, cancel_code);
                try cancel.write(e);
            },
        }
        return e.finish();
    }

    pub fn format(self: *const Message, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.*) {
            .startup => |startup| try startup.format(writer),
            .ssl_request => try writer.writeAll("SSLRequest"),
            .gssenc_request => try writer.writeAll("GSSENCRequest"),
            .cancel_request => |cancel| try cancel.format(writer),
        }
    }
};

test "a peek says which message is opening the connection" {
    try testing.expectEqual(Kind.ssl_request, peek("\x00\x00\x00\x08\x04\xd2\x16\x2f").?);
    try testing.expectEqual(Kind.gssenc_request, peek("\x00\x00\x00\x08\x04\xd2\x16\x30").?);
    try testing.expectEqual(Kind.cancel_request, peek("\x00\x00\x00\x10\x04\xd2\x16\x2e").?);
    try testing.expectEqual(Kind.startup, peek("\x00\x00\x00\x08\x00\x03\x00\x00").?);

    // A tagged message puts its tag where the length goes, and four bytes of
    // 'Q' and zeroes read as a length far past what a startup packet may be.
    try testing.expectEqual(@as(?Kind, null), peek("Q\x00\x00\x00\x0dselect 1\x00"));
    try testing.expectEqual(@as(?Kind, null), peek("\x00\x00\x00\x04\x00\x00\x00\x00"));
    try testing.expectEqual(@as(?Kind, null), peek("\x00\x00\x00\x08"));
}

test "a request is a length and a code, and nothing else" {
    var buffer: [32]u8 = undefined;

    const ssl_message: Message = .{ .ssl_request = {} };
    var ssl: Encoder = .init;
    ssl.reset(&buffer);
    const ssl_request = try ssl_message.encode(&ssl);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x08\x04\xd2\x16\x2f", ssl_request);

    const gssenc_message: Message = .{ .gssenc_request = {} };
    var gssenc: Encoder = .init;
    gssenc.reset(&buffer);
    const gssenc_request = try gssenc_message.encode(&gssenc);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x08\x04\xd2\x16\x30", gssenc_request);

    try testing.expectEqual(@as(u32, 8), try length(ssl_request));
}

test "a startup message carries the version and the parameters" {
    var buffer: [128]u8 = undefined;
    var e: Encoder = .init;
    e.reset(&buffer);

    const message: Message = .{
        .startup = .{
            .parameters = &.{
                .{ .name = "user", .value = "matt" },
                .{ .name = "database", .value = "app" },
            },
        },
    };
    const bytes = try message.encode(&e);

    // The length, the version, two null-terminated pairs, and the terminator:
    // 4 + 4 + 5 + 5 + 9 + 4 + 1.
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), try length(bytes));
    try testing.expectEqual(@as(usize, 32), bytes.len);
    try testing.expectEqualSlices(u8, "\x00\x03\x00\x00", bytes[4..8]);
    try testing.expectEqualStrings(
        "user\x00matt\x00database\x00app\x00\x00",
        bytes[8..32],
    );
}

test "a startup body decodes to its version" {
    const body = "\x00\x03\x00\x00" ++ "user\x00matt\x00" ++ "\x00";
    const message = try Message.decode(body);

    try testing.expectEqual(version.Version.v3_0, message.startup.version);

    var sent = message.startup.sent();
    const user = (try sent.next()).?;
    try testing.expectEqualStrings("user", user.name);
    try testing.expectEqualStrings("matt", user.value);
    try testing.expectEqual(@as(?Startup.Parameter, null), try sent.next());
}

test "a cancel request carries the key to cancel with" {
    var buffer: [32]u8 = undefined;
    var e: Encoder = .init;
    e.reset(&buffer);

    const message: Message = .{
        .cancel_request = .{ .process = 8864, .key = "\xd9\x0c\xae\xdb" },
    };
    const bytes = try message.encode(&e);
    try testing.expectEqualSlices(
        u8,
        "\x00\x00\x00\x10\x04\xd2\x16\x2e\x00\x00\x22\xa0\xd9\x0c\xae\xdb",
        bytes,
    );

    const decoded = try Message.decode(bytes[4..]);
    try testing.expectEqual(@as(u32, 8864), decoded.cancel_request.process);
    try testing.expectEqualSlices(u8, "\xd9\x0c\xae\xdb", decoded.cancel_request.key);
}
