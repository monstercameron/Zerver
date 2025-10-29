// src/zupervisor/pipeline_executor.zig
/// Pipeline executor for Zupervisor
/// Executes step pipelines from DLL features with effect system support
/// Adapted from src/zerver/impure/server.zig executePipeline

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const types = zerver.types;
const ctx_module = zerver.ctx_module;
const ipc_types = zerver.ipc_types;
const executor_module = zerver.executor;
const RuntimeResources = zerver.RuntimeResources;
const effectors = zerver.reactor_effectors;

/// Thread-local storage for effect dispatcher and context
/// This allows the effect handler function to access the dispatcher
threadlocal var g_effect_dispatcher: ?*effectors.EffectDispatcher = null;
threadlocal var g_effect_context: ?effectors.Context = null;

/// Effect handler that uses the thread-local dispatcher and context
fn realEffectHandler(effect: *const types.Effect, timeout_ms: u32) anyerror!executor_module.EffectResult {
    _ = timeout_ms; // TODO: Use timeout_ms in dispatch

    const dispatcher = g_effect_dispatcher orelse return error.NoEffectDispatcher;
    var ctx = g_effect_context orelse return error.NoEffectContext;

    slog.debug("Dispatching effect", &.{
        slog.Attr.string("effect", @tagName(effect.*)),
    });

    return try dispatcher.dispatch(&ctx, effect.*);
}

/// Execute a pipeline and return an IPC response
pub fn executePipeline(
    allocator: std.mem.Allocator,
    request: *const ipc_types.IPCRequest,
    route_match: *const zerver.Router.RouteMatch,
    runtime_resources: *RuntimeResources,
) !ipc_types.IPCResponse {
    const start_time: i64 = @intCast(std.time.nanoTimestamp());

    // Get effect dispatcher from runtime resources and store in thread-local
    g_effect_dispatcher = runtime_resources.reactorEffectDispatcher() orelse {
        slog.err("Effect dispatcher not available", &.{});
        return try errorToIPCResponse(allocator, .{
            .kind = types.ErrorCode.InternalServerError,
            .ctx = .{ .what = "runtime", .key = "no_effect_dispatcher" },
        }, request.request_id, start_time);
    };
    defer g_effect_dispatcher = null;

    // Get effect context from runtime resources and store in thread-local
    g_effect_context = runtime_resources.reactorEffectContext() orelse {
        slog.err("Effect context not available", &.{});
        return try errorToIPCResponse(allocator, .{
            .kind = types.ErrorCode.InternalServerError,
            .ctx = .{ .what = "runtime", .key = "no_effect_context" },
        }, request.request_id, start_time);
    };
    // Store RuntimeResources in context for database access
    g_effect_context.?.user_context = @ptrCast(runtime_resources);
    defer g_effect_context = null;

    // Initialize executor with real effect handler
    var executor = executor_module.Executor.init(allocator, realEffectHandler);

    // Initialize a minimal context
    var ctx = try ctx_module.CtxBase.init(allocator);
    defer ctx.deinit();

    // Convert IPC method to method string
    const method_str = switch (request.method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .PATCH => "PATCH",
        .DELETE => "DELETE",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
    };

    // Set basic context fields
    ctx.method_str = method_str;
    ctx.path_str = request.path;
    ctx.body = request.body;
    ctx.client_ip = "0.0.0.0"; // TODO: Extract from request

    // Copy headers from IPC request
    for (request.headers) |header| {
        const name_lower = try std.ascii.allocLowerString(allocator, header.name);
        defer allocator.free(name_lower);
        try ctx.headers.put(
            try allocator.dupe(u8, name_lower),
            try allocator.dupe(u8, header.value),
        );
    }

    // Copy path parameters from route match
    var param_iter = route_match.params.iterator();
    while (param_iter.next()) |entry| {
        try ctx.params.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*),
        );
    }

    // Execute route-specific before steps using executor
    for (route_match.handler.before) |before_step| {
        slog.debug("Executing before step", &.{
            slog.Attr.string("name", before_step.name),
        });

        const decision = try executor.executeStep(&ctx, before_step.call);

        // Check if step returned early response
        if (decision != .Continue) {
            switch (decision) {
                .Continue => unreachable,
                .Done => |done| {
                    return try decisionToIPCResponse(allocator, done, request.request_id, start_time);
                },
                .Fail => |err| {
                    return try errorToIPCResponse(allocator, err, request.request_id, start_time);
                },
                .need => {
                    // This should not happen - executeStep should resolve all needs
                    slog.err("Executor returned unresolved Need", &.{
                        slog.Attr.string("step", before_step.name),
                    });
                    return try errorToIPCResponse(allocator, .{
                        .kind = types.ErrorCode.InternalServerError,
                        .ctx = .{ .what = "pipeline", .key = "unresolved_need" },
                    }, request.request_id, start_time);
                },
            }
        }
    }

    // Execute main steps using executor
    for (route_match.handler.steps) |main_step| {
        slog.debug("Executing main step", &.{
            slog.Attr.string("name", main_step.name),
        });

        const decision = try executor.executeStep(&ctx, main_step.call);

        // Check if step returned response
        if (decision != .Continue) {
            switch (decision) {
                .Continue => unreachable,
                .Done => |done| {
                    return try decisionToIPCResponse(allocator, done, request.request_id, start_time);
                },
                .Fail => |err| {
                    return try errorToIPCResponse(allocator, err, request.request_id, start_time);
                },
                .need => {
                    // This should not happen - executeStep should resolve all needs
                    slog.err("Executor returned unresolved Need", &.{
                        slog.Attr.string("step", main_step.name),
                    });
                    return try errorToIPCResponse(allocator, .{
                        .kind = types.ErrorCode.InternalServerError,
                        .ctx = .{ .what = "pipeline", .key = "unresolved_need" },
                    }, request.request_id, start_time);
                },
            }
        }
    }

    // If we reach here, no step returned Done - this shouldn't happen
    // Return a 500 error
    slog.err("Pipeline completed without response", &.{
        slog.Attr.string("path", request.path),
    });
    return try errorToIPCResponse(allocator, .{
        .kind = types.ErrorCode.InternalServerError,
        .ctx = .{ .what = "pipeline", .key = "no_response" },
    }, request.request_id, start_time);
}

