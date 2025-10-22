# Zerver API Cheat Sheet

## Core Concepts

### Steps
Pure functions that return `Decision` (Continue/Need/Done/Fail)

```zig
fn myStep(ctx: *CtxView) !Decision {
    // Business logic here
    return .Continue;  // or .Need, .Done, .Fail
}
```

### Effects
Explicit I/O operations

```zig
return .Need(.{
    .effects = &.{ zerver.Effect.dbGet(.{ ... }) },
    .resume = nextStep,
});
```

### Slots
Typed per-request state

```zig
// Define slots
const Slots = enum { UserId, TodoItem };

// Access via CtxView
const View = zerver.CtxView(.{
    .reads = .{ .UserId },
    .writes = .{ .TodoItem }
});

fn step(ctx: *View) !Decision {
    const userId = try ctx.require(.UserId);
    try ctx.put(.TodoItem, todo);
    return .Continue;
}
```

## Server API

### Server Creation
```zig
var server = try zerver.Server.init(allocator, config, effectHandler);
defer server.deinit();
```

### Routing
```zig
// REST routes
try server.addRoute(.GET, "/todos/:id", routeSpec);

// Flow routes (POST to /flow/v1/<slug>)
try server.addFlow(flowSpec);
```

### Route Specification
```zig
const routeSpec = zerver.RouteSpec{
    .before = &.{ authStep },  // Middleware
    .steps = &.{ loadStep, validateStep, saveStep },
};
```

### Flow Specification
```zig
const flowSpec = zerver.FlowSpec{
    .slug = "checkout",
    .before = &.{ authStep },
    .steps = &.{ validateCart, chargeCard, createOrder },
};
```

## Context API

### Request Data Access
```zig
// HTTP method
const method = ctx.method();  // "GET", "POST", etc.

// Request path
const path = ctx.path();  // "/todos/123"

// Path parameters
const id = ctx.param("id");  // "123" from /todos/:id

// Query parameters
const page = ctx.queryParam("page");  // "1" from ?page=1

// Headers
const auth = ctx.header("Authorization");  // "Bearer token"

// Raw body
const body = ctx.body;  // []const u8
```

### Slot Operations
```zig
// Store data
try ctx.put(.UserId, userId);

// Retrieve required data
const userId = try ctx.require(.UserId);

// Retrieve optional data
if (ctx.optional(.UserId)) |userId| {
    // Use userId
}
```

### Response Helpers
```zig
// Success responses
return zerver.done(.{ .status = 200, .body = jsonStr });

// Error responses
return zerver.fail(errorCode, "context", "details");
```

## Effect API

### Database Effects
```zig
// Get single value
.Effect.dbGet(.{
    .key = "todo:123",
    .token = .TodoItem,
    .required = true,
})

// Put value
.Effect.dbPut(.{
    .key = "todo:123",
    .value = todoJson,
})

// Delete
.Effect.dbDel(.{
    .key = "todo:123",
})

// Scan/query
.Effect.dbScan(.{
    .prefix = "todo:",
    .token = .TodoList,
})
```

### HTTP Effects
```zig
// GET request
.Effect.httpGet(.{
    .url = "https://api.example.com/users",
    .headers = &.{ "Authorization: Bearer token" },
    .token = .ApiResponse,
})

// POST request
.Effect.httpPost(.{
    .url = "https://api.example.com/users",
    .body = userJson,
    .headers = &.{ "Content-Type: application/json" },
    .token = .ApiResponse,
})
```

## Decision Types

### Continue
```zig
return .Continue;  // Proceed to next step
```

### Need (with Effects)
```zig
return .Need(.{
    .effects = &.{ effect1, effect2 },
    .mode = .all,  // .all, .all_required, .any, .first_success
    .join = .all,  // How to combine results
    .resume = nextStep,
});
```

### Done (with Response)
```zig
return .Done(.{
    .status = 200,
    .body = "Success",
    .headers = &.{ "Content-Type: application/json" },
});
```

### Fail (with Error)
```zig
return .Fail(.{
    .kind = .NotFound,
    .ctx = .{ .what = "user", .key = userId },
});
```

## Error Handling

### Error Codes
```zig
.Unauthorized
.NotFound
.BadRequest
.InternalError
.Conflict
.Forbidden
```

### Custom Error Handler
```zig
const config = zerver.Config{
    .addr = .{ .ip = .{127, 0, 0, 1}, .port = 8080 },
    .on_error = handleError,
};

fn handleError(ctx: *CtxBase) !Decision {
    const err = ctx.last_error.?;
    return switch (err.kind) {
        .NotFound => zerver.done(.{ .status = 404, .body = "Not Found" }),
        else => zerver.done(.{ .status = 500, .body = "Internal Error" }),
    };
}
```

## Testing API

### ReqTest Setup
```zig
var req = try zerver.ReqTest.init(allocator);
defer req.deinit();

// Seed data
try req.setHeader("Authorization", "Bearer token");
try req.setParam("id", "123");
try req.setQuery("format", "json");
try req.seedSlotString(.UserId, "user123");

// Run step
const decision = try req.callStep(myStep);

// Assert results
try req.assertContinue(decision);
try req.assertDone(decision, 200);
```

## Build System

### Common Commands
```bash
# Build
zig build

# Run
zig build run

# Test
zig build test

# Format code
zig build fmt

# Clean
zig build clean
```

### Development Tasks
```bash
# Format all files
zig build fmt

# Run tests
zig build test

# Generate docs (future)
zig build docs
```

## Configuration

### Server Config
```zig
const config = zerver.Config{
    .addr = .{ .ip = .{127, 0, 0, 1}, .port = 8080 },
    .debug = false,
    .on_error = handleError,
};
```

## Best Practices

### Step Design
- Keep steps pure and focused
- Use CtxView for type safety
- Return appropriate Decision types
- Handle errors explicitly

### Effect Usage
- Use appropriate join strategies
- Handle effect failures
- Consider retry logic in middleware

### Error Handling
- Use structured error codes
- Provide meaningful error context
- Implement proper error responses

### Performance
- Minimize allocations in hot paths
- Use arena allocation for request data
- Profile with `zig build --pgo`

## Common Patterns

### Authentication Middleware
```zig
fn authStep(ctx: *AuthView) !Decision {
    const token = ctx.header("Authorization") orelse
        return zerver.fail(.Unauthorized, "auth", "missing_token");

    // Validate token, extract user
    try ctx.put(.UserId, userId);
    return .Continue;
}
```

### CRUD Operations
```zig
fn createStep(ctx: *CreateView) !Decision {
    const data = ctx.body;  // JSON from request

    return .Need(.{
        .effects = &.{ zerver.Effect.dbPut(.{
            .key = key,
            .value = data,
            .token = .CreatedItem,
        })},
        .resume = respondCreated,
    });
}

fn respondCreated(ctx: *CreateView) !Decision {
    const item = try ctx.require(.CreatedItem);
    return zerver.done(.{
        .status = 201,
        .body = item,
        .headers = &.{"Content-Type: application/json"},
    });
}
```

### Validation Chain
```zig
const validateChain = &.{
    validateInput,
    checkPermissions,
    validateBusinessRules,
};

const routeSpec = RouteSpec{
    .before = validateChain,
    .steps = &.{ processRequest },
};
```

This cheat sheet covers the essential Zerver APIs. For detailed documentation, see the `/docs` folder.