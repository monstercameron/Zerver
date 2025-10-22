/// Todo feature middleware
const std = @import("std");
const zerver = @import("../../zerver/root.zig");

// Global middleware
pub fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Middleware] Logging middleware called\n", .{});
    _ = ctx;
    std.debug.print("→ Request received\n", .{});
    return zerver.continue_();
}
