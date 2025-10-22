/// Core helpers: step trampoline, effect constructors, decision utilities.

const std = @import("std");
const types = @import("types.zig");
const ctx_module = @import("ctx.zig");

/// Wrap a typed step function into a Step struct.
/// This allows the framework to call typed step functions through a generic interface.
pub fn step(comptime name: []const u8, comptime F: anytype) types.Step {
    // TODO: extract reads/writes from F's CtxView spec
    return types.Step{
        .name = name,
        .call = &trampolineWrapper(F),
        .reads = &.{},
        .writes = &.{},
    };
}

/// Create a wrapper function that adapts from *CtxBase to the typed view expected by F.
fn trampolineWrapper(comptime _F: anytype) *const fn (*anyopaque) anyerror!types.Decision {
    _ = _F;  // Used at comptime for type extraction
    return struct {
        pub fn wrapper(base: *anyopaque) anyerror!types.Decision {
            const ctx_base: *ctx_module.CtxBase = @ptrCast(@alignCast(base));
            // TODO: reconstruct the appropriate CtxView from _F's signature and call _F
            _ = ctx_base;
            return error.NotImplemented;
        }
    }.wrapper;
}

/// Helper to create a Decision.Continue.
pub fn continue_() types.Decision {
    return .Continue;
}

/// Helper to create a Decision.Done.
pub fn done(resp: types.Response) types.Decision {
    return .{ .Done = resp };
}

/// Helper to create a Decision.Fail.
pub fn fail(kind: u16, what: []const u8, key: []const u8) types.Decision {
    return .{ .Fail = .{
        .kind = kind,
        .ctx = .{ .what = what, .key = key },
    } };
}

/// Common HTTP error codes (for convenience).
pub const ErrorCode = struct {
    pub const InvalidInput = 400;
    pub const Unauthorized = 401;
    pub const Forbidden = 403;
    pub const NotFound = 404;
    pub const Conflict = 409;
    pub const TooManyRequests = 429;
    pub const UpstreamUnavailable = 502;
    pub const Timeout = 504;
    pub const InternalError = 500;
};
