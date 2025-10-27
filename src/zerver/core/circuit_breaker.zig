/// Circuit Breaker: Fault tolerance pattern for preventing cascading failures
///
/// A circuit breaker monitors for failures and stops sending requests
/// when a threshold is exceeded, allowing the system to recover.
const std = @import("std");
const types = @import("types.zig");
const slog = @import("../observability/slog.zig");

pub const CircuitBreakerState = enum {
    Closed, // Normal operation, requests flow through
    Open, // Too many failures, block requests
    HalfOpen, // Testing if system recovered
};

pub const CircuitBreakerStats = struct {
    state: CircuitBreakerState = .Closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: i64 = 0,
    last_state_change: i64 = 0,
};

/// CircuitBreaker: Protects against cascading failures
pub const CircuitBreaker = struct {
    name: []const u8,
    stats: CircuitBreakerStats = .{},

    // TODO: Concurrency/Safety - CircuitBreaker state modifications (e.g., failure_count, success_count, state) are not synchronized. This can lead to race conditions if multiple threads access the same breaker instance concurrently. Consider using atomics or mutexes for thread-safe updates.

    // Configuration
    failure_threshold: u32, // Failures before opening
    success_threshold: u32, // Successes before closing from half-open
    timeout_ms: u32, // Time in open state before half-open

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        failure_threshold: u32,
        success_threshold: u32,
        timeout_ms: u32,
    ) !@This() {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .failure_threshold = failure_threshold,
            .success_threshold = success_threshold,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.name);
    }

    /// Check if a request should be allowed
    pub fn canExecute(self: *@This()) bool {
        const now = std.time.milliTimestamp();
        // TODO: Perf - Fetch monotonic time once per loop iteration and pass it in to avoid repeated syscalls for every canExecute call.

        return switch (self.stats.state) {
            .Closed => true,
            .Open => self.shouldAttemptReset(now),
            .HalfOpen => true,
        };
    }

    /// Record a successful execution
    pub fn recordSuccess(self: *@This()) void {
        const now = std.time.milliTimestamp();
        // TODO: Perf - Consider batching consecutive successes/failures instead of touching atomics/maps on every call.

        switch (self.stats.state) {
            .Closed => {
                // Reset failure count on success
                self.stats.failure_count = 0;
            },
            .HalfOpen => {
                self.stats.success_count += 1;

                // If enough successes, close circuit
                if (self.stats.success_count >= self.success_threshold) {
                    self.transitionTo(.Closed, now);
                }
            },
            .Open => {
                // Ignore successes in open state
            },
        }
    }

    /// Record a failed execution
    pub fn recordFailure(self: *@This()) void {
        const now = std.time.milliTimestamp();
        // TODO: Perf - Replace std.time.milliTimestamp with a cached monotonic timestamp to cut syscall overhead in hot failure paths.
        self.stats.last_failure_time = now;

        switch (self.stats.state) {
            .Closed => {
                self.stats.failure_count += 1;

                // If failures exceed threshold, open circuit
                if (self.stats.failure_count >= self.failure_threshold) {
                    self.transitionTo(.Open, now);
                }
            },
            .HalfOpen => {
                // Any failure while half-open reopens immediately
                self.transitionTo(.Open, now);
            },
            .Open => {
                // Already open, just update count
                self.stats.failure_count += 1;
            },
        }
    }

    /// Get current state
    pub fn getState(self: *@This()) CircuitBreakerState {
        const now = std.time.milliTimestamp();

        // Check if we should transition from Open to HalfOpen
        if (self.stats.state == .Open and self.shouldAttemptReset(now)) {
            self.transitionTo(.HalfOpen, now);
        }

        return self.stats.state;
    }

    /// Get statistics
    pub fn getStats(self: @This()) CircuitBreakerStats {
        return self.stats;
    }

    // Private: Check if we've waited long enough to retry
    fn shouldAttemptReset(self: @This(), now: i64) bool {
        const elapsed = now - self.stats.last_state_change;
        // TODO: Logical Error - In 'shouldAttemptReset', if 'now' is less than 'self.stats.last_state_change' (e.g., due to clock adjustments), 'elapsed' could be negative, leading to unexpected behavior when compared with 'timeout_ms' (u32). Consider handling negative elapsed time explicitly.
        return elapsed > self.timeout_ms;
    }

    // Private: Transition to a new state
    fn transitionTo(self: *@This(), new_state: CircuitBreakerState, now: i64) void {
        self.stats.state = new_state;
        self.stats.last_state_change = now;

        // Reset counters on state transition
        switch (new_state) {
            .Closed => {
                self.stats.failure_count = 0;
                self.stats.success_count = 0;
            },
            .Open => {
                self.stats.success_count = 0;
            },
            .HalfOpen => {
                self.stats.failure_count = 0;
                self.stats.success_count = 0;
            },
        }
    }
};

