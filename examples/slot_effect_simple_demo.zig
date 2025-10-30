// examples/slot_effect_simple_demo.zig
/// Minimal self-contained demonstration of slot-effect core concepts
/// Shows: slot schema → pipeline steps → pure execution

const std = @import("std");
const slot_effect = @import("slot_effect");

// ============================================================================
// 1. Define Slot Schema
// ============================================================================

/// Slots for a simple calculator pipeline
const CalcSlot = enum {
    input_a,      // First number
    input_b,      // Second number
    operation,    // Operation to perform
    result,       // Calculated result
    formatted,    // Formatted output string
};

/// Type mapping for each slot
fn calcSlotType(comptime slot: CalcSlot) type {
    return switch (slot) {
        .input_a => f64,
        .input_b => f64,
        .operation => []const u8,
        .result => f64,
        .formatted => []const u8,
    };
}

/// Schema instance for compile-time validation
const CalcSchema = slot_effect.SlotSchema(CalcSlot, calcSlotType);

// ============================================================================
// 2. Define Pipeline Steps
// ============================================================================

/// Step 1: Initialize inputs
fn initializeStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = CalcSlot,
        .slotTypeFn = calcSlotType,
        .reads = &[_]CalcSlot{},
        .writes = &[_]CalcSlot{ .input_a, .input_b, .operation },
    });

    var view = Ctx{ .base = ctx };

    // Set input values
    try view.put(.input_a, 42.0);
    try view.put(.input_b, 8.0);
    try view.put(.operation, "add");

    std.debug.print("[Step 1] Initialized: a=42.0, b=8.0, op=add\n", .{});
    return slot_effect.continue_();
}

/// Step 2: Perform calculation
fn calculateStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = CalcSlot,
        .slotTypeFn = calcSlotType,
        .reads = &[_]CalcSlot{ .input_a, .input_b, .operation },
        .writes = &[_]CalcSlot{.result},
    });

    var view = Ctx{ .base = ctx };

    const a = try view.require(.input_a);
    const b = try view.require(.input_b);
    const op = try view.require(.operation);

    const result = if (std.mem.eql(u8, op, "add"))
        a + b
    else if (std.mem.eql(u8, op, "subtract"))
        a - b
    else if (std.mem.eql(u8, op, "multiply"))
        a * b
    else if (std.mem.eql(u8, op, "divide"))
        a / b
    else
        return slot_effect.fail(.InvalidInput, "operation", "Unknown operation");

    try view.put(.result, result);

    std.debug.print("[Step 2] Calculated: {d} {s} {d} = {d}\n", .{ a, op, b, result });
    return slot_effect.continue_();
}

/// Step 3: Format result and return response
fn formatStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = CalcSlot,
        .slotTypeFn = calcSlotType,
        .reads = &[_]CalcSlot{ .input_a, .input_b, .operation, .result },
        .writes = &[_]CalcSlot{.formatted},
    });

    var view = Ctx{ .base = ctx };

    const a = try view.require(.input_a);
    const b = try view.require(.input_b);
    const op = try view.require(.operation);
    const result = try view.require(.result);

    const formatted = try std.fmt.allocPrint(
        ctx.allocator,
        "{d} {s} {d} = {d}",
        .{ a, op, b, result },
    );

    try view.put(.formatted, formatted);

    std.debug.print("[Step 3] Formatted: {s}\n", .{formatted});

    // Build HTTP response
    const json_body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"result\":{d},\"expression\":\"{s}\"}}",
        .{ result, formatted },
    );

    var response = slot_effect.Response.init(
        200,
        slot_effect.Body{ .complete = json_body },
    );

    try response.addHeader(ctx.allocator, "Content-Type", "application/json");

    return slot_effect.done(response);
}

// ============================================================================
// 3. Simple Pipeline Executor
// ============================================================================

