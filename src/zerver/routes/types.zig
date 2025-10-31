// src/zerver/routes/types.zig
/// Pure routing types - NO dependencies on core/types.zig or ctx.zig
/// Used by Router and AtomicRouter for path matching and HTTP semantics
/// Does NOT contain business logic types (Step, Decision, etc.)

/// HTTP method enum - matches RFC 9110 Section 9
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,
};

/// HTTP header name-value pair
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};
