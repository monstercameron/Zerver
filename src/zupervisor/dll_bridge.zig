// src/zupervisor/dll_bridge.zig
/// Bridge between C-compatible DLL ABI and internal Zig pipeline system
/// This module converts simple C-style request/response handlers into
/// the internal RouteSpec/Step pipeline architecture

const std = @import("std");
const zerver = @import("zerver");
const dll_abi = zerver.ipc_types.dll_abi;
const types = zerver.types;
const route_types = zerver.routes.types;
const slog = zerver.slog;
const AtomicRouter = zerver.AtomicRouter;

/// Response builder context - stores response data from DLL handlers
pub const ResponseBuilder = struct {
    allocator: std.mem.Allocator,
    status: c_int = 200,
    headers: std.ArrayList(Header),
    body: ?[]const u8 = null,

    const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResponseBuilder {
        return .{
            .allocator = allocator,
            .headers = std.ArrayList(Header){},
        };
    }

    pub fn deinit(self: *ResponseBuilder) void {
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        if (self.body) |b| {
            self.allocator.free(b);
        }
    }
};

/// C-compatible response builder functions (called by DLLs)

pub fn responseSetStatus(
    response_opaque: *dll_abi.ResponseBuilder,
    status: c_int,
) callconv(.c) void {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));
    response.status = status;
}

pub fn responseSetHeader(
    response_opaque: *dll_abi.ResponseBuilder,
    name_ptr: [*c]const u8,
    name_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));

    const name = response.allocator.dupe(u8, name_ptr[0..name_len]) catch return 1;
    const value = response.allocator.dupe(u8, value_ptr[0..value_len]) catch {
        response.allocator.free(name);
        return 1;
    };

    response.headers.append(.{ .name = name, .value = value }) catch {
        response.allocator.free(name);
        response.allocator.free(value);
        return 1;
    };

    return 0; // Success
}

pub fn responseSetBody(
    response_opaque: *dll_abi.ResponseBuilder,
    body_ptr: [*c]const u8,
    body_len: usize,
) callconv(.c) c_int {
    const response: *ResponseBuilder = @ptrCast(@alignCast(response_opaque));

    // Free previous body if exists
    if (response.body) |old_body| {
        response.allocator.free(old_body);
    }

    response.body = response.allocator.dupe(u8, body_ptr[0..body_len]) catch return 1;
    return 0; // Success
}

/// Wrapper that stores a DLL handler function
const HandlerWrapper = struct {
    handler_fn: dll_abi.HandlerFn,
};

/// Bridge function that converts DLL HandlerFn to internal Step
pub fn createBridgeStep(handler_fn: dll_abi.HandlerFn, allocator: std.mem.Allocator) !types.Step {
    // Allocate wrapper on heap (stays alive for route lifetime)
    const wrapper = try allocator.create(HandlerWrapper);
    wrapper.* = .{ .handler_fn = handler_fn };

    return types.Step{
        .name = "dll_handler",
        .call = bridgeStepHandler,
        .reads = &.{},
        .writes = &.{},
    };
}

/// Internal step handler that calls DLL handler and captures response
fn bridgeStepHandler(_: *types.CtxBase) !types.Decision {
    // This is a stub - in full implementation, would:
    // 1. Extract request data from ctx
    // 2. Create ResponseBuilder
    // 3. Call DLL handler
    // 4. Extract response from ResponseBuilder
    // 5. Set ctx response
    // 6. Return Decision to continue pipeline

    slog.info("bridge_step_handler called", &.{});
    return types.Decision{};
}

/// C-compatible addRoute wrapper
pub fn addRouteWrapper(
    router_opaque: *anyopaque,
    method_int: c_int,
    path_ptr: [*c]const u8,
    path_len: usize,
    handler: dll_abi.HandlerFn,
) callconv(.c) c_int {
    const router: *AtomicRouter = @ptrCast(@alignCast(router_opaque));
    const method: route_types.Method = @enumFromInt(method_int);
    const path: []const u8 = path_ptr[0..path_len];

    // Create bridge step
    const step = createBridgeStep(handler, std.heap.c_allocator) catch |err| {
        slog.err("Failed to create bridge step", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return 1;
    };

    // Create RouteSpec with single bridge step
    const spec = types.RouteSpec{
        .steps = &[_]types.Step{step},
    };

    // Register with router
    router.addRoute(method, path, spec) catch |err| {
        slog.err("Failed to add route", &.{
            slog.Attr.string("error", @errorName(err)),
            slog.Attr.string("path", path),
        });
        return 1;
    };

    slog.info("Route registered via C ABI", &.{
        slog.Attr.string("path", path),
        slog.Attr.string("method", @tagName(method)),
    });

    return 0; // Success
}
