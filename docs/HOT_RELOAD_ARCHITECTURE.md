# Hot Reload Architecture

Zero-downtime hot reload infrastructure for Zerver using multi-process architecture and dynamic libraries.

## Overview

Zerver implements hot reload through a multi-process architecture where features are isolated in dynamically loadable libraries (DLLs) that can be reloaded without stopping the server.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Process 0: System Supervisor (Future)                       │
│ - Manages Zingest and Zupervisor processes                  │
│ - Crash recovery and process respawning                     │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴──────────┐
                    │                    │
          ┌─────────▼────────┐  ┌────────▼────────┐
          │ Process 1:        │  │ Process 2:      │
          │ Zingest           │  │ Zupervisor      │
          │ (HTTP Ingest)     │  │ (Supervisor)    │
          └───────────────────┘  └─────────────────┘
                    │                    │
                    │   Unix Socket      │
                    │   IPC Protocol     │
                    └────────────────────┘
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
    ┌───────▼─────┐  ┌────────▼──────┐  ┌──────▼──────┐
    │ blog.so     │  │ todos.so      │  │ feature.so  │
    │ (DLL v1)    │  │ (DLL v1)      │  │ (DLL vN)    │
    └─────────────┘  └───────────────┘  └─────────────┘
```

## Components

### 1. Zingest (Process 1) - HTTP Ingest Server

**Location:** `src/zingest/`

**Responsibilities:**
- Accept HTTP requests on port 8080
- Parse HTTP protocol
- Forward requests to Zupervisor via Unix socket IPC
- Return responses to clients
- Provides crash isolation (Zupervisor crashes don't bring down HTTP ingress)

**Key Files:**
- `src/zingest/main.zig` - HTTP server with thread-per-connection
- `src/zingest/ipc_client.zig` - IPC client with connection pooling

**Configuration:**
- `PORT` - HTTP listen port (default: 8080)
- `ZERVER_IPC_SOCKET` - Unix socket path (default: `/tmp/zerver.sock`)

### 2. Zupervisor (Process 2) - Supervisor with Hot Reload

**Location:** `src/zupervisor/`

**Responsibilities:**
- Listen on Unix socket for IPC requests from Zingest
- Route requests to feature DLLs
- Watch for DLL file changes
- Load new DLL versions
- Manage DLL lifecycle (Active → Draining → Retired)
- Atomically swap route tables

**Key Files:**
- `src/zupervisor/main.zig` - Supervisor with hot reload loop
- `src/zupervisor/ipc_server.zig` - Unix socket server

**Hot Reload Loop:**
```zig
while (true) {
    sleep(1000ms);
    events = file_watcher.pollEvents();
    for (events) |event| {
        if (ends_with(event.path, ".so")) {
            new_version = version_manager.loadNewVersion(event.path);
            // Router rebuild happens here
            router_lifecycle.beginReload(new_router);
        }
    }
}
```

### 3. Hot Reload Infrastructure

#### FileWatcher (`src/zerver/plugins/file_watcher.zig`)

Cross-platform file change detection:
- **macOS:** kqueue with EVFILT_VNODE
- **Linux:** inotify
- **Windows:** ReadDirectoryChangesW (stub)

```zig
var watcher = try FileWatcher.init(allocator);
try watcher.watch("/path/to/features");
const events = try watcher.pollEvents(allocator);
```

#### DLL Loader (`src/zerver/plugins/dll_loader.zig`)

Dynamic library loading with dlopen/dlclose:

```zig
var loader = try DLLLoader.init(allocator);
const handle = try loader.load("features/blog.so");
const init_fn = try loader.lookup(handle, "featureInit");
```

#### DLL Version Manager (`src/zerver/plugins/dll_version.zig`)

Two-version concurrency with state machine:

```
┌─────────┐
│  None   │
└────┬────┘
     │ loadNewVersion()
     ▼
┌─────────┐
│ Active  │◄─────────┐
└────┬────┘          │
     │ loadNewVersion()
     ▼               │
┌──────────┐         │
│ Draining │         │
└────┬─────┘         │
     │ retire()      │
     ▼               │
┌──────────┐         │
│ Retired  │─────────┘
└──────────┘
```

#### Atomic Router (`src/zerver/plugins/atomic_router.zig`)

Lock-free route table swaps:

```zig
var atomic_router = try AtomicRouter.init(allocator);

// Lock-free reads
const match = try atomic_router.match(.GET, "/api/posts", arena);

// Atomic swap (with lock)
const old_router = atomic_router.swap(new_router);
```

**RouterLifecycle** coordinates swaps with version lifecycle:
```zig
var lifecycle = RouterLifecycle.init(allocator, &atomic_router);
try lifecycle.beginReload(new_router); // Swaps and saves old
lifecycle.completeReload(); // Cleans up old router
```

### 4. IPC Protocol

**Transport:** Unix domain sockets
**Framing:** Length-prefix (4-byte big-endian + payload)
**Encoding:** MessagePack (JSON placeholder)
**Socket Path:** `/tmp/zerver.sock`

**Message Types:**

```zig
// Request: Zingest → Zupervisor
pub const IPCRequest = struct {
    request_id: u128,
    method: HttpMethod,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    remote_addr: []const u8,
    timestamp_ns: i64,
};

