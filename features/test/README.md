# Test Feature

Minimal example feature demonstrating the DLL-first architecture.

## Structure

```
test/
├── main.zig          # DLL entry point (exports featureInit, featureShutdown, featureVersion)
├── src/
│   └── routes.zig    # Route handlers
├── build.zig         # Builds test.dylib → ../../zig-out/lib/
└── README.md         # This file
```

## Routes

- `GET /test` - Returns HTML: `<h1>Test Feature Works!</h1>`

## Building

```bash
cd features/test
zig build
```

Output: `../../zig-out/lib/test.dylib` (or .so/.dll)

## Development Workflow

1. **Edit code** in `src/routes.zig`
2. **Build**: `zig build`
3. **Hot reload**: Zupervisor automatically reloads the DLL

## Team Template

Copy this folder to create a new feature:

```bash
cp -r features/test features/your-feature
cd features/your-feature
# Edit main.zig and src/routes.zig
zig build
```

## DLL API Reference

### Exported Functions (in main.zig)

```zig
export fn featureInit(server: *anyopaque) c_int
export fn featureShutdown() void
export fn featureVersion() [*:0]const u8
```

### Route Handler

```zig
fn handleRoute(
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int
```

### Server API

```zig
server.setStatus(response, 200);
server.setHeader(response, name_ptr, name_len, value_ptr, value_len);
server.setBody(response, body_ptr, body_len);
```

## Notes

- All handlers must use `callconv(.c)` for C ABI compatibility
- DLL is loaded from `zig-out/lib/` directory
- Zupervisor watches this directory for changes (hot reload)