fn executePipeline(
    allocator: std.mem.Allocator,
    ctx: *slot_effect.CtxBase,
    steps: []const slot_effect.StepSpec,
) !slot_effect.Response {
    var interpreter = slot_effect.Interpreter.init(steps);

    const decision = try interpreter.evalUntilNeedOrDone(ctx);

    return switch (decision) {
        .Done => |response| response,
        .Fail => |err| blk: {
            std.debug.print("Pipeline failed: {s} (code {s})\n", .{ err.reason, err.code });

            const error_json = try std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"{s}\",\"code\":\"{s}\"}}",
                .{ err.reason, err.code },
            );

            var response = slot_effect.Response.init(
                400, // Bad Request for validation/input errors
                slot_effect.Body{ .complete = error_json },
            );

            try response.addHeader(allocator, "Content-Type", "application/json");

            break :blk response;
        },
        .need => |_| {
            return error.UnexpectedEffect;
        },
        .Continue => {
            return error.UnexpectedContinue;
        },
    };
}

// ============================================================================
// 4. Main Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Slot-Effect Simple Demo ===\n\n", .{});

    // Verify schema exhaustiveness (compile-time check)
    CalcSchema.verifyExhaustive();
    std.debug.print("✓ Schema verified: all slots have types\n\n", .{});

    // Create context
    var ctx = try slot_effect.CtxBase.init(allocator, "calc-001");
    defer ctx.deinit();

    std.debug.print("✓ Created context: {s}\n\n", .{ctx.request_id});

    // Define pipeline with step metadata
    const pipeline_steps = [_]slot_effect.StepSpec{
        .{
            .name = "initialize",
            .fn_ptr = initializeStep,
            .reads = &[_]u32{},
            .writes = &[_]u32{ @intFromEnum(CalcSlot.input_a), @intFromEnum(CalcSlot.input_b), @intFromEnum(CalcSlot.operation) },
        },
        .{
            .name = "calculate",
            .fn_ptr = calculateStep,
            .reads = &[_]u32{ @intFromEnum(CalcSlot.input_a), @intFromEnum(CalcSlot.input_b), @intFromEnum(CalcSlot.operation) },
            .writes = &[_]u32{ @intFromEnum(CalcSlot.result) },
        },
        .{
            .name = "format",
            .fn_ptr = formatStep,
            .reads = &[_]u32{ @intFromEnum(CalcSlot.input_a), @intFromEnum(CalcSlot.input_b), @intFromEnum(CalcSlot.operation), @intFromEnum(CalcSlot.result) },
            .writes = &[_]u32{ @intFromEnum(CalcSlot.formatted) },
        },
    };

    std.debug.print("✓ Pipeline defined with {d} steps\n\n", .{pipeline_steps.len});
    std.debug.print("--- Executing Pipeline ---\n\n", .{});

    // Execute pipeline
    const response = try executePipeline(allocator, &ctx, &pipeline_steps);

    std.debug.print("\n--- Pipeline Complete ---\n\n", .{});
    std.debug.print("Final Response:\n", .{});
    std.debug.print("  Status: {d}\n", .{response.status});
    std.debug.print("  Headers: {d}\n", .{response.headers_count});
    for (response.headers_inline[0..response.headers_count]) |maybe_header| {
        if (maybe_header) |header| {
            std.debug.print("    {s}: {s}\n", .{ header.name, header.value });
        }
    }
    const body_content = switch (response.body) {
        .complete => |content| content,
        .streaming => "(streaming)",
    };
    std.debug.print("  Body: {s}\n", .{body_content});

    std.debug.print("\n=== Demo Complete ===\n\n", .{});
    std.debug.print("Key Features Demonstrated:\n", .{});
    std.debug.print("  ✓ Type-safe slot operations (compile-time validation)\n", .{});
    std.debug.print("  ✓ Pure pipeline steps (no side effects)\n", .{});
    std.debug.print("  ✓ Context-based slot storage\n", .{});
    std.debug.print("  ✓ HTTP response building\n", .{});
    std.debug.print("  ✓ Error handling with Fail decision\n", .{});
    std.debug.print("\n", .{});
}
