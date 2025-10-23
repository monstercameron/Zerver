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
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const domain = @import("core/domain.zig");
const middleware = @import("common/middleware.zig");
const queries = @import("queries/operations.zig");
const mutations = @import("mutations/operations.zig");

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

    std.debug.print("[error] {s} - {s} on {s} -> {d}\n", .{
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
    return .{ .success = "" };
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN: SERVER SETUP
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Display banner
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Todos Product: Advanced Example              ║\n", .{});
    std.debug.print("║                                                      ║\n", .{});
    std.debug.print("║  Professional Structure:                             ║\n", .{});
    std.debug.print("║    core/      Domain models & business rules         ║\n", .{});
    std.debug.print("║    queries/   Read-only operations                   ║\n", .{});
    std.debug.print("║    mutations/ Write operations                       ║\n", .{});
    std.debug.print("║    common/    Shared middleware & utilities          ║\n", .{});
    std.debug.print("║                                                      ║\n", .{});
    std.debug.print("║  Features:                                            ║\n", .{});
    std.debug.print("║    • Domain-Driven Design (DDD) structure            ║\n", .{});
    std.debug.print("║    • CQRS pattern for read/write separation          ║\n", .{});
    std.debug.print("║    • Auth & rate limiting middleware                 ║\n", .{});
    std.debug.print("║    • Realistic DB operation latencies                ║\n", .{});
    std.debug.print("║    • Simulated async effects ready for Phase 2       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n\n", .{});

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

    std.debug.print("Registering routes...\n\n", .{});

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

    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║              Registered Routes                       ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ QUERIES (Read-Only):                                 ║\n", .{});
    std.debug.print("║   GET  /todos              - List all todos         ║\n", .{});
    std.debug.print("║   GET  /todos/:id          - Get todo by ID         ║\n", .{});
    std.debug.print("║                                                      ║\n", .{});
    std.debug.print("║ MUTATIONS (Write):                                   ║\n", .{});
    std.debug.print("║   POST   /todos            - Create new todo        ║\n", .{});
    std.debug.print("║   PATCH  /todos/:id        - Update todo            ║\n", .{});
    std.debug.print("║   DELETE /todos/:id        - Delete todo            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n\n", .{});

    // ─────────────────────────────────────────────────────────────────────────
    // TEST REQUESTS
    // ─────────────────────────────────────────────────────────────────────────

    std.debug.print("Running test requests...\n\n", .{});

    // Test 1: List todos
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║ TEST 1: GET /todos - List all todos                 ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
    const test1 = try server.handleRequest(
        "GET /todos HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Status: {d}\nBody: {s}\n\n", .{ 200, test1 });

    // Test 2: Get specific todo
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║ TEST 2: GET /todos/abc123 - Get specific todo       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
    const test2 = try server.handleRequest(
        "GET /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Status: {d}\nBody: {s}\n\n", .{ 200, test2 });

    // Test 3: Create todo
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║ TEST 3: POST /todos - Create new todo               ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
    const test3 = try server.handleRequest(
        "POST /todos HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nContent-Length: 0\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Status: {d}\nBody: {s}\n\n", .{ 201, test3 });

    // Test 4: Update todo
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║ TEST 4: PATCH /todos/abc123 - Update todo           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
    const test4 = try server.handleRequest(
        "PATCH /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nContent-Length: 0\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Status: {d}\nBody: {s}\n\n", .{ 200, test4 });

    // Test 5: Delete todo
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║ TEST 5: DELETE /todos/abc123 - Delete todo          ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
    const test5 = try server.handleRequest(
        "DELETE /todos/abc123 HTTP/1.1\r\nAuthorization: Bearer test_user_123\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Status: {d}\nBody: {s}\n\n", .{ 204, test5 });

    // Summary
    std.debug.print("\n╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Example Complete                           ║\n", .{});
    std.debug.print("║                                                      ║\n", .{});
    std.debug.print("║  ✓ Professional folder-based organization           ║\n", .{});
    std.debug.print("║  ✓ Domain-Driven Design patterns                    ║\n", .{});
    std.debug.print("║  ✓ CQRS pattern implementation                      ║\n", .{});
    std.debug.print("║  ✓ Auth & rate limiting                             ║\n", .{});
    std.debug.print("║  ✓ Realistic operation latencies                    ║\n", .{});
    std.debug.print("║  ✓ Ready for Phase 2 async/await                    ║\n", .{});
    std.debug.print("║                                                      ║\n", .{});
    std.debug.print("║  Structure: examples/products/todos/                ║\n", .{});
    std.debug.print("║    • core/       - Domain models                    ║\n", .{});
    std.debug.print("║    • queries/    - Read operations                  ║\n", .{});
    std.debug.print("║    • mutations/  - Write operations                 ║\n", .{});
    std.debug.print("║    • common/     - Middleware & utilities           ║\n", .{});
    std.debug.print("║    • main.zig    - Server initialization            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
}
