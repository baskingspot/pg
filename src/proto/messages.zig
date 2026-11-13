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

const readInt = @import("mem.zig").readInt;

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

    /// A tag this library does not name. The wire can carry one: a newer
    /// server, a proxy, or a byte that is not a tag at all. A switch over the
    /// enum reaches its `else` arm, and the caller decides what to do.
    _,

    pub inline fn fromByte(byte: u8) Frontend {
        return @fromBackingInt(byte);
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

    /// A tag this library does not name. The wire can carry one: a newer
    /// server, a proxy, or a byte that is not a tag at all. A switch over the
    /// enum reaches its `else` arm, and the caller decides what to do.
    _,

    pub inline fn fromByte(byte: u8) Backend {
        return @fromBackingInt(byte);
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

    /// A status byte this library does not name.
    _,

    pub inline fn fromByte(byte: u8) Transaction {
        return @fromBackingInt(byte);
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

    /// An authentication code this library does not name.
    _,

    pub inline fn fromCode(code: u32) Auth {
        return @fromBackingInt(code);
    }
};

/// `ErrorResponse` and `NoticeResponse` field codes.
///
/// The registry is open. The protocol says a frontend silently ignores a field
/// code it does not know, so an unknown code stays an unknown value: it
/// compares equal to none of the fields below and falls into the `else` arm.
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

    /// A field code this library does not name. The protocol says to ignore
    /// it, and an unknown code compares equal to none of the fields above.
    _,

    pub inline fn fromByte(byte: u8) ErrorField {
        return @fromBackingInt(byte);
    }
};
/// Whether `value` is one of the tags `E` declares. A non-exhaustive enum can
/// hold any tag in its backing type, so this is the check a decoder makes when
/// it has to tell a message from a byte it does not know.
fn isDeclared(comptime E: type, value: E) bool {
    inline for (enums.values(E)) |declared| {
        if (@backingInt(declared) == @backingInt(value)) return true;
    }
    return false;
}

test "tags round-trip" {
    try testing.expectEqual(Frontend.query, Frontend.fromByte('Q'));
    try testing.expectEqual(@as(u8, 'p'), Frontend.password.toByte());
    try testing.expectEqual(Backend.ready_for_query, Backend.fromByte('Z'));
    try testing.expectEqual(Backend.negotiate_protocol_version, Backend.fromByte('v'));
    try testing.expectEqual(Transaction.failed, Transaction.fromByte('E'));
}

test "every declared tag survives the conversion" {
    inline for (enums.values(Frontend)) |tag| {
        try testing.expectEqual(tag, Frontend.fromByte(@backingInt(tag)));
    }
    inline for (enums.values(Backend)) |tag| {
        try testing.expectEqual(tag, Backend.fromByte(@backingInt(tag)));
    }
    inline for (enums.values(Transaction)) |state| {
        try testing.expectEqual(state, Transaction.fromByte(@backingInt(state)));
    }
    inline for (enums.values(ErrorField)) |field| {
        try testing.expectEqual(field, ErrorField.fromByte(@backingInt(field)));
    }
}

test "a tag belongs to one direction" {
    // Query is frontend only, ReadyForQuery is backend only. A decoder that
    // guesses the direction accepts both and is wrong either way. The
    // conversion cannot refuse, so what it must do is keep the byte and not
    // pretend to be one of the tags it declares.
    try testing.expect(!isDeclared(Backend, Backend.fromByte('Q')));
    try testing.expect(!isDeclared(Frontend, Frontend.fromByte('Z')));
    try testing.expectEqual(@as(u8, 'Q'), @backingInt(Backend.fromByte('Q')));
}

test "error field codes are distinct" {
    // P is the submitted query, p is a generated one, q is its text. An
    // off-by-one here relabels a position as an internal position, which is
    // the kind of thing a client cannot tell from the outside.
    try testing.expectEqual(ErrorField.position, ErrorField.fromByte('P'));
    try testing.expectEqual(ErrorField.internal_position, ErrorField.fromByte('p'));
    try testing.expectEqual(ErrorField.internal_query, ErrorField.fromByte('q'));
}

test "an unknown error field keeps its code" {
    // 'X' is not a field code, and the protocol says to ignore it. Ignoring
    // it starts with it comparing equal to nothing this library names.
    try testing.expect(!isDeclared(ErrorField, ErrorField.fromByte('X')));
    try testing.expectEqual(@as(u8, 'X'), @backingInt(ErrorField.fromByte('X')));
    // Zero terminates the body rather than naming a field.
    try testing.expect(!isDeclared(ErrorField, ErrorField.fromByte(0)));
}
