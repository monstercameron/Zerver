# DLL Feature Interface Specification

## Overview

This document specifies the interface that feature DLLs must implement to be loaded by the Zerver supervisor.

## C ABI Compatibility

All exported functions use C calling convention for cross-language compatibility:

```zig
export fn featureInit(server: *Server) callconv(.C) ErrorCode!void
export fn featureShutdown() callconv(.C) void
export fn featureVersion() callconv(.C) [*:0]const u8
```

## Required Exports

### 1. Feature Initialization

```zig
/// Called when DLL is loaded or reloaded
/// Must register all routes and initialize feature state
/// @param server - Server instance for route registration
/// @return error if initialization fails
export fn featureInit(server: *Server) ErrorCode!void {
    // Register routes
    try server.addRoute(.GET, "/blogs", .{
        .steps = &.{ list_step, render_step },
    });

    // Initialize feature state (DB pools, caches, etc.)
    try initializeFeatureState();
}
```

**Contract:**
- Must be idempotent (safe to call multiple times)
- Must not block for more than 100ms
- Must not start background threads
- Must register at least one route
- Errors fail hot reload and keep old version active

### 2. Feature Shutdown

```zig
/// Called before DLL is unloaded
/// Must clean up all resources
export fn featureShutdown() void {
    // Close DB connections
    // Free allocated memory
    // Cancel any pending operations
    cleanupFeatureState();
}
```

**Contract:**
- Called after all in-flight requests complete
- Must complete within 5 seconds
- Must not panic
- Must be safe to call even if init failed

### 3. Feature Version

```zig
/// Returns semantic version string
/// Used for logging and metrics
export fn featureVersion() [*:0]const u8 {
    return "1.2.3";
}
```

**Contract:**
- Must return null-terminated C string
- String must remain valid for DLL lifetime
- Should follow semver (MAJOR.MINOR.PATCH)
- Used in logs and health checks

## Optional Exports

### 4. Feature Health Check

```zig
/// Called periodically to check feature health
/// @return true if healthy, false otherwise
export fn featureHealthCheck() bool {
    return db_pool.isHealthy() and cache.isResponsive();
}
```

**Contract:**
- Called every 30 seconds (configurable)
- Must complete within 1 second
- Unhealthy features logged as warnings
- Does not trigger reload

### 5. Feature Metadata

```zig
/// Returns JSON metadata about feature
/// Used for introspection and documentation
export fn featureMetadata() [*:0]const u8 {
    return
        \\{
        \\  "name": "Blog Feature",
        \\  "owner": "platform-team",
        \\  "routes": ["/blogs", "/blogs/api/posts"],
        \\  "dependencies": ["postgres", "redis"]
        \\}
    ;
}
```

## Route Registration

Features register routes during `featureInit`:

```zig
export fn featureInit(server: *Server) ErrorCode!void {
    const blog_routes = @import("routes.zig");
    try blog_routes.registerRoutes(server);
}
```

## Memory Management

### Allocator Rules

Features must use the allocator provided by the server:

```zig
pub fn step_handler(ctx: *CtxBase) !Decision {
    const allocator = ctx.allocator();
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);
    // ...
}
```

**Rules:**
- Never use `std.heap.page_allocator` or global allocators
- Use arena allocators for request-scoped data
- Free all allocations before returning from step
- Slots own their data (freed by framework)

### Static Data

```zig
// OK: Read-only static data
const ALLOWED_ORIGINS = [_][]const u8{ "https://example.com" };

// BAD: Mutable global state
var request_counter: u32 = 0;  // Race conditions!

// OK: Thread-safe atomic
var request_counter = std.atomic.Int(u32).init(0);
```

## Thread Safety

### Concurrent Execution

Steps may execute concurrently across multiple worker threads:

```zig
// BAD: Non-atomic mutation
var cache: HashMap = ...;
pub fn step_handler(ctx: *CtxBase) !Decision {
    cache.put(key, value);  // Race condition!
}

// GOOD: Thread-safe cache
var cache = ThreadSafeCache.init();
pub fn step_handler(ctx: *CtxBase) !Decision {
    cache.put(key, value);  // Safe
}
```

**Requirements:**
- Steps must be thread-safe
- Shared mutable state must use synchronization
- Prefer immutable data or per-request state

### Hot Reload Concurrency

During reload, two versions execute simultaneously:

```zig
// DLL v1.0 and v1.1 both loaded
// Old requests use v1.0
// New requests use v1.1
// Must not share mutable state between versions
```

**Requirements:**
- No shared mutable globals between versions
- DB/cache connections isolated per version
- Configuration copied, not shared

## Error Handling

### Error Types

```zig
pub const ErrorCode = error{
    InitializationFailed,
    DatabaseConnectionFailed,
    InvalidConfiguration,
    ResourceExhausted,
};
```

### Error Reporting

```zig
export fn featureInit(server: *Server) ErrorCode!void {
    const db = database.connect(config.db_url) catch |err| {
        slog.err("Failed to connect to database", .{
            slog.Attr.string("error", @errorName(err)),
            slog.Attr.string("db_url", config.db_url),
        });
        return error.DatabaseConnectionFailed;
    };
    // ...
}
```

## Configuration

### Environment Variables

Features access config via environment:

```zig
const db_url = std.os.getenv("BLOG_DATABASE_URL") orelse {
    return error.InvalidConfiguration;
};
```

**Naming Convention:**
- `{FEATURE}_{SETTING}` (e.g., `BLOG_DATABASE_URL`)
- Uppercase with underscores
- Document all env vars in README

