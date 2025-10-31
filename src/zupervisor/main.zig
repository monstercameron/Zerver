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

// Slot-effect pipeline system
const slot_effect = @import("slot_effect.zig");
const slot_effect_dll = @import("slot_effect_dll.zig");
const slot_effect_executor = @import("slot_effect_executor.zig");
const route_registry = @import("route_registry.zig");
const http_slot_adapter = @import("http_slot_adapter.zig");
const effect_executors = @import("effect_executors.zig");

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

/// Route entry for atomic route swapping
const RouteEntry = struct {
    method: types.Method,
    path: []const u8,
    handler: DLLHandler,
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

    /// Replace all routes atomically (for hot-reload)
    /// Clears existing routes and adds new ones from the provided list
    fn replaceAllRoutes(
        self: *DLLRouter,
        new_routes: []const RouteEntry,
    ) !void {
        // Clear old routes (freeing all keys)
        var iter = self.routes.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.routes.clearRetainingCapacity();

        // Add all new routes
        for (new_routes) |route| {
            try self.addRoute(route.method, route.path, route.handler);
        }
    }
};

const RequestContext = struct {
    allocator: std.mem.Allocator,
    atomic_router: *AtomicRouter,
    version_manager: *VersionManager,
    dll_router: DLLRouter,
    dll_router_mutex: std.Thread.Mutex,
    // Slot-effect pipeline system
    slot_effect_adapter: ?*http_slot_adapter.HttpSlotAdapter,
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

    /// Transfer routes from this builder to the DLLRouter atomically
    /// This is used after featureInit() completes to activate the new routes
    fn transferToRouter(self: *RouterBuilder, old_dll: ?*DLL) !void {
        // Build route list with DLL handlers
        const route_list = try self.allocator.alloc(RouteEntry, self.routes.items.len);
        defer self.allocator.free(route_list);

        for (self.routes.items, 0..) |route, i| {
            route_list[i] = .{
                .method = route.method,
                .path = route.path,
                .handler = .{
                    .func = route.handler,
                    .dll_version = self.reg_ctx.dll,
                },
            };
        }

        // Lock and replace routes atomically
        self.reg_ctx.dll_router_mutex.lock();
        defer self.reg_ctx.dll_router_mutex.unlock();

        try self.reg_ctx.dll_router.replaceAllRoutes(route_list);

        // Release old DLL if hot-reloading
        if (old_dll) |old| {
            old.release();
        }
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

    // Also register to slot-effect adapter if available
    if (reg_ctx.slot_effect_adapter) |adapter| {
        const http_method: route_registry.HttpMethod = @enumFromInt(method);
        adapter.registry.registerStepRoute(http_method, path_slice, handler) catch {
            return 1;
        };
    }

    slog.info("Route registered", &.{
        slog.Attr.int("method", method),
        slog.Attr.string("path", path_slice),
    });

    return 0;
}

/// Response header
const ResponseHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Response builder for DLL handlers
const ResponseBuilder = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: std.ArrayList(ResponseHeader),
    body: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) !ResponseBuilder {
        var builder: ResponseBuilder = undefined;
        builder.allocator = allocator;
        builder.status = 200;
        builder.headers = try std.ArrayList(ResponseHeader).initCapacity(allocator, 0);
        builder.body = try std.ArrayList(u8).initCapacity(allocator, 0);
        return builder;
    }

    fn deinit(self: *ResponseBuilder) void {
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }
};

/// Callbacks for DLL handlers to build responses
fn dllSetStatus(response: *anyopaque, status: c_int) callconv(.c) void {
    const builder = @as(*ResponseBuilder, @ptrCast(@alignCast(response)));
    builder.status = @intCast(status);
}

