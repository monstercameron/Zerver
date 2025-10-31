// src/zerver/effects/network.zig
/// Network Effects Interface - TCP, gRPC, and HTTP helpers
///
/// Provides strong typed interfaces for network operations:
/// - TCP socket connections (client/server)
/// - gRPC client calls
/// - HTTP helpers with builder pattern
/// - WebSocket connections
///
/// Design: All network effects follow the same pattern:
/// 1. Connection establishment (may be pooled)
/// 2. Request/response exchange
/// 3. Automatic retry with backoff
/// 4. Telemetry integration

const std = @import("std");
const types = @import("../core/types.zig");

// ============================================================================
// TCP Socket Effects
// ============================================================================

/// TCP socket operation type
pub const TcpOperation = enum {
    connect,
    send,
    receive,
    send_receive, // Most common: send then receive
    close,
};

/// TCP connection effect - establishes a TCP connection
pub const TcpConnect = struct {
    host: []const u8,
    port: u16,
    token: u32, // Connection handle stored in slot
    timeout_ms: u32 = 3000,
    required: bool = true,

    // Connection options
    keep_alive: bool = true,
    no_delay: bool = true, // Disable Nagle's algorithm
    buffer_size: u32 = 8192,
};

/// TCP send effect - send data over established connection
pub const TcpSend = struct {
    connection_token: u32, // Token from TcpConnect
    data: []const u8,
    token: u32, // Bytes sent stored in slot
    timeout_ms: u32 = 1000,
    required: bool = true,
};

/// TCP receive effect - receive data from established connection
pub const TcpReceive = struct {
    connection_token: u32, // Token from TcpConnect
    token: u32, // Received data stored in slot
    timeout_ms: u32 = 5000,
    max_bytes: u32 = 65536,
    required: bool = true,

    // Read strategy
    read_until: ReadUntil = .{ .any_data = {} },
};

/// Strategy for reading from TCP socket
pub const ReadUntil = union(enum) {
    any_data: void, // Return on any data
    exact_bytes: u32, // Read exactly N bytes
    delimiter: []const u8, // Read until delimiter (e.g., "\r\n")
    timeout: void, // Read until timeout
};

/// TCP send-and-receive effect (most common pattern)
pub const TcpSendReceive = struct {
    connection_token: u32, // Token from TcpConnect
    request: []const u8,
    token: u32, // Response data stored in slot
    timeout_ms: u32 = 5000,
    max_response_bytes: u32 = 65536,
    required: bool = true,

    // Response parsing
    read_until: ReadUntil = .{ .any_data = {} },
};

/// TCP close effect - close established connection
pub const TcpClose = struct {
    connection_token: u32,
    token: u32, // Result (success/failure) stored in slot
    required: bool = false, // Often fire-and-forget
};

// ============================================================================
// gRPC Effects
// ============================================================================

/// gRPC call type (matches HTTP/2 semantics)
pub const GrpcCallType = enum {
    unary, // Single request -> single response
    client_stream, // Stream of requests -> single response
    server_stream, // Single request -> stream of responses
    bidi_stream, // Bidirectional streaming
};

/// gRPC method descriptor
pub const GrpcMethod = struct {
    service: []const u8, // e.g., "helloworld.Greeter"
    method: []const u8, // e.g., "SayHello"
    call_type: GrpcCallType = .unary,
};

/// gRPC unary call effect
pub const GrpcUnaryCall = struct {
    endpoint: []const u8, // e.g., "localhost:50051"
    method: GrpcMethod,
    request_proto: []const u8, // Serialized protobuf message
    token: u32, // Response proto stored in slot
    timeout_ms: u32 = 5000,
    required: bool = true,

    // gRPC metadata (headers)
    metadata: []const types.Header = &.{},

    // Connection pooling
    use_connection_pool: bool = true,

    // Compression
    compression: GrpcCompression = .none,
};

/// gRPC server streaming call effect
pub const GrpcServerStream = struct {
    endpoint: []const u8,
    method: GrpcMethod,
    request_proto: []const u8,
    token: u32, // Stream handle stored in slot
    timeout_ms: u32 = 30000, // Longer for streaming
    required: bool = true,

    metadata: []const types.Header = &.{},
    compression: GrpcCompression = .none,

    // Stream control
    max_messages: u32 = 1000, // Prevent unbounded streams
};

/// gRPC compression algorithm
pub const GrpcCompression = enum {
    none,
    gzip,
    deflate,
};

// ============================================================================
// WebSocket Effects
// ============================================================================

/// WebSocket operation type
pub const WebSocketOp = enum {
    connect,
    send_text,
    send_binary,
    receive,
    close,
    ping,
};

/// WebSocket connect effect
pub const WebSocketConnect = struct {
    url: []const u8, // ws:// or wss://
    token: u32, // Connection handle stored in slot
    timeout_ms: u32 = 5000,
    required: bool = true,

    // WebSocket headers
    headers: []const types.Header = &.{},

    // Sub-protocols
    protocols: []const []const u8 = &.{},
};

/// WebSocket send effect
pub const WebSocketSend = struct {
    connection_token: u32,
    message: []const u8,
    message_type: WebSocketMessageType = .text,
    token: u32, // Send result stored in slot
    timeout_ms: u32 = 1000,
    required: bool = true,
};

