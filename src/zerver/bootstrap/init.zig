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
const http_status = root.HttpStatus;
const helpers = @import("helpers.zig");

// Import features
const todos = @import("../../features/todos/routes.zig");
const hello = @import("../../features/hello/routes.zig");
const blog = @import("../../features/blog/routes.zig");
const todo_effects = @import("../../features/todos/effects.zig");
const todo_steps = @import("../../features/todos/steps.zig");
const todo_errors = @import("../../features/todos/errors.zig");
const blog_effects = @import("../../features/blog/effects.zig");
const blog_errors = @import("../../features/blog/errors.zig");

/// Composite effect handler that routes to the appropriate feature handler
fn compositeEffectHandler(effect: *const root.Effect, timeout_ms: u32) anyerror!root.types.EffectResult {
    // TODO(bug): Branch only forwards to blog_effects; register-switching for hello/todos never happens, so feature-specific effects will 404.
    // Use blog effects handler
    return try blog_effects.effectHandler(effect, timeout_ms);
}
fn helloStep(ctx: *root.CtxBase) !root.Decision {
    slog.debug("Hello step called", &[_]slog.Attr{
        slog.Attr.string("step", "hello"),
        slog.Attr.string("feature", "bootstrap"),
    });
    _ = ctx;
    return root.done(.{
        .status = http_status.ok,
        .body = .{ .complete = "Hello from Zerver! Try /todos endpoints with X-User-ID header." },
    });
}

/// Hello world step wrapper
fn helloStepWrapper(ctx: *root.CtxBase) anyerror!root.Decision {
    return helloStep(ctx);
}

/// Hello world step definition
const hello_world_step = root.types.Step{
    .name = "hello",
    .call = helloStepWrapper,
    .reads = &.{},
    .writes = &.{},
};

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

    try blog_effects.initialize(resources);

    // Create server config
    const mut_config = root.Config{
        .addr = .{
            .ip = server_ip,
            .port = server_port,
        },
        .on_error = blog_errors.onError,
    };
    // TODO(code-smell): Hard-wiring blog error handler here prevents consumers embedding the framework from injecting their own global handler.

    // Create server with a composite effect handler that routes to the appropriate feature handler
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

    var srv = try root.Server.init(allocator, config, compositeEffectHandler);

    // Register features
    // try todos.registerRoutes(&srv);
    try blog.registerRoutes(&srv); // Blog routes now working
    // try hello.registerRoutes(&srv);

    // Add a simple root route
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_world_step} });

    // Print available routes
    printRoutes();

    return Initialization{
        .server = srv,
        .resources = resources,
        .otel_exporter = otel_exporter,
    };
}

/// Print available routes for documentation
fn printRoutes() void {
    slog.info("Routes registered", &[_]slog.Attr{
        slog.Attr.string("todo_routes", "GET /todos, GET /todos/:id, POST /todos, PATCH /todos/:id, DELETE /todos/:id"),
        slog.Attr.string("blog_routes", "GET /blog/posts, GET /blog/posts/:id, POST /blog/posts, PUT /blog/posts/:id, PATCH /blog/posts/:id, DELETE /blog/posts/:id, GET /blog/posts/:id/comments, POST /blog/posts/:id/comments, DELETE /blog/posts/:id/comments/:cid"),
    });
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
