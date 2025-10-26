# Phase 2 Reactor & Scheduler Plan

Owner: TBD  
Status: Draft (2025-10-26)

## 1. Objectives

- **Spec alignment**: Implement the Phase-2 proactor + scheduler upgrade described in `docs/SPEC.md` §10 while keeping the public API (`CtxView`, `Decision`, `Effect`) stable (§13).
- **Transparent engine swap**: Preserve the blocking MVP semantics at the API boundary; `Server.listen` remains synchronous while work is delegated to libuv-backed workers.
- **Deterministic orchestration**: Honour `Decision.Need` join contracts (§4.2) with accurate bookkeeping, ensuring required/optional semantics, join modes, and continuation scheduling are correct under concurrency.
- **Graceful lifecycle**: Provide clean startup/shutdown, cancellation, and backpressure mechanisms consistent with §10.2 and §4.1 (cleanup, `onExit`).
- **Trace-first runtime**: Emit structured events (spec §8) for loop operations, effect dispatch, completion, and continuations without imposing excessive overhead.

## 2. Non-Goals

- Shipping production-grade HTTP/DB drivers: we will stub or adapt existing MVP blocking code for now.
- Implementing OTLP export, circuit breakers, or retry budgets in this iteration; we focus on the core reactor and scheduler scaffolding.
- Replacing all MVP execution paths immediately. We target an opt-in path behind a build flag/env toggle, then iterate.

## 3. Architecture Overview

```text
[app steps] ──(Decision)──▶ [Interpreter]
                                 │
                                 ▼
                        [Scheduler Queue]
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
        [CPU Worker Pool]                 [Effect Dispatcher]
              │                                     │
              ▼                                     ▼
        run continuations               libuv loop (uv_run)
                                            │
                  ┌─────────────────────────┴─────────────────────────┐
                  ▼                     ▼                             ▼
             Timers (uv_timer_t)   Async (uv_async_t)        Thread pool (uv_queue_work)
```

**Interpreter**: Translates `Decision.Need` into reactor tasks, creates join state (counters, required flags, slot tokens), and enqueues continuation work when joins resolve.

**Scheduler Queue**: Lock-free multi-producer/multi-consumer structure (likely Zig `std.atomic.Queue` or custom) feeding CPU workers with ready continuations.

**Effect Dispatcher**: Wraps libuv handles and thread-pool submissions, ensuring each effect’s timeout, retry policy, and optional vs required status is tracked.

**Join State**: A per-request/per-Need structure containing:
- outstanding count
- required failure flag
- optional failures log (for traces)
- resume function pointer + context pointer (continuation slot)
- Mode/Join semantics from `Decision.Need`

## 4. Work Streams & Milestones

### 4.1 Build & Tooling

1. **Build helper**: Encapsulate libuv source list and macros in `build.zig` helper for reuse across binaries/tests.
2. **CI sanity**: Ensure `zig build libuv_smoke` runs in automation (derive from new plan). Add optional `zig test` gating once interpreter integration lands.

### 4.2 Runtime Foundations

1. **`runtime/reactor/libuv.zig`**
   - Wrap libuv loop creation, `uv_async_t`, `uv_timer_t`, and thread-pool submission.
   - Provide RAII-style helpers (`init`, `deinit`, `closeHandle`), returning Zig errors mapped to `LibuvError` equivalents.

2. **`runtime/reactor/join.zig`**
   - Define join state struct with atomic counters and completion callbacks.
   - Implement helpers: `initJoin`, `registerEffect`, `markSuccess`, `markFailure`, `shouldResume`.

3. **`runtime/reactor/effect_dispatch.zig`**
   - Translate `Effect` union into specific libuv operations.
   - Enforce `timeout_ms`, `retry`, and required vs optional semantics.
   - Surface completions back into join state via scheduler queue.

4. **`runtime/reactor/task_system.zig`**
   - Build on shared `JobSystem` to provide continuation vs compute queues with shared shutdown semantics.
   - Expose helper accessors so effect dispatchers and continuations can share pools safely.
   - Source pool sizes and compute mode from `config.json` (`reactor` section) so deployments can tune queues without recompiling.

5. **`core/types.zig` updates**
   - Extend `Effect` union to cover all HTTP verbs for dispatcher parity.
   - Add `Need.compensations` metadata hook; saga execution remains stubbed but can be threaded through pipelines early.

6. **`runtime/scheduler.zig`**
   - Manage CPU worker threads (likely Zig threads) that process continuations.
   - Provide APIs: `spawn`, `enqueue(ContinuationTask)`, `shutdown`.

7. **`runtime/runtime_engine.zig`**
   - Orchestrate interpreter ↔ reactor boundaries.
   - Accept MVP interpreter callbacks but route through new scheduler when enabled.

### 4.3 Integrations