/// CircuitBreakerPool: Manages multiple circuit breakers for different services
pub const CircuitBreakerPool = struct {
    breakers: std.StringHashMap(CircuitBreaker),
    allocator: std.mem.Allocator,

    // TODO: Concurrency/Safety - CircuitBreakerPool's 'breakers' hash map modifications (e.g., put) are not synchronized. This can lead to race conditions if multiple threads concurrently add or retrieve breakers. Consider using a mutex to protect access to the hash map.

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .breakers = std.StringHashMap(CircuitBreaker).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.breakers.valueIterator();
        while (it.next()) |breaker| {
            breaker.deinit();
        }
        self.breakers.deinit();
    }

    /// Get or create a circuit breaker for a service
    pub fn get(
        self: *@This(),
        service_name: []const u8,
        failure_threshold: u32,
        success_threshold: u32,
        timeout_ms: u32,
    ) !*CircuitBreaker {
        if (self.breakers.getPtr(service_name)) |breaker| {
            return breaker;
        }

        var new_breaker = try CircuitBreaker.init(
            self.allocator,
            service_name,
            failure_threshold,
            success_threshold,
            timeout_ms,
        );

        // TODO: Leak - circuit breaker pool stores the key slice by reference. Duplicate service_name when inserting so callers can pass temporary strings safely.
        try self.breakers.put(service_name, new_breaker);
        // TODO: Leak - if put fails, new_breaker.name is never freed; add errdefer before insert.
        return self.breakers.getPtr(service_name).?;
    }

    /// Get existing breaker (returns null if not found)
    pub fn getExisting(self: @This(), service_name: []const u8) ?*CircuitBreaker {
        return self.breakers.getPtr(service_name);
    }
};

/// Test circuit breaker functionality
pub fn testCircuitBreaker() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var breaker = try CircuitBreaker.init(allocator, "test_service", 3, 2, 1000);
    defer breaker.deinit();

    slog.info("Starting circuit breaker tests", &.{});

    // Test 1: Closed state allows requests
    std.debug.assert(breaker.canExecute());
    slog.info("Circuit breaker test: closed state allows requests", &.{});

    // Test 2: Failures accumulate
    breaker.recordFailure();
    breaker.recordFailure();
    std.debug.assert(breaker.getState() == .Closed); // Still closed, threshold is 3
    breaker.recordFailure(); // Third failure
    std.debug.assert(breaker.getState() == .Open); // Now open
    slog.info("Circuit breaker test: circuit opens after failure threshold", &.{});

    // Test 3: Open state blocks requests
    std.debug.assert(!breaker.canExecute());
    slog.info("Circuit breaker test: open state blocks requests", &.{});

    // Test 4: Half-open after timeout
    std.time.sleep(1100 * std.time.ns_per_ms); // Wait for timeout
    std.debug.assert(breaker.canExecute()); // Can attempt
    std.debug.assert(breaker.getState() == .HalfOpen);
    slog.info("Circuit breaker test: transitions to half-open after timeout", &.{});

    // Test 5: Successes in half-open close the circuit
    breaker.recordSuccess();
    breaker.recordSuccess(); // Second success closes
    std.debug.assert(breaker.getState() == .Closed);
    slog.info("Circuit breaker test: successes in half-open close the circuit", &.{});

    // Test 6: Failure in half-open reopens immediately
    // Re-open the circuit
    breaker.recordFailure();
    breaker.recordFailure();
    breaker.recordFailure();
    std.debug.assert(breaker.getState() == .Open);

    std.time.sleep(1100 * std.time.ns_per_ms);
    std.debug.assert(breaker.getState() == .HalfOpen);
    breaker.recordFailure(); // Fail in half-open
    std.debug.assert(breaker.getState() == .Open); // Immediately reopens
    slog.info("Circuit breaker test: failure in half-open immediately reopens", &.{});

    slog.info("Circuit breaker tests completed successfully", &.{});
}

/// Test circuit breaker pool
pub fn testCircuitBreakerPool() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = CircuitBreakerPool.init(allocator);
    defer pool.deinit();

    slog.info("Starting circuit breaker pool tests", &.{});

    // Create breakers for different services
    var db_breaker = try pool.get("database", 5, 3, 2000);
    var http_breaker = try pool.get("stripe", 3, 2, 1000);

    std.debug.assert(db_breaker.canExecute());
    std.debug.assert(http_breaker.canExecute());

    // Simulate failures on HTTP service
    http_breaker.recordFailure();
    http_breaker.recordFailure();
    http_breaker.recordFailure();

    std.debug.assert(http_breaker.getState() == .Open);
    std.debug.assert(!http_breaker.canExecute());

    // DB service should still be working
    std.debug.assert(db_breaker.canExecute());

    slog.info("Circuit breaker pool test: manages multiple independent breakers", &.{});
    slog.info("Circuit breaker pool tests completed successfully", &.{});
}
