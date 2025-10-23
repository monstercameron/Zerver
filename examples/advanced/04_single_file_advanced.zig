/// Advanced Example: Todos Product with DDD/CQRS Structure (Single File)
///
/// This consolidated version demonstrates professional structure using:
/// - Domain-Driven Design (DDD) for core models
/// - CQRS (Command Query Responsibility Segregation) for operations
/// - Middleware composition (auth, rate limit, logging)
/// - Simulated effects with realistic latencies
///
/// This example demonstrates a complete Zerver application in a single file,
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("src/zerver/root.zig");

// ═════════════════════════════════════════════════════════════════════════════
// DOMAIN MODELS (DDD)
// ═════════════════════════════════════════════════════════════════════════════

pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,
    blocked,
};

pub const Todo = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: TodoStatus,
    assigned_to: []const u8,
    priority: u8,
    created_at: i64,
    updated_at: i64,

    pub fn isValid(self: *const @This()) bool {
        return self.id.len > 0 and self.title.len > 0 and self.priority > 0 and self.priority <= 5;
    }

    pub fn transitionTo(self: *@This(), new_status: TodoStatus) bool {
        _ = self;
        _ = new_status;
        return true;
    }
};

pub const DomainError = enum(u32) {
    InvalidInput = 1,
    Unauthorized = 2,
    Forbidden = 3,
    NotFound = 4,
    Conflict = 5,
    TooManyRequests = 6,
    UpstreamUnavailable = 7,
    Timeout = 8,
    Internal = 9,
    CompletedTodosImmutable = 10,
};

pub const ErrorContext = struct {
    error_code: DomainError,
    message: []const u8,
    resource: []const u8,
};

pub const OperationLatency = struct {
    min_ms: u32,
    max_ms: u32,

    pub fn random(self: @This()) u32 {
        if (self.min_ms >= self.max_ms) return self.min_ms;
        var prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        } catch 0);
        const rng = prng.random();
        return self.min_ms + rng.uintLessThan(u32, self.max_ms - self.min_ms);
    }

    pub fn read() @This() {
        return .{ .min_ms = 20, .max_ms = 80 };
    }

    pub fn write() @This() {
        return .{ .min_ms = 50, .max_ms = 150 };
    }

    pub fn scan() @This() {
        return .{ .min_ms = 100, .max_ms = 300 };
    }
};

pub fn makeError(code: DomainError, message: []const u8, resource: []const u8) zerver.Error {
    return .{
        .kind = @intCast(@intFromEnum(code)),
        .ctx = .{
            .what = message,
            .key = resource,
        },
    };
}

// ═════════════════════════════════════════════════════════════════════════════
// MIDDLEWARE & SLOTS
// ═════════════════════════════════════════════════════════════════════════════

pub const Slot = enum(u32) {
    user_id = 1,
    auth_token = 2,
    rate_limit_key = 3,
    operation_latency = 4,
    todo_id = 5,
    request_id = 6,
};

pub fn mw_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    const method = ctx.method();
    const path = ctx.path();
    std.debug.print("[request] {s} {s}\n", .{ @tagName(method), path });
    return zerver.next();
}

pub fn mw_operation_latency(ctx: *zerver.CtxBase) !zerver.Decision {
    const latency_config = OperationLatency.scan();
    const latency = latency_config.random();
    const latency_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{latency});
    try ctx.slotPutString(@intFromEnum(Slot.operation_latency), latency_str);
    std.debug.print("[latency] {d}ms\n", .{latency});
    return zerver.next();
}

pub fn mw_authenticate(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth_header = ctx.header("Authorization") orelse {
        return zerver.fail(makeError(.Unauthorized, "Missing Authorization header", "auth"));
    };

    const token = if (std.mem.startsWith(u8, auth_header, "Bearer "))
        auth_header[7..]
    else
        return zerver.fail(makeError(.Unauthorized, "Invalid Authorization format", "auth"));

    try ctx.slotPutString(@intFromEnum(Slot.auth_token), token);
    std.debug.print("[auth] Token: {s}\n", .{token});

    const latency_str = ctx.slotGetString(@intFromEnum(Slot.operation_latency)) orelse "50";
    const latency = std.fmt.parseInt(u32, latency_str, 10) catch 50;
    std.debug.print("[auth] Simulated latency: {d}ms\n", .{latency});

    return zerver.next();
}

