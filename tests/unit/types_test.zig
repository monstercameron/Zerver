// tests/unit/types_test.zig
const std = @import("std");
const zerver = @import("zerver");

const AdvancedRetryPolicy = zerver.AdvancedRetryPolicy;
const BackoffStrategy = zerver.BackoffStrategy;
const Response = zerver.Response;

fn expectEqual(comptime T: type, expected: T, actual: T) !void {
    try std.testing.expectEqual(expected, actual);
}

test "AdvancedRetryPolicy.calculateDelay handles backoff strategies" {
    const policy_no = AdvancedRetryPolicy{
        .backoff_strategy = BackoffStrategy.NoBackoff,
        .initial_delay_ms = 123,
        .max_delay_ms = 456,
    };
    try expectEqual(u32, 0, policy_no.calculateDelay(0));
    try expectEqual(u32, 0, policy_no.calculateDelay(3));

    const policy_linear = AdvancedRetryPolicy{
        .backoff_strategy = BackoffStrategy.Linear,
        .initial_delay_ms = 100,
        .max_delay_ms = 250,
    };
    try expectEqual(u32, 0, policy_linear.calculateDelay(0));
    try expectEqual(u32, 100, policy_linear.calculateDelay(1));
    try expectEqual(u32, 200, policy_linear.calculateDelay(2));
    try expectEqual(u32, 250, policy_linear.calculateDelay(3)); // capped

    const policy_exp = AdvancedRetryPolicy{
        .backoff_strategy = BackoffStrategy.Exponential,
        .initial_delay_ms = 100,
        .max_delay_ms = 400,
    };
    try expectEqual(u32, 0, policy_exp.calculateDelay(0));
    try expectEqual(u32, 100, policy_exp.calculateDelay(1));
    try expectEqual(u32, 150, policy_exp.calculateDelay(2));
    try expectEqual(u32, 225, policy_exp.calculateDelay(3));
    try expectEqual(u32, 337, policy_exp.calculateDelay(4));
    try expectEqual(u32, 400, policy_exp.calculateDelay(5)); // capped

    const policy_fib = AdvancedRetryPolicy{
        .backoff_strategy = BackoffStrategy.Fibonacci,
        .initial_delay_ms = 20,
        .max_delay_ms = 100,
    };
    try expectEqual(u32, 0, policy_fib.calculateDelay(0));
    try expectEqual(u32, 20, policy_fib.calculateDelay(1));
    try expectEqual(u32, 40, policy_fib.calculateDelay(2));
    try expectEqual(u32, 60, policy_fib.calculateDelay(3));
    try expectEqual(u32, 100, policy_fib.calculateDelay(4));
    try expectEqual(u32, 100, policy_fib.calculateDelay(5));
}

test "Response defaults map to expected HTTP semantics" {
    const resp = Response{};
    try expectEqual(u16, 200, resp.status);
    try expectEqual(usize, 0, resp.headers.len);
    try std.testing.expect(resp.body == .complete);
    try std.testing.expectEqualStrings("", resp.body.complete);
}

test "ParsedRequest.deinit releases dynamic allocations" {
    const allocator = std.testing.allocator;

    var request = zerver.types.ParsedRequest{
        .method = "GET",
        .path = "/",
        .headers = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        .query = std.StringHashMap([]const u8).init(allocator),
        .body = "payload",
        .client_ip = "127.0.0.1",
    };

    {
        const entry = try request.headers.getOrPut("accept");
        if (!entry.found_existing) {
            entry.value_ptr.* = try std.ArrayList([]const u8).initCapacity(allocator, 1);
        }
        try entry.value_ptr.*.append(allocator, "application/json");
    }

    try request.query.put("page", "1");

    request.deinit();
}
