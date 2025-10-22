Below is a complete, end-to-end **product + technical specification** for the framework we’ve been iterating on. It treats the “step/effect” model, typed request state via `CtxView`, explicit continuations, synchronous MVP engine, and a Phase-2 proactor/scheduler upgrade as first-class, with precise contracts.

---

# 1) Purpose & Scope

## 1.1 Goals

* **Debuggability by design**: explicit step boundaries, explicit effects, deterministic timelines, first-class traces, request replay.
* **Composable orchestration**: reuse steps across routes/flows; enforce data dependencies at compile time.
* **Operational control**: centralized policies for retries, timeouts, idempotency; clear failure semantics.
* **Gradual engine**: MVP runs synchronously (blocking I/O) using the same API; Phase-2 swaps in a non-blocking proactor + scheduler with no application code changes.

## 1.2 Non-Goals (MVP)

* Not a full HTTP/2/3 stack (use existing libs beneath).
* Not a full ORM or DB driver zoo.
* Not a template engine.
* Not a reactive streaming framework (basic streaming is optional in Phase-2).

---

# 2) Key Concepts & Terminology

* **Slot**: a named, typed cell of per-request state (`enum Slot { … }`) with a **comptime** mapping `SlotType(slot)`.
* **CtxBase**: base request context (arena, headers, params, helpers).
* **CtxView<Reads,Writes>**: a **type** wrapping `CtxBase` that **compile-time restricts** which slots a step can `require/optional/put`.
* **Step**: a function `fn(*CtxView<…>) !Decision` wrapped by a trampoline `step("name", fn)` so the runtime can call it via `*CtxBase`.
* **Decision**: `{ Continue | Need{…} | Done(Response) | Fail(Error) }`.
* **Effect**: declarative I/O request (e.g., `dbGet`, `httpPost`) with policy knobs; the engine performs the I/O and resumes via the named continuation.
* **Continuation**: an explicit function to call after effects complete; **no implicit re-entry**.
* **Route**: method + path (supports path params) → `{before: []Step, steps: []Step}`.
* **Flow**: `slug`-addressed endpoint under `/flow/v1/<slug>` with the same `{before, steps}` shape (separate namespace from REST routes).

---

# 3) Public API Surface (MVP)

## 3.1 Application-supplied types

```zig
pub const Slot = enum { /* app-defined */ };
pub fn SlotType(comptime s: Slot) type { /* app-defined mapping */ }
```

## 3.2 Core types

```zig
const Header   = struct { name: []const u8, value: []const u8 };
const Response = struct { status: u16 = 200, headers: []const Header = &.{}, body: []const u8 = "" };

const ErrorCtx = struct { what: []const u8, key: []const u8 = "" };
const Error    = struct { kind: u16, ctx: ErrorCtx };

const Retry = struct { max: u8 = 0 };

const HttpGet  = struct { url: []const u8, token: Slot, timeout_ms: u32 = 1000, retry: Retry = .{}, required: bool = true };
const HttpPost = struct { url: []const u8, body: []const u8, headers: []const Header = &.{}, token: Slot, timeout_ms: u32 = 1000, retry: Retry = .{}, required: bool = true };
const DbGet    = struct { key: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true };
const DbPut    = struct { key: []const u8, value: []const u8, token: Slot, timeout_ms: u32 = 400, retry: Retry = .{}, required: bool = true, idem: []const u8 = "" };
const DbDel    = struct { key: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true, idem: []const u8 = "" };
const DbScan   = struct { prefix: []const u8, token: Slot, timeout_ms: u32 = 300, retry: Retry = .{}, required: bool = true };

const Effect = union(enum) { httpGet: HttpGet, httpPost: HttpPost, dbGet: DbGet, dbPut: DbPut, dbDel: DbDel, dbScan: DbScan };
const Mode   = enum { Parallel, Sequential };
const Join   = enum { all, all_required, any, first_success };

const Decision = union(enum) {
  Continue,
  Need: struct {
    effects: []const Effect,
    mode: Mode = .Parallel,
    join: Join = .all,
    resume: fn (*CtxBase) anyerror!Decision, // explicit continuation
  },
  Done: Response,
  Fail: Error,
};
```

## 3.3 Request context & view

