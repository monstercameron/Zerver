// tests/integration/common.zig
const std = @import("std");
const zerver = @import("zerver");

pub const HarnessError = error{UnexpectedStreamingResponse};

pub const TestServer = struct {
    allocator: std.mem.Allocator,
    server: zerver.Server,
    step_storage: std.ArrayList(StepAllocation),

    const StepAllocation = struct {
        ptr: [*]zerver.Step,
        len: usize,

        fn asSlice(self: StepAllocation) []zerver.Step {
            return self.ptr[0..self.len];
        }
    };

    pub fn init(allocator: std.mem.Allocator) !TestServer {
        const effect_handler = struct {
            fn handle(_: *const zerver.Effect, _: u32) anyerror!zerver.executor.EffectResult {
                const empty = [_]u8{};
                return .{ .success = .{ .bytes = empty[0..], .allocator = null } };
            }
        }.handle;

        const error_handler = struct {
            fn handle(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
                var status: u16 = zerver.ErrorCode.InternalServerError;
                var body: []const u8 = "Internal Server Error";

                if (ctx.last_error) |err| {
                    if (err.kind == zerver.ErrorCode.NotFound) {
                        status = zerver.ErrorCode.NotFound;
                        body = "Not Found";
                    }
                }

                return zerver.done(.{
                    .status = status,
                    .body = .{ .complete = body },
                });
            }
        }.handle;

        const config = zerver.Config{
            .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 },
            .on_error = error_handler,
        };

        var server = try zerver.Server.init(allocator, config, effect_handler);
        errdefer server.deinit();

        const storage = try std.ArrayList(StepAllocation).initCapacity(allocator, 8);

        return .{
            .allocator = allocator,
            .server = server,
            .step_storage = storage,
        };
    }

    pub fn deinit(self: *TestServer) void {
        self.server.deinit();
        for (self.step_storage.items) |step_alloc| {
            self.allocator.free(step_alloc.asSlice());
        }
        self.step_storage.deinit(self.allocator);
    }

    pub fn addRoute(self: *TestServer, method: zerver.Method, path: []const u8, spec: zerver.RouteSpec) !void {
        try self.server.addRoute(method, path, spec);
    }

    pub fn use(self: *TestServer, steps: []const zerver.Step) !void {
        try self.server.use(steps);
    }

    pub fn useStep(self: *TestServer, comptime name: []const u8, handler: anytype) !void {
        const steps = try self.allocator.alloc(zerver.Step, 1);
        const slice = steps[0..1];
        slice[0] = zerver.step(name, handler);

        var allocation = StepAllocation{ .ptr = steps.ptr, .len = steps.len };
        var ownership_transferred = false;
        defer if (!ownership_transferred) self.allocator.free(allocation.asSlice());

        try self.use(slice);
        try self.step_storage.append(self.allocator, allocation);
        ownership_transferred = true;
    }

    pub fn handle(self: *TestServer, allocator: std.mem.Allocator, request_text: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const result = try self.server.handleRequest(request_text, arena.allocator());
        return switch (result) {
            .complete => |body| try allocator.dupe(u8, body),
            .streaming => HarnessError.UnexpectedStreamingResponse,
        };
    }
};

pub fn withServer(test_fn: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.init(allocator);
    defer server.deinit();

    try test_fn(&server, allocator);
}

pub fn addRouteStep(
    server: *TestServer,
    method: zerver.Method,
    path: []const u8,
    comptime name: []const u8,
    handler: anytype,
) !void {
    const steps = try server.allocator.alloc(zerver.Step, 1);
    const slice = steps[0..1];
    slice[0] = zerver.step(name, handler);
    var allocation = TestServer.StepAllocation{ .ptr = steps.ptr, .len = steps.len };
    var ownership_transferred = false;
    defer if (!ownership_transferred) server.allocator.free(allocation.asSlice());

    try server.addRoute(method, path, .{ .steps = slice });
    try server.step_storage.append(server.allocator, allocation);
    ownership_transferred = true;
}

pub fn expectStartsWith(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, haystack, needle));
}

pub fn expectEndsWith(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, haystack, needle));
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOfPos(u8, haystack, 0, needle) != null);
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOfPos(u8, haystack, 0, needle) == null);
}

pub fn expectHeaderValue(response: []const u8, header_name: []const u8, expected: []const u8) !void {
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    const headers = response[0..header_end];

    var prefix_buffer: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{s}: ", .{header_name}) catch unreachable;

    const maybe_index = std.mem.indexOf(u8, headers, prefix);
    try std.testing.expect(maybe_index != null);
    const idx = maybe_index.?;
    const line_end = std.mem.indexOfPos(u8, headers, idx, "\r\n") orelse headers.len;
    const actual = headers[idx + prefix.len .. line_end];
    try std.testing.expectEqualStrings(expected, actual);
}

pub fn getHeaderValue(response: []const u8, header_name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    const headers = response[0..header_end];

    var prefix_buffer: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{s}: ", .{header_name}) catch return null;

    const maybe_index = std.mem.indexOf(u8, headers, prefix) orelse return null;
    const line_end = std.mem.indexOfPos(u8, headers, maybe_index, "\r\n") orelse headers.len;
    return headers[maybe_index + prefix.len .. line_end];
}
