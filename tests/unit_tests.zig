/// Unit Tests: Comprehensive test suite for core Zerver modules
/// Tests: router matching, executor decisions, effect handling, CtxView compile-time checks
const std = @import("std");
const zerver = @import("../src/zerver/root.zig");

// ============================================================================
// Router Tests
// ============================================================================

test "router: simple path matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = zerver.Router.init(allocator);
    defer router.deinit();

    const spec = zerver.RouteSpec{
        .before = &.{},
        .steps = &.{},
    };

    try router.addRoute(.GET, "/", spec);

    const match = try router.match(.GET, "/", allocator);
    try std.testing.expect(match != null);
}

test "router: path with parameters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = zerver.Router.init(allocator);
    defer router.deinit();

    const spec = zerver.RouteSpec{
        .before = &.{},
        .steps = &.{},
    };

    try router.addRoute(.GET, "/todos/:id", spec);

    const match = try router.match(.GET, "/todos/123", allocator);
    try std.testing.expect(match != null);

    if (match) |m| {
        const id = m.params.get("id");
        try std.testing.expect(id != null);
        if (id) |id_val| {
            try std.testing.expectEqualStrings(id_val, "123");
        }
    }
}

test "router: no match returns null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = zerver.Router.init(allocator);
    defer router.deinit();

    const spec = zerver.RouteSpec{
        .before = &.{},
        .steps = &.{},
    };

    try router.addRoute(.GET, "/", spec);

    const match = try router.match(.GET, "/nonexistent", allocator);
    try std.testing.expect(match == null);
}

test "router: method matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = zerver.Router.init(allocator);
    defer router.deinit();

    const spec = zerver.RouteSpec{
        .before = &.{},
        .steps = &.{},
    };

    try router.addRoute(.GET, "/", spec);

    // POST should not match GET route
    const match = try router.match(.POST, "/", allocator);
    try std.testing.expect(match == null);
}

// ============================================================================
// CtxBase Tests
// ============================================================================

test "ctx: slot storage and retrieval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // Store a string in a slot
    try ctx.slotPutString(0, "test_value");

    // Retrieve it
    const value = ctx.slotGetString(0);
    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings(v, "test_value");
    }
}

test "ctx: multiple slots" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx.slotPutString(0, "slot_0");
    try ctx.slotPutString(1, "slot_1");
    try ctx.slotPutString(2, "slot_2");

    try std.testing.expectEqualStrings(ctx.slotGetString(0).?, "slot_0");
    try std.testing.expectEqualStrings(ctx.slotGetString(1).?, "slot_1");
    try std.testing.expectEqualStrings(ctx.slotGetString(2).?, "slot_2");
}

test "ctx: missing slot returns null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const value = ctx.slotGetString(999);
    try std.testing.expect(value == null);
}

test "ctx: headers and parameters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx.headers.put("Authorization", "Bearer token123");
    try ctx.params.put("id", "456");

    try std.testing.expectEqualStrings(ctx.header("Authorization").?, "Bearer token123");
    try std.testing.expectEqualStrings(ctx.param("id").?, "456");
}

// ============================================================================
// Decision Tests
// ============================================================================

test "decision: Continue" {
    const dec = zerver.Decision{ .Continue = {} };
    try std.testing.expect(dec == .Continue);
}

test "decision: Done" {
    const dec = zerver.Decision{
        .Done = .{
            .status = 200,
            .body = "OK",
        },
    };
    try std.testing.expect(dec == .Done);
    try std.testing.expectEqual(dec.Done.status, 200);
}

test "decision: Fail" {
    const dec = zerver.Decision{
        .Fail = .{
            .kind = 404,
            .ctx = .{ .what = "todo", .key = "not_found" },
        },
    };
    try std.testing.expect(dec == .Fail);
    try std.testing.expectEqual(dec.Fail.kind, 404);
}

// ============================================================================
// Effect Tests
// ============================================================================

test "effect: DbGet creation" {
    const effect = zerver.Effect{
        .db_get = .{
            .key = "user:123",
            .token = 0,
            .timeout_ms = 300,
            .required = true,
        },
    };

    try std.testing.expect(effect == .db_get);
    try std.testing.expectEqualStrings(effect.db_get.key, "user:123");
    try std.testing.expectEqual(effect.db_get.token, 0);
}

