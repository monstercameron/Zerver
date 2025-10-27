// src/zerver/core/types.zig
/// Core type definitions for Zerver: Decision, Effect, Response, Error, etc.
const std = @import("std");
const ctx_module = @import("ctx.zig");

// TODO: Memory/Safety - Review all structs containing '[]const u8' fields to ensure that string slices are either duplicated into appropriate allocators or their lifetimes are carefully managed to prevent use-after-free issues.

// TODO: Memory/Safety - Review all structs containing '[]const u8' fields to ensure that string slices are either duplicated into appropriate allocators or their lifetimes are carefully managed to prevent use-after-free issues.

// TODO: Memory/Safety - Review all structs containing '[]const u8' fields to ensure that string slices are either duplicated into appropriate allocators or their lifetimes are carefully managed to prevent use-after-free issues.

// TODO: Memory/Safety - Review all structs containing '[]const u8' fields to ensure that string slices are either duplicated into appropriate allocators or their lifetimes are carefully managed to prevent use-after-free issues.

/// HTTP method.
pub const Method = enum {
    // RFC 9110 Section 9 - Standard HTTP methods
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    // PATCH is not in RFC 9110 but widely supported
    PATCH,
};
// TODO: RFC 9110 Section 16.1 - Consider a mechanism for method extensibility beyond the predefined enum.
// TODO: RFC 9110 Section 16.1 - Consider a mechanism for method extensibility beyond the predefined enum.

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

/// A response to send back to the client.
pub const Response = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: ResponseBody = .{ .complete = "" },
    // TODO: SSE - Consider a mechanism for streaming response bodies (e.g., an iterator or a writer) to support Server-Sent Events and other streaming use cases.
    // TODO: SSE - Consider a mechanism for streaming response bodies (e.g., an iterator or a writer) to support Server-Sent Events and other streaming use cases.
    // TODO: Perf - Allow callers to borrow from a small fixed-capacity header array to avoid heap allocations on hot paths.
};

/// Response body can be either complete or streaming
pub const ResponseBody = union(enum) {
    complete: []const u8,
    streaming: StreamingBody,
};

/// Streaming response body for SSE and other use cases
pub const StreamingBody = struct {
    content_type: []const u8 = "text/plain",
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
    is_sse: bool = false,
};

/// A header name-value pair.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
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
pub const EffectResult = union(enum) {
    success: struct {
        bytes: []u8,
        allocator: ?std.mem.Allocator,
        // TODO: Ownership - Clarify who frees `bytes`. Without a contract to call a deinit helper we leak buffers when effects succeed.
    },
    failure: Error,
};

/// Retry policy with configurable parameters for fault tolerance.
pub const Retry = struct {
    max: u8 = 0, // Maximum number of retries
    initial_backoff_ms: u32 = 10, // Initial backoff in milliseconds
    max_backoff_ms: u32 = 5000, // Maximum backoff in milliseconds
    backoff_multiplier: f32 = 1.5, // Exponential backoff multiplier
    jitter_enabled: bool = false, // Add randomness to backoff
};

/// Timeout policy for operations with configurable thresholds.
pub const Timeout = struct {
    deadline_ms: u32, // Hard deadline in milliseconds
    warn_threshold_ms: u32 = 0, // Warn if approaching deadline
};

/// Backoff strategy for retry timing.
pub const BackoffStrategy = enum {
    NoBackoff, // Retry immediately
    Linear, // Linear backoff: delay = attempt * base_ms
    Exponential, // Exponential backoff: delay = base_ms * (multiplier ^ attempt)
    Fibonacci, // Fibonacci backoff: delay = fib(attempt) * base_ms
};