/// Convert a Decision.Done to an IPC response
fn decisionToIPCResponse(
    allocator: std.mem.Allocator,
    done: types.Response,
    request_id: u128,
    start_time: i64,
) !ipc_types.IPCResponse {
    // Extract body
    const body = switch (done.body) {
        .complete => |html| try allocator.dupe(u8, html),
        .streaming => |_| try allocator.dupe(u8, "{\"error\":\"Streaming not yet supported\"}"),
    };

    // Convert headers
    const headers = try allocator.alloc(ipc_types.Header, done.headers.len);
    for (done.headers, 0..) |header, i| {
        headers[i] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        };
    }

    const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

    return .{
        .request_id = request_id,
        .status = done.status,
        .headers = headers,
        .body = body,
        .processing_time_us = duration_us,
    };
}

/// Convert an Error to an IPC response
fn errorToIPCResponse(
    allocator: std.mem.Allocator,
    err: types.Error,
    request_id: u128,
    start_time: i64,
) !ipc_types.IPCResponse {
    // Build error JSON
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"details\":\"{s}\"}}", .{
        err.ctx.what,
        err.ctx.key,
    });

    const headers = try allocator.alloc(ipc_types.Header, 1);
    headers[0] = .{
        .name = try allocator.dupe(u8, "Content-Type"),
        .value = try allocator.dupe(u8, "application/json"),
    };

    const duration_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - start_time, 1000));

    return .{
        .request_id = request_id,
        .status = @intCast(err.kind),
        .headers = headers,
        .body = body,
        .processing_time_us = duration_us,
    };
}
