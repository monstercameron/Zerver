Here’s a clean, scalable project layout that keeps **pure ↔ impure** boundaries obvious, makes testing easy, and leaves room for growth without spaghetti.

# Top-level layout

```
main.zig
build.zig

/zerver            (core server lib — no app logic here)
  zerver.zig       (public API surface; re-exports)
/zerver/core       (pure & scheduler plumbing)
  state.zig        (RequestCtx, State/Decision types, ownership rules)
  plan.zig         (route → plan expansion, profiles, slugs)
  scheduler.zig    (queues, priorities, time budgets, aging)
  jobs.zig         (job abstraction, cooperative step contracts)
  serialize.zig    (render/streams interfaces; no sockets)
/zerver/impure     (I/O edges, impure adapters)
  proactor_linux.zig  (io_uring/epoll)
  proactor_windows.zig (overlapped I/O)
/zerver/observability
  log.zig          (tap-only; pluggable)
  metrics.zig      (counters/timers; Prom/OTLP adapters)

/effects           (impure interpreters of “effects”)
  db.zig           (DB client, pool, retries, idempotency)
  http.zig         (HTTP client; DNS; backoff/circuit-breaker)
  sockets.zig      (raw TCP/UDP; TLS adapter if needed)
  time.zig         (clock/timers/sleep, monotonic/timeouts)
  crypto.zig       (random bytes, signing/HMAC; separated for testability)

/funcs             (pure business logic and helpers)
  steps/           (each file = one cohesive step or small group)
    parse_json.zig
    validate_checkout.zig
    load_user.zig
    load_cart.zig
    biz_quote.zig
    render_ok.zig
    render_err.zig
  helpers/         (pure utility; no I/O)
    json_utils.zig
    pricing.zig
    math.zig

/routes            (server-owned naming & composition)
  catalog.zig      (slug → plan map, aliases, versions)
  binder.zig       (bind slugs/verbs → initial State/DAG)

/config
  defaults.zon     (ports, pool sizes, timeouts)
  tenants.zon      (caps/limits per tenant/profile)

/tests
  pure/            (unit tests for funcs/* and core/*)
  integration/     (fake interpreters; scenario tests)
  perf/            (bench harness; p95/p99 tracking)
```

---

## Responsibilities & dependencies (golden rules)

* **/funcs** (pure): may import `/zerver/core` types and `/funcs/helpers`; **never** import `/effects` or `/zerver/impure`.
* **/effects** (impure): implement effect interfaces; may depend on OS APIs and `/zerver/impure`; **never** import `/funcs`.
* **/zerver/core** (pure infra): defines `State`, `Decision`, `Effect` enums/structs, `RequestCtx`, queues, scheduler contracts.
* **/zerver/impure**: event loop, proactor/reactor, thread pools; plugs into scheduler via narrow interfaces.
* **/routes**: maps **server-owned** slugs (English IDs) or continuation IDs to **plans** (lists/DAGs of steps); versioned registry lives here.
* **main.zig**: wire-up only—load config, build the capability table (which effects are enabled), start the server.

Think “**onion**”: funcs in the center (pure), effects at the edge (impure), zerver holds the ring glue.

---

## Key files (what each should expose)

### `zerver/core/state.zig`

* `RequestCtx` (owned slots, deadline, priority, idempotency info)
* `State` / `Decision`:

  * `Continue | Insert[..] | Replace[..] | Need[..effects] | Done | Fail`
* Ownership rules (doc comments) so each step knows which field it can write.

### `zerver/core/scheduler.zig`

* Priority queues (Interactive/Default/Batch) with bounds + aging
* Cooperative quantum policy (e.g., 2–5ms for interactive)
* Single-writer rule for SM mutations
* Backpressure hooks (per-request caps: in-flight I/O, parallel steps)

### `zerver/impure/proactor_*.zig`

* Submit non-blocking ops; on completion, enqueue continuations with `(req_id, token, payload_or_error)`
* No business logic—just I/O execution & marshaling

### `/effects/*.zig`

* One file per effect domain; each exports **capabilities** (function pointers + small context)
* Centralized retry/timeout/backoff/circuit-breaker/idempotency
* Pluggable (prod vs. fake for tests)

### `/funcs/steps/*.zig`

* Each step: **pure** function taking `(ctx: *RequestCtx)` returning a `Decision`
* Exactly one **owned output** written per step (no locks)
* Zero I/O—return `Need[..]` to request effects

### `/routes/catalog.zig`

* `slug → Plan` registry (versioned), alias table, deprecations
* Keeps your **English URLs** canonical and governed

---

## Configuration & wiring

* **Capabilities table (DI-lite):** Build a struct at startup that lists which effects are available (`db`, `http`, `time`, `crypto`…), each with prod or fake impl. Pass it to the interpreter only.
* **Policy per tenant/profile:** Max inflight I/O, max parallel steps, compression policy, renderer choice—looked up on admission.
* **Portability:** select `proactor_linux` vs `proactor_windows` in `build.zig` by target.

---

## Testing strategy

* **Pure:** Directly unit-test steps under `/funcs/steps` with table-driven inputs → decisions. Zero mocks.
* **Interpreter:** Replace `/effects/*` with fakes in `/tests/integration` to simulate latency, retries, errors.
* **Chaos:** Inject stale completions, timeouts, partial failures—assert scheduler ignores stale `(req_id, version, token)`.
* **Perf:** Small harness in `/tests/perf` to record p50/p95/p99; track regressions in CI.

---

## Observability & ops

* **/zerver/observability** exports:

  * `log` with structured `req_id`, `slug`, `state`, `duration`, `io_wait_ms`, queue depths
  * `metrics` with counters/timers (Prom/OTLP)
* **Catalog endpoint:** `GET /flow/v1/catalog` lists slugs, owners, status, successor versions (helps UX & tooling)
* **Deprecation:** serve `Deprecation` + `Link: rel="successor-version"` when a slug is phased out

---

## Conventions & naming

* **Slugs:** `kebab-case`, ≤ 80 chars, single canonical entry; aliases 308 → canonical
* **Files:** one step per file when possible (`biz_quote.zig`), or a tight group if tiny
* **Effects:** name by resource (`db.zig`, not `postgres.zig`); keep transport details inside
* **Versions:** registry under `/routes` has `v1`, `v2` modules; URLs carry `/flow/v1/...`

---

## Extensibility

* Add a new step? Drop a file into `/funcs/steps`, register it in the routes catalog, done.
* Swap an effect backend (e.g., Postgres → SQLite)? Only `/effects/db.zig` changes; pure code untouched.
* Add a new platform? Implement a new proactor; scheduler and funcs don’t care.

---

## What goes in `main.zig` (high level)

* Load `/config/*.zon`
* Initialize logger/metrics
* Build capability table (choose real vs fake effects)
* Start proactor/reactor + scheduler
* Mount `/routes` catalog (slugs → plans)
* Listen & serve

---

### Why this layout works

* **Separation of concerns** is visible in the tree.
* **Pure business logic** lives in `/funcs` and stays testable.
* **Impure edges** are isolated under `/effects` and `/zerver/impure`.
* **Server behavior** (queues, scheduling, URLs) is centralized under `/zerver` and `/routes`, not scattered.
* **Replaceable parts** (DB, HTTP client, proactor) don’t leak into pure code.

If you want, I can also draft a minimal `build.zig` outline and a short “contribution guide” (coding standards + slug governance) to keep the repo tidy as it grows.
