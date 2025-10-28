// src/zerver/util/helpers.zig
/// Shared helper functions
const zerver = @import("../root.zig");

/// Helper function that simply delegates to the core step wrapper.
pub fn makeStep(comptime name: []const u8, comptime func: anytype) zerver.types.Step {
    return zerver.step(name, func);
}
// Covered by unit test: tests/unit/util_helpers_test.zig
