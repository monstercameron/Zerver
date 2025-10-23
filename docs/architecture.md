# Zerver Architecture

This document explains how the Zerver framework is structured, how a request flows through the system, and where the major subsystems live in the repository. It aims to give contributors and operators enough context to reason about the runtime, extend core features, and debug behaviour.

---

## High-Level Design

Zerver is a step-oriented HTTP backend framework written in Zig. Application logic is authored as **pure steps** that operate on a request context and return **Decisions**. Decisions tell the runtime whether to continue, finish, fail, or enlist the runtime to execute side effects (database calls, HTTP requests, file access, etc.). The runtime is responsible for:

- **Context management** - typed slot storage, lifecycle hooks, request metadata (`src/zerver/core/ctx.zig`).
- **Routing and orchestration** - registering routes/flows, invoking step chains, handling continuations (`src/zerver/impure/server.zig`, `src/zerver/routes/router.zig`).
- **Effect execution** - running requested effects synchronously (MVP) and wiring results back into the context (`src/zerver/impure/executor.zig`).
- **Observability** - structured logging (`slog`) and timeline-style tracing (`src/zerver/observability`).
- **Runtime plumbing** - socket management, HTTP framing, platform shims (`src/zerver/runtime`).

The structure enforces a strict separation between pure decision logic and impure runtime operations. This allows the same step code to run in tests, simulated replays, or a future asynchronous executor without changes.

The current codebase focuses on validating this programming model. Networking, effect handlers, and persistence are intentionally minimal: `Server.handleRequest` accepts raw HTTP text, the bundled examples simulate database behaviour, and the runtime listener is stubbed out. Phase-2 tasks connect these pieces into a production-quality stack without changing the step-based API.

---

## Module Map

| Area | Description | Key Files |
|------|-------------|-----------|
| **Library Entry Point** | Public exports consumed by applications. Re-exports core types, helpers, server APIs. | `src/zerver/root.zig` |
| **Core** | Pure data structures and helpers for writing steps. Includes `CtxBase`, `CtxView`, `Decision`, `Effect`, retry/backoff policies, error renderer helpers, and the request test harness. | `src/zerver/core/ctx.zig`, `src/zerver/core/types.zig`, `src/zerver/core/core.zig`, `src/zerver/core/error_renderer.zig`, `src/zerver/core/reqtest.zig` |
| **Impure Runtime** | Orchestrates steps, handles routing, executes effects. MVP server uses `handleRequest` with caller-supplied bytes; `Server.listen` still logs a stub message. | `src/zerver/impure/server.zig`, `src/zerver/impure/executor.zig` |
| **Routing** | Path/method lookup and route registration. Produces before/step chains consumed by the server. | `src/zerver/routes/router.zig` |
| **Observability** | Structured logging shim and in-memory tracer that records step/effect events and emits JSON traces. | `src/zerver/observability/slog.zig`, `src/zerver/observability/tracer.zig` |
| **Runtime (Phase-2)** | Network listeners, HTTP request/response framing, platform-specific socket helpers. Implemented prototypes waiting to be wired into the main server loop. | `src/zerver/runtime/listener.zig`, `src/zerver/runtime/handler.zig`, `src/zerver/runtime/platform/windows_sockets.zig` |
| **Features** | Example feature implementations (todos, blog, hello). Demonstrate Ctx usage, effects, middleware, and routing patterns. | `src/features/**` |
| **Bootstrap** | Future entry points meant to wire the runtime into applications (currently stubs). | `src/zerver/bootstrap/init.zig` |

Supporting documentation in `docs/*` dives into specific areas (e.g., `IMPLEMENTATION_SUMMARY.md`, `HTTP_REQUEST_HANDLING.md`). This architecture document ties those viewpoints together.

---

## Core Concepts

### Context (`CtxBase` and `CtxView`)

