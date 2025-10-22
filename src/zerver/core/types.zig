/// Core type definitions for Zerver: Decision, Effect, Response, Error, etc.
const std = @import("std");

/// HTTP method.
pub const Method = enum {
    // TODO: RFC 9110 - Expand to include all standard HTTP methods (Section 9) and consider method extensibility (Section 16.1).
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,
};

/// Common HTTP error codes (for convenience).
pub const ErrorCode = struct {
    // TODO: RFC 9110 - Expand to include a more comprehensive set of HTTP status codes (Section 15) for finer-grained error reporting.
    pub const InvalidInput = 400;
    pub const Unauthorized = 401;
    pub const Forbidden = 403;
    pub const NotFound = 404;
    pub const Conflict = 409;
    pub const TooManyRequests = 429;
    pub const UpstreamUnavailable = 502;
    pub const Timeout = 504;
    pub const InternalError = 500;
};

/// A response to send back to the client.
pub const Response = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: []const u8 = "",
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
            .Linear => if (self.initial_delay_ms * attempt > self.max_delay_ms) self.max_delay_ms else self.initial_delay_ms * attempt,
            .Exponential => calculateExponentialBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
            .Fibonacci => calculateFibonacciBackoff(attempt, self.initial_delay_ms, self.max_delay_ms),
        };
    }

    fn calculateExponentialBackoff(attempt: u8, initial: u32, max: u32) u32 {
        var delay: u32 = initial;
        var i: u8 = 1;
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

/// An Effect represents a request to perform I/O (HTTP, DB, etc.).
pub const Effect = union(enum) {
    http_get: HttpGet,
    http_post: HttpPost,
    db_get: DbGet,
    db_put: DbPut,
    db_del: DbDel,
    db_scan: DbScan,
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
pub const ResumeFn = *const fn (*anyopaque) anyerror!Decision;

/// A Decision represents the outcome of a step and tells the engine what to do next.
pub const Need = struct {
    effects: []const Effect,
    mode: Mode,
    join: Join,
    continuation: ResumeFn,
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
    call: *const fn (*anyopaque) anyerror!Decision, // *CtxBase, re-trampolined to typed *CtxView
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
    headers: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    body: []const u8,
    client_ip: []const u8,
};
