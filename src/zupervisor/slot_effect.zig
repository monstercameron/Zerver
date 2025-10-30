// src/zupervisor/slot_effect.zig
/// Slot-Effect Pipeline Architecture
/// Pure-impure split with comptime safety and runtime validation

const std = @import("std");
const builtin = @import("builtin");

/// SlotSchema helper for comptime slot operations
pub fn SlotSchema(comptime SlotEnum: type, comptime slotTypeFn: anytype) type {
    return struct {
        /// Get slot ID at comptime
        pub inline fn slotId(comptime slot: SlotEnum) u32 {
            return @intFromEnum(slot);
        }

        /// Verify all enum tags have a type mapping (exhaustive check)
        pub fn verifyExhaustive() void {
            comptime {
                for (@typeInfo(SlotEnum).@"enum".fields) |field| {
                    const slot = @field(SlotEnum, field.name);
                    _ = slotTypeFn(slot); // Forces exhaustive switch
                }
            }
        }

        /// Get type for a slot at comptime
        pub fn TypeOf(comptime slot: SlotEnum) type {
            return slotTypeFn(slot);
        }
    };
}

/// Debug-only slot usage tracking
pub const DebugSlotUsage = struct {
    declared_reads: std.StaticBitSet(256),
    declared_writes: std.StaticBitSet(256),
    actual_reads: std.StaticBitSet(256),
    actual_writes: std.StaticBitSet(256),
};

/// Assertion policy for slot usage validation
pub const AssertionPolicy = struct {
    /// Error if step declares read but never calls require/optional
    must_use_reads: bool = true,

    /// Error if step declares write but never calls put
    must_use_writes: bool = true,

    /// Warn on unused reads instead of error
    warn_unused_reads: bool = false,

    /// Warn on unused writes instead of error
    warn_unused_writes: bool = false,
};

/// Base context for request processing
pub const CtxBase = struct {
    allocator: std.mem.Allocator,
    request_id: []const u8,
    slots: std.StringHashMap(*anyopaque),
    assertion_policy: AssertionPolicy,

    // Debug-only field
    debug_slot_usage: if (builtin.mode == .Debug) DebugSlotUsage else void,

    pub fn init(allocator: std.mem.Allocator, request_id: []const u8) !CtxBase {
        return CtxBase{
            .allocator = allocator,
            .request_id = request_id,
            .slots = std.StringHashMap(*anyopaque).init(allocator),
            .assertion_policy = .{},
            .debug_slot_usage = if (builtin.mode == .Debug)
                DebugSlotUsage{
                    .declared_reads = std.StaticBitSet(256).initEmpty(),
                    .declared_writes = std.StaticBitSet(256).initEmpty(),
                    .actual_reads = std.StaticBitSet(256).initEmpty(),
                    .actual_writes = std.StaticBitSet(256).initEmpty(),
                }
            else {},
        };
    }

    pub fn deinit(self: *CtxBase) void {
        self.slots.deinit();
    }
};

/// Typed context view with comptime read/write validation
pub fn CtxView(comptime config: anytype) type {
    const SlotEnum = config.SlotEnum;
    const slotTypeFn = config.slotTypeFn;
    const reads = if (@hasField(@TypeOf(config), "reads")) config.reads else &[_]SlotEnum{};
    const writes = if (@hasField(@TypeOf(config), "writes")) config.writes else &[_]SlotEnum{};

    return struct {
        base: *CtxBase,

        const Self = @This();

        /// Require a slot value (error if not present)
        pub fn require(self: Self, comptime slot: SlotEnum) !slotTypeFn(slot) {
            // Comptime check: slot must be in reads
            comptime {
                var found = false;
                for (reads) |r| {
                    if (r == slot) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Slot not in declared reads");
                }
            }

            // Debug tracking
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_reads.set(slot_id);
            }

            const slot_id_str = std.fmt.comptimePrint("{d}", .{@intFromEnum(slot)});
            const ptr = self.base.slots.get(slot_id_str) orelse return error.SlotNotFound;
            const typed_ptr: *slotTypeFn(slot) = @ptrCast(@alignCast(ptr));
            return typed_ptr.*;
        }

        /// Get optional slot value (null if not present)
        pub fn optional(self: Self, comptime slot: SlotEnum) ?slotTypeFn(slot) {
            // Comptime check: slot must be in reads
            comptime {
                var found = false;
                for (reads) |r| {
                    if (r == slot) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Slot not in declared reads");
                }
            }

            // Debug tracking
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_reads.set(slot_id);
            }

            const slot_id_str = std.fmt.comptimePrint("{d}", .{@intFromEnum(slot)});
            const ptr = self.base.slots.get(slot_id_str) orelse return null;
            const typed_ptr: *slotTypeFn(slot) = @ptrCast(@alignCast(ptr));
            return typed_ptr.*;
        }

        /// Put a slot value
        pub fn put(self: Self, comptime slot: SlotEnum, value: slotTypeFn(slot)) !void {
            // Comptime check: slot must be in writes
            comptime {
                var found = false;
                for (writes) |w| {
                    if (w == slot) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Slot not in declared writes");
                }
            }

            // Debug tracking
            if (builtin.mode == .Debug) {
                const slot_id = @intFromEnum(slot);
                self.base.debug_slot_usage.actual_writes.set(slot_id);
            }

            const slot_id_str = std.fmt.comptimePrint("{d}", .{@intFromEnum(slot)});
            const value_ptr = try self.base.allocator.create(slotTypeFn(slot));
            value_ptr.* = value;
            try self.base.slots.put(slot_id_str, @ptrCast(value_ptr));
        }
    };
}

