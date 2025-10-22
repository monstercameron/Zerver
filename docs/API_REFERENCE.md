# Zerver API Reference

This document provides the complete public API surface of Zerver, covering core types, request context, steps, routes, and execution semantics.

---

## Core Types (MVP)

### Header and Response

```zig
const Header   = struct { name: []const u8, value: []const u8 };
const Response = struct { status: u16 = 200, headers: []const Header = &.{}, body: []const u8 = "" };
```

### Error Handling

```zig
const ErrorCtx = struct { what: []const u8, key: []const u8 = "" };
const Error    = struct { kind: u16, ctx: ErrorCtx };
```

- **`what`**: domain or component where error occurred (e.g., "todo", "auth", "db")
- **`key`**: specific ID or key related to the error
- **`kind`**: HTTP status code (404, 500, etc.)

### Effects

Effects represent explicit I/O requests. Each effect includes policy parameters (timeout, retry, required):

```zig
const Retry = struct { max: u8 = 0 };

const HttpGet  = struct { 
    url: []const u8, 
    token: Slot, 
    timeout_ms: u32 = 1000, 
    retry: Retry = .{}, 
    required: bool = true 
};

const HttpPost = struct { 
    url: []const u8, 
    body: []const u8, 
    headers: []const Header = &.{}, 
    token: Slot, 
    timeout_ms: u32 = 1000, 
    retry: Retry = .{}, 
    required: bool = true 
};

const DbGet = struct { 
    key: []const u8, 
    token: Slot, 
    timeout_ms: u32 = 300, 
    retry: Retry = .{}, 
    required: bool = true 
};

const DbPut = struct { 
    key: []const u8, 
    value: []const u8, 
    token: Slot, 
    timeout_ms: u32 = 400, 
    retry: Retry = .{}, 
    required: bool = true, 
    idem: []const u8 = "" 
};

const DbDel = struct { 
    key: []const u8, 
    token: Slot, 
    timeout_ms: u32 = 300, 
    retry: Retry = .{}, 
    required: bool = true, 
    idem: []const u8 = "" 
};

const DbScan = struct { 
    prefix: []const u8, 
    token: Slot, 
    timeout_ms: u32 = 300, 
    retry: Retry = .{}, 
    required: bool = true 
};

const Effect = union(enum) { 
    httpGet: HttpGet, 
    httpPost: HttpPost, 
    dbGet: DbGet, 
    dbPut: DbPut, 
    dbDel: DbDel, 
    dbScan: DbScan 
};
```

### Decision Union

The `Decision` type is what steps return to control the request flow:

```zig
const Mode = enum { Parallel, Sequential };
const Join = enum { all, all_required, any, first_success };

const Decision = union(enum) {
    Continue,
    Need: struct {
        effects: []const Effect,
        mode: Mode = .Parallel,
        join: Join = .all,
        resume: fn (*CtxBase) anyerror!Decision,  // explicit continuation
    },
    Done: Response,
    Fail: Error,
};
```

- **`Continue`**: proceed to the next step
- **`Need{effects, mode, join, resume}`**: execute effects and call the continuation function when complete
- **`Done(Response)`**: immediately return this response to the client
- **`Fail(Error)`**: immediately fail with this error (routes to `on_error` handler)

### Slot System (Application-Defined)

Your application defines the slots available for per-request state:

```zig
pub const Slot = enum { 
    // app-defined: e.g., UserId, TodoId, TodoItem
};

pub fn SlotType(comptime s: Slot) type { 
    return switch (s) {
        // app-defined mapping
    };
}
```

---

## Request Context (CtxBase)

The `CtxBase` struct provides access to request data and utilities:

