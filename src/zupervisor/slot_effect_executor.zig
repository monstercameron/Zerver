// src/zupervisor/slot_effect_executor.zig
/// Complete executor for slot-effect pipelines
/// Handles pipeline execution, effect processing, and response building

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const slot_effect = @import("slot_effect.zig");
const slot_effect_dll = @import("slot_effect_dll.zig");

/// Pipeline executor that manages complete request lifecycle
pub const PipelineExecutor = struct {
    allocator: std.mem.Allocator,
    bridge: *slot_effect_dll.SlotEffectBridge,
    max_iterations: u32,

    const DEFAULT_MAX_ITERATIONS = 100;

    pub fn init(allocator: std.mem.Allocator, bridge: *slot_effect_dll.SlotEffectBridge) PipelineExecutor {
        return .{
            .allocator = allocator,
            .bridge = bridge,
            .max_iterations = DEFAULT_MAX_ITERATIONS,
        };
    }

    /// Execute a pipeline with the given steps
    pub fn execute(
        self: *PipelineExecutor,
        ctx: *slot_effect.CtxBase,
        steps: []const slot_effect.StepFn,
    ) !slot_effect.Response {
        var interpreter = slot_effect.Interpreter.init(steps);

        // Execute pipeline until we get a Done or Error
        var iterations: u32 = 0;
        while (iterations < self.max_iterations) : (iterations += 1) {
            const decision = try interpreter.evalUntilNeedOrDone(ctx);

            switch (decision) {
                .Done => |response| {
                    return response;
                },

                .Fail => |err| {

                    // Build error response
                    return self.buildErrorResponse(err);
                },

                .need => |effect| {
                    // Execute the effect
                    try self.bridge.executeEffect(ctx, effect);

                    // Resume pipeline execution
                    const resume_decision = try interpreter.resumeExecution(ctx);
                    if (resume_decision == .Done) {
                        return resume_decision.Done;
                    } else if (resume_decision == .Fail) {
                        return self.buildErrorResponse(resume_decision.Fail);
                    }
                },

                .Continue => {
                    // Should not happen - evalUntilNeedOrDone stops at need/Done/Fail
                    return error.UnexpectedContinue;
                },
            }
        }

        // Too many iterations - likely infinite loop

        return self.buildErrorResponse(.{
            .message = "Pipeline execution timeout",
            .code = 500,
        });
    }

    fn buildErrorResponse(self: *PipelineExecutor, err: slot_effect.Error) !slot_effect.Response {
        // Build JSON error response
        const error_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"error\":\"{s}\",\"code\":{d}}}",
            .{ err.message, err.code },
        );

        var response = slot_effect.Response{
            .status = @intCast(err.code),
            .headers = slot_effect.Response.Headers.init(self.allocator),
            .body = slot_effect.Body{ .json = error_json },
        };

        // Add content-type header
        try response.headers.append(.{
            .name = "Content-Type",
            .value = "application/json",
        });

        return response;
    }
};

/// Request context builder for DLL handlers
pub const RequestContextBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestContextBuilder {
        return .{ .allocator = allocator };
    }

    /// Build a slot context from HTTP request data
    pub fn buildFromHttp(
        self: *RequestContextBuilder,
        request_id: []const u8,
        method: []const u8,
        path: []const u8,
        headers: []const Header,
        body: []const u8,
    ) !*slot_effect.CtxBase {
        const ctx = try self.allocator.create(slot_effect.CtxBase);
        errdefer self.allocator.destroy(ctx);

        ctx.* = try slot_effect.CtxBase.init(self.allocator, request_id);

        // Store request data in a request info structure
        const request_info = try self.allocator.create(RequestInfo);
        request_info.* = .{
            .method = try self.allocator.dupe(u8, method),
            .path = try self.allocator.dupe(u8, path),
            .headers = try self.allocator.dupe(Header, headers),
            .body = try self.allocator.dupe(u8, body),
        };

        // Store in a well-known slot (we could define a standard slot enum for this)
        try ctx.slots.put("__request_info", @ptrCast(request_info));

        return ctx;
    }

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    const RequestInfo = struct {
        method: []const u8,
        path: []const u8,
        headers: []const Header,
        body: []const u8,
    };
};

