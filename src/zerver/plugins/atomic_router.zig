// src/zerver/plugins/atomic_router.zig
/// Atomic router swap for zero-downtime hot reload
/// Provides lock-free reads with atomic pointer swap

const std = @import("std");
const slog = @import("../observability/slog.zig");
const Router = @import("../routes/router.zig").Router;
const RouteMatch = @import("../routes/router.zig").RouteMatch;
const types = @import("../core/types.zig");

/// Atomic router wrapper with copy-on-write semantics
pub const AtomicRouter = struct {
    allocator: std.mem.Allocator,
    current: std.atomic.Value(?*Router),
    mutex: std.Thread.Mutex, // Only for swaps, not reads

    pub fn init(allocator: std.mem.Allocator) !AtomicRouter {
        const router = try allocator.create(Router);
        router.* = try Router.init(allocator);

        return .{
            .allocator = allocator,
            .current = std.atomic.Value(?*Router).init(router),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *AtomicRouter) void {
        if (self.current.load(.acquire)) |router| {
            router.deinit();
            self.allocator.destroy(router);
        }
    }

    /// Get the current router for read-only operations (lock-free)
    /// IMPORTANT: Do not hold onto this pointer across atomic swaps!
    /// Only safe for immediate use within a single request context.
    fn getCurrent(self: *const AtomicRouter) *Router {
        const router = self.current.load(.acquire) orelse unreachable;
        return router;
    }

    /// Add a route to the current router (requires lock)
    pub fn addRoute(
        self: *AtomicRouter,
        method: types.Method,
        path: []const u8,
        spec: types.RouteSpec,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const router = self.getCurrent();
        try router.addRoute(method, path, spec);
    }

    /// Match a request against current routes (lock-free read)
    pub fn match(
        self: *const AtomicRouter,
        method: types.Method,
        path: []const u8,
        arena: std.mem.Allocator,
    ) !?RouteMatch {
        const router = self.getCurrent();
        return try router.match(method, path, arena);
    }

    /// Get allowed methods for a path (lock-free read)
    pub fn getAllowedMethods(
        self: *const AtomicRouter,
        path: []const u8,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        const router = self.getCurrent();
        return try router.getAllowedMethods(path, arena);
    }

    /// Clone the current router for building a new route table
    pub fn clone(self: *AtomicRouter) !*Router {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_router = self.getCurrent();
        const new_router = try self.allocator.create(Router);
        errdefer self.allocator.destroy(new_router);

        new_router.* = try Router.init(self.allocator);
        errdefer new_router.deinit();

        // Copy all routes from old router to new router
        for (old_router.routes.items) |route| {
            try new_router.addRoute(route.method, try self.reconstructPath(route), route.spec);
        }

        return new_router;
    }

    /// Atomically swap in a new router
    /// The old router is returned for cleanup after draining
    pub fn swap(self: *AtomicRouter, new_router: *Router) *Router {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_router = self.current.swap(new_router, .acq_rel) orelse unreachable;

        slog.info("Router swapped", .{
            slog.Attr.int("old_routes", old_router.routes.items.len),
            slog.Attr.int("new_routes", new_router.routes.items.len),
        });

        return old_router;
    }

    /// Replace all routes with a new set (convenience method)
    /// Returns old router for cleanup after draining
    pub fn replaceRoutes(self: *AtomicRouter) !*Router {
        const new_router = try self.allocator.create(Router);
        new_router.* = try Router.init(self.allocator);

        return self.swap(new_router);
    }

    /// Build a new router from scratch and swap it in
    /// Used during DLL reload - returns old router for draining
    pub fn rebuild(
        self: *AtomicRouter,
        comptime buildFn: fn (router: *Router) anyerror!void,
    ) !*Router {
        const new_router = try self.allocator.create(Router);
        errdefer self.allocator.destroy(new_router);

        new_router.* = try Router.init(self.allocator);
        errdefer new_router.deinit();

        // Build routes using provided function
        try buildFn(new_router);

        // Atomic swap
        return self.swap(new_router);
    }

    /// Reconstruct path string from compiled route (for cloning)
    fn reconstructPath(self: *AtomicRouter, route: @import("../routes/router.zig").CompiledRoute) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        for (route.pattern.segments) |segment| {
            try buf.append('/');
            switch (segment) {
                .literal => |lit| try buf.appendSlice(lit),
                .param => |name| {
                    try buf.append(':');
                    try buf.appendSlice(name);
                },
                .wildcard => |name| {
                    try buf.append('*');
                    try buf.appendSlice(name);
                },
            }
        }

        return try buf.toOwnedSlice();
    }

    /// Get current route count (for monitoring)
    pub fn getRouteCount(self: *const AtomicRouter) usize {
        const router = self.getCurrent();
        return router.routes.items.len;
    }
};

