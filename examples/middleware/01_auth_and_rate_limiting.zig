// examples/middleware/01_auth_and_rate_limiting.zig
/// Middleware examples: auth, rate limiting, and other cross-cutting concerns
///
/// Middleware in Zerver are just Steps that run before main business logic.
/// They can read/write slots and return Continue to proceed or Fail to short-circuit.
const std = @import("std");
const zerver = @import("../src/zerver/root.zig");

/// Example Slot enum for middleware examples
pub const Slot = enum {
    UserId,
    AuthToken,
    RateLimit,
    RequestCount,
};

pub fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .UserId => []const u8,
        .AuthToken => []const u8,
        .RateLimit => RateLimitData,
        .RequestCount => u32,
    };
}

/// Rate limit data structure
pub const RateLimitData = struct {
    requests_per_min: u32,
    current_window_count: u32,
    window_start_ms: i64,
};

/// ============================================================================
/// AUTH MIDDLEWARE
/// ============================================================================
/// Middleware step that parses an Authorization header
/// Reads: nothing
/// Writes: AuthToken
pub fn auth_parse(ctx: *zerver.CtxBase) !zerver.Decision {
    // Extract Authorization header
    const auth_header = ctx.header("Authorization") orelse {
        return zerver.fail(
            zerver.ErrorCode.Unauthorized,
            "auth",
            "missing_header",
        );
    };

    // Simple token extraction (strip "Bearer " prefix)
    const token = if (std.mem.startsWith(u8, auth_header, "Bearer "))
        auth_header[7..]
    else
        return zerver.fail(
            zerver.ErrorCode.Unauthorized,
            "auth",
            "invalid_format",
        );

    // Store token in slot
    try ctx._put(0, token); // 0 = AuthToken slot id
    return zerver.continue_();
}

/// Middleware step that verifies a token and extracts the user ID
/// Reads: AuthToken
/// Writes: UserId
pub fn auth_verify(ctx: *zerver.CtxBase) !zerver.Decision {
    // Retrieve token from slot
    const token_opt = try ctx._get(0, []const u8); // 0 = AuthToken slot id
    const token = token_opt orelse {
        return zerver.fail(
            zerver.ErrorCode.Unauthorized,
            "auth",
            "no_token",
        );
    };

    // In a real app, this would call a database or auth service
    // For this example, we'll do a simple validation
    if (token.len < 10) {
        return zerver.fail(
            zerver.ErrorCode.Unauthorized,
            "auth",
            "invalid_token",
        );
    }

    // Mock: extract user ID from token (token format: "user_<id>_<timestamp>")
    var parts = std.mem.splitSequence(u8, token, "_");
    _ = parts.next(); // skip "user"
    const user_id = parts.next() orelse {
        return zerver.fail(
            zerver.ErrorCode.Unauthorized,
            "auth",
            "malformed_token",
        );
    };

    // Store user ID in slot
    try ctx._put(1, user_id); // 1 = UserId slot id
    return zerver.continue_();
}

/// Example auth chain - middleware runs in sequence
pub const auth_chain = &.{
    zerver.step("auth_parse", auth_parse),
    zerver.step("auth_verify", auth_verify),
};

/// ============================================================================
/// RATE LIMITING MIDDLEWARE
/// ============================================================================
/// Middleware step that checks rate limits
/// Reads: nothing
/// Writes: RateLimit
pub fn rate_limit_check(ctx: *zerver.CtxBase) !zerver.Decision {
    // Get client IP for rate limiting key
    const client_ip = ctx.clientIpText();
    _ = client_ip; // Would use this as the rate limit key

    const now = std.time.milliTimestamp();

    // Simple rate limit: 60 requests per minute
    const limit_data: RateLimitData = .{
        .requests_per_min = 60,
        .current_window_count = 0,
        .window_start_ms = now,
    };

    // In real implementation:
    // - Check Redis or in-memory cache for this IP
    // - Increment counter
    // - Check if over limit
    // - Return 429 if exceeded

    try ctx._put(2, limit_data); // 2 = RateLimit slot id
    return zerver.continue_();
}

/// ============================================================================
/// OPTIONAL MIDDLEWARE
/// ============================================================================
/// Optional auth middleware - doesn't fail if missing, just sets UserId to empty
/// Useful for endpoints that support both authenticated and anonymous users
pub fn optional_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth_header = ctx.header("Authorization");

    if (auth_header) |header| {
        if (std.mem.startsWith(u8, header, "Bearer ")) {
            const token = header[7..];
            if (token.len >= 10) {
                // Valid token - extract user
                var parts = std.mem.splitSequence(u8, token, "_");
                _ = parts.next();
                if (parts.next()) |user_id| {
                    try ctx._put(1, user_id); // 1 = UserId slot id
                    return zerver.continue_();
                }
            }
        }
    }

    // No valid auth - set to anonymous
    try ctx._put(1, "anonymous"); // 1 = UserId slot id
    return zerver.continue_();
}

/// ============================================================================
/// EXAMPLE USAGE
/// ============================================================================
/// Example showing how to use middleware with routes
pub fn example_protected_route(ctx: *zerver.CtxBase) !zerver.Decision {
    // Retrieve UserId from slot
    const user_id_opt = try ctx._get(1, []const u8); // 1 = UserId slot id
    const user_id = user_id_opt orelse "anonymous";

    const response_body = std.fmt.allocPrint(
        ctx.allocator,
        "Protected resource for user: {s}",
        .{user_id},
    ) catch return zerver.fail(
        zerver.ErrorCode.InternalError,
        "memory",
        "allocation_failed",
    );

    return zerver.done(zerver.Response{
        .status = 200,
        .body = response_body,
    });
}

// USAGE EXAMPLE:
// To use in a server:
// var server = try zerver.Server.init(allocator, config, effectHandler);
//
// // Global auth middleware
// try server.use(auth_chain);
//
// // Protected route with rate limiting
// try server.addRoute(.GET, "/protected", .{
//     .before = &.{ zerver.step("rate_limit", rate_limit_check) },
//     .steps = &.{ zerver.step("get_protected", example_protected_route) },
// });
//
// // Optional auth - open endpoint with optional user
// try server.addRoute(.GET, "/public", .{
//     .before = &.{ zerver.step("optional_auth", optional_auth) },
//     .steps = &.{ /* business logic */ },
// });
