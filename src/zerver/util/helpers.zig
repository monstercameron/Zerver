// src/zerver/util/helpers.zig
/// Shared helper functions
const std = @import("std");
const zerver = @import("../root.zig");

/// Helper function to create a step that wraps a CtxBase function
pub fn makeStep(comptime name: []const u8, comptime func: anytype) zerver.types.Step {
    return zerver.types.Step{
        .name = name,
        .call = func,
        .reads = &.{},
        .writes = &.{},
        // TODO: Logical Error - The 'makeStep' function currently sets 'reads' and 'writes' to empty arrays. This bypasses CtxView's compile-time access control. Implement a mechanism to extract 'reads' and 'writes' from the step function's CtxView specification.
    };
}
// Covered by unit test: tests/unit/util_helpers_test.zig