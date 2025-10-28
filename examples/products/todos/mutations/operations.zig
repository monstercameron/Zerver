// examples/products/todos/mutations/operations.zig
/// Todos Product: Mutation Operations (Write-Only)
///
/// Mutations follow CQRS pattern: operations that modify state
/// - CreateTodo: create new todo
/// - UpdateTodo: modify existing todo
/// - DeleteTodo: remove todo
const std = @import("std");
const zerver = @import("zerver");
const domain = @import("../core/domain.zig");
const middleware = @import("../common/middleware.zig");
const slog = @import("src/zerver/observability/slog.zig");

/// Mutation: Create new todo
pub fn mutation_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const user_id = ctx.slotGetString(@intFromEnum(middleware.Slot.user_id)) orelse "anonymous";

    // Generate new ID
    var id_buf: [32]u8 = undefined;
    const new_id = std.fmt.bufPrint(&id_buf, "todo_{d}", .{std.time.timestamp()}) catch unreachable;

    slog.infof("[mutation_create_todo] Creating todo {s}...", .{new_id});

    // Simulate DB write latency (slower than read)
    const latency = domain.OperationLatency.write().random();
    slog.infof("[mutation_create_todo] Writing to DB... ({d}ms)", .{latency});
    std.time.sleep(latency * 1_000_000);

    slog.infof("[mutation_create_todo] ✓ Created by {s}", .{user_id});
    return .Continue;
}

/// Mutation: Update existing todo
pub fn mutation_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(middleware.Slot.todo_id)) orelse {
        return zerver.fail(domain.makeError(.InvalidInput, "No todo ID", "context"));
    };

    // First load the todo
    const read_latency = domain.OperationLatency.read().random();
    slog.infof("[mutation_update_todo] Loading {s}... ({d}ms)", .{ todo_id, read_latency });
    std.time.sleep(read_latency * 1_000_000);

    // Then save changes
    const write_latency = domain.OperationLatency.write().random();
    slog.infof("[mutation_update_todo] Saving changes... ({d}ms)", .{write_latency});
    std.time.sleep(write_latency * 1_000_000);

    slog.infof("[mutation_update_todo] ✓ Updated {s}", .{todo_id});
    return .Continue;
}

/// Mutation: Delete todo
pub fn mutation_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(middleware.Slot.todo_id)) orelse {
        return zerver.fail(domain.makeError(.InvalidInput, "No todo ID", "context"));
    };

    // Simulate DB delete latency
    const latency = domain.OperationLatency.write().random();
    slog.infof("[mutation_delete_todo] Deleting {s}... ({d}ms)", .{ todo_id, latency });
    std.time.sleep(latency * 1_000_000);

    slog.infof("[mutation_delete_todo] ✓ Deleted {s}", .{todo_id});
    return .Continue;
}

/// Render: Output 201 Created response
pub fn render_created(_: *zerver.CtxBase) !zerver.Decision {
    slog.infof("[render] Rendering 201 Created", .{});
    return zerver.done(.{
        .status = 201,
        .body = "{\"id\":\"generated_id\",\"created_at\":\"2025-01-01T00:00:00Z\"}",
    });
}

/// Render: Output 204 No Content response
pub fn render_deleted(_: *zerver.CtxBase) !zerver.Decision {
    slog.infof("[render] Rendering 204 No Content", .{});
    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}

/// Render: Output 200 OK after update
pub fn render_updated(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(middleware.Slot.todo_id)) orelse "unknown";
    slog.infof("[render] Rendering updated item {s}", .{todo_id});
    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":\"updated_id\",\"updated_at\":\"2025-01-01T00:00:00Z\"}",
    });
}
