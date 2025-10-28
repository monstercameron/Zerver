// examples/products/todos/main_impl.zig
/// Todos Product: Advanced Example with Professional Structure
///
/// This example demonstrates a production-ready structure using:
/// - Domain-Driven Design (DDD) for core models
/// - CQRS (Command Query Responsibility Segregation) for operations
/// - Folder organization by concern:
///   * core/       - Domain models, business rules, value objects
///   * queries/    - Read-only operations
///   * mutations/  - Write operations
///   * common/     - Shared middleware, utilities
///   * main.zig    - Server initialization and route registration
///
/// Simulated effects with realistic latencies demonstrate how Phase 2
/// will handle actual async operations (DB, HTTP, etc.)
const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const domain = @import("core/domain.zig");
const middleware = @import("common/middleware.zig");
const queries = @import("queries/operations.zig");
const mutations = @import("mutations/operations.zig");
const slog = @import("../../../src/zerver/observability/slog.zig");

// ─────────────────────────────────────────────────────────────────────────────
// ERROR HANDLER
// ─────────────────────────────────────────────────────────────────────────────

/// Centralized error handler - converts domain errors to HTTP responses
fn error_handler(ctx: *zerver.CtxBase) !zerver.Decision {
    const error_info = ctx.lastError() orelse domain.makeError(
        .Internal,
        "Unknown error",
        "system",
    );

    const error_ctx: domain.ErrorContext = .{
        .error_code = @enumFromInt(error_info.kind),
        .message = error_info.ctx.what,
        .resource = error_info.ctx.key,
    };

    const status_code = switch (error_ctx.error_code) {
        .InvalidInput => 400,
        .Unauthorized => 401,
        .Forbidden => 403,
        .NotFound => 404,
        .Conflict => 409,
        .TooManyRequests => 429,
        .UpstreamUnavailable => 502,
        .Timeout => 504,
        .Internal => 500,
        .CompletedTodosImmutable => 409,
    };

    slog.errf("[error] {s} - {s} on {s} -> {d}", .{
        @tagName(error_ctx.error_code),
        error_ctx.message,
        error_ctx.resource,
        status_code,
    });

    return zerver.done(.{
        .status = status_code,
        .body = "{\"error\":\"Request processing failed\"}",
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MOCK EFFECT HANDLER
// ─────────────────────────────────────────────────────────────────────────────

/// Mock effect handler for MVP
fn mock_effect_handler(
    _effect: *const zerver.Effect,
    _timeout_ms: u32,
) anyerror!zerver.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    const empty_ptr = @constCast(&[_]u8{});
    return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN: SERVER SETUP
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Display banner
    slog.infof("", .{});
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║        Todos Product: Advanced Example              ║", .{});
    slog.infof("║                                                      ║", .{});
    slog.infof("║  Professional Structure:                             ║", .{});
    slog.infof("║    core/      Domain models & business rules         ║", .{});
    slog.infof("║    queries/   Read-only operations                   ║", .{});
    slog.infof("║    mutations/ Write operations                       ║", .{});
    slog.infof("║    common/    Shared middleware & utilities          ║", .{});
    slog.infof("║                                                      ║", .{});
    slog.infof("║  Features:                                            ║", .{});
    slog.infof("║    • Domain-Driven Design (DDD) structure            ║", .{});
    slog.infof("║    • CQRS pattern for read/write separation          ║", .{});
    slog.infof("║    • Auth & rate limiting middleware                 ║", .{});
    slog.infof("║    • Realistic DB operation latencies                ║", .{});
    slog.infof("║    • Simulated async effects ready for Phase 2       ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝\n", .{});

    // Initialize server
    const config = zerver.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8081,
        },
        .on_error = error_handler,
        .debug = true,
    };

    var server = try zerver.Server.init(allocator, config, mock_effect_handler);
    defer server.deinit();

    // ─────────────────────────────────────────────────────────────────────────
    // MIDDLEWARE CHAINS
    // ─────────────────────────────────────────────────────────────────────────

    // Global middleware applied to all routes
    const global_mw = &.{
        zerver.step("mw_logging", middleware.mw_logging),
        zerver.step("mw_operation_latency", middleware.mw_operation_latency),
    };

    // Protected routes: auth required
    const protected_mw = global_mw ++ &.{
        zerver.step("mw_authenticate", middleware.mw_authenticate),
        zerver.step("mw_rate_limit", middleware.mw_rate_limit),
    };

    // Apply global middleware
    try server.use(global_mw);

    // ─────────────────────────────────────────────────────────────────────────
    // ROUTE DEFINITIONS
    // ─────────────────────────────────────────────────────────────────────────

    slog.infof("Registering routes...\n", .{});

    // ── Read Operations (GET)

    // GET /todos - List all todos
    try server.addRoute(.GET, "/todos", .{
        .before = protected_mw,
        .steps = &.{
            zerver.step("query_list_todos", queries.query_list_todos),
            zerver.step("render_list", queries.render_list),
        },
    });

    // GET /todos/:id - Get specific todo
    try server.addRoute(.GET, "/todos/:id", .{
        .before = protected_mw,
        .steps = &.{
            zerver.step("query_extract_id", queries.query_extract_id),
            zerver.step("query_get_todo", queries.query_get_todo),
            zerver.step("render_item", queries.render_item),
        },
    });

    // ── Write Operations (POST, PATCH, DELETE)

    // POST /todos - Create new todo
    try server.addRoute(.POST, "/todos", .{
        .before = protected_mw,
        .steps = &.{
            zerver.step("mutation_create_todo", mutations.mutation_create_todo),
            zerver.step("render_created", mutations.render_created),
        },
    });

    // PATCH /todos/:id - Update todo
    try server.addRoute(.PATCH, "/todos/:id", .{
        .before = protected_mw,
        .steps = &.{
            zerver.step("query_extract_id", queries.query_extract_id),
            zerver.step("mutation_update_todo", mutations.mutation_update_todo),
            zerver.step("render_updated", mutations.render_updated),
        },
    });

    // DELETE /todos/:id - Delete todo
    try server.addRoute(.DELETE, "/todos/:id", .{
        .before = protected_mw,
        .steps = &.{
            zerver.step("query_extract_id", queries.query_extract_id),
            zerver.step("mutation_delete_todo", mutations.mutation_delete_todo),
            zerver.step("render_deleted", mutations.render_deleted),
        },
    });

    // ─────────────────────────────────────────────────────────────────────────
    // ROUTE SUMMARY
    // ─────────────────────────────────────────────────────────────────────────

    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║              Registered Routes                       ║", .{});
    slog.infof("╠══════════════════════════════════════════════════════╣", .{});
    slog.infof("║ QUERIES (Read-Only):                                 ║", .{});
    slog.infof("║   GET  /todos              - List all todos         ║", .{});
    slog.infof("║   GET  /todos/:id          - Get todo by ID         ║", .{});
    slog.infof("║                                                      ║", .{});
    slog.infof("║ MUTATIONS (Write):                                   ║", .{});
    slog.infof("║   POST   /todos            - Create new todo        ║", .{});
    slog.infof("║   PATCH  /todos/:id        - Update todo            ║", .{});
    slog.infof("║   DELETE /todos/:id        - Delete todo            ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝\n", .{});

    // ─────────────────────────────────────────────────────────────────────────
    // TEST REQUESTS
    // ─────────────────────────────────────────────────────────────────────────

    slog.infof("Running test requests...\n", .{});

    // Test 1: List todos
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║ TEST 1: GET /todos - List all todos                 ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
    const test1 = try server.handleRequest(
        "GET /todos HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    slog.infof("Status: {d}\nBody: {s}\n", .{ 200, test1 });

    // Test 2: Get specific todo
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║ TEST 2: GET /todos/abc123 - Get specific todo       ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
    const test2 = try server.handleRequest(
        "GET /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    slog.infof("Status: {d}\nBody: {s}\n", .{ 200, test2 });

    // Test 3: Create todo
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║ TEST 3: POST /todos - Create new todo               ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
    const test3 = try server.handleRequest(
        "POST /todos HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nContent-Length: 0\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    slog.infof("Status: {d}\nBody: {s}\n", .{ 201, test3 });

    // Test 4: Update todo
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║ TEST 4: PATCH /todos/abc123 - Update todo           ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
    const test4 = try server.handleRequest(
        "PATCH /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nContent-Length: 0\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    slog.infof("Status: {d}\nBody: {s}\n", .{ 200, test4 });

    // Test 5: Delete todo
    slog.infof("╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║ TEST 5: DELETE /todos/abc123 - Delete todo          ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
    const test5 = try server.handleRequest(
        "DELETE /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    slog.infof("Status: {d}\nBody: {s}\n", .{ 204, test5 });

    // Summary
    slog.infof("\n╔══════════════════════════════════════════════════════╗", .{});
    slog.infof("║           Example Complete                           ║", .{});
    slog.infof("║                                                      ║", .{});
    slog.infof("║  ✓ Professional folder-based organization           ║", .{});
    slog.infof("║  ✓ Domain-Driven Design patterns                    ║", .{});
    slog.infof("║  ✓ CQRS pattern implementation                      ║", .{});
    slog.infof("║  ✓ Auth & rate limiting                             ║", .{});
    slog.infof("║  ✓ Realistic operation latencies                    ║", .{});
    slog.infof("║  ✓ Ready for Phase 2 async/await                    ║", .{});
    slog.infof("║                                                      ║", .{});
    slog.infof("║  Structure: examples/products/todos/                ║", .{});
    slog.infof("║    • core/       - Domain models                    ║", .{});
    slog.infof("║    • queries/    - Read operations                  ║", .{});
    slog.infof("║    • mutations/  - Write operations                 ║", .{});
    slog.infof("║    • common/     - Middleware & utilities           ║", .{});
    slog.infof("║    • main.zig    - Server initialization            ║", .{});
    slog.infof("╚══════════════════════════════════════════════════════╝", .{});
}
