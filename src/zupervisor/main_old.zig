// src/zupervisor/main.zig
/// Zupervisor: Supervisor with Hot Reload (Zig Supervisor)
/// Receives requests from Zingest via Unix sockets
/// Routes to feature DLLs with zero-downtime hot reload
/// Provides crash isolation - feature crashes don't bring down ingress

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const ipc_server = @import("ipc_server.zig");
const ipc_types = zerver.ipc_types;
const AtomicRouter = zerver.AtomicRouter; // Use pre-instantiated type from root.zig
const RouterLifecycle = zerver.RouterLifecycle; // Use pre-instantiated type from root.zig
const VersionManager = zerver.dll_version.VersionManager;
const FileWatcher = zerver.file_watcher.FileWatcher;
const DLL = zerver.dll_loader.DLL;
const types = zerver.types; // RouteSpec for route handlers
const route_types = zerver.routes.types; // Lightweight routing types (Method)
const pipeline_executor = @import("pipeline_executor.zig");
const RuntimeResources = zerver.RuntimeResources;
const runtime_config = zerver.runtime_config;

const DEFAULT_IPC_SOCKET = "/tmp/zerver.sock";
const DEFAULT_FEATURE_DIR = "./src/plugins";
const DEFAULT_WATCH_INTERVAL_MS = 1000;

/// C-compatible handler function type - what DLLs export
const DLLHandlerFn = *const fn (
    request: *anyopaque,
    response: *anyopaque,
) callconv(.c) c_int;

/// Response builder - collects response data from DLL handlers
const ResponseBuilder = struct {
    allocator: std.mem.Allocator,
    status: c_int = 200,
    headers: std.ArrayList(Header),
    body: ?[]u8 = null,

    const Header = struct {
        name: []u8,
        value: []u8,
    };

    fn init(allocator: std.mem.Allocator) ResponseBuilder {
        return .{
            .allocator = allocator,
            .headers = std.ArrayList(Header).init(allocator),
        };
    }

    fn deinit(self: *ResponseBuilder) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit();
        if (self.body) |b| self.allocator.free(b);
    }
};

/// ServerAdapter wraps an AtomicRouter to provide a Server-like interface for DLL feature initialization
/// Uses C-compatible types for stable ABI across DLL boundaries
const ServerAdapter = extern struct {
    atomic_router: *anyopaque,
    addRouteFn: *const fn (
        router: *anyopaque,
        method: c_int,
        path_ptr: [*c]const u8,
        path_len: usize,
        handler: DLLHandlerFn,
    ) callconv(.c) c_int,
    runtime_resources: *anyopaque,
    setStatusFn: *const fn (*anyopaque, c_int) callconv(.c) void,
    setHeaderFn: *const fn (*anyopaque, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) c_int,
    setBodyFn: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) c_int,
};

/// Global context for request handling
const RequestContext = struct {
    allocator: std.mem.Allocator,
    atomic_router: *AtomicRouter,
    version_manager: *VersionManager,
    runtime_resources: *RuntimeResources,
};

var g_context: ?*RequestContext = null;

/// C-callable response builder functions (called by DLL handlers)

fn responseSetStatus(
    response_opaque: *anyopaque,
    status: c_int,
) callconv(.c) void {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));
    response.status = status;
}

fn responseSetHeader(
    response_opaque: *anyopaque,
    name_ptr: [*c]const u8,
    name_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));

    const name = response.allocator.dupe(u8, name_ptr[0..name_len]) catch return 1;
    const value = response.allocator.dupe(u8, value_ptr[0..value_len]) catch {
        response.allocator.free(name);
        return 1;
    };

    const header = ResponseBuilder.Header{ .name = name, .value = value };
    response.headers.append(response.allocator, header) catch {
        response.allocator.free(name);
        response.allocator.free(value);
        return 1;
    };

    return 0; // Success
}

fn responseSetBody(
    response_opaque: *anyopaque,
    body_ptr: [*c]const u8,
    body_len: usize,
) callconv(.c) c_int {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));

    // Free previous body if exists
    if (response.body) |old_body| {
        response.allocator.free(old_body);
    }

    response.body = response.allocator.dupe(u8, body_ptr[0..body_len]) catch return 1;
    return 0; // Success
}

