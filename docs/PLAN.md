Here’s the compact “single-page” of everything we’ve shaped:

# Architecture (core)

* **Pure vs Impure split:** Pure steps decide *what to do* (effects). An impure interpreter executes I/O, timers, randomness, then feeds results back to the pure steps.
* **Request = State Machine (or tiny DAG):** Explicit stages with fan-out/fan-in, join counters, deadlines, and clear “hard/soft” error semantics.
* **Jobs + Priority Queues:** Steps run as short, cooperative jobs with small time budgets; bounded, multi-class queues (Interactive/Default/Batch), work-stealing, and aging for fairness.
* **Latency hiding:** I/O never blocks workers. Use proactor/reactor (io_uring/epoll/overlapped) to park and resume via continuations; workers only do CPU work.
* **Ownership model:** Each step “owns” exactly one slot in the request context → no locks on the hot path.
* **Backpressure:** Per-request caps (parallel steps, in-flight I/O) + bounded queues; reject/degrade early under load.

# Execution model

* **Decisions:** Pure steps return `{Need[..effects] | Continue | Insert[..] | Replace[..] | Done | Fail}`.
* **Auto-yield:** Any `Need` posts effects, marks Waiting, and returns the worker; completion events re-enqueue the next pure step.
* **Deadlines & cancel:** Deadline in context; interpreter drops late completions; scheduler renders error path.

# Pipelines & ergonomics

* **Pipeline via middleware + router:** Keep orchestration simple; heavy lifting goes to the job system.
* **Cooperative “step” jobs or fibers:** Time-boxed chunks for CPU work; resumable without async/await sprawl.
* **Observability:** Per-step queueed/exec/io-wait times, yield counts, retries; per-request in-flight I/O and priority; queue depths and drops.

# URL & flow expression (multiple styles)

**C) English phrase as ID (readable slugs)**

* Use **canonical slugs**: `…/flow/v1/user-checkout-from-main-page`.
* Backed by a **registry**: `slug → plan/template/version/options/owner`.
* Support aliases (308→canonical), versioned tables (`/v1`, `/v2`), and tenant/region via headers (not in the slug).
* For privacy or control: resolve phrases → redirect to canonical plan/continuation.

# Safety & policy

* **Allowlist steps & options:** Central registry; capability checks per tenant.
* **Idempotency keys:** Required for write effects; retries are safe.
* **Governance:** Ownership, deprecation headers, successor links; linter for slug quality.

# Performance & tuning

* **Time budgets:** ~2–5 ms (interactive), ~10–20 ms (batch); measure p95/p99 and adjust.
* **Streaming:** Prefer streaming writers (and gzip) to avoid big buffers.
* **Memory:** Per-request arenas; zero-copy views for headers/body.

# When it shines

* Mixed CPU + I/O endpoints with strict tail-latency goals.
* Complex flows needing explicit ordering, retries, and auditability.
* Teams that want **readable URLs**, but with **server-owned control**.

# TL;DR

Design the server around **pure planners** and an **impure interpreter**, schedule work as **short, cooperative jobs** over **priority queues**, hide I/O latency with a **proactor/reactor**, and let the **server mint human-readable, canonical slugs (or continuations)** that reflect its internal state—*not* the other way around.
