//! The benchmark suite root. `addMod` finds every top-level
//! `pub fn benchmark*` in the module and registers it by name.

const testingx = @import("testingx");

const backend = @import("backend.zig");
const frame = @import("frame.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(backend);
    try b.addMod(frame);
}
