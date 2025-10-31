# OpenTelemetry Conventions in Zerver

This document describes the OpenTelemetry (OTEL) semantic conventions and span hierarchy used by Zerver's observability system.

## Span Hierarchy

Zerver creates a hierarchical span structure for each request:

```
server (root span)
├── internal (step spans)
│   ├── client (effect spans)
│   │   └── internal (job spans - promoted on threshold)
│   └── client (effect spans)
└── internal (step spans)
```

### Span Types and Naming

| Span Type | Naming Convention | OTEL Kind | Purpose |
|-----------|-------------------|-----------|---------|
| Root | `GET /path` or `POST /path` | `server` | HTTP request lifecycle |
| Step | `zerver.step.{name}` | `internal` | Step execution (load_posts, render_list, etc.) |
| Effect | `zerver.effect.{kind}` | `client` | External operations (db_get, http_post, etc.) |
| Job | `zerver.job.effect` or `zerver.job.step` | `internal` | Async work queue execution |

## Threshold-Based Span Promotion

Job spans are only created when execution latency exceeds configured thresholds:

- **Queue Wait Threshold**: `ZER_VER_PROMOTE_QUEUE_MS` (default: 5ms)
- **Park Wait Threshold**: `ZER_VER_PROMOTE_PARK_MS` (default: 5ms)

If queue_wait < 5ms AND park_wait < 5ms, job lifecycle is recorded as events on the parent span instead of creating separate child spans.

## Root Span Attributes (server)

Following OTEL HTTP semantic conventions:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `http.method` | string | `GET` | HTTP request method |
| `http.target` | string | `/blog/posts/123` | Request path |
| `http.scheme` | string | `http` | Protocol scheme |
| `http.flavor` | string | `1.1` | HTTP protocol version |
| `http.status_code` | int | `200` | Response status code |
| `http.user_agent` | string | `curl/8.9.1` | Client user agent |
| `net.host.name` | string | `127.0.0.1` | Server host |
| `net.host.port` | int | `8080` | Server port |
| `net.peer.ip` | string | `127.0.0.1` | Client IP address |
| `http.request_content_length` | int | `1024` | Request body size |
| `http.response_content_length` | int | `2048` | Response body size |
| `zerver.request_id` | string | `abc123...` | Unique request identifier |
| `zerver.correlation_id` | string | `def456...` | Correlation ID from header or generated |
| `error.type` | string | `client_error` | Error category (4xx/5xx) |

## Step Span Attributes (internal)

Attributes for step execution spans:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `step.name` | string | `load_posts` | Step function name |
| `step.layer` | string | `main` | Step layer (global_before, route_before, main) |
| `step.sequence` | int | `3` | Execution sequence number |
| `step.outcome` | string | `Continue` | Decision type (Continue, need, Done, Fail) |
| `step.duration_ms` | int | `12` | Step execution time |

## Effect Span Attributes (client)

### Core Attributes (all effects)

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `effect.sequence` | int | `5` | Effect execution order |
| `effect.need_sequence` | int | `2` | Parent Need sequence |
| `effect.kind` | string | `db_get` | Effect type |
| `effect.token` | int | `42` | Slot identifier |
| `effect.required` | bool | `true` | Whether effect is required |
| `effect.target` | string | `posts/123` | Target (URL/key/path) |
| `effect.mode` | string | `Parallel` | Execution mode |
| `effect.join` | string | `all` | Join strategy |
| `effect.timeout_ms` | int | `5000` | Effect timeout |
| `effect.success` | bool | `true` | Whether effect succeeded |
| `effect.duration_ms` | int | `8` | Effect execution time |
| `effect.bytes` | int | `512` | Response size |

### HTTP Effect Semantic Attributes

Following OTEL HTTP semantic conventions:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `http.url` | string | `https://api.example.com/users` | Full URL |
| `http.method` | string | `GET` | HTTP method (extracted from effect.kind) |

Example effect.kind values: `http_get`, `http_post`, `http_put`, `http_delete`, `http_patch`

### TCP Effect Semantic Attributes

Following OTEL network semantic conventions:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `network.transport` | string | `tcp` | Transport protocol |
| `network.operation` | string | `connect` | Operation type (extracted from effect.kind) |
| `network.peer.address` | string | `api.example.com:8080` | Peer host and port |

Example effect.kind values: `tcp_connect`, `tcp_send`, `tcp_receive`, `tcp_send_receive`, `tcp_close`

### gRPC Effect Semantic Attributes

Following OTEL RPC semantic conventions:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `rpc.system` | string | `grpc` | RPC system name |
| `rpc.service` | string | `helloworld.Greeter` | gRPC service name |
| `rpc.method` | string | `unary_call` | Call type (extracted from effect.kind) |

Example effect.kind values: `grpc_unary_call`, `grpc_server_stream`

### WebSocket Effect Semantic Attributes

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `network.protocol.name` | string | `websocket` | Protocol name |
| `websocket.operation` | string | `connect` | Operation type |
| `websocket.url` | string | `wss://api.example.com/ws` | WebSocket URL |

Example effect.kind values: `websocket_connect`, `websocket_send`, `websocket_receive`

### Database Effect Semantic Attributes

Following OTEL database semantic conventions:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `db.system` | string | `zerver` | Database system name |
| `db.operation` | string | `get` | Operation type (extracted from effect.kind) |
| `db.statement` | string | `posts/123` | Key or prefix being accessed |

