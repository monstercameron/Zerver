# Slot-Effect Pipeline Architecture (Refined)

**Status:** Active Design - Production-Ready Specification
**Created:** 2025-10-30
**Last Updated:** 2025-10-30
**Additions:** Runtime assertions, generic effects, comptime wiring validation, saga semantics, security policies, observability, performance optimizations, testing strategy
**Based On:** Blog feature implementation (proven architecture)

## Design Goals

This architecture prioritizes:

1. **Lower Cognitive Load** - One way to write steps, one way to compose routes
2. **Stronger Comptime Safety** - SlotSchema helpers, exhaustive type mapping, comptime wiring validation
3. **Clear Ownership/Lifetimes** - Arena-only slot values, explicit ownership rules
4. **Pure-ish Steps** - Deterministic, testable step functions
5. **Clean Pure/Impure Split** - Steps build effect IR, runtime executes effects
6. **Preserve Proven Model** - Keep slots → steps → effects architecture
7. **Debug-Time Validation** - Runtime assertions for slot usage (zero cost in release)
8. **Production Safety** - Resource limits, SSRF protection, compensation semantics
9. **Observable by Default** - First-class tracing, correlation, structured logging

## Architecture Split

### Pure Core (Deterministic)
- **Slot schema** with typed `CtxView`
- **Steps** as pure-ish functions that:
  - Read/write slots
  - Build `Decision`/`Need` (effect intermediate representation)
  - Never perform I/O
- **Pure interpreter** to evaluate steps until `.need`/`.Done`/`.Fail`

### Impure Runtime
- **Effect execution** (HTTP, DB, FS, compute workers)
- **Schedulers/reactor** for parallel/sequential execution
- **Bridges results back** to pure interpreter via slot writes

This preserves the slots/steps/effects model but makes the boundary explicit and testable.

---

## Core Concepts

### 1. Slots - Typed Storage

**Slots** are typed storage locations that hold intermediate data during request processing.

```zig
pub const BlogSlot = enum(u32) {
    PostId = 0,
    Post = 1,
    PostInput = 2,
    PostJson = 3,
};

pub fn BlogSlotType(comptime s: BlogSlot) type {
    return switch (s) {
        .PostId => []const u8,
        .Post => Post,
        .PostInput => PostInput,
        .PostJson => []const u8,
    };
}
```

