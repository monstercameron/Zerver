/// Todo feature step implementations
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const types = @import("types.zig");

// Step 1: Extract and validate user from header
pub fn step_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Auth] Step auth called\n", .{});
    const user_id = ctx.header("X-User-ID") orelse {
        std.debug.print("  [Auth] Missing X-User-ID header\n", .{});
        return zerver.fail(zerver.ErrorCode.Unauthorized, "auth", "missing_user");
    };

    std.debug.print("  [Auth] User: {s}\n", .{user_id});
    return zerver.continue_();
}

// Step 2: Extract todo ID from path parameter
pub fn step_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.continue_(); // OK if not present (LIST operation)
    };

    std.debug.print("  [Extract] TodoId: {s}\n", .{todo_id});
    return zerver.continue_();
}

// Step 3: Simulate database load
pub fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
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

// Step 4: Create todo
pub fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
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

// Step 5: Update todo
pub fn step_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
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

// Step 6: Delete todo
pub fn step_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
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