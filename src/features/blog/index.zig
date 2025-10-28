// src/features/blog/index.zig
/// Blog Feature - Public API
///
/// This is the main entry point for the blog feature. It exports everything
/// that other parts of the application need to interact with this feature.
///
/// Feature Structure Pattern:
/// - index.zig      - Public API (this file)
/// - routes.zig     - Route registration
/// - types.zig      - Public data types
/// - steps.zig      - Step function implementations
/// - effects.zig    - Effect handlers
/// - schema.zig     - Database schema
/// - errors.zig     - Feature-specific errors
/// - page.zig       - Page rendering
/// - list.zig       - List rendering
/// - util.zig       - Utilities
/// - logging.zig    - Feature-specific logging

const std = @import("std");

// Re-export public modules
pub const routes = @import("routes.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const effects = @import("effects.zig");
pub const schema = @import("schema.zig");
pub const util = @import("util.zig");
pub const logging = @import("logging.zig");

// Re-export commonly used functions
pub const registerRoutes = routes.registerRoutes;
pub const effectHandler = effects.effectHandler;
pub const ensureSchema = schema.ensureSchema;
pub const onError = errors.onError;

// Re-export commonly used types
pub const BlogPost = types.BlogPost;
pub const Comment = types.Comment;

/// Feature metadata
pub const Feature = struct {
    pub const name = "blog";
    pub const version = "1.0.0";
    pub const description = "Blog feature with htmx SSR and JSON API";

    /// Base path for all blog routes
    pub const base_path = "/blogs";

    /// API base path
    pub const api_base_path = "/blogs/api";

    /// Feature capabilities
    pub const capabilities = struct {
        pub const has_api = true;
        pub const has_htmx = true;
        pub const has_websocket = false;
        pub const requires_auth = false;
        pub const requires_database = true;
    };

    /// Initialize the feature
    /// This should be called during application startup
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !void {
        _ = allocator;
        try ensureSchema(db_path);
    }

    /// Cleanup the feature
    /// This should be called during application shutdown
    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No cleanup needed for now
    }
};

/// Get feature information as a string
pub fn getInfo(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\Feature: {s}
        \\Version: {s}
        \\Description: {s}
        \\Base Path: {s}
        \\API Path: {s}
        \\Has API: {any}
        \\Has HTMX: {any}
        \\Requires DB: {any}
    , .{
        Feature.name,
        Feature.version,
        Feature.description,
        Feature.base_path,
        Feature.api_base_path,
        Feature.capabilities.has_api,
        Feature.capabilities.has_htmx,
        Feature.capabilities.requires_database,
    });
}

test "feature metadata" {
    const testing = std.testing;
    try testing.expectEqualStrings("blog", Feature.name);
    try testing.expectEqualStrings("/blogs", Feature.base_path);
    try testing.expect(Feature.capabilities.has_api);
    try testing.expect(Feature.capabilities.has_htmx);
    try testing.expect(Feature.capabilities.requires_database);
}
