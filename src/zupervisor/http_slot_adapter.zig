// src/zupervisor/http_slot_adapter.zig
/// HTTP adapter that connects IPC messages to slot-effect pipelines
/// Bridges Zingest HTTP requests with Zupervisor slot-effect handlers

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const slot_effect = @import("slot_effect.zig");
const slot_effect_dll = @import("slot_effect_dll.zig");
const slot_effect_executor = @import("slot_effect_executor.zig");
const route_registry = @import("route_registry.zig");
const effect_executors = @import("effect_executors.zig");

/// HTTP request data from IPC message
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// HTTP response data for IPC message
pub const HttpResponse = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        allocator.free(self.body);
    }
};

/// Thread-local storage for current request's path parameters
threadlocal var current_path_params: ?*const route_registry.RouteRegistry.PathParams = null;

/// Get path parameter by name from current request
/// This is exposed to DLLs with C ABI
pub export fn getPathParam(name_ptr: [*c]const u8, name_len: usize) callconv(.c) ?[*:0]const u8 {
    if (current_path_params) |params| {
        const name = name_ptr[0..name_len];
        if (params.get(name)) |value| {
            // Need to return a null-terminated string
            // For now, we'll rely on the value already being null-terminated
            // (which it should be since it comes from the URL)
            return @ptrCast(value.ptr);
        }
    }
    return null;
}

