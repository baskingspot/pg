# Changelog

All notable changes to pg are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-16

### Added

- Every frontend and backend message in `pg.frontend` and `pg.backend`, tagged
  by `pg.messages.Frontend` and `pg.messages.Backend`, so an arm's name is its
  wire byte. `pg.frontend.Decoded` reads the client side, with views for the
  three messages whose lists have no fixed size.
- `pg.frame.Decoder` finds message boundaries without buffering a body: a
  header, then body runs.
- `pg.startup` covers `StartupMessage`, `SSLRequest`, `GSSENCRequest`, and
  `CancelRequest`, and `pg.startup.peek` names the one that opens a connection.
- `pg.replication` decodes `XLogData`, the primary keepalive, the standby
  status update, and hot standby feedback from a `CopyData` payload.
- `pg.sqlstate` holds all 263 SQLSTATE codes as a `u40` enum whose tag is the
  code, and `error_response.Field.state()` reads one out of an error.
- `pg.write.Encoder` writes into caller-owned bytes and backfills a length
  after the body. `pg.frontend.fixed` builds the messages whose bytes never
  vary at compile time from the same encoder.
- Builders for `ErrorResponse`, `DataRow`, and `RowDescription`, so a proxy or a
  server composes one instead of only forwarding.
- `{f}` renders a message for a log line: strings quoted and escaped, and a
  password or copy stream as a size. `pg.Version` prints as `3.2`.
- A fuzz corpus for the decoders, replayed on every test run.

### Changed

- `Version.zig` is the struct itself, so the type is `pg.Version`. The
  `pg.version.Version` path is gone.

### Fixed

- `{t}` on a wire-decoded enum panicked on a tag the library does not name.
  `pg.print.tag` names a declared tag and prints the number otherwise.
- `frontend.Target` was exhaustive and decoded from a byte; it carries a byte
  this library does not name now.
