// src/zupervisor/slot_effect_integration_test.zig
/// Integration tests for slot-effect DLL system
/// Tests the complete pipeline from route registration to execution

const std = @import("std");
const testing = std.testing;
const slot_effect = @import("slot_effect.zig");
const slot_effect_dll = @import("slot_effect_dll.zig");
const route_registry = @import("route_registry.zig");

// ============================================================================
// Test slot schema
// ============================================================================

const TestSlot = enum {
    input_data,
    processed_data,
    output_data,
};

fn testSlotType(comptime slot: TestSlot) type {
    return switch (slot) {
        .input_data => []const u8,
        .processed_data => u32,
        .output_data => []const u8,
    };
}

const TestSchema = slot_effect.SlotSchema(TestSlot, testSlotType);

// ============================================================================
// Test handlers
// ============================================================================

/// Simple step that reads input and writes processed data
fn processStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = TestSlot,
        .slotTypeFn = testSlotType,
        .reads = &[_]TestSlot{.input_data},
        .writes = &[_]TestSlot{.processed_data},
    });

    var view = Ctx{ .base = ctx };

    const input = try view.require(.input_data);
    const value: u32 = @intCast(input.len);

    try view.put(.processed_data, value);

    return slot_effect.continue_();
}

/// Step that generates output from processed data
fn outputStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = TestSlot,
        .slotTypeFn = testSlotType,
        .reads = &[_]TestSlot{.processed_data},
        .writes = &[_]TestSlot{.output_data},
    });

    var view = Ctx{ .base = ctx };

    const value = try view.require(.processed_data);
    const output = try std.fmt.allocPrint(ctx.allocator, "Processed: {d}", .{value});

    try view.put(.output_data, output);

    const response = slot_effect.Response{
        .status = 200,
        .headers = slot_effect.Response.Headers.init(ctx.allocator),
        .body = slot_effect.Body{ .text = output },
    };

    return slot_effect.done(response);
}

/// Test handler function for DLL interface
fn testHandler(
    server: *const slot_effect_dll.SlotEffectServerAdapter,
    request: *anyopaque,
    response: *anyopaque,
) callconv(.c) c_int {
    _ = server;
    _ = request;
    _ = response;
    // Simplified - would normally execute pipeline here
    return 0;
}

// ============================================================================
// Integration tests
// ============================================================================

test "SlotEffectBridge - full lifecycle" {
    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    // Create context
    const ctx = try bridge.createContext("test-req-001");
    defer bridge.destroyContext(ctx);

    // Verify context is initialized
    try testing.expect(ctx.slots.count() == 0);
    try testing.expectEqualStrings("test-req-001", ctx.request_id);
}

test "SlotEffectBridge - context initialization via adapter" {
    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    var dummy_router: u32 = 0;
    const adapter = bridge.buildAdapter(@ptrCast(&dummy_router));

    // Create context via adapter function
    const ctx_ptr = adapter.createSlotContext.?(
        adapter.runtime_resources,
        "test-req-002",
        12,
    );

    try testing.expect(ctx_ptr != null);

    // Cleanup
    if (adapter.destroySlotContext) |destroy| {
        destroy(ctx_ptr.?);
    }
}

test "RouteRegistry - mixed route types" {
    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register step-based route
    const StepHandler = struct {
        fn handle(_: *anyopaque, _: *anyopaque) callconv(.c) c_int {
            return 0;
        }
    };

    try registry.registerStepRoute(.GET, "/api/legacy", StepHandler.handle);

    // Register slot-effect route
    try registry.registerSlotEffectRoute(
        .POST,
        "/api/slot-effect",
        testHandler,
        .{
            .description = "Slot-effect endpoint",
            .max_body_size = 2048,
            .timeout_ms = 5000,
            .requires_auth = false,
        },
    );

    try testing.expect(registry.count() == 2);

    // Verify routes can be found
    const legacy_route = registry.findRoute(.GET, "/api/legacy");
    try testing.expect(legacy_route != null);
    try testing.expect(legacy_route.?.handler == .step_pipeline);

    const slot_route = registry.findRoute(.POST, "/api/slot-effect");
    try testing.expect(slot_route != null);
    try testing.expect(slot_route.?.handler == .slot_effect);
    try testing.expect(slot_route.?.metadata != null);
}

