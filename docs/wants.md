# Zerver Wants - Ordered by Complexity

## Level 1: Documentation & Cleanup (Simplest)

- ensure README links to todods instead of SPEC [@docs-team]
- update README to reference new todods [@docs-team]
- validate links across markdown files [@docs-team]
- check other docs for SPEC references and update [@docs-team]
- finalize todods and commit [@core-team]
- mark migration task as done [@docs-team]
- finish migrating spec content to docs folder [@docs-team]
- tidy up repository root files [@core-team]
- archive old design notes if needed [@docs-team]
- add license header template for source files [@tooling-team]
- schedule design review meeting notes placeholder [@core-team]
- draft minimal deployment notes in DEPLOY.md [@docs-team]
- document API surface in a compact cheat-sheet [@docs-team]
- Offer concise docs: how to add a step/slug, surface a catalog endpoint, and operate a runbook.
- write setup guide for connecting to OTLP collector [@observability-team]
- add troubleshooting notes and sample collector config [@observability-team]

## Level 2: Simple Configuration & Build Changes

- add build.zig checks for Zig 0.15 compatibility [@core-team]
- create a simple Makefile or run task for dev [@tooling-team]
- add sample env/config file template [@tooling-team]
- open PR template for future contributors [@tooling-team]
- add folder for experiments/prototypes [@tooling-team]
- add security checklist to repo (from SPEC) [@security-team]
- move Security Review Checklist into todods [@security-team]
- create initial git tags or changelog entry [@release-team]
- Configuration and secrets kit that binds `ZER_*` env vars into typed, trace-masked getters.
- Expose OTLP exporter toggle via config/env [@observability-team]
- Add Config.debug field and wire it through Server initialization per SPEC §12 to control step/effect trace logging.
- Expose configuration via ZER_VER_PROMOTE_QUEUE_MS, ZER_VER_PROMOTE_PARK_MS, and ZER_VER_DEBUG_JOBS.
- Source reactor pool sizes and modes from config.json so deployments tune queues without recompiling.
- Factor a shared libuv build helper in build.zig and gate with CI smoke tests.

## Level 3: Small Code Changes (Simple Additions/Refactoring)

- Add short-hand `query()` method alias for `queryParam()` in `src/zerver/core/ctx.zig` to match SPEC §3.3 API surface.
- Add default values `mode: Mode = .Parallel` and `join: Join = .all` to `Need` struct in `src/zerver/core/types.zig:534-535` per SPEC §3.2 to reduce boilerplate.
- Add `pub fn json(*CtxBase) !std.json.Value` method to `src/zerver/core/ctx.zig` that returns parsed JSON as JsonValue (distinct from existing typed `json(T)`) per SPEC §3.3.
- Rename `Need.continuation` to `Need.resume` and make it required (non-optional) in `src/zerver/core/types.zig:536` per SPEC §3.2 so continuations are explicit and mandatory.
- Change Effect token fields from `u32` to application `Slot` enum type in `src/zerver/core/types.zig` (HttpGet, HttpPost, HttpPut, HttpDelete, DbGet, DbPut, DbDel, DbScan, etc.) per SPEC §3.2 to maintain slot typing consistency.
- Change Step.reads and Step.writes from `[]const u32` to `[]const Slot` in `src/zerver/core/types.zig:557-558` for stronger compile-time slot tracking.
- Enhance ReqTest in `src/zerver/core/reqtest.zig` to accept Slot enum tags instead of bare u32 tokens in `seedSlotString` and related methods per SPEC §9.1.
- Update core types to cover all HTTP verbs and add Need.compensations metadata plumbing.
- Make `src/zerver/impure/executor.zig:defaultEffectHandler` fail loudly or require injection so no request silently succeeds without a real effect implementation, as warned in the architecture doc.
- Ensure failure responses carry contextual error details for debugging and logging.
- Validate and parse idempotency keys early in middleware rather than ad hoc lookups.
- Standardize effect timeout configuration so services rely on shared defaults.
- Clarify how slugs map to route patterns and path parameters.
- Guarantee slot state is cleared between requests, even under pooling.
- Create dedicated slots or namespaces for middleware like rate limit keys to avoid slot reuse bugs.

## Level 4: Moderate Features (New Modules & Components)

