// src/zerver/impure/server.zig
/// Server: HTTP listener, routing, request handling.
const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const router_module = @import("../routes/router.zig");
const executor_module = @import("executor.zig");
const tracer_module = @import("../observability/tracer.zig");
const slog = @import("../observability/slog.zig");
const http_status = @import("../core/http_status.zig").HttpStatus;
const telemetry = @import("../observability/telemetry.zig");
const net_handler = @import("../runtime/handler.zig");
const http_connection = @import("../runtime/http/connection.zig");
const http_headers = @import("../runtime/http/headers.zig");

const default_content_type = "text/plain; charset=utf-8";

pub const Address = struct {
    ip: [4]u8,
    port: u16,
};

pub const Config = struct {
    addr: Address,
    on_error: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
    debug: bool = false,
    telemetry: telemetry.RequestTelemetryOptions = .{},
};

const CorrelationSource = enum {
    traceparent,
    x_request_id,
    x_correlation_id,
    generated,
};

const CorrelationContext = struct {
    id: []const u8,
    header_name: []const u8,
    header_value: []const u8,
    source: CorrelationSource,
};

/// Flow stores slug and spec.
const Flow = struct {
    slug: []const u8,
    spec: types.FlowSpec,
};

/// Simple HTTP request parser (MVP).
pub const ParsedRequest = struct {
    method: types.Method,
    path: []const u8,
    headers: std.StringHashMap(std.ArrayList([]const u8)),
    query: std.StringHashMap([]const u8),
    body: []const u8,
};

/// Response result that can be either complete or streaming
pub const ResponseResult = union(enum) {
    complete: []const u8,
    streaming: StreamingResponse,
};

