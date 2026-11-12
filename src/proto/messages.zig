//! PostgreSQL wire protocol message tags, and the messages whose bytes are
//! constant.
//!
//! Every message outside the startup phase starts with a tag byte. The length
//! and the body are `frame.zig`'s business. The startup messages carry no tag
//! and are not here.
//!
//! Tags are not unique across directions. `d` and `c` are copy data and copy
//! done both ways, `p` is a password or a SASL or GSS response depending on
//! when it is sent, and `R` covers a dozen authentication variants. The enums
//! below are per direction; whatever resolves the rest is the connection
//! state machine, not this file.
//!
//! https://www.postgresql.org/docs/current/protocol-message-formats.html

const std = @import("std");
const testing = std.testing;
const enums = std.enums;

/// Frontend to backend messages. A client encodes these; only a server or a
/// proxy decodes them.
pub const Frontend = enum(u8) {
    bind = 'B',
    close = 'C',
    describe = 'D',
    execute = 'E',
    function_call = 'F',
    flush = 'H',
    parse = 'P',
    query = 'Q',
    sync = 'S',
    terminate = 'X',
    copy_data = 'd',
    copy_done = 'c',
    copy_fail = 'f',
    /// Password, SASL initial response, SASL response, or GSS response. The
    /// tag alone does not say which; the authentication conversation does.
    password = 'p',

    pub fn fromByte(byte: u8) error{UnknownTag}!Frontend {
        return enums.fromInt(Frontend, byte) orelse error.UnknownTag;
    }

    pub fn toByte(self: Frontend) u8 {
        return @backingInt(self);
    }
};

/// Backend to frontend messages. A client decodes these; only a server or a
/// proxy encodes them.
pub const Backend = enum(u8) {
    /// Every authentication variant shares this tag. The first int32 of the
    /// body selects one through `Auth`.
    authentication = 'R',
    backend_key_data = 'K',
    bind_complete = '2',
    close_complete = '3',
    command_complete = 'C',
    copy_both_response = 'W',
    copy_data = 'd',
    copy_done = 'c',
    copy_in_response = 'G',
    copy_out_response = 'H',
    data_row = 'D',
    empty_query_response = 'I',
    error_response = 'E',
    function_call_response = 'V',
    negotiate_protocol_version = 'v',
    no_data = 'n',
    notice_response = 'N',
    notification_response = 'A',
    parameter_description = 't',
    parameter_status = 'S',
    parse_complete = '1',
    portal_suspended = 's',
    ready_for_query = 'Z',
    row_description = 'T',

    pub fn fromByte(byte: u8) error{UnknownTag}!Backend {
        return enums.fromInt(Backend, byte) orelse error.UnknownTag;
    }

    pub fn toByte(self: Backend) u8 {
        return @backingInt(self);
    }
};

/// The transaction status that a `ReadyForQuery` carries.
pub const Transaction = enum(u8) {
    /// Not in a transaction block.
    idle = 'I',
    /// In a transaction block.
    in_block = 'T',
    /// In a failed transaction block; queries are rejected until it ends.
    failed = 'E',

    pub fn fromByte(byte: u8) error{UnknownTag}!Transaction {
        return enums.fromInt(Transaction, byte) orelse error.UnknownTag;
    }
};

/// The first int32 of an `authentication` message.
pub const Auth = enum(u32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    /// The body carries four bytes of salt after this word.
    md5_password = 5,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    /// The body carries the mechanism names, each null-terminated, then a
    /// final null.
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,

    pub fn fromCode(code: u32) error{UnknownAuth}!Auth {
        return enums.fromInt(Auth, code) orelse error.UnknownAuth;
    }
};