```zig
const CtxBase = struct {
  arena: std.heap.ArenaAllocator,
  // request API
  pub fn method(*CtxBase) []const u8;
  pub fn path(*CtxBase) []const u8;
  pub fn header(*CtxBase, name: []const u8) ?[]const u8;
  pub fn param(*CtxBase, name: []const u8) ?[]const u8;  // path params
  pub fn query(*CtxBase, name: []const u8) ?[]const u8;
  pub fn clientIpText(*CtxBase) []const u8;

  // json + formatting (arena-backed; valid for request lifetime)
  pub fn json(*CtxBase) !JsonValue;
  pub fn toJson(*CtxBase, v: anytype) []const u8;
  pub fn bufFmt(*CtxBase, comptime fmt: []const u8, args: anytype) []const u8;

  // observability
  pub fn ensureRequestId(*CtxBase) void;
  pub fn status(*CtxBase) u16;
  pub fn elapsedMs(*CtxBase) u64;
  pub fn onExit(*CtxBase, cb: fn (*CtxBase) void) void;
  pub fn logDebug(*CtxBase, comptime fmt: []const u8, args: anytype) void;
  pub fn lastError(*CtxBase) ?Error;

  // policy helpers
  pub fn roleAllow(*CtxBase, roles: []const []const u8, need: []const u8) bool;
  pub fn setUser(*CtxBase, sub: []const u8) void;
  pub fn idempotencyKey(*CtxBase) []const u8;

  // slot storage (hidden), typed access via CtxView
  fn _put(*CtxBase, comptime s: Slot, v: SlotType(s)) !void;
  fn _get(*CtxBase, comptime s: Slot) !?SlotType(s);
};

// compile-time access control wrapper
pub fn CtxView(comptime spec: anytype) type;
```

**CtxView contract**

* `require(slot)` compiles only if `slot ∈ Reads`; returns `!SlotType(slot)` (never `null`, else `error.SlotMissing`).
* `optional(slot)` compiles only if `slot ∈ Reads ∪ Writes`; returns `!?SlotType(slot)`.
* `put(slot,value)` compiles only if `slot ∈ Writes`.
* All three perform **comptime membership checks** and emit `@compileError` on violations.

## 3.4 Steps, trampolines, routes & flows

```zig
pub const Step = struct { name: []const u8, call: fn (*CtxBase) anyerror!Decision, reads: []const Slot = &.{}, writes: []const Slot = &.{} };

// Wrap a typed step fn; the trampoline reconstructs the expected CtxView and calls it
pub fn step(comptime name: []const u8, comptime F: anytype) Step;

pub const Method = enum { GET, POST, PATCH, PUT, DELETE };

pub const RouteSpec = struct { before: []const Step = &.{}, steps: []const Step };
pub const FlowSpec  = struct { slug: []const u8, before: []const Step = &.{}, steps: []const Step };

pub const Config = struct { addr: Address, on_error: fn (*CtxBase) anyerror!Decision, debug: bool = false };
pub const Address = struct { ip: [4]u8, port: u16 };

pub const Server = struct {
  pub fn init(a: std.mem.Allocator, cfg: Config) !Server;
  pub fn deinit(*Server) void;
  pub fn use(*Server, chain: []const Step) !void; // global before
  pub fn addRoute(*Server, method: Method, path: []const u8, spec: RouteSpec) !void;
  pub fn addFlow(*Server, spec: FlowSpec) !void;  // /flow/v1/<slug>
  pub fn listen(*Server) !void;                   // MVP: blocking
};
```

---

# 4) Lifecycle & Execution Semantics

## 4.1 Request workflow

1. **Accept** connection; parse HTTP request into `CtxBase` (arena allocated).
2. **Select pipeline**: match route (`method + path`) or flow (`/flow/v1/<slug>`).
3. **Execute “before” chain**: in sequence; each is a `Step`.

   * `Continue` → next step.
   * `Need{…}` → invoke engine (MVP: execute synchronously), then call `resume` continuation.
   * `Done` or `Fail` → short-circuit pipeline.
4. **Execute main steps** similarly.
5. **On Decision.Done**: write response; run `onExit` callbacks.
6. **On Decision.Fail**: call `on_error(*CtxBase)` to render error response; then `onExit`.
7. **Cleanup**: free arena, close if needed (keep-alive allowed).

## 4.2 Decision.Need contract

* **`effects`**: list of `Effect`s (each has `required: bool`, `retry`, `timeout_ms`).
* **`mode`**:

  * `.Parallel`: engine may perform I/O concurrently; **MVP** executes in sequence but preserves trace semantics.
  * `.Sequential`: execute in order; earlier effects finish before later ones.
* **`join`**:

  * `.all`: wait for all effects to finish (success or failure); if any **required** fails → pipeline fails immediately, else continue.
  * `.all_required`: wait for all **required**; optional may continue in background (MVP: still waits; Phase-2 may detach).
  * `.any`: resume on first completion (success or failure).
  * `.first_success`: resume on first success; if all fail and any required→fail; else continue with “no result”.