/// Step decision result
pub const Decision = union(enum) {
    /// Continue to next step
    Continue: void,

    /// Need to perform effects
    need: Need,

    /// Complete with response
    Done: Response,

    /// Fail with error
    Fail: Error,
};

/// Effects needed by a step
pub const Need = struct {
    effects: []const Effect,
    mode: Mode,
    join: Join,
    compensations: ?[]const Effect,
};

/// Effect execution mode
pub const Mode = enum {
    Sequential,
    Parallel,
};

/// Join strategy for parallel effects
pub const Join = enum {
    all,
    all_required,
    any,
    first_success,
};

/// Effect intermediate representation
pub const Effect = union(enum) {
    db_get: DbGetEffect,
    db_put: DbPutEffect,
    db_del: DbDelEffect,
    db_query: DbQueryEffect,
    http_call: HttpCallEffect,
    compute_task: ComputeTask,
    compensate: CompensateEffect,
};

/// Database GET effect
pub const DbGetEffect = struct {
    database: []const u8,
    key: []const u8,
    result_slot: u32,
};

/// Database PUT effect
pub const DbPutEffect = struct {
    database: []const u8,
    key: []const u8,
    value: []const u8,
    result_slot: ?u32,
};

/// Database DELETE effect
pub const DbDelEffect = struct {
    database: []const u8,
    key: []const u8,
    result_slot: ?u32,
};

/// SQL parameter for queries
pub const SqlParam = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null: void,
};

/// Database QUERY effect
pub const DbQueryEffect = struct {
    database: []const u8,
    query: []const u8,
    params: []const SqlParam,
    result_slot: u32,
};

/// HTTP method enum
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP call effect
pub const HttpCallEffect = struct {
    method: HttpMethod,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
    result_slot: u32,
    timeout_ms: ?u32,
};

/// Compute task effect (for CPU-bound work)
pub const ComputeTask = struct {
    task_type: []const u8,
    input: []const u8,
    result_slot: u32,
};

/// HTTP header key-value pair
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Compensation action union
pub const CompensationAction = union(enum) {
    db_delete: struct { database: []const u8, key: []const u8 },
    db_restore: struct { database: []const u8, key: []const u8, old_value: []const u8 },
    http_rollback: struct { url: []const u8, payload: []const u8 },
    custom: *const fn (*CtxBase) anyerror!void,
};

/// Compensation effect
pub const CompensateEffect = struct {
    action: CompensationAction,
};

/// Response with inline small-vector headers optimization
pub const Response = struct {
    status: u16,
    body: Body,
    headers_inline: [8]?Header, // Small-vector optimization
    headers_extra: ?std.ArrayList(Header), // Overflow for many headers
    headers_count: u8,

    pub fn init(status: u16, body: Body) Response {
        return .{
            .status = status,
            .body = body,
            .headers_inline = [_]?Header{null} ** 8,
            .headers_extra = null,
            .headers_count = 0,
        };
    }

    pub fn addHeader(self: *Response, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const header = Header{ .name = name, .value = value };

        if (self.headers_count < 8) {
            self.headers_inline[self.headers_count] = header;
            self.headers_count += 1;
        } else {
            if (self.headers_extra == null) {
                self.headers_extra = std.ArrayList(Header){};
            }
            try self.headers_extra.?.append(allocator, header);
            self.headers_count += 1;
        }
    }

    /// Get all headers as a slice (combining inline and extra)
    pub fn headers(self: *const Response, allocator: std.mem.Allocator) ![]Header {
        var result = try allocator.alloc(Header, self.headers_count);
        var idx: usize = 0;

        // Copy inline headers
        for (self.headers_inline) |maybe_header| {
            if (maybe_header) |h| {
                result[idx] = h;
                idx += 1;
            }
        }

        // Copy extra headers
        if (self.headers_extra) |extra| {
            for (extra.items) |h| {
                result[idx] = h;
                idx += 1;
            }
        }

        return result;
    }

    pub fn deinit(self: *Response) void {
        if (self.headers_extra) |*extra| {
            extra.deinit();
        }
    }
};

/// Response body (complete or streaming)
pub const Body = union(enum) {
    /// Complete body in memory
    complete: []const u8,

    /// Streaming body (stub for future implementation)
    streaming: void,
};

/// Error with structured fields
pub const Error = struct {
    code: []const u8,
    entity: []const u8,
    reason: []const u8,
    context: ?[]const u8,

    pub fn init(code: []const u8, entity: []const u8, reason: []const u8) Error {
        return .{
            .code = code,
            .entity = entity,
            .reason = reason,
            .context = null,
        };
    }
};

/// Common error codes
pub const ErrorCode = enum {
    InvalidInput,
    NotFound,
    Unauthorized,
    Forbidden,
    Conflict,
    InternalError,
    ServiceUnavailable,

    pub fn toString(self: ErrorCode) []const u8 {
        return switch (self) {
            .InvalidInput => "INVALID_INPUT",
            .NotFound => "NOT_FOUND",
            .Unauthorized => "UNAUTHORIZED",
            .Forbidden => "FORBIDDEN",
            .Conflict => "CONFLICT",
            .InternalError => "INTERNAL_ERROR",
            .ServiceUnavailable => "SERVICE_UNAVAILABLE",
        };
    }
};

