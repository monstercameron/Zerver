Awesome—here’s a clean, implementation-ready **Out-Of-Process (OOP) Plugin Specification** for Zerver. It defines transport, handshake, registration, request execution, effects, tracing, hot-swap, quotas, and failure semantics. It’s opinionated but pragmatic so you can ship a first version and evolve.

---

# Zerver OOP Plugin Spec v1

## 0) Goals

* Crash-safe team plugins in separate OS processes.
* Atomic route/flow registration and hot-swap.
* Deterministic, traceable step/effect execution.
* Minimal overhead: **batched effects**, **shared memory** for large payloads.
* Language-agnostic (any language that can speak the protocol).

---

## 1) Transport & Framing

### 1.1 Transport

* **Linux/macOS**: Unix domain sockets (`AF_UNIX`, `SOCK_STREAM`).
* **Windows**: Named pipes (`\\.\pipe\zerver-plugins\<team>\<version>`).
* One socket/pipe per plugin process (multiplex all requests).
* Optional **shared memory** region per plugin for large payloads (see 6.3).

### 1.2 Framing

* **Length-prefixed binary frames**: `u32 length (BE) | bytes[length]`.
* **Encoding**: **CBOR** (RFC 7049) for compactness & schema evolution.

  * Alt (dev mode): JSON accepted when `protocol.debug_json = true` in handshake.

---

## 2) Process Lifecycle

### 2.1 Launch

* Host spawns plugin with environment:

  * `ZERVER_PLUGIN_SOCKET_PATH` or `ZERVER_PLUGIN_PIPE_NAME`
  * `ZERVER_PLUGIN_TEAM`, `ZERVER_PLUGIN_NAME`, `ZERVER_PLUGIN_VERSION`
  * `ZERVER_PROTOCOL_MAJOR=1`, `ZERVER_PROTOCOL_MINOR=x`
  * Optional: `ZERVER_SHM_FD` (Linux) or name (Windows)
* Plugin must connect within **3s**; otherwise host aborts.

### 2.2 Handshake (synchronous)

1. **Host → Plugin** `Hello`
2. **Plugin → Host** `HelloAck`
3. **Plugin → Host** `Register` (one or more)
4. **Host → Plugin** `RegisterAck` (for each)
5. **Host → Plugin** `CommitRoutes` → atomic activation
6. **Host → Plugin** `Ready`

### 2.3 Shutdown / Hot-swap

* New version connects, registers, and **commits**.
* Host flips route table (RCU). Old version marked **draining**.
* When in-flight requests for old version = 0 or grace timeout (config), host sends `Shutdown{reason}`; plugin exits; host reaps.

### 2.4 Health

* Host sends `Ping{id}` every **10s**; plugin replies `Pong{id}` in **1s**.
* Miss 3 pings → mark **unhealthy**, stop routing, attempt graceful shutdown and restart.

---

## 3) Messages (CBOR)

Define a **type** field for each message. Below are the primary schemas (expressed informally; all fields are lower_snake_case).

### 3.1 Handshake

**Hello (host→plugin)**

```cbor
{
  "type": "hello",
  "protocol": { "major": 1, "minor": 0 },
  "capabilities": ["routes.v1", "effects.db.v1", "effects.http.v1", "trace.v1", "shm.v1?"],
  "limits": {
    "max_routes": 1000,
    "max_effects_per_need": 32,
    "max_concurrent_effects_per_req": 16,
    "max_req_arena_bytes": 1_048_576
  },
  "ownership": { "/t/checkout/*": "checkout" },
  "debug_json": false
}
```

**HelloAck (plugin→host)**

```cbor
{
  "type": "hello_ack",
  "plugin": { "team": "checkout", "name": "checkout-core", "version": "1.5.0" },
  "requires": ["routes.v1", "effects.db.v1", "effects.http.v1", "trace.v1"],
  "optional": ["shm.v1"],
  "env": { "build": "sha256:...", "git": "abcd123" }
}
```

