/// Common types and utilities for multi-team todo system
const std = @import("std");

/// Team identifiers for organizational separation
pub const Team = enum {
    Frontend,
    Backend,
    Platform,
};

/// Domain model: Todo item with team ownership
pub const TodoRecord = struct {
    id: []const u8,
    title: []const u8,
    done: bool = false,
    team: Team,
    created_by: []const u8,
};

/// Auth model: JWT-like claims
pub const AuthClaims = struct {
    user_id: []const u8,
    team: Team,
    roles: []const []const u8,
};

/// Error model: context-aware error codes
pub const ErrorKind = enum {
    InvalidInput,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    TooManyRequests,
    UpstreamUnavailable,
    Timeout,
    Internal,
};

/// Create error with context
pub fn makeError(kind: ErrorKind, what: []const u8, key: []const u8) std.builtin.ErrorSetDeferred {
    return .{
        .kind = @intFromEnum(kind),
        .ctx = .{ .what = what, .key = key },
    };
}

/// Simulated latency in milliseconds
pub const SimulatedLatency = struct {
    min_ms: u32,
    max_ms: u32,
};

/// Generate random latency in milliseconds within range [min_ms, max_ms]
/// This simulates variable network/database performance
pub fn simulateRandomLatency(min_ms: u32, max_ms: u32) u32 {
    var prng = std.Random.DefaultPrng.init(std.time.timestamp());
    const random = prng.random();
    const range = max_ms - min_ms;
    const offset = random.intRangeLessThan(u32, 0, range);
    return min_ms + offset;
}
