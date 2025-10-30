// features/test/src/routes.zig
/// Route handlers for test feature

const std = @import("std");

// ============================================================================
// C ABI Types (matching dll_abi.zig)
// ============================================================================

const Method = enum(c_int) {
    GET = 0,
    POST = 1,
    PUT = 2,
    PATCH = 3,
    DELETE = 4,
    HEAD = 5,
    OPTIONS = 6,
};

const RequestContext = opaque {};
const ResponseBuilder = opaque {};

const HandlerFn = *const fn (
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int;

const AddRouteFn = *const fn (
    router: *anyopaque,
    method: c_int,
    path_ptr: [*c]const u8,
    path_len: usize,
    handler: HandlerFn,
) callconv(.c) c_int;

const SetStatusFn = *const fn (
    response: *ResponseBuilder,
    status: c_int,
) callconv(.c) void;

const SetHeaderFn = *const fn (
    response: *ResponseBuilder,
    name_ptr: [*c]const u8,
    name_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int;

const SetBodyFn = *const fn (
    response: *ResponseBuilder,
    body_ptr: [*c]const u8,
    body_len: usize,
) callconv(.c) c_int;

const ServerAdapter = extern struct {
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: AddRouteFn,
    setStatus: SetStatusFn,
    setHeader: SetHeaderFn,
    setBody: SetBodyFn,
};

// ============================================================================
// Global server adapter (set during init)
// ============================================================================

var g_server: ?*ServerAdapter = null;

// ============================================================================
// Route Registration
// ============================================================================

pub fn registerRoutes(server: *anyopaque) !void {
    const adapter = @as(*ServerAdapter, @ptrCast(@alignCast(server)));
    g_server = adapter;

    // Register GET /test
    const path = "/test";
    const result = adapter.addRoute(
        adapter.router,
        @intFromEnum(Method.GET),
        path.ptr,
        path.len,
        &handleTestRoute,
    );

    if (result != 0) {
        return error.RouteRegistrationFailed;
    }

    std.debug.print("[Test Feature] Registered: GET /test\n", .{});
}

// ============================================================================
// Route Handlers
// ============================================================================

/// Handler for GET /test
/// Returns HTML: <h1>Test Feature Works!</h1>
fn handleTestRoute(
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int {
    _ = request; // Not used in this simple handler

    const server = g_server orelse return 1;

    // Set status 200 OK
    server.setStatus(response, 200);

    // Set Content-Type header
    const header_name = "Content-Type";
    const header_value = "text/html";
    _ = server.setHeader(
        response,
        header_name.ptr,
        header_name.len,
        header_value.ptr,
        header_value.len,
    );

    // Set HTML body
    const html = "<h1>Test Feature Works!</h1>";
    const body_result = server.setBody(
        response,
        html.ptr,
        html.len,
    );

    if (body_result != 0) {
        return 1;
    }

    std.debug.print("[Test Feature] Handled GET /test\n", .{});
    return 0;
}