test "RouteRegistry - DLL route registration" {
    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    // Simulate DLL-exported routes
    const dll_routes = [_]slot_effect_dll.SlotEffectRoute{
        .{
            .method = 0, // GET
            .path = "/api/users",
            .path_len = 10,
            .handler = testHandler,
            .metadata = null,
        },
        .{
            .method = 1, // POST
            .path = "/api/users",
            .path_len = 10,
            .handler = testHandler,
            .metadata = null,
        },
    };

    try registry.registerDllRoutes(&dll_routes);
    try testing.expect(registry.count() == 2);
}

test "Dispatcher - route dispatch" {
    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    var dispatcher = route_registry.Dispatcher.init(testing.allocator, &registry, &bridge);

    // Register a test route
    try registry.registerSlotEffectRoute(
        .GET,
        "/api/test",
        testHandler,
        null,
    );

    // Mock request/response
    var dummy_request: u32 = 0;
    var dummy_response: u32 = 0;

    const result = try dispatcher.dispatch(
        .GET,
        "/api/test",
        @ptrCast(&dummy_request),
        @ptrCast(&dummy_response),
    );

    try testing.expect(result == 0);
}

test "Dispatcher - 404 handling" {
    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    var dispatcher = route_registry.Dispatcher.init(testing.allocator, &registry, &bridge);

    var dummy_request: u32 = 0;
    var dummy_response: u32 = 0;

    const result = dispatcher.dispatch(
        .GET,
        "/api/nonexistent",
        @ptrCast(&dummy_request),
        @ptrCast(&dummy_response),
    );

    try testing.expectError(error.RouteNotFound, result);
}

test "Integration - pipeline execution with bridge" {
    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    const ctx = try bridge.createContext("test-pipeline-001");
    defer bridge.destroyContext(ctx);

    // Set up initial slot
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = TestSlot,
        .slotTypeFn = testSlotType,
        .reads = &[_]TestSlot{},
        .writes = &[_]TestSlot{.input_data},
    });

    var view = Ctx{ .base = ctx };
    try view.put(.input_data, "Hello, World!");

    // Execute process step
    const decision1 = try processStep(ctx);
    try testing.expect(decision1 == .Continue);

    // Execute output step
    const decision2 = try outputStep(ctx);
    try testing.expect(decision2 == .Done);

    // Verify response
    const response = decision2.Done;
    try testing.expect(response.status == 200);
    try testing.expectEqualStrings("Processed: 13", response.body.text);
}

test "Integration - error handling in pipeline" {
    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    const ctx = try bridge.createContext("test-error-001");
    defer bridge.destroyContext(ctx);

    // Try to execute step without required slot
    const result = processStep(ctx);
    try testing.expectError(error.SlotNotFound, result);
}

test "Integration - multiple request contexts" {
    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    // Create multiple contexts
    const ctx1 = try bridge.createContext("req-001");
    const ctx2 = try bridge.createContext("req-002");
    const ctx3 = try bridge.createContext("req-003");

    defer {
        bridge.destroyContext(ctx3);
        bridge.destroyContext(ctx2);
        bridge.destroyContext(ctx1);
    }

    // Each context should be independent
    try testing.expectEqualStrings("req-001", ctx1.request_id);
    try testing.expectEqualStrings("req-002", ctx2.request_id);
    try testing.expectEqualStrings("req-003", ctx3.request_id);
}

test "Integration - concurrent route lookups" {
    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register multiple routes
    try registry.registerSlotEffectRoute(.GET, "/api/route1", testHandler, null);
    try registry.registerSlotEffectRoute(.GET, "/api/route2", testHandler, null);
    try registry.registerSlotEffectRoute(.GET, "/api/route3", testHandler, null);

    // Simulate concurrent lookups (single-threaded test)
    const r1 = registry.findRoute(.GET, "/api/route1");
    const r2 = registry.findRoute(.GET, "/api/route2");
    const r3 = registry.findRoute(.GET, "/api/route3");

    try testing.expect(r1 != null);
    try testing.expect(r2 != null);
    try testing.expect(r3 != null);
}

test "Integration - schema validation" {
    // Verify schema compiles and validates correctly
    TestSchema.verifyExhaustive();

    const input_id = TestSchema.slotId(.input_data);
    const processed_id = TestSchema.slotId(.processed_data);
    const output_id = TestSchema.slotId(.output_data);

    try testing.expect(input_id == 0);
    try testing.expect(processed_id == 1);
    try testing.expect(output_id == 2);

    const InputType = TestSchema.TypeOf(.input_data);
    try testing.expect(InputType == []const u8);
}