/// WebSocket receive effect
pub const WebSocketReceive = struct {
    connection_token: u32,
    token: u32, // Received message stored in slot
    timeout_ms: u32 = 30000,
    required: bool = true,
};

pub const WebSocketMessageType = enum {
    text,
    binary,
    close,
    ping,
    pong,
};

// ============================================================================
// HTTP Builder Helpers
// ============================================================================

/// HTTP request builder with fluent interface
pub const HttpRequestBuilder = struct {
    url: []const u8,
    method: HttpMethod = .GET,
    body: []const u8 = "",
    headers: std.ArrayList(types.Header),
    timeout_ms: u32 = 5000,
    retry: types.Retry = .{},
    required: bool = true,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) HttpRequestBuilder {
        return .{
            .url = url,
            .headers = std.ArrayList(types.Header).init(allocator),
        };
    }

    pub fn withMethod(self: *HttpRequestBuilder, method: HttpMethod) *HttpRequestBuilder {
        self.method = method;
        return self;
    }

    pub fn withBody(self: *HttpRequestBuilder, body: []const u8) *HttpRequestBuilder {
        self.body = body;
        return self;
    }

    pub fn withHeader(self: *HttpRequestBuilder, name: []const u8, value: []const u8) !*HttpRequestBuilder {
        try self.headers.append(.{ .name = name, .value = value });
        return self;
    }

    pub fn withJsonBody(self: *HttpRequestBuilder, body: []const u8) !*HttpRequestBuilder {
        self.body = body;
        try self.headers.append(.{ .name = "Content-Type", .value = "application/json" });
        return self;
    }

    pub fn withTimeout(self: *HttpRequestBuilder, timeout_ms: u32) *HttpRequestBuilder {
        self.timeout_ms = timeout_ms;
        return self;
    }

    pub fn withRetry(self: *HttpRequestBuilder, retry: types.Retry) *HttpRequestBuilder {
        self.retry = retry;
        return self;
    }

    pub fn optional(self: *HttpRequestBuilder) *HttpRequestBuilder {
        self.required = false;
        return self;
    }

    pub fn build(self: *HttpRequestBuilder, token: u32) !types.Effect {
        const headers = try self.headers.toOwnedSlice();

        return switch (self.method) {
            .GET => types.Effect{ .http_get = .{
                .url = self.url,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .POST => types.Effect{ .http_post = .{
                .url = self.url,
                .body = self.body,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .PUT => types.Effect{ .http_put = .{
                .url = self.url,
                .body = self.body,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .DELETE => types.Effect{ .http_delete = .{
                .url = self.url,
                .body = self.body,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .PATCH => types.Effect{ .http_patch = .{
                .url = self.url,
                .body = self.body,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .HEAD => types.Effect{ .http_head = .{
                .url = self.url,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
            .OPTIONS => types.Effect{ .http_options = .{
                .url = self.url,
                .headers = headers,
                .token = token,
                .timeout_ms = self.timeout_ms,
                .retry = self.retry,
                .required = self.required,
            } },
        };
    }
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a JSON HTTP POST request
pub fn jsonPost(url: []const u8, json_body: []const u8, token: u32) types.Effect {
    const headers = [_]types.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };

    return types.Effect{ .http_post = .{
        .url = url,
        .body = json_body,
        .headers = &headers,
        .token = token,
        .timeout_ms = 5000,
        .required = true,
    } };
}

/// Create a JSON HTTP GET request
pub fn jsonGet(url: []const u8, token: u32) types.Effect {
    return types.Effect{ .http_get = .{
        .url = url,
        .token = token,
        .timeout_ms = 3000,
        .required = true,
    } };
}

/// Create a gRPC unary call
pub fn grpcCall(
    endpoint: []const u8,
    service: []const u8,
    method: []const u8,
    request_proto: []const u8,
    token: u32,
) GrpcUnaryCall {
    return .{
        .endpoint = endpoint,
        .method = .{
            .service = service,
            .method = method,
            .call_type = .unary,
        },
        .request_proto = request_proto,
        .token = token,
    };
}

/// Create a TCP connection effect
pub fn tcpConnect(host: []const u8, port: u16, token: u32) TcpConnect {
    return .{
        .host = host,
        .port = port,
        .token = token,
    };
}

/// Create a TCP request-response effect
pub fn tcpRequest(
    connection_token: u32,
    request: []const u8,
    response_token: u32,
) TcpSendReceive {
    return .{
        .connection_token = connection_token,
        .request = request,
        .token = response_token,
    };
}

// ============================================================================
// Network Error Types
// ============================================================================

pub const NetworkError = error{
    ConnectionRefused,
    ConnectionReset,
    ConnectionTimeout,
    HostUnreachable,
    NetworkUnreachable,
    TlsHandshakeFailed,
    DnsResolutionFailed,
    InvalidUrl,
    ProtocolError,
    GrpcError,
    WebSocketError,
};

/// Network error context for detailed diagnostics
pub const NetworkErrorCtx = struct {
    error_type: NetworkError,
    host: []const u8,
    port: ?u16 = null,
    message: []const u8,
    retry_after_ms: ?u32 = null,
};
