# OpenTelemetry Implementation Revision Plan

## Executive Summary

This plan outlines the necessary changes to align the current OTEL implementation with the objectives defined in `OTEL_improvement.md`. The goal is to implement a compact, threshold-based span promotion system that distinguishes logical work from queueing/parking overhead while adhering to OpenTelemetry semantic conventions.

---

## Current State Analysis

### What Exists

1. **Core Infrastructure** (`otel.zig`, `telemetry.zig`, `tracer.zig`)
   - Full OTLP/HTTP JSON exporter with retry logic
   - Request lifecycle tracking with span hierarchy
   - Job system event tracking (enqueue, start, complete)
   - Subscriber pattern for event distribution
   - Resource attributes and instrumentation scope

2. **Span Hierarchy**
   - Root: SERVER span per request
   - Steps: INTERNAL spans for each step execution
   - Effects: CLIENT spans for I/O operations
   - Jobs: INTERNAL spans for effect_job and step_job

3. **Event Tracking**
   - All job lifecycle stages recorded as events
   - Events attached to both job spans and parent spans (mirrored)
   - Rich metadata: queue name, worker_index, job_ctx, sequences

4. **Attributes**
   - HTTP request/response metadata
   - Step/effect sequencing and timing
   - Job execution context (queue, worker, success)
   - Error context propagation

### What's Missing/Wrong

1. **Job Span Behavior**
   - Currently: Job spans (`effect_job`, `step_job`) are **always created** as child spans
   - Target: Job lifecycle should be **events by default**, promoted to spans only when thresholds exceeded

2. **Timestamp Tracking**
   - Missing: Individual `park_ts[]` and `resume_ts[]` arrays for park episodes
   - Missing: `take_ts` (when job dequeued) vs `start_ts` (when work begins)
   - Current: Only `start_time_unix_ns` and `end_time_unix_ns` on job spans

3. **Derived Durations**
   - Missing calculation of:
     - `queue_wait_ms` (take - enqueue)
     - `dispatch_ms` (start - take)
     - `park_wait_ms_total` (sum of park episodes)
     - `run_active_ms` (total - park_wait)

4. **Threshold-Based Promotion**
   - No environment variable configuration (`ZER_VER_PROMOTE_QUEUE_MS`, etc.)
   - No logic to conditionally promote queue/park to spans
   - No route-level p95 tracking for dynamic thresholds

5. **Naming Conventions**
   - Root span: Currently `"{method} {path}"` → Should be `"http.server: {method} {route}"`
   - Effects: Generic → Should include operation type (e.g., `"db.get blog_post"`)
   - Continuations: Not distinguished → Need `"step.<name>.resume"`
   - Promoted spans: Missing `"job.queue_wait"` and `"job.park(<cause>)"` naming

6. **Semantic Conventions Alignment**
   - Old keys used: `http.method`, `http.status_code`
   - New required: `http.request.method`, `http.response.status_code`, `url.scheme`, `url.path`, etc.
   - Missing: `concurrency.limit.*`, `job.park.cause`, `render.*` attributes

7. **Parking/Concurrency Tracking**
   - No park/resume event distinction
   - No concurrency limit tracking
   - No cause attribution for parking (io_wait, rate_limit, backpressure, etc.)

8. **Status Code Strategy**
   - Current: Status set to ERROR for 500s or failures
   - Target: Status should remain UNSET/OK for application-level errors; ERROR reserved for telemetry/system failures

9. **Rendering Attributes**
   - Missing phase tracking (markdown, template, json_encode)
   - Missing size_bytes for rendered content

---

## Revision Tasks

### Phase 1: Configuration & Infrastructure

**1.1 Add Configuration Module**
- [ ] Create `src/zerver/observability/otel_config.zig`
- [ ] Parse environment variables:
  - `ZER_VER_PROMOTE_QUEUE_MS` (default: 5)
  - `ZER_VER_PROMOTE_PARK_MS` (default: 5)
  - `ZER_VER_DEBUG_JOBS` (default: 0)
  - `ZER_VER_QUEUE_NAME_EFFECTS` (default: "effects")
  - `ZER_VER_QUEUE_NAME_CONT` (default: "continuations")
  - `ZER_VER_EXPORT_JOB_DEPTH` (default: 0)
  - `ZER_VER_SAMPLER` (e.g., "head:0.02,tail:error|p99")
  - `ZER_VER_METRICS_VIEW_ROUTE_P95_WINDOW`
- [ ] Expose config struct to `OtelExporter.init()`