/// Main HTTP to slot-effect adapter
pub const HttpSlotAdapter = struct {
    allocator: std.mem.Allocator,
    bridge: slot_effect_dll.SlotEffectBridge,
    registry: route_registry.RouteRegistry,
    executor: slot_effect_executor.PipelineExecutor,
    request_counter: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !HttpSlotAdapter {
        var bridge = try slot_effect_dll.SlotEffectBridge.init(allocator, db_path);
        errdefer bridge.deinit();

        // Bridge now has its own effect executor, so we don't need a separate one
        _ = effect_executors;

        return .{
            .allocator = allocator,
            .bridge = bridge,
            .registry = route_registry.RouteRegistry.init(allocator),
            .executor = slot_effect_executor.PipelineExecutor.init(allocator, &bridge),
            .request_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *HttpSlotAdapter) void {
        self.registry.deinit();
        self.bridge.deinit();
    }

    /// Handle an HTTP request via slot-effect pipeline
    pub fn handleRequest(
        self: *HttpSlotAdapter,
        request: HttpRequest,
    ) !HttpResponse {
        // Generate request ID
        const req_num = self.request_counter.fetchAdd(1, .monotonic);
        const request_id = try std.fmt.allocPrint(
            self.allocator,
            "req-{d}-{d}",
            .{ std.time.timestamp(), req_num },
        );
        defer self.allocator.free(request_id);


        // Convert HTTP method to enum
        const method = try self.parseMethod(request.method);

        // Look up route with path parameter support
        const route_match = try self.registry.findRouteWithParams(self.allocator, method, request.path) orelse {
            return self.build404Response();
        };
        defer {
            // Free path parameter memory
            for (route_match.params.names) |name| self.allocator.free(name);
            for (route_match.params.values) |value| self.allocator.free(value);
            self.allocator.free(route_match.params.names);
            self.allocator.free(route_match.params.values);
        }

        // Handle based on route type
        return switch (route_match.route.handler) {
            .step_pipeline => self.handleStepPipeline(request_id, request, route_match.route, &route_match.params),
            .slot_effect => self.handleSlotEffect(request_id, request, route_match.route),
        };
    }

    fn handleStepPipeline(
        self: *HttpSlotAdapter,
        request_id: []const u8,
        request: HttpRequest,
        route: *const route_registry.Route,
        params: *const route_registry.RouteRegistry.PathParams,
    ) !HttpResponse {
        _ = request_id;

        // Store path parameters in thread-local storage for DLL access
        current_path_params = params;
        defer current_path_params = null;

        // Response builder compatible with main.zig's dllSetStatus/dllSetHeader/dllSetBody
        const ResponseHeader = struct {
            name: []const u8,
            value: []const u8,
        };

        const ResponseBuilder = struct {
            allocator: std.mem.Allocator,
            status: u16,
            headers: std.ArrayList(ResponseHeader),
            body: std.ArrayList(u8),

            fn init(allocator: std.mem.Allocator) !@This() {
                return .{
                    .allocator = allocator,
                    .status = 200,
                    .headers = std.ArrayList(ResponseHeader){},
                    .body = std.ArrayList(u8){},
                };
            }

            fn deinit(s: *@This()) void {
                for (s.headers.items) |header| {
                    s.allocator.free(header.name);
                    s.allocator.free(header.value);
                }
                s.headers.deinit(s.allocator);
                s.body.deinit(s.allocator);
            }
        };

        // Create response builder
        var response_builder = try ResponseBuilder.init(self.allocator);
        defer response_builder.deinit();

        // Cast request and response to opaque pointers for C ABI
        // Note: request is not actually used by simple handlers like test.dylib
        const request_opaque: *anyopaque = @ptrCast(@constCast(&request));
        const response_opaque: *anyopaque = @ptrCast(&response_builder);

        // Call the DLL handler
        const result = route.handler.step_pipeline.handler(request_opaque, response_opaque);

        if (result != 0) {
            return self.buildErrorResponse(500, "Handler execution failed");
        }

        // Convert ResponseBuilder to HttpResponse
        const body = try self.allocator.dupe(u8, response_builder.body.items);

        const headers = try self.allocator.alloc(HttpResponse.Header, response_builder.headers.items.len);
        for (response_builder.headers.items, 0..) |h, i| {
            headers[i] = .{
                .name = try self.allocator.dupe(u8, h.name),
                .value = try self.allocator.dupe(u8, h.value),
            };
        }

        return HttpResponse{
            .status = response_builder.status,
            .headers = headers,
            .body = body,
        };
    }

    fn handleSlotEffect(
        self: *HttpSlotAdapter,
        request_id: []const u8,
        request: HttpRequest,
        route: *const route_registry.Route,
    ) !HttpResponse {
        // Create slot context from HTTP request
        var ctx_builder = slot_effect_executor.RequestContextBuilder.init(self.allocator);

        // Convert headers to the expected type
        const converted_headers = try self.allocator.alloc(slot_effect_executor.RequestContextBuilder.Header, request.headers.len);
        defer self.allocator.free(converted_headers);

        for (request.headers, 0..) |h, i| {
            converted_headers[i] = .{
                .name = h.name,
                .value = h.value,
            };
        }

        const ctx = try ctx_builder.buildFromHttp(
            request_id,
            request.method,
            request.path,
            converted_headers,
            request.body,
        );
        defer {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }

        // Create response object that handler will populate
        var response = slot_effect.Response.init(
            200,
            slot_effect.Body{ .complete = "" },
        );

        // Build adapter for DLL handler
        const adapter = self.bridge.buildAdapter(@ptrCast(&self.registry));

        // Call the DLL handler via C ABI
        const handler_result = route.handler.slot_effect.handler(
            &adapter,
            @ptrCast(ctx),
            @ptrCast(&response),
        );

        // Check handler result
        if (handler_result != 0) {
            // Handler failed, return error response
            return self.buildErrorResponse(500, "Handler execution failed");
        }

        // Serialize response
        var serializer = slot_effect_executor.ResponseSerializer.init(self.allocator);
        const serialized = try serializer.serialize(response);

        // Convert headers to HttpResponse.Header type
        const response_headers = try self.allocator.alloc(HttpResponse.Header, serialized.headers.len);
        for (serialized.headers, 0..) |h, i| {
            response_headers[i] = .{
                .name = h.name,
                .value = h.value,
            };
        }

        return HttpResponse{
            .status = serialized.status,
            .headers = response_headers,
            .body = serialized.body,
        };
    }

    fn parseMethod(self: *HttpSlotAdapter, method: []const u8) !route_registry.HttpMethod {
        _ = self;

        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;

        return error.UnsupportedMethod;
    }

    fn build404Response(self: *HttpSlotAdapter) !HttpResponse {
        return self.buildErrorResponse(404, "Not Found");
    }

    fn buildErrorResponse(self: *HttpSlotAdapter, status: u16, message: []const u8) !HttpResponse {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"error\":\"{s}\",\"code\":{d}}}",
            .{ message, status },
        );

        const headers = try self.allocator.alloc(HttpResponse.Header, 1);
        headers[0] = .{
            .name = try self.allocator.dupe(u8, "Content-Type"),
            .value = try self.allocator.dupe(u8, "application/json"),
        };

        return HttpResponse{
            .status = status,
            .headers = headers,
            .body = body,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HttpSlotAdapter - initialization" {
    const testing = std.testing;

    var adapter = try HttpSlotAdapter.init(testing.allocator, ":memory:");
    defer adapter.deinit();

    try testing.expect(adapter.request_counter.load(.monotonic) == 0);
}

test "HttpSlotAdapter - 404 response" {
    const testing = std.testing;

    var adapter = try HttpSlotAdapter.init(testing.allocator, ":memory:");
    defer adapter.deinit();

    const request = HttpRequest{
        .method = "GET",
        .path = "/nonexistent",
        .headers = &.{},
        .body = "",
    };

    var response = try adapter.handleRequest(request);
    defer response.deinit(testing.allocator);

    try testing.expect(response.status == 404);
    try testing.expect(std.mem.indexOf(u8, response.body, "Not Found") != null);
}

test "HttpSlotAdapter - route registration and lookup" {
    const testing = std.testing;

    var adapter = try HttpSlotAdapter.init(testing.allocator, ":memory:");
    defer adapter.deinit();

    // Register a test route
    const Handler = struct {
        fn handle(_: *const slot_effect_dll.SlotEffectServerAdapter, _: *anyopaque, _: *anyopaque) callconv(.c) c_int {
            return 0;
        }
    };

    try adapter.registry.registerSlotEffectRoute(
        .GET,
        "/api/test",
        Handler.handle,
        null,
    );

    const request = HttpRequest{
        .method = "GET",
        .path = "/api/test",
        .headers = &.{},
        .body = "",
    };

    var response = try adapter.handleRequest(request);
    defer response.deinit(testing.allocator);

    // Should not be 404 since route exists
    try testing.expect(response.status != 404);
}

test "HttpSlotAdapter - method parsing" {
    const testing = std.testing;

    var adapter = try HttpSlotAdapter.init(testing.allocator, ":memory:");
    defer adapter.deinit();

    try testing.expect(try adapter.parseMethod("GET") == .GET);
    try testing.expect(try adapter.parseMethod("POST") == .POST);
    try testing.expect(try adapter.parseMethod("PUT") == .PUT);
    try testing.expect(try adapter.parseMethod("DELETE") == .DELETE);

    try testing.expectError(error.UnsupportedMethod, adapter.parseMethod("INVALID"));
}
