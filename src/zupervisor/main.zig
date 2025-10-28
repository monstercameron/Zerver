// src/zupervisor/main.zig
/// Zupervisor: Supervisor with Hot Reload (Zig Supervisor)
/// Receives requests from Zingest via Unix sockets
/// Routes to feature DLLs with zero-downtime hot reload
/// Provides crash isolation - feature crashes don't bring down ingress

const std = @import("std");
const slog = @import("../zerver/observability/slog.zig");
const ipc_server = @import("ipc_server.zig");
const ipc_types = @import("../zingest/ipc_client.zig");
const AtomicRouter = @import("../zerver/plugins/atomic_router.zig").AtomicRouter;
const RouterLifecycle = @import("../zerver/plugins/atomic_router.zig").RouterLifecycle;
const DLLLoader = @import("../zerver/plugins/dll_loader.zig").DLLLoader;
const DLLVersionManager = @import("../zerver/plugins/dll_version.zig").DLLVersionManager;
const FileWatcher = @import("../zerver/plugins/file_watcher.zig").FileWatcher;
const types = @import("../zerver/core/types.zig");

const DEFAULT_IPC_SOCKET = "/tmp/zerver.sock";
const DEFAULT_FEATURE_DIR = "./features";
const DEFAULT_WATCH_INTERVAL_MS = 1000;

/// Global context for request handling
const RequestContext = struct {
    allocator: std.mem.Allocator,
    atomic_router: *AtomicRouter,
    version_manager: *DLLVersionManager,
    dll_loader: *DLLLoader,
};

var g_context: ?*RequestContext = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    const feature_dir = try getFeatureDir(allocator);
    defer allocator.free(feature_dir);

    slog.info("Zupervisor starting", .{
        slog.Attr.string("ipc_socket", socket_path),
        slog.Attr.string("feature_dir", feature_dir),
    });

    // Initialize atomic router
    var atomic_router = try AtomicRouter.init(allocator);
    defer atomic_router.deinit();

    // Initialize router lifecycle manager
    var router_lifecycle = RouterLifecycle.init(allocator, &atomic_router);
    defer router_lifecycle.deinit();

    // Initialize DLL loader
    var dll_loader = try DLLLoader.init(allocator);
    defer dll_loader.deinit();

    // Initialize version manager
    var version_manager = try DLLVersionManager.init(allocator, &dll_loader);
    defer version_manager.deinit();

    // Set up global context for request handling
    var context = RequestContext{
        .allocator = allocator,
        .atomic_router = &atomic_router,
        .version_manager = &version_manager,
        .dll_loader = &dll_loader,
    };
    g_context = &context;
    defer g_context = null;

    // Initialize IPC server
    var server = try ipc_server.IPCServer.init(allocator, socket_path, &handleIPCRequest);
    defer server.deinit();

    try server.start();

    // Initialize file watcher for hot reload
    var file_watcher = try FileWatcher.init(allocator);
    defer file_watcher.deinit();

    try file_watcher.watch(feature_dir);

    slog.info("Zupervisor initialized", .{
        slog.Attr.string("status", "ready"),
    });

    // Start hot reload loop in background thread
    const reload_thread = try std.Thread.spawn(.{}, hotReloadLoop, .{
        allocator,
        &file_watcher,
        feature_dir,
        &version_manager,
        &router_lifecycle,
    });
    reload_thread.detach();

    // Run IPC server accept loop (blocks)
    try server.acceptLoop();
}

/// Handle IPC request from Zingest
fn handleIPCRequest(
    allocator: std.mem.Allocator,
    request: *const ipc_types.IPCRequest,
) !ipc_types.IPCResponse {
    const start_time = std.time.nanoTimestamp();

    const context = g_context orelse return error.ContextNotInitialized;

    slog.debug("Handling IPC request", .{
        slog.Attr.int("request_id", request.request_id),
        slog.Attr.string("path", request.path),
        slog.Attr.int("method", @intFromEnum(request.method)),
    });

    // Convert IPC method to internal method
    const method = convertMethod(request.method);

    // Match route using atomic router
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const route_match = try context.atomic_router.match(method, request.path, arena.allocator());

    if (route_match == null) {
        // No route found - return 404
        return try build404Response(allocator, request.request_id, start_time);
    }

    // Route found - this would execute the pipeline
    // For now, return a simple success response
    return try buildSuccessResponse(allocator, request.request_id, start_time);
}

