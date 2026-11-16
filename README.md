<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="pg" height="48">
  </picture>
</h1>

PostgreSQL wire protocol in Zig: every message, both directions, no socket.

Postgres defines 42 messages and four more that open a connection, and each one is a byte layout in the manual. This library is those layouts. It turns bytes into messages and messages into bytes, and it has no opinion about what a connection should do next. A client, a server, or a proxy built on it owns the socket, the buffers, and the policy; this owns the bytes.

No allocator, no IO, and no `std.Io` in the wire path.

## What is in it

- `pg.messages`: the tag byte of every message as an enum, and the SQLSTATE codes. `Backend.fromByte` is a cast, because a tag off the wire is a value the library has not necessarily named.
- `pg.frame.Decoder`: finds message boundaries in a stream without holding a body, so a `DataRow` larger than the read buffer costs nothing. Reports a header, then the body in the runs the caller feeds it.
- `pg.backend`: one arm per backend message, tagged by `messages.Backend`. Decodes borrow the body; `DataRow.values()`, `RowDescription.columns()`, and the copy responses hand out iterators. `write` re-emits what it decoded, and `ErrorResponse`, `DataRow`, and `RowDescription` also build from fields.
- `pg.frontend`: one arm per frontend message, tagged by `messages.Frontend`, so an arm's name is its wire byte. `Message.encode` writes the tag and the length; `Decoded` reads the other direction, with views for the three messages whose lists have no fixed size.
- `pg.startup`: `StartupMessage`, `SSLRequest`, `GSSENCRequest`, and `CancelRequest`, the phase that has no tag byte. `peek` reads eight bytes and says which one is opening the connection.
- `pg.replication`: `XLogData`, the primary keepalive, the standby status update, and hot standby feedback, which ride inside `CopyData`.
- `pg.write`: an `Encoder` over caller-owned bytes. `finish` backfills a length that is only known after the body was written.
- `pg.print`: `{f}` on a message gives the one line a log wants. Strings are quoted and escaped, and a password or a copy stream prints as a size.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/pg
```

Add the module to your build:

```zig
const pg = b.dependency("pg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pg", pg.module("pg"));
```

`pg` builds with Zig 0.17.

## Reading a stream

`frame.Decoder` hands back a header and then the body in whatever runs arrive, so nothing is copied and no buffer has to be sized for the largest message:

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
        .header => |header| if (header.tag == 'D') {
            // row in progress: accumulate the body runs if you need the bytes
        },
        .body => |complete| if (complete) {
            // the message ended
        },
    }
}
```

Decoding a body is `backend.Message.decode(tag, body)`, which needs the whole body in one slice.

## Writing one

```zig
var buffer: [512]u8 = undefined;
var encoder: pg.write.Encoder = .init;
encoder.reset(&buffer);

const message: pg.frontend.Message = .{ .query = .{ .sql = "select 1" } };
const bytes = try message.encode(&encoder); // "Q\0\0\0\x0dselect 1\0"
```

A message whose bytes never vary is built at compile time from the same encoder, as in `pg.frontend.fixed.sync`.

## What is not here

- A connection. Startup, authentication, and the ready-for-query cycle are a state machine above this, and this library does not run one.
- SCRAM-SHA-256 and MD5. The messages they ride on are here, `Authentication` and `Password`, and the algorithm is not.
- Constructing a backend message from values beyond the three builders. A `DataRow` built from columns is there; a server that needs others writes them by hand.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs. `just bench` measures the decoders, and `just fuzz 10M` runs the fuzzer with an iteration budget.

## License

MIT. See `LICENSE`. The logo files in `docs/static/` are baskingspot marks and are not covered by it. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