- `CtxBase` holds per-request state: HTTP metadata, slot storage (`std.AutoHashMap` keyed by slot enum tags), tracing buffers, exit callbacks, and the last error. Steps receive this context (or a typed view) and can inspect/modify it.
- Slot helpers (`slotPutString`, `slotGetString`, etc.) are used by the executor to wire effect results into the context. TODOs in `ctx.zig` highlight unfinished compile-time enforcement for `CtxView` reads/writes (currently return `error.NotImplemented`). Runtime slot access is already functional via `CtxBase`.
- `CtxView(spec)` generates a wrapper struct to enforce allowed reads/writes at compile time. The compiler will reject steps that access slots outside the declared spec. The runtime backing store is still TODO, which is called out explicitly with comments.

### Steps and Decisions

- Steps are wrapped via `core.step(name, fn)` into `types.Step` records. Each step exposes a `call` trampoline that accepts `*CtxBase`.
- A step returns a `Decision`:
  - `.Continue` -> next step.
  - `.Done(Response)` -> short-circuit with a response.
  - `.Fail(Error)` -> propagate error (rendered by error renderer/server).
  - `.need(Need)` -> request runtime-managed effects, with `Need.effects`, `Need.mode`, `Need.join`, and a `continuation` callback.

### Effects and Policies

- `types.Effect` captures desired I/O (HTTP, DB, file). Each effect carries a slot token telling the executor where to stash results in the context.
- Retry, timeout, backoff, and idempotency fields live alongside effect definitions. The default `Executor.defaultEffectHandler` is deliberately trivial; applications provide a real handler during `Server.init`.
- TODOs in `types.zig` note future support for streaming responses and RFC-aligned method extensibility. Until real integrations land, the examples simulate results to showcase orchestration and tracing.

---

## Request Lifecycle

### 1. Transport (future runtime integration)

`src/zerver/runtime/listener.zig` and `handler.zig` contain a blocking HTTP/1.1 implementation: it accepts TCP connections, implements keep-alive, parses requests (including chunked bodies), and writes responses. These modules are not yet wired into the public API—`Server.listen` logs a message and expects callers to drive `handleRequest` manually. Phase-2 work will:

1. Replace the stubbed `listen` path with the runtime listener.
2. Introduce a proactor/event-loop so effect execution and socket IO no longer block worker threads.
3. Harden the parser for the full RFC surface (transfer-encodings, header folding, robustness tests).

### 2. Server handleRequest

Applications call `Server.handleRequest(req_bytes, allocator)` directly (typically from tests, examples, or an external harness). The flow inside `src/zerver/impure/server.zig`:

1. **Parse** - `parseRequest` performs a lightweight split of the HTTP text into method, path, headers, and body. It purposefully punts on edge cases (query parsing is TODO, header normalization is basic) so the focus stays on orchestration.
2. **Route Lookup** - `router.findRoute` resolves the request to either a REST route or a flow based on method/path or slug.
3. **Context Setup** - A fresh `CtxBase` is built, storing request metadata, allocating slot/hash maps, and hooking trace buffers.
4. **Tracing** - A `Tracer` instance is initialised per request. Step/effect execution records start/end events for later JSON export (`X-Zerver-Trace` header).
5. **Pipeline Execution** - `executePipeline` runs:
   - global middleware (`Server.use`)
   - route-specific `before` chain
   - main steps

   Each step executes via `Executor.executeStepWithTracer`, which wraps the typed function pointer, handles errors, and records trace markers.
6. **Decision Handling** - The final `Decision` is passed to `renderResponse`. `.Done` responses are reused, `.Fail` delegates to `config.on_error`, `.Continue` defaults to `200 OK`.
7. **Trace Export** - `httpResponse` serialises status line/headers and attaches `X-Zerver-Trace` with JSON produced by `Tracer.toJson`.

### 3. Executor and Effects

When a step returns `.need`, `Executor.executeNeed`:

1. Iterates requested effects, logs start events, and calls the configured effect handler (`Server.init` accepts a function pointer supplied by the application).
2. On success, stores data into context slots via `CtxBase.slotPutString`. On failure, marks the context's `last_error`.
3. Applies join strategy (currently all strategies collapse to "run all effects sequentially" in the MVP).
4. If required effects fail, returns `.Fail`; otherwise, invokes the continuation step pointer with the same context (`executeStepInternal` recursion).

