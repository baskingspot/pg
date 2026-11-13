//! The messages that ride inside a copy-both stream.
//!
//! A client asks for replication with the `replication` startup parameter. The
//! server answers `CopyBothResponse` and from then on both directions carry
//! `CopyData`, whose payload starts with one of these tags instead of a message
//! tag. There is no length field of their own: the `CopyData` length is the
//! only boundary, so a message here runs to the end of the payload it was
//! handed.
//!
//! The WAL inside `XLogData` has its own format, negotiated by
//! `proto_version`. Logical decoding output (the `pgoutput` stream) is a
//! decoder above this one, not another arm here.
//!
//! https://www.postgresql.org/docs/current/protocol-replication.html

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const print = @import("print.zig");
const wire = @import("wire.zig");
const write = @import("write.zig");

const Encoder = write.Encoder;
const Error = write.Error;
const DecodeError = wire.Error;

/// The first byte of a copy-both payload.
pub const Kind = enum(u8) {
    /// WAL from the server.
    xlog_data = 'w',
    /// The server asking whether the standby is alive.
    keepalive = 'k',
    /// The standby saying how far it has got.
    standby_status = 'r',
    /// The standby holding back the server's vacuum.
    hot_standby_feedback = 'h',
    _,

    pub inline fn fromByte(byte: u8) Kind {
        return @fromBackingInt(byte);
    }
};

/// `w`. A section of the WAL stream.
pub const XLogData = struct {
    /// Where this section starts in the WAL.
    start: i64,
    /// The end of the WAL on the server when this was sent.
    end: i64,
    /// The server's clock, in microseconds since 2000-01-01.
    clock: i64,
    /// The WAL itself, borrowed from the copy payload.
    data: []const u8,

    pub fn decode(payload: []const u8) DecodeError!XLogData {
        var reader: wire.Reader = .init(payload);
        return .{
            .start = try reader.read(i64),
            .end = try reader.read(i64),
            .clock = try reader.read(i64),
            .data = reader.remaining(),
        };
    }

    pub fn write(self: *const XLogData, e: *Encoder) Error!void {
        try e.int(i64, self.start);
        try e.int(i64, self.end);
        try e.int(i64, self.clock);
        try e.bytes(self.data);
    }

    pub fn format(self: *const XLogData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("XLogData{{ .start = {d}, .end = {d}, {f} }}", .{
            self.start,
            self.end,
            print.blob(self.data),
        });
    }
};

/// `k`. The server asking whether the standby is still there.
pub const Keepalive = struct {
    /// The end of the WAL on the server.
    end: i64,
    /// The server's clock, in microseconds since 2000-01-01.
    clock: i64,
    /// The server wants an answer before its timeout.
    reply: bool,

    pub fn decode(payload: []const u8) DecodeError!Keepalive {
        var reader: wire.Reader = .init(payload);
        return .{
            .end = try reader.read(i64),
            .clock = try reader.read(i64),
            .reply = (try reader.read(u8)) != 0,
        };
    }

    pub fn write(self: *const Keepalive, e: *Encoder) Error!void {
        try e.int(i64, self.end);
        try e.int(i64, self.clock);
        try e.int(u8, @intFromBool(self.reply));
    }

    pub fn format(self: *const Keepalive, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("Keepalive{{ .end = {d}, .reply = {} }}", .{ self.end, self.reply });
    }
};

/// `r`. How far the standby has written, flushed, and applied.
pub const StandbyStatus = struct {
    /// The last WAL byte received, plus one.
    written: i64,
    /// The last WAL byte flushed to disk, plus one.
    flushed: i64,
    /// The last WAL byte applied, plus one.
    applied: i64,
    /// The standby's clock, in microseconds since 2000-01-01.
    clock: i64,
    /// Ask the server to answer at once, which is how a standby pings.
    reply: bool,

    pub fn decode(payload: []const u8) DecodeError!StandbyStatus {
        var reader: wire.Reader = .init(payload);
        return .{
            .written = try reader.read(i64),
            .flushed = try reader.read(i64),
            .applied = try reader.read(i64),
            .clock = try reader.read(i64),
            .reply = (try reader.read(u8)) != 0,
        };
    }

    pub fn write(self: *const StandbyStatus, e: *Encoder) Error!void {
        try e.int(i64, self.written);
        try e.int(i64, self.flushed);
        try e.int(i64, self.applied);
        try e.int(i64, self.clock);
        try e.int(u8, @intFromBool(self.reply));
    }

    pub fn format(self: *const StandbyStatus, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("StandbyStatus{{ .written = {d}, .flushed = {d}, .applied = {d} }}", .{
            self.written,
            self.flushed,
            self.applied,
        });
    }
};

