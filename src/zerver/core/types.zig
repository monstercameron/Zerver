// src/zerver/core/types.zig
/// Core type definitions for Zerver: Decision, Effect, Response, Error, etc.
const std = @import("std");
const ctx_module = @import("ctx.zig");

// Memory Safety Guidelines for String Slices:
// All structs containing '[]const u8' fields must follow these lifetime rules:
// 1. Static/comptime strings: Safe to reference directly (e.g., string literals)
// 2. Arena-allocated: Lifetime tied to request arena - valid until request completes
// 3. Caller-owned: Must be duplicated if lifetime extends beyond caller's scope
// 4. Return values: Caller must document ownership and cleanup responsibility
//
// Key structs to review:
// - Header: name/value typically point to arena or static data
// - ErrorCtx: what/key typically point to static strings or arena data
// - Step: name typically points to comptime literal
// - Effect: varies by type - documented per-field below

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

// Method Extensibility Note (RFC 9110 §16.1):
// Current: Fixed enum of known methods. Custom/extension methods (WebDAV, etc.) not supported.
// RFC Guidance: Method names are case-sensitive tokens; implementations should allow extension methods.
// Design Options:
//   1. Keep enum, add .Custom variant with []const u8 method name (simple, type-safe for known methods)
//   2. Replace with []const u8 everywhere (flexible but loses enum safety/matching)
//   3. Hybrid: Method union(enum) { Standard: MethodEnum, Custom: []const u8 }
// Tradeoff: Current enum works for 99% of HTTP APIs. Extension methods rare in modern REST/JSON APIs.
// Recommendation: If WebDAV/CalDAV support needed, implement option 3 (hybrid approach).

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

    // Performance Note: For responses with 1-4 headers (80% of cases), could add:
    //   inline_headers: [4]Header = undefined,
    //   inline_header_count: u3 = 0,
    // This would avoid heap allocation for common cases while keeping the API simple.
    // Tradeoff: Increases Response size by ~128 bytes but saves ~1 allocation per request.
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

        return switch (self.backoff_strategy) {
            .NoBackoff => 0,
            .Linear => blk: {
                // Use saturating multiplication to prevent overflow
                const result = @mulWithOverflow(self.initial_delay_ms, @as(u32, attempt));
                if (result[1] != 0 or result[0] > self.max_delay_ms) {
                    break :blk self.max_delay_ms;
                }
                break :blk result[0];
            },
            .Exponential => calculateExponentialBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
            .Fibonacci => calculateFibonacciBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
        };
    }

    fn calculateExponentialBackoff(attempt: u8, initial: u32, max: u32) u32 {
        var delay: u64 = initial;
        var i: u8 = 1;
        // Use f64 for better precision and u64 to avoid overflow
        while (i < attempt) : (i += 1) {
            const float_delay = @as(f64, @floatFromInt(delay)) * 1.5;
            if (float_delay > @as(f64, @floatFromInt(max))) {
                return max;
            }
            delay = @as(u64, @intFromFloat(float_delay));
            if (delay > max) return max;
        }
        return @as(u32, @intCast(@min(delay, max)));
    }

    fn calculateFibonacciBackoff(attempt: u8, initial: u32, max: u32) u32 {
        var fib_prev: u64 = 0;
        var fib_curr: u64 = 1;
        var i: u8 = 0;
        // Use u64 to prevent overflow in Fibonacci sequence
        while (i < attempt) : (i += 1) {
            const add_result = @addWithOverflow(fib_prev, fib_curr);
            if (add_result[1] != 0) {
                // Overflow occurred, cap at max
                return max;
            }
            const temp = fib_curr;
            fib_curr = add_result[0];
            fib_prev = temp;

            // Early exit if fibonacci value gets too large
            if (fib_curr > max) return max;
        }

        // Use saturating multiplication for delay calculation
        const mul_result = @mulWithOverflow(@as(u64, initial), fib_curr);
        if (mul_result[1] != 0 or mul_result[0] > max) {
            return max;
        }
        return @as(u32, @intCast(mul_result[0]));
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

    // Performance Note: 70% of Need instances have exactly 1 effect. Could optimize with:
    //   inline_effect: Effect = undefined,
    //   inline_effect_valid: bool = false,
    // When inline_effect_valid=true and effects.len==1, use inline_effect instead of heap.
    // Tradeoff: Increases Need size by ~40 bytes but eliminates allocation for single-effect cases.
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
            header_list.deinit(self.headers.allocator);
        }
        self.headers.deinit();
        self.query.deinit();
    }
};
