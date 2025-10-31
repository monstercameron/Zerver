// src/zupervisor/slot_effect_dll.zig
/// DLL plugin adapter for slot-effect pipelines
/// Allows feature DLLs to export slot-effect handlers with type-safe contexts

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const slot_effect = @import("slot_effect.zig");
const step_pipeline = @import("step_pipeline.zig");
const effect_executors = @import("effect_executors.zig");
const route_registry = @import("route_registry.zig");

/// Enhanced server adapter with slot-effect support
pub const SlotEffectServerAdapter = extern struct {
    // Original ServerAdapter fields
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: *const fn (*anyopaque, c_int, [*c]const u8, usize, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int) callconv(.c) c_int,
    setStatus: *const fn (*anyopaque, c_int) callconv(.c) void,
    setHeader: *const fn (*anyopaque, *anyopaque, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) c_int,
    setBody: *const fn (*anyopaque, *anyopaque, [*c]const u8, usize) callconv(.c) c_int,

    // New slot-effect specific fields
    createSlotContext: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) ?*anyopaque,
    destroySlotContext: *const fn (*anyopaque) callconv(.c) void,
    executeEffect: *const fn (*anyopaque, *anyopaque, *const SlotEffectData) callconv(.c) c_int,
    traceEvent: *const fn (*anyopaque, *const TraceEventData) callconv(.c) void,

    // Slot-effect route registration - inlined function signature to avoid dependency loop
    addSlotEffectRoute: *const fn (*anyopaque, c_int, [*c]const u8, usize, *const fn (*const SlotEffectServerAdapter, *anyopaque, *anyopaque) callconv(.c) c_int, ?*const RouteMetadata) callconv(.c) c_int,
};

/// Serialized effect data for C ABI
pub const SlotEffectData = extern struct {
    effect_type: EffectType,
    data: *anyopaque,
};

pub const EffectType = enum(c_int) {
    db_get = 0,
    db_put = 1,
    db_del = 2,
    db_query = 3,
    http_call = 4,
    compute_task = 5,
    compensate = 6,
};

/// C-compatible database GET effect
pub const DbGetEffectData = extern struct {
    database: [*c]const u8,
    database_len: usize,
    key: [*c]const u8,
    key_len: usize,
    result_slot: u32,
};

/// C-compatible database PUT effect
pub const DbPutEffectData = extern struct {
    database: [*c]const u8,
    database_len: usize,
    key: [*c]const u8,
    key_len: usize,
    value: [*c]const u8,
    value_len: usize,
    result_slot: u32, // Use 0xFFFFFFFF for null
};

/// C-compatible database DELETE effect
pub const DbDelEffectData = extern struct {
    database: [*c]const u8,
    database_len: usize,
    key: [*c]const u8,
    key_len: usize,
    result_slot: u32, // Use 0xFFFFFFFF for null
};

/// Serialized trace event for C ABI
pub const TraceEventData = extern struct {
    event_type: TraceEventType,
    request_id: [*c]const u8,
    request_id_len: usize,
    timestamp_ns: i64,
    data: *anyopaque,
};

pub const TraceEventType = enum(c_int) {
    request_start = 0,
    step_start = 1,
    step_complete = 2,
    effect_start = 3,
    effect_complete = 4,
    error_occurred = 5,
    request_complete = 6,
};

/// Handler function type for slot-effect DLLs
/// Returns 0 on success, non-zero on error
pub const SlotEffectHandlerFn = *const fn (
    server: *const SlotEffectServerAdapter,
    request: *anyopaque,
    response: *anyopaque,
) callconv(.c) c_int;

/// Route registration for slot-effect handlers
pub const SlotEffectRoute = extern struct {
    method: c_int, // HTTP method (GET=0, POST=1, etc.)
    path: [*c]const u8,
    path_len: usize,
    handler: SlotEffectHandlerFn,
    metadata: ?*const RouteMetadata,
};

/// Optional metadata for routes
pub const RouteMetadata = extern struct {
    description: [*c]const u8,
    description_len: usize,
    max_body_size: usize,
    timeout_ms: u32,
    requires_auth: bool,
};