- add example of streaming JSON writer in a step [@examples-team]
- create a small example that demonstrates replay [@examples-team]
- add targeted tests that exercise CtxView compile-time validation.
- Deliver a real database-backed example to validate the architecture.
- Create FakeInterpreter test harness in `src/zerver/core/fake_interpreter.zig` to drive continuations without live I/O per SPEC §9.1.
- define observability metrics to export (Prom/OTLP) [@observability-team]
- define span naming conventions for flows/steps [@observability-team]
- specify default span attributes and enrichment sources [@observability-team]
- document span status + error mapping rules [@observability-team]
- prototype OTLP exporter interface [@observability-team]
- implement OTLP exporter configuration struct (endpoint, headers, batching) [@observability-team]
- wire tracer to emit OTLP spans through exporter [@observability-team]
- Enrich `Tracer.toJson` in `src/zerver/observability/tracer.zig` with job/need metadata (mode, join, effect counts, worker info) to deliver the timeline detail promised by the architecture overview.
- Wrap libuv loop, async, timer, and thread-pool primitives with RAII helpers in runtime/reactor/libuv.zig.
- Define join state structs with atomic counters plus helpers for registering, success, failure, and resume checks.
- Manage CPU workers that process continuations via spawn/enqueue/shutdown APIs.
- Document the interpreter resumption strategy after .Need() returns.
- Define how partial failures across multiple effects surface to steps.
- Explain conditional effect patterns when decisions depend on slot data.
- Document the error handling lifecycle: on_error hooks, slot cleanup, and recovery options.
- Clarify ownership and lifetime of pointers stored inside slots to ensure safety.

## Level 5: Significant Features (Tooling & Infrastructure)

- Write installation, quickstart, API reference, testing, deployment, and real-world example docs.
- Produce performance benchmarks to substantiate high-performance claims.
- Performance harness in `bench/` that tracks p95/p99 and allocations with CI regression gates.
- House-style repository template pre-wired with OTLP, budgets, error map, and debug endpoints.
- Learning sample catalog demonstrating hello world, auth chains, fanouts, deadlines, and hedging patterns.
- Implement request replay capture/restore tooling per SPEC §8.3 with slot snapshot serialization and playback capabilities.
- design trace replay format and API [@testing-team]
- add replay CLI sketch and subcommands [@tooling-team]
- Default observability kit with ring-buffer tracer, OTLP exporter, per-route sampling knobs, and local timeline viewer.
- Per-request arena allocator with peak usage tracing to expose memory drift.
- Slot and CtxView guardrails providing compile-time lints, cheat sheets, and editor snippets.
- Code mods and editor snippets that enforce idiomatic Step/Effect/resume patterns.
- Effect adapter library for HTTP, SQL, KV, and queue integrations with declarative metadata macros.
- implement basic linter script prototype [@tooling-team]
- plan static pipeline validator for reads/writes [@compiler-team]
- Provide compile-time guarantees that slots are written before reads and expose dependency maps.
- Ship SDK/dev UX helpers, local dev runner, and canonical examples to speed onboarding.
- Project scaffolder command `zerver new` that wires slots, steps, effects, tests, and metrics.
- `zerver dev` hot-reload loop that builds with debug info, watches files, and restarts automatically.
- Measure and optimize slot allocation overhead and repeated formatting/serialization costs.

## Level 6: Complex Architectural Changes

- Replace the `std.AutoHashMap(u32, *anyopaque)` slot store in `src/zerver/core/ctx.zig` with typed storage that honours the `CtxView` read/write spec at runtime, closing the TODO called out in the architecture doc.
- Route `Server.listen` in `src/zerver/impure/server.zig` through the shared plumbing in `src/zerver/runtime/listener.zig`/`handler.zig` so we maintain one canonical HTTP loop.
- Build an effect dispatcher that maps Effect union variants onto libuv operations with timeout and retry handling.
- Extend the task system to coordinate continuation and compute queues with shared shutdown logic.
- Bridge interpreter callbacks into the new scheduler while keeping MVP behaviour behind a feature flag.
- Create deterministic tests for all join modes, timeouts, and retry policies.
- Thread compensation stubs through Need handling using a SagaLog placeholder returning error.Unimplemented.
- design compensation/saga hooks for writes [@arch-team]
- Document configuration, changelog, and usage instructions for the experimental reactor path.
- Emit structured runtime events for loop operations, dispatch, completions, and continuations.
- Context deadline support (`ctx.deadline`) that propagates into effect metadata and cancels expired resumes.
- Effect metadata schema expressing taxonomy, idempotence, retry budgets, and HTTP status mapping.
- Golden route timeline tests with fault-injecting effects to rehearse incident scenarios.
- Join combinators (`join.All`, `join.Race`, `join.Quorum`, `join.Hedge`) with deterministic Slot merge policies.
- Encode decisions as `{Need|Continue|Insert|Replace|Done|Fail}` and auto-yield on `Need`.
- Drop late results via context deadlines and render explicit cancellation paths.
- Require idempotency keys on write effects so retries stay safe.
- Enable composable effects so higher-level workflows can build on lower-level primitives.
- Make control flow, retries, and cancellations explicit to developers.
- Develop richer error handling patterns that differentiate domains and support recovery.
- Formalize middleware dependency ordering or scoping to avoid fragile global chains.

## Level 7: Advanced Architecture (Scheduler, Reactor, Proactor)