/// Wrapper function for AtomicRouter.addRoute with C-compatible signature
/// Accepts DLLHandlerFn, creates bridge, and registers route
fn atomicRouterAddRoute(
    router_opaque: *anyopaque,
    method_int: c_int,
    path_ptr: [*c]const u8,
    path_len: usize,
    handler_fn: DLLHandlerFn,
) callconv(.c) c_int {
    _ = router_opaque;
    _ = handler_fn;

    // Convert c_int to Method enum
    const method: route_types.Method = @enumFromInt(method_int);

    // Convert C pointer+length to Zig slice
    const path: []const u8 = path_ptr[0..path_len];

    // TODO: Implement full bridge between DLL handler and internal pipeline
    // For now, just log that the route was registered
    slog.info("Route registered (bridge not yet implemented)", &.{
        slog.Attr.string("path", path),
        slog.Attr.string("method", @tagName(method)),
    });

    return 0; // Success
}

/// Load all feature DLLs from the plugin directory and register their routes
fn loadFeatureDLLs(
    allocator: std.mem.Allocator,
    feature_dir: []const u8,
    atomic_router: *AtomicRouter,
    runtime_resources: *RuntimeResources,
) !void {
    // Determine DLL extension based on platform
    const dll_ext = if (@import("builtin").os.tag == .macos) ".dylib" else ".so";

    // Open the feature directory
    var dir = std.fs.openDirAbsolute(feature_dir, .{ .iterate = true }) catch |err| {
        slog.warn("Could not open feature directory", &.{
            slog.Attr.string("path", feature_dir),
            slog.Attr.string("error", @errorName(err)),
        });
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, dll_ext)) continue;

        // Construct full path
        const dll_path = try std.fs.path.join(allocator, &[_][]const u8{ feature_dir, entry.name });
        defer allocator.free(dll_path);

        slog.info("Loading feature DLL", &.{
            slog.Attr.string("path", dll_path),
        });

        // Load the DLL (this also looks up all function pointers)
        const dll = DLL.load(allocator, dll_path) catch |err| {
            slog.err("Failed to load DLL", &.{
                slog.Attr.string("path", dll_path),
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        // Create a ServerAdapter to allow DLL to register routes directly to atomic router
        var adapter = ServerAdapter{
            .atomic_router = @ptrCast(atomic_router),
            .addRouteFn = &atomicRouterAddRoute,
            .runtime_resources = @ptrCast(runtime_resources),
            .setStatusFn = &responseSetStatus,
            .setHeaderFn = &responseSetHeader,
            .setBodyFn = &responseSetBody,
        };

        // Call featureInit (already looked up by DLL.load)
        const init_result = dll.featureInit(@ptrCast(&adapter));
        if (init_result != 0) {
            slog.err("Feature initialization failed", &.{
                slog.Attr.string("path", dll_path),
                slog.Attr.int("result", init_result),
            });
            dll.release();
            continue;
        }

        // DLL stays loaded - routes are now registered in atomic router
        // Note: We don't call dll.release() so the DLL stays in memory
        const feature_name = std.fs.path.stem(entry.name);
        slog.info("Feature DLL loaded successfully", &.{
            slog.Attr.string("feature", feature_name),
            slog.Attr.string("path", dll_path),
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    const feature_dir = try getFeatureDir(allocator);
    defer allocator.free(feature_dir);

    slog.info("Zupervisor starting", &.{
        slog.Attr.string("ipc_socket", socket_path),
        slog.Attr.string("feature_dir", feature_dir),
    });

    // Initialize atomic router
    var atomic_router = try AtomicRouter.init(allocator);
    defer atomic_router.deinit();

    // Initialize router lifecycle manager
    var router_lifecycle = RouterLifecycle.init(allocator, &atomic_router);
    defer router_lifecycle.deinit();

    // Initialize version manager
    var version_manager = VersionManager.init(allocator);
    defer version_manager.deinit();

    // Load runtime configuration
    const config_path = "config.json";
    slog.info("Loading runtime configuration", &.{
        slog.Attr.string("path", config_path),
    });
    const app_config = try runtime_config.load(allocator, config_path);

    // Initialize runtime resources with config
    var runtime_resources = try allocator.create(RuntimeResources);
    defer allocator.destroy(runtime_resources);
    try runtime_resources.init(allocator, app_config);
    defer runtime_resources.deinit();

    slog.info("Runtime resources initialized", &.{
        slog.Attr.string("database", app_config.database.path),
        slog.Attr.int("pool_size", @intCast(app_config.database.pool_size)),
        slog.Attr.bool("reactor_enabled", app_config.reactor.enabled),
    });

    // Set global runtime resources so DLL features can access it
    zerver.runtime_global.set(runtime_resources);

    // Load feature DLLs from the plugin directory
    try loadFeatureDLLs(allocator, feature_dir, &atomic_router, runtime_resources);

    // Set up global context for request handling
    var context = RequestContext{
        .allocator = allocator,
        .atomic_router = &atomic_router,
        .version_manager = &version_manager,
        .runtime_resources = runtime_resources,
    };
    g_context = &context;
    defer g_context = null;

    // Initialize IPC server
    var server = try ipc_server.IPCServer.init(allocator, socket_path, &handleIPCRequest);
    defer server.deinit();

    try server.start();

    // Initialize file watcher for hot reload
    var file_watcher = try FileWatcher.init(allocator, feature_dir);
    defer file_watcher.deinit();

    slog.info("Zupervisor initialized", &.{
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
    const start_time: i64 = @intCast(std.time.nanoTimestamp());

    const context = g_context orelse return error.ContextNotInitialized;

    slog.debug("Handling IPC request", &.{
        slog.Attr.int("request_id", @intCast(request.request_id)),
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
        // No route found - return 404 using same pattern as success responses
        const body = try allocator.dupe(u8, "{\"error\":\"Not Found\"}");
        const headers = try allocator.alloc(ipc_types.Header, 1);
        headers[0] = .{
            .name = try allocator.dupe(u8, "Content-Type"),
            .value = try allocator.dupe(u8, "application/json"),
        };
        const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));
        return .{
            .request_id = request.request_id,
            .status = 404,
            .headers = headers,
            .body = body,
            .processing_time_us = duration_us,
        };
    }

    // Route found - execute the pipeline
    slog.debug("Executing pipeline", &.{
        slog.Attr.int("request_id", @intCast(request.request_id)),
        slog.Attr.string("path", request.path),
        slog.Attr.int("step_count", @intCast(route_match.?.handler.steps.len)),
    });

    return try pipeline_executor.executePipeline(allocator, request, &route_match.?, context.runtime_resources);
}

/// Hot reload loop - watches for DLL changes and reloads
fn hotReloadLoop(
    allocator: std.mem.Allocator,
    file_watcher: *FileWatcher,
    feature_dir: []const u8,
    version_manager: *VersionManager,
    router_lifecycle: *RouterLifecycle,
) !void {
    _ = allocator;
    _ = feature_dir;
    _ = version_manager;

    slog.info("Hot reload loop started", &.{});

    while (true) {
        std.Thread.sleep(DEFAULT_WATCH_INTERVAL_MS * std.time.ns_per_ms);

        // Check for file changes
        const event_opt = file_watcher.poll() catch |err| {
            slog.err("File watcher poll failed", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        const event = event_opt orelse continue;

        slog.info("File change detected", &.{
            slog.Attr.string("path", event),
        });

        // Check if it's a DLL file
        if (!std.mem.endsWith(u8, event, ".so")) continue;

        // TODO: Implement hot reload
        // This would:
        // 1. Call version_manager.loadNewVersion(event)
        // 2. Build new router with new DLL routes
        // 3. Atomically swap router using router_lifecycle.beginReload()
        // 4. Clean up old version with router_lifecycle.completeReload()

        _ = router_lifecycle;

        slog.info("Hot reload detected (not yet implemented)", &.{
            slog.Attr.string("path", event),
        });
    }
}

fn convertMethod(ipc_method: ipc_types.HttpMethod) route_types.Method {
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

fn getSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ZERVER_IPC_SOCKET")) |path| {
        return try allocator.dupe(u8, path);
    }
    return try allocator.dupe(u8, DEFAULT_IPC_SOCKET);
}

fn getFeatureDir(allocator: std.mem.Allocator) ![]const u8 {
    const relative_dir = if (std.posix.getenv("ZERVER_FEATURE_DIR")) |path|
        try allocator.dupe(u8, path)
    else
        try allocator.dupe(u8, DEFAULT_FEATURE_DIR);
    defer allocator.free(relative_dir);

    // Convert to absolute path
    return try std.fs.cwd().realpathAlloc(allocator, relative_dir);
}
