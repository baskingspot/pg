//! Backend messages: the ones a server sends.
//!
//! Decoding borrows the body. A message with a list in it, which is `DataRow`,
//! `RowDescription`, and the copy responses among others, keeps the body and
//! hands out an iterator, because a client cannot know how many columns fit a
//! fixed buffer and this layer does not allocate.
//!
//! Encoding is not here yet. A proxy forwards the bytes it already has, and a
//! server constructing one of these wants a shape made of slices rather than a
//! borrowed body, so that is its own pass.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const error_response = @import("error_response.zig");
const write = @import("write.zig");
const Encoder = write.Encoder;
const messages = @import("messages.zig");
const print = @import("print.zig");
const wire = @import("wire.zig");
pub const Error = wire.Error;

/// The encoder's error, which is the buffer running out.
const WriteError = write.Error;

/// One decoded backend message.
pub const Message = union(messages.Backend) {
    authentication: Authentication,
    backend_key_data: BackendKeyData,
    bind_complete: BindComplete,
    close_complete: CloseComplete,
    command_complete: CommandComplete,
    copy_both_response: CopyBoth,
    copy_data: CopyData,
    copy_done: CopyDone,
    copy_in_response: CopyIn,
    copy_out_response: CopyOut,
    data_row: DataRow,
    empty_query_response: EmptyQueryResponse,
    error_response: ErrorResponse,
    function_call_response: FunctionCallResponse,
    negotiate_protocol_version: NegotiateProtocolVersion,
    no_data: NoData,
    notice_response: NoticeResponse,
    notification_response: NotificationResponse,
    parameter_description: ParameterDescription,
    parameter_status: ParameterStatus,
    parse_complete: ParseComplete,
    portal_suspended: PortalSuspended,
    ready_for_query: ReadyForQuery,
    row_description: RowDescription,

    /// Decode one body, given the tag byte from its frame.
    ///
    /// Derived from the union: an arm's name is a field of
    /// `messages.Backend`, so the mapping from tag to decoder is the union
    /// itself and adding an arm adds its decoder.
    ///
    /// A tag this library does not name is `error.UnknownTag` rather than a
    /// panic, so a caller can forward it or fail on its own terms.
    pub fn decode(tag: u8, body: []const u8) error{ UnexpectedEof, UnknownTag }!Message {
        const info = @typeInfo(Message).@"union";
        inline for (info.field_names, info.field_types) |name, Arm| {
            if (@backingInt(@field(messages.Backend, name)) == tag) {
                return @unionInit(Message, name, try Arm.decode(body));
            }
        } else {
            @branchHint(.unlikely);
            return error.UnknownTag;
        }
    }

    pub fn encode(self: *const Message, e: *Encoder) WriteError![]const u8 {
        return switch (self.*) {
            inline else => |body, tag| blk: {
                try e.startBackend(tag);
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

/// `R`. Which login method the server wants next.
pub const Authentication = union(enum) {
    ok,
    kerberos_v5,
    cleartext_password,
    /// The four bytes to salt the MD5 digest.
    md5_password: [4]u8,
    gss,
    gss_continue: []const u8,
    sspi,
    sasl: Sasl,
    sasl_continue: []const u8,
    sasl_final: []const u8,
    /// A code this library does not name. The server will not continue a
    /// login the client cannot answer.
    unknown: u32,

    pub fn decode(body: []const u8) Error!Authentication {
        var reader: wire.Reader = .init(body);
        const code = try reader.read(u32);
        return switch (messages.Auth.fromCode(code)) {
            .ok => .ok,
            .kerberos_v5 => .kerberos_v5,
            .cleartext_password => .cleartext_password,
            .md5_password => .{ .md5_password = (try reader.readSlice(4))[0..4].* },
            .gss => .gss,
            .gss_continue => .{ .gss_continue = reader.remaining() },
            .sspi => .sspi,
            .sasl => .{ .sasl = .{ .mechanisms = reader.remaining() } },
            .sasl_continue => .{ .sasl_continue = reader.remaining() },
            .sasl_final => .{ .sasl_final = reader.remaining() },
            else => blk: {
                @branchHint(.unlikely);
                break :blk .{ .unknown = code };
            },
        };
    }

    pub fn write(self: *const Authentication, e: *Encoder) WriteError!void {
        switch (self.*) {
            .ok => try e.int(u32, @backingInt(messages.Auth.ok)),
            .kerberos_v5 => try e.int(u32, @backingInt(messages.Auth.kerberos_v5)),
            .cleartext_password => try e.int(u32, @backingInt(messages.Auth.cleartext_password)),
            .md5_password => |salt| {
                try e.int(u32, @backingInt(messages.Auth.md5_password));
                try e.bytes(&salt);
            },
            .gss => try e.int(u32, @backingInt(messages.Auth.gss)),
            .gss_continue => |data| {
                try e.int(u32, @backingInt(messages.Auth.gss_continue));
                try e.bytes(data);
            },
            .sspi => try e.int(u32, @backingInt(messages.Auth.sspi)),
            .sasl => |sasl| {
                try e.int(u32, @backingInt(messages.Auth.sasl));
                try e.bytes(sasl.mechanisms);
            },
            .sasl_continue => |data| {
                try e.int(u32, @backingInt(messages.Auth.sasl_continue));
                try e.bytes(data);
            },
            .sasl_final => |data| {
                try e.int(u32, @backingInt(messages.Auth.sasl_final));
                try e.bytes(data);
            },
            .unknown => |code| try e.int(u32, code),
        }
    }

    pub fn format(self: *const Authentication, writer: *Io.Writer) Io.Writer.Error!void {
        try switch (self.*) {
            .ok => writer.writeAll("Authentication{ .ok }"),
            .kerberos_v5 => writer.writeAll("Authentication{ .kerberos_v5 }"),
            .cleartext_password => writer.writeAll("Authentication{ .cleartext_password }"),
            .md5_password => |salt| writer.print("Authentication{{ .md5_password = {f} }}", .{
                print.quoted(&salt),
            }),
            .gss => writer.writeAll("Authentication{ .gss }"),
            .gss_continue => |data| writer.print("Authentication{{ .gss_continue = {f} }}", .{
                print.blob(data),
            }),
            .sspi => writer.writeAll("Authentication{ .sspi }"),
            .sasl => |sasl| writer.print("Authentication{{ .sasl = {f} }}", .{sasl}),
            .sasl_continue => |data| writer.print("Authentication{{ .sasl_continue = {f} }}", .{
                print.blob(data),
            }),
            .sasl_final => |data| writer.print("Authentication{{ .sasl_final = {f} }}", .{
                print.blob(data),
            }),
            .unknown => |code| writer.print("Authentication{{ .unknown = {d} }}", .{code}),
        };
    }
};

/// The mechanism names an `AuthenticationSASL` offers, in the server's order of
/// preference, each null-terminated with a final null.
pub const Sasl = struct {
    mechanisms: []const u8,

    pub fn iterator(self: *const Sasl) SaslIterator {
        return .{ .reader = .init(self.mechanisms) };
    }

    pub fn format(self: *const Sasl, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("Sasl{ ");
        var it = self.iterator();
        var first = true;
        while (it.next() catch null) |name| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.print("{f}", .{print.quoted(name)});
        }
        try writer.writeAll(" }");
    }
};

pub const SaslIterator = struct {
    reader: wire.Reader,

    pub fn next(self: *SaslIterator) Error!?[]const u8 {
        if (self.reader.remaining().len == 0) return null;
        const name = try wire.takeString(&self.reader);
        // A zero byte where a name would start is the end of the list.
        if (name.len == 0) return null;
        return name;
    }
};

/// `K`. The cancel key, to send in `CancelRequest` on another connection.
pub const BackendKeyData = struct {
    process: u32,
    /// Four bytes at protocol 3.0, up to 256 from 3.2.
    key: []const u8,

    pub fn decode(body: []const u8) Error!BackendKeyData {
        var reader: wire.Reader = .init(body);
        return .{
            .process = try reader.read(u32),
            .key = reader.remaining(),
        };
    }

    pub fn write(self: *const BackendKeyData, e: *Encoder) WriteError!void {
        try e.int(u32, self.process);
        try e.bytes(self.key);
    }

    pub fn format(self: *const BackendKeyData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("BackendKeyData{{ .process = {d}, .key = {f} }}", .{
            self.process,
            print.blob(self.key),
        });
    }
};

/// `1`. The statement parsed.
pub const ParseComplete = struct {
    pub fn decode(body: []const u8) Error!ParseComplete {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const ParseComplete, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: ParseComplete, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("ParseComplete");
    }
};

/// `2`. The portal is bound.
pub const BindComplete = struct {
    pub fn decode(body: []const u8) Error!BindComplete {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const BindComplete, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: BindComplete, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("BindComplete");
    }
};

/// `3`. The statement or portal is gone.
pub const CloseComplete = struct {
    pub fn decode(body: []const u8) Error!CloseComplete {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const CloseComplete, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: CloseComplete, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("CloseComplete");
    }
};

/// `n`. A statement or portal has no row description.
pub const NoData = struct {
    pub fn decode(body: []const u8) Error!NoData {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const NoData, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: NoData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("NoData");
    }
};

/// `I`. The query was empty, so there is no CommandComplete.
pub const EmptyQueryResponse = struct {
    pub fn decode(body: []const u8) Error!EmptyQueryResponse {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const EmptyQueryResponse, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: EmptyQueryResponse, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("EmptyQueryResponse");
    }
};

/// `s`. The portal hit its row limit and can be executed again.
pub const PortalSuspended = struct {
    pub fn decode(body: []const u8) Error!PortalSuspended {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const PortalSuspended, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: PortalSuspended, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("PortalSuspended");
    }
};

/// `c`. The end of a copy stream.
pub const CopyDone = struct {
    pub fn decode(body: []const u8) Error!CopyDone {
        if (body.len != 0) return error.UnexpectedEof;
        return .{};
    }

    pub fn write(_: *const CopyDone, e: *Encoder) WriteError!void {
        _ = e;
    }

    pub fn format(_: CopyDone, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("CopyDone");
    }
};

/// `C`. The command tag, such as `INSERT 0 3` or `SELECT 2`.
pub const CommandComplete = struct {
    tag: []const u8,

    pub fn decode(body: []const u8) Error!CommandComplete {
        var reader: wire.Reader = .init(body);
        return .{ .tag = try wire.takeString(&reader) };
    }

    pub fn write(self: *const CommandComplete, e: *Encoder) WriteError!void {
        try e.string(self.tag);
    }

    pub fn format(self: *const CommandComplete, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CommandComplete{{ .tag = {f} }}", .{print.quoted(self.tag)});
    }
};

/// `Z`. The server is ready for another cycle, and the transaction state.
pub const ReadyForQuery = struct {
    status: messages.Transaction,

    pub fn decode(body: []const u8) Error!ReadyForQuery {
        var reader: wire.Reader = .init(body);
        return .{ .status = messages.Transaction.fromByte(try reader.read(u8)) };
    }

    pub fn write(self: *const ReadyForQuery, e: *Encoder) WriteError!void {
        try e.int(u8, @backingInt(self.status));
    }

    pub fn format(self: ReadyForQuery, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("ReadyForQuery{{ .status = .{t} }}", .{self.status});
    }
};

/// `S`. A run-time parameter, sent at connect and again whenever it changes.
pub const ParameterStatus = struct {
    name: []const u8,
    value: []const u8,

    pub fn decode(body: []const u8) Error!ParameterStatus {
        var reader: wire.Reader = .init(body);
        return .{
            .name = try wire.takeString(&reader),
            .value = try wire.takeString(&reader),
        };
    }

    pub fn write(self: *const ParameterStatus, e: *Encoder) WriteError!void {
        try e.string(self.name);
        try e.string(self.value);
    }

    pub fn format(self: *const ParameterStatus, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("ParameterStatus{{ .name = {f}, .value = {f} }}", .{
            print.quoted(self.name),
            print.quoted(self.value),
        });
    }
};

/// `A`. A `LISTEN`/`NOTIFY` delivery, arriving between messages.
pub const NotificationResponse = struct {
    process: u32,
    channel: []const u8,
    payload: []const u8,

    pub fn decode(body: []const u8) Error!NotificationResponse {
        var reader: wire.Reader = .init(body);
        return .{
            .process = try reader.read(u32),
            .channel = try wire.takeString(&reader),
            .payload = try wire.takeString(&reader),
        };
    }

    pub fn write(self: *const NotificationResponse, e: *Encoder) WriteError!void {
        try e.int(u32, self.process);
        try e.string(self.channel);
        try e.string(self.payload);
    }

    pub fn format(self: *const NotificationResponse, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("NotificationResponse{{ .channel = {f}, .payload = {f} }}", .{
            print.quoted(self.channel),
            print.quoted(self.payload),
        });
    }
};

/// `D`. One row. The values are borrowed from the frame that carried them.
pub const DataRow = struct {
    body: []const u8,
    columns: u16,

    pub fn decode(body: []const u8) Error!DataRow {
        var reader: wire.Reader = .init(body);
        return .{ .body = body, .columns = try reader.read(u16) };
    }

    /// The values, in column order. A null is a SQL NULL.
    pub fn values(self: *const DataRow) Values {
        return .{ .reader = .init(self.body[2..]), .left = self.columns };
    }

    pub const Value = struct {
        /// Null for a SQL NULL, which the wire sends as a length of -1.
        bytes: ?[]const u8,
    };

    pub const Values = struct {
        reader: wire.Reader,
        left: u16,

        pub fn next(self: *Values) Error!?Value {
            if (self.left == 0) return null;
            self.left -= 1;

            const length = try self.reader.read(i32);
            // -1 is a null, and the wire has no other negative length. Saying
            // so here is what keeps a cast from turning -2 into a huge slice.
            if (length == -1) return .{ .bytes = null };
            if (length < 0) return error.UnexpectedEof;

            return .{ .bytes = try self.reader.readSlice(@intCast(length)) };
        }
    };

    pub fn write(self: *const DataRow, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const DataRow, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("DataRow{{ .columns = {d} }}", .{self.columns});
    }
};

/// `T`. The columns a result will return, before the rows.
pub const RowDescription = struct {
    body: []const u8,
    fields: u16,

    pub fn decode(body: []const u8) Error!RowDescription {
        var reader: wire.Reader = .init(body);
        return .{ .body = body, .fields = try reader.read(u16) };
    }

    pub fn columns(self: *const RowDescription) Columns {
        return .{ .reader = .init(self.body[2..]), .left = self.fields };
    }

    pub const Field = struct {
        name: []const u8,
        /// Zero when the column does not come from a table.
        table: u32,
        column: i16,
        /// The data type. Its meaning is the server's catalog, not ours.
        type: u32,
        /// Negative for a variable-width type.
        type_size: i16,
        type_modifier: i32,
        format: u16,
    };

    pub const Columns = struct {
        reader: wire.Reader,
        left: u16,

        pub fn next(self: *Columns) Error!?Field {
            if (self.left == 0) return null;
            self.left -= 1;

            return .{
                .name = try wire.takeString(&self.reader),
                .table = try self.reader.read(u32),
                .column = try self.reader.read(i16),
                .type = try self.reader.read(u32),
                .type_size = try self.reader.read(i16),
                .type_modifier = try self.reader.read(i32),
                .format = try self.reader.read(u16),
            };
        }
    };

    pub fn write(self: *const RowDescription, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const RowDescription, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("RowDescription{{ .fields = {d} }}", .{self.fields});
    }
};

/// `t`. The parameter types a prepared statement resolved to.
pub const ParameterDescription = struct {
    body: []const u8,
    count: u16,

    pub fn decode(body: []const u8) Error!ParameterDescription {
        var reader: wire.Reader = .init(body);
        return .{ .body = body, .count = try reader.read(u16) };
    }

    pub fn types(self: *const ParameterDescription) Types {
        return .{ .reader = .init(self.body[2..]), .left = self.count };
    }

    pub const Types = struct {
        reader: wire.Reader,
        left: u16,

        pub fn next(self: *Types) Error!?u32 {
            if (self.left == 0) return null;
            self.left -= 1;
            const value = try self.reader.read(u32);
            return value;
        }
    };

    pub fn write(self: *const ParameterDescription, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const ParameterDescription, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("ParameterDescription{{ .count = {d} }}", .{self.count});
    }
};

/// `v`. The server speaks an older minor version than the client asked for, or
/// it ignored some startup options.
pub const NegotiateProtocolVersion = struct {
    body: []const u8,
    /// The newest minor version this server supports.
    minor: u32,
    options: u32,

    pub fn decode(body: []const u8) Error!NegotiateProtocolVersion {
        var reader: wire.Reader = .init(body);
        const minor = try reader.read(u32);
        const options = try reader.read(u32);
        return .{ .body = body, .minor = minor, .options = options };
    }

    pub fn unrecognized(self: *const NegotiateProtocolVersion) Options {
        return .{ .reader = .init(self.body[8..]), .left = self.options };
    }

    pub const Options = struct {
        reader: wire.Reader,
        left: u32,

        pub fn next(self: *Options) Error!?[]const u8 {
            if (self.left == 0) return null;
            self.left -= 1;
            const value = try wire.takeString(&self.reader);
            return value;
        }
    };

    pub fn write(self: *const NegotiateProtocolVersion, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const NegotiateProtocolVersion, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("NegotiateProtocolVersion{{ .minor = {d}, .options = {d} }}", .{
            self.minor,
            self.options,
        });
    }
};

/// `d`. A chunk of a copy stream, in either direction.
pub const CopyData = struct {
    data: []const u8,

    pub fn decode(body: []const u8) Error!CopyData {
        return .{ .data = body };
    }

    pub fn write(self: *const CopyData, e: *Encoder) WriteError!void {
        try e.bytes(self.data);
    }

    pub fn format(self: *const CopyData, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("CopyData{{ {f} }}", .{print.blob(self.data)});
    }
};

/// The body of a copy response: the overall format and the per-column formats.
fn CopyBody(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        body: []const u8,
        /// 0 for text, 1 for binary.
        overall: u8,
        columns: u16,

        pub fn decode(body: []const u8) Error!Self {
            var reader: wire.Reader = .init(body);
            return .{
                .body = body,
                .overall = try reader.read(u8),
                .columns = try reader.read(u16),
            };
        }

        /// One format code per column. All of them are text when the overall
        /// format is text.
        pub fn formats(self: *const Self) wire.U16s {
            return .{ .reader = .init(self.body[1 + 2 ..]), .left = self.columns };
        }

        pub fn write(self: *const Self, e: *Encoder) WriteError!void {
            try e.bytes(self.body);
        }

        pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print("{s}{{ .columns = {d} }}", .{ name, self.columns });
        }
    };
}

/// `G`. The server wants copy-in data.
pub const CopyIn = CopyBody("CopyIn");

/// `H`. The server is about to send copy-out data.
pub const CopyOut = CopyBody("CopyOut");

/// `W`. Streaming replication only: both directions at once.
pub const CopyBoth = CopyBody("CopyBoth");

/// `E`. A failed statement. The connection stays up unless the severity says
/// otherwise.
pub const ErrorResponse = struct {
    body: []const u8,

    pub fn decode(body: []const u8) Error!ErrorResponse {
        return .{ .body = body };
    }

    pub fn fields(self: *const ErrorResponse) error_response.Iterator {
        return .init(self.body);
    }

    pub fn write(self: *const ErrorResponse, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const ErrorResponse, writer: *Io.Writer) Io.Writer.Error!void {
        try formatFields("ErrorResponse", self.body, writer);
    }
};

/// `N`. A warning, a notice, or a server-side log line, carrying the same
/// fields an error does.
pub const NoticeResponse = struct {
    body: []const u8,

    pub fn decode(body: []const u8) Error!NoticeResponse {
        return .{ .body = body };
    }

    pub fn fields(self: *const NoticeResponse) error_response.Iterator {
        return .init(self.body);
    }

    pub fn write(self: *const NoticeResponse, e: *Encoder) WriteError!void {
        try e.bytes(self.body);
    }

    pub fn format(self: *const NoticeResponse, writer: *Io.Writer) Io.Writer.Error!void {
        try formatFields("NoticeResponse", self.body, writer);
    }
};

/// The code and message a person needs, out of a field list.
///
/// A body that ends early stops the scan rather than failing: this writes a
/// log line, and a truncated body is still worth what it carried.
fn formatFields(
    comptime name: []const u8,
    body: []const u8,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    var code: ?[]const u8 = null;
    var message: ?[]const u8 = null;

    var fields = error_response.fields(body);
    while (fields.next() catch null) |field| {
        switch (field.kind()) {
            .code => code = field.value,
            .message => message = field.value,
            else => {},
        }
    }

    try writer.print("{s}{{ .code = {f}, .message = {f} }}", .{
        name,
        print.quoted(code orelse ""),
        print.quoted(message orelse ""),
    });
}

/// `V`. The result of the obsolete fast-path function call.
pub const FunctionCallResponse = struct {
    /// Null when the function returned NULL.
    value: ?[]const u8,

    pub fn decode(body: []const u8) Error!FunctionCallResponse {
        var reader: wire.Reader = .init(body);
        const length = try reader.read(i32);
        if (length == -1) return .{ .value = null };
        if (length < 0) return error.UnexpectedEof;
        return .{ .value = try reader.readSlice(@intCast(length)) };
    }

    pub fn write(self: *const FunctionCallResponse, e: *Encoder) WriteError!void {
        if (self.value) |value| {
            try e.int(i32, @intCast(value.len));
            try e.bytes(value);
        } else {
            try e.int(i32, -1);
        }
    }

    pub fn format(self: *const FunctionCallResponse, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.value) |value| {
            try writer.print("FunctionCallResponse{{ {f} }}", .{print.blob(value)});
        } else {
            try writer.writeAll("FunctionCallResponse{ null }");
        }
    }
};

