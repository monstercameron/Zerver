// tests/unit/circuit_breaker_test.zig
const std = @import("std");
const zerver = @import("zerver");
const circuit_breaker = zerver.circuit_breaker;

fn makeAllocator() std.mem.Allocator {
    return std.testing.allocator;
}

test "CircuitBreaker opens after failures and respects timeout" {
    const allocator = makeAllocator();
    var breaker = try circuit_breaker.CircuitBreaker.init(allocator, "svc", 2, 2, 50);
    defer breaker.deinit();

    breaker.recordFailureAt(10);
    var stats = breaker.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.failure_count);
    try std.testing.expectEqual(circuit_breaker.CircuitBreakerState.Closed, stats.state);

    breaker.recordFailureAt(20); // reaches threshold => open
    stats = breaker.getStats();
    try std.testing.expectEqual(circuit_breaker.CircuitBreakerState.Open, stats.state);
    try std.testing.expectEqual(@as(i64, 20), stats.last_state_change);

    try std.testing.expect(!breaker.canExecuteAt(20));
    try std.testing.expect(!breaker.canExecuteAt(60));
    try std.testing.expect(breaker.canExecuteAt(80));
}

test "CircuitBreaker closes after successes in half-open" {
    const allocator = makeAllocator();
    var breaker = try circuit_breaker.CircuitBreaker.init(allocator, "svc", 3, 2, 100);
    defer breaker.deinit();

    breaker.stats.state = .HalfOpen;
    breaker.stats.success_count = 0;
    breaker.stats.failure_count = 0;
    breaker.stats.last_state_change = 40;

    breaker.recordSuccessAt(50);
    var stats = breaker.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.success_count);
    try std.testing.expectEqual(circuit_breaker.CircuitBreakerState.HalfOpen, stats.state);

    breaker.recordSuccessAt(51);
    stats = breaker.getStats();
    try std.testing.expectEqual(circuit_breaker.CircuitBreakerState.Closed, stats.state);
    try std.testing.expectEqual(@as(u32, 0), stats.success_count);
    try std.testing.expectEqual(@as(u32, 0), stats.failure_count);
}

test "CircuitBreaker failure in half-open reopens circuit" {
    const allocator = makeAllocator();
    var breaker = try circuit_breaker.CircuitBreaker.init(allocator, "svc", 3, 2, 200);
    defer breaker.deinit();

    breaker.stats.state = .HalfOpen;
    breaker.stats.success_count = 1;
    breaker.stats.failure_count = 0;
    breaker.stats.last_state_change = 70;

    breaker.recordFailureAt(90);
    const stats = breaker.getStats();
    try std.testing.expectEqual(circuit_breaker.CircuitBreakerState.Open, stats.state);
    try std.testing.expectEqual(@as(u32, 0), stats.success_count);
    try std.testing.expectEqual(@as(u32, 0), stats.failure_count);
    try std.testing.expectEqual(@as(i64, 90), stats.last_state_change);
}

test "CircuitBreaker does not reset when clock goes backwards" {
    const allocator = makeAllocator();
    var breaker = try circuit_breaker.CircuitBreaker.init(allocator, "svc", 1, 1, 100);
    defer breaker.deinit();

    breaker.stats.state = .Open;
    breaker.stats.last_state_change = 200;

    try std.testing.expect(!breaker.canExecuteAt(150));
}

test "CircuitBreakerPool creates and reuses breakers" {
    const allocator = makeAllocator();
    var pool = circuit_breaker.CircuitBreakerPool.init(allocator);
    defer pool.deinit();

    try std.testing.expectEqual(@as(?*circuit_breaker.CircuitBreaker, null), pool.getExisting("api"));

    const first = try pool.get("api", 3, 2, 1000);
    const again = try pool.get("api", 5, 5, 5000);
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(first, pool.getExisting("api").?);

    const other = try pool.get("db", 2, 1, 500);
    try std.testing.expect(first != other);
}
