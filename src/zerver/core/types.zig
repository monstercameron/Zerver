// src/zerver/core/types.zig
/// Core type definitions for Zerver: Decision, Effect, Response, Error, etc.
const std = @import("std");
const ctx_module = @import("ctx.zig");
const route_types = @import("../routes/types.zig");
const effect_interface = @import("effect_interface.zig");

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

/// HTTP method - re-exported from routes/types.zig for backward compatibility
pub const Method = route_types.Method;

// Method Extensibility Note (RFC 9110 §16.1):
// Current: Fixed enum of known methods. Custom/extension methods (WebDAV, etc.) not supported.
// RFC Guidance: Method names are case-sensitive tokens; implementations should allow extension methods.
// Design Options:
//   1. Keep enum, add .Custom variant with []const u8 method name (simple, type-safe for known methods)
//   2. Replace with []const u8 everywhere (flexible but loses enum safety/matching)
//   3. Hybrid: Method union(enum) { Standard: MethodEnum, Custom: []const u8 }
// Tradeoff: Current enum works for 99% of HTTP APIs. Extension methods rare in modern REST/JSON APIs.
// Recommendation: If WebDAV/CalDAV support needed, implement option 3 (hybrid approach).

// Re-export all effect types from effect_interface.zig
pub const ErrorCode = effect_interface.ErrorCode;
pub const ErrorCtx = effect_interface.ErrorCtx;
pub const Error = effect_interface.Error;
pub const EffectResult = effect_interface.EffectResult;
pub const Retry = effect_interface.Retry;

// Re-export all HTTP effect types
pub const HttpGet = effect_interface.HttpGet;
pub const HttpPost = effect_interface.HttpPost;
pub const HttpHead = effect_interface.HttpHead;
pub const HttpPut = effect_interface.HttpPut;
pub const HttpDelete = effect_interface.HttpDelete;
pub const HttpOptions = effect_interface.HttpOptions;
pub const HttpTrace = effect_interface.HttpTrace;
pub const HttpConnect = effect_interface.HttpConnect;
pub const HttpPatch = effect_interface.HttpPatch;

// Re-export TCP effect types
pub const TcpConnect = effect_interface.TcpConnect;
pub const TcpSend = effect_interface.TcpSend;
pub const TcpReceive = effect_interface.TcpReceive;
pub const TcpSendReceive = effect_interface.TcpSendReceive;
pub const TcpClose = effect_interface.TcpClose;

// Re-export gRPC effect types
pub const GrpcUnaryCall = effect_interface.GrpcUnaryCall;
pub const GrpcServerStream = effect_interface.GrpcServerStream;

// Re-export WebSocket effect types
pub const WebSocketConnect = effect_interface.WebSocketConnect;
pub const WebSocketSend = effect_interface.WebSocketSend;
pub const WebSocketReceive = effect_interface.WebSocketReceive;

// Re-export database effect types
pub const DbGet = effect_interface.DbGet;
pub const DbPut = effect_interface.DbPut;
pub const DbDel = effect_interface.DbDel;
pub const DbParam = effect_interface.DbParam;
pub const DbQuery = effect_interface.DbQuery;
pub const DbScan = effect_interface.DbScan;

// Re-export file effect types
pub const FileJsonRead = effect_interface.FileJsonRead;
pub const FileJsonWrite = effect_interface.FileJsonWrite;

// Re-export compute effect types
pub const ComputeTask = effect_interface.ComputeTask;
pub const AcceleratorTask = effect_interface.AcceleratorTask;

// Re-export cache effect types
pub const KvCacheGet = effect_interface.KvCacheGet;
pub const KvCacheSet = effect_interface.KvCacheSet;
pub const KvCacheDelete = effect_interface.KvCacheDelete;

// Re-export Effect union
pub const Effect = effect_interface.Effect;

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

/// A header name-value pair - re-exported from routes/types.zig for backward compatibility
pub const Header = route_types.Header;

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