// Response: Zupervisor → Zingest
pub const IPCResponse = struct {
    request_id: u128,
    status: u16,
    headers: []const Header,
    body: []const u8,
    processing_time_us: u64,
};

// Error: Zupervisor → Zingest
pub const IPCError = struct {
    request_id: u128,
    error_code: ErrorCode,
    message: []const u8,
    details: ?[]const u8,
};
```

See: `docs/ipc-protocol.md`

### 5. DLL Interface

All feature DLLs must implement:

```zig
export fn featureInit(allocator: *std.mem.Allocator) c_int;
export fn featureShutdown() void;
export fn featureVersion() u32;
export fn featureMetadata() [*c]const u8;
export fn registerRoutes(router: ?*anyopaque) c_int;
```

See: `docs/dll-interface.md`

### 6. Feature DLLs

#### Blog Feature (`features/blog/`)
- Routes: `/blog/posts`, `/blog/posts/:id`, `/blog/posts/:id/comments`
- Build: `cd features/blog && zig build`
- Output: `zig-out/lib/libblog.so`

#### Todos Feature (`features/todos/`)
- Routes: `/todos`, `/todos/:id`
- Requires: `X-User-ID` header
- Build: `cd features/todos && zig build`
- Output: `zig-out/lib/libtodos.so`

## Hot Reload Flow

1. **Developer modifies feature code** (e.g., `features/blog/main.zig`)
2. **Developer rebuilds DLL** (`cd features/blog && zig build`)
3. **FileWatcher detects change** (blog.so modified)
4. **Zupervisor loads new DLL version**
   ```zig
   new_version_id = version_manager.loadNewVersion("blog.so");
   ```
5. **New router built with new DLL routes**
   ```zig
   new_router = buildRouterFromDLL(new_dll);
   ```
6. **Atomic router swap**
   ```zig
   old_router = atomic_router.swap(new_router);
   ```
7. **Old router enters draining state**
   - New requests use new router
   - In-flight requests complete on old router
8. **Old router retired after drain timeout**
   ```zig
   lifecycle.completeReload();
   dll_loader.close(old_version_handle);
   ```

## Zero-Downtime Guarantees

1. **No dropped requests:** Zingest queues requests during swap
2. **No request failures:** In-flight requests complete on old version
3. **Atomic cutover:** Single atomic pointer swap for route table
4. **Crash isolation:** Process boundaries prevent cascading failures

## Benefits

1. **Team Autonomy:** Each feature is an independent DLL owned by a team
2. **Fast Deployments:** Reload feature DLL in <1s without server restart
3. **Reduced Risk:** Only one feature reloads, others unaffected
4. **Crash Isolation:** Feature crashes don't bring down HTTP ingress
5. **Testability:** DLLs can be loaded/tested independently

## Testing

### Unit Tests
```bash
zig build test
```

Validates:
- FileWatcher initialization
- DLL loader functionality
- Version manager state transitions
- Atomic router swap operations

### Smoke Tests
```bash
zig test tests/hot_reload_smoke_test.zig
```

Validates:
- All components initialize successfully
- Components integrate correctly
- Route matching works
- Atomic swaps maintain consistency

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP listen port (Zingest) |
| `ZERVER_IPC_SOCKET` | `/tmp/zerver.sock` | Unix socket path |
| `ZERVER_FEATURE_DIR` | `./features` | Feature DLL directory |

## Monitoring

Key metrics to monitor:

1. **DLL Reload Time:** How long a hot reload takes
2. **Draining Duration:** Time for old version to drain
3. **Active Versions:** Should never exceed 2
4. **IPC Latency:** Round-trip time for IPC requests
5. **File Watch Events:** Rate of DLL changes detected

## Future Enhancements

1. **Process 0 (System Supervisor)**
   - Manage Zingest and Zupervisor processes
   - Automatic crash recovery
   - Health checks

2. **Graceful Drain Timeout**
   - Configurable timeout for draining old versions
   - Force-close connections after timeout

3. **Hot Reload Testing**
   - End-to-end tests with actual DLL modifications
   - Load testing during reload
   - Failure scenario testing

4. **Metrics & Observability**
   - Prometheus metrics export
   - Distributed tracing
   - Hot reload event logging

## References

- [IPC Protocol Specification](./ipc-protocol.md)
- [DLL Interface Specification](./dll-interface.md)
- [Blog Feature README](../features/blog/README.md)
- [Todos Feature README](../features/todos/README.md)

## Team Ownership

| Component | Owner |
|-----------|-------|
| Zingest | Platform Team |
| Zupervisor | Platform Team |
| Hot Reload Infrastructure | Platform Team |
| Blog Feature DLL | Blog Team |
| Todos Feature DLL | Todos Team |
