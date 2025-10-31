// src/features/blog/errors.zig
const std = @import("std");
const zerver = @import("zerver/root.zig");
const slog = @import("zerver/observability/slog.zig");
const http_status = zerver.HttpStatus;

pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    slog.warn("blog error handler invoked", &.{});
    if (ctx.last_error) |err| {
        slog.warn("blog error details", &.{
            slog.Attr.int("kind", @intCast(err.kind)),
            slog.Attr.string("what", err.ctx.what),
            slog.Attr.string("key", err.ctx.key),
        });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing ID\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Not Found\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_post_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing Post ID\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_comment_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing Comment ID\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Unknown blog error\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        }
    } else {
        slog.err("blog error with no details", &.{});
        return zerver.done(.{
            .status = http_status.internal_server_error,
            .body = .{ .complete = "{\"error\":\"Internal server error - no error details\"}" },
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }
}