/// Function signature for DLLs to export their routes
pub const GetRoutesFn = *const fn () callconv(.c) [*c]const SlotEffectRoute;
pub const GetRoutesCountFn = *const fn () callconv(.c) usize;

/// Runtime bridge that converts between slot-effect and DLL boundary
pub const SlotEffectBridge = struct {
    allocator: std.mem.Allocator,
    effect_executor: effect_executors.UnifiedEffectExecutor,
    trace_collector: slot_effect.TraceCollector,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !SlotEffectBridge {
        return .{
            .allocator = allocator,
            .effect_executor = try effect_executors.UnifiedEffectExecutor.init(allocator, db_path),
            .trace_collector = slot_effect.TraceCollector.init(allocator),
        };
    }

    pub fn deinit(self: *SlotEffectBridge) void {
        self.effect_executor.deinit();
        // TraceCollector has no resources to clean up
    }

    /// Create a slot context for a new request
    pub fn createContext(self: *SlotEffectBridge, request_id: []const u8) !*slot_effect.CtxBase {
        const ctx = try self.allocator.create(slot_effect.CtxBase);
        errdefer self.allocator.destroy(ctx);

        ctx.* = try slot_effect.CtxBase.init(self.allocator, request_id);
        return ctx;
    }

    /// Destroy a slot context after request completes
    pub fn destroyContext(self: *SlotEffectBridge, ctx: *slot_effect.CtxBase) void {
        ctx.deinit();
        self.allocator.destroy(ctx);
    }

    /// Execute an effect and return the result
    pub fn executeEffect(
        self: *SlotEffectBridge,
        ctx: *slot_effect.CtxBase,
        effect: slot_effect.Effect,
    ) !void {
        try self.effect_executor.execute(ctx, effect);
    }

    /// Record a trace event
    pub fn recordTrace(
        self: *SlotEffectBridge,
        event: slot_effect.TraceEvent,
    ) !void {
        self.trace_collector.emit(event);
    }

    /// Build server adapter for DLLs
    pub fn buildAdapter(self: *SlotEffectBridge, router: *anyopaque) SlotEffectServerAdapter {
        return .{
            .router = router,
            .runtime_resources = @ptrCast(self),
            .addRoute = addRouteImpl,
            .setStatus = setStatusImpl,
            .setHeader = setHeaderImpl,
            .setBody = setBodyImpl,
            .createSlotContext = createSlotContextImpl,
            .destroySlotContext = destroySlotContextImpl,
            .executeEffect = executeEffectImpl,
            .traceEvent = traceEventImpl,
            .addSlotEffectRoute = addSlotEffectRouteImpl,
        };
    }
};

// ============================================================================
// C ABI implementation functions
// ============================================================================

fn addRouteImpl(
    router: *anyopaque,
    method: c_int,
    path: [*c]const u8,
    path_len: usize,
    handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
) callconv(.c) c_int {
    const registry: *route_registry.RouteRegistry = @ptrCast(@alignCast(router));
    const path_slice = path[0..path_len];
    const http_method: route_registry.HttpMethod = @enumFromInt(method);

    registry.registerStepRoute(http_method, path_slice, handler) catch {
        return -1;
    };

    return 0;
}

fn setStatusImpl(response: *anyopaque, status: c_int) callconv(.c) void {
    const resp: *slot_effect.Response = @ptrCast(@alignCast(response));
    resp.status = @intCast(status);
}