**1.2 Enhance RequestRecord with Job Lifecycle State**
- [ ] Add fields to track timestamps:
  ```zig
  enqueue_ts: ?i64 = null,
  take_ts: ?i64 = null,
  start_ts: ?i64 = null,
  end_ts: ?i64 = null,
  park_episodes: std.ArrayList(ParkEpisode),
  ```
- [ ] Define `ParkEpisode`:
  ```zig
  const ParkEpisode = struct {
      cause: []const u8, // io_wait|rate_limit|backpressure|lock|timer|other
      token: ?u32,
      park_ts: i64,
      resume_ts: ?i64,
      concurrency_limit_current: ?usize,
      concurrency_limit_max: ?usize,
  };
  ```
- [ ] Store per-effect and per-step-job

**1.3 Add Telemetry Events for Lifecycle Stages**
- [ ] Extend `telemetry.zig` events:
  - `EffectJobTaken` (when dequeued, before started)
  - `EffectJobParked` (with cause, token, limits)
  - `EffectJobResumed`
  - `StepJobTaken`
  - `StepJobParked`
  - `StepJobResumed`
- [ ] Update `Event` union and `RequestRecord.record*` methods

---

### Phase 2: Job Lifecycle Refactoring

**2.1 Default to Events (Not Spans)**
- [ ] Remove automatic span creation in:
  - `recordEffectJobEnqueued`
  - `recordStepJobEnqueued`
- [ ] Store lifecycle events as `RequestEvent` on parent span (effect or step)
- [ ] Track job state in a new map: `job_states: AutoHashMap(usize, JobState)`
  ```zig
  const JobState = struct {
      job_type: enum { effect, step },
      sequence: usize,
      enqueue_ts: i64,
      take_ts: ?i64,
      start_ts: ?i64,
      end_ts: ?i64,
      park_episodes: std.ArrayList(ParkEpisode),
      queue: []const u8,
      job_ctx: ?usize,
      worker_index: ?usize,
      success: ?bool,
  };
  ```

**2.2 Compute Derived Durations**
- [ ] On `recordEffectJobCompleted` / `recordStepJobCompleted`:
  - Calculate `queue_wait_ms = take_ts - enqueue_ts`
  - Calculate `dispatch_ms = start_ts - take_ts`
  - Calculate `park_wait_ms_total = sum(resume_ts[i] - park_ts[i])`
  - Calculate `run_active_ms = (end_ts - start_ts) - park_wait_ms_total`
- [ ] Add as attributes to logical span (effect/step) or events

**2.3 Implement Threshold-Based Promotion**
- [ ] On job completion, check:
  - `queue_wait_ms >= config.promote_queue_ms`
  - Any `park_wait_ms[i] >= config.promote_park_ms`
  - `config.debug_jobs == true`
- [ ] If triggered, create promoted child spans:
  - `job.queue_wait` (Kind=INTERNAL)
  - `job.park(<cause>)` (Kind=INTERNAL, one per episode)
- [ ] Attach lifecycle events to promoted spans
- [ ] Finalize derived attributes on promoted spans

---

### Phase 3: Naming & Semantic Conventions

**3.1 Update Root Span Naming**
- [ ] Change from `"{method} {path}"` to `"http.server: {method} {route}"`
- [ ] Extract route template from path (e.g., `/blogs/posts/{id}`)

**3.2 Update Step Span Naming**
- [ ] Keep `"step.{name}"` for forward steps
- [ ] Add `"step.{name}.resume"` for continuation resumption
- [ ] Set `Kind=INTERNAL` consistently

**3.3 Update Effect Span Naming**
- [ ] Include operation: `"db.get blog_post"`, `"http.get comments"`, `"cache.get author"`
- [ ] Extract from effect details (kind + target)
- [ ] Set `Kind=CLIENT`

**3.4 Adopt New Semantic Conventions**
- [ ] Rename attributes:
  - `http.method` → `http.request.method`
  - `http.status_code` → `http.response.status_code`
  - `http.host` → `server.address` (split port if present)
  - `http.user_agent` → `user_agent.original`
  - `http.client_ip` → `client.address`
- [ ] Add new attributes:
  - `url.scheme`, `url.path`, `server.port`, `client.port`
  - `network.transport`, `network.protocol.version`
  - `url.path.params.*` (path parameters)
- [ ] Keep old keys for one release (dual-emit)