/// Response serializer for sending back to HTTP layer
pub const ResponseSerializer = struct {
    allocator: std.mem.Allocator,

    pub const ResponseHeader = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResponseSerializer {
        return .{ .allocator = allocator };
    }

    /// Serialize response to HTTP format
    pub fn serialize(
        self: *ResponseSerializer,
        response: slot_effect.Response,
    ) !SerializedResponse {
        var headers = std.ArrayList(ResponseHeader){};
        errdefer headers.deinit(self.allocator);

        // Add response headers
        for (response.headers_inline[0..response.headers_count]) |maybe_header| {
            if (maybe_header) |header| {
                try headers.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, header.name),
                    .value = try self.allocator.dupe(u8, header.value),
                });
            }
        }

        // Add extra headers if any
        if (response.headers_extra) |extra| {
            for (extra.items) |header| {
                try headers.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, header.name),
                    .value = try self.allocator.dupe(u8, header.value),
                });
            }
        }

        // Get body content
        const body_content = switch (response.body) {
            .complete => |complete| complete,
            .streaming => "",
        };

        const body_copy = try self.allocator.dupe(u8, body_content);

        return .{
            .status = response.status,
            .headers = try headers.toOwnedSlice(self.allocator),
            .body = body_copy,
        };
    }

    pub const SerializedResponse = struct {
        status: u16,
        headers: []const ResponseHeader,
        body: []const u8,

        pub fn deinit(self: *SerializedResponse, allocator: std.mem.Allocator) void {
            for (self.headers) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(self.headers);
            allocator.free(self.body);
        }
    };
};

// ============================================================================
// Tests
// ============================================================================

test "PipelineExecutor - simple pipeline" {
    const testing = std.testing;

    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator);
    defer bridge.deinit();

    var executor = PipelineExecutor.init(testing.allocator, &bridge);

    const ctx = try bridge.createContext("test-exec-001");
    defer bridge.destroyContext(ctx);

    // Simple step that returns Done
    const TestStep = struct {
        fn step(step_ctx: *slot_effect.CtxBase) !slot_effect.Decision {
            _ = step_ctx;
            const response = slot_effect.Response{
                .status = 200,
                .headers = slot_effect.Response.Headers.init(testing.allocator),
                .body = slot_effect.Body{ .text = "Success" },
            };
            return slot_effect.done(response);
        }
    };

    const steps = [_]slot_effect.StepFn{TestStep.step};

    const response = try executor.execute(ctx, &steps);
    try testing.expect(response.status == 200);
    try testing.expectEqualStrings("Success", response.body.text);
}

test "PipelineExecutor - error handling" {
    const testing = std.testing;

    var bridge = try slot_effect_dll.SlotEffectBridge.init(testing.allocator);
    defer bridge.deinit();

    var executor = PipelineExecutor.init(testing.allocator, &bridge);

    const ctx = try bridge.createContext("test-error-001");
    defer bridge.destroyContext(ctx);

    // Step that returns error
    const ErrorStep = struct {
        fn step(step_ctx: *slot_effect.CtxBase) !slot_effect.Decision {
            _ = step_ctx;
            return slot_effect.fail("Test error", 400);
        }
    };

    const steps = [_]slot_effect.StepFn{ErrorStep.step};

    const response = try executor.execute(ctx, &steps);
    try testing.expect(response.status == 400);
    try testing.expect(std.mem.indexOf(u8, response.body.json, "Test error") != null);
}

test "RequestContextBuilder - from HTTP" {
    const testing = std.testing;

    var builder = RequestContextBuilder.init(testing.allocator);

    const headers = [_]RequestContextBuilder.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = "Bearer token123" },
    };

    const ctx = try builder.buildFromHttp(
        "req-123",
        "POST",
        "/api/test",
        &headers,
        "{\"test\":true}",
    );
    defer {
        ctx.deinit();
        testing.allocator.destroy(ctx);
    }

    try testing.expectEqualStrings("req-123", ctx.request_id);

    // Verify request info was stored
    const request_info_ptr = ctx.slots.get("__request_info");
    try testing.expect(request_info_ptr != null);
}

test "ResponseSerializer - serialize response" {
    const testing = std.testing;

    var serializer = ResponseSerializer.init(testing.allocator);

    var response = slot_effect.Response{
        .status = 201,
        .headers = slot_effect.Response.Headers.init(testing.allocator),
        .body = slot_effect.Body{ .json = "{\"id\":42}" },
    };

    try response.headers.append(.{
        .name = "Content-Type",
        .value = "application/json",
    });

    var serialized = try serializer.serialize(response);
    defer serialized.deinit(testing.allocator);

    try testing.expect(serialized.status == 201);
    try testing.expect(serialized.headers.len == 1);
    try testing.expectEqualStrings("Content-Type", serialized.headers[0].name);
    try testing.expectEqualStrings("{\"id\":42}", serialized.body);
}
