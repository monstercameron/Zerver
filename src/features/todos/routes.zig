/// Todo feature route registration
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const types = @import("types.zig");
const effects_mod = @import("effects.zig");
// Global middleware
fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Middleware] Logging middleware called\n", .{});
    _ = ctx;
    std.debug.print("→ Request received\n", .{});
    return zerver.continue_();
}

// Wrapper functions for steps
fn extract_id_wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return step_extract_id(ctx);
}

fn load_from_db_wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return step_load_from_db(ctx);
}

fn create_todo_wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return step_create_todo(ctx);
}

fn update_todo_wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return step_update_todo(ctx);
}

fn delete_todo_wrapper(ctx_opaque: *anyopaque) anyerror!zerver.types.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return step_delete_todo(ctx);
}

// Step definitions
const extract_id_step = zerver.types.Step{
    .name = "extract_id",
    .call = extract_id_wrapper,
    .reads = &.{},
    .writes = &.{},
};

const load_step = zerver.types.Step{
    .name = "load",
    .call = load_from_db_wrapper,
    .reads = &.{},
    .writes = &.{},
};

const create_step = zerver.types.Step{
    .name = "create",
    .call = create_todo_wrapper,
    .reads = &.{},
    .writes = &.{},
};

const update_step = zerver.types.Step{
    .name = "update",
    .call = update_todo_wrapper,
    .reads = &.{},
    .writes = &.{},
};

const delete_step = zerver.types.Step{
    .name = "delete",
    .call = delete_todo_wrapper,
    .reads = &.{},
    .writes = &.{},
};

// Step 1: Extract todo ID from path parameter
fn step_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.continue_(); // OK if not present (LIST operation)
    };

    std.debug.print("  [Extract] TodoId: {s}\n", .{todo_id});
    return zerver.continue_();
}

// Step 2: Simulate database load
fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Step] step_load_from_db called\n", .{});
    const todo_id = ctx.param("id") orelse {
        // LIST operation - return empty list effect
        std.debug.print("  [DB Load] Fetching todo list\n", .{});

        const effects = [_]zerver.Effect{
            .{
                .db_get = .{
                    .key = "todos:*",
                    .token = 3, // TodoList slot
                    .required = true,
                },
            },
        };

        return .{ .need = .{
            .effects = &effects,
            .mode = .Sequential,
            .join = .all,
            .continuation = continuation_list,
        } };
    };

    // Single item load
    std.debug.print("  [DB Load] Fetching todo {s}\n", .{todo_id});

    const effects = [_]zerver.Effect{
        .{
            .db_get = .{
                .key = "todo:123", // In real app, use todo_id
                .token = 2, // TodoItem slot
                .required = true,
            },
        },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_get,
    } };
}

fn continuation_list(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Continuation] List continuation called\n", .{});

    return zerver.done(.{
        .status = 200,
        .body = "[{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false},{\"id\":\"2\",\"title\":\"Pay bills\",\"done\":true}]",
    });
}

fn continuation_get(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Continuation] Item continuation called\n", .{});

    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false}",
    });
}

// Step 3: Create todo
fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Create] Storing new todo\n", .{});

    const effects = [_]zerver.Effect{
        .{
            .db_put = .{
                .key = "todo:123",
                .value = "{\"id\":1,\"title\":\"New todo\"}",
                .token = 2, // TodoItem
                .required = true,
            },
        },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_create,
    } };
}

fn continuation_create(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Continuation] Create continuation called\n", .{});

    return zerver.done(.{
        .status = 201,
        .body = "{\"id\":\"1\",\"title\":\"New todo\",\"done\":false}",
    });
}

// Step 4: Update todo
fn step_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    std.debug.print("  [Update] Updating todo {s}\n", .{todo_id});

    const effects = [_]zerver.Effect{
        .{
            .db_put = .{
                .key = "todo:123",
                .value = "{\"id\":1,\"title\":\"Updated todo\",\"done\":true}",
                .token = 2, // TodoItem
                .required = true,
                .idem = "update-123", // Idempotency key
            },
        },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_update,
    } };
}

fn continuation_update(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Continuation] Update continuation called\n", .{});

    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":\"1\",\"title\":\"Updated todo\",\"done\":true}",
    });
}

// Step 5: Delete todo
fn step_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    std.debug.print("  [Delete] Deleting todo {s}\n", .{todo_id});

    const effects = [_]zerver.Effect{
        .{
            .db_del = .{
                .key = "todo:123",
                .token = 2, // TodoItem
                .required = true,
            },
        },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_delete,
    } };
}

fn continuation_delete(ctx: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));
    _ = base;
    std.debug.print("  [Continuation] Todo deleted\n", .{});

    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}

/// Register all todo routes with the server
pub fn registerRoutes(server: *zerver.Server) !void {
    // Register routes without auth steps
    try server.addRoute(.GET, "/todos", .{ .steps = &.{
        extract_id_step,
        load_step,
    } });

    try server.addRoute(.GET, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        load_step,
    } });

    try server.addRoute(.POST, "/todos", .{ .steps = &.{
        create_step,
    } });

    try server.addRoute(.PATCH, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        update_step,
    } });

    try server.addRoute(.DELETE, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        delete_step,
    } });
}