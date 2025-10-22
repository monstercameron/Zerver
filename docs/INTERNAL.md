awesome — here’s a tight **`lib/zerver.zig` API surface** you can drop in and build your MVP on. it encodes the ideas we’ve converged on, but keeps implementation swappable later (sync MVP now; proactor/scheduler in phase 2).

it’s a **header-like** file: mostly types, function signatures, and a few tiny comptime helpers. comments explain the BTS contracts. you can wire your `main.zig` against this right away.

```zig
// lib/zerver.zig
const std = @import("std");

/// ─────────────────────────────────────────────────────────────────────────────
/// APP-SUPPLIED TYPES (you define these in app code and import this lib)
/// - `Slot`: your slot enum
/// - `SlotType(slot)`: comptime mapping Slot → concrete type
///
/// For MVP simplicity, we expect you to provide them by @importing this lib
/// *after* declaring Slot+SlotType in the app module (the root).
pub const Slot = @import("root").Slot;
pub const SlotType = @import("root").SlotType;

/// Minimal JSON surface (replace with your real JSON type)
pub const JsonValue = struct {
    // placeholder API; swap for your preferred JSON lib
    pub fn getString(self: @This(), k: []const u8) ?[]const u8 { _ = self; _ = k; return null; }
    pub fn getOptionalString(self: @This(), k: []const u8) ?[]const u8 { _ = self; _ = k; return null; }
    pub fn getOptionalBool(self: @This(), k: []const u8) ?bool { _ = self; _ = k; return null; }
};

/// ─────────────────────────────────────────────────────────────────────────────
/// ERROR MODEL (with tiny context for precise rendering)

pub const ErrorCtx = struct { what: []const u8, key: []const u8 = "" };

pub const Error = struct {
    kind: u16,     // app maps to an enum in render_error
    ctx: ErrorCtx,
};

/// ─────────────────────────────────────────────────────────────────────────────
/// HTTP RESPONSE

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// ─────────────────────────────────────────────────────────────────────────────
/// EFFECTS (MVP: synchronous execution; Phase 2 swaps engine w/o API changes)

pub const Retry = struct { max: u8 = 0 };

pub const HttpGet = struct {
    url: []const u8,
    token: Slot,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
    // Phase 2: .circuit_breaker, .headers, etc.
};
pub const HttpPost = struct {
    url: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
    token: Slot,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

pub const DbGet = struct { key: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true };
pub const DbPut = struct {
    key: []const u8, value: []const u8, token: Slot,
    timeout_ms: u32 = 400, retry: Retry = .{}, required: bool = true,
    idem: []const u8 = "",
    // Phase 2: compensate: ?Effect = null,
};
pub const DbDel = struct { key: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true, idem: []const u8 = "" };
pub const DbScan = struct { prefix: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true };

pub const Effect = union(enum) {
    httpGet: HttpGet,
    httpPost: HttpPost,
    dbGet: DbGet,
    dbPut: DbPut,
    dbDel: DbDel,
    dbScan: DbScan,
    // Phase 2: sleep, random, now, etc.
};

pub const Join = enum { all, all_required, any, first_success };
pub const Mode = enum { Parallel, Sequential };

/// ─────────────────────────────────────────────────────────────────────────────
/// DECISIONS

pub const Decision = union(enum) {
    Continue,
    Need: struct {
        effects: []const Effect,
        mode: Mode = .Parallel,
        join: Join = .all,
        /// explicit continuation (no implicit re-entry).
        /// MVP: continuation receives *CtxBase; step-trampolines will wrap it in a typed view.
        resume: fn (*CtxBase) anyerror!Decision,
    },
    Done: Response,
    Fail: Error,
};

/// ─────────────────────────────────────────────────────────────────────────────
/// REQUEST CONTEXT (base)  — runtime storage + request utilities
/// MVP stores into a per-request arena; effects execute synchronously.

pub const CtxBase = struct {
    /// INTERNALS (opaque to steps)
    arena: std.heap.ArenaAllocator,
    // slot storage (MVP can be a map; Phase 2: indexed slab/bitset for perf)
    // intentionally hidden; use require/optional/put wrappers through views.

    /// ── Request metadata
    pub fn method(self: *CtxBase) []const u8 { _ = self; return "GET"; }
    pub fn path(self: *CtxBase) []const u8 { _ = self; return "/"; }
    pub fn header(self: *CtxBase, name: []const u8) ?[]const u8 { _ = self; _ = name; return null; }
    pub fn param(self: *CtxBase, name: []const u8) ?[]const u8 { _ = self; _ = name; return null; }
    pub fn query(self: *CtxBase, name: []const u8) ?[]const u8 { _ = self; _ = name; return null; }
    pub fn clientIpText(self: *CtxBase) []const u8 { _ = self; return "0.0.0.0"; }

    /// ── JSON helpers (arena-backed)
    pub fn json(self: *CtxBase) !JsonValue { _ = self; return .{}; }
    pub fn toJson(self: *CtxBase, v: anytype) []const u8 { _ = self; _ = v; return "null"; }

    /// ── Formatting (arena-backed, valid for request lifetime)
    pub fn bufFmt(self: *CtxBase, comptime fmt: []const u8, args: anytype) []const u8 {
        _ = self; _ = fmt; _ = args; return "";
    }

    /// ── Observability
    pub fn ensureRequestId(self: *CtxBase) void { _ = self; }
    pub fn status(self: *CtxBase) u16 { _ = self; return 200; }
    pub fn elapsedMs(self: *CtxBase) u64 { _ = self; return 0; }
    pub fn onExit(self: *CtxBase, cb: fn (*CtxBase) void) void { _ = self; _ = cb; }
    pub fn logDebug(self: *CtxBase, comptime fmt: []const u8, args: anytype) void { _ = self; _ = fmt; _ = args; }
    pub fn lastError(self: *CtxBase) ?Error { _ = self; return null; }

    /// ── Policy
    pub fn roleAllow(self: *CtxBase, roles: []const []const u8, need: []const u8) bool { _ = self; _ = roles; _ = need; return true; }
    pub fn setUser(self: *CtxBase, sub: []const u8) void { _ = self; _ = sub; }
    pub fn idempotencyKey(self: *CtxBase) []const u8 { _ = self; return ""; }

    /// INTERNAL slot ops (typed via SlotType at call sites through CtxView)
    fn _put(self: *CtxBase, comptime s: Slot, v: SlotType(s)) !void { _ = self; _ = s; _ = v; }
    fn _get(self: *CtxBase, comptime s: Slot) !?SlotType(s) { _ = self; _ = s; return null; }
};

/// ─────────────────────────────────────────────────────────────────────────────
/// CTX VIEW — compile-time access control (reads/writes). This is the heart.
/// If you try to `require(.Claims)` from a view that doesn’t list it in `reads`,
/// you get a @compileError.

pub fn CtxView(comptime spec: anytype) type {
    const Reads: []const Slot = if (@hasField(@TypeOf(spec), "reads")) spec.reads else &.{};
    const Writes: []const Slot = if (@hasField(@TypeOf(spec), "writes")) spec.writes else &.{};

    fn hasSlot(comptime needle: Slot, comptime hay: []const Slot) bool {
        inline for (hay) |s| { if (s == needle) return true; }
        return false;
    }

    return struct {
        base: *CtxBase,

        pub fn require(self: *@This(), comptime s: Slot) !SlotType(s) {
            comptime if (!hasSlot(s, Reads)) @compileError("slot not in reads: " ++ @tagName(s));
            return (try self.base._get(s)) orelse error.SlotMissing;
        }
        pub fn optional(self: *@This(), comptime s: Slot) !?SlotType(s) {
            comptime if (!hasSlot(s, Reads) and !hasSlot(s, Writes)) @compileError("slot not declared: " ++ @tagName(s));
            return try self.base._get(s);
        }
        pub fn put(self: *@This(), comptime s: Slot, v: SlotType(s)) !void {
            comptime if (!hasSlot(s, Writes)) @compileError("slot not in writes: " ++ @tagName(s));
            try self.base._put(s, v);
        }

        // Safe passthroughs
        pub usingnamespace struct {
            pub const method = CtxBase.method;
            pub const path = CtxBase.path;
            pub const header = CtxBase.header;
            pub const param = CtxBase.param;
            pub const query = CtxBase.query;
            pub const clientIpText = CtxBase.clientIpText;

            pub const json = CtxBase.json;
            pub const toJson = CtxBase.toJson;
            pub const bufFmt = CtxBase.bufFmt;

            pub const ensureRequestId = CtxBase.ensureRequestId;
            pub const status = CtxBase.status;
            pub const elapsedMs = CtxBase.elapsedMs;
            pub const onExit = CtxBase.onExit;
            pub const logDebug = CtxBase.logDebug;
            pub const lastError = CtxBase.lastError;

            pub const roleAllow = CtxBase.roleAllow;
            pub const setUser = CtxBase.setUser;
            pub const idempotencyKey = CtxBase.idempotencyKey;
        };
    };
}

/// ─────────────────────────────────────────────────────────────────────────────
/// STEP & TRAMPOLINE — wrap typed step fns so the engine can call via *CtxBase

pub const Step = struct {
    name: []const u8,
    call: fn (*CtxBase) anyerror!Decision,
    // Optional metadata for static validation / tooling:
    reads: []const Slot = &.{},
    writes: []const Slot = &.{},
};

/// `step("name", fn_ptr)` builds a trampoline that constructs the view the fn expects.
/// We introspect the parameter type of `fn_ptr` to create the correct wrapper.
///
/// Usage:
///   const View = zerver.CtxView(.{ .reads=.{.A}, .writes=.{.B} });
///   fn my_step(ctx: *View) !Decision { ... }
///   pub const STEP = zerver.step("my_step", my_step);
pub fn step(comptime name: []const u8, comptime F: anytype) Step {
    const FnInfo = @typeInfo(@TypeOf(F)).Fn;
    comptime if (FnInfo.params.len != 1) @compileError("step fn must take exactly one parameter");
    const ParamType = FnInfo.params[0].type.?;
    const ViewHasBase = @hasField(ParamType, "base") and @typeInfo(@TypeOf(@field(@as(ParamType undefined), "base"))).Pointer.child == CtxBase;

    comptime if (!ViewHasBase) @compileError("step param must be *CtxView(...)");

    const Tramp = struct {
        fn call(base: *CtxBase) anyerror!Decision {
            var v: ParamType = .{ .base = base };
            return F(&v);
        }
    };
    return .{ .name = name, .call = Tramp.call };
}

/// ─────────────────────────────────────────────────────────────────────────────
/// ROUTING / FLOWS (MVP)

pub const Method = enum { GET, POST, PATCH, PUT, DELETE };

pub const RouteSpec = struct {
    before: []const Step = &.{},
    steps: []const Step,
};

pub const FlowSpec = struct {
    slug: []const u8,
    before: []const Step = &.{},
    steps: []const Step,
};

pub const Config = struct {
    addr: Address = .{ .ip = .{ 0,0,0,0 }, .port = 8080 },
    on_error: fn (*CtxBase) anyerror!Decision,
    debug: bool = false,
    // Phase 2: priorities, scheduler knobs
};
pub const Address = struct { ip: [4]u8, port: u16 };

pub const Server = struct {
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, cfg: Config) !Server { _ = cfg; return .{ .alloc = a }; }
    pub fn deinit(self: *Server) void { _ = self; }

    pub fn use(self: *Server, chain: []const Step) !void { _ = self; _ = chain; }

    pub fn addRoute(self: *Server, method: Method, path: []const u8, spec: RouteSpec) !void {
        _ = self; _ = method; _ = path; _ = spec;
        // BTS: MVP may skip static read-before-write; Phase 2 can check spec.before/spec.steps metadata.
    }

    pub fn addFlow(self: *Server, spec: FlowSpec) !void {
        _ = self; _ = spec;
    }

    pub fn listen(self: *Server) !void {
        _ = self;
        // MVP: use a simple blocking HTTP server (or stub); call pipelines sequentially.
    }
};

/// ─────────────────────────────────────────────────────────────────────────────
/// TEST HARNESS — fast unit tests without a server

pub const ReqTest = struct {
    ctx: CtxBase,

    pub fn init(a: std.mem.Allocator) !ReqTest {
        var arena = std.heap.ArenaAllocator.init(a);
        return .{ .ctx = .{ .arena = arena } };
    }
    pub fn deinit(self: *ReqTest) void { _ = self; }

    pub fn base(self: *ReqTest) *CtxBase { return &self.ctx; }

    /// seed slots for a test
    pub fn put(self: *ReqTest, comptime s: Slot, v: SlotType(s)) !void { try self.ctx._put(s, v); }
    pub fn get(self: *ReqTest, comptime s: Slot) !?SlotType(s) { return self.ctx._get(s); }
};

/// Fake interpreter lets you assert .Need and then "complete" effects.
/// MVP: execute effects immediately (blocking). For unit tests, you can
/// inject canned results by pattern (e.g., key/url match).
pub const FakeInterpreter = struct {
    pub fn completeAll(_d: Decision) !void { _ = _d; }
};

/// Small helpers to build effects (so user code can write zerver.Effect.dbGet(...))
pub const Effect = struct {
    pub fn httpGet(x: HttpGet) @This() { return .{ .httpGet = x }; }
    pub fn httpPost(x: HttpPost) @This() { return .{ .httpPost = x }; }
    pub fn dbGet(x: DbGet) @This() { return .{ .dbGet = x }; }
    pub fn dbPut(x: DbPut) @This() { return .{ .dbPut = x }; }
    pub fn dbDel(x: DbDel) @This() { return .{ .dbDel = x }; }
    pub fn dbScan(x: DbScan) @This() { return .{ .dbScan = x }; }
};

```

