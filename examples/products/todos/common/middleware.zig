// examples/products/todos/common/middleware.zig
/// Todos Product: Shared Middleware
///
/// Cross-cutting concerns:
/// - Authentication and authorization
/// - Rate limiting
/// - Request/response logging
/// - Operation latency simulation
const std = @import("std");
const zerver = @import("zerver");
const domain = @import("../core/domain.zig");
const slog = @import("src/zerver/observability/slog.zig");

// Slot IDs for request context storage (typed state)
pub const Slot = enum(u32) {
    user_id = 1,
    auth_token = 2,
    rate_limit_key = 3,
    operation_latency = 4,
    todo_id = 5,
    request_id = 6,
};

/// Middleware: Authenticate request with bearer token
pub fn mw_authenticate(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth_header = ctx.header("authorization") orelse {
        slog.warnf("[auth] ✗ Missing authorization header", .{});
        return zerver.fail(domain.makeError(
            .Unauthorized,
            "Missing authorization header",
            "auth",
        ));
    };

    // Validate bearer token format
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        slog.warnf("[auth] ✗ Invalid token format", .{});
        return zerver.fail(domain.makeError(
            .Unauthorized,
            "Invalid token format",
            "auth",
        ));
    }

    const token = auth_header[7..]; // Skip "Bearer " prefix

    // Simulate token validation latency
    const latency_config = domain.OperationLatency{ .min_ms = 10, .max_ms = 50 };
    const latency = latency_config.random();
    slog.infof("[auth] Validating token... ({d}ms)", .{latency});
    std.time.sleep(latency * 1_000_000);

    // Store token for downstream use
    try ctx.slotPutString(@intFromEnum(Slot.auth_token), token);

    // Extract user ID from token (simplified: use first 10 chars)
    const user_id = token[0..std.math.min(token.len, 10)];
    try ctx.slotPutString(@intFromEnum(Slot.user_id), user_id);

    slog.infof("[auth] ✓ User {s} authenticated", .{user_id});
    return .Continue;
}

/// Middleware: Apply rate limiting
pub fn mw_rate_limit(ctx: *zerver.CtxBase) !zerver.Decision {
    const user_id = ctx.slotGetString(@intFromEnum(Slot.user_id)) orelse "anonymous";

    // Store rate limit key for later checks
    try ctx.slotPutString(@intFromEnum(Slot.rate_limit_key), user_id);

    // BTS: In real implementation, check Redis counter
    // For MVP, accept all requests
    slog.infof("[rate_limit] ✓ {s} - OK", .{user_id});
    return .Continue;
}

/// Middleware: Simulate operation latency baseline
pub fn mw_operation_latency(ctx: *zerver.CtxBase) !zerver.Decision {
    // Set a baseline latency for all DB operations in this request
    const latency = domain.OperationLatency.read().random();

    var latency_buf: [10]u8 = undefined;
    const latency_str = std.fmt.bufPrint(&latency_buf, "{d}", .{latency}) catch unreachable;
    try ctx.slotPutString(@intFromEnum(Slot.operation_latency), latency_str);

    slog.infof("[latency] Baseline: {d}ms", .{latency});
    return .Continue;
}

/// Middleware: Request logging
pub fn mw_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.infof("\n[request] → {s} {s}", .{ ctx.method(), ctx.path() });
    return .Continue;
}

/// Utility: Get operation latency from context or use default
pub fn getOperationLatency(ctx: *zerver.CtxBase) u32 {
    const latency_str = ctx.slotGetString(@intFromEnum(Slot.operation_latency)) orelse "50";
    return std.fmt.parseInt(u32, latency_str, 10) catch 50;
}
