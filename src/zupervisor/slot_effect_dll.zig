// src/zupervisor/slot_effect_dll.zig
/// DLL plugin adapter for slot-effect pipelines
/// Allows feature DLLs to export slot-effect handlers with type-safe contexts

const std = @import("std");
// TODO: Fix slog import to avoid module conflicts
const slot_effect = @import("slot_effect.zig");
const step_pipeline = @import("step_pipeline.zig");
const effect_executors = @import("effect_executors.zig");

/// Enhanced server adapter with slot-effect support
pub const SlotEffectServerAdapter = extern struct {
    // Original ServerAdapter fields
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: *const fn (*anyopaque, c_int, [*c]const u8, usize, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int) callconv(.c) c_int,
    setStatus: *const fn (*anyopaque, c_int) callconv(.c) void,
    setHeader: *const fn (*anyopaque, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) c_int,
    setBody: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) c_int,

    // New slot-effect specific fields
    createSlotContext: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) ?*anyopaque,
    destroySlotContext: *const fn (*anyopaque) callconv(.c) void,
    executeEffect: *const fn (*anyopaque, *anyopaque, *const SlotEffectData) callconv(.c) c_int,
    traceEvent: *const fn (*anyopaque, *const TraceEventData) callconv(.c) void,
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
    effector_table: slot_effect.EffectorTable,
    trace_collector: slot_effect.TraceCollector,

    pub fn init(allocator: std.mem.Allocator) !SlotEffectBridge {
        return .{
            .allocator = allocator,
            .effector_table = slot_effect.EffectorTable.init(allocator),
            .trace_collector = slot_effect.TraceCollector.init(allocator),
        };
    }

    pub fn deinit(self: *SlotEffectBridge) void {
        // EffectorTable and TraceCollector have no resources to clean up
        _ = self;
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
        try self.effector_table.execute(ctx, effect);
    }

    /// Record a trace event
    pub fn recordTrace(
        self: *SlotEffectBridge,
        event: slot_effect.TraceEvent,
    ) !void {
        try self.trace_collector.record(event);
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
    _ = router;
    _ = method;
    _ = path;
    _ = path_len;
    _ = handler;
    // TODO: Implement route registration
    return 0;
}

fn setStatusImpl(response: *anyopaque, status: c_int) callconv(.c) void {
    _ = response;
    _ = status;
    // TODO: Implement status setting
}

fn setHeaderImpl(
    response: *anyopaque,
    name: [*c]const u8,
    name_len: usize,
    value: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int {
    _ = response;
    _ = name;
    _ = name_len;
    _ = value;
    _ = value_len;
    // TODO: Implement header setting
    return 0;
}

fn setBodyImpl(
    response: *anyopaque,
    data: [*c]const u8,
    data_len: usize,
) callconv(.c) c_int {
    _ = response;
    _ = data;
    _ = data_len;
    // TODO: Implement body setting
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

// ============================================================================
// Serialization helpers
// ============================================================================

fn deserializeEffect(effect_data: *const SlotEffectData) !slot_effect.Effect {
    // TODO: Implement proper deserialization based on effect_type
    _ = effect_data;
    return error.NotImplemented;
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
            .request_complete = .{
                .request_id = request_id,
                .timestamp_ns = event_data.timestamp_ns,
                .status_code = 0, // TODO: Extract from data
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