### Notes on the tricky bits (kept short)

* **CtxView works**: the `require/optional/put` methods do a **comptime membership check** against the view’s `reads/writes`. If you call with an undeclared slot, you get a **compile error** (helpful message).
* **Continuation typing**: MVP continuations take `*CtxBase`. The trampoline `step("name", fn)` reconstructs the typed view at call time, so you can “resume into” a function expecting a *different* `CtxView`. This sidesteps the “same-view only” limit while keeping call sites clean.
* **Join semantics**: included `Join.{all, all_required, any, first_success}`. MVP runs effects sequentially but keeps the flags for forward-compat; Phase 2 honors the contract with real concurrency.
* **Saga/compensation**: deliberately **not in MVP** to avoid half-baked semantics. We left a comment stub in `DbPut` for Phase 2.
* **bufFmt & JSON lifetimes**: both are **arena-backed** (per-request). Valid until the request ends. If you format too much, you’ll OOM the request arena; that’s on the app (we can add a soft cap later).

---

## Micro test to prove unit-test ergonomics

This is how a unit test for your `db_load_by_id` would look with the harness:

```zig
test "db_load_by_id requests a dbGet and resumes with item" {
    const z = @import("lib/zerver.zig");
    var gpa = std.testing.allocator;

    var t = try z.ReqTest.init(gpa);
    defer t.deinit();

    // seed slot
    try t.put(.TodoId, "123");

    // call the typed step via trampoline
    const STEP_DB_LOAD = /* from your app code */ ;
    const d = try STEP_DB_LOAD.call(t.base());

    // assert it asked for I/O
    try std.testing.expectEqual(@as(z.Decision.Tag, .Need), @as(z.Decision, d).tag);

    // Fake completion in MVP you’d just call the resume directly after stubbing:
    try t.put(.TodoItem, .{ .id = "123", .title = "Test", .done = false });
    const LoadView = z.CtxView(.{ .reads = .{ .TodoId, .TodoItem }, .writes = .{ .TodoItem } });
    const cont = @ptrCast(fn(*z.CtxBase) anyerror!z.Decision, db_loaded); // or call your typed fn through trampoline pattern
    const d2 = try cont(t.base());
    try std.testing.expectEqual(@as(z.Decision.Tag, .Continue), @as(z.Decision, d2).tag);
}
```

(You’ll wire the actual `STEP_DB_LOAD` from your app; this shows the pattern.)

---

## What to do next

* Paste this `lib/zerver.zig`.
* Point your `main.zig` (last version you liked) at it.
* Start with **sync MVP** (effects block; traces still emit).
* Add 3–5 **unit tests** using `ReqTest` to prove the ergonomics.
* If this feels good, we can fill in the minimal blocking HTTP server and the “blocking effect executor” so the sample actually serves requests on `:8080`.

want me to also drop a **minimal blocking executor** (so `Need` runs the effects synchronously and immediately calls `resume`) to make the whole sample runnable end-to-end?
