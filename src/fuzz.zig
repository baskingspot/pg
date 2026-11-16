//! Fuzz the decoders on the bodies a proxy forwards.
//!
//! `just test` replays every corpus entry through the runner, which is what
//! runs in CI. Mutation needs Zig's own fuzzer, and on 0.17.1 neither entry
//! point works from this tree: `zig build` with a fuzz module and `--fuzz`
//! answers "no fuzz tests found", and `zig test -ffuzz` runs the binary
//! without the `--cache-dir` its runner requires. A minimal package with one
//! `testing.fuzz` test reproduces both, so it is the toolchain and not this
//! wiring. Until that changes, the corpus is the check.
//!
//! The property under test is the same in every one of them: whatever a
//! decoder returns, every slice it hands back is inside the bytes it was
//! given, and every loop it starts ends. A decoder that reads past its input
//! is the bug this file exists to find.

const std = @import("std");
const testing = std.testing;

const backend = @import("proto/backend.zig");
const frame = @import("proto/frame.zig");
const startup = @import("proto/startup.zig");

test "fuzz authentication request" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [65536]u8 = undefined;
            const len = smith.slice(&buffer);
            const input = buffer[0..len];

            const auth = backend.Authentication.decode(input) catch return;
            switch (auth) {
                .md5_password => {},
                .gss_continue, .sasl_continue, .sasl_final => |data| {
                    try testing.expect(data.len <= input.len);
                },
                .sasl => |sasl| {
                    var mechanisms = sasl.iterator();
                    while (mechanisms.next() catch return) |name| {
                        try testing.expect(name.len <= input.len);
                    }
                },
                else => {},
            }
        }
    }.run, .{ .corpus = &.{
        &[_]u8{ 0, 0, 0, 0 },
        "\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00",
        &[_]u8{ 0, 0, 0, 5, 1, 2, 3, 4 },
        "\x00\x00\x00\x0br=nonce,s=salt,i=4096",
        "\x00\x00\x00\x0cv=c2lnbmF0dXJl",
        &[_]u8{ 0, 0, 0 },
        "\x00\x00\x00\x0aSCRAM-SHA-256\x00",
        "",
    } });
}

test "fuzz startup" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [65536]u8 = undefined;
            const len = smith.slice(&buffer);
            const input = buffer[0..len];

            const message = startup.Message.decode(input) catch return;
            switch (message) {
                .startup => |value| {
                    var parameters = value.sent();
                    while (parameters.next() catch return) |parameter| {
                        try testing.expect(parameter.name.len <= input.len);
                        try testing.expect(parameter.value.len <= input.len);
                    }
                },
                .cancel_request => |cancel| {
                    try testing.expect(cancel.key.len <= input.len);
                },
                else => {},
            }
        }
    }.run, .{ .corpus = &.{
        "\x00\x00\x00\x08\x04\xd2\x16\x2f",
        "\x00\x00\x00\x10\x04\xd2\x16\x2e\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x00\x00\x00\x08\x04\xd2\x16\x30",
        "\x00\x00\x00\x08\x00\x03\x00\x00",
        "",
    } });
}

test "fuzz data row" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [65536]u8 = undefined;
            const len = smith.slice(&buffer);
            const input = buffer[0..len];

            const row = backend.DataRow.decode(input) catch return;
            var values = row.values();
            while (values.next() catch return) |value| {
                if (value.bytes) |bytes| {
                    try testing.expect(bytes.len <= input.len);
                }
            }
        }
    }.run, .{
        .corpus = &.{
            "\x00\x01\xff\xff\xff\xff",
            "\x00\x01\x00\x00\x00\x00",
            "\x00\x01\x00\x00\x00\x03one",
            "\x00\x01\xff\xff\xff\xfe",
            "\x00\x01\x00\x00\x00\x04one",
            "",
            &[_]u8{0},
        },
    });
}

test "fuzz backend dispatch" {
    // Every tag reaches a decoder, and every decoder's answer formats without
    // reading outside the body it was given.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [65536]u8 = undefined;
            const len = smith.slice(&buffer);
            const input = buffer[0..len];
            if (input.len == 0) return;

            const message = backend.Message.decode(input[0], input[1..]) catch return;

            // A log line is allowed to be longer than this; what matters is
            // that formatting walks the parsed fields inside the body.
            var out: [256]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&out);
            message.format(&writer) catch return;
        }
    }.run, .{ .corpus = &.{
        "Z" ++ "I",
        "C" ++ "SELECT 1\x00",
        "S" ++ "server_version\x0018.0\x00",
        "E" ++ "SERROR\x00C42P01\x00Mno such table\x00\x00",
        "T" ++ "\x00\x01id\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x04\xff\xff\xff\xff\x00\x00",
        "z",
        "R",
    } });
}

test "fuzz frame decoder" {
    // The boundary finder is fed arbitrary bytes, including a claimed length
    // of a gigabyte. It must never hand back more than it was given, never
    // report progress without consuming, and never fail to finish.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var buffer: [65536]u8 = undefined;
            const len = smith.slice(&buffer);
            const input = buffer[0..len];

            var decoder: frame.Decoder = .init;
            var rest = input;
            var steps: usize = 0;

            while (rest.len != 0 or decoder.in_message) {
                const step = decoder.next(rest) catch return;

                try testing.expect(step.consumed <= rest.len);

                // `.more` consumes nothing and only arrives when the input is
                // spent. A loop that did not stop here would ask forever.
                if (step.event == .more) break;

                try testing.expect(step.consumed != 0);
                rest = rest[step.consumed..];
                steps += 1;

                // The two invariants above imply this bound; the counter is
                // here so a future bug hangs the test instead of the machine.
                if (steps > input.len + 2) return error.TooManySteps;
            }
        }
    }.run, .{ .corpus = &.{
        "S\x00\x00\x00\x04",
        "Q\x00\x00\x00\x0dselect 1\x00",
        "D\x00\x00\x00\x14\x00\x02\x00\x00\x00\x03one\xff\xff\xff\xff",
        "Q\x00\x00\x00\x03",
        "Q\x7f\xff\xff\xff",
        "Q",
        "",
    } });
}
