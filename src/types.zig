/// Core type definitions for Zerver: Decision, Effect, Response, Error, etc.

const std = @import("std");

/// HTTP method.
pub const Method = enum {
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,
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
    what: []const u8,  // domain: "todo", "auth", "db"
    key: []const u8 = "",  // id or key associated with the error
};

/// An error result with kind code and context.
pub const Error = struct {
    kind: u16,
    ctx: ErrorCtx,
};

/// Retry policy.
pub const Retry = struct {
    max: u8 = 0,
};

/// HTTP GET effect.
pub const HttpGet = struct {
    url: []const u8,
    token: u32,  // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// HTTP POST effect.
pub const HttpPost = struct {
    url: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
    token: u32,  // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 1000,
    retry: Retry = .{},
    required: bool = true,
};

/// Database GET effect.
pub const DbGet = struct {
    key: []const u8,
    token: u32,  // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 300,
    retry: Retry = .{},
    required: bool = true,
};

/// Database PUT effect.
pub const DbPut = struct {
    key: []const u8,
    value: []const u8,
    token: u32,  // Slot identifier (enum tag value) for result storage
    timeout_ms: u32 = 400,
    retry: Retry = .{},
    required: bool = true,
    idem: []const u8 = "",  // idempotency key
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
    Parallel,      // May execute concurrently
    Sequential,    // Execute in strict order
};

/// Join strategy for waiting on multiple effects.
pub const Join = enum {
    all,              // Wait for all effects
    all_required,     // Wait for all required; optional may complete in background
    any,              // Resume on first completion
    first_success,    // Resume on first success
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
    call: *const fn (*anyopaque) anyerror!Decision,  // *CtxBase, re-trampolined to typed *CtxView
    reads: []const u32 = &.{},  // Slot identifiers
    writes: []const u32 = &.{},  // Slot identifiers
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
