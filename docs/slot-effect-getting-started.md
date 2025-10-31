# Getting Started with Slot-Effect Pipelines

**A step-by-step guide to building type-safe, testable request handlers with the slot-effect architecture**

## Table of Contents

1. [What is Slot-Effect?](#what-is-slot-effect)
2. [Quick Start](#quick-start)
3. [Your First Pipeline](#your-first-pipeline)
4. [Understanding the Architecture](#understanding-the-architecture)
5. [Building a Feature DLL](#building-a-feature-dll)
6. [Testing Your Pipeline](#testing-your-pipeline)
7. [Advanced Topics](#advanced-topics)
8. [Troubleshooting](#troubleshooting)

## What is Slot-Effect?

The slot-effect architecture separates your business logic into:

- **Slots**: Type-safe data storage (like variables)
- **Steps**: Pure functions that read/write slots and return decisions
- **Effects**: Impure operations (HTTP, DB, compute) executed separately
- **Pipeline**: Sequence of steps that process a request

### Why Use Slot-Effect?

✅ **Type Safety** - Compile-time validation of all data access
✅ **Testability** - Pure business logic, easy to unit test
✅ **Observability** - Built-in tracing and logging
✅ **Security** - SSRF and SQL injection protection
✅ **Hot Reload** - Update code without downtime

## Quick Start

### Prerequisites

- Zig 0.15.1 or higher
- Basic understanding of Zig enums and functions
- Zerver framework installed

### Run the Demo

```bash
# Build and run the calculator demo
zig build run_slot_demo

# You should see:
# === Slot-Effect Simple Demo ===
# ✓ Schema verified: all slots have types
# ✓ Created context: calc-001
# ✓ Pipeline defined with 3 steps
# [Step 1] Initialized: a=42.0, b=8.0, op=add
# [Step 2] Calculated: 42 add 8 = 50
# [Step 3] Formatted: 42 add 8 = 50
# Final Response: {"result":50,"expression":"42 add 8 = 50"}
```

## Your First Pipeline

Let's build a simple greeting API using slot-effect pipelines.

### Step 1: Define Your Slot Schema

Slots are like strongly-typed variables. Define an enum for your slots:

```zig
const GreetingSlot = enum {
    user_name,        // Input: from request
    greeting_msg,     // Intermediate: generated greeting
    timestamp,        // Intermediate: when generated
    response_built,   // Final: marker for completion
};
```

### Step 2: Map Slots to Types

Each slot must have a type. This is checked at compile time:

```zig
fn greetingSlotType(comptime slot: GreetingSlot) type {
    return switch (slot) {
        .user_name => []const u8,
        .greeting_msg => []const u8,
        .timestamp => i64,
        .response_built => bool,
    };
}
```

### Step 3: Create the Schema

```zig
const slot_effect = @import("slot_effect");
const GreetingSchema = slot_effect.SlotSchema(GreetingSlot, greetingSlotType);

// Verify at compile time that all slots have types
comptime {
    GreetingSchema.verifyExhaustive();
}
```

### Step 4: Write Your Pipeline Steps

Each step is a pure function that reads/writes slots:

```zig
/// Step 1: Extract user name from request
fn extractNameStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    // Define what this step can read/write
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{},  // Reads nothing
        .writes = &[_]GreetingSlot{.user_name},  // Writes user_name
    });

    var view = Ctx{ .base = ctx };

    // Extract from request (simplified - would parse from HTTP)
    const name = "Alice";

    // Write to slot
    try view.put(.user_name, name);

    // Continue to next step
    return slot_effect.continue_();
}

/// Step 2: Generate greeting message
fn generateGreetingStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{.user_name},  // Reads user_name
        .writes = &[_]GreetingSlot{.greeting_msg, .timestamp},  // Writes two slots
    });

    var view = Ctx{ .base = ctx };

    // Read user name (type-safe!)
    const name = try view.require(.user_name);

    // Generate greeting
    const greeting = try std.fmt.allocPrint(
        ctx.allocator,
        "Hello, {s}! Welcome to slot-effect pipelines.",
        .{name},
    );

    // Store timestamp
    const now = std.time.timestamp();

    // Write to slots
    try view.put(.greeting_msg, greeting);
    try view.put(.timestamp, now);

    return slot_effect.continue_();
}

/// Step 3: Build HTTP response (terminal step)
fn buildResponseStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{.greeting_msg, .timestamp},
        .writes = &[_]GreetingSlot{.response_built},
    });

    var view = Ctx{ .base = ctx };

    // Read required slots
    const greeting = try view.require(.greeting_msg);
    const timestamp = try view.require(.timestamp);

    // Mark as built
    try view.put(.response_built, true);

    // Build JSON response
    const json_body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"message\":\"{s}\",\"timestamp\":{d}}}",
        .{ greeting, timestamp },
    );

    // Create HTTP response
    var response = slot_effect.Response{
        .status = 200,
        .headers = slot_effect.Response.Headers.init(ctx.allocator),
        .body = slot_effect.Body{ .json = json_body },
    };

    try response.headers.append(.{
        .name = "Content-Type",
        .value = "application/json",
    });

    // Return Done to finish pipeline
    return slot_effect.done(response);
}
```

### Step 5: Execute the Pipeline

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create request context
    var ctx = try slot_effect.CtxBase.init(allocator, "greeting-001");
    defer ctx.deinit();

    // Define pipeline (order matters!)
    const steps = [_]slot_effect.StepFn{
        extractNameStep,
        generateGreetingStep,
        buildResponseStep,
    };

    // Create interpreter
    var interpreter = slot_effect.Interpreter.init(&steps);

    // Execute pipeline
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    // Handle result
    switch (decision) {
        .Done => |response| {
            std.debug.print("Success! Status: {d}\n", .{response.status});
            std.debug.print("Body: {s}\n", .{response.body.json});
        },
        .Fail => |err| {
            std.debug.print("Error: {s} (code {d})\n", .{err.message, err.code});
        },
        else => {
            std.debug.print("Unexpected result\n", .{});
        },
    }
}
```

## Understanding the Architecture

### The Four Decision Types

Your steps return one of four decision types:

1. **`continue_()`** - Move to next step
2. **`done(response)`** - Pipeline complete, return response
3. **`fail(message, code)`** - Pipeline failed, return error
4. **`need(effect)`** - Execute side effect, then resume

### Pure Steps vs Effects

**Steps are pure:**
- No HTTP calls
- No database queries
- No file I/O
- Deterministic and testable

**Effects are impure:**
- HTTP requests
- Database operations
- Compute tasks
- Executed separately by EffectorTable

### Example with Effects

```zig
fn fetchUserStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{.username},
        .writes = &[_]AuthSlot{},
    });

    var view = Ctx{ .base = ctx };
    const username = try view.require(.username);

    // Return an effect to be executed
    const effect = slot_effect.Effect{
        .db_query = .{
            .sql = "SELECT * FROM users WHERE username = $1",
            .params = &[_][]const u8{username},
        },
    };

    return slot_effect.need(effect);
}
```

The EffectorTable will:
1. Execute the DB query
2. Store result in a well-known slot
3. Resume the pipeline at the next step

## Building a Feature DLL

Feature DLLs allow hot reload without downtime.

### Step 1: Create Feature Directory

```bash
mkdir -p src/features/greeting
```

### Step 2: Write main.zig

```zig
// src/features/greeting/main.zig
const std = @import("std");
const slot_effect = @import("../../zupervisor/slot_effect.zig");
const slot_effect_dll = @import("../../zupervisor/slot_effect_dll.zig");

// Define your slot schema (as shown above)
const GreetingSlot = enum { /* ... */ };
fn greetingSlotType(comptime slot: GreetingSlot) type { /* ... */ }

// Define your steps
fn extractNameStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision { /* ... */ }
fn generateGreetingStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision { /* ... */ }
fn buildResponseStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision { /* ... */ }

// Pipeline definition
const pipeline_steps = [_]slot_effect.StepFn{
    extractNameStep,
    generateGreetingStep,
    buildResponseStep,
};

// Handler wrapper
fn greetingHandler(
    server: *const slot_effect_dll.SlotEffectServerAdapter,
    request: *anyopaque,
    response: *anyopaque,
) callconv(.c) c_int {
    _ = server;
    _ = request;
    _ = response;

    // TODO: Execute pipeline with request data
    // This would use PipelineExecutor to run the pipeline

    return 0;
}

// Route table export
const routes = [_]slot_effect_dll.SlotEffectRoute{
    .{
        .method = 0, // GET
        .path = "/greeting",
        .path_len = 9,
        .handler = greetingHandler,
        .metadata = null,
    },
};

// DLL exports
export fn getRoutes() [*c]const slot_effect_dll.SlotEffectRoute {
    return &routes;
}

export fn getRoutesCount() usize {
    return routes.len;
}

export fn featureInit(adapter: *const slot_effect_dll.SlotEffectServerAdapter) c_int {
    _ = adapter;
    return 0;
}

export fn featureShutdown() void {}

export fn featureVersion() [*c]const u8 {
    return "1.0.0";
}
```

### Step 3: Build the DLL

```bash
# Build as shared library
zig build-lib -dynamic -lc src/features/greeting/main.zig \
    -femit-bin=zig-out/lib/libgreeting.dylib

# Or add to build.zig (TODO: complete build integration)
```

### Step 4: Deploy

```bash
# Copy to feature directory
cp zig-out/lib/libgreeting.dylib /path/to/features/

# Zupervisor will detect and load it automatically
```

## Testing Your Pipeline

### Unit Testing Steps

Test individual steps in isolation:

```zig
test "extractNameStep - writes user_name" {
    const testing = std.testing;

    var ctx = try slot_effect.CtxBase.init(testing.allocator, "test-001");
    defer ctx.deinit();

    const decision = try extractNameStep(&ctx);

    // Verify it continues
    try testing.expect(decision == .Continue);

    // Verify slot was written
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = GreetingSlot,
        .slotTypeFn = greetingSlotType,
        .reads = &[_]GreetingSlot{.user_name},
        .writes = &[_]GreetingSlot{},
    });
    var view = Ctx{ .base = &ctx };
    const name = try view.require(.user_name);

    try testing.expectEqualStrings("Alice", name);
}
```

### Integration Testing Pipelines

Test the complete pipeline:

```zig
test "greeting pipeline - end to end" {
    const testing = std.testing;

    var ctx = try slot_effect.CtxBase.init(testing.allocator, "test-pipeline-001");
    defer ctx.deinit();

    const steps = [_]slot_effect.StepFn{
        extractNameStep,
        generateGreetingStep,
        buildResponseStep,
    };

    var interpreter = slot_effect.Interpreter.init(&steps);
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    try testing.expect(decision == .Done);
    try testing.expect(decision.Done.status == 200);

    const body = decision.Done.body.json;
    try testing.expect(std.mem.indexOf(u8, body, "Alice") != null);
}
```

### Testing with Effects

Use mock effectors to test effect-based steps:

```zig
test "fetchUserStep - requests db_query effect" {
    const testing = std.testing;

    var ctx = try slot_effect.CtxBase.init(testing.allocator, "test-effect-001");
    defer ctx.deinit();

    // Pre-populate username slot
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{},
        .writes = &[_]AuthSlot{.username},
    });
    var view = Ctx{ .base = &ctx };
    try view.put(.username, "bob");

    // Execute step
    const decision = try fetchUserStep(&ctx);

    // Verify it returned need<db_query>
    try testing.expect(decision == .need);
    try testing.expect(decision.need == .db_query);

    const query = decision.need.db_query;
    try testing.expectEqualStrings("SELECT * FROM users WHERE username = $1", query.sql);
}
```

## Advanced Topics

### Compile-Time Dependency Validation

Validate that all reads are produced by prior steps:

```zig
const route = routeChecked(
    GreetingSlot,
    greetingSlotType,
    &steps,
    .{
        .require_reads_produced = true,    // All reads must be written first
        .forbid_duplicate_writers = true,  // No two steps write same slot
        .trace_execution = false,          // Disable tracing for tests
    },
);
```

This catches bugs at **compile time**:
- Reading a slot that was never written
- Multiple steps writing to the same slot
- Missing required slots

### Security Policies

Configure SSRF protection:

```zig
const http_policy = slot_effect.HttpSecurityPolicy{
    .allowed_hosts = &.{"api.example.com", "db.internal"},
    .forbidden_schemes = &.{"file", "ftp"},
    .max_response_size = 10 * 1024 * 1024,
    .follow_redirects = false,
};

