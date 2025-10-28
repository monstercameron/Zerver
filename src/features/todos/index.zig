// src/features/todos/index.zig
/// Todo Feature - Public API
const std = @import("std");

// Re-export public modules
pub const routes = @import("routes.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const effects = @import("effects.zig");
pub const middleware = @import("middleware.zig");
pub const steps = @import("steps.zig");

// Re-export commonly used functions
pub const registerRoutes = routes.registerRoutes;
pub const effectHandler = effects.effectHandler;
pub const onError = errors.onError;

// Re-export commonly used types
pub const TodoSlot = types.TodoSlot;
pub const TodoSlotType = types.TodoSlotType;

/// Feature metadata
pub const Feature = struct {
    pub const name = "todos";
    pub const version = "1.0.0";
    pub const description = "Todo feature with JSON API demonstrating effects and continuations";
    pub const base_path = "/todos";
    pub const api_base_path = "/todos";

    pub const capabilities = struct {
        pub const has_api = true;
        pub const has_htmx = false;
        pub const has_websocket = false;
        pub const requires_auth = false;
        pub const requires_database = true;
    };

    pub fn init(allocator: std.mem.Allocator) !void {
        _ = allocator;
        // No schema initialization needed for todos (mock database)
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
    }
};

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
