/// Todo feature route registration
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const types = @import("types.zig");
const effects_mod = @import("effects.zig");
const slog = @import("../../zerver/observability/slog.zig");
const http_status = zerver.HttpStatus;
// Global middleware
fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Middleware called", &.{
        slog.Attr.string("middleware", "logging"),
        slog.Attr.string("feature", "todos"),
    });
    _ = ctx;
    slog.info("Request received", &.{
        slog.Attr.string("feature", "todos"),
        slog.Attr.string("middleware", "logging"),
    });
    return zerver.continue_();
}

// Wrapper functions for steps
fn extract_id_wrapper(ctx: *zerver.CtxBase) anyerror!zerver.types.Decision {
    return step_extract_id(ctx);
}

fn load_from_db_wrapper(ctx: *zerver.CtxBase) anyerror!zerver.types.Decision {
    return step_load_from_db(ctx);
}

fn create_todo_wrapper(ctx: *zerver.CtxBase) anyerror!zerver.types.Decision {
    return step_create_todo(ctx);
}

fn update_todo_wrapper(ctx: *zerver.CtxBase) anyerror!zerver.types.Decision {
    return step_update_todo(ctx);
}

fn delete_todo_wrapper(ctx: *zerver.CtxBase) anyerror!zerver.types.Decision {
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

    slog.debug("Extracted todo ID", &.{
        slog.Attr.string("step", "extract_id"),
        slog.Attr.string("todo_id", todo_id),
    });
    return zerver.continue_();
}

// Step 2: Simulate database load
fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
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

        const effects_list = try ctx.allocator.alloc(zerver.Effect, 1);
        effects_list[0] = .{
            .db_get = .{
                .key = "todos:*",
                .token = 3, // TodoList slot
                .required = true,
            },
        };

        return .{ .need = .{
            .effects = effects_list,
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

    const effects_single = try ctx.allocator.alloc(zerver.Effect, 1);
    effects_single[0] = .{
        .db_get = .{
            .key = "todo:123", // In real app, use todo_id
            .token = 2, // TodoItem slot
            .required = true,
        },
    };

    return .{ .need = .{
        .effects = effects_single,
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
        .body = .{ .complete = "[{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false},{\"id\":\"2\",\"title\":\"Pay bills\",\"done\":true}]" },
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
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false}" },
    });
}

// Step 3: Create todo
fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.debug("Creating new todo", &.{
        slog.Attr.string("step", "create_todo"),
        slog.Attr.string("feature", "todos"),
    });

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{
            .key = "todo:123",
            .value = "{\"id\":1,\"title\":\"New todo\"}",
            .token = 2, // TodoItem
            .required = true,
        },
    };

    return .{ .need = .{
        .effects = effects,
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
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"New todo\",\"done\":false}" },
    });
}

// Step 4: Update todo
fn step_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.debug("Updating todo", &.{
        slog.Attr.string("step", "update_todo"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{
            .key = "todo:123",
            .value = "{\"id\":1,\"title\":\"Updated todo\",\"done\":true}",
            .token = 2, // TodoItem
            .required = true,
            .idem = "update-123", // Idempotency key
        },
    };

    return .{ .need = .{
        .effects = effects,
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
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Updated todo\",\"done\":true}" },
    });
}

// Step 5: Delete todo
fn step_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.debug("Deleting todo", &.{
        slog.Attr.string("step", "delete_todo"),
        slog.Attr.string("todo_id", todo_id),
        slog.Attr.string("feature", "todos"),
    });

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_del = .{
            .key = "todo:123",
            .token = 2, // TodoItem
            .required = true,
        },
    };

    return .{ .need = .{
        .effects = effects,
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
        .body = .{ .complete = "" },
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
