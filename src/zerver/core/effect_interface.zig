// src/zerver/core/effect_interface.zig
/// Minimal effect interface for breaking circular dependency
/// Contains only Effect, EffectResult, and supporting types
/// Does NOT import ctx.zig or types.zig

const std = @import("std");
const route_types = @import("../routes/types.zig");

/// Re-export Header from routes/types.zig
pub const Header = route_types.Header;

/// Common HTTP error codes (for convenience).
pub const ErrorCode = struct {
    // RFC 9110 Section 15 - Comprehensive HTTP status codes

    // 1xx Informational
    pub const Continue = 100;
    pub const SwitchingProtocols = 101;
    pub const Processing = 102;

    // 2xx Successful
    pub const OK = 200;
    pub const Created = 201;
    pub const Accepted = 202;
    pub const NonAuthoritativeInformation = 203;
    pub const NoContent = 204;
    pub const ResetContent = 205;
    pub const PartialContent = 206;
    pub const MultiStatus = 207;
    pub const AlreadyReported = 208;
    pub const IMUsed = 226;

    // 3xx Redirection
    pub const MultipleChoices = 300;
    pub const MovedPermanently = 301;
    pub const Found = 302;
    pub const SeeOther = 303;
    pub const NotModified = 304;
    pub const UseProxy = 305;
    pub const TemporaryRedirect = 307;
    pub const PermanentRedirect = 308;

    // 4xx Client Error
    pub const BadRequest = 400;
    pub const InvalidInput = BadRequest; // Alias for backward compatibility
    pub const Unauthorized = 401;
    pub const PaymentRequired = 402;
    pub const Forbidden = 403;
    pub const NotFound = 404;
    pub const MethodNotAllowed = 405;
    pub const NotAcceptable = 406;
    pub const ProxyAuthenticationRequired = 407;
    pub const RequestTimeout = 408;
    pub const Conflict = 409;
    pub const Gone = 410;
    pub const LengthRequired = 411;
    pub const PreconditionFailed = 412;
    pub const PayloadTooLarge = 413;
    pub const URITooLong = 414;
    pub const UnsupportedMediaType = 415;
    pub const RangeNotSatisfiable = 416;
    pub const ExpectationFailed = 417;
    pub const ImATeapot = 418;
    pub const MisdirectedRequest = 421;
    pub const UnprocessableEntity = 422;
    pub const Locked = 423;
    pub const FailedDependency = 424;
    pub const TooEarly = 425;
    pub const UpgradeRequired = 426;
    pub const PreconditionRequired = 428;
    pub const TooManyRequests = 429;
    pub const RequestHeaderFieldsTooLarge = 431;
    pub const UnavailableForLegalReasons = 451;

    // 5xx Server Error
    pub const InternalServerError = 500;
    pub const InternalError = InternalServerError; // Alias for backward compatibility
    pub const NotImplemented = 501;
    pub const BadGateway = 502;
    pub const UpstreamUnavailable = BadGateway; // Alias for backward compatibility
    pub const ServiceUnavailable = 503;
    pub const GatewayTimeout = 504;
    pub const Timeout = GatewayTimeout; // Alias for backward compatibility
    pub const HTTPVersionNotSupported = 505;
    pub const VariantAlsoNegotiates = 506;
    pub const InsufficientStorage = 507;
    pub const LoopDetected = 508;
    pub const NotExtended = 510;
    pub const NetworkAuthenticationRequired = 511;
};

/// Error context for detailed diagnostics.
pub const ErrorCtx = struct {
    what: []const u8, // domain: "todo", "auth", "db"
    key: []const u8 = "", // id or key associated with the error
};

/// An error result with kind code and context.
pub const Error = struct {
    kind: u16,
    ctx: ErrorCtx,
};

/// Effect result: either success payload bytes or failure metadata.
/// Caller owns the result and must call deinit() to free allocated bytes.
pub const EffectResult = union(enum) {
    success: struct {
        bytes: []u8,
        allocator: ?std.mem.Allocator,
    },
    failure: Error,

    /// Free allocated bytes if this result owns them.
    /// Must be called by the consumer to prevent memory leaks.
    pub fn deinit(self: *EffectResult) void {
        switch (self.*) {
            .success => |succ| {
                if (succ.allocator) |alloc| {
                    alloc.free(succ.bytes);
                }
            },
            .failure => {},
        }
        self.* = undefined;
    }
};

