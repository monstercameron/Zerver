// examples/slot_effect_demo.zig
/// Minimal working example demonstrating the slot-effect pipeline architecture
/// Shows: slot schema → pipeline steps → execution → HTTP response

const std = @import("std");
const slot_effect = @import("slot_effect");
const slot_effect_dll = @import("../src/zupervisor/slot_effect_dll.zig");
const slot_effect_executor = @import("../src/zupervisor/slot_effect_executor.zig");

// ============================================================================
// 1. Define Slot Schema
// ============================================================================

/// Slots for a simple greeting API
const GreetingSlot = enum {
    name_param,          // Input: extracted from request
    greeting_message,    // Intermediate: constructed message
    timestamp,           // Intermediate: current time
    response_built,      // Final: marker that response is ready
};

/// Type mapping for each slot
fn greetingSlotType(comptime slot: GreetingSlot) type {
    return switch (slot) {
        .name_param => []const u8,
        .greeting_message => []const u8,
        .timestamp => i64,
        .response_built => bool,
    };
}

/// Schema instance for compile-time validation
const GreetingSchema = slot_effect.SlotSchema(GreetingSlot, greetingSlotType);

// ============================================================================
// 2. Define Pipeline Steps
// ============================================================================

/// Step 1: Extract name parameter from request
fn extractNameStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{},
        .writes = &[_]GreetingSlot{.name_param},
    });

    var view = Ctx{ .base = ctx };

    // In a real scenario, this would extract from HTTP request
    // For demo, we'll use a hardcoded value
    const name = "Alice";

    std.debug.print("[Step 1] Extracted name: {s}\n", .{name});
    try view.put(.name_param, name);

    return slot_effect.continue_();
}

/// Step 2: Build greeting message
fn buildGreetingStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{.name_param},
        .writes = &[_]GreetingSlot{.greeting_message, .timestamp},
    });

    var view = Ctx{ .base = ctx };

    // Read the name
    const name = try view.require(.name_param);

    // Get current timestamp
    const now = std.time.timestamp();
    try view.put(.timestamp, now);

    // Build greeting message
    const message = try std.fmt.allocPrint(
        ctx.allocator,
        "Hello, {s}! Welcome to the slot-effect demo.",
        .{name},
    );

    std.debug.print("[Step 2] Built message: {s}\n", .{message});
    try view.put(.greeting_message, message);

    return slot_effect.continue_();
}

/// Step 3: Build HTTP response (terminal step)
fn buildResponseStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{.greeting_message, .timestamp},
        .writes = &[_]GreetingSlot{.response_built},
    });

    var view = Ctx{ .base = ctx };

    // Read required data
    const message = try view.require(.greeting_message);
    const timestamp = try view.require(.timestamp);

    // Mark response as built
    try view.put(.response_built, true);

    // Build JSON response body
    const json_body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"message\":\"{s}\",\"timestamp\":{d}}}",
        .{ message, timestamp },
    );

    std.debug.print("[Step 3] Response JSON: {s}\n", .{json_body});

    // Create HTTP response
    var response = slot_effect.Response{
        .status = 200,
        .headers = slot_effect.Response.Headers.init(ctx.allocator),
        .body = slot_effect.Body{ .json = json_body },
    };

    // Add content-type header
    try response.headers.append(.{
        .name = "Content-Type",
        .value = "application/json",
    });

    return slot_effect.done(response);
}

// ============================================================================
// 3. Main Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Slot-Effect Pipeline Demo ===\n\n", .{});

    // Verify schema exhaustiveness (compile-time check)
    GreetingSchema.verifyExhaustive();
    std.debug.print("✓ Schema verified: all slots have types\n\n", .{});

    // Initialize bridge and executor
    var bridge = try slot_effect_dll.SlotEffectBridge.init(allocator);
    defer bridge.deinit();

    var executor = slot_effect_executor.PipelineExecutor.init(allocator, &bridge);

    // Create context for request
    const ctx = try bridge.createContext("demo-request-001");
    defer bridge.destroyContext(ctx);

    std.debug.print("✓ Created request context: {s}\n\n", .{ctx.request_id});

    // Define pipeline
    const pipeline_steps = [_]slot_effect.StepFn{
        extractNameStep,
        buildGreetingStep,
        buildResponseStep,
    };

    std.debug.print("✓ Pipeline defined with {d} steps\n\n", .{pipeline_steps.len});
    std.debug.print("--- Executing Pipeline ---\n\n", .{});

    // Execute pipeline
    const response = try executor.execute(ctx, &pipeline_steps);

    std.debug.print("\n--- Pipeline Complete ---\n\n", .{});
    std.debug.print("Final Response:\n", .{});
    std.debug.print("  Status: {d}\n", .{response.status});
    std.debug.print("  Headers: {d}\n", .{response.headers.items.len});
    for (response.headers.items) |header| {
        std.debug.print("    {s}: {s}\n", .{ header.name, header.value });
    }
    std.debug.print("  Body: {s}\n", .{response.body.json});

    std.debug.print("\n=== Demo Complete ===\n\n", .{});
    std.debug.print("Key Features Demonstrated:\n", .{});
    std.debug.print("  ✓ Type-safe slot operations with compile-time validation\n", .{});
    std.debug.print("  ✓ Pure pipeline steps (no side effects)\n", .{});
    std.debug.print("  ✓ Context-based slot storage\n", .{});
    std.debug.print("  ✓ HTTP response building\n", .{});
    std.debug.print("  ✓ Pipeline executor with iteration limits\n", .{});
    std.debug.print("\n", .{});
}
