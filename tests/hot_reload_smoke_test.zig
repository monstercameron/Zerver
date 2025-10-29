// tests/hot_reload_smoke_test.zig
/// Smoke tests for hot reload infrastructure
/// Validates that all components are properly set up

const std = @import("std");
const testing = std.testing;

// Import hot reload components
const FileWatcher = @import("../src/zerver/plugins/file_watcher.zig").FileWatcher;
const DLLLoader = @import("../src/zerver/plugins/dll_loader.zig").DLLLoader;
const DLLVersionManager = @import("../src/zerver/plugins/dll_version.zig").DLLVersionManager;
const AtomicRouter = @import("../src/zerver/plugins/atomic_router.zig").AtomicRouter;
const RouterLifecycle = @import("../src/zerver/plugins/atomic_router.zig").RouterLifecycle;

test "FileWatcher - basic initialization" {
    var watcher = try FileWatcher.init(testing.allocator);
    defer watcher.deinit();

    // FileWatcher should initialize successfully
    try testing.expect(true);
}

test "DLLLoader - basic initialization" {
    var loader = try DLLLoader.init(testing.allocator);
    defer loader.deinit();

    // DLL loader should track loaded libraries
    try testing.expectEqual(@as(usize, 0), loader.loaded_libs.count());
}

test "DLLVersionManager - initialization and lifecycle" {
    var loader = try DLLLoader.init(testing.allocator);
    defer loader.deinit();

    var manager = try DLLVersionManager.init(testing.allocator, &loader);
    defer manager.deinit();

    // Should start with no active versions
    try testing.expect(manager.active_version == null);
    try testing.expect(manager.draining_version == null);
}

test "AtomicRouter - initialization and basic operations" {
    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    // Should start with empty route table
    try testing.expectEqual(@as(usize, 0), atomic.getRouteCount());
}

test "RouterLifecycle - reload flow" {
    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    var lifecycle = RouterLifecycle.init(testing.allocator, &atomic);
    defer lifecycle.deinit();

    // Should not be in reload state initially
    try testing.expect(!lifecycle.isReloadInProgress());
}

test "AtomicRouter - route addition and matching" {
    const types = @import("../src/zerver/core/types.zig");
    const Router = @import("../src/zerver/routes/router.zig").Router;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    // Add a test route
    const spec = types.RouteSpec{ .steps = &.{} };
    try atomic.addRoute(.GET, "/test", spec);

    try testing.expectEqual(@as(usize, 1), atomic.getRouteCount());

    // Test route matching
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const match = try atomic.match(.GET, "/test", arena.allocator());
    try testing.expect(match != null);
}

test "AtomicRouter - atomic swap operation" {
    const types = @import("../src/zerver/core/types.zig");
    const Router = @import("../src/zerver/routes/router.zig").Router;

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    // Add route to initial router
    const spec1 = types.RouteSpec{ .steps = &.{} };
    try atomic.addRoute(.GET, "/old", spec1);
    try testing.expectEqual(@as(usize, 1), atomic.getRouteCount());

    // Create new router with different route
    var new_router = try testing.allocator.create(Router);
    new_router.* = try Router.init(testing.allocator);
    const spec2 = types.RouteSpec{ .steps = &.{} };
    try new_router.addRoute(.GET, "/new", spec2);

    // Perform atomic swap
    const old_router = atomic.swap(new_router);
    defer {
        old_router.deinit();
        testing.allocator.destroy(old_router);
    }

    // New router should be active
    try testing.expectEqual(@as(usize, 1), atomic.getRouteCount());

    // Verify new route is matched
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const match_new = try atomic.match(.GET, "/new", arena.allocator());
    try testing.expect(match_new != null);

    const match_old = try atomic.match(.GET, "/old", arena.allocator());
    try testing.expect(match_old == null);
}

test "DLLVersionManager - version lifecycle" {
    var loader = try DLLLoader.init(testing.allocator);
    defer loader.deinit();

    var manager = try DLLVersionManager.init(testing.allocator, &loader);
    defer manager.deinit();

    // Test version state transitions
    try testing.expect(manager.active_version == null);
    try testing.expect(manager.draining_version == null);

    // Note: Actual DLL loading would require a real .so file
    // This test validates the state management structure
}

test "Multi-process architecture - component integration" {
    // Validate that all components can coexist
    var loader = try DLLLoader.init(testing.allocator);
    defer loader.deinit();

    var manager = try DLLVersionManager.init(testing.allocator, &loader);
    defer manager.deinit();

    var atomic = try AtomicRouter.init(testing.allocator);
    defer atomic.deinit();

    var lifecycle = RouterLifecycle.init(testing.allocator, &atomic);
    defer lifecycle.deinit();

    var watcher = try FileWatcher.init(testing.allocator);
    defer watcher.deinit();

    // All components initialized successfully
    try testing.expect(true);
}