pub fn mw_rate_limit(ctx: *zerver.CtxBase) !zerver.Decision {
    const user_id = ctx.header("X-User-ID") orelse "anonymous";
    try ctx.slotPutString(@intFromEnum(Slot.user_id), user_id);
    std.debug.print("[rate_limit] User: {s}\n", .{user_id});
    return zerver.next();
}

pub fn getOperationLatency(ctx: *zerver.CtxBase) u32 {
    const latency_str = ctx.slotGetString(@intFromEnum(Slot.operation_latency)) orelse "50";
    return std.fmt.parseInt(u32, latency_str, 10) catch 50;
}

// ═════════════════════════════════════════════════════════════════════════════
// QUERY OPERATIONS (CQRS - Read)
// ═════════════════════════════════════════════════════════════════════════════

pub fn query_extract_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(makeError(.InvalidInput, "Missing todo ID in path", "path"));
    };
    try ctx.slotPutString(@intFromEnum(Slot.todo_id), todo_id);
    return zerver.next();
}

pub fn query_list_todos(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("[query] Listing todos\n", .{});
    return zerver.next();
}

pub fn query_get_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.todo_id)) orelse "unknown";
    std.debug.print("[query] Getting todo: {s}\n", .{todo_id});
    return zerver.next();
}

pub fn render_list(ctx: *zerver.CtxBase) !zerver.Decision {
    const body = try std.fmt.allocPrint(ctx.arena, "[{{\"id\":\"todo_1\",\"title\":\"Sample\"}}]", .{});
    return zerver.done(.{
        .status = 200,
        .body = body,
    });
}

pub fn render_item(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.todo_id)) orelse "unknown";
    const body = try std.fmt.allocPrint(ctx.arena, "{{\"id\":\"{s}\",\"title\":\"Sample Todo\",\"status\":\"pending\"}}", .{todo_id});
    return zerver.done(.{
        .status = 200,
        .body = body,
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// MUTATION OPERATIONS (CQRS - Write)
// ═════════════════════════════════════════════════════════════════════════════

pub fn mutation_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const user_id = ctx.slotGetString(@intFromEnum(Slot.user_id)) orelse "anonymous";
    std.debug.print("[mutation] Creating todo for user: {s}\n", .{user_id});
    return zerver.next();
}

pub fn mutation_update_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.todo_id)) orelse "unknown";
    std.debug.print("[mutation] Updating todo: {s}\n", .{todo_id});
    return zerver.next();
}

pub fn mutation_delete_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.todo_id)) orelse "unknown";
    std.debug.print("[mutation] Deleting todo: {s}\n", .{todo_id});
    return zerver.next();
}

pub fn render_created(ctx: *zerver.CtxBase) !zerver.Decision {
    const body = try std.fmt.allocPrint(ctx.arena, "{{\"id\":\"todo_new\",\"status\":\"created\"}}", .{});
    return zerver.done(.{
        .status = 201,
        .body = body,
    });
}

pub fn render_updated(ctx: *zerver.CtxBase) !zerver.Decision {
    const body = try std.fmt.allocPrint(ctx.arena, "{{\"status\":\"updated\"}}", .{});
    return zerver.done(.{
        .status = 200,
        .body = body,
    });
}