// Applied automatically by effect executors
```

Configure SQL injection protection:

```zig
const sql_policy = slot_effect.SqlSecurityPolicy{
    .require_parameterized = true,
    .forbidden_keywords = &.{"EXEC", "DROP", "ALTER"},
    .max_query_length = 10_000,
};
```

### Distributed Tracing

Enable request correlation:

```zig
const TraceCollector = slot_effect.TraceCollector.init(allocator);

// Automatic tracing of:
// - Request start/end
// - Step execution
// - Effect execution
// - Slot writes
// - Errors

// Events exported in OpenTelemetry format (future)
```

### Compensation (Saga Pattern)

Roll back on failure:

```zig
fn createOrderStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    // Create order effect
    const create_effect = slot_effect.Effect{
        .db_put = .{
            .table = "orders",
            .key = order_id,
            .value = order_data,
        },
    };

    // Compensation if later step fails
    const compensate_effect = slot_effect.Effect{
        .db_del = .{
            .table = "orders",
            .key = order_id,
        },
    };

    return slot_effect.need(.{
        .compensate = .{
            .effect = &create_effect,
            .on_failure = &compensate_effect,
        },
    });
}
```

## Troubleshooting

### Common Errors

**Error: Slot not in declared reads**
```zig
// ❌ Wrong - trying to read slot not declared
const Ctx = slot_effect.CtxView(.{
    .reads = &[_]MySlot{},  // Empty reads
    // ...
});
const value = try view.require(.some_slot);  // Compile error!