/// Helper: Continue to next step
pub fn continue_() Decision {
    return .{ .Continue = {} };
}

/// Helper: Complete with response
pub fn done(response: Response) Decision {
    return .{ .Done = response };
}

/// Helper: Fail with error
pub fn fail(code: ErrorCode, entity: []const u8, reason: []const u8) Decision {
    return .{ .Fail = Error.init(code.toString(), entity, reason) };
}

/// Database operation type
pub const DbOperation = enum {
    get,
    put,
    del,
    query,
};

/// HTTP configuration
pub const HttpConfig = struct {
    url: []const u8,
    method: HttpMethod = .GET,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

/// Helper: Create HTTP JSON POST effect
pub fn httpJsonPost(url: []const u8, json_body: []const u8, result_slot: u32) Effect {
    const content_type = Header{ .name = "Content-Type", .value = "application/json" };
    const headers = &[_]Header{content_type};

    return .{ .http_call = .{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = json_body,
        .result_slot = result_slot,
        .timeout_ms = null,
    }};
}

/// Helper: Create database query effect
pub fn dbQ(database: []const u8, query: []const u8, params: []const SqlParam, result_slot: u32) Effect {
    return .{ .db_query = .{
        .database = database,
        .query = query,
        .params = params,
        .result_slot = result_slot,
    }};
}

/// Step specification with metadata
pub const StepSpec = struct {
    name: []const u8,
    fn_ptr: *const fn (*CtxBase) anyerror!Decision,
    reads: []const u32,
    writes: []const u32,

    /// Call the step function with assertion tracking
    pub fn call(self: StepSpec, ctx: *CtxBase) !Decision {
        // Initialize debug tracking for this step
        if (builtin.mode == .Debug) {
            // Mark declared reads/writes
            for (self.reads) |slot_id| {
                ctx.debug_slot_usage.declared_reads.set(slot_id);
            }
            for (self.writes) |slot_id| {
                ctx.debug_slot_usage.declared_writes.set(slot_id);
            }
        }

        // Execute step
        const decision = try self.fn_ptr(ctx);

        // Validate slot usage after step completes
        if (builtin.mode == .Debug) {
            switch (decision) {
                .Continue, .Done => {
                    try assertSlotUsage(ctx, self.name);
                },
                .need => {
                    try assertReadsUsed(ctx, self.name);
                },
                .Fail => {}, // Skip assertion on failure
            }
        }

        return decision;
    }
};

/// Assert that all declared slots were used
fn assertSlotUsage(ctx: *CtxBase, step_name: []const u8) !void {
    if (builtin.mode != .Debug) return;

    const usage = ctx.debug_slot_usage;
    const policy = ctx.assertion_policy;

    // Check reads
    var read_iter = usage.declared_reads.iterator(.{});
    while (read_iter.next()) |slot_id| {
        if (!usage.actual_reads.isSet(slot_id)) {
            if (policy.must_use_reads and !policy.warn_unused_reads) {
                std.log.err("Step '{s}' declared read for slot {d} but never used it", .{step_name, slot_id});
                return error.UnusedSlotRead;
            } else if (policy.warn_unused_reads) {
                std.log.warn("Step '{s}' declared read for slot {d} but never used it", .{step_name, slot_id});
            }
        }
    }

    // Check writes
    var write_iter = usage.declared_writes.iterator(.{});
    while (write_iter.next()) |slot_id| {
        if (!usage.actual_writes.isSet(slot_id)) {
            if (policy.must_use_writes and !policy.warn_unused_writes) {
                std.log.err("Step '{s}' declared write for slot {d} but never used it", .{step_name, slot_id});
                return error.UnusedSlotWrite;
            } else if (policy.warn_unused_writes) {
                std.log.warn("Step '{s}' declared write for slot {d} but never used it", .{step_name, slot_id});
            }
        }
    }
}

/// Assert that all declared reads were used (for need variant)
fn assertReadsUsed(ctx: *CtxBase, step_name: []const u8) !void {
    if (builtin.mode != .Debug) return;

    const usage = ctx.debug_slot_usage;
    const policy = ctx.assertion_policy;

    var read_iter = usage.declared_reads.iterator(.{});
    while (read_iter.next()) |slot_id| {
        if (!usage.actual_reads.isSet(slot_id)) {
            if (policy.must_use_reads and !policy.warn_unused_reads) {
                std.log.err("Step '{s}' declared read for slot {d} but never used it before need", .{step_name, slot_id});
                return error.UnusedSlotRead;
            } else if (policy.warn_unused_reads) {
                std.log.warn("Step '{s}' declared read for slot {d} but never used it before need", .{step_name, slot_id});
            }
        }
    }
}

/// Resource budget for a route
pub const ResourceBudget = struct {
    max_cpu_ms: ?u32 = null,
    max_memory_bytes: ?usize = null,
    max_concurrent_effects: ?u32 = null,
};

/// Route specification
pub const RouteSpec = struct {
    path: []const u8,
    method: HttpMethod,
    steps: []const StepSpec,
    budget: ResourceBudget,

    pub fn init(path: []const u8, method: HttpMethod, steps: []const StepSpec) RouteSpec {
        return .{
            .path = path,
            .method = method,
            .steps = steps,
            .budget = .{},
        };
    }
};

/// Comptime route validation with dependency checking
pub fn routeChecked(
    comptime path: []const u8,
    comptime method: HttpMethod,
    comptime steps: []const StepSpec,
    comptime checks: struct {
        require_reads_produced: bool = true,
        forbid_duplicate_writers: bool = true,
        warn_unread_writes: bool = true,
    },
) RouteSpec {
    comptime {
        var produced = std.StaticBitSet(256).initEmpty();
        var consumed = std.StaticBitSet(256).initEmpty();
        var writers = std.StaticBitSet(256).initEmpty();

        // Build dependency graph
        for (steps) |step| {
            // Check reads
            for (step.reads) |slot_id| {
                consumed.set(slot_id);

                if (checks.require_reads_produced and !produced.isSet(slot_id)) {
                    @compileError(std.fmt.comptimePrint(
                        "Step '{s}' reads slot {d} but it was never written by a previous step",
                        .{step.name, slot_id}
                    ));
                }
            }

            // Check writes
            for (step.writes) |slot_id| {
                if (checks.forbid_duplicate_writers and writers.isSet(slot_id)) {
                    @compileError(std.fmt.comptimePrint(
                        "Step '{s}' writes to slot {d} but another step already wrote to it",
                        .{step.name, slot_id}
                    ));
                }

                produced.set(slot_id);
                writers.set(slot_id);
            }
        }

        // Warn on unread writes
        if (checks.warn_unread_writes) {
            var write_iter = produced.iterator(.{});
            while (write_iter.next()) |slot_id| {
                if (!consumed.isSet(slot_id)) {
                    // Can't use @compileLog for warnings, so this will be compile-time info
                    // Silently skip for now - would need custom warning mechanism
                }
            }
        }
    }

    return RouteSpec.init(path, method, steps);
}

/// Compensation tracker for saga rollback
pub const CompensationTracker = struct {
    compensations: std.ArrayList(Effect),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompensationTracker {
        const AL = std.ArrayList(Effect);
        return .{
            .compensations = AL.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompensationTracker) void {
        self.compensations.deinit(self.allocator);
    }

    /// Track a compensation action
    pub fn track(self: *CompensationTracker, compensation: Effect) !void {
        try self.compensations.append(compensation);
    }

    /// Run compensations in reverse order
    pub fn runCompensations(self: *CompensationTracker, ctx: *CtxBase, effectors: *EffectorTable) !void {
        std.log.info("Running {d} compensations", .{self.compensations.items.len});

        var i = self.compensations.items.len;
        while (i > 0) {
            i -= 1;
            const compensation = self.compensations.items[i];

            std.log.debug("Executing compensation {d}", .{i});
            try effectors.execute(ctx, compensation);
        }
    }
};

/// Pure interpreter for step pipelines
pub const Interpreter = struct {
    steps: []const StepSpec,
    current_step: usize,

    pub fn init(steps: []const StepSpec) Interpreter {
        return .{
            .steps = steps,
            .current_step = 0,
        };
    }

    /// Execute steps until we hit a Need or Done/Fail
    pub fn evalUntilNeedOrDone(self: *Interpreter, ctx: *CtxBase) !Decision {
        while (self.current_step < self.steps.len) {
            const step = self.steps[self.current_step];
            const decision = try step.call(ctx);

            switch (decision) {
                .Continue => {
                    self.current_step += 1;
                    continue;
                },
                .need => {
                    // Pause here, will resume after effects execute
                    return decision;
                },
                .Done => {
                    return decision;
                },
                .Fail => {
                    return decision;
                },
            }
        }

        // All steps completed without explicit Done
        return continue_();
    }

    /// Resume execution after effects complete
    pub fn resumeExecution(self: *Interpreter, ctx: *CtxBase) !Decision {
        self.current_step += 1;
        return self.evalUntilNeedOrDone(ctx);
    }
};

/// Effector table for executing effects (stub implementations)
pub const EffectorTable = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EffectorTable {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *EffectorTable, ctx: *CtxBase, effect: Effect) !void {
        switch (effect) {
            .db_get => |e| try self.executeDbGet(ctx, e),
            .db_put => |e| try self.executeDbPut(ctx, e),
            .db_del => |e| try self.executeDbDel(ctx, e),
            .db_query => |e| try self.executeDbQuery(ctx, e),
            .http_call => |e| try self.executeHttpCall(ctx, e),
            .compute_task => |e| try self.executeCompute(ctx, e),
            .compensate => {}, // Handled separately
        }
    }

    fn executeDbGet(self: *EffectorTable, ctx: *CtxBase, effect: DbGetEffect) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual database get
        std.log.debug("DB GET: {s}/{s} -> slot {d}", .{effect.database, effect.key, effect.result_slot});
    }

    fn executeDbPut(self: *EffectorTable, ctx: *CtxBase, effect: DbPutEffect) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual database put
        std.log.debug("DB PUT: {s}/{s}", .{effect.database, effect.key});
    }

    fn executeDbDel(self: *EffectorTable, ctx: *CtxBase, effect: DbDelEffect) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual database delete
        std.log.debug("DB DEL: {s}/{s}", .{effect.database, effect.key});
    }

    fn executeDbQuery(self: *EffectorTable, ctx: *CtxBase, effect: DbQueryEffect) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual database query
        std.log.debug("DB QUERY: {s} -> slot {d}", .{effect.database, effect.result_slot});
    }

    fn executeHttpCall(self: *EffectorTable, ctx: *CtxBase, effect: HttpCallEffect) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual HTTP call
        std.log.debug("HTTP {s}: {s} -> slot {d}", .{effect.method.toString(), effect.url, effect.result_slot});
    }

    fn executeCompute(self: *EffectorTable, ctx: *CtxBase, effect: ComputeTask) !void {
        _ = self;
        _ = ctx;
        // TODO: Implement actual compute dispatch
        std.log.debug("COMPUTE: {s} -> slot {d}", .{effect.task_type, effect.result_slot});
    }
};

