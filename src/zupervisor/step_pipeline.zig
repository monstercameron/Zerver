// src/zupervisor/step_pipeline.zig
/// Step-based pipeline execution for request handlers
/// Enables composable request processing: [auth] → [validate] → [compute] → [respond]

const std = @import("std");
// TODO: Fix slog import to avoid module conflicts

/// Result from executing a step
pub const StepResult = enum(c_int) {
    /// Continue to next step in pipeline
    Continue = 0,
    /// Stop pipeline and return current response
    Complete = 1,
    /// Abort pipeline with error
    Error = 2,
};

/// Context passed through the step pipeline
/// Contains request data, response builder, and step-specific state
pub const StepContext = extern struct {
    // Request information
    request: *anyopaque, // RequestContext from DLL perspective

    // Response building
    response: *anyopaque, // ResponseBuilder from DLL perspective

    // Step-specific state (key-value store for inter-step communication)
    state: *anyopaque, // Will be a HashMap or similar

    // Allocator for dynamic allocations within steps
    allocator: *anyopaque,

    // Server adapter for calling response-building functions
    server: *const ServerAdapter,
};

/// Server adapter with optional slot-effect support
pub const ServerAdapter = extern struct {
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: *const fn (*anyopaque, c_int, [*c]const u8, usize, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int) callconv(.c) c_int,
    setStatus: *const fn (*anyopaque, c_int) callconv(.c) void,
    setHeader: *const fn (*anyopaque, [*c]const u8, usize, [*c]const u8, usize) callconv(.c) c_int,
    setBody: *const fn (*anyopaque, [*c]const u8, usize) callconv(.c) c_int,

    // Optional slot-effect support (can be null for legacy step-based handlers)
    createSlotContext: ?*const fn (*anyopaque, [*c]const u8, usize) callconv(.c) ?*anyopaque,
    destroySlotContext: ?*const fn (*anyopaque) callconv(.c) void,
    executeEffect: ?*const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) c_int,
    traceEvent: ?*const fn (*anyopaque, *anyopaque) callconv(.c) void,
};

/// A step function exported by a DLL
/// Takes a StepContext and returns a StepResult
pub const StepFn = *const fn (ctx: *StepContext) callconv(.c) c_int;

/// A pipeline is a sequence of steps to execute
pub const Pipeline = struct {
    steps: []const StepFn,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, steps: []const StepFn) !Pipeline {
        const steps_copy = try allocator.dupe(StepFn, steps);
        return .{
            .steps = steps_copy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.allocator.free(self.steps);
    }

    /// Execute all steps in sequence
    /// Returns true if pipeline completed successfully
    pub fn execute(self: Pipeline, ctx: *StepContext) bool {
        for (self.steps) |step| {
            const result: StepResult = @enumFromInt(step(ctx));


            switch (result) {
                .Continue => continue,
                .Complete => return true,
                .Error => return false,
            }
        }

        return true; // All steps completed
    }
};

/// Pipeline builder for registering routes with step pipelines
pub const PipelineBuilder = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(StepFn),

    pub fn init(allocator: std.mem.Allocator) PipelineBuilder {
        return .{
            .allocator = allocator,
            .steps = std.ArrayList(StepFn).init(allocator),
        };
    }

    pub fn deinit(self: *PipelineBuilder) void {
        self.steps.deinit();
    }

    pub fn addStep(self: *PipelineBuilder, step: StepFn) !void {
        try self.steps.append(step);
    }

    pub fn build(self: *PipelineBuilder) !Pipeline {
        return Pipeline.init(self.allocator, self.steps.items);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Pipeline - basic execution" {
    const testing = std.testing;

    // Mock step that continues
    const continueStep = struct {
        fn step(_: *StepContext) callconv(.c) c_int {
            return @intFromEnum(StepResult.Continue);
        }
    }.step;

    // Mock step that completes
    const completeStep = struct {
        fn step(_: *StepContext) callconv(.c) c_int {
            return @intFromEnum(StepResult.Complete);
        }
    }.step;

    var builder = PipelineBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addStep(continueStep);
    try builder.addStep(completeStep);

    var pipeline = try builder.build();
    defer pipeline.deinit();

    // We can't actually execute without a real context
    // This test just verifies the API compiles
    try testing.expect(pipeline.steps.len == 2);
}