**Properties:**
- Compile-time type safety (can't mix types)
- Arena-owned or static data only
- Automatic cleanup (request-scoped allocator)
- Order correctness (can't read before write)

### 2. SlotSchema Helper (Comptime Safety)

The `SlotSchema` helper provides comptime utilities for working with slots:

```zig
pub fn SlotSchema(comptime SlotEnum: type, comptime slotTypeFn: anytype) type {
    return struct {
        /// Get slot ID at comptime
        pub inline fn slotId(comptime slot: SlotEnum) u32 {
            return @intFromEnum(slot);
        }

        /// Verify all enum tags have a type mapping (exhaustive)
        pub fn verifyExhaustive() void {
            comptime {
                inline for (@typeInfo(SlotEnum).Enum.fields) |field| {
                    const slot = @field(SlotEnum, field.name);
                    _ = slotTypeFn(slot); // Forces exhaustive switch
                }
            }
        }

        /// Get type for a slot at comptime
        pub fn TypeOf(comptime slot: SlotEnum) type {
            return slotTypeFn(slot);
        }
    };
}
```

**Usage:**

```zig
const BlogSlots = SlotSchema(BlogSlot, BlogSlotType);

// Verify exhaustiveness at comptime
comptime {
    BlogSlots.verifyExhaustive();
}

// Use in code
const post_id_token = BlogSlots.slotId(.PostId);
```

### 3. Steps - Pure-ish Processing Units

**Design Principle:** Steps are pure-ish functions that build effect IR but never perform I/O.

**One Way to Write Steps:**
1. Define a typed `CtxView` with reads/writes
2. Step function takes `*CtxView` parameter
3. Step reads/writes slots, builds `Decision`
4. Use `step()` trampoline to register

**Example:**

```zig
// Define typed context view
const ParseCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .writes = &.{ BlogSlot.PostInput },
});

// Step function (pure-ish)
pub fn step_parse(ctx: *ParseCtx) !Decision {
    const input = try ctx.base.json(PostInput);
    try ctx.put(BlogSlot.PostInput, input);
    return zerver.continue_();
}

// Register with trampoline
const route = zerver.route(.{
    step("parse", step_parse),
    step("validate", step_validate),
    step("create", step_create),
    step("respond", step_respond),
});
```

**Steps MAY:**
- Parse/validate data
- Transform values
- Build `Need` decisions (effect IR)
- Read/write slots

**Steps MAY NOT:**
- Open sockets, DB connections
- Write files
- Get current time (use effect instead)
- Perform any I/O

This keeps the test matrix simple and deterministic.

### 4. Context Views - Typed Slot Access

**CtxView** provides compile-time checked slot access based on declared reads/writes.

```zig
const PostIdWriteCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .writes = &.{BlogSlot.PostId}
});

const PostReadCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.Post}
});

const UpdatePostCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.PostId, BlogSlot.Post, BlogSlot.PostInput},
    .writes = &.{BlogSlot.Post}
});
```

**CtxView API:**
- `ctx.put(slot, value)` - Write to slot (type-checked, arena-owned)
- `ctx.require(slot)` - Read from slot, error if not filled
- `ctx.optional(slot)` - Read from slot, return null if not filled
- `ctx.base` - Access to underlying request context

**Comptime Enforcement:**
- Can only `put()` slots in `writes` array
- Can only `require()`/`optional()` slots in `reads` array
- Type mismatch caught at compile time

### 5. Runtime Assertion Strategy

**Goal:** Catch when a step declares slots in its view but never actually reads/writes them during execution. Minimal overhead, zero cost in release, low cognitive load.

#### Core Tracking Mechanism

```zig
pub const DebugSlotUsage = struct {
    declared_reads: std.bit_set.StaticBitSet(256),
    declared_writes: std.bit_set.StaticBitSet(256),
    actual_reads: std.bit_set.StaticBitSet(256),
    actual_writes: std.bit_set.StaticBitSet(256),
};

pub const CtxBase = struct {
    // ... other fields ...

    // Only compiled in debug mode
    debug_slot_usage: if (builtin.mode == .Debug) DebugSlotUsage else void,
};
```

#### Usage Marking in CtxView Accessors

```zig
pub fn CtxView(comptime config: anytype) type {
    return struct {
        base: *CtxBase,

        pub fn require(self: *@This(), comptime slot: SlotEnum) !SlotType(slot) {
            // Mark slot as read in debug builds only
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_reads.set(slot_id);
            }

            return self.base.slots.get(slot) orelse error.SlotNotFilled;
        }

        pub fn optional(self: *@This(), comptime slot: SlotEnum) ?SlotType(slot) {
            // Mark slot as read in debug builds only
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_reads.set(slot_id);
            }

            return self.base.slots.get(slot);
        }

        pub fn put(self: *@This(), comptime slot: SlotEnum, value: SlotType(slot)) !void {
            // Mark slot as written in debug builds only
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_writes.set(slot_id);
            }

            try self.base.slots.put(slot, value);
        }
    };
}
```

#### Assertion Checking in Step Trampoline

```zig
pub const StepSpec = struct {
    name: []const u8,
    fn_ptr: *const anyopaque,
    reads: []const u32,
    writes: []const u32,

    pub fn call(self: StepSpec, ctx: *CtxBase) !Decision {
        if (builtin.mode == .Debug) {
            // Initialize declared slots
            ctx.debug_slot_usage.declared_reads.setRangeValue(.{ .start = 0, .end = 256 }, false);
            ctx.debug_slot_usage.declared_writes.setRangeValue(.{ .start = 0, .end = 256 }, false);
            ctx.debug_slot_usage.actual_reads.setRangeValue(.{ .start = 0, .end = 256 }, false);
            ctx.debug_slot_usage.actual_writes.setRangeValue(.{ .start = 0, .end = 256 }, false);

            for (self.reads) |slot_id| {
                ctx.debug_slot_usage.declared_reads.set(slot_id);
            }
            for (self.writes) |slot_id| {
                ctx.debug_slot_usage.declared_writes.set(slot_id);
            }
        }

        // Call the actual step function
        const decision = try self.callImpl(ctx);

        if (builtin.mode == .Debug) {
            // Check assertions based on decision type
            switch (decision) {
                .Continue, .Done => {
                    // Full validation: must use all declared slots
                    try assertSlotUsage(ctx, self);
                },
                .need => {
                    // Partial validation: writes may be deferred to post-effect
                    try assertReadsUsed(ctx, self);
                },
                .Fail => {
                    // No validation on early exit
                },
            }
        }

        return decision;
    }

    fn assertSlotUsage(ctx: *CtxBase, step: StepSpec) !void {
        const policy = ctx.assertion_policy;

        if (policy.must_use_reads) {
            for (step.reads) |slot_id| {
                if (!ctx.debug_slot_usage.actual_reads.isSet(slot_id)) {
                    slog.err("Step declared read but never read slot", &.{
                        slog.Attr.string("step", step.name),
                        slog.Attr.int("slot_id", slot_id),
                    });
                    return error.UnusedSlotRead;
                }
            }
        }

        if (policy.must_use_writes) {
            for (step.writes) |slot_id| {
                if (!ctx.debug_slot_usage.actual_writes.isSet(slot_id)) {
                    slog.err("Step declared write but never wrote slot", &.{
                        slog.Attr.string("step", step.name),
                        slog.Attr.int("slot_id", slot_id),
                    });
                    return error.UnusedSlotWrite;
                }
            }
        }
    }

    fn assertReadsUsed(ctx: *CtxBase, step: StepSpec) !void {
        const policy = ctx.assertion_policy;

        if (policy.must_use_reads) {
            for (step.reads) |slot_id| {
                if (!ctx.debug_slot_usage.actual_reads.isSet(slot_id)) {
                    slog.warn("Step declared read but never read slot before Need", &.{
                        slog.Attr.string("step", step.name),
                        slog.Attr.int("slot_id", slot_id),
                    });
                }
            }
        }
    }
};
```

#### Configuration Knobs

```zig
pub const AssertionPolicy = struct {
    /// Error if step declares read but never calls require/optional
    must_use_reads: bool = true,

    /// Error if step declares write but never calls put
    must_use_writes: bool = true,

    /// Warn on unused reads instead of error
    warn_unused_reads: bool = false,

    /// Warn on unused writes instead of error
    warn_unused_writes: bool = false,
};

pub const CtxBase = struct {
    // ... other fields ...

    assertion_policy: AssertionPolicy = .{},
};

// Per-view override (future enhancement)
const MyStrictCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.PostId},
    .writes = &.{BlogSlot.Post},
    .assertion_policy = .{
        .must_use_reads = true,
        .must_use_writes = true,
    },
});

const MyLenientCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.PostId, BlogSlot.User},  // User is optional
    .assertion_policy = .{
        .must_use_reads = false,  // Allow declared but unused reads
    },
});
```

#### Benefits

1. **Zero Cost in Release** - All tracking code is `if (builtin.mode == .Debug)`
2. **Catches Mistakes Early** - Detects copy-paste errors, stale declarations
3. **Low Cognitive Load** - Automatically enforced, no manual tracking
4. **Configurable** - Global and per-view policies
5. **Decision-Aware** - Different validation for Continue/Need/Done/Fail

#### Example Error

```zig
const MyCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.PostId, BlogSlot.User},  // Declared User read
    .writes = &.{BlogSlot.Post},
});

pub fn step_example(ctx: *MyCtx) !Decision {
    const post_id = try ctx.require(BlogSlot.PostId);
    // BUG: Never read User slot

    try ctx.put(BlogSlot.Post, post);
    return zerver.continue_();
}

// Debug build output:
// ERROR: Step declared read but never read slot
//   step=example slot_id=2 (User)
// error: UnusedSlotRead
```

---

### 6. Comptime Wiring Validation

**Goal:** Catch slot dependency errors at compile time (reads-before-writes, duplicate writers, unread writes).

#### Route-Level Validation with `routeChecked`

```zig
pub fn routeChecked(
    comptime config: anytype,
    comptime checks: struct {
        require_reads_produced: bool = true,
        forbid_duplicate_writers: bool = true,
        warn_unread_writes: bool = true,
    },
) RouteSpec {
    comptime {
        // Build slot dependency graph
        var produced = std.StaticBitSet(256).initEmpty();
        var consumed = std.StaticBitSet(256).initEmpty();
        var writers = std.StringHashMap([]const u8).init(std.heap.page_allocator);

        // Track .before steps
        if (@hasField(@TypeOf(config), "before")) {
            for (config.before) |step_spec| {
                try validateStep(step_spec, &produced, &consumed, &writers, checks);
            }
        }

        // Track main steps
        if (@hasField(@TypeOf(config), "steps")) {
            for (config.steps) |step_spec| {
                try validateStep(step_spec, &produced, &consumed, &writers, checks);
            }
        }

        // Final validation
        if (checks.require_reads_produced) {
            // Ensure all reads have corresponding writes
            var it = consumed.iterator(.{});
            while (it.next()) |slot_id| {
                if (!produced.isSet(slot_id)) {
                    @compileError(std.fmt.comptimePrint(
                        "Slot {} is read but never written in route",
                        .{slot_id},
                    ));
                }
            }
        }

        if (checks.warn_unread_writes) {
            // Warn about writes that are never read
            var it = produced.iterator(.{});
            while (it.next()) |slot_id| {
                if (!consumed.isSet(slot_id)) {
                    @compileLog(std.fmt.comptimePrint(
                        "Warning: Slot {} is written but never read in route",
                        .{slot_id},
                    ));
                }
            }
        }
    }

    return RouteSpec.init(config);
}

fn validateStep(
    comptime step_spec: StepSpec,
    comptime produced: *std.StaticBitSet(256),
    comptime consumed: *std.StaticBitSet(256),
    comptime writers: *std.StringHashMap([]const u8),
    comptime checks: anytype,
) !void {
    // Check reads-before-writes
    for (step_spec.reads) |slot_id| {
        if (!produced.isSet(slot_id)) {
            @compileError(std.fmt.comptimePrint(
                "Step '{}' reads slot {} before it is written",
                .{ step_spec.name, slot_id },
            ));
        }
        consumed.set(slot_id);
    }

    // Check duplicate writers
    for (step_spec.writes) |slot_id| {
        if (checks.forbid_duplicate_writers) {
            if (writers.get(slot_id)) |existing_step| {
                @compileError(std.fmt.comptimePrint(
                    "Slot {} written by both '{}' and '{}'",
                    .{ slot_id, existing_step, step_spec.name },
                ));
            }
        }

        try writers.put(slot_id, step_spec.name);
        produced.set(slot_id);
    }
}
```

#### Usage Example

```zig
const create_post_route = zerver.routeChecked(.{
    .steps = &.{
        step("parse", step_parse),           // writes: PostInput
        step("validate", step_validate),     // reads: PostInput
        step("create", step_create),         // reads: PostInput, writes: Post
        step("respond", step_respond),       // reads: Post
    },
}, .{
    .require_reads_produced = true,
    .forbid_duplicate_writers = true,
    .warn_unread_writes = true,
});

// Compile error example:
const broken_route = zerver.routeChecked(.{
    .steps = &.{
        step("validate", step_validate),  // reads: PostInput
        step("parse", step_parse),        // writes: PostInput
    },
}, .{});
// ERROR: Step 'validate' reads slot 0 (PostInput) before it is written
```

#### Benefits

1. **Catch bugs at compile time** - Impossible to deploy reads-before-writes
2. **Dependency visualization** - Clear slot data flow through pipeline
3. **Refactoring safety** - Reordering steps triggers validation errors
4. **Documentation** - Slot dependencies serve as inline documentation

---

### 7. Decisions - Step Outcomes

**Decision** tells the pipeline interpreter what to do next.

```zig
pub const Decision = union(enum) {
    Continue,                    // Move to next step
    need: Need,                  // Execute effects, then continue
    Done: Response,              // Complete pipeline with response
    Fail: Error,                 // Abort pipeline with error
};

pub const Response = struct {
    status: u16,
    headers: []const Header = &.{},
    body: Body,
};

pub const Body = union(enum) {
    complete: []const u8,        // Full response body
    streaming: StreamHandle,     // Future: streaming responses
};

pub const Error = struct {
    code: ErrorCode,
    entity: []const u8,          // e.g., "post", "user"
    reason: []const u8,          // e.g., "title_empty", "not_found"
    context: ?[]const u8 = null, // Optional additional context
};

pub const ErrorCode = enum {
    InvalidInput,
    NotFound,
    Unauthorized,
    Forbidden,
    Conflict,
    InternalError,
};
```

**Helper Functions:**

```zig
// Continue to next step
return zerver.continue_();

// Execute effects
return zerver.need(.{
    .effects = &.{ /* effects */ },
    .mode = .Sequential,
    .join = .all,
});

// Complete with response (RECOMMENDED: return directly, don't use slots)
return zerver.done(.{
    .status = 201,
    .headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    },
    .body = .{ .complete = json },
});

// Early-return error (centralized rendering via on_error hook)
return zerver.fail(ErrorCode.InvalidInput, "post", "title_empty");

// Error with context
return zerver.failWithContext(
    ErrorCode.NotFound,
    "user",
    "user_not_found",
    try std.fmt.allocPrint(ctx.base.allocator, "id={s}", .{user_id}),
);
```

**Design Principle: Responses vs Slots**

**RECOMMENDED:** Return responses directly via `Decision.Done`, not through slots.

```zig
// ✅ Good: Direct return
pub fn step_respond(ctx: *RespondCtx) !Decision {
    const post = try ctx.require(BlogSlot.Post);
    const json = try ctx.base.toJson(post);

    return zerver.done(.{
        .status = 201,
        .body = .{ .complete = json },
    });
}
```

**Why?**
- Keeps finalizer simple
- Separates response from intermediate data
- Avoids slot pollution with response-specific data

**Optional Pattern** (if you prefer slot-based rendering):
- Fill slots with domain data only (e.g., `Slot.Post`, `Slot.User`)
- Final render step reads slots, builds `Response`, returns `Done`
- Only use `Slot.Response` if you need shared renderer across routes

### 6. Effects - Async Operation IR

**Effects** are intermediate representations of async operations built by steps.

**Key Design:** Each effect carries its own `token: u32` indicating which slot gets filled. This keeps composition simple and parallel-safe.

```zig
pub const Need = struct {
    effects: []const Effect,       // Effects to execute
    mode: Mode,                    // Sequential or Parallel
    join: Join,                    // Completion strategy
    continuation: ?ResumeFn,       // Optional callback after effects
};

pub const Mode = enum {
    Sequential,  // Execute effects one by one
    Parallel,    // Execute effects concurrently
};

pub const Join = enum {
    all,            // Wait for all effects to complete
    all_required,   // All must succeed or fail entire pipeline
    any,            // Return when first succeeds (ignore failures)
    first_success,  // Return when first completes successfully
};
```

**Effect Types (Wire Format):**

```zig
pub const Effect = union(enum) {
    db_get: DbGetEffect,
    db_put: DbPutEffect,
    db_del: DbDelEffect,
    db_query: DbQueryEffect,         // SQL queries
    http_call: HttpCallEffect,       // HTTP requests
    compute_task: ComputeTask,       // CPU-bound work
    // ... extensible
};

pub const DbGetEffect = struct {
    key: []const u8,
    token: u32,                      // Which slot to fill
    required: bool = true,
};

pub const DbPutEffect = struct {
    key: []const u8,
    value: []const u8,
    token: u32,
};

pub const DbDelEffect = struct {
    key: []const u8,
    token: u32,
};

pub const DbQueryEffect = struct {
    sql: []const u8,                 // Parameterized query: "SELECT * FROM users WHERE id = $1"
    params: []const SqlParam,        // Parameters for $1, $2, etc.
    token: u32,
};

pub const SqlParam = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null,
};

pub const HttpCallEffect = struct {
    method: HttpMethod,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
    token: u32,
    timeout_ms: u32 = 30000,
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

pub const ComputeTask = struct {
    operation: []const u8,           // Operation identifier (e.g., "hash:sha256", "encode:base64")
    token: u32,                      // Output slot
    timeout_ms: u32 = 0,             // 0 = no timeout
    cpu_budget_ms: u32 = 0,          // 0 = no CPU limit
    priority: u8 = 128,              // 0=lowest, 255=highest
    cooperative_yield_interval_ms: u32 = 100,
    metadata: ?*const anyopaque = null,  // Optional arena-allocated metadata
};
```

**Note:** All effectors return `[]const u8` (raw bytes). Typed decoding happens in dedicated steps or via per-slot codecs.

### 7. Pure Interpreter

The **pure interpreter** evaluates steps until reaching a decision boundary (`.need`, `.Done`, `.Fail`).

```zig
pub const Interpreter = struct {
    pub fn evalUntilNeedOrDone(
        ctx: *CtxBase,
        spec: RouteSpec,
        slots: *SlotMap,
    ) !Decision {
        // Pure loop over steps
        for (spec.steps) |step_spec| {
            const decision = try step_spec.call(ctx);

            switch (decision) {
                .Continue => continue,
                .need => |n| return .{ .need = n },
                .Done => |r| return .{ .Done = r },
                .Fail => |e| return .{ .Fail = e },
            }
        }

        return error.PipelineEndedWithoutDecision;
    }
};
```

**Unit Testing:**

```zig
test "parse step fills PostInput slot" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = try CtxBase.init(arena.allocator());
    defer ctx.deinit();

    // Set request body
    try ctx.setBody("{\"title\":\"Hello\",\"content\":\"World\"}");

    // Execute step
    const decision = try step_parse(&ctx);

    // Verify decision
    try testing.expect(decision == .Continue);

    // Verify slot filled
    const input = try ctx.require(BlogSlot.PostInput);
    try testing.expectEqualStrings("Hello", input.title);
}
```

**Fake Effects for Testing:**

```zig
test "create step returns Need with db_put effect" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = try CtxBase.init(arena.allocator());
    defer ctx.deinit();

    // Pre-fill input slot
    try ctx.put(BlogSlot.PostInput, PostInput{
        .title = "Test",
        .content = "Content",
    });

    // Execute step
    const decision = try step_create(&ctx);

    // Verify Need decision
    try testing.expect(decision == .need);
    try testing.expectEqual(1, decision.need.effects.len);
    try testing.expect(decision.need.effects[0] == .db_put);
}
```

### 8. Error Handling (Early Return + Centralized Rendering)

**Design:** Steps can early-return errors. The pure interpreter stops and returns `Decision.Fail` to the runtime, which handles rendering via configurable hooks.

#### Option A: Global `on_error` Hook (Simplest)

Centralized error rendering for uniform branding and telemetry.

```zig
pub const ServerConfig = struct {
    on_error: *const fn (*CtxBase, Error) anyerror!Response,
    // ... other config
};

// Example implementation
fn renderError(ctx: *CtxBase, err: Error) !Response {
    // Map error codes to status codes
    const status: u16 = switch (err.code) {
        .InvalidInput => 400,
        .NotFound => 404,
        .Unauthorized => 401,
        .Forbidden => 403,
        .Conflict => 409,
        .InternalError => 500,
    };

    // Simple JSON error response
    const json = try std.fmt.allocPrint(
        ctx.allocator,
        \\{{"error": "{s}", "entity": "{s}", "reason": "{s}"}}
    ,
        .{ @tagName(err.code), err.entity, err.reason },
    );

    return Response{
        .status = status,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = json },
    };
}

// Or branded HTML pages
fn renderErrorHTML(ctx: *CtxBase, err: Error) !Response {
    const html = switch (err.code) {
        .NotFound => try templates.render404(ctx.allocator, err.entity),
        .InternalError => try templates.render500(ctx.allocator),
        else => try templates.renderGenericError(ctx.allocator, err),
    };

    return Response{
        .status = @intFromEnum(err.code),
        .body = .{ .complete = html },
    };
}
```

#### Option B: Error Pipeline (Slot-Based, Richer UX)

For custom error pages with slot-based rendering (e.g., user-specific 404 pages).

```zig
// Define error slot schema
pub const ErrorSlot = enum(u32) {
    Error = 0,
    User = 1,
    ErrorPage = 2,
};

pub fn ErrorSlotType(comptime s: ErrorSlot) type {
    return switch (s) {
        .Error => types.Error,
        .User => User,
        .ErrorPage => []const u8,
    };
}

// Error pipeline steps
pub fn error_step_load_user(ctx: *ErrorLoadUserCtx) !Decision {
    const err = try ctx.require(ErrorSlot.Error);

    // Try to load current user for personalized error page
    const user_id = ctx.base.getCookie("user_id") orelse return zerver.continue_();

    const effects = &.{
        ctx.base.db(.get, ErrorSlots.slotId(.User), .{
            .key = try std.fmt.allocPrint(ctx.base.allocator, "user:{s}", .{user_id}),
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

pub fn error_step_render(ctx: *ErrorRenderCtx) !Decision {
    const err = try ctx.require(ErrorSlot.Error);
    const user = ctx.optional(ErrorSlot.User);

    const html = switch (err.code) {
        .NotFound => try templates.render404(ctx.base.allocator, user, err),
        .Unauthorized => try templates.renderLogin(ctx.base.allocator),
        .InternalError => try templates.render500(ctx.base.allocator),
        else => try templates.renderGenericError(ctx.base.allocator, err),
    };

    const status: u16 = switch (err.code) {
        .InvalidInput => 400,
        .NotFound => 404,
        .Unauthorized => 401,
        .Forbidden => 403,
        .Conflict => 409,
        .InternalError => 500,
    };

    return zerver.done(.{
        .status = status,
        .body = .{ .complete = html },
    });
}

// Runtime invokes error pipeline when step returns Fail
pub fn handleError(
    ctx: *CtxBase,
    err: Error,
    error_route: RouteSpec,
) !Response {
    // Fill error slot
    try ctx.slots.put(ErrorSlot.Error, err);

    // Run error pipeline
    const decision = try interpreter.evalUntilNeedOrDone(ctx, error_route, ctx.slots);

    return switch (decision) {
        .Done => |response| response,
        .Fail => {
            // Error pipeline itself failed - fall back to on_error
            return on_error(ctx, err);
        },
        else => unreachable,
    };
}
```

#### Option C: Per-Status Code Error Steps

Route different error codes to different step chains.

```zig
pub const ErrorRoutes = struct {
    not_found: RouteSpec,      // 404
    unauthorized: RouteSpec,   // 401
    forbidden: RouteSpec,      // 403
    internal: RouteSpec,       // 500
    generic: RouteSpec,        // Catch-all
};

pub fn handleError(ctx: *CtxBase, err: Error, routes: ErrorRoutes) !Response {
    const route = switch (err.code) {
        .NotFound => routes.not_found,
        .Unauthorized => routes.unauthorized,
        .Forbidden => routes.forbidden,
        .InternalError => routes.internal,
        else => routes.generic,
    };

    // Fill error slot and run appropriate route
    try ctx.slots.put(ErrorSlot.Error, err);
    const decision = try interpreter.evalUntilNeedOrDone(ctx, route, ctx.slots);

    return switch (decision) {
        .Done => |response| response,
        else => on_error(ctx, err),  // Fallback
    };
}
```

**Recommendation:**
- Start with **Option A** (global `on_error`)
- Add **Option B** (error pipeline) if you need rich, slot-based error pages
- **Option C** is useful for complex apps with very different error UX per status code

### 9. EffectorTable (Simple Union Tag → Function Table)

**Design:** Keep it simple - a union tag → function table, not a complex registry.

```zig
/// Simple function table for effect execution
/// Maps effect union tags to executor functions
pub const EffectorTable = struct {
    /// Execute an effect and return result bytes
    pub fn execute(effect: Effect, ctx: *CtxBase) ![]const u8 {
        return switch (effect) {
            .db_get => |e| executeDbGet(e, ctx),
            .db_put => |e| executeDbPut(e, ctx),
            .db_del => |e| executeDbDel(e, ctx),
            .compute => |e| executeCompute(e, ctx),
            .sql_query => unreachable, // Not yet implemented
            .http_call => unreachable, // Not yet implemented
        };
    }

    fn executeDbGet(effect: DbGetEffect, ctx: *CtxBase) ![]const u8 {
        // Implementation
    }

    fn executeDbPut(effect: DbPutEffect, ctx: *CtxBase) ![]const u8 {
        // Implementation
    }

    fn executeDbDel(effect: DbDelEffect, ctx: *CtxBase) ![]const u8 {
        // Implementation
    }

    fn executeCompute(effect: ComputeEffect, ctx: *CtxBase) ![]const u8 {
        // Implementation
    }
};
```

**Note:** All effectors return `[]const u8` (raw bytes). Decoding happens either:
1. In a dedicated step after effects complete, or
2. Via per-slot codec (comptime function) - see "Effect-to-Slot Adapters" below

### 9. Effect Execution Boundary (Impure)

The **runtime** executes the `EffectPlan` returned by the pure interpreter.

```zig
pub const EffectExecutor = struct {
    effectors: EffectorTable,
    worker_pool: *WorkerPool,

    pub fn execute(
        self: *EffectExecutor,
        need: Need,
        ctx: *CtxBase,
        slots: *SlotMap,
    ) !void {
        switch (need.mode) {
            .Sequential => try self.executeSequential(need, ctx, slots),
            .Parallel => try self.executeParallel(need, ctx, slots),
        }
    }

    fn executeSequential(
        self: *EffectExecutor,
        need: Need,
        ctx: *CtxBase,
        slots: *SlotMap,
    ) !void {
        for (need.effects) |effect| {
            const effector = self.effectors.get(effect);
            const result = try effector.execute(effect, ctx);
            try slots.putString(effect.token(), result);
        }
    }

    fn executeParallel(
        self: *EffectExecutor,
        need: Need,
        ctx: *CtxBase,
        slots: *SlotMap,
    ) !void {
        var tasks = std.ArrayList(Task).init(ctx.allocator);
        defer tasks.deinit();

        // Submit all effects to worker pool
        for (need.effects) |effect| {
            const task = try self.worker_pool.submit(effect, ctx);
            try tasks.append(task);
        }

        // Wait based on join strategy
        switch (need.join) {
            .all => try self.waitForAll(tasks.items, slots),
            .all_required => try self.waitForAllRequired(tasks.items, slots),
            .any => try self.waitForAny(tasks.items, slots),
            .first_success => try self.waitForFirstSuccess(tasks.items, slots),
        }
    }
};
```

**Fake Effectors for Tests:**

```zig
pub const FakeEffectorTable = struct {
    db_data: std.StringHashMap([]const u8),

    pub fn get(self: *FakeEffectorTable, effect: Effect) Effector {
        return switch (effect) {
            .db_get => Effector{ .executeFn = fakeDbGet },
            .db_put => Effector{ .executeFn = fakeDbPut },
            else => unreachable,
        };
    }

    fn fakeDbGet(effect: Effect, ctx: *CtxBase) ![]const u8 {
        const db_get = effect.db_get;
        return self.db_data.get(db_get.key) orelse error.KeyNotFound;
    }

    fn fakeDbPut(effect: Effect, ctx: *CtxBase) ![]const u8 {
        const db_put = effect.db_put;
        try self.db_data.put(db_put.key, db_put.value);
        return "ok";
    }
};
```

---

## Ownership and Lifetimes

### Arena-Only Rule

**All slot values must be arena-owned or static.**

```zig
pub fn slotPutOwned(
    self: *CtxBase,
    comptime slot: SlotEnum,
    value: anytype,
) !void {
    const T = @TypeOf(value);

    // String slices: duplicate into arena
    if (T == []const u8 or T == []u8) {
        const owned = try self.allocator.dupe(u8, value);
        try self.slots.put(slot, owned);
        return;
    }

    // Structs: recursively ensure arena ownership
    if (@typeInfo(T) == .Struct) {
        const owned = try self.allocator.create(T);
        owned.* = try cloneToArena(T, value, self.allocator);
        try self.slots.put(slot, owned);
        return;
    }

    // Primitives: copy directly
    try self.slots.put(slot, value);
}
```

**Guideline:**
- Allocate all slot data in request arena
- No manual `deinit()` required
- Arena cleanup happens at end of request

### Response Building

**All response bodies must be arena-allocated or static slices.**

```zig
pub fn step_respond(ctx: *RespondCtx) !Decision {
    const post = try ctx.require(BlogSlot.Post);

    // JSON serialization allocates in arena
    const json = try ctx.base.toJson(post);

    return zerver.done(.{
        .status = 201,
        .body = .{ .complete = json },  // Arena-owned
    });
}
```

**Invalid:**
```zig
pub fn step_respond(ctx: *RespondCtx) !Decision {
    var buffer: [1024]u8 = undefined;  // Stack allocation
    const json = try std.json.stringify(post, .{}, &buffer);

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = json },  // ❌ Stack pointer will be invalid
    });
}
```

### Effect-to-Slot Type Adapters

**Decision:** All effect outputs are `[]const u8` (raw bytes). Decoding happens in two ways:

**Option 1: Dedicated decode step** (Recommended)

```zig
// Step 1: Execute effect, fills slot with JSON bytes
pub fn step_fetch_user(ctx: *FetchCtx) !Decision {
    const user_id = try ctx.require(BlogSlot.UserId);

    const effects = &.{
        ctx.base.db(.get, BlogSlots.slotId(.UserJson), .{
            .key = try std.fmt.allocPrint(ctx.base.allocator, "user:{s}", .{user_id}),
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

// Step 2: Decode JSON bytes to typed struct
pub fn step_decode_user(ctx: *DecodeCtx) !Decision {
    const user_json = try ctx.require(BlogSlot.UserJson);
    const user = try ctx.base.parseJson(User, user_json);
    try ctx.put(BlogSlot.User, user);
    return zerver.continue_();
}
```

**Option 2: Per-slot codec** (Future enhancement)

```zig
pub fn BlogSlotCodec(comptime slot: BlogSlot) type {
    return switch (slot) {
        .UserJson => struct {
            pub fn decode(bytes: []const u8, allocator: Allocator) !User {
                return std.json.parseFromSlice(User, allocator, bytes, .{});
            }
        },
        .PostJson => struct {
            pub fn decode(bytes: []const u8, allocator: Allocator) !Post {
                return std.json.parseFromSlice(Post, allocator, bytes, .{});
            }
        },
        else => void,  // No codec
    };
}

// Automatic decoding when slot has codec
try slots.putWithCodec(BlogSlot.UserJson, raw_bytes);
```

**Recommendation:** Start with Option 1 (dedicated steps). Add Option 2 later if decoding boilerplate becomes burdensome.

---

## Ergonomics

### Route Builder DSL

```zig
pub fn route(comptime config: anytype) RouteSpec {
    return RouteSpec.init(config);
}

pub fn step(comptime name: []const u8, comptime fn: anytype) StepSpec {
    return StepSpec{
        .name = name,
        .fn = fn,
        .reads = extractReads(fn),   // Comptime extraction from CtxView
        .writes = extractWrites(fn), // Comptime extraction from CtxView
    };
}
```

**Usage:**

```zig
const create_post_route = zerver.route(.{
    step("parse", step_parse),
    step("validate", step_validate),
    step("create", step_create),
    step("respond", step_respond),
});
```

### Effect Helpers on CtxBase

**Design:** Provide thin, ergonomic builders that produce wire format effects. Effects use generic methods (e.g., `db()`, `http()`) with configuration via CtxView.

```zig
pub const CtxBase = struct {
    // ... fields ...

    /// Generic database effect
    /// Database selection happens via CtxView configuration
    pub fn db(
        self: *CtxBase,
        comptime operation: DbOperation,
        token: u32,
        config: anytype,
    ) Effect {
        return switch (operation) {
            .get => .{ .db_get = .{
                .key = config.key,
                .token = token,
                .required = config.required orelse true,
            }},
            .put => .{ .db_put = .{
                .key = config.key,
                .value = config.value,
                .token = token,
            }},
            .del => .{ .db_del = .{
                .key = config.key,
                .token = token,
            }},
            .query => .{ .db_query = .{
                .sql = config.sql,
                .params = config.params,
                .token = token,
            }},
        };
    }

    /// Generic HTTP effect
    pub fn http(
        self: *CtxBase,
        token: u32,
        config: HttpConfig,
    ) Effect {
        return .{ .http_call = .{
            .method = config.method,
            .url = config.url,
            .headers = config.headers orelse &.{},
            .body = config.body orelse &.{},
            .token = token,
            .timeout_ms = config.timeout_ms orelse 30000,
        }};
    }
};

pub const DbOperation = enum {
    get,
    put,
    del,
    query,
};

pub const HttpConfig = struct {
    method: HttpMethod,
    url: []const u8,
    headers: ?[]const Header = null,
    body: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};
```

**CtxView Database Selection:**

```zig
pub fn CtxView(comptime config: anytype) type {
    return struct {
        base: *CtxBase,

        // ... other methods ...

        /// Database-scoped effect builder
        /// Selects database based on CtxView configuration
        pub fn db(
            self: *@This(),
            comptime operation: DbOperation,
            token: u32,
            effect_config: anytype,
        ) Effect {
            const db_name = if (@hasField(@TypeOf(config), "database"))
                config.database
            else
                "default";

            // Store database name in effect metadata for runtime resolution
            var enriched_config = effect_config;
            enriched_config.database = db_name;

            return self.base.db(operation, token, enriched_config);
        }
    };
}
```

**Usage Examples:**

```zig
// Define CtxView with database selection
const BlogDbCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{BlogSlot.PostId},
    .database = "blog_db",  // Selects specific database
});

pub fn step_fetch_post(ctx: *BlogDbCtx) !Decision {
    const post_id = try ctx.require(BlogSlot.PostId);
    const key = try std.fmt.allocPrint(ctx.base.allocator, "post:{s}", .{post_id});

    const effects = &.{
        // Uses blog_db automatically from CtxView config
        ctx.db(.get, BlogSlots.slotId(.PostJson), .{ .key = key }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

// HTTP effect example
pub fn step_send_notification(ctx: *NotifyCtx) !Decision {
    const payload = try ctx.require(BlogSlot.NotificationPayload);

    const effects = &.{
        ctx.base.http(BlogSlots.slotId(.HttpResult), .{
            .method = .POST,
            .url = "https://api.example.com/notify",
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = "Bearer token123" },
            },
            .body = payload,
            .timeout_ms = 5000,
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

// Query example
pub fn step_query_posts(ctx: *QueryCtx) !Decision {
    const author_id = try ctx.require(BlogSlot.AuthorId);

    const effects = &.{
        ctx.db(.query, BlogSlots.slotId(.PostsJson), .{
            .sql = "SELECT * FROM posts WHERE author_id = $1 ORDER BY created_at DESC",
            .params = &.{
                .{ .string = author_id },
            },
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}
```

### Typed Compute Builders

**Design:** Typed union that produces wire `ComputeTask` for comptime safety and lower cognitive load.

```zig
/// Typed compute operations
pub const ComputeOp = union(enum) {
    hash: struct {
        algorithm: HashAlgorithm,
        input_slot: u32,
    },
    encode: struct {
        format: EncodingFormat,
        input_slot: u32,
    },
    validate: struct {
        rule: []const u8,
        input_slot: u32,
    },
    transform: struct {
        spec: []const u8,
        input_slot: u32,
    },
    custom: struct {
        name: []const u8,
        input_slot: u32,
        metadata: ?[]const u8 = null,
    },
};

pub const HashAlgorithm = enum {
    sha256,
    sha512,
    blake3,
};

pub const EncodingFormat = enum {
    base64,
    base64url,
    hex,
};

/// Build compute task from typed operation
pub fn compute(
    op: ComputeOp,
    out_token: u32,
    opts: struct {
        timeout_ms: u32 = 0,
        cpu_budget_ms: u32 = 0,
        priority: u8 = 128,
    },
) Effect {
    // Encode operation name deterministically
    const op_name = switch (op) {
        .hash => |p| blk: {
            break :blk switch (p.algorithm) {
                .sha256 => "hash:sha256",
                .sha512 => "hash:sha512",
                .blake3 => "hash:blake3",
            };
        },
        .encode => |p| blk: {
            break :blk switch (p.format) {
                .base64 => "encode:base64",
                .base64url => "encode:base64url",
                .hex => "encode:hex",
            };
        },
        .validate => "validate",
        .transform => "transform",
        .custom => |p| p.name,
    };

    return .{ .compute_task = .{
        .operation = op_name,
        .token = out_token,
        .timeout_ms = opts.timeout_ms,
        .cpu_budget_ms = opts.cpu_budget_ms,
        .priority = opts.priority,
        .metadata = null,  // Or pointer to arena-allocated metadata
    }};
}
```

**Usage Examples:**

```zig
// Hash a post's content
pub fn step_hash_content(ctx: *HashCtx) !Decision {
    const effects = &.{
        compute(
            .{
                .hash = .{
                    .algorithm = .sha256,
                    .input_slot = BlogSlots.slotId(.PostContent),
                },
            },
            BlogSlots.slotId(.ContentHash),
            .{ .timeout_ms = 1000 },
        ),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

// Encode data to base64
pub fn step_encode_data(ctx: *EncodeCtx) !Decision {
    const effects = &.{
        compute(
            .{
                .encode = .{
                    .format = .base64,
                    .input_slot = BlogSlots.slotId(.RawData),
                },
            },
            BlogSlots.slotId(.EncodedData),
            .{},
        ),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}

// Custom compute operation
pub fn step_custom_transform(ctx: *TransformCtx) !Decision {
    const effects = &.{
        compute(
            .{
                .custom = .{
                    .name = "slugify",
                    .input_slot = BlogSlots.slotId(.PostTitle),
                },
            },
            BlogSlots.slotId(.PostSlug),
            .{ .timeout_ms = 500 },
        ),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}
```

**Ownership Notes:**
- Operation names are static strings or arena-allocated
- Metadata (if used) must be arena-allocated to survive until runtime reads it
- Compute outputs are `[]const u8` - decode in follow-up step

**Usage in Steps:**

```zig
pub fn step_create(ctx: *CreateCtx) !Decision {
    const input = try ctx.require(BlogSlot.PostInput);

    const post = Post{
        .id = ctx.base.newId(),
        .title = input.title,
        .content = input.content,
        .created_at = ctx.base.timestamp(),
    };

    try ctx.put(BlogSlot.Post, post);

    const post_json = try ctx.base.toJson(post);
    const post_key = try ctx.base.allocPrint("post:{s}", .{post.id});

    const effects = &.{
        ctx.base.db(.put, BlogSlots.slotId(.PostJson), .{
            .key = post_key,
            .value = post_json,
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}
```

---

## Request Flow Example

### Create Blog Post Pipeline

**Pipeline:** `[parse_and_validate] → [load_user_and_quota] → [build_post_and_slug] → [save_and_notify] → [respond]`

**Shows:**
- Pure steps grouped logically
- Parallel effects (load user + check quota)
- Multiple effect types (db, compute, http)
- Clear pure/impure boundaries

---

#### Step 1: Parse and Validate (Pure)

**Group pure validation logic together - no I/O needed.**

```zig
const ParseAndValidateCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .writes = &.{ BlogSlot.PostInput, BlogSlot.AuthorId },
});

pub fn step_parse_and_validate(ctx: *ParseAndValidateCtx) !Decision {
    // Parse JSON input
    const input = try ctx.base.json(PostInput);

    // Validate (pure checks)
    if (input.title.len == 0) {
        return zerver.fail(ErrorCode.InvalidInput, "post", "title_empty");
    }
    if (input.content.len == 0) {
        return zerver.fail(ErrorCode.InvalidInput, "post", "content_empty");
    }
    if (input.title.len > 200) {
        return zerver.fail(ErrorCode.InvalidInput, "post", "title_too_long");
    }

    // Extract author ID from auth token
    const author_id = try ctx.base.getAuthUserId();

    // Fill slots
    try ctx.put(BlogSlot.PostInput, input);
    try ctx.put(BlogSlot.AuthorId, author_id);

    return zerver.continue_();
}
```

---

#### Step 2: Load User and Check Quota (Parallel Effects)

**Fetch user data and check posting quota concurrently.**

```zig
const LoadUserAndQuotaCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{ BlogSlot.AuthorId },
    .writes = &.{},  // Effects fill User and QuotaInfo slots
});

pub fn step_load_user_and_quota(ctx: *LoadUserAndQuotaCtx) !Decision {
    const author_id = try ctx.require(BlogSlot.AuthorId);

    const user_key = try std.fmt.allocPrint(ctx.base.allocator, "user:{s}", .{author_id});
    const quota_key = try std.fmt.allocPrint(ctx.base.allocator, "quota:{s}", .{author_id});

    // Parallel effects: load user + check quota
    const effects = &.{
        ctx.db(.get, BlogSlots.slotId(.UserJson), .{ .key = user_key }),
        ctx.db(.get, BlogSlots.slotId(.QuotaJson), .{ .key = quota_key }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Parallel,      // Run concurrently
        .join = .all_required,  // Both must succeed
    });
}
```

---

#### Step 3: Build Post and Generate Slug (Pure + Compute)

**Pure logic to build post, then compute effect to generate URL slug.**

```zig
const BuildPostCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{ BlogSlot.PostInput, BlogSlot.AuthorId, BlogSlot.UserJson, BlogSlot.QuotaJson },
    .writes = &.{ BlogSlot.Post },
});

pub fn step_build_post_and_slug(ctx: *BuildPostCtx) !Decision {
    const input = try ctx.require(BlogSlot.PostInput);
    const author_id = try ctx.require(BlogSlot.AuthorId);
    const quota_json = try ctx.require(BlogSlot.QuotaJson);

    // Parse quota and check limit (pure)
    const quota = try std.json.parseFromSlice(QuotaInfo, ctx.base.allocator, quota_json, .{});
    if (quota.posts_today >= quota.daily_limit) {
        return zerver.fail(ErrorCode.Forbidden, "quota", "daily_limit_exceeded");
    }

    // Build post struct (pure)
    const post = Post{
        .id = ctx.base.newId(),
        .title = input.title,
        .content = input.content,
        .author_id = author_id,
        .created_at = ctx.base.timestamp(),
        .slug = "",  // Will be filled by compute effect
    };

    try ctx.put(BlogSlot.Post, post);

    // Generate URL slug from title (compute effect)
    const effects = &.{
        compute(
            .{
                .custom = .{
                    .name = "slugify",
                    .input_slot = BlogSlots.slotId(.Post) + 1,  // Read from PostTitle sub-field
                },
            },
            BlogSlots.slotId(.PostSlug),
            .{ .timeout_ms = 500 },
        ),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}
```

---

#### Step 4: Save Post and Send Notification (Parallel Effects)

**Save to database and notify followers concurrently.**

```zig
const SaveAndNotifyCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{ BlogSlot.Post, BlogSlot.PostSlug, BlogSlot.AuthorId },
    .writes = &.{},  // Effects fill SaveResult and NotifyResult
});

pub fn step_save_and_notify(ctx: *SaveAndNotifyCtx) !Decision {
    const post = try ctx.require(BlogSlot.Post);
    const slug = try ctx.require(BlogSlot.PostSlug);
    const author_id = try ctx.require(BlogSlot.AuthorId);

    // Update post with generated slug
    var post_final = post;
    post_final.slug = slug;

    const post_json = try ctx.base.toJson(post_final);
    const post_key = try std.fmt.allocPrint(ctx.base.allocator, "post:{s}", .{post_final.id});

    // Build notification payload
    const notify_payload = try std.fmt.allocPrint(
        ctx.base.allocator,
        \\{{"event":"new_post","author":"{s}","post_id":"{s}","title":"{s}"}}
    ,
        .{ author_id, post_final.id, post_final.title },
    );

    // Parallel effects: save post + send notification
    const effects = &.{
        ctx.db(.put, BlogSlots.slotId(.SaveResult), .{
            .key = post_key,
            .value = post_json,
        }),
        ctx.base.http(BlogSlots.slotId(.NotifyResult), .{
            .method = .POST,
            .url = "https://notifications.example.com/broadcast",
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .body = notify_payload,
        }),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Parallel,  // Run concurrently
        .join = .any,       // Post save must succeed; notification is best-effort
    });
}
```

---

#### Step 5: Respond (Pure)

**Return response with created post.**

```zig
const RespondCtx = zerver.CtxView(.{
    .slotTypeFn = BlogSlotType,
    .reads = &.{ BlogSlot.Post, BlogSlot.PostSlug },
});

pub fn step_respond(ctx: *RespondCtx) !Decision {
    const post = try ctx.require(BlogSlot.Post);
    const slug = try ctx.require(BlogSlot.PostSlug);

    // Build final post with slug
    var post_final = post;
    post_final.slug = slug;

    const json = try ctx.base.toJson(post_final);

    return zerver.done(.{
        .status = 201,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Location", .value = try std.fmt.allocPrint(
                ctx.base.allocator,
                "/posts/{s}",
                .{slug},
            )},
        },
        .body = .{ .complete = json },
    });
}
```

---

#### Route Registration

```zig
pub fn registerRoutes(server: *zerver.Server) !void {
    try server.addRoute(
        .POST,
        "/posts",
        zerver.route(.{
            step("parse_and_validate", step_parse_and_validate),
            step("load_user_and_quota", step_load_user_and_quota),
            step("build_post_and_slug", step_build_post_and_slug),
            step("save_and_notify", step_save_and_notify),
            step("respond", step_respond),
        }),
    );
}
```

---

## Execution Flow

### Pure → Impure → Pure

1. **Pure Interpreter** evaluates steps:
   - `step_parse` → fills `PostInput` slot → `.Continue`
   - `step_validate` → reads `PostInput` → `.Continue`
   - `step_create` → fills `Post`, `PostJson` slots → `.need` with `db_put` effect

2. **Runtime** executes effects:
   - Execute `db_put` effect (write to database)
   - Write result to slot if needed

3. **Pure Interpreter** resumes:
   - `step_respond` → reads `Post` slot → `.Done` with response

---

## Effect Types

### Database Effects

```zig
pub const DbGetEffect = struct {
    key: []const u8,
    token: u32,
    required: bool = true,
};

pub const DbPutEffect = struct {
    key: []const u8,
    value: []const u8,
    token: u32,
};

pub const DbDelEffect = struct {
    key: []const u8,
    token: u32,
};
```

### Compute Effect (Pure Functions from Feature Code)

```zig
pub const ComputeEffect = struct {
    compute_fn: *const fn (ctx: *ComputeContext) callconv(.c) c_int,
    input_slots: []const u32,
    token: u32,
    timeout_ms: ?u32 = null,
};

pub const ComputeContext = extern struct {
    allocator: *anyopaque,
    inputs: [*]const ComputeInput,
    input_count: usize,
    output: *ComputeOutput,
    user_data: ?*anyopaque,
};
```

**Feature DLL Example:**

```zig
// features/blog/src/compute.zig

export fn computeSlugify(ctx: *ComputeContext) callconv(.c) c_int {
    const inputs = ctx.inputs[0..ctx.input_count];
    if (inputs.len != 1) return 1;

    const title = inputs[0].data[0..inputs[0].len];
    const slug = slugify(title);

    ctx.output.setData(slug.ptr, slug.len);
    return 0;
}
```

**Usage in Step:**

```zig
pub fn step_generate_slug(ctx: *SlugCtx) !Decision {
    const effects = &.{
        ctx.base.compute(
            BlogSlots.slotId(.Slug),
            &computeSlugify,
            &.{ BlogSlots.slotId(.PostTitle) },
        ),
    };

    return zerver.need(.{
        .effects = effects,
        .mode = .Sequential,
        .join = .all,
    });
}
```

---

## Production-Ready Considerations

### Saga Semantics & Compensations

**Goal:** Handle partial failures in multi-effect operations with automatic compensations.

#### Compensation Model

```zig
pub const Need = struct {
    effects: []const Effect,
    mode: Mode,
    join: Join,

    /// Compensations run in reverse order if pipeline fails
    compensations: ?[]const Effect = null,
};

pub const Effect = union(enum) {
    db_get: DbGetEffect,
    db_put: DbPutEffect,
    db_del: DbDelEffect,
    http_call: HttpCallEffect,
    compute_task: ComputeTask,

    /// Compensation effect (undo a previous effect)
    compensate: CompensateEffect,
};

pub const CompensateEffect = struct {
    /// Original effect that succeeded
    original: Effect,

    /// Compensation action
    action: CompensationAction,
};

pub const CompensationAction = union(enum) {
    /// Delete the key that was written
    db_delete: struct { key: []const u8 },

    /// Restore previous value
    db_restore: struct { key: []const u8, old_value: []const u8 },

    /// Call HTTP endpoint to undo
    http_rollback: struct { url: []const u8, payload: []const u8 },

    /// Custom compensation function
    custom: *const fn (*CtxBase) anyerror!void,
};
```

#### Usage Example

```zig
pub fn step_create_order(ctx: *CreateOrderCtx) !Decision {
    const order = try ctx.require(OrderSlot.Order);
    const user = try ctx.require(OrderSlot.User);

    // Define compensations for each effect
    const effects = &.{
        // Reserve inventory
        ctx.db(.put, OrderSlots.slotId(.InventoryReserved), .{
            .key = try std.fmt.allocPrint(ctx.base.allocator, "inventory:{s}", .{order.product_id}),
            .value = try ctx.base.toJson(.{ .reserved = order.quantity }),
        }),

        // Charge payment
        ctx.base.http(OrderSlots.slotId(.PaymentResult), .{
            .method = .POST,
            .url = "https://payments.example.com/charge",
            .body = try ctx.base.toJson(.{
                .user_id = user.id,
                .amount = order.total,
                .idempotency_key = order.id,  // Ensures idempotent retries
            }),
        }),

        // Create order record
        ctx.db(.put, OrderSlots.slotId(.OrderCreated), .{
            .key = try std.fmt.allocPrint(ctx.base.allocator, "order:{s}", .{order.id}),
            .value = try ctx.base.toJson(order),
        }),
    };

    // Define compensations (reverse order)
    const compensations = &.{
        // Delete order if created
        Effect{ .compensate = .{
            .original = effects[2],
            .action = .{ .db_delete = .{
                .key = try std.fmt.allocPrint(ctx.base.allocator, "order:{s}", .{order.id}),
            }},
        }},

        // Refund payment if charged
        Effect{ .compensate = .{
            .original = effects[1],
            .action = .{ .http_rollback = .{
                .url = "https://payments.example.com/refund",
                .payload = try ctx.base.toJson(.{ .charge_id = order.payment_id }),
            }},
        }},

        // Release inventory if reserved
        Effect{ .compensate = .{
            .original = effects[0],
            .action = .{ .db_delete = .{
                .key = try std.fmt.allocPrint(ctx.base.allocator, "inventory:{s}", .{order.product_id}),
            }},
        }},
    };

    return zerver.need(.{
        .effects = effects,
        .compensations = compensations,
        .mode = .Sequential,
        .join = .all_required,  // If any fails, run compensations
    });
}
```

#### Compensation Execution

```zig
pub fn executeWithCompensation(
    executor: *EffectExecutor,
    need: Need,
    ctx: *CtxBase,
) !void {
    var completed = std.ArrayList(Effect).init(ctx.allocator);
    defer completed.deinit();

    for (need.effects, 0..) |effect, i| {
        executor.execute(effect, ctx) catch |err| {
            // Effect failed - run compensations for completed effects
            slog.warn("Effect failed, running compensations", &.{
                slog.Attr.int("effect_index", i),
                slog.Attr.string("error", @errorName(err)),
            });

            if (need.compensations) |comps| {
                // Run compensations in reverse order
                var j = completed.items.len;
                while (j > 0) {
                    j -= 1;
                    runCompensation(comps[j], ctx) catch |comp_err| {
                        slog.err("Compensation failed", &.{
                            slog.Attr.int("compensation_index", j),
                            slog.Attr.string("error", @errorName(comp_err)),
                        });
                    };
                }
            }

            return err;
        };

        try completed.append(effect);
    }
}
```

#### Cancellation Policy

For `.any` and `.first_success` join strategies, define what happens to in-flight effects:

```zig
pub const CancellationPolicy = enum {
    /// Let all effects complete, ignore losers
    complete_all,

    /// Cancel in-flight effects, compensate completed
    cancel_and_compensate,

    /// Cancel in-flight, no compensation (idempotent effects only)
    cancel_only,
};

pub const Join = enum {
    all,
    all_required,
    any,
    first_success,

    pub fn cancellationPolicy(self: Join) CancellationPolicy {
        return switch (self) {
            .all, .all_required => .complete_all,
            .any => .cancel_and_compensate,
            .first_success => .cancel_only,
        };
    }
};
```

---

### Security & Resource Limits

**Goal:** Protect against SSRF, SQL injection, resource exhaustion.

#### HTTP SSRF Protection

```zig
pub const HttpSecurityPolicy = struct {
    /// Allowlist of permitted host patterns
    allowed_hosts: []const []const u8 = &.{
        "*.example.com",
        "api.trusted-partner.com",
    },

    /// Blocklist of forbidden schemes
    forbidden_schemes: []const []const u8 = &.{
        "file",
        "ftp",
        "gopher",
    },

    /// Maximum response size (bytes)
    max_response_size: usize = 10 * 1024 * 1024,  // 10MB

    /// Timeout for HTTP calls
    default_timeout_ms: u32 = 30_000,

    /// Follow redirects?
    follow_redirects: bool = false,
};

pub fn validateHttpEffect(effect: HttpCallEffect, policy: HttpSecurityPolicy) !void {
    const uri = try std.Uri.parse(effect.url);

    // Check scheme
    for (policy.forbidden_schemes) |forbidden| {
        if (std.mem.eql(u8, uri.scheme, forbidden)) {
            return error.ForbiddenScheme;
        }
    }

    // Check host allowlist
    const host = uri.host orelse return error.MissingHost;
    var allowed = false;
    for (policy.allowed_hosts) |pattern| {
        if (matchHostPattern(host, pattern)) {
            allowed = true;
            break;
        }
    }

    if (!allowed) {
        slog.warn("HTTP effect blocked by security policy", &.{
            slog.Attr.string("url", effect.url),
            slog.Attr.string("host", host),
        });
        return error.HostNotAllowed;
    }

    // Enforce timeout
    if (effect.timeout_ms > policy.default_timeout_ms) {
        return error.TimeoutTooLong;
    }
}
```

#### SQL Injection Protection

```zig
pub const SqlSecurityPolicy = struct {
    /// Only allow parameterized queries
    require_parameterized: bool = true,

    /// Maximum query length
    max_query_length: usize = 10_000,

    /// Forbidden keywords (DDL, etc.)
    forbidden_keywords: []const []const u8 = &.{
        "DROP",
        "TRUNCATE",
        "ALTER",
        "CREATE",
        "GRANT",
        "REVOKE",
    },
};

pub fn validateSqlQuery(effect: DbQueryEffect, policy: SqlSecurityPolicy) !void {
    if (effect.sql.len > policy.max_query_length) {
        return error.QueryTooLong;
    }

    // Check for forbidden keywords
    const sql_upper = try std.ascii.allocUpperString(std.heap.page_allocator, effect.sql);
    defer std.heap.page_allocator.free(sql_upper);

    for (policy.forbidden_keywords) |keyword| {
        if (std.mem.indexOf(u8, sql_upper, keyword)) |_| {
            slog.err("SQL query blocked - forbidden keyword", &.{
                slog.Attr.string("keyword", keyword),
                slog.Attr.string("sql", effect.sql),
            });
            return error.ForbiddenKeyword;
        }
    }

    // Ensure parameterized (contains $1, $2, etc.)
    if (policy.require_parameterized and effect.params.len > 0) {
        // Verify placeholders match param count
        // (Implementation detail)
    }
}
```

#### Per-Route Resource Budgets

```zig
pub const ResourceBudget = struct {
    /// Maximum CPU time for compute effects (ms)
    max_cpu_ms: u32 = 5_000,

    /// Maximum memory for request arena (bytes)
    max_memory_bytes: usize = 100 * 1024 * 1024,  // 100MB

    /// Maximum outbound HTTP body size (bytes)
    max_outbound_bytes: usize = 1 * 1024 * 1024,  // 1MB

    /// Maximum concurrent effects
    max_concurrent_effects: u32 = 10,

    /// Maximum effects per request
    max_total_effects: u32 = 50,
};

pub const RouteSpec = struct {
    steps: []const StepSpec,
    budget: ResourceBudget = .{},  // Per-route override

    // ... other fields
};
```

---

### Observability & Tracing

**Goal:** First-class distributed tracing with correlation.

#### Trace Events

```zig
pub const TraceEvent = union(enum) {
    request_start: struct {
        request_id: []const u8,
        method: HttpMethod,
        path: []const u8,
        timestamp_ns: i64,
    },

    step_start: struct {
        request_id: []const u8,
        step_name: []const u8,
        step_index: u32,
        timestamp_ns: i64,
    },

    step_end: struct {
        request_id: []const u8,
        step_name: []const u8,
        decision: []const u8,  // "Continue", "need", "Done", "Fail"
        duration_ns: i64,
    },

    effect_start: struct {
        request_id: []const u8,
        step_name: []const u8,
        effect_type: []const u8,  // "db_get", "http_call", etc.
        effect_index: u32,
        token: u32,
        timestamp_ns: i64,
    },

    effect_end: struct {
        request_id: []const u8,
        effect_type: []const u8,
        outcome: []const u8,  // "success", "error"
        duration_ns: i64,
    },

    slot_write: struct {
        request_id: []const u8,
        step_name: []const u8,
        slot_id: u32,
        timestamp_ns: i64,
    },

    request_end: struct {
        request_id: []const u8,
        status: u16,
        duration_ns: i64,
    },
};

pub const TraceCollector = struct {
    events: std.ArrayList(TraceEvent),
    mutex: std.Thread.Mutex,

    pub fn emit(self: *TraceCollector, event: TraceEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.events.append(event) catch return;

        // Also log structured
        logTraceEvent(event);
    }
};

fn logTraceEvent(event: TraceEvent) void {
    switch (event) {
        .step_start => |e| slog.info("step_start", &.{
            slog.Attr.string("request_id", e.request_id),
            slog.Attr.string("step", e.step_name),
            slog.Attr.int("index", e.step_index),
        }),
        .effect_end => |e| slog.info("effect_end", &.{
            slog.Attr.string("request_id", e.request_id),
            slog.Attr.string("type", e.effect_type),
            slog.Attr.string("outcome", e.outcome),
            slog.Attr.int("duration_ms", @divTrunc(e.duration_ns, std.time.ns_per_ms)),
        }),
        // ... other events
        else => {},
    }
}
```

#### Correlation

```zig
pub const CtxBase = struct {
    request_id: []const u8,  // Generated on request start
    trace_collector: *TraceCollector,

    // ... other fields

    pub fn emitStepStart(self: *CtxBase, step_name: []const u8, index: u32) void {
        self.trace_collector.emit(.{ .step_start = .{
            .request_id = self.request_id,
            .step_name = step_name,
            .step_index = index,
            .timestamp_ns = std.time.nanoTimestamp(),
        }});
    }
};
```

---

### Performance Optimizations

**Goal:** Minimize allocations, normalize once, cap concurrency.

#### Small-Vector Headers

```zig
pub const Response = struct {
    status: u16,

    /// Inline headers for common case (≤4 headers)
    headers_inline: [4]Header = undefined,
    headers_len: u8 = 0,

    /// Overflow for >4 headers
    headers_extra: ?[]const Header = null,

    body: Body,

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.headers_len < 4) {
            self.headers_inline[self.headers_len] = .{
                .name = name,
                .value = value,
            };
            self.headers_len += 1;
        } else {
            // Allocate extra
            // ...
        }
    }

    pub fn headers(self: *const Response) []const Header {
        if (self.headers_extra) |extra| {
            // Return combined view
            // ...
        }
        return self.headers_inline[0..self.headers_len];
    }
};
```

#### Header Normalization

```zig
pub fn parseHeaders(allocator: Allocator, raw_headers: []const Header) ![]Header {
    var normalized = try allocator.alloc(Header, raw_headers.len);

    for (raw_headers, 0..) |header, i| {
        // Normalize name to lowercase once
        const name_lower = try std.ascii.allocLowerString(allocator, header.name);

        normalized[i] = .{
            .name = name_lower,
            .value = header.value,
        };
    }

    return normalized;
}
```

#### Effect Concurrency Cap

```zig
pub const EffectExecutor = struct {
    worker_pool: *WorkerPool,
    max_concurrent: u32 = 10,  // Configurable per route

    pub fn executeParallel(
        self: *EffectExecutor,
        need: Need,
        ctx: *CtxBase,
    ) !void {
        // Batch effects into chunks of max_concurrent
        var i: usize = 0;
        while (i < need.effects.len) {
            const batch_size = @min(self.max_concurrent, need.effects.len - i);
            const batch = need.effects[i..i + batch_size];

            // Execute batch in parallel
            try self.executeBatch(batch, ctx, need.join);

            i += batch_size;
        }
    }
};
```

---

### Testing Strategy

**Goal:** Pure interpreter harness, golden tests, fuzz testing.

#### Pure Interpreter Test Harness

```zig
pub const TestHarness = struct {
    allocator: Allocator,
    fake_effects: FakeEffectorTable,
    trace_events: std.ArrayList(TraceEvent),

    pub fn init(allocator: Allocator) TestHarness {
        return .{
            .allocator = allocator,
            .fake_effects = FakeEffectorTable.init(allocator),
            .trace_events = std.ArrayList(TraceEvent).init(allocator),
        };
    }

    pub fn runPipeline(
        self: *TestHarness,
        route: RouteSpec,
        request: TestRequest,
    ) !TestResponse {
        var ctx = try CtxBase.initTest(self.allocator, request);
        defer ctx.deinit();

        // Run pure interpreter with fake effects
        var decision = try interpreter.evalUntilNeedOrDone(&ctx, route);

        while (decision == .need) {
            // Execute fake effects
            try self.fake_effects.execute(decision.need, &ctx);

            // Resume interpreter
            decision = try interpreter.evalUntilNeedOrDone(&ctx, route);
        }

        return switch (decision) {
            .Done => |response| TestResponse.fromResponse(response),
            .Fail => |err| TestResponse.fromError(err),
            else => error.UnexpectedDecision,
        };
    }

    pub fn setFakeEffect(
        self: *TestHarness,
        effect_type: EffectType,
        token: u32,
        result: []const u8,
    ) !void {
        try self.fake_effects.stub(effect_type, token, result);
    }
};

test "create post pipeline with fake effects" {
    var harness = TestHarness.init(testing.allocator);
    defer harness.deinit();

    // Stub HTTP effect
    try harness.setFakeEffect(.http_call, 1,
        \\{"id":"post-123","status":"created"}
    );

    // Run pipeline
    const response = try harness.runPipeline(create_post_route, .{
        .method = .POST,
        .path = "/posts",
        .body = \\{"title":"Test Post","content":"Hello World"}
    });

    // Assertions
    try testing.expectEqual(201, response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, "post-123") != null);
}
```

#### Golden Tests for Error Pages

```zig
test "error pages - 404 golden" {
    var harness = TestHarness.init(testing.allocator);
    defer harness.deinit();

    const response = try harness.runPipeline(not_found_route, .{
        .method = .GET,
        .path = "/nonexistent",
    });

    // Compare to golden file
    const golden = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        "testdata/golden/404.html",
        1024 * 1024,
    );
    defer testing.allocator.free(golden);

    try testing.expectEqualStrings(golden, response.body);
}
```

#### Fuzz Testing

```zig
test "fuzz - slot wiring validation" {
    var rng = std.rand.DefaultPrng.init(12345);
    const random = rng.random();

    for (0..1000) |_| {
        // Generate random route configuration
        const num_steps = random.intRangeAtMost(u8, 1, 10);

        var steps = std.ArrayList(StepSpec).init(testing.allocator);
        defer steps.deinit();

        for (0..num_steps) |i| {
            const num_reads = random.intRangeAtMost(u8, 0, 5);
            const num_writes = random.intRangeAtMost(u8, 0, 5);

            // Random reads/writes
            // ... generate StepSpec ...
        }

        // Validate should catch errors or succeed
        _ = routeChecked(.{ .steps = steps.items }, .{}) catch continue;
    }
}
```

---

### Effect Builder Helpers

**Goal:** Ergonomic builders for common effect patterns.

```zig
/// HTTP JSON POST helper
pub fn httpJsonPost(url: []const u8, body: []const u8, token: u32) Effect {
    return .{ .http_call = .{
        .method = .POST,
        .url = url,
        .body = body,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .token = token,
        .timeout_ms = 3000,
    }};
}

/// Database query helper
pub fn dbQ(sql: []const u8, params: []const SqlParam, token: u32) Effect {
    return .{ .db_query = .{
        .sql = sql,
        .params = params,
        .token = token,
    }};
}

/// Convenience method on CtxBase for effect batching
pub const CtxBase = struct {
    // ... other fields ...

    /// Helper to return Need with effects
    pub fn runEffects(self: *CtxBase, effects: []const Effect) Decision {
        return .{ .need = .{
            .effects = effects,
            .mode = .Sequential,
            .join = .all,
        }};
    }

    /// Helper for parallel effects
    pub fn runParallel(self: *CtxBase, effects: []const Effect, join: Join) Decision {
        return .{ .need = .{
            .effects = effects,
            .mode = .Parallel,
            .join = join,
        }};
    }
};
```

---

### Streamlined Happy Path Example

**This is the recommended pattern for new features:**

```zig
// Slot definitions
const BlogSlot = enum(u32) {
    Input = 0,
    PostJson = 1,
};

fn BlogSlotType(comptime s: BlogSlot) type {
    return switch (s) {
        .Input => PostInput,
        .PostJson => []const u8,
    };
}

const BlogSlots = SlotSchema(BlogSlot, BlogSlotType);

// Typed context views
const Parse = CtxView(.{ .slotTypeFn = BlogSlotType, .writes = &.{BlogSlot.Input} });
const Validate = CtxView(.{ .slotTypeFn = BlogSlotType, .reads = &.{BlogSlot.Input} });
const Plan = CtxView(.{ .slotTypeFn = BlogSlotType, .reads = &.{BlogSlot.Input}, .writes = &.{BlogSlot.PostJson} });
const Respond = CtxView(.{ .slotTypeFn = BlogSlotType, .reads = &.{BlogSlot.PostJson} });

// Step functions
pub fn step_parse(ctx: *Parse) !Decision {
    const inp = try ctx.base.json(PostInput);
    try ctx.put(BlogSlot.Input, inp);
    return continue_();
}

pub fn step_validate(ctx: *Validate) !Decision {
    const inp = try ctx.require(BlogSlot.Input);
    if (inp.title.len == 0) return fail(ErrorCode.InvalidInput, "post", "title_empty");
    return continue_();
}

pub fn step_plan(ctx: *Plan) !Decision {
    const inp = try ctx.require(BlogSlot.Input);
    const body = try ctx.base.toJson(inp);
    const eff = httpJsonPost("/posts", body, @intFromEnum(BlogSlot.PostJson));
    return ctx.base.runEffects(&.{eff});
}

pub fn step_respond(ctx: *Respond) !Decision {
    const json = try ctx.require(BlogSlot.PostJson);
    return done(.{
        .status = 201,
        .headers = &.{ .{ .name = "Content-Type", .value = "application/json" } },
        .body = .{ .complete = json },
    });
}

// Route registration with comptime validation
pub fn registerRoutes(server: *Server) !void {
    try server.addRoute(.POST, "/posts", zerver.routeChecked(.{
        .steps = &.{
            step("parse", step_parse),
            step("validate", step_validate),
            step("plan", step_plan),
            step("respond", step_respond),
        },
    }, .{
        .require_reads_produced = true,
        .forbid_duplicate_writers = true,
    }));
}
```

**Key Features:**
- One way to write steps: `fn (*CtxView) !Decision`
- Comptime wiring validation catches errors early
- Ergonomic helpers (`runEffects`, `httpJsonPost`)
- Direct response returns (no response-in-slot)
- Clear pure/impure boundaries

---

## Future Work

### SQL Query Effector

**Status:** Not yet implemented

**Planned API:**

```zig
pub const SqlQueryEffect = struct {
    query: []const u8,          // Parameterized query with $1, $2
    params: []const SqlParam,
    token: u32,
    result_format: ResultFormat = .json,
};
```

### HTTP Call Effector

**Status:** Not yet implemented

**Planned API:**

```zig
pub const HttpCallEffect = struct {
    request: HttpRequest,
    token: u32,
    result_format: HttpResultFormat = .body_text,
};

pub const HttpRequest = struct {
    url: []const u8,
    method: HttpMethod = .GET,
    headers: HttpHeaders = .{},
    query_params: QueryParams = .{},
    body: HttpBody = .empty,
    timeout_ms: ?u32 = null,
};
```

---

## Implementation Phases

### Phase 1: Pure Core (Week 1)
- [x] SlotSchema helper with `slotId()` and `verifyExhaustive()`
- [ ] Port CtxBase and CtxView to zupervisor
- [ ] Implement pure interpreter (`evalUntilNeedOrDone`)
- [ ] Implement Decision types (Continue, Need, Done, Fail)
- [ ] Implement route builder DSL (`route()`, `step()`)

### Phase 2: Ownership & Lifetimes (Week 2)
- [ ] Implement `slotPutOwned()` for arena-owned values
- [ ] Implement `cloneToArena()` for structs
- [ ] Document ownership conventions
- [ ] Add arena cleanup verification

### Phase 3: Effect Infrastructure (Week 3)
- [ ] Implement Effect types (db_get, db_put, db_del, compute)
- [ ] Implement EffectorTable (union tag → fn table)
- [ ] Implement Sequential effect execution
- [ ] Test: single effect fills slot

### Phase 4: Testing Harness (Week 4)
- [ ] Implement FakeEffectorTable
- [ ] Create test harness for pipelines
- [ ] Write tests for pure interpreter
- [ ] Write tests with fake effects

### Phase 5: Parallel Execution (Week 5)
- [ ] Implement WorkerPool (thread pool)
- [ ] Implement Parallel effect execution
- [ ] Implement Join strategies (.all, .all_required, .any, .first_success)
- [ ] Test: parallel peer effects

### Phase 6: Compute Effector (Week 6)
- [ ] Implement ComputeEffector with function pointer execution
- [ ] Implement worker pool for compute tasks
- [ ] Add timeout support for compute
- [ ] Test: feature DLL compute functions

### Phase 7: Production Ready (Week 7+)
- [ ] Add observability (metrics, traces, events)
- [ ] Add error handling and retries
- [ ] Performance testing and optimization
- [ ] Document migration guide from current architecture

---

## Benefits

1. **Lower Cognitive Load** - One way to write steps, clear patterns
2. **Stronger Type Safety** - Compile-time slot type checking, exhaustive switches
3. **Deterministic Tests** - Pure interpreter + fake effectors
4. **Clear Ownership** - Arena-only slot values, no manual cleanup
5. **Explicit Dependencies** - Reads/writes declared in CtxView
6. **Automatic Parallelization** - Independent effects run concurrently
7. **Composability** - Mix and match steps, effects, batching strategies
8. **Testability** - Mock effectors, pre-fill slots for testing
9. **Observability** - Track slot fills, effect execution, pipeline flow
10. **Performance** - Minimize allocations, maximize parallelism

---

## References

- Blog feature: `/features/blog/src/steps.zig` - Reference implementation
- Core types: `/src/zerver/core/types.zig` - Decision, Need, Effect types (to be created)
- Context: `/src/zerver/core/ctx.zig` - CtxBase, CtxView implementation (to be ported)
- SlotSchema: `/src/zerver/core/slot_schema.zig` - SlotSchema helper (to be created)
- Pure Interpreter: `/src/zupervisor/interpreter.zig` - Pure step evaluator (to be created)