```zig
const CtxBase = struct {
    arena: std.heap.ArenaAllocator,

    // Request API
    pub fn method(self: *CtxBase) []const u8;
    pub fn path(self: *CtxBase) []const u8;
    pub fn header(self: *CtxBase, name: []const u8) ?[]const u8;
    pub fn param(self: *CtxBase, name: []const u8) ?[]const u8;     // path params
    pub fn query(self: *CtxBase, name: []const u8) ?[]const u8;     // query params
    pub fn clientIpText(self: *CtxBase) []const u8;

    // JSON + formatting (arena-backed; valid for request lifetime)
    pub fn json(self: *CtxBase) !JsonValue;
    pub fn toJson(self: *CtxBase, v: anytype) []const u8;
    pub fn bufFmt(self: *CtxBase, comptime fmt: []const u8, args: anytype) []const u8;

    // Observability
    pub fn ensureRequestId(self: *CtxBase) void;
    pub fn status(self: *CtxBase) u16;
    pub fn elapsedMs(self: *CtxBase) u64;
    pub fn onExit(self: *CtxBase, cb: fn (*CtxBase) void) void;
    pub fn logDebug(self: *CtxBase, comptime fmt: []const u8, args: anytype) void;
    pub fn lastError(self: *CtxBase) ?Error;

    // Policy helpers
    pub fn roleAllow(self: *CtxBase, roles: []const []const u8, need: []const u8) bool;
    pub fn setUser(self: *CtxBase, sub: []const u8) void;
    pub fn idempotencyKey(self: *CtxBase) []const u8;

    // Slot storage (hidden; typed access via CtxView)
    fn _put(self: *CtxBase, comptime s: Slot, v: SlotType(s)) !void;
    fn _get(self: *CtxBase, comptime s: Slot) !?SlotType(s);
};
```

---

## Compile-Time Typed Views (CtxView)

`CtxView` is a compile-time wrapper that enforces which slots a step can access:

```zig
pub fn CtxView(comptime spec: anytype) type;
```

### CtxView API

Given a view for a step, you can access slots using:

- **`require(slot)`** - Get a required slot
  - Compiles only if `slot ∈ spec.reads`
  - Returns `!SlotType(slot)` (never null, or error.SlotMissing)
  - Use when the slot **must** be present from a prior step

- **`optional(slot)`** - Get an optional slot
  - Compiles only if `slot ∈ (spec.reads ∪ spec.writes)`
  - Returns `!?SlotType(slot)` (null if not yet written)
  - Use when the slot may or may not be present

- **`put(slot, value)`** - Write a slot
  - Compiles only if `slot ∈ spec.writes`
  - Stores the value for downstream steps
  - Use when your step produces data for later steps

### Example

```zig
const MyStepView = zerver.CtxView(.{
    .reads = &.{ .TodoId },
    .writes = &.{ .TodoItem },
});

fn my_step(ctx: *MyStepView) !zerver.Decision {
    const id = try ctx.require(.TodoId);        // ✓ compiles
    const user = try ctx.optional(.UserId);     // ✗ compile error! UserId not in reads/writes
    try ctx.put(.TodoItem, item);               // ✓ compiles
    return zerver.continue_();
}
```

---

## Steps and Routing

### Step Definition

```zig
pub const Step = struct { 
    name: []const u8, 
    call: fn (*CtxBase) anyerror!Decision, 
    reads: []const Slot = &.{}, 
    writes: []const Slot = &.{} 
};

pub fn step(comptime name: []const u8, comptime F: anytype) Step;
```

The `step()` helper wraps a typed step function and creates a trampoline that the runtime can invoke.

### HTTP Methods

```zig
pub const Method = enum { GET, POST, PATCH, PUT, DELETE };
```

### Routes and Flows

```zig
pub const RouteSpec = struct { 
    before: []const Step = &.{}, 
    steps: []const Step 
};

pub const FlowSpec = struct { 
    slug: []const u8, 
    before: []const Step = &.{}, 
    steps: []const Step 
};

pub const Config = struct { 
    addr: Address, 
    on_error: fn (*CtxBase) anyerror!Decision, 
    debug: bool = false 
};

pub const Address = struct { 
    ip: [4]u8, 
    port: u16 
};
```

### Server API

```zig
pub const Server = struct {
    pub fn init(a: std.mem.Allocator, cfg: Config) !Server;
    pub fn deinit(self: *Server) void;
    pub fn use(self: *Server, chain: []const Step) !void;           // global before
    pub fn addRoute(self: *Server, method: Method, path: []const u8, spec: RouteSpec) !void;
    pub fn addFlow(self: *Server, spec: FlowSpec) !void;            // /flow/v1/<slug>
    pub fn listen(self: *Server) !void;                             // MVP: blocking
};
```