* **`resume`**: **mandatory**; a function taking `*CtxBase` (engine re-trampolines into the typed view expected by your continuation).
* **Effect results**: each effect fills its `token` slot (e.g., `.TodoItem`). On required failure, engine **does not** write the slot and abends with `Fail(Error{...})`.

---

# 5) Memory Model & Lifetimes

* **Arena-per-request**: all helper allocations (`bufFmt`, `json`, `toJson`, effect results if copied) live until the request terminates.
* **Zero-copy encouragement**: APIs prefer slices of the request buffer when safe; large payloads can be handled via handles (cache keys) instead of copying.
* **Arena bounds**: configurable soft/hard caps per request (MVP: constant; Phase-2: metrics + error on cap exceed).
* **Ownership**: slots hold pointers/slices valid for the request lifetime; you **must not** retain them beyond `onExit`.

---

# 6) Routing, Middleware, and Flows

## 6.1 Routing

* Path patterns: literals + `:param` segments. Example: `/todos/:id`.
* **Param precedence**: routes are matched longest-literal first, then by number of params, then declaration order (stable).
* **Query params** remain available via `ctx.query`.

## 6.2 Middleware chains (before)

* Arrays of steps attached globally and/or per-route/flow.
* **Composition**: `try srv.use(&.{ … })` global; route-specific `before` runs **after** global before.
* **Validation (Phase-2)**: static check that for each pipeline, every `Reads` has an earlier `Writes` across `before+steps`, and each slot has exactly one writer. MVP: optional warning logs.

## 6.3 Flows

* Namespaced under `/flow/v1/<slug>`, separate from REST routes.
* Same `{before, steps}` shape, useful for multi-step orchestration endpoints.

---

# 7) Error Model

* **Error**: `{ kind: u16, ctx: ErrorCtx{what,key} }`.
* **Common mapping** (recommended, app-customizable):
  `InvalidInput→400`, `Unauthorized→401`, `Forbidden→403`, `NotFound→404`, `Conflict→409`, `TooManyRequests→429`, `UpstreamUnavailable→502`, `Timeout→504`, default `500`.
* **Propagation**:

  * From steps: `return .Fail(err(..))` → route to `on_error`.
  * From effects: a **required** effect failure → engine synthesizes `Error{kind=..., ctx=...}` and routes to `on_error`. Optional effect failure is recorded in trace and the slot remains **unset**; the continuation can decide how to react.
* **Context discipline**: always set `what` (domain: “todo”, “auth”, “db”) and `key` (id or key) when possible for precise diagnostics.

---

# 8) Observability & Tracing

## 8.1 Events (per request)

* **StepStart(name)** → timestamp
* **EffectStart(kind, key/url, token, required, timeout, retry)**
* **EffectEnd(success|failure, duration, error?)**
* **StepEnd(name, outcome: Continue|Done|Fail)**
* **Done(status)**, **Fail(kind, what, key)**
* **OnExit callbacks timing**

## 8.2 Exports

* **OTLP (Phase-2)**: map steps/effects to spans; request ID as trace ID.
* **Log hooks**: `ctx.logDebug` and a global logger for high-level events.
* **Trace dump**: structured JSON per request (MVP) for CLI/GUI viewing.

## 8.3 Replay

* **Slot snapshot** (MVP optional): serialize slot values to JSON if types are serializable. Replay by loading snapshot, then re-executing steps (effects disabled or mocked).

---

# 9) Testing & Tooling

## 9.1 Unit tests

* **ReqTest**: build a request context + arena + seed slots; call `Step.call(ctxBase*)`.
* **Pattern**:

  1. Seed required slots.
  2. Invoke step → get `Decision`.
  3. If `.Need`, emulate completions by writing slots or by using a FakeInterpreter helper, then call the continuation.
  4. Assert on slots or final `Decision`.

## 9.2 Static validation (Phase-2)

* Tooling to emit a **Reads/Writes graph** (DOT) per pipeline.
* CI linter: flag multiple writers, read-before-write, dead slots, and cycles.

## 9.3 Developer UX niceties

* `ctx.require` / `ctx.optional` to reduce boilerplate.
* `zerver.step("name", fn)` trampoline avoids hand-written wrappers.
* Optional **codegen** (Phase-2): generate `CtxView` typedefs for common step templates.

---

# 10) Engine Details

## 10.1 MVP engine (blocking)

* **Execution**: linear; `Need` executes effects **immediately** in call order, recording timings; then calls `resume`.
* **Join semantics in MVP**:

  * `.Parallel`: still sequentially executed (but recorded as separate effects); `join` controls when `resume` is invoked (after all or first, etc.).
  * `.Sequential`: same as above with strict order.
  * Required failures → immediate `Fail`. Optional failures → slot unset, error recorded.