### Configuration Files

```zig
// Load feature-specific config
const config_path = std.os.getenv("BLOG_CONFIG_PATH")
    orelse "/etc/zerver/blog.json";
const config = try loadConfig(allocator, config_path);
```

## Logging

Features use structured logging:

```zig
const slog = @import("slog.zig");

pub fn step_handler(ctx: *CtxBase) !Decision {
    slog.info("Processing blog request", .{
        slog.Attr.string("feature", "blog"),
        slog.Attr.string("operation", "list_posts"),
        slog.Attr.string("request_id", ctx.requestId()),
    });
}
```

**Guidelines:**
- Use request ID for tracing
- Log at appropriate levels (debug/info/warn/error)
- Include structured attributes
- Avoid PII in logs

## Metrics

Features emit metrics via callbacks:

```zig
pub fn step_handler(ctx: *CtxBase) !Decision {
    const start = std.time.nanoTimestamp();
    defer {
        const duration = std.time.nanoTimestamp() - start;
        ctx.recordMetric("blog.request.duration_ns", duration);
    }
    // ...
}
```

## Example Feature

```zig
// blog_feature.zig

const std = @import("std");
const zerver = @import("zerver");
const routes = @import("routes.zig");
const slog = @import("slog.zig");

var db_pool: ?*DatabasePool = null;

export fn featureInit(server: *zerver.Server) callconv(.C) ErrorCode!void {
    slog.info("Initializing blog feature", .{
        slog.Attr.string("version", featureVersion()),
    });

    // Initialize DB pool
    const db_url = std.os.getenv("BLOG_DATABASE_URL") orelse {
        slog.err("Missing BLOG_DATABASE_URL", .{});
        return error.InvalidConfiguration;
    };

    db_pool = try DatabasePool.init(server.allocator(), db_url);
    errdefer db_pool.?.deinit();

    // Register routes
    try routes.registerRoutes(server);

    slog.info("Blog feature initialized", .{
        slog.Attr.int("routes", 16),
    });
}

export fn featureShutdown() callconv(.C) void {
    slog.info("Shutting down blog feature", .{});

    if (db_pool) |pool| {
        pool.deinit();
        db_pool = null;
    }
}

export fn featureVersion() callconv(.C) [*:0]const u8 {
    return "1.0.0";
}

export fn featureHealthCheck() callconv(.C) bool {
    if (db_pool) |pool| {
        return pool.isHealthy();
    }
    return false;
}

const ErrorCode = error{
    InitializationFailed,
    InvalidConfiguration,
};
```

## Build Configuration

### Shared Library

Build as a shared library (.so on Linux, .dylib on macOS):

```zig
// build.zig
const lib = b.addSharedLibrary(.{
    .name = "blog_feature",
    .root_source_file = .{ .path = "src/features/blog/feature.zig" },
    .target = target,
    .optimize = optimize,
});

// Link against zerver core
lib.linkLibrary(zerver_lib);
```

### Symbol Visibility

Export only required symbols:

```bash
# Linux: version script
{
    global:
        featureInit;
        featureShutdown;
        featureVersion;
        featureHealthCheck;
        featureMetadata;
    local: *;
};

# macOS: export list
_featureInit
_featureShutdown
_featureVersion
_featureHealthCheck
_featureMetadata
```

## ABI Stability

### Versioning

Features specify minimum required Zerver version:

```zig
export fn requiredZerverVersion() [*:0]const u8 {
    return "2.0.0";
}
```

### Breaking Changes

When server API changes:
1. Bump major version
2. Keep old ABI for 2 releases
3. Emit deprecation warnings
4. Document migration path

## Testing

### Unit Tests

Test features in isolation:

```zig
test "blog feature initialization" {
    var server = try TestServer.init(testing.allocator);
    defer server.deinit();

    try featureInit(&server);

    try testing.expect(server.routeCount() > 0);
}
```

### Integration Tests

Load actual DLL:

```zig
test "hot reload blog feature" {
    const loader = try DLLLoader.init(testing.allocator);
    defer loader.deinit();

    try loader.load("./zig-out/lib/libblog_feature.so");
    try loader.callInit();

    // Modify and rebuild DLL
    // ...

    try loader.reload();
}
```

## Security

### Input Validation

Features must validate all inputs:

```zig
pub fn step_handler(ctx: *CtxBase) !Decision {
    const post_id = ctx.param("id") orelse return error.MissingParameter;

    // Validate format
    if (!isValidUUID(post_id)) {
        return error.InvalidParameter;
    }

    // Validate length
    if (post_id.len > 36) {
        return error.InvalidParameter;
    }
}
```

### SQL Injection Prevention

Use parameterized queries:

```zig
// BAD
const query = try std.fmt.allocPrint(allocator,
    "SELECT * FROM posts WHERE id = '{s}'", .{post_id});

// GOOD
const query = "SELECT * FROM posts WHERE id = $1";
const result = try db.query(query, .{post_id});
```

### Path Traversal Prevention

```zig
// Sanitize file paths
const safe_path = try sanitizePath(user_path);
if (!safe_path.isWithin("/var/uploads")) {
    return error.PathTraversal;
}
```

## Performance

### Optimization Guidelines

- Minimize allocations in hot paths
- Use arenas for request-scoped data
- Cache compiled templates/queries
- Pool expensive resources
- Avoid locks in request path

### Benchmarking

```zig
const bench = @import("bench");

test "benchmark blog list" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    try bench.run("blog_list", struct {
        pub fn run() void {
            _ = step_list_posts(&ctx);
        }
    });
}
```