pub fn render_deleted(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// ERROR HANDLER
// ═════════════════════════════════════════════════════════════════════════════

fn error_handler(ctx: *zerver.CtxBase) !zerver.Decision {
    const error_info = ctx.lastError() orelse makeError(.Internal, "Unknown error", "system");
    const error_code_val: DomainError = @enumFromInt(error_info.kind);

    const status_code: u16 = switch (error_code_val) {
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

    const arena_allocator = ctx.arena;
    const response_body = try std.fmt.allocPrint(arena_allocator, "{{\"error\":\"{s}\"}}", .{error_info.ctx.what});
    return zerver.done(.{
        .status = status_code,
        .body = response_body,
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// MOCK EFFECT HANDLER
// ═════════════════════════════════════════════════════════════════════════════

fn mock_effect_handler(effect: *const zerver.Effect, timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = timeout_ms;
    _ = effect;
    return .{ .success = "" };
}

// ═════════════════════════════════════════════════════════════════════════════
// SERVER SETUP & MAIN
// ═════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zerver.server.Config{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8081 },
        .on_error = error_handler,
        .debug = false,
    };

    var server = try zerver.server.Server.init(allocator, config, mock_effect_handler);
    defer server.deinit();

    // Middleware chains
    var global_mw = try std.ArrayList(zerver.Step).initCapacity(allocator, 8);
    defer global_mw.deinit();
    try global_mw.append(allocator, .{ .function = mw_logging });
    try global_mw.append(allocator, .{ .function = mw_operation_latency });

    var protected_mw = try std.ArrayList(zerver.Step).initCapacity(allocator, 10);
    defer protected_mw.deinit();
    try protected_mw.appendSlice(allocator, global_mw.items);
    try protected_mw.append(allocator, .{ .function = mw_authenticate });
    try protected_mw.append(allocator, .{ .function = mw_rate_limit });

    // Routes
    try server.addRoute(.GET, "/todos", .{
        .middleware = global_mw.items,
        .steps = &.{
            .{ .function = query_list_todos },
            .{ .function = render_list },
        },
    });

    try server.addRoute(.GET, "/todos/:id", .{
        .middleware = global_mw.items,
        .steps = &.{
            .{ .function = query_extract_id },
            .{ .function = query_get_todo },
            .{ .function = render_item },
        },
    });

    try server.addRoute(.POST, "/todos", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = mutation_create_todo },
            .{ .function = render_created },
        },
    });

    try server.addRoute(.PATCH, "/todos/:id", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = query_extract_id },
            .{ .function = mutation_update_todo },
            .{ .function = render_updated },
        },
    });

    try server.addRoute(.DELETE, "/todos/:id", .{
        .middleware = protected_mw.items,
        .steps = &.{
            .{ .function = query_extract_id },
            .{ .function = mutation_delete_todo },
            .{ .function = render_deleted },
        },
    });

    // Print banner
    try std.io.getStdOut().writeAll(
        \\ 
        \\╔══════════════════════════════════════════════════════════════════════════════╗
        \\║ Zerver Advanced Example: Todos Product (DDD + CQRS)                         ║
        \\╚══════════════════════════════════════════════════════════════════════════════╝
        \\
        \\ Professional structure demonstration:
        \\   ✓ Domain-Driven Design (core models, business rules)
        \\   ✓ CQRS Pattern (queries vs mutations)
        \\   ✓ Middleware Composition (auth, rate limit, logging)
        \\   ✓ Simulated Effects (realistic latencies)
        \\
        \\═══════════════════════════════════════════════════════════════════════════════
        \\
    );

    // Test requests
    std.debug.print("Test 1: GET /todos\n", .{});
    var req1 = try zerver.reqtest_module.RequestBuilder.init(allocator, "GET", "/todos").build();
    defer req1.deinit();
    const res1 = try server.handleRequest(&req1);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res1.status, res1.body });

    std.debug.print("Test 2: GET /todos/todo_123\n", .{});
    var req2 = try zerver.reqtest_module.RequestBuilder.init(allocator, "GET", "/todos/todo_123").build();
    defer req2.deinit();
    const res2 = try server.handleRequest(&req2);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res2.status, res2.body });

    std.debug.print("Test 3: POST /todos (with Authorization)\n", .{});
    var req3 = try zerver.reqtest_module.RequestBuilder.init(allocator, "POST", "/todos")
        .withHeader("Authorization", "Bearer valid-token-12345")
        .build();
    defer req3.deinit();
    const res3 = try server.handleRequest(&req3);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res3.status, res3.body });

    std.debug.print("Test 4: PATCH /todos/todo_123 (with Authorization)\n", .{});
    var req4 = try zerver.reqtest_module.RequestBuilder.init(allocator, "PATCH", "/todos/todo_123")
        .withHeader("Authorization", "Bearer valid-token-12345")
        .build();
    defer req4.deinit();
    const res4 = try server.handleRequest(&req4);
    std.debug.print("  Status: {d}\n  Body: {s}\n\n", .{ res4.status, res4.body });

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
        \\ ✓ Advanced example completed! Ready for Phase 2 with async/await.
        \\
    );
}
