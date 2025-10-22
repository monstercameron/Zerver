/// Shared helper functions
const std = @import("std");
const zerver = @import("../../zerver/root.zig");

/// Helper function to create a step that wraps a CtxBase function
pub fn makeStep(comptime name: []const u8, comptime func: anytype) zerver.types.Step {
    return zerver.types.Step{
        .name = name,
        .call = struct {
            pub fn wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
                const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
                return func(ctx);
            }
        }.wrapper,
        .reads = &.{},
        .writes = &.{},
    };
}