/// Streaming response for SSE and other use cases
pub const StreamingResponse = struct {
    headers: []const u8,
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    router: router_module.Router,
    executor: executor_module.Executor,
    flows: std.ArrayList(Flow),
    global_before: std.ArrayList(types.Step),
    telemetry_options: telemetry.RequestTelemetryOptions,

    /// SSE event structure per HTML Living Standard
    pub const SSEEvent = struct {
        data: ?[]const u8 = null,
        event: ?[]const u8 = null,
        id: ?[]const u8 = null,
        retry: ?u32 = null,
    };

    /// Format an SSE event according to HTML Living Standard
    pub fn formatSSEEvent(self: *Server, event: SSEEvent, arena: std.mem.Allocator) ![]const u8 {
        _ = self;
        var buf = std.ArrayList(u8).initCapacity(arena, 256) catch unreachable;
        // TODO: Safety - Propagate allocator failure instead of unreachable; a missed OOM here will crash the whole server.
        // TODO: Perf - Reuse a scratch buffer or stream directly to the client to avoid per-event allocations when broadcasting SSE.
        const w = buf.writer(arena);

        // Event type (optional)
        if (event.event) |event_type| {
            try w.print("event: {s}\n", .{event_type});
        }

        // Event data (required for most events)
        if (event.data) |data| {
            // Split multi-line data
            var lines = std.mem.splitSequence(u8, data, "\n");
            while (lines.next()) |line| {
                try w.print("data: {s}\n", .{line});
            }
        }

        // Event ID (optional)
        if (event.id) |id| {
            try w.print("id: {s}\n", .{id});
        }

        // Retry delay (optional)
        if (event.retry) |retry_ms| {
            try w.print("retry: {d}\n", .{retry_ms});
        }

        // Double newline to end the event
        try w.writeAll("\n");

        return buf.items;
    }

    /// Create an SSE streaming response
    pub fn createSSEResponse(self: *Server, writer: *const fn (*anyopaque, []const u8) anyerror!void, context: *anyopaque) types.Response {
        _ = self;
        return .{
            .status = http_status.ok,
            .headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache" },
                .{ .name = "Connection", .value = "keep-alive" },
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Cache-Control" },
            },
            .body = .{
                .streaming = .{
                    .content_type = "text/event-stream",
                    .writer = writer,
                    .context = context,
                    .is_sse = true,
                },
            },
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: Config,
        effect_handler: *const fn (*const types.Effect, u32) anyerror!types.EffectResult,
    ) !Server {
        return Server{
            .allocator = allocator,
            .config = cfg,
            .router = try router_module.Router.init(allocator),
            .executor = executor_module.Executor.init(allocator, effect_handler),
            .flows = try std.ArrayList(Flow).initCapacity(allocator, 16),
            .global_before = try std.ArrayList(types.Step).initCapacity(allocator, 8),
            .telemetry_options = cfg.telemetry,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.flows.deinit(self.allocator);
        self.global_before.deinit(self.allocator);
    }

    /// Register global middleware chain.
    pub fn use(self: *Server, chain: []const types.Step) !void {
        try self.global_before.appendSlice(self.allocator, chain);
    }

    /// Register a REST route.
    pub fn addRoute(self: *Server, method: types.Method, path: []const u8, spec: types.RouteSpec) !void {
        try self.router.addRoute(method, path, spec);
    }

    /// Register a Flow endpoint.
    pub fn addFlow(self: *Server, spec: types.FlowSpec) !void {
        try self.flows.append(self.allocator, .{
            .slug = spec.slug,
            .spec = spec,
        });
    }

    /// Execute a pipeline for a request context.
    pub fn executePipeline(
        self: *Server,
        ctx_base: *ctx_module.CtxBase,
        telemetry_ctx: *telemetry.Telemetry,
        before_steps: []const types.Step,
        main_steps: []const types.Step,
    ) !types.Decision {
        // Execute global before chain
        for (self.global_before.items) |before_step| {
            telemetry_ctx.stepStart(.global_before, before_step.name);
            const decision = try self.executor.executeStepWithTelemetry(ctx_base, before_step.call, telemetry_ctx);
            telemetry_ctx.stepEnd(.global_before, before_step.name, @tagName(decision));
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute route-specific before chain
        for (before_steps) |before_step| {
            telemetry_ctx.stepStart(.route_before, before_step.name);
            const decision = try self.executor.executeStepWithTelemetry(ctx_base, before_step.call, telemetry_ctx);
            telemetry_ctx.stepEnd(.route_before, before_step.name, @tagName(decision));
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute main steps
        for (main_steps) |main_step| {
            telemetry_ctx.stepStart(.main, main_step.name);
            const ptr = @intFromPtr(main_step.call);
            slog.debug("Executing step", &.{
                slog.Attr.string("step", main_step.name),
                slog.Attr.int("ptr", @as(i64, @intCast(ptr))),
            });
            const decision = try self.executor.executeStepWithTelemetry(ctx_base, main_step.call, telemetry_ctx);
            telemetry_ctx.stepEnd(.main, main_step.name, @tagName(decision));
            if (decision != .Continue) {
                return decision;
            }
        }

        // If we reach here with no final decision, return Continue
        return .Continue;
    }

    /// Handle a single HTTP request: parse, route, execute.
    /// The caller provides an arena that will be used for allocations.
    /// The returned response slice is valid only while the arena is alive.
    pub fn handleRequest(
        self: *Server,
        request_text: []const u8,
        arena: std.mem.Allocator,
    ) !ResponseResult {
        const parsed = self.parseRequest(request_text, arena) catch |err| {
            switch (err) {
                error.MissingHostHeader => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.bad_request,
                        .body = .{ .complete = "Bad Request: Missing Host header (required for HTTP/1.1)" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.MultipleHostHeader => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.bad_request,
                        .body = .{ .complete = "Bad Request: Multiple Host headers" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.InvalidRequest, error.InvalidMethod, error.UnsupportedVersion, error.InvalidUri, error.UserinfoNotAllowed, error.InvalidHeaderFieldName => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.bad_request,
                        .body = .{ .complete = "Bad Request" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.MultipleContentLength, error.InvalidContentLength, error.ContentLengthMismatch, error.InvalidPercentEncoding, error.InvalidChunkedEncoding, error.TransferEncodingConflict, error.TrailerFieldNotDeclared, error.TrailerHeaderWithoutChunked => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.bad_request,
                        .body = .{ .complete = "Bad Request: Invalid request format" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.ExpectationFailed => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.expectation_failed,
                        .body = .{ .complete = "Expectation Failed: Unsupported Expect header" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.UnexpectedBody => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.bad_request,
                        .body = .{ .complete = "Bad Request: Body not allowed for this method" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.ContentLengthRequired => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.length_required,
                        .body = .{ .complete = "Length Required: Content-Length header is required" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.UnsupportedContentEncoding => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.unsupported_media_type,
                        .body = .{ .complete = "Unsupported Media Type: Content-Encoding not supported" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.UnsupportedContentType => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.unsupported_media_type,
                        .body = .{ .complete = "Unsupported Media Type: Content-Type not supported" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.NotAcceptable => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.not_acceptable,
                        .body = .{ .complete = "Not Acceptable: Requested representation not available" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.UnsupportedTeValue => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.not_implemented,
                        .body = .{ .complete = "Not Implemented: TE header contains unsupported value" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                error.UpgradeUnsupported => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.upgrade_required,
                        .body = .{ .complete = "Upgrade Required: Protocol upgrade not supported" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
                else => {
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = http_status.internal_server_error,
                        .body = .{ .complete = "Internal Server Error" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = default_content_type },
                        },
                    }, arena, false, false, "", null) };
                },
            }
        };

        var ctx = try ctx_module.CtxBase.init(arena);
        defer ctx.deinit();

        ctx.method_str = try self.methodToString(parsed.method, arena);
        ctx.path_str = parsed.path;
        ctx.body = parsed.body;
        ctx.request_bytes = request_text.len;

        slog.debug("HTTP request parsed", &.{
            slog.Attr.string("method", ctx.method_str),
            slog.Attr.string("path", ctx.path_str),
            slog.Attr.uint("body_len", parsed.body.len),
        });

        var header_iter = parsed.headers.iterator();
        while (header_iter.next()) |entry| {
            if (entry.value_ptr.items.len == 1) {
                try ctx.headers.put(entry.key_ptr.*, entry.value_ptr.items[0]);
            } else {
                var combined = try std.ArrayList(u8).initCapacity(arena, 64);
                for (entry.value_ptr.items, 0..) |value, i| {
                    if (i > 0) try combined.appendSlice(arena, ", ");
                    try combined.appendSlice(arena, value);
                }
                try ctx.headers.put(entry.key_ptr.*, combined.items);
            }
        }

        var query_iter = parsed.query.iterator();
        while (query_iter.next()) |entry| {
            try ctx.query.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const correlation = try self.resolveCorrelation(parsed.headers, arena);
        ctx.setRequestId(correlation.id);

        slog.debug("Correlation resolved", &.{
            slog.Attr.string("correlation_id", correlation.id),
            slog.Attr.string("correlation_source", @tagName(correlation.source)),
        });

        if (correlation.header_name.len != 0 and correlation.header_value.len != 0) {
            if (ctx.headers.get(correlation.header_name) != null) {
                ctx.headers.put(correlation.header_name, correlation.header_value) catch {};
            } else {
                const header_name_owned = ctx.allocator.dupe(u8, correlation.header_name) catch null;
                const header_name_slice: []const u8 = if (header_name_owned) |owned|
                    @as([]const u8, owned)
                else
                    correlation.header_name;
                ctx.headers.put(header_name_slice, correlation.header_value) catch {};
            }
        }

        var tracer = tracer_module.Tracer.init(arena);
        defer tracer.deinit();

        const telemetry_init = telemetry.buildInitOptions(self.telemetry_options, self.config.debug);
        var telemetry_ctx = try telemetry.Telemetry.init(arena, &tracer, telemetry_init);
        defer telemetry_ctx.deinit();

        telemetry_ctx.requestStart(&ctx);

        const keep_alive = self.shouldKeepAlive(parsed.headers);

        if (parsed.method == .OPTIONS) {
            telemetry_ctx.stepStart(.system, "options_handler");
            const allowed_methods = try self.getAllowedMethods(parsed.path, arena);
            telemetry_ctx.stepEnd(.system, "options_handler", "Continue");

            const response_body = try std.fmt.allocPrint(arena, "Allow: {s}", .{allowed_methods});
            const response = types.Response{
                .status = http_status.ok,
                .body = .{ .complete = response_body },
                .headers = &[_]types.Header{
                    .{ .name = "Allow", .value = allowed_methods },
                },
            };
            telemetry_ctx.recordResponseMetrics(telemetry.Telemetry.responseMetricsFromResponse(response));
            const trace_header = telemetry_ctx.finish(.{
                .status_code = http_status.ok,
                .outcome = "options",
                .error_ctx = null,
            }, arena) catch "";

            return ResponseResult{ .complete = try self.httpResponse(response, arena, false, keep_alive, trace_header, correlation) };
        }

        if (parsed.method == .CONNECT or parsed.method == .TRACE) {
            const response = types.Response{
                .status = http_status.not_implemented,
                .body = .{ .complete = if (parsed.method == .CONNECT)
                    "Not Implemented: CONNECT tunneling unsupported"
                else
                    "Not Implemented: TRACE diagnostics disabled" },
                .headers = &[_]types.Header{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            };

            ctx.status_code = response.status;
            ctx.runExitCallbacks();

            telemetry_ctx.recordResponseMetrics(telemetry.Telemetry.responseMetricsFromResponse(response));
            const outcome = telemetry.RequestOutcome{
                .status_code = response.status,
                .outcome = if (parsed.method == .CONNECT) "ConnectNotImplemented" else "TraceNotImplemented",
                .error_ctx = null,
            };
            const trace_header = telemetry_ctx.finish(outcome, arena) catch "";

            return ResponseResult{ .complete = try self.httpResponse(response, arena, false, keep_alive, trace_header, correlation) };
        }

        var route_match_opt = try self.router.match(parsed.method, parsed.path, arena);
        if (route_match_opt == null and parsed.method == .HEAD) {
            route_match_opt = try self.router.match(.GET, parsed.path, arena);
        }

        if (route_match_opt) |route_match| {
            telemetry_ctx.stepStart(.system, "route_match");
            var param_iter = route_match.params.iterator();
            while (param_iter.next()) |entry| {
                try ctx.params.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            telemetry_ctx.stepEnd(.system, "route_match", "Continue");

            const decision = try self.executePipeline(&ctx, &telemetry_ctx, route_match.spec.before, route_match.spec.steps);

            var outcome = telemetry.RequestOutcome{
                .status_code = ctx.status(),
                .outcome = @tagName(decision),
                .error_ctx = null,
            };
            switch (decision) {
                .Done => |resp| outcome.status_code = resp.status,
                .Fail => |err| {
                    outcome.status_code = err.kind;
                    outcome.error_ctx = err.ctx;
                },
                else => {},
            }

            return try self.renderResponse(&ctx, &telemetry_ctx, decision, outcome, arena, keep_alive, correlation);
        }

        if (route_match_opt == null) {
            const allowed_methods = try self.getAllowedMethods(parsed.path, arena);
            if (!std.mem.eql(u8, allowed_methods, "OPTIONS")) {
                const headers = [_]types.Header{
                    .{ .name = "Allow", .value = allowed_methods },
                    .{ .name = "Content-Type", .value = "text/plain" },
                };
                const response = types.Response{
                    .status = http_status.method_not_allowed,
                    .headers = &headers,
                    .body = .{ .complete = "Method Not Allowed" },
                };

                ctx.status_code = response.status;
                ctx.runExitCallbacks();

                telemetry_ctx.recordResponseMetrics(telemetry.Telemetry.responseMetricsFromResponse(response));
                const outcome = telemetry.RequestOutcome{
                    .status_code = response.status,
                    .outcome = "MethodNotAllowed",
                    .error_ctx = types.ErrorCtx{ .what = "routing", .key = parsed.path },
                };
                const trace_header = telemetry_ctx.finish(outcome, arena) catch "";

                return ResponseResult{ .complete = try self.httpResponse(response, arena, false, keep_alive, trace_header, correlation) };
            }
        }

        if (parsed.method == .POST and std.mem.startsWith(u8, parsed.path, "/flow/v1/")) {
            const slug = parsed.path[9..];
            for (self.flows.items) |flow| {
                if (std.mem.eql(u8, flow.slug, slug)) {
                    telemetry_ctx.stepStart(.system, "flow_match");
                    telemetry_ctx.stepEnd(.system, "flow_match", "Continue");

                    const decision = try self.executePipeline(&ctx, &telemetry_ctx, flow.spec.before, flow.spec.steps);

                    var outcome = telemetry.RequestOutcome{
                        .status_code = ctx.status(),
                        .outcome = @tagName(decision),
                        .error_ctx = null,
                    };
                    switch (decision) {
                        .Done => |resp| outcome.status_code = resp.status,
                        .Fail => |err| {
                            outcome.status_code = err.kind;
                            outcome.error_ctx = err.ctx;
                        },
                        else => {},
                    }

                    return try self.renderResponse(&ctx, &telemetry_ctx, decision, outcome, arena, keep_alive, correlation);
                }
            }
        }

        const not_found_error = types.Error{
            .kind = types.ErrorCode.NotFound,
            .ctx = .{ .what = "routing", .key = parsed.path },
        };
        ctx.status_code = not_found_error.kind;
        const outcome = telemetry.RequestOutcome{
            .status_code = not_found_error.kind,
            .outcome = "NotFound",
            .error_ctx = not_found_error.ctx,
        };

        return self.renderError(&ctx, &telemetry_ctx, not_found_error, outcome, arena, keep_alive, correlation);
    }

    /// Parse an HTTP request (MVP: very simplified).
    fn parseRequest(self: *Server, text: []const u8, arena: std.mem.Allocator) !ParsedRequest {
        var lines = std.mem.splitSequence(u8, text, "\r\n");

        // Parse request line: "GET /path HTTP/1.1"
        const request_line = lines.next() orelse return error.InvalidRequest;
        var request_parts = std.mem.tokenizeScalar(u8, request_line, ' ');

        const method_str = request_parts.next() orelse return error.InvalidRequest;
        const path_str = request_parts.next() orelse return error.InvalidRequest;
        const version_str = request_parts.next() orelse return error.InvalidRequest;

        if (request_parts.next() != null) {
            return error.InvalidRequest;
        }

        // RFC 9110 Section 2.5 - Parse and validate HTTP version
        if (!std.mem.eql(u8, version_str, "HTTP/1.1")) {
            return error.UnsupportedVersion;
        }

        const method = try self.parseMethod(method_str);
        const path_with_query = try arena.dupe(u8, path_str);

        // RFC 9110 Section 4.2.2 - CONNECT uses authority-form targets, others use origin/absolute.
        const normalized_target = blk: {
            if (method == .CONNECT) {
                try self.validateAuthorityForm(path_with_query);
                break :blk path_with_query;
            }

            // RFC 9110 Section 4.2.3, 4.2.4 - Validate and normalize URI
            break :blk try self.validateAndNormalizeUri(path_with_query, arena);
        };

        // Parse path and query string
        var path = normalized_target;
        var query = std.StringHashMap([]const u8).init(arena);

        if (std.mem.indexOfScalar(u8, normalized_target, '?')) |query_start| {
            path = normalized_target[0..query_start];
            const query_str = normalized_target[query_start + 1 ..];
            try self.parseQueryString(query_str, &query, arena);
        }

        path = try arena.dupe(u8, path);
        // TODO: Perf - Avoid re-duplicating the path slice when it already lives in the arena; keep a slice into `path_with_query` instead.

        // Parse headers (until empty line)
        var headers = std.StringHashMap(std.ArrayList([]const u8)).init(arena);
        while (lines.next()) |line| {
            if (line.len == 0) break; // Empty line = end of headers

            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaderFieldName;

            const header_name_raw = line[0..colon_idx];
            const header_name_trimmed = std.mem.trim(u8, header_name_raw, " \t");
            if (header_name_trimmed.len == 0 or header_name_trimmed.len != header_name_raw.len) {
                return error.InvalidHeaderFieldName;
            }
            try validateHeaderFieldName(header_name_trimmed);
            const header_name = try std.ascii.allocLowerString(arena, header_name_trimmed);

            const header_value_raw = line[colon_idx + 1 ..];
            const header_value_trimmed = std.mem.trim(u8, header_value_raw, " \t");
            const header_value = try arena.dupe(u8, header_value_trimmed);

            const gop = try headers.getOrPut(header_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.ArrayList([]const u8).initCapacity(arena, 1);
            }
            try gop.value_ptr.append(arena, header_value);
        }

        // RFC 9110 Section 7.2 - HTTP/1.1 requires exactly one Host header
        const host_values = headers.get("host") orelse return error.MissingHostHeader;
        if (host_values.items.len != 1) {
            return error.MultipleHostHeader;
        }

        // RFC 9110 Section 6 - Parse message body with proper framing
        const body_start = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.InvalidRequest;
        const raw_body = text[body_start + 4 ..];

        // Parse Content-Length and Transfer-Encoding
        var content_length: ?usize = null;
        var has_transfer_encoding = false;
        var unsupported_transfer_encoding = false;

        if (headers.get("content-length")) |cl_values| {
            if (cl_values.items.len > 1) {
                return error.MultipleContentLength;
            }
            const cl_str = cl_values.items[0];
            content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        }

        if (headers.get("expect")) |expect_values| {
            // RFC 9110 Section 10.1.1 - Only support the 100-continue expectation; reject all others.
            for (expect_values.items) |raw_value| {
                var token_it = std.mem.splitSequence(u8, raw_value, ",");
                var saw_supported = false;
                while (token_it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (trimmed.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(trimmed, "100-continue")) {
                        saw_supported = true;
                        continue;
                    }
                    return error.ExpectationFailed;
                }

                if (!saw_supported and raw_value.len > 0) {
                    return error.ExpectationFailed;
                }
            }
        }

        if (headers.get("content-encoding")) |encoding_values| {
            var unsupported = false;
            for (encoding_values.items) |raw_value| {
                var token_it = std.mem.splitSequence(u8, raw_value, ",");
                while (token_it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (trimmed.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(trimmed, "identity")) continue;
                    unsupported = true;
                    break;
                }
                if (unsupported) break;
            }

            if (unsupported) {
                return error.UnsupportedContentEncoding;
            }
        }

        if (headers.get("accept")) |accept_values| {
            if (!http_headers.acceptsTextPlain(accept_values.items, self.allocator)) {
                return error.NotAcceptable;
            }
        }

        if (headers.get("accept-language")) |accept_language_values| {
            if (!http_headers.acceptLanguageAllowsEnglish(accept_language_values.items, self.allocator)) {
                return error.NotAcceptable;
            }
        }

        if (headers.get("accept-charset")) |accept_charset_values| {
            if (!http_headers.acceptCharsetAllowsUtf8(accept_charset_values.items, self.allocator)) {
                return error.NotAcceptable;
            }
        }

        if (headers.get("accept-encoding")) |accept_encoding_values| {
            if (!http_headers.acceptEncodingAllowsIdentity(accept_encoding_values.items, self.allocator)) {
                return error.NotAcceptable;
            }
        }

        if (headers.get("te")) |te_values| {
            var unsupported_te = false;
            var token_buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.UnsupportedTeValue;
            defer token_buffer.deinit(self.allocator);

            for (te_values.items) |raw_value| {
                var token_it = std.mem.splitSequence(u8, raw_value, ",");
                while (token_it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (trimmed.len == 0) continue;

                    const sanitized_raw = http_headers.sanitizeHeaderSegment(trimmed, &token_buffer, self.allocator) catch return error.UnsupportedTeValue;
                    const sanitized = std.mem.trim(u8, sanitized_raw, " \t");
                    if (sanitized.len == 0) continue;

                    const semicolon_idx = std.mem.indexOfScalar(u8, sanitized, ';');
                    const coding = std.mem.trim(u8, if (semicolon_idx) |idx| sanitized[0..idx] else sanitized, " \t");
                    const params = if (semicolon_idx) |idx| sanitized[idx + 1 ..] else "";

                    if (coding.len == 0) continue;

                    if (std.ascii.eqlIgnoreCase(coding, "trailers") or std.ascii.eqlIgnoreCase(coding, "chunked")) {
                        if (!http_headers.qAllowsSelection(params, self.allocator)) {
                            unsupported_te = true;
                            break;
                        }
                    } else {
                        unsupported_te = true;
                        break;
                    }
                }
                if (unsupported_te) break;
            }

            if (unsupported_te) {
                return error.UnsupportedTeValue;
            }
        }

        var connection_requests_upgrade = false;
        if (headers.get("connection")) |connection_values| {
            for (connection_values.items) |value| {
                var token_it = std.mem.splitSequence(u8, value, ",");
                while (token_it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (trimmed.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(trimmed, "upgrade")) {
                        connection_requests_upgrade = true;
                        break;
                    }
                }
                if (connection_requests_upgrade) break;
            }
        }

        if (connection_requests_upgrade and headers.contains("upgrade")) {
            return error.UpgradeUnsupported;
        }

        if (headers.get("transfer-encoding")) |te_values| {
            for (te_values.items) |raw_value| {
                var token_it = std.mem.splitSequence(u8, raw_value, ",");
                while (token_it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (trimmed.len == 0) continue;
                    if (std.ascii.eqlIgnoreCase(trimmed, "chunked")) {
                        has_transfer_encoding = true;
                    } else {
                        unsupported_transfer_encoding = true;
                    }
                }
            }

            if (unsupported_transfer_encoding) {
                return error.InvalidChunkedEncoding;
            }
        }

        if (has_transfer_encoding and content_length != null) {
            return error.TransferEncodingConflict;
        }

        var allowed_trailer_storage: std.StringHashMap(void) = undefined;
        var allowed_trailers: ?*std.StringHashMap(void) = null;
        var has_trailer_header = false;

        if (headers.get("trailer")) |trailer_values| {
            has_trailer_header = true;
            allowed_trailer_storage = std.StringHashMap(void).init(arena);

            for (trailer_values.items) |raw_value| {
                var name_it = std.mem.splitSequence(u8, raw_value, ",");
                while (name_it.next()) |segment| {
                    const trimmed = std.mem.trim(u8, segment, " \t");
                    if (trimmed.len == 0) continue;
                    try validateHeaderFieldName(trimmed);
                    const lower = try std.ascii.allocLowerString(arena, trimmed);
                    try allowed_trailer_storage.put(lower, {});
                }
            }

            if (allowed_trailer_storage.count() != 0) {
                allowed_trailers = &allowed_trailer_storage;
            }
        }

        if (has_trailer_header and !has_transfer_encoding) {
            return error.TrailerHeaderWithoutChunked;
        }

        // RFC 9110 Section 6.4 - Validate message body framing
        var body: []const u8 = "";

        if (has_transfer_encoding) {
            // RFC 9112 Section 6 - Parse chunked encoding
            body = try self.parseChunkedBody(raw_body, arena, &headers, allowed_trailers);
        } else if (content_length) |cl| {
            // Content-Length specified - body must be exactly this length
            if (raw_body.len != cl) {
                slog.err("Content-Length mismatch", &.{
                    slog.Attr.uint("declared_len", cl),
                    slog.Attr.uint("actual_len", raw_body.len),
                    slog.Attr.string("path", path),
                });
                return error.ContentLengthMismatch;
            }
            slog.debug("Content-Length verified", &.{
                slog.Attr.uint("content_length", cl),
                slog.Attr.uint("raw_body_len", raw_body.len),
                slog.Attr.string("path", path),
            });
            body = raw_body;
        } else {
            // No Content-Length or Transfer-Encoding
            // RFC 9110 Section 6.3 - For methods that typically don't have bodies
            if (method == .GET or method == .HEAD or method == .DELETE or method == .OPTIONS or method == .TRACE or method == .CONNECT) {
                // These methods should not have bodies
                if (raw_body.len > 0) {
                    return error.UnexpectedBody;
                }
            } else {
                // For other methods (POST, PUT, PATCH), require Content-Length
                return error.ContentLengthRequired;
            }
        }

        if (!self.methodAllowsPayload(method) and body.len > 0) {
            return error.UnexpectedBody;
        }

        if (headers.get("content-type")) |content_type_values| {
            if (!http_headers.contentTypeAllowsTextPlain(content_type_values.items, self.allocator)) {
                return error.UnsupportedContentType;
            }
        }

        return ParsedRequest{
            .method = method,
            .path = path,
            .headers = headers,
            .query = query,
            .body = try arena.dupe(u8, body),
        };
    }

    fn parseMethod(self: *Server, text: []const u8) !types.Method {
        _ = self;
        // RFC 9110 Section 9 - Support all standard HTTP methods
        if (std.mem.eql(u8, text, "GET")) return .GET;
        if (std.mem.eql(u8, text, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, text, "POST")) return .POST;
        if (std.mem.eql(u8, text, "PUT")) return .PUT;
        if (std.mem.eql(u8, text, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, text, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, text, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, text, "TRACE")) return .TRACE;
        if (std.mem.eql(u8, text, "PATCH")) return .PATCH;
        return error.InvalidMethod;
    }

    fn methodAllowsPayload(self: *Server, method: types.Method) bool {
        _ = self;
        return switch (method) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }

    fn methodToString(self: *Server, method: types.Method, arena: std.mem.Allocator) ![]const u8 {
        _ = self;
        return switch (method) {
            .GET => try arena.dupe(u8, "GET"),
            .HEAD => try arena.dupe(u8, "HEAD"),
            .POST => try arena.dupe(u8, "POST"),
            .PUT => try arena.dupe(u8, "PUT"),
            .DELETE => try arena.dupe(u8, "DELETE"),
            .CONNECT => try arena.dupe(u8, "CONNECT"),
            .OPTIONS => try arena.dupe(u8, "OPTIONS"),
            .TRACE => try arena.dupe(u8, "TRACE"),
            .PATCH => try arena.dupe(u8, "PATCH"),
        };
    }

    fn parseQueryString(self: *Server, query_str: []const u8, query_map: *std.StringHashMap([]const u8), arena: std.mem.Allocator) !void {
        _ = self;
        var it = std.mem.splitSequence(u8, query_str, "&");
        while (it.next()) |param| {
            if (std.mem.indexOfScalar(u8, param, '=')) |eq_idx| {
                const encoded_key = param[0..eq_idx];
                const encoded_value = param[eq_idx + 1 ..];

                // URL decode key and value per RFC 3986
                const key = try urlDecode(encoded_key, arena);
                const value = try urlDecode(encoded_value, arena);

                try query_map.put(key, value);
            } else if (param.len > 0) {
                // Parameter without value (e.g., ?flag)
                const key = try urlDecode(param, arena);
                try query_map.put(key, "");
            }
        }
    }

    /// URL decode a string per RFC 3986
    fn urlDecode(encoded: []const u8, arena: std.mem.Allocator) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(arena, encoded.len);
        // TODO: Perf - Fast-path strings without escapes to return the original slice and skip allocation.
        var i: usize = 0;

        while (i < encoded.len) {
            const c = encoded[i];
            if (c == '%') {
                // Percent-encoded sequence: %XX
                if (i + 2 >= encoded.len) {
                    return error.InvalidPercentEncoding;
                }
                const hex1 = encoded[i + 1];
                const hex2 = encoded[i + 2];

                // Convert hex digits to byte
                const high = try std.fmt.charToDigit(hex1, 16);
                const low = try std.fmt.charToDigit(hex2, 16);
                const byte = @as(u8, @intCast(high * 16 + low));

                try result.append(arena, byte);
                i += 3;
            } else if (c == '+') {
                // In query strings, + represents space
                try result.append(arena, ' ');
                i += 1;
            } else {
                // Regular character
                try result.append(arena, c);
                i += 1;
            }
        }

        return result.items;
    }

    /// Validate and normalize URI per RFC 9110 Section 4.2.3, 4.2.4
    fn validateAndNormalizeUri(self: *Server, uri: []const u8, arena: std.mem.Allocator) ![]const u8 {
        _ = self;
        // RFC 9110 Section 4.2.3 - Reject userinfo in URI
        // Check for userinfo pattern: scheme://user:pass@host/path
        if (std.mem.indexOf(u8, uri, "://")) |scheme_end| {
            const after_scheme = uri[scheme_end + 3 ..];
            if (std.mem.indexOfScalar(u8, after_scheme, '@')) |at_pos| {
                // Check if there's a colon before @ (indicating user:pass format)
                const userinfo_part = after_scheme[0..at_pos];
                if (std.mem.indexOfScalar(u8, userinfo_part, ':')) |_| {
                    return error.UserinfoNotAllowed;
                }
            }
        }

        // RFC 9110 Section 4.2.4 - Path normalization
        // For HTTP/1.1, clients are expected to send normalized paths
        // Basic validation: path should start with / or be * for OPTIONS
        if (uri.len == 0) {
            return error.InvalidUri;
        }

        if (std.mem.indexOfScalar(u8, uri, '#') != null) {
            return error.InvalidUri;
        }

        if (uri.len >= 2 and uri[0] == '/' and uri[1] == '/') {
            return error.InvalidUri;
        }

        // Allow asterisk-form for OPTIONS
        if (std.mem.eql(u8, uri, "*")) {
            return uri;
        }

        // For origin-form and absolute-form, path should be absolute
        if (!std.mem.startsWith(u8, uri, "/")) {
            // Check if it's an absolute URI (has scheme)
            if (!std.mem.containsAtLeast(u8, uri, 1, "://")) {
                return error.InvalidUri;
            }
        }

        var normalized = uri;

        if (std.mem.indexOf(u8, uri, "://")) |scheme_idx| {
            const scheme = uri[0..scheme_idx];
            if (!std.ascii.eqlIgnoreCase(scheme, "http")) {
                return error.InvalidUri;
            }

            const after_scheme = uri[scheme_idx + 3 ..];
            if (after_scheme.len == 0) {
                return error.InvalidUri;
            }

            var suffix_start = after_scheme.len;

            if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash_idx| {
                suffix_start = slash_idx;
            }

            if (std.mem.indexOfScalar(u8, after_scheme, '?')) |query_idx| {
                if (query_idx < suffix_start) {
                    suffix_start = query_idx;
                }
            }

            const authority = after_scheme[0..suffix_start];
            if (authority.len == 0) {
                return error.InvalidUri;
            }

            const suffix = if (suffix_start < after_scheme.len) after_scheme[suffix_start..] else "";
            const needs_leading_slash = !(suffix.len > 0 and suffix[0] == '/');

            const normalized_len = suffix.len + (if (needs_leading_slash) @as(usize, 1) else 0);
            var buffer = try arena.alloc(u8, normalized_len);

            if (needs_leading_slash) {
                buffer[0] = '/';
            }

            if (suffix.len > 0) {
                const copy_start: usize = if (needs_leading_slash) 1 else 0;
                const dest = buffer[copy_start .. copy_start + suffix.len];
                @memcpy(dest, suffix);
            }

            normalized = buffer;
        }

        if (!std.mem.startsWith(u8, normalized, "/")) {
            return error.InvalidUri;
        }

        var i: usize = 0;
        while (i < normalized.len) : (i += 1) {
            if (normalized[i] == '%') {
                if (i + 2 >= normalized.len) {
                    return error.InvalidPercentEncoding;
                }

                const h1 = normalized[i + 1];
                const h2 = normalized[i + 2];
                _ = std.fmt.charToDigit(h1, 16) catch return error.InvalidPercentEncoding;
                _ = std.fmt.charToDigit(h2, 16) catch return error.InvalidPercentEncoding;

                i += 2;
            }
        }

        return normalized;
    }

    fn validateAuthorityForm(self: *Server, authority: []const u8) !void {
        _ = self;

        if (authority.len == 0) {
            return error.InvalidUri;
        }

        if (std.mem.indexOfScalar(u8, authority, '#') != null or std.mem.indexOfScalar(u8, authority, '?') != null) {
            return error.InvalidUri;
        }

        for (authority) |ch| {
            if (ch <= 0x20 or ch == 0x7f) {
                return error.InvalidUri;
            }
        }

        var host_slice: []const u8 = undefined;
        var port_slice: []const u8 = undefined;

        if (authority[0] == '[') {
            const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUri;
            if (closing == 1) {
                return error.InvalidUri;
            }

            host_slice = authority[1..closing];

            if (closing + 1 >= authority.len or authority[closing + 1] != ':') {
                return error.InvalidUri;
            }

            port_slice = authority[closing + 2 ..];
        } else {
            const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidUri;
            if (colon == 0) {
                return error.InvalidUri;
            }

            host_slice = authority[0..colon];
            port_slice = authority[colon + 1 ..];
        }

        if (port_slice.len == 0) {
            return error.InvalidUri;
        }

        if (host_slice.len == 0) {
            return error.InvalidUri;
        }

        _ = std.fmt.parseInt(u16, port_slice, 10) catch return error.InvalidUri;
    }

    fn validateHeaderFieldName(name: []const u8) !void {
        if (name.len == 0) return error.InvalidHeaderFieldName;
        for (name) |ch| {
            if (!isTchar(ch)) {
                return error.InvalidHeaderFieldName;
            }
        }
    }

    fn isTchar(ch: u8) bool {
        return switch (ch) {
            '0'...'9', 'A'...'Z', 'a'...'z', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
    }

    /// Determine if connection should be kept alive per RFC 9112 Section 9
    fn shouldKeepAlive(self: *Server, headers: std.StringHashMap(std.ArrayList([]const u8))) bool {
        _ = self;

        // RFC 9112 Section 9.3 - HTTP/1.1 connections are persistent by default
        // unless Connection header contains "close"
        if (headers.get("connection")) |connection_values| {
            for (connection_values.items) |value| {
                // Connection values are comma-separated and case-insensitive
                var it = std.mem.splitSequence(u8, value, ",");
                while (it.next()) |token| {
                    const trimmed = std.mem.trim(u8, token, " \t");
                    if (std.ascii.eqlIgnoreCase(trimmed, "close")) {
                        return false;
                    }
                }
            }
        }

        // Default for HTTP/1.1 is keep-alive
        return true;
    }

    /// Render a successful response.
    fn renderResponse(
        self: *Server,
        ctx: *ctx_module.CtxBase,
        telemetry_ctx: *telemetry.Telemetry,
        decision: types.Decision,
        outcome: telemetry.RequestOutcome,
        arena: std.mem.Allocator,
        keep_alive: bool,
        correlation: CorrelationContext,
    ) !ResponseResult {
        const response = switch (decision) {
            .Continue => types.Response{ .status = http_status.ok, .body = .{ .complete = "OK" } },
            .Done => |resp| resp,
            .Fail => |err| {
                slog.debug("Decision failed", &.{
                    slog.Attr.int("status", @intCast(err.kind)),
                    slog.Attr.string("what", err.ctx.what),
                    slog.Attr.string("key", err.ctx.key),
                });
                return self.renderError(ctx, telemetry_ctx, err, outcome, arena, keep_alive, correlation);
            },
            .need => types.Response{ .status = http_status.internal_server_error, .body = .{ .complete = "Pipeline incomplete" } },
        };

        ctx.runExitCallbacks();

        const response_metrics = telemetry.Telemetry.responseMetricsFromResponse(response);
        telemetry_ctx.recordResponseMetrics(response_metrics);

        var final_outcome = outcome;
        final_outcome.status_code = response.status;
        const trace_header = telemetry_ctx.finish(final_outcome, arena) catch "";

        switch (response.body) {
            .complete => |body| {
                slog.debug("Rendering response", &.{
                    slog.Attr.int("status", @intCast(response.status)),
                    slog.Attr.int("body_len", @intCast(body.len)),
                });
            },
            .streaming => {
                slog.debug("Rendering streaming response", &.{
                    slog.Attr.int("status", @intCast(response.status)),
                });
            },
        }

        const is_head = std.mem.eql(u8, ctx.method_str, "HEAD");

        switch (response.body) {
            .streaming => |streaming| {
                if (is_head) {
                    const headers_only = try self.httpResponse(.{
                        .status = response.status,
                        .headers = response.headers,
                        .body = .{ .complete = "" },
                    }, arena, true, keep_alive, trace_header, correlation);

                    return ResponseResult{ .complete = headers_only };
                }

                const headers_only = try self.httpResponse(.{
                    .status = response.status,
                    .headers = response.headers,
                    .body = .{ .complete = "" },
                }, arena, false, keep_alive, trace_header, correlation);

                return ResponseResult{
                    .streaming = .{
                        .headers = headers_only,
                        .writer = streaming.writer,
                        .context = streaming.context,
                    },
                };
            },
            .complete => {
                const formatted = try self.httpResponse(response, arena, is_head, keep_alive, trace_header, correlation);
                return ResponseResult{ .complete = formatted };
            },
        }
    }

    fn renderError(
        self: *Server,
        ctx: *ctx_module.CtxBase,
        telemetry_ctx: *telemetry.Telemetry,
        _err: types.Error,
        outcome: telemetry.RequestOutcome,
        arena: std.mem.Allocator,
        keep_alive: bool,
        correlation: CorrelationContext,
    ) !ResponseResult {
        ctx.last_error = _err;
        const response = try self.config.on_error(ctx);
        const is_head = std.mem.eql(u8, ctx.method_str, "HEAD");

        var final_response = types.Response{ .status = http_status.internal_server_error, .body = .{ .complete = "Error" } };

        switch (response) {
            .Continue => {},
            .Done => |resp| final_response = resp,
            else => {},
        }

        ctx.runExitCallbacks();

        const response_metrics = telemetry.Telemetry.responseMetricsFromResponse(final_response);
        telemetry_ctx.recordResponseMetrics(response_metrics);

        var final_outcome = outcome;
        final_outcome.status_code = final_response.status;
        const trace_header = telemetry_ctx.finish(final_outcome, arena) catch "";

        return ResponseResult{ .complete = try self.httpResponse(final_response, arena, is_head, keep_alive, trace_header, correlation) };
    }

    /// Parse chunked transfer encoding per RFC 9112 Section 6
    fn parseChunkedBody(
        self: *Server,
        raw_body: []const u8,
        arena: std.mem.Allocator,
        headers: *std.StringHashMap(std.ArrayList([]const u8)),
        allowed_trailers: ?*std.StringHashMap(void),
    ) ![]const u8 {
        _ = self;

        var result = try std.ArrayList(u8).initCapacity(arena, 0);
        var pos: usize = 0;
        var saw_final_chunk = false;

        while (pos < raw_body.len) {
            const line_end = std.mem.indexOfPos(u8, raw_body, pos, "\r\n") orelse return error.InvalidChunkedEncoding;
            const chunk_size_line = raw_body[pos..line_end];

            var size_section = chunk_size_line;
            if (std.mem.indexOfScalar(u8, chunk_size_line, ';')) |semicolon_pos| {
                size_section = chunk_size_line[0..semicolon_pos];
            }

            const size_str = std.mem.trim(u8, size_section, " \t");
            if (size_str.len == 0) return error.InvalidChunkedEncoding;
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

            pos = line_end + 2;

            if (chunk_size == 0) {
                var saw_final_blank = false;

                while (true) {
                    const trailer_end = std.mem.indexOfPos(u8, raw_body, pos, "\r\n") orelse return error.InvalidChunkedEncoding;
                    const trailer_line = raw_body[pos..trailer_end];
                    pos = trailer_end + 2;

                    if (trailer_line.len == 0) {
                        saw_final_blank = true;
                        break;
                    }

                    const colon_idx = std.mem.indexOfScalar(u8, trailer_line, ':') orelse return error.InvalidChunkedEncoding;

                    const name_raw = trailer_line[0..colon_idx];
                    const name_trimmed = std.mem.trim(u8, name_raw, " \t");
                    if (name_trimmed.len == 0 or name_trimmed.len != name_raw.len) {
                        return error.InvalidChunkedEncoding;
                    }
                    try validateHeaderFieldName(name_trimmed);
                    const name_lower = try std.ascii.allocLowerString(arena, name_trimmed);

                    if (allowed_trailers) |allowed| {
                        if (!allowed.contains(name_lower)) {
                            return error.TrailerFieldNotDeclared;
                        }
                    }

                    const value_raw = trailer_line[colon_idx + 1 ..];
                    const value_trimmed = std.mem.trim(u8, value_raw, " \t");
                    const value_dup = try arena.dupe(u8, value_trimmed);

                    const gop = try headers.getOrPut(name_lower);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = try std.ArrayList([]const u8).initCapacity(arena, 1);
                    }
                    try gop.value_ptr.append(arena, value_dup);
                }

                if (!saw_final_blank) return error.InvalidChunkedEncoding;
                if (pos != raw_body.len) return error.InvalidChunkedEncoding;
                saw_final_chunk = true;
                break;
            }

            if (pos + chunk_size + 2 > raw_body.len) {
                return error.InvalidChunkedEncoding;
            }

            const chunk_data = raw_body[pos .. pos + chunk_size];
            try result.appendSlice(arena, chunk_data);

            if (pos + chunk_size + 2 > raw_body.len or !std.mem.eql(u8, raw_body[pos + chunk_size .. pos + chunk_size + 2], "\r\n")) {
                return error.InvalidChunkedEncoding;
            }

            pos += chunk_size + 2;
        }

        if (!saw_final_chunk or pos != raw_body.len) {
            return error.InvalidChunkedEncoding;
        }

        return result.items;
    }

    /// Format timestamp as HTTP date (IMF-fixdate format per RFC 9110 Section 5.6.7)
    fn formatHttpDate(arena: std.mem.Allocator, timestamp: i64) ![]const u8 {
        std.debug.assert(timestamp >= 0);

        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const calendar = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        const weekday_index = @as(usize, @intCast(@mod(epoch_day.day + 4, 7)));
        const month_index = @as(usize, @intCast(@intFromEnum(calendar.month)));

        return std.fmt.allocPrint(arena, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            day_names[weekday_index],
            calendar.day_index + 1,
            month_names[month_index],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    fn httpResponse(
        self: *Server,
        response: types.Response,
        arena: std.mem.Allocator,
        is_head: bool,
        keep_alive: bool,
        trace_header: []const u8,
        correlation: ?CorrelationContext,
    ) ![]const u8 {
        _ = self;

        var buf = std.ArrayList(u8).initCapacity(arena, 512) catch unreachable;
        const w = buf.writer(arena);

        // Get status text - RFC 9110 Section 15
        const status_text = switch (response.status) {
            // 1xx Informational
            100 => "Continue",
            101 => "Switching Protocols",
            102 => "Processing",

            // 2xx Successful
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            203 => "Non-Authoritative Information",
            204 => "No Content",
            205 => "Reset Content",
            206 => "Partial Content",
            207 => "Multi-Status",
            208 => "Already Reported",
            226 => "IM Used",

            // 3xx Redirection
            300 => "Multiple Choices",
            301 => "Moved Permanently",
            302 => "Found",
            303 => "See Other",
            304 => "Not Modified",
            305 => "Use Proxy",
            307 => "Temporary Redirect",
            308 => "Permanent Redirect",

            // 4xx Client Error
            400 => "Bad Request",
            401 => "Unauthorized",
            402 => "Payment Required",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            406 => "Not Acceptable",
            407 => "Proxy Authentication Required",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            411 => "Length Required",
            412 => "Precondition Failed",
            413 => "Payload Too Large",
            414 => "URI Too Long",
            415 => "Unsupported Media Type",
            416 => "Range Not Satisfiable",
            417 => "Expectation Failed",
            418 => "I'm a teapot",
            421 => "Misdirected Request",
            422 => "Unprocessable Entity",
            423 => "Locked",
            424 => "Failed Dependency",
            425 => "Too Early",
            426 => "Upgrade Required",
            428 => "Precondition Required",
            429 => "Too Many Requests",
            431 => "Request Header Fields Too Large",
            451 => "Unavailable For Legal Reasons",

            // 5xx Server Error
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            505 => "HTTP Version Not Supported",
            506 => "Variant Also Negotiates",
            507 => "Insufficient Storage",
            508 => "Loop Detected",
            510 => "Not Extended",
            511 => "Network Authentication Required",

            else => "OK", // Default fallback
        };

        try w.print("HTTP/1.1 {} {s}\r\n", .{ response.status, status_text });

        const status = response.status;
        const send_date = !((status >= 100 and status < 200) or status == 204 or status == 304);
        if (send_date and !headerExists(response.headers, "Date")) {
            const now_raw = std.time.timestamp();
            const now = @as(i64, @intCast(now_raw));
            const date_str = try formatHttpDate(arena, now);
            try w.print("Date: {s}\r\n", .{date_str});
        }

        // RFC 9110 Section 10.2.4 - Include Server header if not already present
        if (!headerExists(response.headers, "Server")) {
            try w.print("Server: Zerver/1.0\r\n", .{});
        }

        // RFC 9112 Section 9 - Include Connection header
        if (keep_alive) {
            try w.print("Connection: keep-alive\r\n", .{});
        } else {
            try w.print("Connection: close\r\n", .{});
        }

        if (trace_header.len > 0) {
            try w.print("X-Zerver-Trace: {s}\r\n", .{trace_header});
        }

        if (correlation) |ctx_corr| {
            if (ctx_corr.header_name.len != 0 and ctx_corr.header_value.len != 0 and
                !headerExists(response.headers, ctx_corr.header_name))
            {
                try w.print("{s}: {s}\r\n", .{ ctx_corr.header_name, ctx_corr.header_value });
            }
        }

        if (!headerExists(response.headers, "Content-Language")) {
            try w.print("Content-Language: en\r\n", .{});
        }

        if (!headerExists(response.headers, "Vary")) {
            try w.print("Vary: Accept, Accept-Encoding, Accept-Charset, Accept-Language\r\n", .{});
        }

        // Add custom headers from the response
        for (response.headers) |header| {
            if (!send_date and std.ascii.eqlIgnoreCase(header.name, "date")) continue;
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        // Handle different response body types
        switch (response.body) {
            .complete => |body| {
                // For complete responses, add Content-Length unless it's SSE
                const is_sse = response.status == 200 and
                    blk: {
                        for (response.headers) |header| {
                            if (std.ascii.eqlIgnoreCase(header.name, "content-type") and
                                std.mem.eql(u8, header.value, "text/event-stream"))
                            {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };

                if (!is_sse) {
                    const has_custom_content_length = headerExists(response.headers, "Content-Length");
                    if (!has_custom_content_length) {
                        try w.print("Content-Length: {d}\r\n", .{body.len});
                    }
                }

                try w.print("\r\n", .{});

                // RFC 9110 Section 9.3.2 - HEAD responses must not include a message body
                if (!is_head) {
                    try w.writeAll(body);
                }
            },
            .streaming => |streaming| {
                // For streaming responses (SSE), never send Content-Length
                try w.print("\r\n", .{});

                // For SSE, we don't write the body here - it will be streamed later
                // The streaming writer will be called by the handler
                _ = streaming;
            },
        }

        // RFC 9110 Section 9.3.2 - HEAD responses omit bodies; handlers can supply Content-Length for the corresponding GET representation.

        return buf.items;
    }

    fn headerExists(headers: []const types.Header, name: []const u8) bool {
        for (headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return true;
            }
        }
        return false;
    }

    fn resolveCorrelation(
        self: *Server,
        headers: std.StringHashMap(std.ArrayList([]const u8)),
        arena: std.mem.Allocator,
    ) !CorrelationContext {
        if (self.tryTraceparent(headers, arena)) |ctx| return ctx;
        if (self.tryCorrelationHeader(headers, arena, "x-request-id", .x_request_id)) |ctx| return ctx;
        if (self.tryCorrelationHeader(headers, arena, "x-correlation-id", .x_correlation_id)) |ctx| return ctx;
        return try self.generateCorrelation(arena);
    }

    fn tryTraceparent(
        self: *Server,
        headers: std.StringHashMap(std.ArrayList([]const u8)),
        arena: std.mem.Allocator,
    ) ?CorrelationContext {
        _ = self;
        const values = headers.get("traceparent") orelse return null;
        if (values.items.len == 0) return null;
        const raw = std.mem.trim(u8, values.items[0], " \t");
        if (raw.len == 0) return null;

        if (parseTraceparent(arena, raw)) |parsed| {
            return CorrelationContext{
                .id = parsed.trace_id,
                .header_name = "traceparent",
                .header_value = parsed.header_value,
                .source = .traceparent,
            };
        }

        return null;
    }

    fn tryCorrelationHeader(
        self: *Server,
        headers: std.StringHashMap(std.ArrayList([]const u8)),
        arena: std.mem.Allocator,
        name: []const u8,
        source: CorrelationSource,
    ) ?CorrelationContext {
        _ = self;
        const values = headers.get(name) orelse return null;
        if (values.items.len == 0) return null;
        const raw = std.mem.trim(u8, values.items[0], " \t");
        if (raw.len == 0) return null;

        const owned = arena.dupe(u8, raw) catch return null;
        const value_slice: []const u8 = owned;

        return CorrelationContext{
            .id = value_slice,
            .header_name = name,
            .header_value = value_slice,
            .source = source,
        };
    }

    fn generateCorrelation(self: *Server, arena: std.mem.Allocator) !CorrelationContext {
        _ = self;
        var entropy: [16]u8 = undefined;
        std.crypto.random.bytes(&entropy);

        const entropy_value = std.mem.bytesToValue(u128, &entropy);
        var buf: [32]u8 = undefined;
        const id_slice = std.fmt.bufPrint(&buf, "{x:0>32}", .{entropy_value}) catch unreachable;
        const owned = try arena.dupe(u8, id_slice);
        const id_value: []const u8 = owned;

        return CorrelationContext{
            .id = id_value,
            .header_name = "x-request-id",
            .header_value = id_value,
            .source = .generated,
        };
    }

    const TraceparentParts = struct {
        trace_id: []const u8,
        header_value: []const u8,
    };

    fn parseTraceparent(arena: std.mem.Allocator, value: []const u8) ?TraceparentParts {
        var parts = std.mem.splitScalar(u8, value, '-');
        const version = parts.next() orelse return null;
        const trace_id = parts.next() orelse return null;
        const span_id = parts.next() orelse return null;
        const flags = parts.next() orelse return null;
        if (parts.next() != null) return null;

        if (version.len != 2 or trace_id.len != 32 or span_id.len != 16 or flags.len != 2) return null;
        if (!isHexSlice(version) or !isHexSlice(trace_id) or !isHexSlice(span_id) or !isHexSlice(flags)) return null;
        if (std.mem.allEqual(u8, trace_id, '0') or std.mem.allEqual(u8, span_id, '0')) return null;

        const header_value_owned = arena.dupe(u8, value) catch return null;
        const trace_id_owned = arena.dupe(u8, trace_id) catch return null;

        return TraceparentParts{
            .trace_id = @as([]const u8, trace_id_owned),
            .header_value = @as([]const u8, header_value_owned),
        };
    }

    fn isHexSlice(value: []const u8) bool {
        for (value) |c| {
            const is_digit = c >= '0' and c <= '9';
            const is_lower = c >= 'a' and c <= 'f';
            const is_upper = c >= 'A' and c <= 'F';
            if (!(is_digit or is_lower or is_upper)) return false;
        }
        return true;
    }

    /// Get allowed methods for a given path (RFC 9110 Section 9.3.7)
    fn getAllowedMethods(self: *Server, path: []const u8, arena: std.mem.Allocator) ![]const u8 {
        var allowed = try std.ArrayList(u8).initCapacity(arena, 64);

        // Check each method to see if there's a route for it
        const methods = [_]types.Method{ .GET, .HEAD, .POST, .PUT, .DELETE, .PATCH, .OPTIONS };
        // CONNECT and TRACE (RFC 9110 Sections 9.3.6, 9.3.8) demand bespoke behaviors, so we intentionally omit them from the generic Allow synthesis.

        for (methods) |method| {
            var match_found = self.router.match(method, path, arena) catch null;
            if (match_found == null and method == .HEAD) {
                match_found = self.router.match(.GET, path, arena) catch null;
            }

            if (match_found != null) {
                if (allowed.items.len > 0) try allowed.appendSlice(arena, ", ");
                const method_str = switch (method) {
                    .GET => "GET",
                    .HEAD => "HEAD",
                    .POST => "POST",
                    .PUT => "PUT",
                    .DELETE => "DELETE",
                    .PATCH => "PATCH",
                    .OPTIONS => "OPTIONS",
                    else => continue,
                };
                try allowed.appendSlice(arena, method_str);
            }
        }

        // Always allow OPTIONS
        if (allowed.items.len == 0) {
            try allowed.appendSlice(arena, "OPTIONS");
        } else if (!std.mem.containsAtLeast(u8, allowed.items, 1, "OPTIONS")) {
            try allowed.appendSlice(arena, ", OPTIONS");
        }

        return allowed.items;
    }

    /// Start listening for HTTP requests (blocking).
    pub fn listen(self: *Server) !void {
        var ip_buf: [32]u8 = undefined;
        const ip_str = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
            self.config.addr.ip[0],
            self.config.addr.ip[1],
            self.config.addr.ip[2],
            self.config.addr.ip[3],
        }) catch "0.0.0.0";

        const listen_addr = std.net.Address.initIp4(self.config.addr.ip, self.config.addr.port);
        var listener = try listen_addr.listen(.{ .reuse_address = true });
        defer listener.deinit();

        slog.info("Server ready for HTTP requests", &.{
            slog.Attr.string("host", ip_str),
            slog.Attr.int("port", @as(i64, @intCast(self.config.addr.port))),
            slog.Attr.string("status", "running"),
        });

        while (true) {
            const connection = listener.accept() catch |err| {
                slog.err("Failed to accept connection", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            };

            slog.info("Accepted new connection", &.{});

            self.handleConnection(connection) catch |err| {
                slog.err("Connection handling failed", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        const keep_alive_timeout_ms: i64 = 60 * 1000;
        var last_activity = std.time.milliTimestamp();

        while (true) {
            const now = std.time.milliTimestamp();
            if (now - last_activity > keep_alive_timeout_ms) {
                slog.debug("Connection idle timeout", &.{});
                return;
            }

            var request_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer request_arena.deinit();

            const request_bytes = net_handler.readRequestWithTimeout(
                connection,
                request_arena.allocator(),
                5000,
            ) catch |err| {
                switch (err) {
                    error.Timeout, error.ConnectionClosed => {
                        slog.debug("Request read timeout or connection closed", &.{});
                        return;
                    },
                    else => {
                        slog.err("Failed to read request", &.{
                            slog.Attr.string("error", @errorName(err)),
                        });
                        return;
                    },
                }
            };

            if (request_bytes.len == 0) {
                slog.debug("Received empty request", &.{});
                return;
            }

            last_activity = std.time.milliTimestamp();

            const preview_len = @min(request_bytes.len, 120);
            slog.info("Received HTTP request", &.{
                slog.Attr.uint("bytes", request_bytes.len),
                slog.Attr.string("preview", request_bytes[0..preview_len]),
            });

            if (request_bytes.len > 0) {
                const line_end = std.mem.indexOf(u8, request_bytes, "\r\n") orelse request_bytes.len;
                const request_line = request_bytes[0..line_end];
                slog.info("HTTP request line", &.{
                    slog.Attr.string("line", request_line),
                });
            }

            const response_result = self.handleRequest(request_bytes, request_arena.allocator()) catch |err| {
                slog.err("Failed to handle request", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                try net_handler.sendErrorResponse(connection, "500 Internal Server Error", "Internal Server Error");
                return;
            };

            slog.info("handleRequest completed", &.{
                slog.Attr.enumeration("result", response_result),
            });

            switch (response_result) {
                .complete => |response| {
                    try net_handler.sendResponse(connection, response);
                    slog.info("Response sent successfully", &.{});
                },
                .streaming => |streaming_resp| {
                    try net_handler.sendStreamingResponse(connection, streaming_resp.headers, streaming_resp.writer, streaming_resp.context);
                    slog.info("Streaming response initiated", &.{});
                    return;
                },
            }

            const keep_alive = http_connection.shouldKeepAliveFromRaw(request_bytes);
            if (!keep_alive) {
                slog.info("Connection close requested by client", &.{});
                return;
            }

            slog.info("Keeping connection alive for next request", &.{});
        }
    }
};