Example effect.kind values: `db_get`, `db_put`, `db_del`, `db_scan`

### Cache Effect Semantic Attributes

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `cache.system` | string | `kv` | Cache system type |
| `cache.operation` | string | `get` | Operation type |
| `cache.key` | string | `session:abc123` | Cache key |

Example effect.kind values: `kv_cache_get`, `kv_cache_set`, `kv_cache_delete`

### File I/O Effect Semantic Attributes

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `file.path` | string | `/data/config.json` | File path |
| `file.operation` | string | `json_read` | File operation type |

Example effect.kind values: `file_json_read`, `file_json_write`

### Compute Effect Semantic Attributes

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `compute.operation` | string | `ml_inference` | Compute operation name |

Example effect.kind values: `compute_task`, `accelerator_task`

## Job Span Attributes (internal)

Attributes for async job execution spans (promoted on threshold):

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `job.sequence` | int | `5` | Parent effect/step sequence |
| `job.kind` | string | `effect` | Job type (effect or step) |
| `job.queue` | string | `io_pool` | Target queue name |
| `job.enqueued_at_ms` | int | `1234567890` | Enqueue timestamp |
| `job.started_at_ms` | int | `1234567895` | Start timestamp |
| `job.queue_wait_ms` | int | `8` | Time waiting in queue |
| `job.park_wait_ms` | int | `3` | Time parked for I/O |
| `job.run_duration_ms` | int | `12` | Pure execution time |
| `job.promoted` | bool | `true` | Whether span was promoted |

## Span Status and Error Handling

### Status Values

- `ok`: Successful execution
- `error`: Failure occurred

### Error Attributes

When errors occur, additional attributes are added:

| Attribute | Type | Example | Description |
|-----------|------|---------|-------------|
| `error.type` | string | `client_error` | Error category |
| `zerver.error.what` | string | `post` | Error domain |
| `zerver.error.key` | string | `not_found` | Specific error identifier |

## Event-First Telemetry Model

For fast requests, Zerver uses an event-first model to minimize overhead:

1. **Default**: Record job lifecycle as events on parent span
2. **Promotion**: Create child job span only when thresholds exceeded

### Event Names

- `zerver.need_scheduled`: Need decision scheduled for execution
- `zerver.effect_job_enqueued`: Effect job added to queue
- `zerver.effect_job_started`: Effect job execution started
- `zerver.effect_job_completed`: Effect job finished
- `zerver.step_job_enqueued`: Step job added to queue
- `zerver.step_job_started`: Step job execution started
- `zerver.step_job_completed`: Step job finished
- `zerver.step_resume`: Step resumed after effects
- `zerver.executor_crash`: Executor encountered error
- `zerver.compute_budget_registered`: Compute task budget allocated
- `zerver.compute_budget_exceeded`: Task exceeded CPU budget
- `zerver.compute_budget_yield`: Task cooperatively yielded

### Compute Budget Events

Compute budget events track CPU time consumption for compute-bound tasks:

| Event | Attributes | Description |
|-------|-----------|-------------|
| `compute_budget_registered` | token, allocated_ms, priority, yield_interval_ms | Budget allocated when task registered |
| `compute_budget_exceeded` | token, allocated_ms, used_ms, action (park/reject) | Task exceeded budget, parked or rejected |
| `compute_budget_yield` | token, elapsed_ms, yield_interval_ms | Task cooperatively yielded to other tasks |

## Configuration

Observability can be configured via environment variables:

```bash
# Enable/disable OTEL exporter
export ZER_VER_OTEL_ENABLED=true

# OTLP endpoint
export ZER_VER_OTEL_ENDPOINT=http://localhost:4318/v1/traces

# Promotion thresholds (milliseconds)
export ZER_VER_PROMOTE_QUEUE_MS=5
export ZER_VER_PROMOTE_PARK_MS=5

# Debug mode (promotes all jobs)
export ZER_VER_DEBUG_JOBS=true

# Compute budget configuration
export ZER_VER_MAX_REQUEST_CPU_MS=2000  # Max CPU time per request
export ZER_VER_MAX_TASK_CPU_MS=500      # Max CPU time per task
export ZER_VER_ENFORCE_BUDGETS=true     # Enable budget enforcement
export ZER_VER_PARK_ON_EXCEEDED=true    # Park tasks that exceed budgets
```

## Best Practices

### Querying Traces

1. **Find slow requests**: Filter by `http.status_code` and `span.duration`
2. **Database bottlenecks**: Query `db.operation` and `db.statement`
3. **HTTP dependencies**: Filter by `http.url` and `http.method`
4. **Job queue analysis**: Look for promoted job spans with high `job.queue_wait_ms`

### Performance Impact

- Event-first model: ~1-2µs overhead per effect
- Promoted span: ~10-15µs overhead per job
- Root span: ~5-10µs overhead per request

## Future Enhancements

Planned improvements (see `docs/wants.md`):

- Adaptive promotion thresholds based on p95/p99 latency
- Tail sampling for expensive traces
- Exemplar links between metrics and traces
- Queue depth and worker pool metrics
- Concurrency limit signals
- Automatic SLO breach detection

## References

- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [OTEL HTTP Conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/)
- [OTEL Database Conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/)
- Zerver architecture: `docs/architecture.md`
- Observability wants: `docs/wants.md` (lines 35-57)
