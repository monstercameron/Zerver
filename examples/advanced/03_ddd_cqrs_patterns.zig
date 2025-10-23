/// Advanced Example: Todos Product with DDD/CQRS Structure
///
/// This example demonstrates a production-ready structure using:
/// - Domain-Driven Design (DDD) for core models
/// - CQRS (Command Query Responsibility Segregation) for operations
/// - Folder organization by concern:
///   * core/       - Domain models, business rules, value objects
///   * queries/    - Read-only operations
///   * mutations/  - Write operations
///   * common/     - Shared middleware, utilities
///
/// Simulated effects with realistic latencies demonstrate how Phase 2
/// will handle actual async operations (DB, HTTP, etc.)
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("zerver");

// Import product modules with relative paths that work from root
const domain = @import("examples/products/todos/core/domain.zig");
const middleware = @import("examples/products/todos/common/middleware.zig");
const queries = @import("examples/products/todos/queries/operations.zig");
const mutations = @import("examples/products/todos/mutations/operations.zig");

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

    const response_body = try std.fmt.allocPrint(
        ctx.arena,
        "{{\"error\":\"{}\"}}",
        .{error_ctx.message},
    );

    return zerver.done(.{
        .status = status_code,
        .body = response_body,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MOCK EFFECT HANDLER
// ─────────────────────────────────────────────────────────────────────────────

fn mock_effect_handler(effect: *const zerver.Effect, timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = timeout_ms;
    return switch (effect.effect_type) {
        .Other => .{ .success = "" },
        else => .{ .success = "" },
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// SERVER INITIALIZATION
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = zerver.server.Server.init(allocator);
    defer server.deinit();

    try server.setErrorHandler(error_handler);
    try server.setEffectHandler(mock_effect_handler);

    // ─────────────────────────────────────────────────────────────────────────
    // Middleware Chains
    // ─────────────────────────────────────────────────────────────────────────

    // Global middleware: applied to all routes
    var global_mw = std.ArrayList(zerver.Step).init(allocator);
    defer global_mw.deinit();
    try global_mw.append(.{ .function = middleware.mw_logging });
    try global_mw.append(.{ .function = middleware.mw_operation_latency });

    // Protected middleware: requires authentication
    var protected_mw = std.ArrayList(zerver.Step).init(allocator);
    defer protected_mw.deinit();
    try protected_mw.appendSlice(global_mw.items);
    try protected_mw.append(.{ .function = middleware.mw_authenticate });
    try protected_mw.append(.{ .function = middleware.mw_rate_limit });

    // ─────────────────────────────────────────────────────────────────────────
    // Routes
    // ─────────────────────────────────────────────────────────────────────────

    // GET /todos - List all todos
    try server.addRoute(.GET, "/todos", .{
        .middleware = global_mw.items,
        .steps = &.{
            .{ .function = queries.query_list_todos },
            .{ .function = queries.render_list },
        },
    });

    // GET /todos/:id - Get single todo
    try server.addRoute(.GET, "/todos/:id", .{
        .middleware = global_mw.items,
        .steps = &.{
            .{ .function = queries.query_extract_id },
            .{ .function = queries.query_get_todo },
            .{ .function = queries.render_item },
        },
    });

    // POST /todos - Create new todo
    try server.addRoute(.POST, "/todos", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = mutations.mutation_create_todo },
            .{ .function = mutations.render_created },
        },
    });

    // PATCH /todos/:id - Update todo
    try server.addRoute(.PATCH, "/todos/:id", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = queries.query_extract_id },
            .{ .function = mutations.mutation_update_todo },
            .{ .function = mutations.render_updated },
        },
    });

    // DELETE /todos/:id - Delete todo
    try server.addRoute(.DELETE, "/todos/:id", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = queries.query_extract_id },
            .{ .function = mutations.mutation_delete_todo },
            .{ .function = mutations.render_deleted },
        },
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Test Requests
    // ─────────────────────────────────────────────────────────────────────────

    // Print banner
    try std.io.getStdOut().writeAll(
        \\ 
        \\╔══════════════════════════════════════════════════════════════════════════════╗
        \\║ Zerver Advanced Example: Todos Product (DDD + CQRS)                         ║
        \\╚══════════════════════════════════════════════════════════════════════════════╝
        \\
        \\ This example demonstrates professional structure:
        \\   ✓ Domain-Driven Design (core/, business rules)
        \\   ✓ CQRS Pattern (queries/ + mutations/)
        \\   ✓ Middleware Composition (auth, rate limit, logging)
        \\   ✓ Simulated Effects (realistic latencies)
        \\
        \\═══════════════════════════════════════════════════════════════════════════════
        \\
    );

    // Test 1: List todos
    std.debug.print("Test 1: GET /todos\n", .{});
    var req1 = try zerver.reqtest_module.RequestBuilder.init(allocator, "GET", "/todos").build();
    defer req1.deinit();
    const res1 = try server.handleRequest(&req1);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res1.status, res1.body });

    // Test 2: Get single todo
    std.debug.print("Test 2: GET /todos/todo_123\n", .{});
    var req2 = try zerver.reqtest_module.RequestBuilder.init(allocator, "GET", "/todos/todo_123").build();
    defer req2.deinit();
    const res2 = try server.handleRequest(&req2);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res2.status, res2.body });

    // Test 3: Create todo (with auth)
    std.debug.print("Test 3: POST /todos (with Authorization)\n", .{});
    var req3 = try zerver.reqtest_module.RequestBuilder.init(allocator, "POST", "/todos")
        .withHeader("Authorization", "Bearer valid-token-12345")
        .build();
    defer req3.deinit();
    const res3 = try server.handleRequest(&req3);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res3.status, res3.body });

    // Test 4: Update todo
    std.debug.print("Test 4: PATCH /todos/todo_123 (with Authorization)\n", .{});
    var req4 = try zerver.reqtest_module.RequestBuilder.init(allocator, "PATCH", "/todos/todo_123")
        .withHeader("Authorization", "Bearer valid-token-12345")
        .build();
    defer req4.deinit();
    const res4 = try server.handleRequest(&req4);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res4.status, res4.body });

    // Test 5: Delete todo
    std.debug.print("Test 5: DELETE /todos/todo_123 (with Authorization)\n", .{});
    var req5 = try zerver.reqtest_module.RequestBuilder.init(allocator, "DELETE", "/todos/todo_123")
        .withHeader("Authorization", "Bearer valid-token-12345")
        .build();
    defer req5.deinit();
    const res5 = try server.handleRequest(&req5);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res5.status, res5.body });

    try std.io.getStdOut().writeAll(
        \\═══════════════════════════════════════════════════════════════════════════════
        \\
        \\ Example completed! Ready for Phase 2 with async/await support.
        \\
    );
}