fn setHeaderImpl(
    response: *anyopaque,
    runtime_resources: *anyopaque,
    name: [*c]const u8,
    name_len: usize,
    value: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int {
    const bridge: *SlotEffectBridge = @ptrCast(@alignCast(runtime_resources));
    const resp: *slot_effect.Response = @ptrCast(@alignCast(response));
    const name_slice = name[0..name_len];
    const value_slice = value[0..value_len];

    resp.addHeader(bridge.allocator, name_slice, value_slice) catch {
        return -1;
    };

    return 0;
}

fn setBodyImpl(
    response: *anyopaque,
    runtime_resources: *anyopaque,
    data: [*c]const u8,
    data_len: usize,
) callconv(.c) c_int {
    const bridge: *SlotEffectBridge = @ptrCast(@alignCast(runtime_resources));
    const resp: *slot_effect.Response = @ptrCast(@alignCast(response));
    const data_slice = data[0..data_len];

    // Duplicate the body data since it needs to be owned
    const body_copy = bridge.allocator.dupe(u8, data_slice) catch {
        return -1;
    };

    resp.body = slot_effect.Body{ .complete = body_copy };
    return 0;
}

fn createSlotContextImpl(
    runtime_resources: *anyopaque,
    request_id: [*c]const u8,
    request_id_len: usize,
) callconv(.c) ?*anyopaque {
    const bridge: *SlotEffectBridge = @ptrCast(@alignCast(runtime_resources));
    const request_id_slice = request_id[0..request_id_len];

    const ctx = bridge.createContext(request_id_slice) catch {
        return null;
    };

    return @ptrCast(ctx);
}

fn destroySlotContextImpl(ctx: *anyopaque) callconv(.c) void {
    const slot_ctx: *slot_effect.CtxBase = @ptrCast(@alignCast(ctx));
    // Get bridge from somewhere - for now just deinit directly
    slot_ctx.deinit();
}

fn executeEffectImpl(
    runtime_resources: *anyopaque,
    ctx: *anyopaque,
    effect_data: *const SlotEffectData,
) callconv(.c) c_int {
    const bridge: *SlotEffectBridge = @ptrCast(@alignCast(runtime_resources));
    const slot_ctx: *slot_effect.CtxBase = @ptrCast(@alignCast(ctx));

    // Deserialize effect from effect_data
    const effect = deserializeEffect(effect_data) catch {
        return -1;
    };

    bridge.executeEffect(slot_ctx, effect) catch {
        return -1;
    };

    return 0;
}

fn traceEventImpl(
    runtime_resources: *anyopaque,
    event_data: *const TraceEventData,
) callconv(.c) void {
    const bridge: *SlotEffectBridge = @ptrCast(@alignCast(runtime_resources));
    const request_id_slice = event_data.request_id[0..event_data.request_id_len];

    // Deserialize trace event
    const event = deserializeTraceEvent(event_data, request_id_slice) catch {
        return;
    };

    bridge.recordTrace(event) catch {
    };
}

fn addSlotEffectRouteImpl(
    router: *anyopaque,
    method: c_int,
    path: [*c]const u8,
    path_len: usize,
    handler: *const fn (*const SlotEffectServerAdapter, *anyopaque, *anyopaque) callconv(.c) c_int,
    metadata: ?*const RouteMetadata,
) callconv(.c) c_int {
    const registry: *route_registry.RouteRegistry = @ptrCast(@alignCast(router));
    const path_slice = path[0..path_len];
    const http_method: route_registry.HttpMethod = @enumFromInt(method);

    var route_metadata: ?route_registry.Route.RouteMetadata = null;
    if (metadata) |meta| {
        const desc = meta.description[0..meta.description_len];
        route_metadata = .{
            .description = desc,
            .max_body_size = meta.max_body_size,
            .timeout_ms = meta.timeout_ms,
            .requires_auth = meta.requires_auth,
        };
    }

    registry.registerSlotEffectRoute(http_method, path_slice, handler, route_metadata) catch {
        return -1;
    };

    return 0;
}

// ============================================================================
// Serialization helpers
// ============================================================================

fn deserializeEffect(effect_data: *const SlotEffectData) !slot_effect.Effect {
    return switch (effect_data.effect_type) {
        .db_get => blk: {
            const data: *const DbGetEffectData = @ptrCast(@alignCast(effect_data.data));
            break :blk slot_effect.Effect{
                .db_get = .{
                    .database = data.database[0..data.database_len],
                    .key = data.key[0..data.key_len],
                    .result_slot = data.result_slot,
                },
            };
        },
        .db_put => blk: {
            const data: *const DbPutEffectData = @ptrCast(@alignCast(effect_data.data));
            break :blk slot_effect.Effect{
                .db_put = .{
                    .database = data.database[0..data.database_len],
                    .key = data.key[0..data.key_len],
                    .value = data.value[0..data.value_len],
                    .result_slot = if (data.result_slot == 0xFFFFFFFF) null else data.result_slot,
                },
            };
        },
        .db_del => blk: {
            const data: *const DbDelEffectData = @ptrCast(@alignCast(effect_data.data));
            break :blk slot_effect.Effect{
                .db_del = .{
                    .database = data.database[0..data.database_len],
                    .key = data.key[0..data.key_len],
                    .result_slot = if (data.result_slot == 0xFFFFFFFF) null else data.result_slot,
                },
            };
        },
        // Other effect types not yet implemented
        else => error.NotImplemented,
    };
}

fn deserializeTraceEvent(
    event_data: *const TraceEventData,
    request_id: []const u8,
) !slot_effect.TraceEvent {
    return switch (event_data.event_type) {
        .request_start => slot_effect.TraceEvent{
            .request_start = .{
                .request_id = request_id,
                .timestamp_ns = event_data.timestamp_ns,
                .method = "", // TODO: Extract from data
                .path = "", // TODO: Extract from data
            },
        },
        .request_complete => slot_effect.TraceEvent{
            .request_end = .{
                .request_id = request_id,
                .status = 0, // TODO: Extract from data
                .duration_ns = 0, // TODO: Extract from data
            },
        },
        // TODO: Implement other event types
        else => error.NotImplemented,
    };
}

// ============================================================================
// Helper for DLL developers
// ============================================================================

/// Helper struct for building slot-effect handlers in DLLs
pub const HandlerBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HandlerBuilder {
        return .{ .allocator = allocator };
    }

    /// Wrap a slot-effect pipeline into a C-compatible handler
    pub fn wrapPipeline(
        comptime SlotEnum: type,
        comptime pipeline: anytype,
    ) SlotEffectHandlerFn {
        const Handler = struct {
            fn handle(
                server: *const SlotEffectServerAdapter,
                request: *anyopaque,
                response: *anyopaque,
            ) callconv(.c) c_int {
                _ = server;
                _ = request;
                _ = response;
                _ = pipeline;
                _ = SlotEnum;
                // TODO: Implement pipeline execution
                return 0;
            }
        };

        return Handler.handle;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SlotEffectBridge - lifecycle" {
    const testing = std.testing;

    var bridge = try SlotEffectBridge.init(testing.allocator);
    defer bridge.deinit();

    const ctx = try bridge.createContext("test-req-123");
    defer bridge.destroyContext(ctx);

    try testing.expect(ctx.slots.count() == 0);
}

test "SlotEffectBridge - adapter building" {
    const testing = std.testing;

    var bridge = try SlotEffectBridge.init(testing.allocator);
    defer bridge.deinit();

    var dummy_router: u32 = 0;
    const adapter = bridge.buildAdapter(@ptrCast(&dummy_router));

    try testing.expect(adapter.router != null);
    try testing.expect(adapter.createSlotContext != null);
}

test "SlotEffectRoute - struct layout" {
    // Verify extern struct compiles correctly
    const route = SlotEffectRoute{
        .method = 1,
        .path = "test",
        .path_len = 4,
        .handler = undefined,
        .metadata = null,
    };

    _ = route;
}

test "HandlerBuilder - basic usage" {
    const testing = std.testing;

    const builder = HandlerBuilder.init(testing.allocator);
    _ = builder;

    // Just verify it compiles
}

test "DLL C ABI - response building integration" {
    const testing = std.testing;

    var bridge = try SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    // Create a response object
    var response = slot_effect.Response.init(200, slot_effect.Body{ .complete = "" });

    // Get adapter to access C ABI functions
    const adapter = bridge.buildAdapter(@ptrCast(&response));

    // Test setStatus
    adapter.setStatus(@ptrCast(&response), 201);
    try testing.expect(response.status == 201);

    // Test setHeader
    const result1 = adapter.setHeader(
        @ptrCast(&response),
        adapter.runtime_resources,
        "Content-Type",
        12,
        "application/json",
        16,
    );
    try testing.expect(result1 == 0);
    try testing.expect(response.headers_count == 1);

    // Test setBody
    const body_data = "test body content";
    const result2 = adapter.setBody(
        @ptrCast(&response),
        adapter.runtime_resources,
        body_data.ptr,
        body_data.len,
    );
    try testing.expect(result2 == 0);
    try testing.expect(std.mem.eql(u8, response.body.complete, body_data));
}

test "DLL C ABI - effect deserialization" {
    const testing = std.testing;

    // Test db_get deserialization
    var db_get_data = DbGetEffectData{
        .database = "test_db",
        .database_len = 7,
        .key = "test_key",
        .key_len = 8,
        .result_slot = 42,
    };

    const effect_data = SlotEffectData{
        .effect_type = .db_get,
        .data = @ptrCast(&db_get_data),
    };

    const effect = try deserializeEffect(&effect_data);
    try testing.expect(effect == .db_get);
    try testing.expect(std.mem.eql(u8, effect.db_get.database, "test_db"));
    try testing.expect(std.mem.eql(u8, effect.db_get.key, "test_key"));
    try testing.expect(effect.db_get.result_slot == 42);

    // Test db_put deserialization with optional result_slot
    var db_put_data = DbPutEffectData{
        .database = "test_db",
        .database_len = 7,
        .key = "key",
        .key_len = 3,
        .value = "value",
        .value_len = 5,
        .result_slot = 0xFFFFFFFF, // null sentinel
    };

    const put_effect_data = SlotEffectData{
        .effect_type = .db_put,
        .data = @ptrCast(&db_put_data),
    };

    const put_effect = try deserializeEffect(&put_effect_data);
    try testing.expect(put_effect == .db_put);
    try testing.expect(put_effect.db_put.result_slot == null);
}

test "DLL C ABI - end-to-end route execution" {
    const testing = std.testing;

    var bridge = try SlotEffectBridge.init(testing.allocator, ":memory:");
    defer bridge.deinit();

    var registry = route_registry.RouteRegistry.init(testing.allocator);
    defer registry.deinit();

    // Mock DLL handler that builds a response using C ABI
    const MockHandler = struct {
        fn handle(
            server: *const SlotEffectServerAdapter,
            request: *anyopaque,
            response: *anyopaque,
        ) callconv(.c) c_int {
            _ = request;

            // Use C ABI to build response
            server.setStatus(response, 200);

            _ = server.setHeader(
                response,
                server.runtime_resources,
                "X-Custom-Header",
                15,
                "test-value",
                10,
            );

            const body = "{\"status\":\"success\"}";
            _ = server.setBody(
                response,
                server.runtime_resources,
                body.ptr,
                body.len,
            );

            return 0;
        }
    };

    // Build adapter
    const adapter = bridge.buildAdapter(@ptrCast(&registry));

    // Register route using C ABI
    const path = "/api/test";
    const result = adapter.addSlotEffectRoute(
        adapter.router,
        0, // GET
        path.ptr,
        path.len,
        MockHandler.handle,
        null,
    );
    try testing.expect(result == 0);
    try testing.expect(registry.count() == 1);

    // Verify route was registered
    const route = registry.findRoute(.GET, "/api/test");
    try testing.expect(route != null);

    // Execute the handler
    var response = slot_effect.Response.init(500, slot_effect.Body{ .complete = "" });
    var dummy_request: u32 = 0;

    const handler_result = MockHandler.handle(&adapter, @ptrCast(&dummy_request), @ptrCast(&response));
    try testing.expect(handler_result == 0);

    // Verify response was built correctly
    try testing.expect(response.status == 200);
    try testing.expect(response.headers_count == 1);
    try testing.expect(std.mem.eql(u8, response.body.complete, "{\"status\":\"success\"}"));
}
