// src/zerver/bootstrap/init.zig
/// Server initialization and route setup
///
/// This module handles server configuration, route registration,
/// and initialization of the application.
const std = @import("std");
const root = @import("../root.zig");
const slog = @import("../observability/slog.zig");
const runtime_config = @import("../runtime/config.zig");
const runtime_resources = @import("../runtime/resources.zig");
const runtime_global = @import("../runtime/global.zig");
const helpers = @import("helpers.zig");
const effectors = @import("../runtime/reactor/effectors.zig");

// Import features - DISABLED: Features have been moved to external DLLs
// const hello = @import("../../features/hello/routes.zig");
// const blog = @import("../../features/blog/index.zig");
// const todos = @import("../../features/todos/index.zig");
// const feature_registry = @import("../features/registry.zig");

// Create feature registry with automatic token assignment
// Blog gets tokens 0-99, Todos gets tokens 100-199
// DISABLED: Using external DLLs instead
// const FeatureRouter = feature_registry.FeatureRegistry(.{ blog, todos });

// Reactor dispatcher handlers that route through the feature registry
fn reactorDbGetHandler(_: *effectors.Context, payload: root.types.DbGet) effectors.DispatchError!root.types.EffectResult {
    slog.info("🚀 REGISTRY DB_GET 🚀", &.{
        slog.Attr.string("key", payload.key),
        slog.Attr.uint("token", payload.token),
    });
    const effect = root.types.Effect{ .db_get = payload };
    return FeatureRouter.effectHandler(&effect, 300) catch |err| {
        slog.err("registry_handler_error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return effectors.DispatchError.UnsupportedEffect;
    };
}

fn reactorDbPutHandler(_: *effectors.Context, payload: root.types.DbPut) effectors.DispatchError!root.types.EffectResult {
    slog.info("🚀 REGISTRY DB_PUT 🚀", &.{
        slog.Attr.string("key", payload.key),
        slog.Attr.uint("token", payload.token),
    });
    const effect = root.types.Effect{ .db_put = payload };
    return FeatureRouter.effectHandler(&effect, 300) catch |err| {
        slog.err("registry_handler_error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return effectors.DispatchError.UnsupportedEffect;
    };
}

fn reactorDbDelHandler(_: *effectors.Context, payload: root.types.DbDel) effectors.DispatchError!root.types.EffectResult {
    slog.info("🚀 REGISTRY DB_DEL 🚀", &.{
        slog.Attr.string("key", payload.key),
        slog.Attr.uint("token", payload.token),
    });
    const effect = root.types.Effect{ .db_del = payload };
    return FeatureRouter.effectHandler(&effect, 300) catch |err| {
        slog.err("registry_handler_error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return effectors.DispatchError.UnsupportedEffect;
    };
}

// Register feature registry handlers with the reactor dispatcher
fn registerReactorHandlers(resources: *runtime_resources.RuntimeResources) void {
    if (resources.reactorEffectDispatcher()) |dispatcher| {
        slog.info("Registering feature registry handlers", &.{});
        dispatcher.setDbGetHandler(reactorDbGetHandler);
        dispatcher.setDbPutHandler(reactorDbPutHandler);
        dispatcher.setDbDelHandler(reactorDbDelHandler);
    }
}

// Stub effect handler (won't be called since dispatcher handles everything)
fn stubEffectHandler(effect: *const root.types.Effect, timeout_ms: u32) anyerror!root.types.EffectResult {
    _ = effect;
    _ = timeout_ms;
    slog.warn("⚠️ STUB HANDLER CALLED - SHOULD NOT HAPPEN ⚠️", &.{});
    return root.types.EffectResult{ .failure = .{
        .kind = 500,
        .ctx = .{ .what = "stub", .key = "unreachable" },
    } };
}

pub const Initialization = struct {
    server: root.Server,
    resources: *runtime_resources.RuntimeResources,
    otel_exporter: ?*root.otel.OtelExporter = null,

    pub fn deinit(self: *Initialization, allocator: std.mem.Allocator) void {
        self.server.deinit();
        self.resources.deinit();
        allocator.destroy(self.resources);
        if (self.otel_exporter) |exporter| {
            exporter.deinit();
            allocator.destroy(exporter);
        }
        runtime_global.clear();
    }
};


/// Initialize and configure the server
pub fn initializeServer(allocator: std.mem.Allocator) !Initialization {
    var app_config = try runtime_config.load(allocator, "config.json");
    const server_host = app_config.server.host;
    const server_port = app_config.server.port;
    const server_ip = try helpers.parseIpv4Host(server_host);

    slog.info("Zerver MVP Server Starting", &[_]slog.Attr{
        slog.Attr.string("version", "mvp"),
        slog.Attr.string("host", server_host),
        slog.Attr.int("port", @as(i64, @intCast(server_port))),
    });

    const reactor_cfg = app_config.reactor;
    slog.info("reactor_config", &[_]slog.Attr{
        slog.Attr.bool("enabled", reactor_cfg.enabled),
        slog.Attr.uint("continuation_workers", reactor_cfg.continuation_pool.size),
        slog.Attr.uint("continuation_queue", reactor_cfg.continuation_pool.queue_capacity),
        slog.Attr.uint("effector_workers", reactor_cfg.effector_pool.size),
        slog.Attr.uint("effector_queue", reactor_cfg.effector_pool.queue_capacity),
        slog.Attr.string("compute_kind", @tagName(reactor_cfg.compute_pool.kind)),
        slog.Attr.uint("compute_workers", reactor_cfg.compute_pool.size),
        slog.Attr.uint("compute_queue", reactor_cfg.compute_pool.queue_capacity),
    });

    if (app_config.observability.otlp_endpoint.len == 0) {
        if (try helpers.detectTempoEndpoint(allocator, &app_config.observability)) |detected_endpoint| {
            slog.info("tempo_auto_configured", &.{
                slog.Attr.string("endpoint", detected_endpoint),
            });
            app_config.observability.otlp_endpoint = detected_endpoint;
        } else {
            slog.debug("tempo_autodetect_skipped", &.{});
        }
    }

    var resources = runtime_resources.create(allocator, app_config) catch |err| {
        app_config.deinit(allocator);
        return err;
    };
    errdefer {
        runtime_global.clear();
        resources.deinit();
        allocator.destroy(resources);
    }
    // app_config ownership transferred to runtime resources
    runtime_global.set(resources);

    // Register feature registry handlers with the reactor dispatcher
    registerReactorHandlers(resources);

    // Create server config
    // API Design Note: Error handler is currently hardwired to blog_errors.onError
    // Ideal: Accept error handler as parameter or via config:
    //   pub fn init(allocator: Allocator, config: InitConfig) !*Server
    //   where InitConfig contains:
    //     - error_handler: ?*const fn(Error) void
    //     - effect_handler: *const fn(Effect) EffectResult
    //     - router: Router
    // This would allow library consumers to provide custom error handling.
    // Current limitation: bootstrap/init.zig is specific to blog example;
    // consumers should copy and modify this file rather than calling it directly.
    const mut_config = root.Config{
        .addr = .{
            .ip = server_ip,
            .port = server_port,
        },
        .on_error = blog.errors.onError,
    };

    // Create server with the blog effects handler until additional feature routing is wired
    var config = mut_config;
    var otel_exporter: ?*root.otel.OtelExporter = null;
    const observability = resources.configPtr().observability;
    if (observability.otlp_endpoint.len != 0) {
        var header_storage: ?[]root.otel.Header = null;
        var header_slice: []const root.otel.Header = &.{};
        if (observability.otlp_headers.len != 0) {
            const parsed = try root.otel.parseHeaderList(allocator, observability.otlp_headers);
            header_storage = parsed;
            header_slice = parsed;
        }
        defer if (header_storage) |storage| root.otel.freeHeaderList(allocator, storage);

        const otel_config = root.otel.OtelConfig{
            .endpoint = observability.otlp_endpoint,
            .service_name = observability.service_name,
            .service_version = observability.service_version,
            .environment = observability.environment,
            .headers = header_slice,
            .instrumentation_scope_name = observability.scope_name,
            .instrumentation_scope_version = observability.scope_version,
        };

        otel_exporter = blk: {
            const exporter = root.otel.OtelExporter.create(allocator, otel_config) catch |err| {
                slog.warn("otel_exporter_init_failed", &.{
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("endpoint", observability.otlp_endpoint),
                });
                break :blk null;
            };
            break :blk exporter;
        };

        if (otel_exporter) |exporter| {
            config.telemetry.subscriber = exporter.subscriber();
        }
    }

    var srv = try root.Server.init(allocator, config, stubEffectHandler);

    // Register features
    try blog.registerRoutes(&srv); // Blog routes now working
    try hello.registerRoutes(&srv);
    try todos.registerRoutes(&srv);

    // Print available routes
    printRoutes(&srv, allocator) catch |err| {
        slog.err("failed to print routes", &.{
            slog.Attr.string("error", @errorName(err)),
        });
    };

    return Initialization{
        .server = srv,
        .resources = resources,
        .otel_exporter = otel_exporter,
    };
}

/// Print available routes for documentation
fn printRoutes(srv: *root.Server, allocator: std.mem.Allocator) !void {
    const routes = try srv.getAllRoutes(allocator);
    defer {
        for (routes) |route| {
            allocator.free(route.path);
        }
        allocator.free(routes);
    }

    slog.info("Routes registered", &.{
        slog.Attr.uint("count", @as(u64, @intCast(routes.len))),
    });

    for (routes) |route| {
        slog.info("route", &.{
            slog.Attr.string("method", route.method),
            slog.Attr.string("path", route.path),
        });
    }
}

/// Print demonstration information
pub fn printDemoInfo(app_config: *const runtime_config.AppConfig) void {
    slog.info("Server ready for HTTP requests", &[_]slog.Attr{
        slog.Attr.string("host", app_config.server.host),
        slog.Attr.int("port", @as(i64, @intCast(app_config.server.port))),
        slog.Attr.string("status", "running"),
    });

    slog.info("Features demonstrated", &[_]slog.Attr{
        slog.Attr.string("features", "slot system, middleware, routing, steps, effects, continuations, error handling, CRUD"),
    });
}
// Covered by unit test: tests/unit/bootstrap_init_test.zig
// FORCE_RECOMPILE_1761666448