- plan Phase-2: proactor + scheduler design [@arch-team]
- research io_uring bindings and Windows alternatives [@platform-team]
- design priority queues and work-stealing sketch [@arch-team]
- add backpressure and queue bounding plan [@arch-team]
- add circuit breaker and retry budget plan [@arch-team]
- Implement the phase-2 proactor + scheduler upgrade without changing CtxView/Decision/Effect APIs.
- Keep Server.listen synchronous while delegating work to libuv-backed workers for transparency.
- Enforce Decision.Need join contracts with accurate required/optional bookkeeping under concurrency.
- Provide clean startup, shutdown, cancellation, and backpressure semantics for the new reactor.
- Pure/Impure split where pure steps plan effects and an interpreter handles I/O, timers, and randomness.
- Treat each request as a small DAG with fan-in/out, join counters, deadlines, and explicit hard vs soft errors.
- Schedule steps as short cooperative jobs on priority queues with work-stealing and aging for fairness.
- Ensure I/O never blocks workers by using a reactor/proactor and resuming via continuations.
- Keep slot ownership single-writer to avoid locks on the hot path.
- Enforce backpressure with per-request caps on parallelism and bounded queues that shed load early.
- Let middleware + router handle orchestration while CPU work runs in time-boxed cooperative jobs.
- Capture observability for queue times, execution durations, yields, retries, in-flight I/O, and queue depth.
- Expose interpreter scheduling, concurrency, and cancellation semantics for transparency.
- Support chained flows, asynchronous triggers, and background jobs in the architecture.

## Level 8: Operational Excellence & Governance

- Use canonical flow slugs backed by a registry with aliasing, versioning, and tenant/region headers.
- Maintain an allowlist registry for steps/options with capability checks per tenant.
- Govern flows with ownership metadata, deprecation headers, successor links, and slug quality linting.
- Establish slug governance covering naming rules, aliasing, deprecation, and versioning.
- Maintain a route catalog documenting ownership, review expectations, and change workflow.
- Define where auth/identity logic runs in the state machine and how tenant roles map to capabilities.
- Publish effect policy defaults for retries, backoff, circuit breakers, idempotency keys, and timeouts.
- Tune scheduler priorities, quanta, and queue bounds for interactive versus batch workloads.
- Implement backpressure caps and overload shedding strategies (503 vs degrade).
- Route fairness framework with priority classes, aging/token buckets, and per-route p99 budget alerts.
- Set time budgets (~2-5 ms interactive, 10-20 ms batch) and tune from p95/p99 telemetry.
- Document streaming/compression policy: when to stream, gzip/brotli rules, range support.
- Specify persistence requirements for continuation IDs, snapshots, and audit retention.
- List required observability metrics, log fields, tracing spans, and SLO targets (p95/p99).
- Codify a testing plan for pure steps, fake interpreters, chaos drills, and timeout exercises.
- Describe deployment shape: per-core worker counts, proactor choice per platform, configuration knobs.
- Enforce security hygiene: input limits, header allowlists, slug denylists, privacy-safe URLs.
- Stream responses (and gzip) to avoid large buffers.
- Allocate per-request arenas with zero-copy header/body views.
- Target mixed CPU+I/O endpoints needing strict tail latency control.
- Support complex flows that demand explicit ordering, retries, and auditability.
- Provide readable URLs while keeping canonical control on the server.

## Level 9: Advanced Observability & Telemetry

- Distinguish logical execution, queueing, and parking latency in telemetry.
- Keep default traces compact while auto-promoting spans when thresholds are exceeded.
- Align span kinds and attributes with current OpenTelemetry semantic conventions.
- Standardize span taxonomy: server root, internal steps, client effects, and promoted job internals.
- Capture full job lifecycle timestamps so queue, dispatch, park, and run durations are derived consistently.
- Emit job lifecycle events on logical spans by default to minimize span fan-out.
- Auto-promote queue-wait and park episodes to child spans when threshold env vars or debug flags trigger.
- Adopt clear naming conventions for roots, steps, effects, continuations, and job internals.
- Populate root spans with HTTP, URL, network, client, and request identifiers per OTEL spec.
- Record step span metadata such as sequence numbers, layers, decisions, reads, and writes.
- Enrich effect spans with job timing metrics plus domain-specific fields for DB, HTTP, and cache calls.
- Represent job state with structs that aggregate park episodes and compute duration metrics safely.
- Defer span creation until completion so only slow jobs allocate span structures.
- Emit events with uniform job attributes and promote to spans only when necessary.
- Quantify memory and CPU savings from the event-first model to justify the new telemetry design.
- Follow the phased migration plan: event-first, runtime wiring, validation, then adaptive thresholds.
- Capture lessons learned around thresholds, backfilled events, and semantic namespace choices.
- Plan future enhancements including adaptive thresholds, tail sampling, exemplars, queue depth, worker metrics, and concurrency limit signals.
- Double down on observability: trace UI, OTLP export, comparison tooling for slow/fast requests.

## Level 10: Long-term Vision

- Plan the Phase 2 migration path and communicate expectations.
- Optional declarative route metadata that emits minimal OpenAPI artifacts for clients.
