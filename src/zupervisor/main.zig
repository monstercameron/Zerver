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
const AtomicRouter = zerver.AtomicRouter;
const RouterLifecycle = zerver.RouterLifecycle;
const DLL = zerver.dll_loader.DLL;
const VersionManager = zerver.dll_version.VersionManager;
const FileWatcher = zerver.file_watcher.FileWatcher;
const types = zerver.types;

const DEFAULT_IPC_SOCKET = "/tmp/zerver.sock";
const DEFAULT_FEATURE_DIR = "zig-out/lib"; // Watch compiled DLLs, not source
const DEFAULT_WATCH_INTERVAL_MS = 1000;

/// Global context for request handling
/// Route key for DLL handler lookup (using string for simpler HashMap usage)
const RouteKey = struct {
    // Format: "METHOD:path" e.g. "GET:/test"
    key: []const u8,

    fn make(allocator: std.mem.Allocator, method: types.Method, path: []const u8) !RouteKey {
        const method_str = @tagName(method);
        const key_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ method_str, path });
        return .{ .key = key_str };
    }

    fn deinit(self: RouteKey, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// DLL route handler
const DLLHandler = struct {
    func: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    dll_version: *DLL,
};

/// Simple DLL router (replaces RouteSpec-based router for DLL handlers)
const DLLRouter = struct {
    allocator: std.mem.Allocator,
    routes: std.StringHashMap(DLLHandler),

    fn init(allocator: std.mem.Allocator) !DLLRouter {
        return .{
            .allocator = allocator,
            .routes = std.StringHashMap(DLLHandler).init(allocator),
        };
    }

    fn deinit(self: *DLLRouter) void {
        var iter = self.routes.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.routes.deinit();
    }

    fn addRoute(self: *DLLRouter, method: types.Method, path: []const u8, handler: DLLHandler) !void {
        const key = try RouteKey.make(self.allocator, method, path);
        errdefer key.deinit(self.allocator);

        try self.routes.put(key.key, handler);
    }

    fn match(self: *const DLLRouter, method: types.Method, path: []const u8) ?DLLHandler {
        // Create temporary key for lookup (no allocation needed)
        const method_str = @tagName(method);
        var buf: [256]u8 = undefined;
        const key_str = std.fmt.bufPrint(&buf, "{s}:{s}", .{ method_str, path }) catch return null;
        return self.routes.get(key_str);
    }
};

const RequestContext = struct {
    allocator: std.mem.Allocator,
    atomic_router: *AtomicRouter,
    version_manager: *VersionManager,
    dll_router: DLLRouter,
    dll_router_mutex: std.Thread.Mutex,
};

var g_context: ?*RequestContext = null;

/// ServerAdapter for DLL route registration
const ServerAdapter = extern struct {
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: *const fn (
        router: *anyopaque,
        method: c_int,
        path_ptr: [*c]const u8,
        path_len: usize,
        handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    ) callconv(.c) c_int,
    setStatus: *const fn (*anyopaque, c_int) callconv(.c) void,
    setHeader: *const fn (*anyopaque, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) c_int,
    setBody: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) c_int,
};

/// Temporary router builder for DLL initialization
const RouterBuilder = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),
    reg_ctx: *RouteRegistrationContext,

    const Route = struct {
        method: types.Method,
        path: []const u8,
        handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    };

    fn init(allocator: std.mem.Allocator, reg_ctx: *RouteRegistrationContext) !RouterBuilder {
        return .{
            .allocator = allocator,
            .routes = try std.ArrayList(Route).initCapacity(allocator, 8),
            .reg_ctx = reg_ctx,
        };
    }

    fn deinit(self: *RouterBuilder) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.path);
        }
        self.routes.deinit(self.allocator);
    }
};

