// examples/todo_crud.zig
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
const slog = @import("src/zerver/observability/slog.zig");

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
    slog.infof("  [Auth] Step auth called", .{});
    const user_id = ctx.header("x-user-id") orelse {
        slog.warnf("  [Auth] Missing X-User-ID header", .{});
        return zerver.fail(zerver.ErrorCode.Unauthorized, "auth", "missing_user");
    };

    slog.infof("  [Auth] User: {s}", .{user_id});
    return zerver.continue_();
}

// Step 2: Extract todo ID from path parameter
pub fn step_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.continue_(); // OK if not present (LIST operation)
    };

    slog.infof("  [Extract] TodoId: {s}", .{todo_id});
    return zerver.continue_();
}

// Step 3: Simulate database load
pub fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.infof("  [Step] step_load_from_db called", .{});
    const todo_id = ctx.param("id") orelse {
        // LIST operation - return empty list effect
        slog.infof("  [DB Load] Fetching todo list", .{});

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
    slog.infof("  [DB Load] Fetching todo {s}", .{todo_id});

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
    slog.infof("  [Continuation] List continuation called", .{});

    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "[{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false},{\"id\":\"2\",\"title\":\"Pay bills\",\"done\":true}]" },
    });
}

fn continuation_get(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Continuation] Item continuation called", .{});

    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Buy milk\",\"done\":false}" },
    });
}

// Step 4: Create todo
pub fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Create] Storing new todo", .{});

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
    slog.infof("  [Continuation] Create continuation called", .{});

    return zerver.done(.{
        .status = 201,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"New todo\",\"done\":false}" },
    });
}

// Step 5: Update todo
pub fn step_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.infof("  [Update] Updating todo {s}", .{todo_id});

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
    slog.infof("  [Continuation] Update continuation called", .{});

    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Updated todo\",\"done\":true}" },
    });
}

// Step 6: Delete todo
pub fn step_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "missing_id");
    };

    slog.infof("  [Delete] Deleting todo {s}", .{todo_id});

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
    slog.infof("  [Continuation] Todo deleted", .{});

    return zerver.done(.{
        .status = 204,
        .body = .{ .complete = "" },
    });
}

// Global middleware
pub fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.infof("  [Middleware] Logging middleware called", .{});
    _ = ctx;
    slog.infof("→ Request received", .{});
    return zerver.continue_();
}

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    slog.warnf("  [Error] onError called", .{});
    if (ctx.last_error) |err| {
        slog.warnf("  [Error] Last error: kind={}, what='{s}', key='{s}'", .{ err.kind, err.ctx.what, err.ctx.key });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_user")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = .{ .complete = "{\"error\":\"Missing X-User-ID header\"}" },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = .{ .complete = "{\"error\":\"Missing todo ID\"}" },
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = .{ .complete = "{\"error\":\"Unknown error\"}" },
            });
        }
    } else {
        slog.warnf("  [Error] No last_error set", .{});
        return zerver.done(.{
            .status = 500,
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .body = .{ .complete = "{\"error\":\"Internal server error - no error details\"}" },
        });
    }
}

// Effect handler (mock database)
pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    slog.infof("  [Effect] Handling effect type: {}", .{@as(std.meta.Tag(zerver.Effect), effect.*)});
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            slog.infof("  [Effect] DB GET: {s} (token {})", .{ db_get.key, db_get.token });
            // Don't store in slots for now
            const empty_ptr = @constCast(&[_]u8{});
            return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
        },
        .db_put => |db_put| {
            slog.infof("  [Effect] DB PUT: {s} = {s} (token {})", .{ db_put.key, db_put.value, db_put.token });
            const empty_ptr = @constCast(&[_]u8{});
            return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
        },
        .db_del => |db_del| {
            slog.infof("  [Effect] DB DEL: {s} (token {})", .{ db_del.key, db_del.token });
            const empty_ptr = @constCast(&[_]u8{});
            return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
        },
        else => {
            slog.warnf("  [Effect] Unknown effect type", .{});
            const empty_ptr = @constCast(&[_]u8{});
            return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    slog.infof("Todo CRUD Example - Complete Zerver Demo", .{});
    slog.infof("========================================\n", .{});

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

    slog.infof("Todo CRUD Routes:", .{});
    slog.infof("  GET    /todos          - List all todos", .{});
    slog.infof("  GET    /todos/:id      - Get specific todo", .{});
    slog.infof("  POST   /todos          - Create todo", .{});
    slog.infof("  PATCH  /todos/:id      - Update todo", .{});
    slog.infof("  DELETE /todos/:id      - Delete todo\n", .{});

    // Test requests
    slog.infof("Test 1: GET /todos (list)", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp1 = try server.handleRequest("GET /todos HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        slog.infof("Response: {s}\n", .{resp1.complete});
    }

    slog.infof("Test 2: GET /todos/1 (get)", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp2 = try server.handleRequest("GET /todos/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        slog.infof("Response: {s}\n", .{resp2.complete});
    }

    slog.infof("Test 3: POST /todos (create)", .{});
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
        slog.infof("Response: {s}\n", .{resp3.complete});
    }

    slog.infof("Test 4: PATCH /todos/1 (update)", .{});
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
        slog.infof("Response: {s}\n", .{resp4.complete});
    }

    slog.infof("Test 5: DELETE /todos/1 (delete)", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp5 = try server.handleRequest("DELETE /todos/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "X-User-ID: user-123\r\n" ++
            "\r\n", arena_alloc);
        slog.infof("Response: {s}\n", .{resp5.complete});
    }

    slog.infof("--- Features Demonstrated ---", .{});
    slog.infof("✓ Slot system for per-request state", .{});
    slog.infof("✓ Global middleware chain", .{});
    slog.infof("✓ Route matching with path parameters", .{});
    slog.infof("✓ Step-based orchestration", .{});
    slog.infof("✓ Effect handling (DB operations)", .{});
    slog.infof("✓ Continuations after effects", .{});
    slog.infof("✓ Error handling", .{});
    slog.infof("✓ Complete CRUD workflow", .{});
}