/// Retry policy with configurable parameters for fault tolerance.
pub const Retry = struct {
    max: u8 = 0, // Maximum number of retries
    initial_backoff_ms: u32 = 10, // Initial backoff in milliseconds
    max_backoff_ms: u32 = 5000, // Maximum backoff in milliseconds
    backoff_multiplier: f32 = 1.5, // Exponential backoff multiplier
    jitter_enabled: bool = false, // Add randomness to backoff
};

/// HTTP GET effect.
pub const HttpGet = struct {
    url: []const u8,
    token: u32, // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP POST effect.
pub const HttpPost = struct {
    url: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
    token: u32, // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP HEAD effect.
pub const HttpHead = struct {
    url: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP PUT effect.
pub const HttpPut = struct {
    url: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP DELETE effect.
pub const HttpDelete = struct {
    url: []const u8,
    body: []const u8 = "",
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP OPTIONS effect.
pub const HttpOptions = struct {
    url: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP TRACE effect.
pub const HttpTrace = struct {
    url: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP CONNECT effect.
pub const HttpConnect = struct {
    url: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP PATCH effect.
pub const HttpPatch = struct {
    url: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
    token: u32,
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// TCP connection effect - establishes a TCP connection.
pub const TcpConnect = struct {
    host: []const u8,
    port: u16,
    token: u32,
    timeout_ms: u32 = 3000,
    required: bool = true,
    keep_alive: bool = true,
    no_delay: bool = true,
};

/// TCP send effect - send data over established connection.
pub const TcpSend = struct {
    connection_token: u32,
    data: []const u8,
    token: u32,
    timeout_ms: u32 = 1000,
    required: bool = true,
};

/// TCP receive effect - receive data from established connection.
pub const TcpReceive = struct {
    connection_token: u32,
    token: u32,
    timeout_ms: u32 = 5000,
    max_bytes: u32 = 65536,
    required: bool = true,
};

/// TCP send-and-receive effect (most common pattern).
pub const TcpSendReceive = struct {
    connection_token: u32,
    request: []const u8,
    token: u32,
    timeout_ms: u32 = 5000,
    max_response_bytes: u32 = 65536,
    required: bool = true,
};

/// TCP close effect - close established connection.
pub const TcpClose = struct {
    connection_token: u32,
    token: u32,
    required: bool = false,
};

/// gRPC unary call effect.
pub const GrpcUnaryCall = struct {
    endpoint: []const u8,
    service: []const u8,
    method: []const u8,
    request_proto: []const u8,
    token: u32,
    timeout_ms: u32 = 5000,
    required: bool = true,
    metadata: []const Header = &.{},
};

/// gRPC server streaming call effect.
pub const GrpcServerStream = struct {
    endpoint: []const u8,
    service: []const u8,
    method: []const u8,
    request_proto: []const u8,
    token: u32,
    timeout_ms: u32 = 30000,
    required: bool = true,
    metadata: []const Header = &.{},
    max_messages: u32 = 1000,
};

/// WebSocket connect effect.
pub const WebSocketConnect = struct {
    url: []const u8,
    token: u32,
    timeout_ms: u32 = 5000,
    required: bool = true,
    headers: []const Header = &.{},
};

/// WebSocket send effect.
pub const WebSocketSend = struct {
    connection_token: u32,
    message: []const u8,
    token: u32,
    timeout_ms: u32 = 1000,
    required: bool = true,
};

/// WebSocket receive effect.
pub const WebSocketReceive = struct {
    connection_token: u32,
    token: u32,
    timeout_ms: u32 = 30000,
    required: bool = true,
};

/// Database GET effect.
pub const DbGet = struct {
    key: []const u8,
    token: u32, // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 300,
    retry: Retry = .{},
    required: bool = true,
};

/// Database PUT effect.
pub const DbPut = struct {
    key: []const u8,
    value: []const u8,
    token: u32, // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 400,
    retry: Retry = .{},
    required: bool = true,
    idem: []const u8 = "", // idempotency key
};

/// Database DELETE effect.
pub const DbDel = struct {
    key: []const u8,
    token: u32,
    timeout_ms: u32 = 300,
    retry: Retry = .{},
    required: bool = true,
    idem: []const u8 = "",
};

/// Database query parameter - supports primitive types and slot references
pub const DbParam = union(enum) {
    null: void,
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    slot: u32, // Reference to slot value
};

/// Database QUERY effect - generic SQL execution with parameters
pub const DbQuery = struct {
    sql: []const u8, // SQL query with ? placeholders
    params: []const DbParam, // Parameters to bind
    token: u32, // Slot identifier for result storage
    timeout_ms: u32 = 300,
    retry: Retry = .{},
    required: bool = true,
};

/// Database SCAN effect.
pub const DbScan = struct {
    prefix: []const u8,
    token: u32,
    timeout_ms: u32 = 300,
    retry: Retry = .{},
    required: bool = true,
};

/// File JSON Read effect.
pub const FileJsonRead = struct {
    path: []const u8,
    token: u32, // Slot identifier for result storage
    required: bool = true,
};

/// File JSON Write effect.
pub const FileJsonWrite = struct {
    path: []const u8,
    data: []const u8,
    token: u32, // Slot identifier for result storage (e.g., success/failure)
    required: bool = true,
};

/// Compute-bound task scheduled on dedicated worker pool.
pub const ComputeTask = struct {
    operation: []const u8,
    token: u32,
    timeout_ms: u32 = 0,
    required: bool = true,
    metadata: ?*const anyopaque = null,

    // CPU Budget Management
    cpu_budget_ms: u32 = 0, // Estimated CPU time budget (0 = unlimited)
    priority: u8 = 128, // Task priority (0=highest, 255=lowest, 128=normal)
    park_on_budget_exceeded: bool = true, // Park task if budget exceeded
    cooperative_yield_interval_ms: u32 = 10, // Yield to other tasks every N ms
};

/// Accelerator task (GPU/TPU/etc.) routed to specialized queue.
pub const AcceleratorTask = struct {
    kernel: []const u8,
    token: u32,
    timeout_ms: u32 = 2000,
    required: bool = true,
    metadata: ?*const anyopaque = null,

    // Accelerator Budget Management
    compute_budget_ms: u32 = 0, // Estimated accelerator time budget (0 = unlimited)
    priority: u8 = 128, // Task priority (0=highest, 255=lowest, 128=normal)
    park_on_budget_exceeded: bool = true, // Park task if budget exceeded
};

/// Key-value cache read.
pub const KvCacheGet = struct {
    key: []const u8,
    token: u32,
    timeout_ms: u32 = 50,
    required: bool = true,
};

/// Key-value cache write.
pub const KvCacheSet = struct {
    key: []const u8,
    value: []const u8,
    token: u32,
    timeout_ms: u32 = 50,
    required: bool = true,
    ttl_ms: u32 = 0,
};

/// Key-value cache delete/invalidate.
pub const KvCacheDelete = struct {
    key: []const u8,
    token: u32,
    timeout_ms: u32 = 50,
    required: bool = false,
};

/// An Effect represents a request to perform I/O (HTTP, DB, etc.).
pub const Effect = union(enum) {
    http_get: HttpGet,
    http_head: HttpHead,
    http_post: HttpPost,
    http_put: HttpPut,
    http_delete: HttpDelete,
    http_options: HttpOptions,
    http_trace: HttpTrace,
    http_connect: HttpConnect,
    http_patch: HttpPatch,
    tcp_connect: TcpConnect,
    tcp_send: TcpSend,
    tcp_receive: TcpReceive,
    tcp_send_receive: TcpSendReceive,
    tcp_close: TcpClose,
    grpc_unary_call: GrpcUnaryCall,
    grpc_server_stream: GrpcServerStream,
    websocket_connect: WebSocketConnect,
    websocket_send: WebSocketSend,
    websocket_receive: WebSocketReceive,
    db_get: DbGet,
    db_put: DbPut,
    db_del: DbDel,
    db_query: DbQuery,
    db_scan: DbScan,
    file_json_read: FileJsonRead,
    file_json_write: FileJsonWrite,
    compute_task: ComputeTask,
    accelerator_task: AcceleratorTask,
    kv_cache_get: KvCacheGet,
    kv_cache_set: KvCacheSet,
    kv_cache_delete: KvCacheDelete,
};
