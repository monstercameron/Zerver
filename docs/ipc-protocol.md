# IPC Protocol Specification

## Overview

This document specifies the IPC protocol between Process 1 (HTTP Ingest) and Process 2 (Router/Supervisor/Effector).

## Transport

- **Mechanism**: Unix domain sockets (SOCK_STREAM)
- **Socket Path**: `/tmp/zerver-{pid}.sock` or configured via `ZERVER_IPC_SOCKET`
- **Connection**: Process 1 connects to Process 2 as a client

## Wire Protocol

### Framing

Length-prefix framing to handle variable-size messages:

```
┌─────────────┬─────────────────────────────┐
│   Length    │         Payload             │
│  (4 bytes)  │     (Length bytes)          │
│   u32 BE    │      MessagePack            │
└─────────────┴─────────────────────────────┘
```

- **Length**: 32-bit unsigned big-endian integer
- **Payload**: MessagePack-encoded message
- **Max Size**: 16 MB (configurable)

### Message Types

#### Request Message

```zig
const IPCRequest = struct {
    request_id: u128,           // Unique ID for tracing
    method: HttpMethod,         // GET, POST, PUT, PATCH, DELETE
    path: []const u8,           // e.g., "/blogs/api/posts/123"
    headers: []Header,          // Array of key-value pairs
    body: []const u8,           // Raw body bytes
    remote_addr: []const u8,    // Client IP for logging
    timestamp_ns: i64,          // Request arrival time
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

const HttpMethod = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    PATCH = 3,
    DELETE = 4,
    HEAD = 5,
    OPTIONS = 6,
};
```

#### Response Message

```zig
const IPCResponse = struct {
    request_id: u128,           // Matches request
    status: u16,                // HTTP status code
    headers: []Header,          // Response headers
    body: []const u8,           // Response body
    processing_time_us: u64,    // Time spent in Process 2
};
```

#### Error Response

```zig
const IPCError = struct {
    request_id: u128,
    error_code: ErrorCode,
    message: []const u8,
    details: ?[]const u8,       // Stack trace, etc.
};

const ErrorCode = enum(u8) {
    Timeout = 1,
    FeatureCrash = 2,
    RouteNotFound = 3,
    InternalError = 4,
    OverloadRejection = 5,
};
```

## Communication Flow

### Normal Request

```
Process 1                    Process 2
    |                            |
    |------- IPCRequest -------->|
    |                            | (route matching)
    |                            | (execute steps)
    |                            | (run effects)
    |<------ IPCResponse --------|
    |                            |
```

### Error Handling

```
Process 1                    Process 2
    |                            |
    |------- IPCRequest -------->|
    |                            | (feature crashes)
    |<------ IPCError ----------|
    |                            |
```

### Timeout

Process 1 implements client-side timeout (default: 30s):
- If no response in 30s, close connection
- Return 504 Gateway Timeout to HTTP client
- Log timeout event

## Connection Management

### Socket Creation

Process 2 creates and binds the Unix socket on startup:

```zig
const socket_path = try getSocketPath(allocator);
const listener = try std.net.StreamServer.init(.{
    .reuse_address = true,
});
try listener.listen(try std.net.Address.initUnix(socket_path));
```

### Connection Pool

Process 1 maintains a connection pool (default: 4 connections):
- Connections are pre-established at startup
- Round-robin distribution
- Automatic reconnection on failure
- Health check via ping messages

### Graceful Shutdown

1. Process 2 sends SHUTDOWN signal
2. Process 1 stops accepting new HTTP requests
3. Process 1 drains in-flight IPC requests (30s timeout)
4. Process 1 closes connections
5. Process 2 closes socket

## Performance Considerations

### Zero-Copy

- Headers stored as slices pointing into receive buffer
- Body passed by reference when possible
- Allocate only for response composition

### Pipelining

Process 1 can send multiple requests without waiting:
- Request IDs ensure proper matching
- Process 2 handles concurrently
- Responses may arrive out-of-order

### Backpressure

If Process 2 is overloaded:
1. Socket send buffer fills up
2. Process 1 blocks on send()
3. HTTP accepts slow down naturally
4. Or return 503 if queue > threshold

## Serialization Format

### Why MessagePack?

- Smaller than JSON (30-50% reduction)
- Faster to encode/decode
- Schema-less like JSON
- Preserves binary data
- Wide language support

### Alternative: Custom Binary

For even better performance, could use custom binary format:

```
Request:
[u128 request_id][u8 method][u16 path_len][path][u16 header_count]
  [for each header: u16 name_len][name][u16 value_len][value]
[u32 body_len][body]

Response:
[u128 request_id][u16 status][u16 header_count]
  [for each header: u16 name_len][name][u16 value_len][value]
[u32 body_len][body][u64 processing_time]
```

## Error Scenarios

### Process 2 Crash

- Process 1 detects closed connection
- Returns 502 Bad Gateway
- Attempts reconnection
- Alerts monitoring

### Process 2 Restart

- Old socket is closed
- New socket is created
- Process 1 reconnects automatically
- Brief 502 responses during reconnection

### Malformed Message

- Process 2 logs error
- Sends IPCError response
- Connection remains open

### Large Request

- Enforce max size (16 MB default)
- Return 413 Payload Too Large
- Consider streaming for uploads

## Security

### Unix Socket Permissions

```bash
chmod 600 /tmp/zerver-{pid}.sock
chown zerver:zerver /tmp/zerver-{pid}.sock
```

### Process Isolation

- Processes run as separate users
- Socket permissions enforce access control
- No shared memory

### Input Validation

- Process 2 validates all inputs
- Sanitize path parameters
- Check header sizes
- Limit nesting depth

## Monitoring

### Metrics to Track

- IPC request rate
- IPC request duration (p50, p95, p99)
- Active IPC connections
- IPC error rate by type
- Socket buffer usage
- Reconnection attempts

### Logging

All IPC operations are logged with:
- Request ID
- Timestamp
- Duration
- Status/Error
- Process IDs

## Future Extensions

### Streaming

For large uploads/downloads:
- Chunk-based protocol
- Stream request/response in multiple frames
- Use continuation tokens

### Multiplexing

- Multiple logical channels over one socket
- HTTP/2-style frame protocol
- Better resource utilization

### Compression

- Optional zstd compression for bodies
- Negotiate during connection setup
- Trade CPU for bandwidth
