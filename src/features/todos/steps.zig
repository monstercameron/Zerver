// src/features/todos/steps.zig
/// Todo feature step implementations
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const types = @import("types.zig");
const slog = @import("../../zerver/observability/slog.zig");
const http_status = zerver.HttpStatus;

// Step 1: Extract and validate user from header
pub fn step_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Auth step called", &.{
        slog.Attr.string("step", "auth"),
        slog.Attr.string("feature", "todos"),
    });
    const user_id = ctx.header("X-User-ID") orelse {
        slog.warn("Missing X-User-ID header", &.{
            slog.Attr.string("step", "auth"),
            slog.Attr.string("feature", "todos"),
        });
        return zerver.fail(zerver.ErrorCode.Unauthorized, "auth", "missing_user");
    };

    slog.debug("User authenticated", &.{
        slog.Attr.string("step", "auth"),
        slog.Attr.string("user_id", user_id),
        slog.Attr.string("feature", "todos"),
    });
    return zerver.continue_();
}

// Step 2: Extract todo ID from path parameter
pub fn step_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.continue_(); // OK if not present (LIST operation)
    };

    slog.debug("Extracted todo ID from path", &.{
        slog.Attr.string("step", "extract_id"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });
    return zerver.continue_();
}

// Step 3: Simulate database load
pub fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Database load step called", &.{
        slog.Attr.string("step", "load_from_db"),
        slog.Attr.string("feature", "todos"),
    });
    const todo_id = ctx.param("id") orelse {
        // LIST operation - return empty list effect
        slog.debug("Fetching todo list", &.{
            slog.Attr.string("operation", "list"),
            slog.Attr.string("feature", "todos"),
        });

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
    slog.debug("Fetching single todo", &.{
        slog.Attr.string("operation", "get"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });

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

fn continuation_list(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("List continuation called", &.{
        slog.Attr.string("continuation", "list"),
        slog.Attr.string("feature", "todos"),
    });

    return zerver.done(.{
        .status = http_status.ok,
        .body = "[{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false},{\"id\":\"2\",\"title\":\"Pay bills\",\"done\":true}]",
    });
}

fn continuation_get(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("Item continuation called", &.{
        slog.Attr.string("continuation", "get"),
        slog.Attr.string("feature", "todos"),
    });

    return zerver.done(.{
        .status = http_status.ok,
        .body = "{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false}",
    });
}

// Step 4: Create todo
pub fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("Storing new todo", &.{
        slog.Attr.string("operation", "create"),
        slog.Attr.string("feature", "todos"),
    });

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

fn continuation_create(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("Create continuation called", &.{
        slog.Attr.string("continuation", "create"),
        slog.Attr.string("feature", "todos"),
    });

    return zerver.done(.{
        .status = http_status.created,
        .body = "{\"id\":\"1\",\"title\":\"New todo\",\"done\":false}",
    });
}

// Step 5: Update todo
pub fn step_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.debug("Updating todo", &.{
        slog.Attr.string("operation", "update"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });

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

fn continuation_update(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("Update continuation called", &.{
        slog.Attr.string("continuation", "update"),
        slog.Attr.string("feature", "todos"),
    });

    return zerver.done(.{
        .status = http_status.ok,
        .body = "{\"id\":\"1\",\"title\":\"Updated todo\",\"done\":true}",
    });
}

// Step 6: Delete todo
pub fn step_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.debug("Deleting todo", &.{
        slog.Attr.string("operation", "delete"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });

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

fn continuation_delete(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debug("Todo deleted", &.{
        slog.Attr.string("continuation", "delete"),
        slog.Attr.string("feature", "todos"),
    });

    return zerver.done(.{
        .status = http_status.no_content,
        .body = "",
    });
}

