/// Todo feature middleware
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");

// Global middleware
pub fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Logging middleware called", &.{
        slog.Attr.string("middleware", "logging"),
        slog.Attr.string("feature", "todos"),
    });
    _ = ctx;
    slog.info("Request received", &.{
        slog.Attr.string("middleware", "logging"),
        slog.Attr.string("feature", "todos"),
    });
    return zerver.continue_();
}