The default effect handler (`defaultEffectHandler`) just returns success; real applications inject their own implementations for HTTP/DB/etc. The MVP executor runs all effects sequentially irrespective of join mode—future work (tracked in `docs/TODO.md`) introduces parallel dispatch, backpressure, circuit breakers, and OTLP telemetry so production handlers can take advantage of richer scheduling.

---

## Observability Pipeline

- **Structured Logging (`slog`)** - `src/zerver/observability/slog.zig` wraps log levels and attribute helpers. Logging is used throughout the runtime to provide context-rich diagnostics.
- **Tracer** - `Tracer` records step/effect start/end events with timestamps and durations. After the pipeline completes, `Tracer.toJson` produces a timeline embedded in HTTP responses. TODOs in the code call out missing attribute printing and planned OTLP/trace replay integrations.
- **Trace TODOs** - `docs/TODO.md` now includes tasks to define span naming conventions, enrich attributes, wire OTLP exporters, expose configuration toggles, and document collector setup. These feed into the architecture roadmap for comprehensive observability.

---

## Example Data Path and Tests

`examples/todo_crud.zig` wires the framework together with simulated database effects—it provides its own `effectHandler` that returns canned JSON for reads and a success marker for writes. This keeps the spotlight on orchestration, tracing, and middleware composition. Real deployments should swap in effect handlers that call actual databases or services (for example, a Postgres client that respects retries and idempotency keys). The `src/zerver/core/reqtest.zig` harness supports running pipelines in memory so these handlers can be validated with deterministic inputs. Expanding the examples to cover real persistence, authentication, configuration, and deployment stories is a key next step on the roadmap.

---

## Example Features

Under `src/features`, Zerver includes runnable samples that exercise the framework:

- **Todos**: Demonstrates CRUD flows, middleware, slot usage, and effects.
- **Blog**: Shows multi-step orchestration with custom types and effect combinations.
- **Hello**: Minimal "hello world" pipeline.

Each feature registers routes via the exported `Server` API and uses `core.step` to define logic. These files serve as reference implementations aligning with the architecture described above.

---

## Roadmap Notes & Gaps

Open TODOs captured in code and `docs/TODO.md` directly influence architectural evolution:

- **Transport** - Implement the real TCP listener, keep-alive policies, query parsing, and integrate `runtime/*` with `Server.listen`.
- **Scheduler** - Design and build the proactor/event loop, priority queues, backpressure, and circuit breaker enforcement for resilient throughput.
- **CtxView Runtime** - Finish slot storage for typed views (`ctx.zig` TODOs) so compile-time guarantees are backed by runtime storage.
- **HTTP Compliance** - Align timeout handling, header parsing, and streaming responses with RFC 9110/9112.
- **Telemetry** - Deliver OTLP exporters, trace replay tooling, configuration surfaces, and document external collector setup.
- **Production Guides** - Provide Quickstart, testing, deployment, and performance docs that walk developers from the MVP examples to production services.

These gaps are intentional placeholders; the MVP focuses on proving the step/decision model while leaving space for Phase-2 features and documentation that explain how to run the framework against real infrastructure.

---

## How to Navigate the Codebase

1. Start with `src/zerver/root.zig` to see exposed APIs.
2. Examine `src/features/todos` for a full example of defining steps, effects, and routes.
3. Follow `Server.handleRequest` to understand routing, context initialisation, and pipeline execution.
4. Dive into `Executor` to see how `.need` decisions are satisfied and how effect results flow back into slots.
5. Explore `docs/HTTP_REQUEST_HANDLING.md` and `docs/IMPLEMENTATION_SUMMARY.md` for deeper dives into specialised areas.

The combination of this architecture doc and the existing docs should provide a comprehensive mental model for extending or integrating Zerver.

---

## Summary

Zerver splits pure business logic from runtime execution. Steps describe "what should happen"; the runtime handles "how it happens" (I/O, scheduling, tracing, HTTP plumbing). The framework currently ships with a synchronous MVP executor and a rich observability story, with Phase-2 work scoped around networking, async execution, and production hardening.

Contributors should use this document as a starting point, then consult source files and TODOs for implementation details and upcoming work.