**3.5 Add Job-Specific Attributes**
- [ ] On effect/step spans:
  - `job.queue_wait_ms`, `job.dispatch_ms`, `job.park_wait_ms_total`, `job.run_active_ms`, `job.park_count`
- [ ] On promoted `job.queue_wait` spans:
  - `job.queue`, `job.depth_start`, `job.depth_end`
- [ ] On promoted `job.park` spans:
  - `job.park.cause`, `job.park.token`, `concurrency.limit.current`, `concurrency.limit.max`

**3.6 Add Rendering Attributes**
- [ ] For rendering phases (if detected):
  - `render.phase` (markdown, template, json_encode, other)
  - `render.size_bytes`

---

### Phase 4: Status Code & Error Strategy

**4.1 Revise Status Setting Logic**
- [ ] Root span:
  - UNSET/OK for `status_code < 500` (even 4xx)
  - ERROR only for `status_code >= 500` or internal telemetry failures
- [ ] Step spans:
  - OK if decision=Continue/Done
  - ERROR only if `outcome="Fail"` AND system-level error (not application logic)
- [ ] Effect spans:
  - OK if `success=true`
  - ERROR if `required=true AND success=false` AND represents infrastructure failure
  - UNSET for non-required failures

**4.2 Error Context Propagation**
- [ ] Attach `error_type`, `error_message` attributes when available
- [ ] Distinguish application errors from system errors in `ErrorCtx`

---

### Phase 5: Event Refinement

**5.1 Standardize Event Names**
- [ ] Prefix all custom events with `zerver.`
- [ ] Align names:
  - `job.enqueued`, `job.taken`, `job.started`, `job.parked`, `job.resumed`, `job.completed`
  - `need.requested`, `need.join`
  - `slot.write`
  - `retry`

**5.2 Add New Events**
- [ ] `need.requested {effects:n, mode, join}` (on need schedule)
- [ ] `need.join {completed, failed, duration_ms}` (on need completion)
- [ ] `slot.write {slot, size_bytes}` (on slot writes)
- [ ] `retry {attempt, reason, backoff_ms}` (on effect retries)

---

### Phase 6: Parking & Concurrency

**6.1 Integrate with Job System**
- [ ] Emit `EffectJobParked` / `StepJobParked` events from job system when:
  - Waiting on I/O
  - Rate limit hit
  - Backpressure applied
  - Lock contention
  - Timer/sleep
- [ ] Include cause, token, concurrency limits in event
- [ ] Emit `EffectJobResumed` / `StepJobResumed` when work resumes

**6.2 Track Concurrency Limits**
- [ ] Query job system for current/max concurrency limits per queue
- [ ] Attach to park events and promoted park spans

---

### Phase 7: Sampling & Metrics (Optional)

**7.1 Head Sampling**
- [ ] Implement probabilistic sampling at root (1–5%)
- [ ] Skip export if sample decision is "drop"

**7.2 Tail Sampling**
- [ ] Collect triggers:
  - `status_code >= 500`
  - Duration ≥ route p95/p99
  - Required effect failures
  - Queue/park wait ≥ route p95
- [ ] Force export if any trigger matches

**7.3 Exemplar Linking**
- [ ] Attach `trace_id` to latency histogram exemplars (future work)

**7.4 Metrics Derivation**
- [ ] Document exporter-side metrics:
  - `http.server.duration_ms`, `zerver.step.duration_ms`, `zerver.effect.duration_ms`
  - `zerver.job.queue_wait_ms`, `zerver.job.dispatch_ms`, `zerver.job.park_wait_ms`, `zerver.job.run_active_ms`
  - `zerver.job.depth` (gauge)
  - `zerver.job.retries_total`
  - `cache.hit_ratio`

---

### Phase 8: Testing & Validation

**8.1 Golden Trace Tests**
- [ ] Create test cases:
  - Happy path 200 (no promotions)
  - 404 not found (status UNSET/OK, no DB write)
  - 500 error (status ERROR)
  - Queue-heavy run (queue_wait promoted)
  - Park-heavy run (park promoted)
  - Parallel effects with join=all
- [ ] Assert:
  - Span tree shape (parent/child relationships)
  - Required attributes present
  - Derived durations consistent with timestamps
  - Event sequence validity

**8.2 Load Testing**
- [ ] Run under load with `ZER_VER_DEBUG_JOBS=1` to verify span creation doesn't degrade performance
- [ ] Test with `ZER_VER_PROMOTE_QUEUE_MS=0` to force all promotions
- [ ] Verify OTLP export succeeds with large span batches

