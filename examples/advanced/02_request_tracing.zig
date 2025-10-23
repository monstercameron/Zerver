/// This example demonstrates how to use the Zerver tracer for recording and exporting request traces.
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("zerver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Trace Recording Example\n", .{});
    std.debug.print("======================\n\n", .{});

    var tracer = zerver.Tracer.init(allocator);
    defer tracer.deinit();

    // Record a simulated request trace
    std.debug.print("Recording events...\n", .{});
    tracer.recordRequestStart();

    tracer.recordStepStart("authenticate");
    std.time.sleep(5 * std.time.ns_per_ms);
    tracer.recordStepEnd("authenticate", "Continue");

    tracer.recordStepStart("fetch_data");
    tracer.recordEffectStart("db_get");
    std.time.sleep(10 * std.time.ns_per_ms);
    tracer.recordEffectEnd("db_get", true);
    tracer.recordStepEnd("fetch_data", "Continue");

    tracer.recordStepStart("process");
    tracer.recordEffectStart("http_post");
    std.time.sleep(15 * std.time.ns_per_ms);
    tracer.recordEffectEnd("http_post", true);
    tracer.recordStepEnd("process", "Done");

    tracer.recordRequestEnd();

    std.debug.print("\nTrace has {} events\n\n", .{tracer.events.items.len});

    // Export as JSON
    var trace_arena = std.heap.ArenaAllocator.init(allocator);
    defer trace_arena.deinit();

    const json = try tracer.toJson(trace_arena.allocator());
    std.debug.print("JSON Export:\n", .{});
    std.debug.print("{s}\n", .{json});

    std.debug.print("\n--- Tracer Features ---\n", .{});
    std.debug.print("✓ Records step start/end events\n", .{});
    std.debug.print("✓ Records effect start/end events\n", .{});
    std.debug.print("✓ Captures event timestamps\n", .{});
    std.debug.print("✓ Tracks step outcomes (Continue/Done/Fail)\n", .{});
    std.debug.print("✓ Exports complete trace as JSON\n", .{});
    std.debug.print("✓ Enables observability for debugging\n", .{});
}