/// Retry policy with advanced options (Phase-2 ready).
pub const AdvancedRetryPolicy = struct {
    max_attempts: u8 = 3, // Total attempts (including initial)
    backoff_strategy: BackoffStrategy = .Exponential,
    initial_delay_ms: u32 = 50,
    max_delay_ms: u32 = 5000,
    timeout_per_attempt_ms: u32 = 1000,

    /// Calculate delay for a specific attempt number
    pub fn calculateDelay(self: @This(), attempt: u8) u32 {
        if (attempt == 0) return 0;

        // TODO: Safety - Review arithmetic operations in retry/backoff calculations (e.g., calculateExponentialBackoff, calculateFibonacciBackoff) for potential integer overflows and use checked arithmetic (e.g., @add, @mul) or larger integer types if necessary.

        // TODO: Safety - Review arithmetic operations in retry/backoff calculations (e.g., calculateExponentialBackoff, calculateFibonacciBackoff) for potential integer overflows and use checked arithmetic (e.g., @add, @mul) or larger integer types if necessary.

        // TODO: Safety - Review arithmetic operations in retry/backoff calculations (e.g., calculateExponentialBackoff, calculateFibonacciBackoff) for potential integer overflows and use checked arithmetic (e.g., @add, @mul) or larger integer types if necessary.

        // TODO: Safety - Review arithmetic operations in retry/backoff calculations (e.g., calculateExponentialBackoff, calculateFibonacciBackoff) for potential integer overflows and use checked arithmetic (e.g., @add, @mul) or larger integer types if necessary.

        return switch (self.backoff_strategy) {
            .NoBackoff => 0,
            .Linear => if (self.initial_delay_ms * attempt > self.max_delay_ms) self.max_delay_ms else self.initial_delay_ms * attempt,
            .Exponential => calculateExponentialBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
            .Fibonacci => calculateFibonacciBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
        };
    }

    fn calculateExponentialBackoff(attempt: u8, initial: u32, max: u32) u32 {
        var delay: u32 = initial;
        var i: u8 = 1;
        // TODO: Logical Error - The 'calculateExponentialBackoff' function uses f32 for calculations, which can introduce floating-point precision errors. Consider using fixed-point arithmetic or a larger float type (f64) if precision is critical for backoff timing.
        // TODO: Logical Error - The 'calculateExponentialBackoff' function uses f32 for calculations, which can introduce floating-point precision errors. Consider using fixed-point arithmetic or a larger float type (f64) if precision is critical for backoff timing.
        while (i < attempt) : (i += 1) {
            delay = @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay)) * 1.5));
            if (delay > max) return max;
        }
        return delay;
    }

    fn calculateFibonacciBackoff(attempt: u8, initial: u32, max: u32) u32 {
        var fib_prev: u32 = 0;
        var fib_curr: u32 = 1;
        var i: u8 = 0;
        // TODO: Logical Error - The Fibonacci sequence in 'calculateFibonacciBackoff' grows rapidly. For larger 'attempt' values, intermediate 'fib_curr' or 'delay' calculations might overflow u32, leading to incorrect backoff values. Consider using larger integer types or checked arithmetic.
        // TODO: Logical Error - The Fibonacci sequence in 'calculateFibonacciBackoff' grows rapidly. For larger 'attempt' values, intermediate 'fib_curr' or 'delay' calculations might overflow u32, leading to incorrect backoff values. Consider using larger integer types or checked arithmetic.
        while (i < attempt) : (i += 1) {
            const temp = fib_curr;
            fib_curr = fib_prev + fib_curr;
            fib_prev = temp;
        }
        const delay = initial * fib_curr;
        return if (delay > max) max else delay;
    }
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
};

/// Accelerator task (GPU/TPU/etc.) routed to specialized queue.
pub const AcceleratorTask = struct {
    kernel: []const u8,
    token: u32,
    timeout_ms: u32 = 2000,
    required: bool = true,
    metadata: ?*const anyopaque = null,
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
    db_get: DbGet,
    db_put: DbPut,
    db_del: DbDel,
    db_scan: DbScan,
    file_json_read: FileJsonRead,
    file_json_write: FileJsonWrite,
    compute_task: ComputeTask,
    accelerator_task: AcceleratorTask,
    kv_cache_get: KvCacheGet,
    kv_cache_set: KvCacheSet,
    kv_cache_delete: KvCacheDelete,
};

/// Trigger condition for running compensating actions.
pub const CompensationTrigger = enum {
    on_failure,
    on_cancel,
};

/// Description of a compensating action for saga-style orchestration.
pub const Compensation = struct {
    label: []const u8 = "",
    trigger: CompensationTrigger = .on_failure,
    effect: Effect,
};

/// Mode for executing multiple effects.
pub const Mode = enum {
    Parallel, // May execute concurrently
    Sequential, // Execute in strict order
};

/// Join strategy for waiting on multiple effects.
pub const Join = enum {
    all, // Wait for all effects
    all_required, // Wait for all required; optional may complete in background
    any, // Resume on first completion
    first_success, // Resume on first success
};

/// Callback for continuation after effects complete.
pub const ResumeFn = *const fn (*ctx_module.CtxBase) anyerror!Decision;

/// A Decision represents the outcome of a step and tells the engine what to do next.
pub const Need = struct {
    effects: []const Effect,
    mode: Mode,
    join: Join,
    continuation: ?ResumeFn = null,
    compensations: []const Compensation = &.{},
    // TODO: Perf - Support small fixed-capacity inline storage for effects to avoid heap allocations for common single-effect cases.
};

pub const Decision = union(enum) {
    Continue,
    need: Need,
    Done: Response,
    Fail: Error,
};

/// A Step represents a unit of logic in a pipeline.
pub const Step = struct {
    name: []const u8,
    call: *const fn (*ctx_module.CtxBase) anyerror!Decision, // Typed *CtxBase
    reads: []const u32 = &.{}, // Slot identifiers
    writes: []const u32 = &.{}, // Slot identifiers
};

/// Route specification: before chain and main steps.
pub const RouteSpec = struct {
    before: []const Step = &.{},
    steps: []const Step,
};

/// Flow specification: slug-addressed endpoint.
pub const FlowSpec = struct {
    slug: []const u8,
    before: []const Step = &.{},
    steps: []const Step,
};

/// Result of parsing an HTTP request.
pub const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap(std.ArrayList([]const u8)),
    query: std.StringHashMap([]const u8),
    body: []const u8,
    client_ip: []const u8,

    /// Clean up allocated memory in the request
    pub fn deinit(self: *ParsedRequest) void {
        // Deinit each header's ArrayList
        var header_it = self.headers.valueIterator();
        while (header_it.next()) |header_list| {
            header_list.deinit();
        }
        self.headers.deinit();
        self.query.deinit();
    }
};

