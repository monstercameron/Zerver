/// Todo feature error handler
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    slog.debug("Error handler called", &.{
        slog.Attr.string("handler", "onError"),
        slog.Attr.string("feature", "todos"),
    });
    if (ctx.last_error) |err| {
        slog.err("Processing error", &.{
            slog.Attr.uint("error_kind", err.kind),
            slog.Attr.string("error_what", err.ctx.what),
            slog.Attr.string("error_key", err.ctx.key),
            slog.Attr.string("feature", "todos"),
        });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_user")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing X-User-ID header\"}" },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing todo ID\"}" },
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Unknown error\"}" },
            });
        }
    } else {
        slog.err("Error handler called but no error details available", &.{
            slog.Attr.string("feature", "todos"),
        });
        return zerver.done(.{
            .status = 500,
            .body = .{ .complete = "{\"error\":\"Internal server error - no error details\"}" },
        });
    }
}