### 3.2 Registration

**Register (plugin→host)**

```cbor
{
  "type": "register",
  "kind": "route" | "flow",
  "spec": {
    "method": "GET" | "POST" | ... ,                       // for routes
    "path": "/t/checkout/orders/:id/report",               // for routes
    "slug": "order-report",                                 // for flows
    "before": [ StepRef, ... ],
    "steps":  [ StepRef, ... ],
    "meta": { "priority": "interactive" | "batch", "tags": ["checkout"] }
  }
}
```

**StepRef**

```cbor
{ "name": "step_build_report", "reads": ["Order", "User", "Team"], "writes": ["Report"] }
```

**RegisterAck (host→plugin)**

```cbor
{ "type": "register_ack", "ok": true, "reason": null }
// or { "ok": false, "reason": "conflict: /orders/* owned by inventory" }
```

**CommitRoutes (host→plugin)**

```cbor
{ "type": "commit_routes", "transaction_id": "txn_abc123" }
```

**Ready (host→plugin)**

```cbor
{ "type": "ready" }
```

---

## 4) Request Execution

### 4.1 Dispatch

**InvokeStep (host→plugin)** — host calls into the plugin to execute a step.

```cbor
{
  "type": "invoke_step",
  "req": {
    "id": "req_7a8f3c2b",
    "method": "GET",
    "path": "/t/checkout/orders/42/report",
    "headers": [["authorization","Bearer ..."], ...],
    "params":  { "id": "42" },
    "query":   { "notify": "1" },
    "deadline_ms": 250,                   // relative budget for this step
    "trace_id": "tr_123", "span_id": "sp_456"
  },
  "step": {
    "name": "step_build_report",
    "reads":  ["Order","User","Team"],    // compile-time in-proc; here informational
    "writes": ["Report"]
  },
  "slots": [
    // serialized slot values present before this step
    { "slot": "Order", "format": "cbor", "data": <bytes> },
    { "slot": "User",  "format": "cbor", "data": <bytes> },
    { "slot": "Team",  "format": "cbor", "data": <bytes> } // can be null
  ]
}
```

### 4.2 Step Result

**StepResult (plugin→host)**

```cbor
{
  "type": "step_result",
  "req_id": "req_7a8f3c2b",
  "step": "step_build_report",
  "decision": {
    "kind": "continue" |
            "done"     |
            "fail"     |
            "need"     |
            "run"
  },

  // when kind == "continue": may include slot writes produced by this step
  "writes": [
    { "slot": "Report", "format": "cbor", "data": <bytes> }
  ],

  // when kind == "done"
  "response": {
    "status": 200,
    "headers": [["content-type","application/json"]],
    "body": { "format": "bytes" | "shm", "data": <bytes>|{"offset":u64,"len":u32} }
  },

  // when kind == "fail"
  "error": {
    "kind": 404,
    "ctx": { "what": "order", "key": "42" }
  },

  // when kind == "need"
  "need": {
    "mode":   "parallel" | "sequential",
    "join":   "all" | "all_required" | "any" | "first_success",
    "resume": { "name": "after_build" },
    "effects": [
      // Effect items; each must specify a token slot to write on completion
      { "type":"db_get", "token":"Order", "key":"order:42", "timeout_ms":300, "retry":1, "required":true },
      { "type":"http_post", "token":"Notified", "url":"https://hooks.example.com/report",
        "headers":[["content-type","application/json"]],
        "body": { "format": "bytes" | "shm", "data": ... },
        "timeout_ms":500, "retry":0, "required":false }
    ]
  },

  // when kind == "run"
  "run": {
    "steps": [ StepRef, ... ],
    "resume": { "name": "resume_after_subchain" }
  }
}
```

> **Contract:** Plugin must **not** block on its own network/DB; it should only return `need` and let **host** perform effects. (Keeps policy central and trace unified.)

