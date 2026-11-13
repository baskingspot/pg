//! The benchmark suite root. `addMod` finds every top-level
//! `pub fn benchmark*` in the module and registers it by name.

const testingx = @import("testingx");

const frame = @import("frame.zig");
const tag = @import("tag.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(frame);
    try b.addMod(tag);
}