/// `ErrorResponse` and `NoticeResponse` field codes.
///
/// The registry is open. The protocol says a frontend silently ignores a field
/// code it does not know, so `fromByte` returns null instead of an error, and
/// a decoder skips to the next field.
///
/// A field appears at most once in a message, in any order, and the body ends
/// with a zero byte.
pub const ErrorField = enum(u8) {
    /// `S`. Localized.
    severity = 'S',
    /// `V`. Never localized; present from PostgreSQL 9.6.
    severity_unlocalized = 'V',
    /// `C`. The SQLSTATE code.
    code = 'C',
    message = 'M',
    detail = 'D',
    hint = 'H',
    /// `P`. A one-based character index into the submitted query, not bytes.
    position = 'P',
    /// `p`. The same, for a command the server generated itself.
    internal_position = 'p',
    /// `q`. The text of that generated command.
    internal_query = 'q',
    /// `W`. A call stack of procedures and generated queries, most recent
    /// first.
    where = 'W',
    schema = 's',
    table = 't',
    column = 'c',
    data_type = 'd',
    constraint = 'n',
    file = 'F',
    line = 'L',
    routine = 'R',

    pub fn fromByte(byte: u8) ?ErrorField {
        return enums.fromInt(ErrorField, byte);
    }
};

/// Messages whose bytes never vary, so the wire form is a constant.
pub const fixed = struct {
    pub const sync: [5]u8 = .{ 'S', 0, 0, 0, 4 };
    pub const terminate: [5]u8 = .{ 'X', 0, 0, 0, 4 };
    pub const flush: [5]u8 = .{ 'H', 0, 0, 0, 4 };

    /// Bind the unnamed portal to the unnamed statement with no parameters,
    /// no format codes, and no result format codes. Length 12: the two empty
    /// names and three zero counts after the four-byte length.
    pub const bind_empty: [13]u8 = .{ 'B', 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0 };

    /// Describe the unnamed portal. Length 6.
    pub const describe_portal: [7]u8 = .{ 'D', 0, 0, 0, 6, 'P', 0 };

    /// Execute the unnamed portal with no row limit. Length 9.
    pub const execute_portal: [10]u8 = .{ 'E', 0, 0, 0, 9, 0, 0, 0, 0, 0 };
};

test "tags round-trip" {
    try testing.expectEqual(Frontend.query, try Frontend.fromByte('Q'));
    try testing.expectEqual(@as(u8, 'p'), Frontend.password.toByte());
    try testing.expectEqual(Backend.ready_for_query, try Backend.fromByte('Z'));
    try testing.expectEqual(Backend.negotiate_protocol_version, try Backend.fromByte('v'));
    try testing.expectEqual(Transaction.failed, try Transaction.fromByte('E'));
}

test "a tag belongs to one direction" {
    // Query is frontend only, ReadyForQuery is backend only. A decoder that
    // guesses the direction accepts both and is wrong either way.
    try testing.expectError(error.UnknownTag, Backend.fromByte('Q'));
    try testing.expectError(error.UnknownTag, Frontend.fromByte('Z'));
}

test "error field codes are distinct" {
    // P is the submitted query, p is a generated one, q is its text. An
    // off-by-one here relabels a position as an internal position, which is
    // the kind of thing a client cannot tell from the outside.
    try testing.expectEqual(ErrorField.position, ErrorField.fromByte('P').?);
    try testing.expectEqual(ErrorField.internal_position, ErrorField.fromByte('p').?);
    try testing.expectEqual(ErrorField.internal_query, ErrorField.fromByte('q').?);
}

test "unknown error fields are skipped, not rejected" {
    // 'X' is not a field code, and the protocol says to ignore it.
    try testing.expectEqual(@as(?ErrorField, null), ErrorField.fromByte('X'));
    // Zero terminates the body rather than naming a field.
    try testing.expectEqual(@as(?ErrorField, null), ErrorField.fromByte(0));
}

test "fixed messages declare their own length" {
    inline for (.{
        fixed.sync,
        fixed.terminate,
        fixed.flush,
        fixed.bind_empty,
        fixed.describe_portal,
        fixed.execute_portal,
    }) |message| {
        const declared = std.mem.readInt(u32, message[1..5], .big);
        try testing.expectEqual(@as(u32, message.len - 1), declared);
    }
}

test "fixed messages start with their tag" {
    inline for (.{
        fixed.sync,
        fixed.terminate,
        fixed.flush,
        fixed.bind_empty,
        fixed.describe_portal,
        fixed.execute_portal,
    }) |message| {
        _ = try Frontend.fromByte(message[0]);
    }
}