/// Callback for DLL to register routes
fn dllAddRoute(
    router: *anyopaque,
    method: c_int,
    path_ptr: [*c]const u8,
    path_len: usize,
    handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
) callconv(.c) c_int {
    const builder = @as(*RouterBuilder, @ptrCast(@alignCast(router)));

    const path_slice = path_ptr[0..path_len];
    const path_copy = builder.allocator.dupe(u8, path_slice) catch return 1;

    const method_enum: types.Method = @enumFromInt(method);

    // Add to temporary route list for tracking
    builder.routes.append(builder.allocator, .{
        .method = method_enum,
        .path = path_copy,
        .handler = handler,
    }) catch {
        builder.allocator.free(path_copy);
        return 1;
    };

    // Add to DLL router
    const reg_ctx = builder.reg_ctx;
    reg_ctx.dll_router_mutex.lock();
    defer reg_ctx.dll_router_mutex.unlock();

    const dll_handler = DLLHandler{
        .func = handler,
        .dll_version = reg_ctx.dll,
    };

    reg_ctx.dll_router.addRoute(method_enum, path_slice, dll_handler) catch {
        return 1;
    };

    slog.info("Route registered", &.{
        slog.Attr.int("method", method),
        slog.Attr.string("path", path_slice),
    });

    return 0;
}

