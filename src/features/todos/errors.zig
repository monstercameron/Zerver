/// Todo feature error handler
const std = @import("std");
const zerver = @import("../../zerver/root.zig");

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    std.debug.print("  [Error] onError called\n", .{});
    if (ctx.last_error) |err| {
        std.debug.print("  [Error] Last error: kind={}, what='{s}', key='{s}'\n", .{err.kind, err.ctx.what, err.ctx.key});

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_user")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Missing X-User-ID header\"}",
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Missing todo ID\"}",
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Unknown error\"}",
            });
        }
    } else {
        std.debug.print("  [Error] No last_error set\n", .{});
        return zerver.done(.{
            .status = 500,
            .body = "{\"error\":\"Internal server error - no error details\"}",
        });
    }
}