// ✅ Correct - declare all reads
const Ctx = slot_effect.CtxView(.{
    .reads = &[_]MySlot{.some_slot},  // Declared
    // ...
});
const value = try view.require(.some_slot);  // OK
```

**Error: Slot not in declared writes**
```zig
// ❌ Wrong
const Ctx = slot_effect.CtxView(.{
    .writes = &[_]MySlot{},  // Empty writes
    // ...
});
try view.put(.result, 42);  // Compile error!

// ✅ Correct
const Ctx = slot_effect.CtxView(.{
    .writes = &[_]MySlot{.result},  // Declared
    // ...
});
try view.put(.result, 42);  // OK
```

**Error: Non-exhaustive slot types**
```zig
// ❌ Wrong - missing types for some slots
fn mySlotType(comptime slot: MySlot) type {
    return switch (slot) {
        .input => []const u8,
        // Missing .output!
    };
}

// Compile error: "switch not exhaustive"

// ✅ Correct - all slots have types
fn mySlotType(comptime slot: MySlot) type {
    return switch (slot) {
        .input => []const u8,
        .output => u32,  // Added
    };
}
```

### Debugging Tips

1. **Enable trace logging:**
   ```zig
   const trace_collector = slot_effect.TraceCollector.init(allocator);
   trace_collector.emit(.request_start);
   ```

2. **Print slot contents:**
   ```zig
   const value = try view.require(.my_slot);
   std.debug.print("Slot value: {any}\n", .{value});
   ```

3. **Check pipeline iterations:**
   ```zig
   executor.max_iterations = 100;  // Default
   // If exceeded, likely infinite loop
   ```

4. **Verify step order:**
   ```zig
   // Steps execute in array order
   const steps = [_]slot_effect.StepFn{
       step1,  // Runs first
       step2,  // Runs second
       step3,  // Runs third
   };
   ```

## Next Steps

- **Read the architecture docs**: `docs/architecture/slot-effect-pipeline.md`
- **Study the examples**: `examples/slot_effect_simple_demo.zig`
- **Explore the auth DLL**: `src/features/auth_slot_effect/main.zig`
- **Review integration guide**: `docs/architecture/slot-effect-dll-integration.md`

## Reference

### Key Types

```zig
// Context (per-request storage)
CtxBase.init(allocator, request_id)

// View (type-safe access)
CtxView(.{ .SlotEnum = MySlot, .slotTypeFn = mySlotTypeFn, ... })

// Decisions (step results)
continue_()
done(response)
fail(message, code)
need(effect)

// Effects (side operations)
Effect{ .http_call = ... }
Effect{ .db_query = ... }
Effect{ .compute_task = ... }

// Response (HTTP output)
Response{ .status = 200, .headers = ..., .body = ... }
```

### Useful Functions

```zig
// Slot operations
try view.put(.slot_name, value)
const value = try view.require(.slot_name)

// Pipeline execution
var interpreter = Interpreter.init(&steps);
const decision = try interpreter.evalUntilNeedOrDone(&ctx);

// Validation
Schema.verifyExhaustive()  // Compile-time
routeChecked(...)  // Compile-time dependency checking
```

## Support

- **Documentation**: `docs/` directory
- **Examples**: `examples/` directory
- **Tests**: `src/zupervisor/*_test.zig`
- **Implementation Summary**: `docs/slot-effect-implementation-summary.md`

---

**Built with Zerver** • **Type-Safe** • **Production-Ready**
