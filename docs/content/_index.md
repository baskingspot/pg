+++
title = "pg"
+++

PostgreSQL wire protocol in Zig: frontend and backend message codecs, with no IO
and no allocator.

Postgres defines 42 messages and four more that open a connection, and each one
is a byte layout in the manual. This library is those layouts. It turns bytes
into messages and messages into bytes, and it has no opinion about what a
connection does next: a client, a server, or a proxy built on it owns the
socket, the buffers, and the policy.

- [Reading a stream](#reading-a-stream): `frame.Decoder` finds boundaries without holding a body, so a `DataRow` larger than the read buffer costs nothing.
- [Decoding a message](#decoding-a-message): `backend.Message.decode` takes a tag and a body, and every slice it returns points into that body.
- [Writing a message](#writing-a-message): `frontend.Message.encode` writes the tag from the union arm and the length after the body.
- [Opening a connection](#opening-a-connection): the four messages before the protocol has tags, and `startup.peek` for the first eight bytes.
- [Error codes](#error-codes): `sqlstate.SqlState` holds every SQLSTATE code, and the code is the enum tag.
- [Limits](#limits): no connection, no SCRAM, and one builder that is missing.

The [API reference](https://baskingspot.dev/pg/api/) documents every public
symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/pg/v0.1.0.tar.gz
```

Add the module to your build:

```zig
const pg = b.dependency("pg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pg", pg.module("pg"));
```

## Import it

```zig
const pg = @import("pg");
```

The module name does not collide with anything in `std`.

## Read the examples

`pg` builds with Zig 0.17. `just ci` runs the tests, the lint, a benchmark smoke
run, and this site's build, so a guide that stops compiling fails CI.

# Reading a stream

`frame.Decoder` hands back a header and then the body in whatever runs arrive.
Nothing is copied, and no buffer has to be sized for the largest message a
server might send.

```zig
var decoder: pg.frame.Decoder = .init;
var rest = bytes_from_the_socket;

while (rest.len != 0 or decoder.in_message) {
    const step = try decoder.next(rest);
    rest = rest[step.consumed..];

    switch (step.event) {
        // `.more` is the only event that consumes nothing. A loop that does
        // not stop here asks forever.
        .more => break,
        .header => |header| {
            // `header.tag` is the byte, `header.bodyLength()` the room it needs
        },
        .body => |complete| {
            if (complete) {
                // the message ended
            }
        },
    }
}
```

Two rules cover the states. The loop condition has to test `in_message` as well
as unread bytes, because a five-byte message reports its header and then its end
on a later call with nothing fed to it. And `.more` always consumes zero, so it
is the only event to break on.

A length below 4, or above 1 GiB, is `error.InvalidLength` or
`error.MessageTooLong`. Either one means the bytes no longer line up with a
message boundary: drop the connection rather than reading on.

# Decoding a message

`backend.Message.decode` takes the tag byte from the header and the body as one
slice. Every slice it returns points into that body, so the body has to outlive
the message.

```zig
const message = try pg.backend.Message.decode(header.tag, body);

switch (message) {
    .data_row => |row| {
        var values = row.values();
        while (try values.next()) |value| {
            // `value.bytes` is null for a SQL NULL
        }
    },
    .ready_for_query => |ready| switch (ready.status) {
        .in_block => {},
        else => {},
    },
    else => {},
}
```

A tag this library does not name is `error.UnknownTag` rather than a panic: the
tag enums are non-exhaustive, because a tag off the wire is a value the library
has not necessarily heard of, and a proxy may want to forward it.

Five messages carry a list whose size the wire decides: `DataRow`,
`RowDescription`, `ParameterDescription`, `NegotiateProtocolVersion`, and the
copy responses. They keep the body and hand out an iterator, since this layer
does not allocate.

`Authentication` is a union over the twelve login codes, and the `p` tag is a
union of its own: a password, a SASL initial response, a SASL response, and a GSS
response share one byte, and only the authentication conversation knows which
one arrived.

# Writing a message

```zig
var buffer: [512]u8 = undefined;
var encoder: pg.write.Encoder = .init;
encoder.reset(&buffer);

const message: pg.frontend.Message = .{ .query = .{ .sql = "select 1" } };
const bytes = try message.encode(&encoder);
```

`frontend.Message` is a union tagged by `messages.Frontend`, so an arm's name is
its wire byte and the encoder writes the tag from the arm. A message whose bytes
never vary is built at compile time from the same code:

```zig
const sync = pg.frontend.fixed.sync; // [5]u8: 'S', 0, 0, 0, 4
```

The encoder writes into bytes the caller owns and keeps the length field by
offset, so the buffer must not move or be reallocated until `finish`.

A proxy that composes a backend message instead of forwarding one uses the three
builders: `ErrorResponse` from a severity, a `SqlState`, and a message;
`DataRow` from `[]const ?[]const u8`; `RowDescription` from the `Field` shape it
decodes to.

`{f}` on a message gives the line a log wants. Strings are quoted and escaped,
a password or a copy stream prints as a size, and `pg.print.tag` names a tag the
library declares and prints the number otherwise, which `{t}` cannot do.

# Opening a connection

The first message on a connection has no tag: four bytes of length, then a
version or a request code. `startup.peek` reads eight bytes and says which one
it is.

```zig
if (pg.startup.peek(prefix)) |kind| switch (kind) {
    .startup => {},        // length, version, parameters
    .ssl_request => {},    // eight bytes total
    .gssenc_request => {}, // eight bytes total
    .cancel_request => {}, // length, the code, a process id, a key
};
```

A tagged message puts its tag where the length goes, and four bytes with a tag
in front read far past the 10000-byte cap the server itself enforces on a
startup packet, which is why an unrecognized prefix is null. `startup.length`
gives the count of bytes to buffer, and `startup.Message.decode` the rest.

# Error codes

`sqlstate.SqlState` is every SQLSTATE code as an enum whose tag is the code, so
comparing, switching, and printing cost what an enum costs and there is no
lookup table.

```zig
var fields = error_body.fields();
while (try fields.next()) |field| switch (field.kind()) {
    .code => if (field.state()) |state| switch (state) {
        .unique_violation => {},
        else => {},
    },
    else => {},
};
```

An unknown code keeps its five bytes and compares equal to none of the named
ones, since the registry is open and a client must carry a code it has not heard
of.

# Limits

- A connection: startup, authentication, and the ready-for-query cycle are a state machine above this library, and `pg` does not run one.
- SCRAM-SHA-256 and MD5: the messages they ride on are here, `Authentication` and `Password`, and the algorithms are not. Nothing here can complete a login against PostgreSQL 10 or later on its own.
- Backend builders beyond the three: a server that needs a `CommandComplete` or a `ParameterStatus` composed from values writes those bytes itself, or decodes one it received and rewrites it.
- Replication bodies: `XLogData` carries the WAL stream, and the `pgoutput` format inside it is a decoder above this one.
