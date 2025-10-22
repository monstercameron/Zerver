/// Todos Product: Query Operations (Read-Only)
///
/// Queries follow CQRS pattern: read-only operations that don't modify state
/// - GetTodo: fetch single todo by ID
/// - ListTodos: fetch all todos (with potential filtering/sorting)
/// - Render: convert domain models to HTTP responses
const std = @import("std");
const zerver = @import("zerver");
const domain = @import("../core/domain.zig");
const middleware = @import("../common/middleware.zig");

/// Query: Extract todo ID from URL path parameter
pub fn query_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(domain.makeError(.InvalidInput, "Missing todo ID in path", "path"));
    };

    try ctx.slotPutString(@intFromEnum(middleware.Slot.todo_id), todo_id);
    std.debug.print("[query] Extracted ID: {s}\n", .{todo_id});

    return .Continue;
}

/// Query: Load single todo from database
pub fn query_get_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(middleware.Slot.todo_id)) orelse {
        return zerver.fail(domain.makeError(.InvalidInput, "No todo ID", "context"));
    };

    // Simulate DB read latency
    const latency = domain.OperationLatency.read().random();
    std.debug.print("[query_get_todo] Loading {s}... ({d}ms)\n", .{ todo_id, latency });
    std.time.sleep(latency * 1_000_000);

    // BTS: Real implementation would fetch from database
    // For MVP, return mock success
    std.debug.print("[query_get_todo] ✓ Loaded: {s}\n", .{todo_id});
    return .Continue;
}

/// Query: Scan all todos for user
pub fn query_list_todos(ctx: *zerver.CtxBase) !zerver.Decision {
    const user_id = ctx.slotGetString(@intFromEnum(middleware.Slot.user_id)) orelse "anonymous";

    // Simulate DB scan latency (slower than single read)
    const latency = domain.OperationLatency.scan().random();
    std.debug.print("[query_list_todos] Scanning user '{s}'... ({d}ms)\n", .{ user_id, latency });
    std.time.sleep(latency * 1_000_000);

    std.debug.print("[query_list_todos] ✓ Found 0 todos\n", .{});
    return .Continue;
}

/// Render: Output list of todos as JSON
pub fn render_list(_: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("[render] Rendering todo list\n", .{});
    return zerver.done(.{
        .status = 200,
        .body = "{\"data\":[],\"total\":0}",
    });
}

/// Render: Output single todo as JSON
pub fn render_item(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(middleware.Slot.todo_id)) orelse "unknown";
    std.debug.print("[render] Rendering item {s}\n", .{todo_id});
    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":\"unknown\",\"title\":\"\",\"status\":\"pending\"}",
    });
}
