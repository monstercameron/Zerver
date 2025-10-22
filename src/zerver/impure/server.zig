/// Server: HTTP listener, routing, request handling.
const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const router_module = @import("../routes/router.zig");
const executor_module = @import("executor.zig");
const tracer_module = @import("../observability/tracer.zig");
const slog = @import("../observability/slog.zig");

pub const Address = struct {
    ip: [4]u8,
    port: u16,
};

pub const Config = struct {
    addr: Address,
    on_error: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
    debug: bool = false,
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
            .status = 200,
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
        effect_handler: *const fn (*const types.Effect, u32) anyerror!executor_module.EffectResult,
    ) !Server {
        return Server{
            .allocator = allocator,
            .config = cfg,
            .router = router_module.Router.init(allocator),
            .executor = executor_module.Executor.init(allocator, effect_handler),
            .flows = try std.ArrayList(Flow).initCapacity(allocator, 16),
            .global_before = try std.ArrayList(types.Step).initCapacity(allocator, 8),
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
        tracer: *tracer_module.Tracer,
        before_steps: []const types.Step,
        main_steps: []const types.Step,
    ) !types.Decision {
        // Execute global before chain
        for (self.global_before.items) |before_step| {
            tracer.recordStepStart(before_step.name);
            const decision = try self.executor.executeStepWithTracer(ctx_base, before_step.call, tracer);
            tracer.recordStepEnd(before_step.name, @tagName(decision));
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute route-specific before chain
        for (before_steps) |before_step| {
            tracer.recordStepStart(before_step.name);
            const decision = try self.executor.executeStepWithTracer(ctx_base, before_step.call, tracer);
            tracer.recordStepEnd(before_step.name, @tagName(decision));
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute main steps
        for (main_steps) |main_step| {
            tracer.recordStepStart(main_step.name);
            const decision = try self.executor.executeStepWithTracer(ctx_base, main_step.call, tracer);
            tracer.recordStepEnd(main_step.name, @tagName(decision));
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
        // Create tracer for this request
        var tracer = tracer_module.Tracer.init(arena);
        defer tracer.deinit();

        tracer.recordRequestStart();

        // Parse the HTTP request (simplified)
        const parsed = self.parseRequest(request_text, arena) catch |err| {
            // Handle parsing errors
            switch (err) {
                error.MissingHostHeader => {
                    // RFC 9110 Section 7.2 - Missing Host header in HTTP/1.1
                    tracer.recordRequestEnd();
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = 400,
                        .body = .{ .complete = "Bad Request: Missing Host header (required for HTTP/1.1)" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = "text/plain" },
                        },
                    }, &tracer, arena, false, false) };
                },
                error.InvalidRequest, error.InvalidMethod, error.UnsupportedVersion, error.InvalidUri, error.UserinfoNotAllowed => {
                    tracer.recordRequestEnd();
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = 400,
                        .body = .{ .complete = "Bad Request" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = "text/plain" },
                        },
                    }, &tracer, arena, false, false) };
                },
                error.MultipleContentLength, error.InvalidContentLength, error.ContentLengthMismatch, error.UnexpectedBody, error.ContentLengthRequired, error.InvalidPercentEncoding => {
                    // RFC 9110 Section 6 - Message body framing errors and RFC 3986 - URL decoding errors
                    tracer.recordRequestEnd();
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = 400,
                        .body = .{ .complete = "Bad Request: Invalid request format" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = "text/plain" },
                        },
                    }, &tracer, arena, false, false) };
                },
                else => {
                    tracer.recordRequestEnd();
                    return ResponseResult{ .complete = try self.httpResponse(.{
                        .status = 500,
                        .body = .{ .complete = "Internal Server Error" },
                        .headers = &[_]types.Header{
                            .{ .name = "Content-Type", .value = "text/plain" },
                        },
                    }, &tracer, arena, false, false) };
                },
            }
        };

        // Create request context
        var ctx = try ctx_module.CtxBase.init(arena);
        defer ctx.deinit();

        // Populate context with parsed request data
        ctx.method_str = try self.methodToString(parsed.method, arena);
        ctx.path_str = parsed.path;
        ctx.body = parsed.body;

        // Copy headers to context
        var header_iter = parsed.headers.iterator();
        while (header_iter.next()) |entry| {
            // RFC 9110 Section 5.3 - Combine multiple values with comma
            if (entry.value_ptr.items.len == 1) {
                try ctx.headers.put(entry.key_ptr.*, entry.value_ptr.items[0]);
            } else {
                // Combine multiple values with comma separator
                var combined = try std.ArrayList(u8).initCapacity(arena, 64);
                for (entry.value_ptr.items, 0..) |value, i| {
                    if (i > 0) try combined.appendSlice(arena, ", ");
                    try combined.appendSlice(arena, value);
                }
                try ctx.headers.put(entry.key_ptr.*, combined.items);
            }
        }

        // Copy query parameters to context (parsed.query is currently empty due to TODO)
        var query_iter = parsed.query.iterator();
        while (query_iter.next()) |entry| {
            try ctx.query.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // RFC 9110 Section 9.3.7 - Handle OPTIONS method
        if (parsed.method == .OPTIONS) {
            tracer.recordStepStart("options_handler");

            // Determine allowed methods for this path
            const allowed_methods = try self.getAllowedMethods(parsed.path, arena);

            tracer.recordStepEnd("options_handler", "Continue");

            const response_body = try std.fmt.allocPrint(arena, "Allow: {s}", .{allowed_methods});
            const keep_alive = self.shouldKeepAlive(parsed.headers);
            return ResponseResult{ .complete = try self.httpResponse(.{
                .status = 200,
                .body = .{ .complete = response_body },
                .headers = &[_]types.Header{
                    .{ .name = "Allow", .value = allowed_methods },
                },
            }, &tracer, arena, false, keep_alive) };
        }

        // Try to match route
        if (try self.router.match(parsed.method, parsed.path, arena)) |route_match| {
            tracer.recordStepStart("route_match");

            // Copy route parameters into context
            var param_iter = route_match.params.iterator();
            while (param_iter.next()) |entry| {
                try ctx.params.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            tracer.recordStepEnd("route_match", "Continue");

            // Execute the pipeline
            const decision = try self.executePipeline(&ctx, &tracer, route_match.spec.before, route_match.spec.steps);

            tracer.recordRequestEnd();

            // Render response based on decision
            const keep_alive = self.shouldKeepAlive(parsed.headers);
            return try self.renderResponse(&ctx, decision, &tracer, arena, keep_alive);
        }

        // Try to match flow (if method is POST to /flow/v1/<slug>)
        if (parsed.method == .POST and std.mem.startsWith(u8, parsed.path, "/flow/v1/")) {
            const slug = parsed.path[9..]; // Remove "/flow/v1/"

            for (self.flows.items) |flow| {
                if (std.mem.eql(u8, flow.slug, slug)) {
                    tracer.recordStepStart("flow_match");
                    tracer.recordStepEnd("flow_match", "Continue");

                    const decision = try self.executePipeline(&ctx, &tracer, flow.spec.before, flow.spec.steps);

                    tracer.recordRequestEnd();

                    const keep_alive = self.shouldKeepAlive(parsed.headers);
                    return try self.renderResponse(&ctx, decision, &tracer, arena, keep_alive);
                }
            }
        }

        // No route matched: 404
        tracer.recordRequestEnd();
        const keep_alive = self.shouldKeepAlive(parsed.headers);
        return self.renderError(&ctx, .{
            .kind = types.ErrorCode.NotFound,
            .ctx = .{ .what = "routing", .key = parsed.path },
        }, &tracer, arena, keep_alive);
    }

    /// Parse an HTTP request (MVP: very simplified).
    fn parseRequest(self: *Server, text: []const u8, arena: std.mem.Allocator) !ParsedRequest {
        var lines = std.mem.splitSequence(u8, text, "\r\n");

        // Parse request line: "GET /path HTTP/1.1"
        const request_line = lines.next() orelse return error.InvalidRequest;
        var request_parts = std.mem.splitSequence(u8, request_line, " ");

        const method_str = request_parts.next() orelse return error.InvalidRequest;
        const path_str = request_parts.next() orelse return error.InvalidRequest;
        const version_str = request_parts.next() orelse return error.InvalidRequest;

        // RFC 9110 Section 2.5 - Parse and validate HTTP version
        if (!std.mem.eql(u8, version_str, "HTTP/1.1")) {
            return error.UnsupportedVersion;
        }

        const method = try self.parseMethod(method_str);
        const path_with_query = try arena.dupe(u8, path_str);

        // RFC 9110 Section 4.2.3, 4.2.4 - Validate and normalize URI
        try self.validateAndNormalizeUri(path_with_query);

        // Parse path and query string
        var path = path_with_query;
        var query = std.StringHashMap([]const u8).init(arena);

        if (std.mem.indexOfScalar(u8, path_with_query, '?')) |query_start| {
            path = path_with_query[0..query_start];
            const query_str = path_with_query[query_start + 1 ..];
            try self.parseQueryString(query_str, &query, arena);
        }

        path = try arena.dupe(u8, path);

        // Parse headers (until empty line)
        var headers = std.StringHashMap(std.ArrayList([]const u8)).init(arena);
        while (lines.next()) |line| {
            if (line.len == 0) break; // Empty line = end of headers

            if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
                // RFC 9110 Section 5.1 - Field names are case-insensitive
                const header_name_raw = line[0..colon_idx];
                const header_name = try std.ascii.allocLowerString(arena, header_name_raw);

                // RFC 9110 Section 5.6.3 - Trim OWS (optional whitespace) around field value
                const header_value_raw = line[colon_idx + 1 ..];
                const header_value = std.mem.trim(u8, header_value_raw, " \t");
                // TODO: RFC 9110 Section 5.5, 5.6 - Implement full parsing of HTTP header field values, including quoted strings, comments, and specific ABNF rules for various header types.

                // RFC 9110 Section 5.3 - Multiple header fields with same name
                // Get or create the list for this header name
                const gop = try headers.getOrPut(header_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try std.ArrayList([]const u8).initCapacity(arena, 1);
                }
                try gop.value_ptr.append(arena, header_value);
            }
        }

        // RFC 9110 Section 7.2 - HTTP/1.1 requires Host header
        if (headers.get("host") == null) {
            return error.MissingHostHeader;
        }

        // RFC 9110 Section 6 - Parse message body with proper framing
        const body_start = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.InvalidRequest;
        const raw_body = text[body_start + 4 ..];

        // Parse Content-Length and Transfer-Encoding
        var content_length: ?usize = null;
        var has_transfer_encoding = false;

        if (headers.get("content-length")) |cl_values| {
            if (cl_values.items.len > 1) {
                return error.MultipleContentLength;
            }
            const cl_str = cl_values.items[0];
            content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        }

        if (headers.get("transfer-encoding")) |te_values| {
            // RFC 9112 Section 6 - Check for chunked encoding
            for (te_values.items) |value| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "chunked")) {
                    has_transfer_encoding = true;
                    break;
                }
            }
        }

        // RFC 9110 Section 6.4 - Validate message body framing
        var body: []const u8 = "";

        if (has_transfer_encoding) {
            // RFC 9112 Section 6 - Parse chunked encoding
            body = try self.parseChunkedBody(raw_body, arena);
        } else if (content_length) |cl| {
            // Content-Length specified - body must be exactly this length
            if (raw_body.len != cl) {
                return error.ContentLengthMismatch;
            }
            body = raw_body;
        } else {
            // No Content-Length or Transfer-Encoding
            // RFC 9110 Section 6.3 - For methods that typically don't have bodies
            if (method == .GET or method == .HEAD or method == .DELETE or method == .OPTIONS or method == .TRACE) {
                // These methods should not have bodies
                if (raw_body.len > 0) {
                    return error.UnexpectedBody;
                }
            } else {
                // For other methods (POST, PUT, PATCH), require Content-Length
                return error.ContentLengthRequired;
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
    fn validateAndNormalizeUri(self: *Server, uri: []const u8) !void {
        _ = self;
        // TODO: RFC 9110 Section 4.2.3 - Implement comprehensive URI normalization (e.g., resolving '.' and '..' segments, case normalization for scheme/host, default port omission).

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

        // Allow asterisk-form for OPTIONS
        if (std.mem.eql(u8, uri, "*")) {
            return;
        }

        // For origin-form and absolute-form, path should be absolute
        if (!std.mem.startsWith(u8, uri, "/")) {
            // Check if it's an absolute URI (has scheme)
            if (!std.mem.containsAtLeast(u8, uri, 1, "://")) {
                return error.InvalidUri;
            }
        }
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
        decision: types.Decision,
        tracer: *tracer_module.Tracer,
        arena: std.mem.Allocator,
        keep_alive: bool,
    ) !ResponseResult {
        const response = switch (decision) {
            .Continue => types.Response{ .status = 200, .body = .{ .complete = "OK" } },
            .Done => |resp| resp,
            .Fail => |err| {
                return self.renderError(ctx, err, tracer, arena, keep_alive);
            },
            .need => types.Response{ .status = 500, .body = .{ .complete = "Pipeline incomplete" } },
        };

        // Check if this is a streaming response
        switch (response.body) {
            .streaming => |streaming| {
                // For streaming responses, return headers separately
                const headers_only = try self.httpResponse(.{
                    .status = response.status,
                    .headers = response.headers,
                    .body = .{ .complete = "" }, // Empty body for headers-only
                }, tracer, arena, false, keep_alive);

                return ResponseResult{
                    .streaming = .{
                        .headers = headers_only,
                        .writer = streaming.writer,
                        .context = streaming.context,
                    },
                };
            },
            .complete => {
                // For complete responses, format normally
                const formatted = try self.httpResponse(response, tracer, arena, false, keep_alive);
                return ResponseResult{ .complete = formatted };
            },
        }
    }

    /// Render an error response.
    fn renderError(
        self: *Server,
        ctx: *ctx_module.CtxBase,
        _err: types.Error,
        tracer: *tracer_module.Tracer,
        arena: std.mem.Allocator,
        keep_alive: bool,
    ) !ResponseResult {
        // Store the error in the context for the error handler
        ctx.last_error = _err;

        // Call on_error handler
        const response = try self.config.on_error(ctx);

        // RFC 9110 Section 9.3.2 - HEAD responses are identical to GET but without message body
        const is_head = std.mem.eql(u8, ctx.method_str, "HEAD");

        return switch (response) {
            .Continue => ResponseResult{ .complete = try self.httpResponse(.{ .status = 500, .body = .{ .complete = "Error" } }, tracer, arena, is_head, keep_alive) },
            .Done => |resp| ResponseResult{ .complete = try self.httpResponse(resp, tracer, arena, is_head, keep_alive) },
            else => ResponseResult{ .complete = try self.httpResponse(.{ .status = 500, .body = .{ .complete = "Error" } }, tracer, arena, is_head, keep_alive) },
        };
    }

    /// Parse chunked transfer encoding per RFC 9112 Section 6
    fn parseChunkedBody(self: *Server, raw_body: []const u8, arena: std.mem.Allocator) ![]const u8 {
        _ = self;

        var result = try std.ArrayList(u8).initCapacity(arena, 0);
        var pos: usize = 0;

        while (pos < raw_body.len) {
            // Find the end of the chunk size line (CRLF)
            const line_end = std.mem.indexOfPos(u8, raw_body, pos, "\r\n") orelse return error.InvalidChunkedEncoding;
            const chunk_size_line = raw_body[pos..line_end];

            // Parse chunk size (hexadecimal)
            var chunk_size: usize = 0;
            var size_end: usize = 0;

            // Skip chunk extensions if present
            if (std.mem.indexOfScalar(u8, chunk_size_line, ';')) |semicolon_pos| {
                size_end = semicolon_pos;
            } else {
                size_end = chunk_size_line.len;
            }

            const size_str = std.mem.trim(u8, chunk_size_line[0..size_end], " \t");
            chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

            // Move past the chunk size line
            pos = line_end + 2;

            // If chunk size is 0, this is the last chunk
            if (chunk_size == 0) {
                // Skip trailer headers (field-line CRLF until empty line)
                // TODO: RFC 9110 Section 6.5, RFC 9112 Section 6.5 - Implement parsing and processing of Trailer Fields.
                while (pos < raw_body.len) {
                    const trailer_end = std.mem.indexOfPos(u8, raw_body, pos, "\r\n") orelse return error.InvalidChunkedEncoding;
                    if (trailer_end == pos) {
                        // Empty line after trailers
                        pos = trailer_end + 2;
                        break;
                    }
                    // Skip trailer header line
                    pos = trailer_end + 2;
                }
                break;
            }

            // Read chunk data
            if (pos + chunk_size + 2 > raw_body.len) {
                return error.InvalidChunkedEncoding;
            }

            const chunk_data = raw_body[pos .. pos + chunk_size];
            try result.appendSlice(arena, chunk_data);

            // Skip the trailing CRLF after chunk data
            pos += chunk_size + 2;
        }

        return result.items;
    }

    /// Format timestamp as HTTP date (IMF-fixdate format per RFC 9110 Section 5.6.7)
    fn formatHttpDate(arena: std.mem.Allocator, timestamp: i64) ![]const u8 {
        // Convert Unix timestamp to seconds
        const epoch_seconds = @as(u64, @intCast(timestamp));
        const epoch_time = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };

        // Get the civil time (broken down time)
        const year_and_day = epoch_time.getEpochDay().calculateYearDay();
        const civil_time = year_and_day.calculateMonthDay();
        const day_seconds = epoch_time.getDaySeconds();

        // Day names and month names
        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        // Calculate day of week using epoch day
        const epoch_day = epoch_time.getEpochDay();
        const day_of_week = @as(usize, @intCast(@mod(epoch_day.day, 7)));

        return std.fmt.allocPrint(arena, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            day_names[day_of_week],
            civil_time.day_index + 1, // day_index is 0-based, we need 1-based
            month_names[@intFromEnum(civil_time.month)],
            year_and_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    /// Format an HTTP response as text.
    fn httpResponse(
        self: *Server,
        response: types.Response,
        tracer: *tracer_module.Tracer,
        arena: std.mem.Allocator,
        is_head: bool,
        keep_alive: bool,
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

        // RFC 9110 Section 5.6.7 - Include Date header in IMF-fixdate format
        const now = std.time.timestamp();
        const date_str = try formatHttpDate(arena, now);
        try w.print("Date: {s}\r\n", .{date_str});

        // RFC 9110 Section 10.2.4 - Include Server header
        try w.print("Server: Zerver/1.0\r\n", .{});

        // RFC 9112 Section 9 - Include Connection header
        if (keep_alive) {
            try w.print("Connection: keep-alive\r\n", .{});
        } else {
            try w.print("Connection: close\r\n", .{});
        }

        // Export trace as JSON header
        const trace_json = tracer.toJson(arena) catch "";
        if (trace_json.len > 0) {
            try w.print("X-Zerver-Trace: {s}\r\n", .{trace_json});
        }

        // Add custom headers from the response
        for (response.headers) |header| {
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
                                          std.mem.eql(u8, header.value, "text/event-stream")) {
                                          break :blk true;
                                      }
                                  }
                                  break :blk false;
                              };

                if (!is_sse) {
                    try w.print("Content-Length: {d}\r\n", .{body.len});
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

        // TODO: RFC 9110 Section 9.3.2 - For HEAD responses, ensure the Content-Length header indicates the length of the content that would have been sent in a corresponding GET response.

        return buf.items;
    }

    /// Get allowed methods for a given path (RFC 9110 Section 9.3.7)
    fn getAllowedMethods(self: *Server, path: []const u8, arena: std.mem.Allocator) ![]const u8 {
        var allowed = try std.ArrayList(u8).initCapacity(arena, 64);

        // Check each method to see if there's a route for it
        const methods = [_]types.Method{ .GET, .HEAD, .POST, .PUT, .DELETE, .PATCH, .OPTIONS };

        for (methods, 0..) |method, i| {
            if (self.router.match(method, path, arena) catch null) |_| {
                if (i > 0) try allowed.appendSlice(arena, ", ");
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
        slog.info("Server starting", &.{
            slog.Attr.uint("ip0", self.config.addr.ip[0]),
            slog.Attr.uint("ip1", self.config.addr.ip[1]),
            slog.Attr.uint("ip2", self.config.addr.ip[2]),
            slog.Attr.uint("ip3", self.config.addr.ip[3]),
            slog.Attr.uint("port", self.config.addr.port),
        });

        // TODO: Phase-2: Implement actual TCP listener
        // For MVP, this is a stub that allows testing via handleRequest()
        slog.info("MVP server initialized", &.{
            slog.Attr.string("note", "requires explicit handleRequest() calls"),
            slog.Attr.string("status", "no TCP listener yet"),
        });
    }
};