## 10.2 Phase-2 engine (non-blocking proactor + scheduler)

* **I/O**: epoll or io_uring backed; HTTP client/DB client pools integrated with reactor.
* **Workers**: CPU workers process steps; **workers never block on I/O**.
* **Queues**:

  * Global effect queue with priority (interactive vs batch); bounded in-flight per target (DB, HTTP) and per request.
  * Work-stealing among workers for fairness.
* **Join & Continuations**:

  * Each `Need` creates a join counter; each effect completion decrements and records success/failure. When the join condition is met, a continuation task is enqueued.
* **Cancellation**:

  * On client disconnect or deadline, cancel outstanding effects (if supported) and drop late completions by `(req_id, version, token)` checks.
* **Backpressure**:

  * If global or per-target concurrency limits hit, new effects are queued; if queues exceed bounds, shed load (return `503`) or degrade (configurable).
* **Circuit breakers / retry budgets (Phase-2)**:

  * Per-target breaker (open/half-open) with configurable thresholds.
  * Per-request retry budget limiting cumulative retries across effects.

---

# 11) Security & Policy

* **Auth steps**: parse header, verify token (via effect), verify roles. Steps run **only** where attached.
* **Rate limiting**: key derivation (e.g., IP + route), check/incr via effect; failure → 429.
* **Idempotency**: all write effects accept an `idem` key; engine ensures single-writer semantics with backend support (e.g., Redis SETNX, DB unique keys).
* **Input limits**: request size, JSON depth/size; safe defaults + configurable caps.
* **Header allowlist**: expose select headers to steps.
* **PII hygiene**: redaction hooks for tracing/logging.

---

# 12) Configuration

* **Server.Config**

  * `addr`: ip/port
  * `on_error`: error renderer
  * `debug`: prints step/effect trace to logs (MVP)
* **Runtime knobs (Phase-2)**:

  * In-flight effect caps (per target / per request)
  * Priority weights
  * Circuit breaker parameters
  * Retry budget per request
  * Arena soft cap per request

---

# 13) Versioning & Compatibility

* **API stability**: `CtxView`, `Decision`, `Effect` shape stable across MVP → Phase-2. Engine swap is transparent.
* **Shared steps**: recommend semantic versioning of shared step libraries (e.g., `shared/auth@v1`).
* **Deprecation**: `@compileError` on removed slots/steps; add shims where feasible.

---

# 14) Example (abridged)

(You already have the full Todo CRUD example updated with path params, typed slots, `CtxView`, explicit continuations, and scoped middleware.)

Key patterns enforced:

* `STEP_ID` writes `.TodoId`; any downstream reader must include `.TodoId` in its View’s `reads`.
* `STEP_DB_LOAD` `Need{ dbGet→.TodoItem, resume=db_loaded }`; continuation must `require(.TodoItem)` then `Continue`.
* `STEP_DB_PUT_NOTIFY` runs required DB write + optional webhook in “Parallel”; **MVP** executes sequentially but preserves trace semantics.

---

# 15) Precise Behavioral Contracts (Edge Cases)

* **Missing slot**: `ctx.require(.X)` → returns `error.SlotMissing` (step should convert to `.Fail(error.InvalidInput)` or similar).
* **Optional effect failure**: token slot is **unset**; continuation sees `optional(.Token) == null`.
* **`Join=any/first_success`**:

  * `any`: resume on first completion; continuation decides next actions; remaining **in-flight** effects are allowed to complete (MVP) or cancelled (Phase-2 option).
  * `first_success`: resume when a success arrives; if all complete and none succeeded:

    * if any required effect failed → pipeline fails,
    * else continue with unset tokens.
* **Multiple writers**: disallowed; **Phase-2** validator rejects pipelines with two writers to the same slot across `before+steps`.
* **Continuation view**: engine calls `resume(*CtxBase)`; the trampoline reconstructs whatever `CtxView` is declared on the **continuation** function, allowing **view transitions** between steps safely.
* **Arena overflow**: on allocation failure, engine fails the request with `500`; future enhancement: soft cap → 413 (Payload Too Large).
* **onExit semantics**: executed after final `Done` or `Fail`, exceptions ignored (logged).

---

# 16) Performance Targets & Benchmarks (Phase-2, aspirational)

