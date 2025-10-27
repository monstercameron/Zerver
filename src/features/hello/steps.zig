// src/features/hello/steps.zig
/// Hello feature step implementations
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const http_status = zerver.HttpStatus;

pub fn helloStep(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Hello step called", &.{
        slog.Attr.string("step", "hello"),
        slog.Attr.string("feature", "hello"),
    });
    _ = ctx;
    return zerver.done(.{
        .status = http_status.ok,
        .body = "Hello from Zerver! Try /todos endpoints with X-User-ID header.",
    });
}

