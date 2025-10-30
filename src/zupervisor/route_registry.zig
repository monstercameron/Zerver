// src/zupervisor/route_registry.zig
/// Unified route registry supporting both step-based and slot-effect pipelines
/// Manages route registration, dispatch, and lifecycle

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const step_pipeline = @import("step_pipeline.zig");
const slot_effect_dll = @import("slot_effect_dll.zig");

/// HTTP method enumeration
pub const HttpMethod = enum(c_int) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
};

/// Route handler types
pub const RouteHandler = union(enum) {
    /// Legacy step-based handler
    step_pipeline: struct {
        handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    },

    /// New slot-effect handler
    slot_effect: struct {
        handler: slot_effect_dll.SlotEffectHandlerFn,
    },
};

/// Route metadata
pub const Route = struct {
    method: HttpMethod,
    path: []const u8,
    handler: RouteHandler,
    metadata: ?RouteMetadata,

    pub const RouteMetadata = struct {
        description: []const u8,
        max_body_size: usize = 1024 * 1024, // 1MB default
        timeout_ms: u32 = 30_000, // 30s default
        requires_auth: bool = false,
    };
};

/// Route registry that manages all registered routes
pub const RouteRegistry = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) RouteRegistry {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(Route){},
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RouteRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.routes.items) |route| {
            self.allocator.free(route.path);
            if (route.metadata) |meta| {
                self.allocator.free(meta.description);
            }
        }
        self.routes.deinit(self.allocator);
    }

    /// Register a step-based route
    pub fn registerStepRoute(
        self: *RouteRegistry,
        method: HttpMethod,
        path: []const u8,
        handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = path_copy,
            .handler = .{ .step_pipeline = .{ .handler = handler } },
            .metadata = null,
        });
    }

    /// Register a slot-effect route
    pub fn registerSlotEffectRoute(
        self: *RouteRegistry,
        method: HttpMethod,
        path: []const u8,
        handler: slot_effect_dll.SlotEffectHandlerFn,
        metadata: ?Route.RouteMetadata,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        var metadata_copy: ?Route.RouteMetadata = null;
        if (metadata) |meta| {
            const desc_copy = try self.allocator.dupe(u8, meta.description);
            errdefer self.allocator.free(desc_copy);

            metadata_copy = .{
                .description = desc_copy,
                .max_body_size = meta.max_body_size,
                .timeout_ms = meta.timeout_ms,
                .requires_auth = meta.requires_auth,
            };
        }

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = path_copy,
            .handler = .{ .slot_effect = .{ .handler = handler } },
            .metadata = metadata_copy,
        });
    }

    /// Register routes from a DLL's exported route table
    pub fn registerDllRoutes(
        self: *RouteRegistry,
        routes: []const slot_effect_dll.SlotEffectRoute,
    ) !void {
        for (routes) |route| {
            const path = route.path[0..route.path_len];
            const method: HttpMethod = @enumFromInt(route.method);

            var metadata: ?Route.RouteMetadata = null;
            if (route.metadata) |meta| {
                const desc = meta.description[0..meta.description_len];
                metadata = .{
                    .description = desc,
                    .max_body_size = meta.max_body_size,
                    .timeout_ms = meta.timeout_ms,
                    .requires_auth = meta.requires_auth,
                };
            }

            try self.registerSlotEffectRoute(method, path, route.handler, metadata);
        }
    }

    /// Path parameter storage
    pub const PathParams = struct {
        names: []const []const u8,
        values: []const []const u8,

        pub fn get(self: *const PathParams, name: []const u8) ?[]const u8 {
            for (self.names, 0..) |param_name, i| {
                if (std.mem.eql(u8, param_name, name)) {
                    return self.values[i];
                }
            }
            return null;
        }
    };

    /// Route match result with extracted path parameters
    pub const RouteMatch = struct {
        route: *const Route,
        params: PathParams,
    };

    /// Find a matching route for the given method and path
    pub fn findRoute(self: *RouteRegistry, method: HttpMethod, path: []const u8) ?*const Route {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.routes.items) |*route| {
            if (route.method == method and std.mem.eql(u8, route.path, path)) {
                return route;
            }
        }

        return null;
    }

    /// Find a matching route with path parameters
    pub fn findRouteWithParams(
        self: *RouteRegistry,
        allocator: std.mem.Allocator,
        method: HttpMethod,
        path: []const u8,
    ) !?RouteMatch {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.routes.items) |*route| {
            if (route.method != method) continue;

            // Try exact match first (faster)
            if (std.mem.eql(u8, route.path, path)) {
                return RouteMatch{
                    .route = route,
                    .params = .{ .names = &.{}, .values = &.{} },
                };
            }

            // Try pattern match with parameters
            if (try matchPathPattern(allocator, route.path, path)) |params| {
                return RouteMatch{
                    .route = route,
                    .params = params,
                };
            }
        }

        return null;
    }

    /// Match a path pattern against an actual path and extract parameters
    /// Pattern: "/blogs/{id}" matches "/blogs/123" and extracts id=123
    fn matchPathPattern(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        path: []const u8,
    ) !?PathParams {
        var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
        var path_parts = std.mem.splitScalar(u8, path, '/');

        var param_names = std.ArrayList([]const u8){};
        defer param_names.deinit(allocator);
        var param_values = std.ArrayList([]const u8){};
        defer param_values.deinit(allocator);

        while (pattern_parts.next()) |pattern_part| {
            const path_part = path_parts.next() orelse return null;

            if (pattern_part.len > 2 and pattern_part[0] == '{' and pattern_part[pattern_part.len - 1] == '}') {
                // This is a parameter
                const param_name = pattern_part[1 .. pattern_part.len - 1];
                try param_names.append(allocator, try allocator.dupe(u8, param_name));
                try param_values.append(allocator, try allocator.dupe(u8, path_part));
            } else {
                // This must be an exact match
                if (!std.mem.eql(u8, pattern_part, path_part)) {
                    // Free allocated memory before returning
                    for (param_names.items) |name| allocator.free(name);
                    for (param_values.items) |value| allocator.free(value);
                    return null;
                }
            }
        }

        // Check that both iterators are exhausted (same number of parts)
        if (path_parts.next() != null) {
            for (param_names.items) |name| allocator.free(name);
            for (param_values.items) |value| allocator.free(value);
            return null;
        }

        return PathParams{
            .names = try param_names.toOwnedSlice(allocator),
            .values = try param_values.toOwnedSlice(allocator),
        };
    }

    /// Get all routes (for debugging/monitoring)
    pub fn getAllRoutes(self: *RouteRegistry, allocator: std.mem.Allocator) ![]const Route {
        self.mutex.lock();
        defer self.mutex.unlock();

        return try allocator.dupe(Route, self.routes.items);
    }

    /// Get route count
    pub fn count(self: *RouteRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.routes.items.len;
    }
};

