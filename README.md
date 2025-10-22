# Zerver

**Zerver is a backend framework for Zig that gives you X-ray vision into your API. It's built on the idea that observability isn't a feature you add later—it's the architecture.**

---

## The Problem: "Why is this endpoint slow?"

Every production incident starts with a question you can't easily answer. Consider a standard checkout endpoint in a traditional framework:

```javascript
// Express.js, Gin, Actix... they all look similar
app.post('/checkout', async (req, res) => {
    const user = await auth.verify(req);        // How long did this take?
    const cart = await db.getCart(user.id);     // Was this cached?
    const payment = await stripe.charge(cart);  // Did this retry?
    const order = await db.createOrder(cart);   // Did this deadlock?
    await email.sendReceipt(order);             // Did this fail silently?
    res.json({ order });
});
```

When it's slow, you're flying blind. You have to litter your code with `console.log` statements, manually configure distributed tracing, and spend hours correlating logs across services just to guess what happened.

## The Zerver Solution: A Framework That Tells You What Happened

In Zerver, you define your logic as a series of pure, composable steps. The framework orchestrates them and performs I/O on your behalf.

```zig
// Define the flow as a series of steps
const checkout_flow = &.{
    auth.verify,      // Pure step
    cart.load,        // Requests a DB effect
    payment.charge,   // Requests a Stripe API effect
    order.create,     // Requests a DB effect
    email.send,       // Requests an email effect (optional)
    render.success,   // Pure step to build the response
};
```

When that flow runs, Zerver produces a detailed trace **automatically**. No instrumentation required.

```
Request: POST /checkout [req_7a8f3c2b]
Timeline:
  0.0ms  auth.verify        ✓ 0.15ms  (cpu)
  0.2ms  cart.load          → dbGet(cart:u_123)
  2.8ms  cart.load          ✓ 2.6ms   (io: postgres)
  2.8ms  payment.charge     → httpPost(stripe.com/charges)
  45ms   payment.charge     ⚠ retry 1/1 (timeout)
  89ms   payment.charge     ✓ 86.2ms  (io: stripe, total: 44+86=130ms)
  89ms   order.create       → dbPut(order:o_456)
  95ms   order.create       ✓ 6ms     (io: postgres)
  95ms   email.send         → httpPost(sendgrid.com) [optional]
  96ms   render.success     ✓ 0.1ms   (cpu)

🔴 SLOW: payment.charge took 130ms (timeout + retry)
   └─ Stripe latency P99: 45ms → 89ms (2x normal)
```

You immediately know the root cause: Stripe timed out and retried. The problem isn't your code; it's a downstream service.

---

## Core Principles

Zerver is built on a few key ideas that enable this level of insight and safety.

### 1. Explicit is Better Than Implicit

Business logic is defined in **pure steps**. These steps don't perform I/O directly. Instead, they return a `Decision` that tells the framework what to do next. To perform I/O, a step returns a `.Need` decision, requesting one or more **Effects**.

```zig
const LoadView = zerver.CtxView(.{ .reads = .{ .TodoId }, .writes = .{ .TodoItem } });

fn db_load_by_id(ctx: *LoadView) !zerver.Decision {
    const id = try ctx.require(.TodoId);
    return .Need(.{
        .effects = &.{
            zerver.Effect.dbGet(.{
                .key = ctx.bufFmt("todo:{s}", .{id}),
                .token = .TodoItem, // Write result to this slot
                .required = true,
            }),
        },
        // After the effect, call this function
        .resume = db_loaded,
    });
}

fn db_loaded(ctx: *LoadView) !zerver.Decision {
    // We can now safely access the result of the effect
    _ = try ctx.require(.TodoItem);
    return .Continue;
}
```

This makes control flow visible and testable. There's no hidden `await` or callback hell.

### 2. Compile-Time Confidence

Zerver uses Zig's compile-time features to prevent entire classes of runtime bugs. Per-request state is stored in typed **Slots**. Each step declares which slots it reads from and writes to using a `CtxView`.

If you try to read a slot that hasn't been written yet, or if two steps try to write to the same slot, **your code won't compile**.

```zig
// This step declares it reads .TodoItem
const ValidateUpdateView = zerver.CtxView(.{ .reads = .{ .TodoItem }, .writes = .{ .TodoItem } });
fn validate_update(ctx: *ValidateUpdateView) !zerver.Decision {
    // If no previous step wrote to .TodoItem, this is a compile error.
    var t = try ctx.require(.TodoItem);
    // ...
    return .Continue;
}
```

This prevents null pointer exceptions, race conditions, and state management bugs before your code ever runs.

### 3. Composable and Reusable Logic

Steps are like Lego bricks. You can assemble them into chains and pipelines to build complex features. A platform team can provide a standard, audited `auth_chain`, and product teams can use it with confidence.

```zig
// Platform team defines and owns the auth logic
const auth_chain = &.{ MW_AUTH_PARSE, MW_AUTH_LOOKUP, MW_AUTH_VERIFY };

// Product team uses it for a protected route
try srv.addRoute(.POST, "/todos", .{
    .before = auth_chain, // Apply auth middleware
    .steps = &.{
        STEP_VALIDATE_CREATE,
        STEP_DB_PUT_NOTIFY,
        STEP_RENDER_CREATED,
    },
});
```

This promotes consistency, reduces boilerplate, and makes it easy to enforce security and business rules across an entire organization.

---

## Architecture in a Nutshell

Zerver is designed as a **job scheduler with an HTTP frontend**.

1.  **HTTP requests** are classified and submitted to a **priority queue** (e.g., `Interactive`, `Batch`).
2.  A pool of **worker threads** picks up jobs from these queues.
3.  Workers execute **pure steps** within a small time budget.
4.  When a step requests I/O (`.Need`), the request is handed off to a non-blocking **I/O reactor** (e.g., `io_uring`). The worker is freed to work on another job.
5.  When I/O completes, a **continuation job** is enqueued to resume the flow.

This architecture is designed for high throughput and excellent tail latency, ensuring that slow batch jobs can't block critical interactive requests.

## Project Status: MVP Implementation Complete ✅

Zerver is now in **active development** with a working MVP. The core concepts, API surface, and architectural roadmap are implemented. The synchronous MVP proves the developer experience and debugging benefits.

Phase-2 will introduce the non-blocking I/O reactor and priority scheduler. The MVP API is fully compatible with Phase-2 enhancements.

We welcome discussion, feedback, and contributions on the design. Please review the documentation in `docs/` and open an issue to share your thoughts.
