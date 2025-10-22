/// Hello feature step implementations
const std = @import("std");
const zerver = @import("../../zerver/root.zig");

pub fn helloStep(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Hello] Hello step called\n", .{});
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .body = "Hello from Zerver! Try /todos endpoints with X-User-ID header.",
    });
}