/// Request dispatcher that invokes the appropriate handler
pub const Dispatcher = struct {
    registry: *RouteRegistry,
    bridge: *slot_effect_dll.SlotEffectBridge,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *RouteRegistry,
        bridge: *slot_effect_dll.SlotEffectBridge,
    ) Dispatcher {
        return .{
            .allocator = allocator,
            .registry = registry,
            .bridge = bridge,
        };
    }

    /// Dispatch a request to the appropriate handler
    pub fn dispatch(
        self: *Dispatcher,
        method: HttpMethod,
        path: []const u8,
        request: *anyopaque,
        response: *anyopaque,
    ) !c_int {
        const route = self.registry.findRoute(method, path) orelse {
            return error.RouteNotFound;
        };


        return switch (route.handler) {
            .step_pipeline => |h| h.handler(request, response),
            .slot_effect => |h| blk: {
                const adapter = self.bridge.buildAdapter(self.registry);
                break :blk h.handler(&adapter, request, response);
            },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RouteRegistry - lifecycle" {
    const testing = std.testing;

    var registry = RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expect(registry.count() == 0);
}

test "RouteRegistry - step route registration" {
    const testing = std.testing;

    var registry = RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    const Handler = struct {
        fn handle(_: *anyopaque, _: *anyopaque) callconv(.c) c_int {
            return 0;
        }
    };

    try registry.registerStepRoute(.GET, "/api/test", Handler.handle);
    try testing.expect(registry.count() == 1);

    const route = registry.findRoute(.GET, "/api/test");
    try testing.expect(route != null);
    try testing.expect(route.?.method == .GET);
    try testing.expect(std.mem.eql(u8, route.?.path, "/api/test"));
}

test "RouteRegistry - slot-effect route registration" {
    const testing = std.testing;

    var registry = RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    const Handler = struct {
        fn handle(_: *const slot_effect_dll.SlotEffectServerAdapter, _: *anyopaque, _: *anyopaque) callconv(.c) c_int {
            return 0;
        }
    };

    const metadata = Route.RouteMetadata{
        .description = "Test endpoint",
        .max_body_size = 2048,
        .timeout_ms = 5000,
        .requires_auth = true,
    };

    try registry.registerSlotEffectRoute(.POST, "/api/slot-test", Handler.handle, metadata);
    try testing.expect(registry.count() == 1);

    const route = registry.findRoute(.POST, "/api/slot-test");
    try testing.expect(route != null);
    try testing.expect(route.?.metadata != null);
    try testing.expect(route.?.metadata.?.requires_auth == true);
}

test "RouteRegistry - route lookup" {
    const testing = std.testing;

    var registry = RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    const Handler = struct {
        fn handle(_: *anyopaque, _: *anyopaque) callconv(.c) c_int {
            return 0;
        }
    };

    try registry.registerStepRoute(.GET, "/api/users", Handler.handle);
    try registry.registerStepRoute(.POST, "/api/users", Handler.handle);

    const get_route = registry.findRoute(.GET, "/api/users");
    try testing.expect(get_route != null);

    const post_route = registry.findRoute(.POST, "/api/users");
    try testing.expect(post_route != null);

    const missing_route = registry.findRoute(.DELETE, "/api/users");
    try testing.expect(missing_route == null);
}

test "Dispatcher - initialization" {
    const testing = std.testing;

    var registry = RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator);
    defer bridge.deinit();

    const dispatcher = Dispatcher.init(testing.allocator, &registry, &bridge);
    _ = dispatcher;
}