/// Effect executor for sequential and parallel execution
pub const EffectExecutor = struct {
    effectors: *EffectorTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, effectors: *EffectorTable) EffectExecutor {
        return .{
            .effectors = effectors,
            .allocator = allocator,
        };
    }

    /// Execute effects sequentially
    pub fn executeSequential(self: *EffectExecutor, ctx: *CtxBase, effects: []const Effect) !void {
        for (effects) |effect| {
            try self.effectors.execute(ctx, effect);
        }
    }

    /// Execute effects in parallel (stub - would use thread pool)
    pub fn executeParallel(self: *EffectExecutor, ctx: *CtxBase, effects: []const Effect, join: Join) !void {
        _ = join;
        // For now, just execute sequentially
        // TODO: Implement actual parallel execution with thread pool
        for (effects) |effect| {
            try self.effectors.execute(ctx, effect);
        }
    }
};

/// HTTP security policy for SSRF protection
pub const HttpSecurityPolicy = struct {
    allowed_hosts: []const []const u8 = &.{},
    forbidden_schemes: []const []const u8 = &.{"file", "ftp"},
    max_response_size: usize = 10 * 1024 * 1024,
    default_timeout_ms: u32 = 30_000,
    follow_redirects: bool = false,
};

/// Validate HTTP effect against security policy
pub fn validateHttpEffect(effect: HttpCallEffect, policy: HttpSecurityPolicy) !void {
    // Check scheme
    for (policy.forbidden_schemes) |scheme| {
        if (std.mem.startsWith(u8, effect.url, scheme)) {
            std.log.err("Forbidden URL scheme: {s}", .{scheme});
            return error.ForbiddenScheme;
        }
    }

    // Check host allowlist if configured
    if (policy.allowed_hosts.len > 0) {
        var allowed = false;
        for (policy.allowed_hosts) |pattern| {
            if (matchHostPattern(effect.url, pattern)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
            std.log.err("Host not in allowlist: {s}", .{effect.url});
            return error.HostNotAllowed;
        }
    }
}

/// Match URL against host pattern (supports wildcards)
fn matchHostPattern(url: []const u8, pattern: []const u8) bool {
    // Simple wildcard matching for *.example.com
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[2..];
        return std.mem.indexOf(u8, url, suffix) != null;
    }
    return std.mem.indexOf(u8, url, pattern) != null;
}

