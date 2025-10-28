# Todos Feature DLL

External hot-reloadable todos feature for Zerver.

## Overview

This is the todos feature packaged as a dynamically loadable library (.so/.dylib/.dll). It can be loaded, unloaded, and reloaded at runtime without stopping the server, enabling zero-downtime deployments.

## DLL Interface

The todos feature implements the standard Zerver DLL interface:

```zig
export fn featureInit(allocator: *std.mem.Allocator) c_int
export fn featureShutdown() void
export fn featureVersion() u32
export fn featureMetadata() [*c]const u8
export fn registerRoutes(router: ?*anyopaque) c_int
```

## Routes

The todos feature registers the following routes:

### Todo Operations
- `GET /todos` - List all todos for the authenticated user
- `GET /todos/:id` - Get a specific todo item
- `POST /todos` - Create a new todo
- `PUT /todos/:id` - Update a todo (full replacement)
- `DELETE /todos/:id` - Delete a todo

## Authentication

All endpoints require the `X-User-ID` header for user authentication. Requests without this header will receive a 401 Unauthorized response.

## Data Model

```zig
pub const TodoItem = struct {
    id: []const u8,
    title: []const u8,
    done: bool = false,
};
```

## Building

Build the todos DLL:

```bash
cd features/todos
zig build
```

This will produce `zig-out/lib/libtodos.so` (or `.dylib` on macOS, `.dll` on Windows).

## Hot Reload

The Zupervisor watches for changes to DLL files and automatically reloads them:

1. Modify todos feature code
2. Rebuild: `zig build`
3. Zupervisor detects file change
4. New DLL version is loaded (Active state)
5. Old DLL version drains existing requests (Draining state)
6. Old DLL version is unloaded (Retired state)

## Version History

- **v1.0.0** - Initial release with full CRUD for todos

## Team Ownership

This feature is independently owned and can be deployed by the todos team without coordinating with other teams.