test "a row keeps its values and says which are null" {
    // Two columns: "one", then a NULL.
    const body = "\x00\x02" ++ "\x00\x00\x00\x03one" ++ "\xff\xff\xff\xff";
    const row: DataRow = try .decode(body);
    try testing.expectEqual(@as(u16, 2), row.columns);

    var values = row.values();
    try testing.expectEqualStrings("one", (try values.next()).?.bytes.?);
    try testing.expectEqual(@as(?[]const u8, null), (try values.next()).?.bytes);
    try testing.expectEqual(@as(?DataRow.Value, null), try values.next());
}

test "a length below -1 is refused, not cast" {
    // -2 would become a huge slice length on the cast.
    const body = "\x00\x01" ++ "\xff\xff\xff\xfe";
    const row: DataRow = try .decode(body);
    var values = row.values();
    try testing.expectError(error.UnexpectedEof, values.next());
}

test "a row description names its columns" {
    const body = "\x00\x01" ++
        "id\x00" ++
        "\x00\x00\x00\x00" ++ // table
        "\x00\x00" ++ // column
        "\x00\x00\x00\x17" ++ // int4
        "\x00\x04" ++ // size
        "\xff\xff\xff\xff" ++ // modifier
        "\x00\x00"; // text
    const description: RowDescription = try .decode(body);
    try testing.expectEqual(@as(u16, 1), description.fields);

    var columns = description.columns();
    const field = (try columns.next()).?;
    try testing.expectEqualStrings("id", field.name);
    try testing.expectEqual(@as(u32, 0), field.table);
    try testing.expectEqual(@as(u32, 23), field.type);
    try testing.expectEqual(@as(i16, 4), field.type_size);
    try testing.expectEqual(@as(?RowDescription.Field, null), try columns.next());
}