fn dllSetHeader(
    response: *anyopaque,
    name_ptr: [*c]const u8,
    name_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int {
    const builder = @as(*ResponseBuilder, @ptrCast(@alignCast(response)));

    const name_slice = name_ptr[0..name_len];
    const value_slice = value_ptr[0..value_len];

    const name_copy = builder.allocator.dupe(u8, name_slice) catch return 1;
    const value_copy = builder.allocator.dupe(u8, value_slice) catch {
        builder.allocator.free(name_copy);
        return 1;
    };

    builder.headers.append(builder.allocator, ResponseHeader{
        .name = name_copy,
        .value = value_copy,
    }) catch {
        builder.allocator.free(name_copy);
        builder.allocator.free(value_copy);
        return 1;
    };

    return 0;
}

fn dllSetBody(
    response: *anyopaque,
    body_ptr: [*c]const u8,
    body_len: usize,
) callconv(.c) c_int {
    const builder = @as(*ResponseBuilder, @ptrCast(@alignCast(response)));

    const body_slice = body_ptr[0..body_len];
    builder.body.appendSlice(builder.allocator, body_slice) catch return 1;

    return 0;
}

/// Global server adapter used by all DLL handlers
/// This stays alive for the lifetime of the program and holds stateless function pointers
var g_runtime_resources: u8 = 0; // Placeholder for runtime resources

var g_server_adapter = ServerAdapter{
    .router = @ptrCast(&g_runtime_resources), // Unused during request handling
    .runtime_resources = @ptrCast(&g_runtime_resources),
    .addRoute = &dllAddRoute,
    .setStatus = &dllSetStatus,
    .setHeader = &dllSetHeader,
    .setBody = &dllSetBody,
};

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

    // Initialize slot-effect pipeline system
    const db_path = "zerver.db"; // TODO: Make configurable via env var
    var slot_adapter = try allocator.create(http_slot_adapter.HttpSlotAdapter);
    defer allocator.destroy(slot_adapter);

    slot_adapter.* = try http_slot_adapter.HttpSlotAdapter.init(allocator, db_path);
    defer slot_adapter.deinit();

    slog.info("Slot-effect pipeline initialized", &.{
        slog.Attr.string("db_path", db_path),
    });

    // Set up global context for request handling
    var context = RequestContext{
        .allocator = allocator,
        .atomic_router = &atomic_router,
        .version_manager = &version_manager,
        .dll_router = dll_router,
        .dll_router_mutex = .{},
        .slot_effect_adapter = slot_adapter,
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
    try loadInitialDLLs(allocator, feature_dir, &atomic_router, &version_manager, &context.dll_router, &context.dll_router_mutex, slot_adapter);

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
    slot_effect_adapter: ?*http_slot_adapter.HttpSlotAdapter,
};

/// Load all DLLs from feature directory on startup
fn loadInitialDLLs(
    allocator: std.mem.Allocator,
    feature_dir: []const u8,
    atomic_router: *AtomicRouter,
    version_manager: *VersionManager,
    dll_router: *DLLRouter,
    dll_router_mutex: *std.Thread.Mutex,
    slot_effect_adapter: ?*http_slot_adapter.HttpSlotAdapter,
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
        // Note: Skip AlreadyInitialized error to support multiple DLLs
        version_manager.setInitial(dll) catch |err| {
            if (err != error.AlreadyInitialized) {
                slog.err("Failed to set initial DLL version", &.{
                    slog.Attr.string("file", entry.name),
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            }
            // AlreadyInitialized is OK - this is the second+ DLL being loaded
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
            .slot_effect_adapter = slot_effect_adapter,
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

        // Use global adapter for DLL initialization
        // Temporarily update the router pointer for this DLL's registration
        const original_router = g_server_adapter.router;
        g_server_adapter.router = @ptrCast(&router_builder);
        defer g_server_adapter.router = original_router;

        // Call featureInit to register routes
        slog.info("Calling featureInit", &.{
            slog.Attr.string("dll", entry.name),
        });

        const init_result = dll.featureInit(@ptrCast(@constCast(&g_server_adapter)));
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

        // Transfer routes from builder to active router
        router_builder.transferToRouter(null) catch |err| {
            slog.err("Failed to transfer routes to router", &.{
                slog.Attr.string("dll", entry.name),
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        slog.info("Routes activated", &.{
            slog.Attr.string("dll", entry.name),
        });

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

    // Try slot-effect adapter first if available
    if (context.slot_effect_adapter) |adapter| {
        // Convert IPC request to HttpRequest format
        const headers = try allocator.alloc(http_slot_adapter.HttpRequest.Header, request.headers.len);
        defer allocator.free(headers);

        for (request.headers, 0..) |h, i| {
            headers[i] = .{ .name = h.name, .value = h.value };
        }

        const http_request = http_slot_adapter.HttpRequest{
            .method = @tagName(request.method),
            .path = request.path,
            .headers = headers,
            .body = request.body,
        };

        // Try to handle via slot-effect pipeline
        if (adapter.handleRequest(http_request)) |http_response| {
            // Convert HttpResponse to IPCResponse
            const ipc_headers = try allocator.alloc(ipc_types.Header, http_response.headers.len);
            for (http_response.headers, 0..) |h, i| {
                ipc_headers[i] = .{
                    .name = try allocator.dupe(u8, h.name),
                    .value = try allocator.dupe(u8, h.value),
                };
            }

            const body_copy = try allocator.dupe(u8, http_response.body);
            const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

            // Free the original HttpResponse (it allocated its own memory)
            allocator.free(http_response.headers);
            allocator.free(http_response.body);

            return .{
                .request_id = request.request_id,
                .status = http_response.status,
                .headers = ipc_headers,
                .body = body_copy,
                .processing_time_us = duration_us,
            };
        } else |err| {
            // If error is NotFound, fall through to legacy DLL router
            if (err != error.NotFound) {
                slog.err("Slot-effect handler error", &.{
                    slog.Attr.string("path", request.path),
                    slog.Attr.string("error", @errorName(err)),
                });
                return try build404Response(allocator, request.request_id, start_time);
            }
            // Fall through to legacy DLL router for NotFound
        }
    }

    // Fall back to legacy DLL router
    context.dll_router_mutex.lock();
    const dll_handler = context.dll_router.match(method, request.path);
    context.dll_router_mutex.unlock();

    if (dll_handler == null) {
        // No route found in either system - return 404
        return try build404Response(allocator, request.request_id, start_time);
    }

    // Route found - execute the DLL handler
    var response_builder = try ResponseBuilder.init(allocator);
    defer response_builder.deinit();

    // Create request context placeholder
    var request_context: u8 = 0; // TODO: Build real request context

    // Call the DLL handler with (request, response)
    // The handler will use g_server (stored during init) to call response-building callbacks
    const handler_result = dll_handler.?.func(@ptrCast(&request_context), @ptrCast(&response_builder));
    if (handler_result != 0) {
        slog.err("DLL handler failed", &.{
            slog.Attr.string("path", request.path),
            slog.Attr.int("result", handler_result),
        });
        return try build404Response(allocator, request.request_id, start_time);
    }

    // Build IPC response from collected data
    return try buildDLLResponse(allocator, request.request_id, start_time, &response_builder);
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

    // Get global context for DLL router access
    const context = g_context orelse return error.ContextNotInitialized;

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

            // Step 1: Load new DLL
            const dll = DLL.load(allocator, full_path) catch |err| {
                slog.err("Failed to load DLL for hot reload", &.{
                    slog.Attr.string("file", filename),
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            };
            errdefer dll.release();

            slog.info("Hot reload: DLL loaded successfully", &.{
                slog.Attr.string("path", full_path),
                slog.Attr.string("version", dll.getVersion()),
            });

            // Step 2: Create route registration context
            var reg_ctx = RouteRegistrationContext{
                .dll = dll,
                .dll_router = &context.dll_router,
                .dll_router_mutex = &context.dll_router_mutex,
                .slot_effect_adapter = context.slot_effect_adapter,
            };

            // Step 3: Create router builder for this DLL
            var router_builder = RouterBuilder.init(allocator, &reg_ctx) catch |err| {
                slog.err("Hot reload: Failed to create router builder", &.{
                    slog.Attr.string("file", filename),
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            };
            defer router_builder.deinit();

            // Step 4: Temporarily swap router and call featureInit
            const original_router = g_server_adapter.router;
            g_server_adapter.router = @ptrCast(&router_builder);
            defer g_server_adapter.router = original_router;

            const init_result = dll.featureInit(@ptrCast(@constCast(&g_server_adapter)));
            if (init_result != 0) {
                slog.err("Hot reload: DLL init failed", &.{
                    slog.Attr.string("file", filename),
                    slog.Attr.int("result_code", init_result),
                });
                continue;
            }

            // Step 5: Transfer routes from builder to active router
            // NOTE: old_dll=null because version_manager isn't implemented yet
            // This means old DLLs will leak memory until version management is added
            const route_count = router_builder.routes.items.len;
            router_builder.transferToRouter(null) catch |err| {
                slog.err("Hot reload: Failed to transfer routes", &.{
                    slog.Attr.string("file", filename),
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            };

            // Step 6: Log success
            slog.info("Hot reload completed successfully", &.{
                slog.Attr.string("file", filename),
                slog.Attr.string("path", full_path),
                slog.Attr.string("version", dll.getVersion()),
                slog.Attr.int("routes_registered", @intCast(route_count)),
            });

            slog.info("Routes activated for hot reload", &.{
                slog.Attr.string("file", filename),
            });

            // TODO: Future enhancements
            // - Use version_manager for old DLL cleanup and pass to transferToRouter
            // - Use router_lifecycle for atomic swap
            _ = version_manager;
            _ = router_lifecycle;
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

fn buildDLLResponse(
    allocator: std.mem.Allocator,
    request_id: u128,
    start_time: i128,
    builder: *ResponseBuilder,
) !ipc_types.IPCResponse {
    // Convert headers
    const headers = try allocator.alloc(ipc_types.Header, builder.headers.items.len);
    for (builder.headers.items, 0..) |header, i| {
        headers[i] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        };
    }

    // Copy body
    const body = try allocator.dupe(u8, builder.body.items);

    const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

    return .{
        .request_id = request_id,
        .status = builder.status,
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