/// `h`. The standby's oldest transaction, so the server does not vacuum what a
/// running query still needs.
pub const HotStandbyFeedback = struct {
    /// The standby's clock, in microseconds since 2000-01-01.
    clock: i64,
    /// The standby's oldest transaction.
    xmin: u32,
    xmin_epoch: u32,
    /// The oldest of any replication slot on the standby, or zero.
    catalog_xmin: u32,
    catalog_xmin_epoch: u32,

    pub fn decode(payload: []const u8) DecodeError!HotStandbyFeedback {
        var reader: wire.Reader = .init(payload);
        return .{
            .clock = try reader.read(i64),
            .xmin = try reader.read(u32),
            .xmin_epoch = try reader.read(u32),
            .catalog_xmin = try reader.read(u32),
            .catalog_xmin_epoch = try reader.read(u32),
        };
    }

    pub fn write(self: *const HotStandbyFeedback, e: *Encoder) Error!void {
        try e.int(i64, self.clock);
        try e.int(u32, self.xmin);
        try e.int(u32, self.xmin_epoch);
        try e.int(u32, self.catalog_xmin);
        try e.int(u32, self.catalog_xmin_epoch);
    }

    pub fn format(self: *const HotStandbyFeedback, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("HotStandbyFeedback{{ .xmin = {d}, .catalog_xmin = {d} }}", .{
            self.xmin,
            self.catalog_xmin,
        });
    }
};

/// One message of the copy-both stream.
pub const Message = union(Kind) {
    xlog_data: XLogData,
    keepalive: Keepalive,
    standby_status: StandbyStatus,
    hot_standby_feedback: HotStandbyFeedback,

    /// Decode one `CopyData` payload.
    ///
    /// A tag this library does not name is `error.UnknownTag`, so a caller can
    /// skip a message from a newer server instead of failing the stream.
    pub fn decode(payload: []const u8) error{ UnexpectedEof, UnknownTag }!Message {
        if (payload.len == 0) return error.UnexpectedEof;

        const body = payload[1..];
        return switch (Kind.fromByte(payload[0])) {
            .xlog_data => .{ .xlog_data = try XLogData.decode(body) },
            .keepalive => .{ .keepalive = try Keepalive.decode(body) },
            .standby_status => .{ .standby_status = try StandbyStatus.decode(body) },
            .hot_standby_feedback => .{
                .hot_standby_feedback = try HotStandbyFeedback.decode(body),
            },
            else => error.UnknownTag,
        };
    }

    /// Write one payload, without a `CopyData` around it.
    pub fn encode(self: *const Message, e: *Encoder) Error![]const u8 {
        const at = e.mark();
        switch (self.*) {
            inline else => |body, tag| {
                try e.int(u8, @backingInt(tag));
                try body.write(e);
            },
        }
        return e.since(at);
    }

    pub fn format(self: *const Message, writer: *Io.Writer) Io.Writer.Error!void {
        try switch (self.*) {
            inline else => |body| body.format(writer),
        };
    }
};

test "a keepalive is two positions, a clock, and a request" {
    var buffer: [32]u8 = undefined;
    var e: Encoder = .init;
    e.reset(&buffer);

    const message: Message = .{ .keepalive = .{ .end = 1, .clock = 2, .reply = true } };
    const payload = try message.encode(&e);

    try testing.expectEqual(@as(usize, 18), payload.len);
    try testing.expectEqual(@as(u8, 'k'), payload[0]);
    try testing.expectEqual(@as(u8, 1), payload[17]);

    const decoded = try Message.decode(payload);
    try testing.expectEqual(@as(i64, 1), decoded.keepalive.end);
    try testing.expectEqual(@as(i64, 2), decoded.keepalive.clock);
    try testing.expect(decoded.keepalive.reply);
}

test "every replication message decodes back to its bytes" {
    const samples = [_]Message{
        .{ .xlog_data = .{ .start = 1, .end = 2, .clock = 3, .data = "wal" } },
        .{ .keepalive = .{ .end = 1, .clock = 2, .reply = false } },
        .{ .standby_status = .{
            .written = 1,
            .flushed = 2,
            .applied = 3,
            .clock = 4,
            .reply = true,
        } },
        .{ .hot_standby_feedback = .{
            .clock = 1,
            .xmin = 2,
            .xmin_epoch = 3,
            .catalog_xmin = 4,
            .catalog_xmin_epoch = 5,
        } },
    };

    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;

    for (samples) |sample| {
        var to: Encoder = .init;
        to.reset(&first);
        const payload = try sample.encode(&to);

        const decoded = try Message.decode(payload);

        var again: Encoder = .init;
        again.reset(&second);
        try testing.expectEqualSlices(u8, payload, try decoded.encode(&again));
    }
}

test "an unknown tag ends the stream cleanly" {
    try testing.expectError(error.UnknownTag, Message.decode("z"));
    try testing.expectError(error.UnexpectedEof, Message.decode(""));
}