/// SQL security policy
pub const SqlSecurityPolicy = struct {
    forbidden_keywords: []const []const u8 = &.{"DROP", "TRUNCATE", "DELETE FROM", "ALTER"},
    require_parameterized: bool = true,
};

/// Validate SQL query against security policy
pub fn validateSqlQuery(query: []const u8, params: []const SqlParam, policy: SqlSecurityPolicy) !void {
    // Check for forbidden keywords
    for (policy.forbidden_keywords) |keyword| {
        if (std.mem.indexOf(u8, query, keyword) != null) {
            std.log.err("Forbidden SQL keyword: {s}", .{keyword});
            return error.ForbiddenSqlKeyword;
        }
    }

    // Check parameterization if required
    if (policy.require_parameterized) {
        if (params.len == 0 and std.mem.indexOf(u8, query, "WHERE") != null) {
            std.log.warn("Query has WHERE clause but no parameters", .{});
            // This is a warning, not an error, as some queries may legitimately have no params
        }
    }
}

/// Trace event for observability
pub const TraceEvent = union(enum) {
    request_start: struct { request_id: []const u8, method: []const u8, path: []const u8, timestamp_ns: i64 },
    step_start: struct { request_id: []const u8, step_name: []const u8, step_index: u32, timestamp_ns: i64 },
    step_end: struct { request_id: []const u8, step_name: []const u8, decision: []const u8, duration_ns: i64 },
    effect_start: struct { request_id: []const u8, step_name: []const u8, effect_type: []const u8, effect_index: u32, timestamp_ns: i64 },
    effect_end: struct { request_id: []const u8, effect_type: []const u8, outcome: []const u8, duration_ns: i64 },
    slot_write: struct { request_id: []const u8, step_name: []const u8, slot_id: u32, timestamp_ns: i64 },
    request_end: struct { request_id: []const u8, status: u16, duration_ns: i64 },
};

/// Trace collector (stub - would write to structured log)
pub const TraceCollector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TraceCollector {
        return .{ .allocator = allocator };
    }

    pub fn emit(self: *TraceCollector, event: TraceEvent) void {
        _ = self;
        // TODO: Write to actual trace backend
        logTraceEvent(event);
    }
};

