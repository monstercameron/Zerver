const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");

pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    std.debug.print("  [Blog Error] onError called\n", .{});
    if (ctx.last_error) |err| {
        std.debug.print("  [Blog Error] Last error: kind={}, what='{s}', key='{s}'\n", .{ err.kind, err.ctx.what, err.ctx.key });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Missing ID\"}",
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Not Found\"}",
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_post_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Missing Post ID\"}",
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_comment_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Missing Comment ID\"}",
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = "{\"error\":\"Unknown blog error\"}",
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        }
    } else {
        std.debug.print("  [Blog Error] No last_error set\n", .{});
        return zerver.done(.{
            .status = 500,
            .body = "{\"error\":\"Internal server error - no error details\"}",
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }
}