/// Stub callbacks for response building (not used during init)
fn dllSetStatus(_: *anyopaque, _: c_int) callconv(.c) void {}
fn dllSetHeader(_: *anyopaque, _: [*c]const u8, _: usize, _: [*c]const u8, _: usize) callconv(.c) c_int { return 0; }
fn dllSetBody(_: *anyopaque, _: [*c]const u8, _: usize) callconv(.c) c_int { return 0; }

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    const feature_dir_relative = try getFeatureDir(allocator);
    defer allocator.free(feature_dir_relative);

    // Convert to absolute path for FileWatcher
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const feature_dir = try std.fs.path.join(allocator, &.{ cwd, feature_dir_relative });
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

    // Note: We'll load DLLs on demand when discovered by FileWatcher
    // For now, initialize empty version manager
    var version_manager = VersionManager.init(allocator);
    defer version_manager.deinit();

    // Initialize DLL router
    var dll_router = try DLLRouter.init(allocator);
    defer dll_router.deinit();

    // Set up global context for request handling
    var context = RequestContext{
        .allocator = allocator,
        .atomic_router = &atomic_router,
        .version_manager = &version_manager,
        .dll_router = dll_router,
        .dll_router_mutex = .{},
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

    // Load initial DLLs from feature directory
    try loadInitialDLLs(allocator, feature_dir, &atomic_router, &version_manager, &context.dll_router, &context.dll_router_mutex);

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

/// Context for route registration (passed to RouterBuilder via adapter)
const RouteRegistrationContext = struct {
    dll: *DLL,
    dll_router: *DLLRouter,
    dll_router_mutex: *std.Thread.Mutex,
};

/// Load all DLLs from feature directory on startup
fn loadInitialDLLs(
    allocator: std.mem.Allocator,
    feature_dir: []const u8,
    atomic_router: *AtomicRouter,
    version_manager: *VersionManager,
    dll_router: *DLLRouter,
    dll_router_mutex: *std.Thread.Mutex,
) !void {
    _ = atomic_router;

    slog.info("Loading initial DLLs", &.{
        slog.Attr.string("directory", feature_dir),
    });

    var dir = try std.fs.openDirAbsolute(feature_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if it's a DLL file
        const is_dll = std.mem.endsWith(u8, entry.name, ".dylib") or
            std.mem.endsWith(u8, entry.name, ".so") or
            std.mem.endsWith(u8, entry.name, ".dll");

        if (!is_dll) continue;

        // Build full path
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ feature_dir, entry.name });

        slog.info("Loading DLL", &.{
            slog.Attr.string("file", entry.name),
            slog.Attr.string("path", full_path),
        });

        // Load the DLL
        const dll = DLL.load(allocator, full_path) catch |err| {
            slog.err("Failed to load DLL", &.{
                slog.Attr.string("file", entry.name),
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        // Set as initial version in version manager
        version_manager.setInitial(dll) catch |err| {
            slog.err("Failed to set initial DLL version", &.{
                slog.Attr.string("file", entry.name),
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        slog.info("DLL loaded successfully", &.{
            slog.Attr.string("file", entry.name),
            slog.Attr.string("version", dll.getVersion()),
        });

        // Create route registration context
        var reg_ctx = RouteRegistrationContext{
            .dll = dll,
            .dll_router = dll_router,
            .dll_router_mutex = dll_router_mutex,
        };

        // Create router builder for this DLL
        var router_builder = RouterBuilder.init(allocator, &reg_ctx) catch |err| {
            slog.err("Failed to create router builder", &.{
                slog.Attr.string("file", entry.name),
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };
        defer router_builder.deinit();

        // Create server adapter for DLL initialization
        var runtime_resources: u8 = 0; // Placeholder
        const adapter = ServerAdapter{
            .router = @ptrCast(&router_builder),
            .runtime_resources = @ptrCast(&runtime_resources),
            .addRoute = &dllAddRoute,
            .setStatus = &dllSetStatus,
            .setHeader = &dllSetHeader,
            .setBody = &dllSetBody,
        };

        // Call featureInit to register routes
        slog.info("Calling featureInit", &.{
            slog.Attr.string("dll", entry.name),
        });

        const init_result = dll.featureInit(@ptrCast(@constCast(&adapter)));
        if (init_result != 0) {
            slog.err("featureInit failed", &.{
                slog.Attr.string("dll", entry.name),
                slog.Attr.int("result", init_result),
            });
            continue;
        }

        slog.info("DLL initialized", &.{
            slog.Attr.string("dll", entry.name),
            slog.Attr.int("routes_registered", @intCast(router_builder.routes.items.len)),
        });

        // TODO: Build router with registered routes and swap atomically
        _ = atomic_router;
    }
}

/// Handle IPC request from Zingest
fn handleIPCRequest(
    allocator: std.mem.Allocator,
    request: *const ipc_types.IPCRequest,
) !ipc_types.IPCResponse {
    const start_time = std.time.nanoTimestamp();

    const context = g_context orelse return error.ContextNotInitialized;

    slog.debug("Handling IPC request", &.{
        slog.Attr.string("path", request.path),
        slog.Attr.int("method", @intFromEnum(request.method)),
    });

    // Convert IPC method to internal method
    const method = convertMethod(request.method);

    // Match route using DLL router
    context.dll_router_mutex.lock();
    const dll_handler = context.dll_router.match(method, request.path);
    context.dll_router_mutex.unlock();

    if (dll_handler == null) {
        // No route found - return 404
        return try build404Response(allocator, request.request_id, start_time);
    }

    // Route found - execute the DLL handler
    // TODO: Call the actual DLL handler function
    // For now, return a simple success response
    return try buildSuccessResponse(allocator, request.request_id, start_time);
}

/// Hot reload loop - watches for DLL changes and reloads
fn hotReloadLoop(
    allocator: std.mem.Allocator,
    file_watcher: *FileWatcher,
    feature_dir: []const u8,
    version_manager: *VersionManager,
    router_lifecycle: *RouterLifecycle,
) !void {
    slog.info("Hot reload loop started", &.{});

    while (true) {
        std.Thread.sleep(DEFAULT_WATCH_INTERVAL_MS * std.time.ns_per_ms);

        // Check for file changes
        const changed_file = file_watcher.poll() catch |err| {
            slog.err("File watcher poll failed", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        if (changed_file) |filename| {
            defer allocator.free(filename);

            slog.info("File change detected", &.{
                slog.Attr.string("file", filename),
            });

            // Build full path
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ feature_dir, filename }) catch {
                slog.err("Path too long", &.{
                    slog.Attr.string("file", filename),
                });
                continue;
            };

            // TODO: Implement full DLL hot reload
            // 1. Load new DLL using DLL.load()
            // 2. Create new DLLVersion using DLLVersion.init()
            // 3. Rebuild router with new DLL's routes
            // 4. Swap router atomically using router_lifecycle
            // 5. Drain old version and unload when safe

            _ = version_manager;
            _ = router_lifecycle;

            slog.info("Hot reload triggered (not yet implemented)", &.{
                slog.Attr.string("path", full_path),
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
    start_time: i128,
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
    start_time: i128,
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