---

## Request Lifecycle & Execution Semantics

### 1. Request Acceptance and Parsing

1. Accept connection; parse HTTP request into `CtxBase` with arena allocation
2. Extract method, path, headers, and body

### 2. Route/Flow Selection

1. Match route (`method + path`) or flow (`/flow/v1/<slug>`)
2. Extract path parameters (`:param` syntax)

### 3. Pipeline Execution

The request flows through the pipeline in this order:

1. **Global "before" chain** - middleware applied to all requests
2. **Route-specific "before" chain** - middleware for this specific route
3. **Main steps** - business logic steps for this route

Each step in the pipeline receives a `Decision`:

- **`Continue`** → execute the next step
- **`Need{…}`** → invoke executor (execute effects, call continuation)
- **`Done(response)`** → short-circuit; return response immediately
- **`Fail(error)`** → short-circuit; call `on_error` handler

### 4. Effect Execution (Need)

When a step returns `Need{effects, mode, join, resume}`:

1. Execute effects according to `mode` (Parallel/Sequential)
2. Apply `join` strategy to determine when to resume:
   - **`all`**: wait for all effects; any required failure → pipeline fails
   - **`all_required`**: wait for all required effects; optional may fail without failing pipeline
   - **`any`**: resume on first completion
   - **`first_success`**: resume on first success; if all fail and any required → pipeline fails
3. Call the `resume` continuation function with updated `CtxBase`
4. Continue pipeline with the result of `resume`

### 5. Response and Cleanup

- **On `Done`**: render HTTP response; run `onExit` callbacks
- **On `Fail`**: call `on_error(*CtxBase)` to render error response; run `onExit` callbacks
- **Cleanup**: free arena; close connection if needed

---

## Effect Results and Slot Token

Each effect has a `token` that specifies which slot to write the result to:

```zig
// In a step:
return .{
    .Need = .{
        .effects = &.{
            zerver.Effect{
                .DbGet = .{
                    .key = "todo:123",
                    .token = .TodoItem,     // Write result to .TodoItem slot
                    .required = true,
                }
            }
        },
        .join = .all,
        .resume = handle_response,
    }
};
```

- **Required effect success** → result written to token slot
- **Required effect failure** → pipeline fails immediately with error
- **Optional effect success** → result written to token slot
- **Optional effect failure** → token slot remains unset; continuation can check with `optional(slot)`

---

## Continuation Functions

A continuation is an explicit function that resumes after effects complete:

```zig
fn handle_response(ctx: *MyView) !zerver.Decision {
    // The engine has already executed effects and populated slots
    const todo = try ctx.require(.TodoItem);
    // Process the result...
    return zerver.continue_();
}
```

The engine calls the continuation by:
1. Extracting the expected `CtxView` spec from the function signature
2. Calling the typed function via a trampoline
3. Continuing the pipeline with the returned `Decision`

---

## Compile-Time Safety Properties

1. **No read-before-write**: If a step tries to `require` a slot that hasn't been written, it's a compile error
2. **No undefined accesses**: Steps can only access slots they declare in their `CtxView`
3. **Type safety**: Each slot has a well-defined type checked at compile time
4. **Deterministic** (in MVP): No implicit async/await; all side effects are explicit `Effect`s

---

## Common Helper Functions

```zig
pub const zerver = @import("zerver");

// Decision constructors
pub fn continue_() Decision;            // Return Continue
pub fn done(response: Response) Decision;
pub fn fail(code: u16, what: []const u8, key: []const u8) Decision;

// Step wrapper
pub fn step(comptime name: []const u8, comptime F: anytype) Step;
```

---

## Summary Table: Decision Outcomes

| Outcome | Handler | Response |
|---------|---------|----------|
| `Continue` | (next step) | - |
| `Done(response)` | HTTP formatter | status + headers + body |
| `Fail(error)` | `on_error` handler | formatted error response |
| `Need{effects,…}` | Executor | execute effects, call resume |