/// Log trace event to standard logging
fn logTraceEvent(event: TraceEvent) void {
    switch (event) {
        .request_start => |e| std.log.info("REQUEST_START: {s} {s} {s}", .{e.request_id, e.method, e.path}),
        .step_start => |e| std.log.debug("STEP_START: {s} step={s} idx={d}", .{e.request_id, e.step_name, e.step_index}),
        .step_end => |e| std.log.debug("STEP_END: {s} step={s} decision={s} dur={d}ns", .{e.request_id, e.step_name, e.decision, e.duration_ns}),
        .effect_start => |e| std.log.debug("EFFECT_START: {s} step={s} type={s} idx={d}", .{e.request_id, e.step_name, e.effect_type, e.effect_index}),
        .effect_end => |e| std.log.debug("EFFECT_END: {s} type={s} outcome={s} dur={d}ns", .{e.request_id, e.effect_type, e.outcome, e.duration_ns}),
        .slot_write => |e| std.log.debug("SLOT_WRITE: {s} step={s} slot={d}", .{e.request_id, e.step_name, e.slot_id}),
        .request_end => |e| std.log.info("REQUEST_END: {s} status={d} dur={d}ns", .{e.request_id, e.status, e.duration_ns}),
    }
}

// ============================================================================
// Tests
// ============================================================================

test "SlotSchema - slotId and TypeOf" {
    const TestSlot = enum(u32) {
        Input = 0,
        Output = 1,
    };

    const slotTypeFn = struct {
        fn f(comptime slot: TestSlot) type {
            return switch (slot) {
                .Input => []const u8,
                .Output => u32,
            };
        }
    }.f;

    const schema = SlotSchema(TestSlot, slotTypeFn);

    try std.testing.expectEqual(@as(u32, 0), schema.slotId(.Input));
    try std.testing.expectEqual(@as(u32, 1), schema.slotId(.Output));
    try std.testing.expectEqual([]const u8, schema.TypeOf(.Input));
    try std.testing.expectEqual(u32, schema.TypeOf(.Output));
}

test "CtxBase - init and deinit" {
    const testing = std.testing;

    var ctx = try CtxBase.init(testing.allocator, "test-request-123");
    defer ctx.deinit();

    try testing.expectEqualStrings("test-request-123", ctx.request_id);
}

test "Response - addHeader inline" {
    const testing = std.testing;

    const body = Body{ .complete = "test body" };
    var response = Response.init(200, body);
    defer response.deinit();

    try response.addHeader(testing.allocator, "Content-Type", "application/json");
    try response.addHeader(testing.allocator, "X-Request-ID", "123");

    try testing.expectEqual(@as(u8, 2), response.headers_count);
    try testing.expect(response.headers_inline[0] != null);
    try testing.expectEqualStrings("Content-Type", response.headers_inline[0].?.name);
}

test "Response - addHeader overflow" {
    const testing = std.testing;

    const body = Body{ .complete = "test body" };
    var response = Response.init(200, body);
    defer response.deinit();

    // Add 10 headers (8 inline + 2 overflow)
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        try response.addHeader(testing.allocator, "Header", "Value");
    }

    try testing.expectEqual(@as(u8, 10), response.headers_count);
    try testing.expect(response.headers_extra != null);
    try testing.expectEqual(@as(usize, 2), response.headers_extra.?.items.len);
}

test "Decision - continue helper" {
    const decision = continue_();
    try std.testing.expect(decision == .Continue);
}

test "Decision - done helper" {
    const body = Body{ .complete = "response" };
    const response = Response.init(200, body);
    const decision = done(response);
    try std.testing.expect(decision == .Done);
    try std.testing.expectEqual(@as(u16, 200), decision.Done.status);
}

test "Decision - fail helper" {
    const decision = fail(.InvalidInput, "user", "missing_name");
    try std.testing.expect(decision == .Fail);
    try std.testing.expectEqualStrings("INVALID_INPUT", decision.Fail.code);
    try std.testing.expectEqualStrings("user", decision.Fail.entity);
}

test "Effect - httpJsonPost helper" {
    const effect = httpJsonPost("https://api.example.com/users", "{\"name\":\"test\"}", 42);
    try std.testing.expect(effect == .http_call);
    try std.testing.expectEqual(HttpMethod.POST, effect.http_call.method);
    try std.testing.expectEqual(@as(u32, 42), effect.http_call.result_slot);
}

test "Effect - dbQ helper" {
    const params = &[_]SqlParam{SqlParam{ .string = "test" }};
    const effect = dbQ("main", "SELECT * FROM users WHERE name = ?", params, 10);
    try std.testing.expect(effect == .db_query);
    try std.testing.expectEqualStrings("main", effect.db_query.database);
    try std.testing.expectEqual(@as(u32, 10), effect.db_query.result_slot);
}

test "Interpreter - Continue flow" {
    const testing = std.testing;

    const TestStep = struct {
        fn step(_: *CtxBase) !Decision {
            return continue_();
        }
    };

    const steps = &[_]StepSpec{
        .{ .name = "step1", .fn_ptr = TestStep.step, .reads = &.{}, .writes = &.{} },
    };

    var ctx = try CtxBase.init(testing.allocator, "test-123");
    defer ctx.deinit();

    var interpreter = Interpreter.init(steps);
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    try testing.expect(decision == .Continue);
}