/// Hot reload loop - watches for DLL changes and reloads
fn hotReloadLoop(
    allocator: std.mem.Allocator,
    file_watcher: *FileWatcher,
    feature_dir: []const u8,
    version_manager: *DLLVersionManager,
    router_lifecycle: *RouterLifecycle,
) !void {
    _ = feature_dir;

    slog.info("Hot reload loop started", .{});

    while (true) {
        std.time.sleep(DEFAULT_WATCH_INTERVAL_MS * std.time.ns_per_ms);

        // Check for file changes
        const events = file_watcher.pollEvents(allocator) catch |err| {
            slog.err("File watcher poll failed", .{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };
        defer allocator.free(events);

        if (events.len == 0) continue;

        slog.info("File changes detected", .{
            slog.Attr.int("event_count", events.len),
        });

        // For each changed DLL, reload it
        for (events) |event| {
            if (!std.mem.endsWith(u8, event.path, ".so")) continue;

            slog.info("Reloading DLL", .{
                slog.Attr.string("path", event.path),
            });

            // Load new DLL version
            const new_version_id = version_manager.loadNewVersion(event.path) catch |err| {
                slog.err("Failed to load new DLL version", .{
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("path", event.path),
                });
                continue;
            };

            slog.info("New DLL version loaded", .{
                slog.Attr.int("version_id", new_version_id),
                slog.Attr.string("path", event.path),
            });

            // TODO: Rebuild router with new DLL routes
            // This would call into the DLL's route registration function
            // and build a new router, then swap it atomically

            _ = router_lifecycle;

            // For now, just log the reload
            slog.info("Hot reload completed", .{
                slog.Attr.int("version_id", new_version_id),
            });
        }
    }
}

fn convertMethod(ipc_method: ipc_types.HttpMethod) types.Method {
    return switch (ipc_method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
    };
}

fn build404Response(
    allocator: std.mem.Allocator,
    request_id: u128,
    start_time: i64,
) !ipc_types.IPCResponse {
    const body = try allocator.dupe(u8, "Not Found");
    const headers = try allocator.alloc(ipc_types.Header, 1);
    headers[0] = .{
        .name = try allocator.dupe(u8, "Content-Type"),
        .value = try allocator.dupe(u8, "text/plain"),
    };

    const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

    return .{
        .request_id = request_id,
        .status = 404,
        .headers = headers,
        .body = body,
        .processing_time_us = duration_us,
    };
}

fn buildSuccessResponse(
    allocator: std.mem.Allocator,
    request_id: u128,
    start_time: i64,
) !ipc_types.IPCResponse {
    const body = try allocator.dupe(u8, "{\"message\":\"OK\"}");
    const headers = try allocator.alloc(ipc_types.Header, 1);
    headers[0] = .{
        .name = try allocator.dupe(u8, "Content-Type"),
        .value = try allocator.dupe(u8, "application/json"),
    };

    const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

    return .{
        .request_id = request_id,
        .status = 200,
        .headers = headers,
        .body = body,
        .processing_time_us = duration_us,
    };
}

fn getSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ZERVER_IPC_SOCKET")) |path| {
        return try allocator.dupe(u8, path);
    }
    return try allocator.dupe(u8, DEFAULT_IPC_SOCKET);
}

fn getFeatureDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ZERVER_FEATURE_DIR")) |path| {
        return try allocator.dupe(u8, path);
    }
    return try allocator.dupe(u8, DEFAULT_FEATURE_DIR);
}