test "effect: HttpGet creation" {
    const effect = zerver.Effect{
        .http_get = .{
            .url = "https://api.example.com/data",
            .token = 1,
            .timeout_ms = 5000,
            .required = true,
        },
    };

    try std.testing.expect(effect == .http_get);
    try std.testing.expectEqualStrings(effect.http_get.url, "https://api.example.com/data");
}

test "effect: DbPut with idempotency key" {
    const effect = zerver.Effect{
        .db_put = .{
            .key = "order:789",
            .value = "{}",
            .token = 2,
            .idem = "order_create_abc123",
            .required = true,
        },
    };

    try std.testing.expect(effect == .db_put);
    try std.testing.expectEqualStrings(effect.db_put.idem, "order_create_abc123");
}

// ============================================================================
// Executor Tests
// ============================================================================

fn dummy_effect_handler(_: *const zerver.Effect, _: u32) anyerror!zerver.executor.EffectResult {
    const empty_ptr = @constCast(&[_]u8{});
    return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
}

test "executor: init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var executor = zerver.Executor.init(allocator, dummy_effect_handler);
    _ = &executor;
}

// ============================================================================
// Tracer Tests
// ============================================================================

test "tracer: record events" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tracer = zerver.tracer.Tracer.init(allocator);
    defer tracer.deinit();

    tracer.recordRequestStart();
    tracer.recordStepStart("test_step");
    tracer.recordStepEnd("test_step", "Continue");
    tracer.recordRequestEnd();

    try std.testing.expect(tracer.events.items.len > 0);
}

test "tracer: to_json" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var tracer = zerver.tracer.Tracer.init(arena.allocator());
    defer tracer.deinit();

    tracer.recordRequestStart();
    tracer.recordRequestEnd();

    const json = try tracer.toJson(arena.allocator());
    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "events"));
}

// ============================================================================
// Error Tests
// ============================================================================

test "error: ErrorCode constants" {
    try std.testing.expectEqual(zerver.ErrorCode.InvalidInput, 400);
    try std.testing.expectEqual(zerver.ErrorCode.Unauthorized, 401);
    try std.testing.expectEqual(zerver.ErrorCode.Forbidden, 403);
    try std.testing.expectEqual(zerver.ErrorCode.NotFound, 404);
    try std.testing.expectEqual(zerver.ErrorCode.InternalError, 500);
}

// ============================================================================
// Response Tests
// ============================================================================

test "response: creation" {
    const resp = zerver.Response{
        .status = 200,
        .body = "Hello, World!",
    };

    try std.testing.expectEqual(resp.status, 200);
    try std.testing.expectEqualStrings(resp.body, "Hello, World!");
}

test "response: 404 error response" {
    const resp = zerver.Response{
        .status = 404,
        .body = "Not Found",
    };

    try std.testing.expectEqual(resp.status, 404);
}

// ============================================================================
// Helper Tests
// ============================================================================

test "helpers: continue_" {
    const dec = zerver.continue_();
    try std.testing.expect(dec == .Continue);
}

test "helpers: done" {
    const dec = zerver.done(.{ .status = 201, .body = "Created" });
    try std.testing.expect(dec == .Done);
    try std.testing.expectEqual(dec.Done.status, 201);
}

test "helpers: fail" {
    const dec = zerver.fail(500, "server", "crashed");
    try std.testing.expect(dec == .Fail);
    try std.testing.expectEqual(dec.Fail.kind, 500);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: ctx and slots together" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // Simulate a request flow
    try ctx.params.put("todo_id", "42");
    try ctx.slotPutString(0, "todo:42");
    try ctx.slotPutString(1, "{\"id\":\"42\",\"title\":\"test\"}");

    try std.testing.expectEqualStrings(ctx.param("todo_id").?, "42");
    try std.testing.expectEqualStrings(ctx.slotGetString(0).?, "todo:42");
    try std.testing.expectEqualStrings(ctx.slotGetString(1).?, "{\"id\":\"42\",\"title\":\"test\"}");
}

test "integration: effect lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Create an effect
    const effect = zerver.Effect{
        .db_get = .{
            .key = "user:100",
            .token = 5,
            .timeout_ms = 1000,
            .retry = .{
                .max = 3,
                .initial_backoff_ms = 50,
                .max_backoff_ms = 5000,
                .jitter_enabled = false,
            },
            .required = true,
        },
    };

    // Verify effect properties
    try std.testing.expect(effect == .db_get);
    try std.testing.expectEqual(effect.db_get.retry.max, 3);
    try std.testing.expectEqual(effect.db_get.timeout_ms, 1000);
}