/// Router lifecycle manager for hot reload
/// Coordinates router swaps with DLL version lifecycle
pub const RouterLifecycle = struct {
    allocator: std.mem.Allocator,
    atomic_router: *AtomicRouter,
    draining_router: ?*Router,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, atomic_router: *AtomicRouter) RouterLifecycle {
        return .{
            .allocator = allocator,
            .atomic_router = atomic_router,
            .draining_router = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RouterLifecycle) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.draining_router) |router| {
            router.deinit();
            self.allocator.destroy(router);
            self.draining_router = null;
        }
    }

    /// Begin hot reload: swap in new router, return old for draining
    pub fn beginReload(self: *RouterLifecycle, new_router: *Router) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up any previous draining router
        if (self.draining_router) |old_draining| {
            slog.warn("Replacing still-draining router", .{
                slog.Attr.int("routes", old_draining.routes.items.len),
            });
            old_draining.deinit();
            self.allocator.destroy(old_draining);
        }

        // Swap and save old router for draining
        self.draining_router = self.atomic_router.swap(new_router);

        slog.info("Hot reload began", .{
            slog.Attr.int("active_routes", new_router.routes.items.len),
            slog.Attr.int("draining_routes", self.draining_router.?.routes.items.len),
        });
    }

    /// Complete hot reload: cleanup draining router once version is retired
    pub fn completeReload(self: *RouterLifecycle) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.draining_router) |router| {
            router.deinit();
            self.allocator.destroy(router);
            self.draining_router = null;

            slog.info("Hot reload completed", .{});
        }
    }

    /// Check if a reload is in progress
    pub fn isReloadInProgress(self: *RouterLifecycle) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.draining_router != null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AtomicRouter - basic init and deinit" {
    const testing = std.testing;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    try testing.expect(atomic.getRouteCount() == 0);
}

test "AtomicRouter - add route and match" {
    const testing = std.testing;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    const spec = types.RouteSpec{ .steps = &.{} };
    try atomic.addRoute(.GET, "/test", spec);

    try testing.expect(atomic.getRouteCount() == 1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const match = try atomic.match(.GET, "/test", arena.allocator());
    try testing.expect(match != null);
}

test "AtomicRouter - swap operation" {
    const testing = std.testing;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    // Add route to initial router
    const spec1 = types.RouteSpec{ .steps = &.{} };
    try atomic.addRoute(.GET, "/old", spec1);
    try testing.expect(atomic.getRouteCount() == 1);

    // Create new router with different route
    var new_router = try testing.allocator.create(Router);
    new_router.* = try Router.init(testing.allocator);
    const spec2 = types.RouteSpec{ .steps = &.{} };
    try new_router.addRoute(.GET, "/new", spec2);

    // Swap
    const old_router = atomic.swap(new_router);
    defer {
        old_router.deinit();
        testing.allocator.destroy(old_router);
    }

    // New router should be active
    try testing.expect(atomic.getRouteCount() == 1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const match_new = try atomic.match(.GET, "/new", arena.allocator());
    try testing.expect(match_new != null);
}

test "RouterLifecycle - reload flow" {
    const testing = std.testing;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    var lifecycle = RouterLifecycle.init(testing.allocator, &atomic);
    defer lifecycle.deinit();

    try testing.expect(!lifecycle.isReloadInProgress());

    // Create new router for reload
    var new_router = try testing.allocator.create(Router);
    new_router.* = try Router.init(testing.allocator);

    try lifecycle.beginReload(new_router);
    try testing.expect(lifecycle.isReloadInProgress());

    lifecycle.completeReload();
    try testing.expect(!lifecycle.isReloadInProgress());
}