test "Interpreter - Done flow" {
    const testing = std.testing;

    const TestStep = struct {
        fn step(_: *CtxBase) !Decision {
            const body = Body{ .complete = "test" };
            const response = Response.init(200, body);
            return done(response);
        }
    };

    const steps = &[_]StepSpec{
        .{ .name = "step1", .fn_ptr = TestStep.step, .reads = &.{}, .writes = &.{} },
    };

    var ctx = try CtxBase.init(testing.allocator, "test-123");
    defer ctx.deinit();

    var interpreter = Interpreter.init(steps);
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    try testing.expect(decision == .Done);
    try testing.expectEqual(@as(u16, 200), decision.Done.status);
}

test "HttpSecurityPolicy - forbidden scheme" {
    const policy = HttpSecurityPolicy{};
    const effect = HttpCallEffect{
        .method = .GET,
        .url = "file:///etc/passwd",
        .headers = &.{},
        .body = null,
        .result_slot = 0,
        .timeout_ms = null,
    };

    const result = validateHttpEffect(effect, policy);
    try std.testing.expectError(error.ForbiddenScheme, result);
}

test "HttpSecurityPolicy - host allowlist" {
    const allowed_hosts = &[_][]const u8{"api.example.com"};
    const policy = HttpSecurityPolicy{ .allowed_hosts = allowed_hosts };

    const good_effect = HttpCallEffect{
        .method = .GET,
        .url = "https://api.example.com/users",
        .headers = &.{},
        .body = null,
        .result_slot = 0,
        .timeout_ms = null,
    };

    try validateHttpEffect(good_effect, policy);

    const bad_effect = HttpCallEffect{
        .method = .GET,
        .url = "https://evil.com/steal",
        .headers = &.{},
        .body = null,
        .result_slot = 0,
        .timeout_ms = null,
    };

    const result = validateHttpEffect(bad_effect, policy);
    try std.testing.expectError(error.HostNotAllowed, result);
}

test "SqlSecurityPolicy - forbidden keywords" {
    const policy = SqlSecurityPolicy{};
    const params = &[_]SqlParam{};

    const result = validateSqlQuery("DROP TABLE users", params, policy);
    try std.testing.expectError(error.ForbiddenSqlKeyword, result);
}

test "EffectorTable - execute stubs" {
    const testing = std.testing;

    var effectors = EffectorTable.init(testing.allocator);
    var ctx = try CtxBase.init(testing.allocator, "test-123");
    defer ctx.deinit();

    const db_get = Effect{ .db_get = .{
        .database = "main",
        .key = "user:123",
        .result_slot = 1,
    }};

    // Just verify it doesn't crash
    try effectors.execute(&ctx, db_get);
}

test "TraceCollector - emit event" {
    const testing = std.testing;

    var collector = TraceCollector.init(testing.allocator);

    const event = TraceEvent{ .request_start = .{
        .request_id = "test-123",
        .method = "GET",
        .path = "/api/users",
        .timestamp_ns = 0,
    }};

    // Just verify it doesn't crash
    collector.emit(event);
}

test "CompensationTracker - track and run" {
    const testing = std.testing;

    var tracker = CompensationTracker.init(testing.allocator);
    defer tracker.deinit();

    // Track some compensations
    const comp1 = Effect{ .db_del = .{
        .database = "main",
        .key = "temp_key",
        .result_slot = null,
    }};

    try tracker.track(comp1);
    try testing.expectEqual(@as(usize, 1), tracker.compensations.items.len);

    // Run compensations
    var ctx = try CtxBase.init(testing.allocator, "test-123");
    defer ctx.deinit();

    var effectors = EffectorTable.init(testing.allocator);
    try tracker.runCompensations(&ctx, &effectors);
}

test "routeChecked - validates dependencies" {
    // Slot indices: Input=0, Processed=1, Output=2
    const step1 = StepSpec{
        .name = "parse",
        .fn_ptr = undefined,
        .reads = &.{},
        .writes = &.{0}, // Writes Input
    };

    const step2 = StepSpec{
        .name = "process",
        .fn_ptr = undefined,
        .reads = &.{0}, // Reads Input
        .writes = &.{1}, // Writes Processed
    };

    const step3 = StepSpec{
        .name = "format",
        .fn_ptr = undefined,
        .reads = &.{1}, // Reads Processed
        .writes = &.{2}, // Writes Output
    };

    const steps = &[_]StepSpec{ step1, step2, step3 };

    const route = routeChecked("/api/test", .POST, steps, .{});
    try std.testing.expectEqualStrings("/api/test", route.path);
    try std.testing.expectEqual(HttpMethod.POST, route.method);
}

// ============================================================================
// Examples
// ============================================================================

// Example: Minimal happy-path pipeline
test "Example - minimal happy path" {
    const testing = std.testing;

    // Define slots: ParsedInput=0, Result=1

    // Define steps
    const ParseStep = struct {
        fn execute(ctx: *CtxBase) !Decision {
            _ = ctx;
            // In real code: parse JSON, validate, etc.
            // ctx.put(Slot.ParsedInput, parsed_data);
            return continue_();
        }
    };

    const ProcessStep = struct {
        fn execute(ctx: *CtxBase) !Decision {
            _ = ctx;
            // In real code: business logic
            // const input = ctx.require(Slot.ParsedInput);
            // ctx.put(Slot.Result, computed_result);
            return continue_();
        }
    };

    const RespondStep = struct {
        fn execute(_: *CtxBase) !Decision {
            const body = Body{ .complete = "{\"status\":\"ok\"}" };
            var response = Response.init(200, body);
            try response.addHeader(testing.allocator, "Content-Type", "application/json");
            return done(response);
        }
    };

    // Build route
    const steps = &[_]StepSpec{
        .{ .name = "parse", .fn_ptr = ParseStep.execute, .reads = &.{}, .writes = &.{0} },
        .{ .name = "process", .fn_ptr = ProcessStep.execute, .reads = &.{0}, .writes = &.{1} },
        .{ .name = "respond", .fn_ptr = RespondStep.execute, .reads = &.{1}, .writes = &.{} },
    };

    const route = routeChecked("/api/process", .POST, steps, .{});

    // Execute pipeline
    var ctx = try CtxBase.init(testing.allocator, "req-001");
    defer ctx.deinit();

    var interpreter = Interpreter.init(route.steps);
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    try testing.expect(decision == .Done);
    try testing.expectEqual(@as(u16, 200), decision.Done.status);
}