test "authentication says which login method is next" {
    try testing.expectEqual(Authentication.ok, try Authentication.decode("\x00\x00\x00\x00"));
    try testing.expectEqual(
        Authentication.cleartext_password,
        try Authentication.decode("\x00\x00\x00\x03"),
    );
    try testing.expectEqual(
        @as([4]u8, .{ 1, 2, 3, 4 }),
        (try Authentication.decode("\x00\x00\x00\x05\x01\x02\x03\x04")).md5_password,
    );

    // The mechanisms are a list of null-terminated names.
    const sasl: Authentication = try .decode("\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00");
    var mechanisms = sasl.sasl.iterator();
    try testing.expectEqualStrings("SCRAM-SHA-256", (try mechanisms.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try mechanisms.next());

    // A code this library does not name stays a number rather than panicking.
    const unknown: Authentication = try .decode("\x00\x00\x00\x63");
    try testing.expectEqual(@as(u32, 99), unknown.unknown);
}

test "a message dispatches on its tag" {
    const decode = Message.decode;
    try testing.expectEqual(
        messages.Transaction.idle,
        (try decode('Z', "I")).ready_for_query.status,
    );
    const tag = "SELECT 1\x00";
    try testing.expectEqualStrings("SELECT 1", (try decode('C', tag)).command_complete.tag);
    try testing.expectEqualStrings(
        "server_version",
        (try decode('S', "server_version\x0018.0\x00")).parameter_status.name,
    );
    try testing.expectError(error.UnknownTag, decode('Q', ""));
}

test "an error prints its code and message" {
    const body = "S" ++ "ERROR\x00" ++ "C" ++ "42P01\x00" ++ "M" ++ "no such table\x00" ++ "\x00";
    const message: Message = try .decode('E', body);
    try testing.expectFmt(
        "ErrorResponse{ .code = \"42P01\", .message = \"no such table\" }",
        "{f}",
        .{message},
    );
}

test "the messages with no body print their names" {
    try testing.expectFmt("ParseComplete", "{f}", .{try Message.decode('1', "")});
    try testing.expectFmt("NoData", "{f}", .{try Message.decode('n', "")});
    try testing.expectFmt("CopyDone", "{f}", .{try Message.decode('c', "")});
    try testing.expectError(error.UnexpectedEof, Message.decode('1', "\x00"));
}

test "copy responses carry the formats of their columns" {
    const body = "\x00" ++ "\x00\x02" ++ "\x00\x00" ++ "\x00\x01";
    const out: Message = try .decode('H', body);
    try testing.expectEqual(@as(u8, 0), out.copy_out_response.overall);
    try testing.expectEqual(@as(u16, 2), out.copy_out_response.columns);

    var formats = out.copy_out_response.formats();
    try testing.expectEqual(@as(?u16, 0), try formats.next());
    try testing.expectEqual(@as(?u16, 1), try formats.next());
    try testing.expectEqual(@as(?u16, null), try formats.next());
}

test "a parameter description is a list of type OIDs" {
    const body = "\x00\x02" ++ "\x00\x00\x00\x17" ++ "\x00\x00\x00\x19";
    const description: Message = try .decode('t', body);
    var types = description.parameter_description.types();
    try testing.expectEqual(@as(?u32, 23), try types.next());
    try testing.expectEqual(@as(?u32, 25), try types.next());
    try testing.expectEqual(@as(?u32, null), try types.next());
}

test "the cancel key is as long as the frame says" {
    const body = "\x00\x00\x22\xa0" ++ "\xd9\x0c\xae\xdb";
    const key: BackendKeyData = try .decode(body);
    try testing.expectEqual(@as(u32, 8864), key.process);
    try testing.expectEqualSlices(u8, "\xd9\x0c\xae\xdb", key.key);

    // Protocol 3.2 allows up to 256 bytes, so nothing here assumes four.
    const long = "\x00\x00\x22\xa0" ++ "0123456789abcdef";
    try testing.expectEqual(@as(usize, 16), (try BackendKeyData.decode(long)).key.len);
}

test "every backend message encodes back to its bytes" {
    // One sample per tag, in the shape the docs give. Decoding and encoding it
    // again must return the same message, which is what makes the two
    // directions two directions of one codec.
    const samples = [_]struct { tag: u8, body: []const u8 }{
        .{ .tag = 'R', .body = "\x00\x00\x00\x03" },
        .{ .tag = 'K', .body = "\x00\x00\x22\xa0\xd9\x0c\xae\xdb" },
        .{ .tag = '2', .body = "" },
        .{ .tag = '3', .body = "" },
        .{ .tag = 'C', .body = "SELECT 1\x00" },
        .{ .tag = 'W', .body = "\x00\x00\x01\x00\x00" },
        .{ .tag = 'd', .body = "abc" },
        .{ .tag = 'c', .body = "" },
        .{ .tag = 'G', .body = "\x00\x00\x00" },
        .{ .tag = 'H', .body = "\x01\x00\x01\x00\x01" },
        .{ .tag = 'D', .body = "\x00\x02\x00\x00\x00\x03one\xff\xff\xff\xff" },
        .{ .tag = 'I', .body = "" },
        .{ .tag = 'E', .body = "SERROR\x00C42P01\x00Mno such table\x00\x00" },
        .{ .tag = 'V', .body = "\x00\x00\x00\x03abc" },
        .{ .tag = 'v', .body = "\x00\x00\x00\x00\x00\x00\x00\x01opt\x00" },
        .{ .tag = 'n', .body = "" },
        .{ .tag = 'N', .body = "SNOTICE\x00\x00" },
        .{ .tag = 'A', .body = "\x00\x00\x00\x01chan\x00payload\x00" },
        .{ .tag = 't', .body = "\x00\x02\x00\x00\x00\x17" },
        .{ .tag = 'S', .body = "server_version\x0018.0\x00" },
        .{ .tag = '1', .body = "" },
        .{ .tag = 's', .body = "" },
        .{ .tag = 'Z', .body = "I" },
        .{ .tag = 'T', .body = "\x00\x01id\x00" ++
            "\x00\x00\x00\x00\x00\x00" ++
            "\x00\x00\x00\x17\x00\x04" ++
            "\xff\xff\xff\xff\x00\x00" },
    };

    var buffer: [256]u8 = undefined;

    for (samples) |sample| {
        const message = try Message.decode(sample.tag, sample.body);

        var e: Encoder = .init;
        e.reset(&buffer);
        const bytes = try message.encode(&e);

        try testing.expectEqual(sample.tag, bytes[0]);

        var frame: wire.Reader = .init(bytes);
        _ = try frame.read(u8);
        try testing.expectEqual(@as(u32, @intCast(bytes.len - 1)), try frame.read(u32));
        try testing.expectEqualSlices(u8, sample.body, bytes[5..]);
    }
}