* **Echo route**: ≈ Nginx baseline ±10% for HTTP/1.1 keep-alive at p50/p95 (same OS/kernel).
* **CRUD route** (1 DB read + 1 DB write): within 20–30% of a hand-written Zig async handler at p95 with identical clients/drivers.
* **Scheduler fairness**: no starvation under mixed workloads; p99 wobble ≤ 1.5× p95 at 75% saturation.
* **Tracing overhead**: ≤ 5% CPU delta with tracing on; ≤ 1% with sampling at 10%.

(These are validation gates; not guaranteed day one.)

---

# 17) Roadmap

* **MVP (weeks 1–5)**

  * `CtxView` with compile-time enforcement ✅
  * Step trampoline ✅
  * Decision + Effects + explicit continuations ✅
  * Blocking executor; trace recording; error renderer ✅
  * Router (path params) + flows namespace ✅
  * ReqTest + FakeInterpreter; 10 sample unit tests ✅
* **Phase-2 (months 2–4)**

  * Proactor (epoll/io_uring) + worker pool
  * True parallel effects; join counters; cancellation
  * Circuit breaker + retry budgets
  * Static pipeline validator (reads/writes)
  * OTLP exporter + simple web UI for traces
* **Phase-3**

  * Streaming bodies, backpressure on writes
  * Saga compensations (reverse-order rollback with retry/alert policy)
  * CLI tooling (graph gen, replay, trace diff)

---

# 18) Security Review Checklist

* [ ] Input size limits (headers, path, query, body)
* [ ] JSON depth and number of fields caps
* [ ] Auth chain present on protected routes; deny-by-default fallback
* [ ] Sensitive slots redacted in traces/logs
* [ ] Idempotency keys on unsafe methods (POST, PATCH, DELETE)
* [ ] TLS termination and upstream verification (Phase-2 if client calls used)
* [ ] Per-target concurrency limits to avoid amplification attacks
* [ ] Circuit breaker defaults for external IdP/HTTP

---

# 19) Developer Experience (DX) Expectations

* **Compile-time errors** when you access undeclared slots → actionable messages naming the slot and the step.
* **Trace-first** mental model: every step/effect is visible; no hidden async.
* **Unit tests** that run in milliseconds without bringing up a server.
* **No boilerplate wrappers** beyond `CtxView` type aliases and `zerver.step("name", fn)`.

---

# 20) Open Questions (to decide during prototype)

* **Serialization of arbitrary `SlotType`** for replay: require `toJson/fromJson` traits or keep best-effort?
* **Global vs per-route retry budgets**: default landings and overrides.
* **How strict the static validator is in MVP**: warn vs hard-fail on read-before-write.
* **Default `Join` for `.Parallel`**: `.all` or `.all_required`?

---

## Appendix A — Example CtxView Implementation Notes (comptime enforcement)

* `CtxView(spec)` generates methods that **inline** a `slotIn(spec.reads)` or `slotIn(spec.writes)` check:

  ```zig
  comptime if (!hasSlot(s, Reads)) @compileError("slot not in reads: " ++ @tagName(s));
  ```
* The linear search is **comptime**, not runtime; no cost at runtime.
* Error messages include the slot name and the offending method (`require/optional/put`).

## Appendix B — Join Semantics Table (MVP)

| mode     | join          | resume when…                            | required fail                             | optional fail | token state                                 |
| -------- | ------------- | --------------------------------------- | ----------------------------------------- | ------------- | ------------------------------------------- |
| Parallel | all           | all effects finished (success/failure)  | Fail                                      | Continue      | success → set; else unset                   |
| Parallel | all_required  | all **required** finished               | Fail                                      | Continue      | required success set; optional may be unset |
| Parallel | any           | first effect finished (success/failure) | N/A                                       | N/A           | only the finished token (if any)            |
| Parallel | first_success | first success; else all finished        | Fail if any required fails and no success | Continue      | success → set; failures unset               |

(Phase-2 may allow truly background optional effects for `all_required`; MVP still waits, but records optional failure without failing the pipeline.)

## Appendix C — Minimal Unit Test Shape

* Build `ReqTest`, seed `.TodoId`.
* Call `STEP_DB_LOAD.call(req.base())`.
* Assert `.Need`.
* Emulate effect: `req.put(.TodoItem, Todo{…})`.
* Call continuation: `db_loaded` via trampoline or direct typed fn with `CtxBase` → `CtxView` adapter.
* Assert `.Continue`, then read `.TodoItem`.

---

**Bottom line:**
This spec defines a framework whose **core value** is *observability and composable orchestration* with **compile-time enforcement** of state access, while keeping the engine replaceable. Build the **synchronous MVP** to validate the developer experience and trace benefits; invest in the scheduler/proactor **only if** those benefits prove compelling in real use.