// Example: Saga with compensations
test "Example - saga with compensations" {
    const testing = std.testing;

    // Slot indices: OrderId=0, PaymentId=1, ShipmentId=2

    const CreateOrderStep = struct {
        fn execute(ctx: *CtxBase) !Decision {
            _ = ctx;
            // Simulate order creation that needs effect
            const db_put = Effect{ .db_put = .{
                .database = "orders",
                .key = "order:123",
                .value = "{\"total\":100}",
                .result_slot = 0,
            }};

            const compensation = Effect{ .db_del = .{
                .database = "orders",
                .key = "order:123",
                .result_slot = null,
            }};

            return .{ .need = Need{
                .effects = &[_]Effect{db_put},
                .mode = .Sequential,
                .join = .all,
                .compensations = &[_]Effect{compensation},
            }};
        }
    };

    const ProcessPaymentStep = struct {
        fn execute(ctx: *CtxBase) !Decision {
            _ = ctx;
            // Simulate payment processing
            const http_call = httpJsonPost(
                "https://payment.api/charge",
                "{\"amount\":100}",
                1
            );

            const compensation = Effect{ .compensate = .{
                .action = .{ .http_rollback = .{
                    .url = "https://payment.api/refund",
                    .payload = "{\"payment_id\":\"pay_123\"}",
                }},
            }};

            return .{ .need = Need{
                .effects = &[_]Effect{http_call},
                .mode = .Sequential,
                .join = .all,
                .compensations = &[_]Effect{compensation},
            }};
        }
    };

    const steps = &[_]StepSpec{
        .{ .name = "create_order", .fn_ptr = CreateOrderStep.execute, .reads = &.{}, .writes = &.{0} },
        .{ .name = "process_payment", .fn_ptr = ProcessPaymentStep.execute, .reads = &.{0}, .writes = &.{1} },
    };

    const route = RouteSpec.init("/api/checkout", .POST, steps);

    // Execute with compensation tracking
    var ctx = try CtxBase.init(testing.allocator, "checkout-001");
    defer ctx.deinit();

    var tracker = CompensationTracker.init(testing.allocator);
    defer tracker.deinit();

    var interpreter = Interpreter.init(route.steps);
    var effectors = EffectorTable.init(testing.allocator);

    // First step
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);
    try testing.expect(decision == .need);

    // Track compensation
    if (decision.need.compensations) |comps| {
        for (comps) |comp| {
            try tracker.track(comp);
        }
    }

    // Execute effects
    var executor = EffectExecutor.init(testing.allocator, &effectors);
    try executor.executeSequential(&ctx, decision.need.effects);

    // Simulate failure in second step - run compensations
    try tracker.runCompensations(&ctx, &effectors);
}

// Example: Parallel effects with different join strategies
test "Example - parallel effects" {
    const testing = std.testing;

    const ParallelStep = struct {
        fn execute(_: *CtxBase) !Decision {
            const effects = &[_]Effect{
                Effect{ .http_call = .{
                    .method = .GET,
                    .url = "https://api1.com/data",
                    .headers = &.{},
                    .body = null,
                    .result_slot = 0,
                    .timeout_ms = 5000,
                }},
                Effect{ .http_call = .{
                    .method = .GET,
                    .url = "https://api2.com/data",
                    .headers = &.{},
                    .body = null,
                    .result_slot = 1,
                    .timeout_ms = 5000,
                }},
                Effect{ .http_call = .{
                    .method = .GET,
                    .url = "https://api3.com/data",
                    .headers = &.{},
                    .body = null,
                    .result_slot = 2,
                    .timeout_ms = 5000,
                }},
            };

            // Execute in parallel, wait for all
            return .{ .need = Need{
                .effects = effects,
                .mode = .Parallel,
                .join = .all, // Could also use .any, .all_required, .first_success
                .compensations = null,
            }};
        }
    };

    const steps = &[_]StepSpec{
        .{ .name = "fetch_parallel", .fn_ptr = ParallelStep.execute, .reads = &.{}, .writes = &.{0, 1, 2} },
    };

    var ctx = try CtxBase.init(testing.allocator, "parallel-001");
    defer ctx.deinit();

    var interpreter = Interpreter.init(steps);
    const decision = try interpreter.evalUntilNeedOrDone(&ctx);

    try testing.expect(decision == .need);
    try testing.expectEqual(Mode.Parallel, decision.need.mode);
    try testing.expectEqual(Join.all, decision.need.join);
    try testing.expectEqual(@as(usize, 3), decision.need.effects.len);
}
