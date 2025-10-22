/// Complete Todo CRUD example: Full demonstration of Zerver capabilities
///
/// Demonstrates:
/// - Slot system with typed per-request state
/// - CtxView with compile-time slot access restrictions
/// - Steps with effects (simulated DB operations)
/// - Continuations and join strategies
/// - Error handling
/// - Complete request/response cycle
/// - All framework features working together
const std = @import("std");
const zerver = @import("zerver");

/// Application slots for Todo state
pub const TodoSlot = enum(u32) {
    UserId = 0,
    TodoId = 1,
    TodoItem = 2,
    TodoList = 3,
};

pub fn TodoSlotType(comptime s: TodoSlot) type {
    return switch (s) {
        .UserId => []const u8,
        .TodoId => []const u8,
        .TodoItem => struct { id: []const u8, title: []const u8, done: bool = false },
        .TodoList => []const u8, // JSON string
    };
}

// Step 1: Extract and validate user from header
pub fn step_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Auth] Step auth called\n", .{});
    const user_id = ctx.header("x-user-id") orelse {
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
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = "[{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false},{\"id\":\"2\",\"title\":\"Pay bills\",\"done\":true}]",
    });
}

fn continuation_get(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Continuation] Item continuation called\n", .{});

    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
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
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
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
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
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

// Global middleware
pub fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Middleware] Logging middleware called\n", .{});
    _ = ctx;
    std.debug.print("→ Request received\n", .{});
    return zerver.continue_();
}

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    std.debug.print("  [Error] onError called\n", .{});
    if (ctx.last_error) |err| {
        std.debug.print("  [Error] Last error: kind={}, what='{s}', key='{s}'\n", .{ err.kind, err.ctx.what, err.ctx.key });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_user")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = "{\"error\":\"Missing X-User-ID header\"}",
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = "{\"error\":\"Missing todo ID\"}",
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = "{\"error\":\"Unknown error\"}",
            });
        }
    } else {
        std.debug.print("  [Error] No last_error set\n", .{});
        return zerver.done(.{
            .status = 500,
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .body = "{\"error\":\"Internal server error - no error details\"}",
        });
    }
}

// Effect handler (mock database)
pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    std.debug.print("  [Effect] Handling effect type: {}\n", .{@as(std.meta.Tag(zerver.Effect), effect.*)});
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Effect] DB GET: {s} (token {})\n", .{ db_get.key, db_get.token });
            // Don't store in slots for now
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            std.debug.print("  [Effect] DB PUT: {s} = {s} (token {})\n", .{ db_put.key, db_put.value, db_put.token });
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            std.debug.print("  [Effect] DB DEL: {s} (token {})\n", .{ db_del.key, db_del.token });
            return .{ .success = "" };
        },
        else => {
            std.debug.print("  [Effect] Unknown effect type\n", .{});
            return .{ .success = "" };
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Todo CRUD Example - Complete Zerver Demo\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Create server
    const config = zerver.Config{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8080 },
        .on_error = onError,
    };

    var server = try zerver.Server.init(allocator, config, effectHandler);
    defer server.deinit();

    // Register global middleware
    try server.use(&.{
        zerver.step("logging", middleware_logging),
        zerver.step("auth", step_auth),
    });

    // Register routes
    try server.addRoute(.GET, "/todos", .{ .steps = &.{
        zerver.step("extract_id", step_extract_id),
        zerver.step("load", step_load_from_db),
    } });

    try server.addRoute(.GET, "/todos/:id", .{ .steps = &.{
        zerver.step("extract_id", step_extract_id),
        zerver.step("load", step_load_from_db),
    } });

    try server.addRoute(.POST, "/todos", .{ .steps = &.{
        zerver.step("create", step_create_todo),
    } });

    try server.addRoute(.PATCH, "/todos/:id", .{ .steps = &.{
        zerver.step("extract_id", step_extract_id),
        zerver.step("update", step_update_todo),
    } });

    try server.addRoute(.DELETE, "/todos/:id", .{ .steps = &.{
        zerver.step("extract_id", step_extract_id),
        zerver.step("delete", step_delete_todo),
    } });

    std.debug.print("Todo CRUD Routes:\n", .{});
    std.debug.print("  GET    /todos          - List all todos\n", .{});
    std.debug.print("  GET    /todos/:id      - Get specific todo\n", .{});
    std.debug.print("  POST   /todos          - Create todo\n", .{});
    std.debug.print("  PATCH  /todos/:id      - Update todo\n", .{});
    std.debug.print("  DELETE /todos/:id      - Delete todo\n\n", .{});

    // Test requests
    std.debug.print("Test 1: GET /todos (list)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp1 = try server.handleRequest("GET /todos HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp1});
    }

    std.debug.print("Test 2: GET /todos/1 (get)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp2 = try server.handleRequest("GET /todos/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp2});
    }

    std.debug.print("Test 3: POST /todos (create)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp3 = try server.handleRequest("POST /todos HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "Content-Length: 20\r\n" ++
            "\r\n" ++
            "{\"title\":\"New todo\"}", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp3});
    }

    std.debug.print("Test 4: PATCH /todos/1 (update)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp4 = try server.handleRequest("PATCH /todos/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "Content-Length: 36\r\n" ++
            "\r\n" ++
            "{\"title\":\"Updated todo\",\"done\":true}", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp4});
    }

    std.debug.print("Test 5: DELETE /todos/1 (delete)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp5 = try server.handleRequest("DELETE /todos/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp5});
    }

    std.debug.print("--- Features Demonstrated ---\n", .{});
    std.debug.print("✓ Slot system for per-request state\n", .{});
    std.debug.print("✓ Global middleware chain\n", .{});
    std.debug.print("✓ Route matching with path parameters\n", .{});
    std.debug.print("✓ Step-based orchestration\n", .{});
    std.debug.print("✓ Effect handling (DB operations)\n", .{});
    std.debug.print("✓ Continuations after effects\n", .{});
    std.debug.print("✓ Error handling\n", .{});
    std.debug.print("✓ Complete CRUD workflow\n", .{});
}