---

## 5) Effects (Host-Executed)

Host executes **all I/O effects**. When they complete (respecting `mode/join`), host re-enters plugin with the given **continuation** step.

### 5.1 Effect Result Delivery

**EffectResults (host→plugin)** — prior to resuming continuation

```cbor
{
  "type": "effect_results",
  "req_id": "req_7a8f3c2b",
  "resume": { "name": "after_build" },
  "results": [
    { "token":"Order", "ok":true,  "format":"cbor", "data":<bytes> },
    { "token":"Notified", "ok":false, "error":{ "kind":502, "ctx":{ "what":"webhook", "key":"" } } }
  ]
}
```

Host then issues a fresh `invoke_step` for the continuation step (the **continuation is just another step**; the plugin can treat continuation like a normal step that expects certain slots now present).

---

## 6) Performance Features

### 6.1 Batching

* **One `need` → many effects** issued at once; **one IPC roundtrip**.
* **Join semantics** applied by host; continuation scheduled upon join condition met.

### 6.2 Keep-alive & Pipelining

* The socket is long-lived; host may have multiple in-flight requests; messages are **correlated** via `req_id`.
* Plugin must be re-entrant and able to process concurrent `invoke_step` frames.

### 6.3 Shared Memory (optional)

* Host creates a shared memory region per plugin:

  * **Linux**: `memfd_create` + `mmap` (RO in plugin when host writes, RW when plugin writes via “outbox” region).
  * **Windows**: `CreateFileMapping` + `MapViewOfFile`.
* Large payloads (HTTP bodies, JSON, blobs) are passed as `{ "format":"shm", "offset":u64, "len":u32 }`.
* Plugin must treat SHM slices as **read-only** unless within its outbox window (for StepResult body or slot writes meant to be large). Host reclaims offsets.

---

## 7) Tracing & Logging

### 7.1 Inline Trace Events (optional)

Plugin can emit trace events that the host will stitch into the request timeline:

**Trace (plugin→host)**

```cbor
{
  "type":"trace",
  "req_id":"req_7a8f3c2b",
  "events":[
    { "ts_ns": 1234567890, "name":"validate json", "kind":"step_local", "attrs": { "len": 228 } }
  ]
}
```

### 7.2 Auto Trace

Host automatically spans:

* step start/end
* effect start/end (with retries/timeouts)
* resume invocations
* subchain execution

---

## 8) Quotas & Limits (enforced by host)

* **Per plugin** (configurable defaults):

  * `max_routes`, `max_flows`
  * `max_effects_per_need`, `max_concurrent_effects_per_req`
  * `max_req_arena_bytes`
  * `max_cpu_ms_per_req` (via cgroup in OOP)
  * `max_shm_bytes_per_req`
* **On violation**: host fails the request with `429 QuotaExceeded` and logs `quota_violation{ plugin, limit, req_id }`.

---

## 9) Errors & Recovery

### 9.1 Protocol Errors

* Malformed CBOR, unknown message types → host logs `protocol_error` and **disconnects** plugin.
* Plugin crash → host marks plugin **dead**, stops routing, attempts restart; if rolling upgrade, route to previous version; else 503 on owned paths.

### 9.2 Step Errors

* Plugin `StepResult.fail` → host runs global `on_error` renderer (for that route/flow), includes plugin error context in trace.

### 9.3 Effect Failures

* Host maps upstream errors to Zerver errors (`timeout`, `unavailable`, `notfound`, etc.).
* For **optional** effects: slot remains unset, error recorded, continuation still runs.
* For **required** effects: request fails immediately (unless join mode delays failure).

---

## 10) Security

* **Sandboxing**:

  * Dedicated Unix user, `no_new_privs=1`, minimal file system view, seccomp profile (deny dangerous syscalls).
  * cgroup limits for CPU/memory/IO.
* **Network**:

  * Plugin must not open outbound sockets (policy). All I/O goes through host effects.
  * Enforce via seccomp/Windows sandboxing.
