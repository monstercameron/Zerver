/// Server: HTTP listener, routing, request handling.
const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const router_module = @import("../../routes/router.zig");
const executor_module = @import("executor.zig");
const tracer_module = @import("../observability/tracer.zig");

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
    headers: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    body: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    router: router_module.Router,
    executor: executor_module.Executor,
    flows: std.ArrayList(Flow),
    global_before: std.ArrayList(types.Step),

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
        try self.global_before.appendSlice(chain);
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
        before_steps: []const types.Step,
        main_steps: []const types.Step,
    ) !types.Decision {
        // Execute global before chain
        for (self.global_before.items) |before_step| {
            const decision = try self.executor.executeStep(ctx_base, before_step.call);
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute route-specific before chain
        for (before_steps) |before_step| {
            const decision = try self.executor.executeStep(ctx_base, before_step.call);
            if (decision != .Continue) {
                return decision;
            }
        }

        // Execute main steps
        for (main_steps) |main_step| {
            const decision = try self.executor.executeStep(ctx_base, main_step.call);
            if (decision != .Continue) {
                return decision;
            }
        }

        // If we reach here with no final decision, return Continue
        return .Continue;
    }

    /// Handle a single HTTP request: parse, route, execute.
    pub fn handleRequest(
        self: *Server,
        request_text: []const u8,
    ) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Create tracer for this request
        var tracer = tracer_module.Tracer.init(arena.allocator());
        defer tracer.deinit();

        tracer.recordRequestStart();

        // Parse the HTTP request (simplified)
        const parsed = try self.parseRequest(request_text, arena.allocator());

        // Create request context
        var ctx = try ctx_module.CtxBase.init(arena.allocator());
        defer ctx.deinit();

        // Try to match route
        if (try self.router.match(parsed.method, parsed.path, arena.allocator())) |route_match| {
            tracer.recordStepStart("route_match");
            tracer.recordStepEnd("route_match", "Continue");

            // Execute the pipeline
            const decision = try self.executePipeline(&ctx, route_match.spec.before, route_match.spec.steps);

            tracer.recordRequestEnd();

            // Render response based on decision
            return self.renderResponse(&ctx, decision, arena.allocator());
        }

        // Try to match flow (if method is POST to /flow/v1/<slug>)
        if (parsed.method == .POST and std.mem.startsWith(u8, parsed.path, "/flow/v1/")) {
            const slug = parsed.path[9..]; // Remove "/flow/v1/"

            for (self.flows.items) |flow| {
                if (std.mem.eql(u8, flow.slug, slug)) {
                    tracer.recordStepStart("flow_match");
                    tracer.recordStepEnd("flow_match", "Continue");

                    const decision = try self.executePipeline(&ctx, flow.spec.before, flow.spec.steps);

                    tracer.recordRequestEnd();

                    return self.renderResponse(&ctx, decision, arena.allocator());
                }
            }
        }

        // No route matched: 404
        tracer.recordRequestEnd();
        return self.renderError(&ctx, .{
            .kind = types.ErrorCode.NotFound,
            .ctx = .{ .what = "routing", .key = parsed.path },
        }, arena.allocator());
    }

    /// Parse an HTTP request (MVP: very simplified).
    fn parseRequest(self: *Server, text: []const u8, arena: std.mem.Allocator) !ParsedRequest {
        var lines = std.mem.splitSequence(u8, text, "\r\n");

        // Parse request line: "GET /path HTTP/1.1"
        const request_line = lines.next() orelse return error.InvalidRequest;
        var request_parts = std.mem.splitSequence(u8, request_line, " ");

        const method_str = request_parts.next() orelse return error.InvalidRequest;
        const path_str = request_parts.next() orelse return error.InvalidRequest;

        const method = try self.parseMethod(method_str);
        const path = try arena.dupe(u8, path_str);

        // Parse headers (until empty line)
        var headers = std.StringHashMap([]const u8).init(arena);
        while (lines.next()) |line| {
            if (line.len == 0) break; // Empty line = end of headers

            if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
                const header_name = line[0..colon_idx];
                const header_value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
                try headers.put(header_name, header_value);
            }
        }

        // Body (remaining text after headers)
        const body_start = std.mem.indexOf(u8, text, "\r\n\r\n");
        const body = if (body_start) |idx| text[idx + 4 ..] else "";

        return ParsedRequest{
            .method = method,
            .path = path,
            .headers = headers,
            .query = std.StringHashMap([]const u8).init(arena), // TODO: parse query string
            .body = try arena.dupe(u8, body),
        };
    }

    fn parseMethod(self: *Server, text: []const u8) !types.Method {
        _ = self;
        if (std.mem.eql(u8, text, "GET")) return .GET;
        if (std.mem.eql(u8, text, "POST")) return .POST;
        if (std.mem.eql(u8, text, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, text, "PUT")) return .PUT;
        if (std.mem.eql(u8, text, "DELETE")) return .DELETE;
        return error.InvalidMethod;
    }

    /// Render a successful response.
    fn renderResponse(
        self: *Server,
        _ctx: *ctx_module.CtxBase,
        decision: types.Decision,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        const response = switch (decision) {
            .Continue => types.Response{ .status = 200, .body = "OK" },
            .Done => |resp| resp,
            .Fail => |err| {
                return self.renderError(_ctx, err, arena);
            },
            .need => types.Response{ .status = 500, .body = "Pipeline incomplete" },
        };

        return self.httpResponse(response, arena);
    }

    /// Render an error response.
    fn renderError(
        self: *Server,
        ctx: *ctx_module.CtxBase,
        _err: types.Error,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        _ = _err;
        // Call on_error handler
        const response = try self.config.on_error(ctx);

        return switch (response) {
            .Continue => self.httpResponse(.{ .status = 500, .body = "Error" }, arena),
            .Done => |resp| self.httpResponse(resp, arena),
            else => self.httpResponse(.{ .status = 500, .body = "Error" }, arena),
        };
    }

    /// Format an HTTP response as text.
    fn httpResponse(
        self: *Server,
        response: types.Response,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        _ = self;

        var buf = std.ArrayList(u8).initCapacity(arena, 512) catch unreachable;
        const w = buf.writer(arena);
        try w.print("HTTP/1.1 {} OK\r\n", .{response.status});
        try w.print("Content-Length: {}\r\n", .{response.body.len});
        try w.print("\r\n", .{});
        try w.writeAll(response.body);

        return buf.items;
    }

    /// Start listening for HTTP requests (blocking).
    pub fn listen(self: *Server) !void {
        std.debug.print("Server listening on {}.{}.{}.{}:{}\n", .{
            self.config.addr.ip[0],
            self.config.addr.ip[1],
            self.config.addr.ip[2],
            self.config.addr.ip[3],
            self.config.addr.port,
        });

        // TODO: Phase-2: Implement actual TCP listener
        // For MVP, this is a stub that allows testing via handleRequest()
        std.debug.print("Note: MVP server requires explicit handleRequest() calls (no TCP listener yet)\n", .{});
    }
};