**8.3 Backwards Compatibility**
- [ ] Dual-emit old and new attribute keys for one release
- [ ] Document migration path in `CHANGELOG.md`

---

## Implementation Order

### Milestone 1: Job Lifecycle (Weeks 1-2)
1. Add configuration module (1.1)
2. Enhance RequestRecord with job state (1.2)
3. Add new telemetry events (1.3)
4. Refactor to event-first logic (2.1)
5. Compute derived durations (2.2)

### Milestone 2: Promotion Logic (Week 3)
1. Implement threshold checks (2.3)
2. Create promoted span logic (2.3)
3. Integrate with config (1.1)

### Milestone 3: Naming & Conventions (Week 4)
1. Update root span naming (3.1)
2. Update step/effect naming (3.2, 3.3)
3. Adopt new semantic conventions (3.4)
4. Add job-specific attributes (3.5)
5. Add rendering attributes (3.6)

### Milestone 4: Status & Events (Week 5)
1. Revise status logic (4.1, 4.2)
2. Standardize event names (5.1)
3. Add new events (5.2)

### Milestone 5: Parking & Concurrency (Week 6)
1. Integrate with job system (6.1)
2. Track concurrency limits (6.2)

### Milestone 6: Testing & Validation (Week 7)
1. Golden trace tests (8.1)
2. Load testing (8.2)
3. Backwards compatibility (8.3)

### Milestone 7: Sampling & Metrics (Optional, Week 8+)
1. Head sampling (7.1)
2. Tail sampling (7.2)
3. Exemplar linking (7.3)
4. Metrics derivation (7.4)

---

## Key Design Decisions

### 1. **Event-First, Span-on-Threshold**
- **Rationale**: Keeps default traces compact; deep visibility only when latency indicates issues
- **Trade-off**: Adds complexity to promotion logic but dramatically reduces span count

### 2. **Park Episodes as Array**
- **Rationale**: Jobs can park multiple times (I/O wait, then rate limit, etc.)
- **Trade-off**: Requires dynamic allocation but captures full concurrency story

### 3. **Dual-Emit for Migration**
- **Rationale**: Allows downstream consumers to migrate gradually
- **Trade-off**: Temporary attribute bloat, removed in next major version

### 4. **Status=UNSET for Application Errors**
- **Rationale**: Aligns with OTEL philosophy (status is for telemetry health, not app logic)
- **Trade-off**: May confuse users expecting ERROR for 404/400; document clearly

### 5. **Route-Level p95 Thresholds (Future)**
- **Rationale**: Static thresholds don't adapt to varying route latencies
- **Trade-off**: Requires aggregation infra; defer to Phase 7 or later

---

## Risk Mitigation

1. **Breaking Changes**: Dual-emit old keys for one release; document migration
2. **Performance Regression**: Profile promotion logic; ensure O(1) threshold checks
3. **Memory Leaks**: Carefully manage `ParkEpisode` allocations; use arena for temp data
4. **Job System Integration**: Coordinate with reactor team on park/resume event emission
5. **Testing Gaps**: Require golden traces before merging any naming/convention changes

---

## Success Criteria

- [ ] Job lifecycle fully captured with enqueue/take/start/park/resume/complete timestamps
- [ ] Derived durations (queue_wait, dispatch, park_wait, run_active) computed correctly
- [ ] Promotion logic triggered by thresholds; `ZER_VER_DEBUG_JOBS=1` forces promotion
- [ ] Span naming matches spec: `http.server: GET /path`, `db.get table`, `step.name.resume`
- [ ] New semantic conventions adopted; old keys dual-emitted
- [ ] Status codes set per policy (UNSET for app errors, ERROR for system failures)
- [ ] Golden trace tests pass; load tests show no perf degradation
- [ ] Backwards compatibility verified

---

## Next Steps

1. **Review with team**: Validate approach, especially job system integration points
2. **Prototype Milestone 1**: Build config + job state tracking in isolation
3. **Integration testing**: Coordinate with reactor team for park/resume events
4. **Iterate on naming**: Confirm naming conventions with OTEL community best practices
5. **Document**: Update `API_REFERENCE.md` and `OTEL_improvement.md` with final design

---

## References

- `docs/OTEL_improvement.md` (requirements)
- `src/zerver/observability/otel.zig` (current implementation)
- `src/zerver/observability/telemetry.zig` (event definitions)
- `src/zerver/runtime/reactor/job_system.zig` (job lifecycle)
- OpenTelemetry Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