* **Filesystem**:

  * Read-only runtime (unless plugin explicitly allowed a config directory).
* **Secrets**:

  * No direct secret access; secrets only via host effects (e.g., `vault.get` in future).

---

## 11) Ownership & Registration Policy

* Host holds `ownership.yaml` (authoritative).
* On `register`, host validates that paths/slugs are within owned prefixes; conflicts rejected unless operator sets an **override with TTL**.
* All registrations are transactional: `register*` → `commit_routes` → atomic flip.

---

## 12) Versioning & Capabilities

* **Wire protocol**: `(major, minor)`; major must match; minor can be ≥ host’s minor (host ignores unknown fields).
* **Capabilities** discovered at handshake; **cap tables** (function groups) exposed via host internally—OOP uses message types instead.

---

## 13) Dev & DX

* **SDKs**: thin client libs for Zig, Rust, Go, Node:

  * Connection & framing (CBOR)
  * Step authoring helpers
  * Serialization of slots (derive/codec)
  * Test harness (feed `invoke_step`, check `StepResult`)
* **CLI**:

  * `zerver plugin run <path-to-plugin>` (dev)
  * `zerver plugin status` (list, health, routes)
  * `zerver plugin reload <team>` (roll to new version)
  * `zerver plugin logs <team>` (tail aggregated logs)

---

## 14) Minimal End-to-End Example

**Flow**: `/t/checkout/orders/:id/report`

1. Host receives HTTP request → finds route → enqueues step `params`.
2. Host sends `invoke_step` to plugin with current slots (`OrderId` empty).
3. Plugin returns `continue` and writes `OrderId="42"`, `AuthHeader="Bearer..."`.
4. Host invokes `load_both` → plugin returns `need{ effects=[db_get("order:42")->Order, http_get(profile)->User], join=all, resume="fanout_done" }`.
5. Host executes effects → sends `effect_results` → invokes `fanout_done`.
6. Plugin `continue` → `branch_team` → returns `need{ db_get("user_team:...")->Team, resume="team_done" }`.
7. Host resumes → plugin `continue` → `build_report` → writes `Report` → `maybe_notify` → `need{ http_post(...)->Notified (optional) }` with `join=all_required`.
8. Host completes → invokes `notify_done` → plugin `continue` → `render` → `done{ status=200, body=Report }`.
9. Host writes response. Trace is complete.

---

## 15) Compliance Rules (MUST/SHOULD)

* **MUST** respond to `hello` with `hello_ack` in 1s.
* **MUST** implement `register`, `commit_routes`, `invoke_step`, `step_result`.
* **MUST NOT** perform external network I/O directly (unless explicitly whitelisted).
* **MUST** be re-entrant; handle concurrent `invoke_step`.
* **MUST NOT** retain host pointers or SHM offsets beyond a single request.
* **SHOULD** batch effects; avoid tiny `need`s for micro-ops.
* **SHOULD** include rich error context (`what`, `key`) on `fail`.

---

## 16) Open Questions (for v1.1)

* Pluggable **auth chain** shared by multiple plugins (host-executed “before”).
* Durable timers / long pauses (beginning of a “durable mode”).
* Streaming bodies across IPC (backpressure).
* WASM lane parity (same protocol; different runtime).

---

### TL;DR

* Speak **CBOR over length-prefixed sockets/pipes**.
* Use **InvokeStep/StepResult** to drive steps; **Need** to request host-executed effects; **EffectResults** before continuation.
* **Batch**, **SHM**, and **RCU hot-swap** keep it fast and safe.
* **Ownership, quotas, sandboxing** make it enterprise-ready.

If you want, I can package this into a short **`.md` spec + `.proto`/CBOR map** and a **reference plugin** (in Zig or Rust) that handles handshake, registers one route, and echoes a `Need→resume→Done` loop so you can integration-test the host.