1. **Interpreter bridge**: Update the existing step execution pipeline to call the scheduler when `Decision.Need` appears.
2. **Slot writes**: Ensure effect completions write tokens via `CtxBase._put` before enqueuing continuations.
3. **Error propagation**: Required effect failures synthesize `Decision.Fail` with `Error` per spec §7.
4. **Shutdown**: Connect `Server.deinit` / `listen` teardown to reactor shutdown (cancel outstanding work, flush queues).

### 4.4 Observability & Testing

1. **Tracing hooks**: Mirror spec §8 events: `ReactorEffectScheduled`, `ReactorEffectCompleted`, `JoinSatisfied`, `ContinuationEnqueued`.
2. **Smoke suite expansion**:
   - Multi-effect join cases (all / any / first_success).
   - Timeout + cancellation scenario (close loop before completion, ensure join handles gracefully).
   - Retry policy enforcement (simulate failure; ensure retry budget decrements).

3. **Integration tests**: Extend `tests/integration/server_test.zig` (or add new) to run a real route via libuv engine path.
4. **Bench harness** (optional): Basic throughput benchmark comparing MVP vs reactor path.

### 4.5 Compute Worker Pool

1. **Dedicated CPU queue**: Introduce a separate queue for long-running, CPU-bound tasks (analytics, JSON encoding, compression) so they do not block continuation workers.
2. **Worker sizing**: Expose configuration for compute worker count (default `max(1, cpu_count / 2)`) and allow runtime overrides via `Server.Config` extensions.
3. **Task API**: Provide `scheduleCompute(work: *const fn(*CtxBase) void, ctx: *CtxBase)` or similar so steps can explicitly offload heavy work while guaranteeing arena ownership rules.
4. **Tracing hooks**: Emit `ComputeTaskScheduled`, `ComputeTaskStarted`, `ComputeTaskCompleted` events feeding into the tracing pipeline for observability.
5. **Backpressure**: Enforce bounded compute queue size (configurable). When full, surface a `Decision.Fail` with `Error{kind = TooManyRequests}` or fallback strategy per spec §10.2.
6. **Testing**: Add stress tests that enqueue many CPU tasks to ensure fairness between continuation workers and compute workers; confirm shutdown drains both pools cleanly.

### 4.6 Saga & Compensation Stubs

1. **`runtime/reactor/saga.zig`**
   - Provide a minimal stub (`SagaLog`) returning `error.Unimplemented` so upper layers can begin wiring compensation metadata without committing to behaviour.
2. **Compensation pipeline**
   - Thread `Need.compensations` through interpreter plumbing while keeping execution disabled.
3. **Documentation**
   - Mark saga rollback work as deferred; capture open questions for ordering, retry strategy, and observability before implementing in a later phase.

## 5. Incremental Delivery Plan

| Step | Deliverable | Validation |
| --- | --- | --- |
| 1 | libuv build helper + smoke tests (done) | `zig build libuv_smoke` |
| 2 | Reactor wrapper module + unit tests | new tests under `tests/unit/reactor_*.zig` |
| 3 | Join state implementation | deterministic tests covering all join modes |
| 4 | Effect dispatcher (HTTP/DB placeholders) | fake effect completions + timeouts |
| 5 | Task system coordinating continuation/compute pools | unit tests under `tests/unit/reactor_task_system.zig` |
| 6 | Compensation stubs threaded through Need | unit coverage validating `error.Unimplemented` |
| 7 | Scheduler integration with continuations | existing ReqTest + new integration tests |
| 8 | Feature flag to switch runtime | CLI/env gating, docs updated |

## 6. Open Questions

- **Backpressure strategy**: Do we implement per-target caps now or stub metrics/coarse limits first? (Spec §10.2 mentions bounded queues.)
- **Cancellation semantics**: Should optional effects continue completing post-resume (MVP behaviour) or be cancelled immediately when join condition is met? (Spec Appendix B suggests optional completions may still occur in MVP.)
- **Retry policy location**: Implement inside dispatcher now or defer until dedicated policy manager is available?
- **Configuration surface**: Where do we expose thread counts, queue depths, and timeout defaults? (Candidate: extend `Server.Config`.)

## 7. Documentation & Communication

- Update `docs/SPEC.md` once implementation details differ or solidify (e.g., actual backpressure approach).
- Maintain changelog entries summarising the experimental reactor work.
- Add developer guide in `docs/` for enabling the Phase 2 engine (`docs/PHASE2_USAGE.md`, future work).

---

**Next Immediate Actions**

1. Factor libuv build helper (`libuv_sources` handling) into reusable function in `build.zig`.
2. Scaffold `src/zerver/runtime/reactor/libuv.zig` with loop setup/teardown and a placeholder API.
3. Expand smoke tests to cover join behaviours as soon as join module exists.
