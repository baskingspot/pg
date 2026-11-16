//! PostgreSQL wire protocol in Zig: message framing, with no IO and no
//! allocator.
//!
//! Callers provide every buffer. `frame.Decoder` finds message boundaries and
//! hands out headers and body runs; the codecs that read a body into a message
//! sit above it.
//!
//! ```
//! const pg = @import("pg");
//!
//! var decoder: pg.frame.Decoder = .init();
//! var rest = chunk_from_the_socket;
//!
//! while (rest.len != 0 or decoder.inMessage()) {
//!     const step = try decoder.next(rest);
//!     rest = rest[step.consumed..];
//!
//!     switch (step.event) {
//!         .header => |header| {
//!             const tag = try pg.messages.Backend.fromByte(header.tag);
//!             // ... decode header.bodyLength() bytes from the body runs
//!         },
//!         .body => |complete| if (complete) { ... },
//!         .more => break,
//!     }
//! }
//! ```

const std = @import("std");
const testing = std.testing;

pub const backend = @import("proto/backend.zig");
pub const error_response = @import("proto/error_response.zig");
pub const frame = @import("proto/frame.zig");
pub const frontend = @import("proto/frontend.zig");
pub const messages = @import("proto/messages.zig");
pub const replication = @import("proto/replication.zig");
pub const sqlstate = @import("proto/sqlstate.zig");
pub const startup = @import("proto/startup.zig");
pub const Version = @import("proto/Version.zig");
pub const wire = @import("proto/wire.zig");
pub const write = @import("proto/write.zig");

test {
    testing.refAllDecls(@This());
    _ = @import("fuzz.zig");
}
