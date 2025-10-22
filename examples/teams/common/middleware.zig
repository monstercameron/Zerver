/// Shared middleware for all teams: authentication, rate limiting, logging
const std = @import("std");
const zerver = @import("zerver");
const common = @import("../common/types.zig");

/// Middleware: Parse authorization header and validate token
/// BTS: In Phase 2, this would be an async HTTP call to identity provider
/// For MVP, simulate token parsing with random latency
pub fn mw_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth_header = ctx.header("authorization") orelse {
        std.debug.print("[mw_auth] Missing authorization header\n", .{});
        return zerver.fail(common.makeError(.Unauthorized, "auth", "missing_header"));
    };

    // Simulate token validation with latency
    const latency_ms = common.simulateRandomLatency(50, 150);
    std.debug.print("[mw_auth] Simulating token validation ({d}ms)...\n", .{latency_ms});
    std.time.sleep(latency_ms * 1_000_000); // Convert ms to nanoseconds

    // Validate token format (simplified)
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        return zerver.fail(common.makeError(.Unauthorized, "auth", "invalid_format"));
    }

    const token = auth_header[7..]; // Skip "Bearer " prefix
    try ctx.slotPutString(1, token); // Slot 1: AuthToken

    std.debug.print("[mw_auth] Token validated: {s}\n", .{token[0..std.math.min(token.len, 10)]});
    return .Continue;
}

/// Middleware: Extract user ID and verify team access
pub fn mw_verify_claims(ctx: *zerver.CtxBase) !zerver.Decision {
    // BTS: In real scenario, decode JWT and verify signature
    // For MVP, extract user ID from token
    const token = ctx.slotGetString(1) orelse {
        return zerver.fail(common.makeError(.Unauthorized, "auth", "no_token"));
    };

    const user_id = token[0..std.math.min(token.len, 20)];
    try ctx.slotPutString(2, user_id); // Slot 2: UserId

    std.debug.print("[mw_verify_claims] User: {s}\n", .{user_id});
    return .Continue;
}

/// Middleware: Rate limiting based on user or IP
pub fn mw_rate_limit(ctx: *zerver.CtxBase) !zerver.Decision {
    // Extract rate limit key (use user ID if available, otherwise IP)
    const rate_key = blk: {
        if (ctx.slotGetString(2)) |user_id| {
            break :blk user_id;
        } else {
            break :blk ctx.clientIpText();
        }
    };

    try ctx.slotPutString(3, rate_key); // Slot 3: RateLimitKey

    // BTS: In real scenario, check Redis counter
    // For MVP, accept all (could add random rejection for testing)
    std.debug.print("[mw_rate_limit] Rate key: {s} - OK\n", .{rate_key});
    return .Continue;
}

/// Middleware: Simulate and store effect latency for this request
pub fn mw_effect_latency(ctx: *zerver.CtxBase) !zerver.Decision {
    // Each request gets a random baseline latency (50-300ms range)
    // This simulates varying database/network conditions
    const latency = common.simulateRandomLatency(50, 300);

    var latency_buf: [10]u8 = undefined;
    const latency_str = std.fmt.bufPrint(&latency_buf, "{d}", .{latency}) catch unreachable;
    try ctx.slotPutString(4, latency_str); // Slot 4: EffectLatency

    std.debug.print("[mw_effect_latency] Baseline: {d}ms\n", .{latency});
    return .Continue;
}

/// Middleware: Extract team from path (e.g., /teams/frontend/todos/:id)
pub fn mw_extract_team(ctx: *zerver.CtxBase) !zerver.Decision {
    const path = ctx.path();

    // Parse team from path: /teams/<team_name>/...
    if (std.mem.startsWith(u8, path, "/teams/")) {
        const remainder = path[7..];
        if (std.mem.indexOf(u8, remainder, "/")) |slash_idx| {
            const team_str = remainder[0..slash_idx];
            const team = std.meta.stringToEnum(common.Team, team_str) orelse {
                return zerver.fail(common.makeError(.InvalidInput, "team", team_str));
            };

            // Store team in context
            try ctx.slotPutString(5, @tagName(team)); // Slot 5: TeamId
            std.debug.print("[mw_extract_team] Team: {s}\n", .{@tagName(team)});
            return .Continue;
        }
    }

    return zerver.fail(common.makeError(.InvalidInput, "path", "missing /teams/<team>"));
}

/// Middleware: Request logging
pub fn mw_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("[mw_logging] → {s} {s}\n", .{ ctx.method(), ctx.path() });
    return .Continue;
}
