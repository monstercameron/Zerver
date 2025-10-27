// src/zerver/core/circuit_breaker.zig
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
    mutex: std.Thread.Mutex = .{},

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
        return self.canExecuteAt(std.time.milliTimestamp());
    }

    pub fn canExecuteAt(self: *@This(), now: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return switch (self.stats.state) {
            .Closed => true,
            .Open => self.shouldAttemptReset(now),
            .HalfOpen => true,
        };
    }

    /// Record a successful execution
    pub fn recordSuccess(self: *@This()) void {
        self.recordSuccessAt(std.time.milliTimestamp());
    }

    pub fn recordSuccessAt(self: *@This(), now: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.recordFailureAt(std.time.milliTimestamp());
    }

    pub fn recordFailureAt(self: *@This(), now: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we should transition from Open to HalfOpen
        if (self.stats.state == .Open and self.shouldAttemptReset(now)) {
            self.transitionTo(.HalfOpen, now);
        }

        return self.stats.state;
    }

    /// Get statistics
    pub fn getStats(self: *@This()) CircuitBreakerStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.stats;
    }

    // Private: Check if we've waited long enough to retry
    fn shouldAttemptReset(self: *const @This(), now: i64) bool {
        const elapsed = now - self.stats.last_state_change;
        // Handle negative elapsed time due to clock adjustments (e.g., NTP corrections)
        if (elapsed < 0) {
            // If clock went backwards, conservatively assume timeout has not elapsed
            return false;
        }
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
    breakers: std.StringHashMap(*CircuitBreaker),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .breakers = std.StringHashMap(*CircuitBreaker).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.breakers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const breaker_ptr = entry.value_ptr.*;
            breaker_ptr.deinit();
            self.allocator.destroy(breaker_ptr);
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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.breakers.getPtr(service_name)) |breaker_slot| {
            return breaker_slot.*;
        }

        var new_breaker_ptr = try self.allocator.create(CircuitBreaker);
        errdefer self.allocator.destroy(new_breaker_ptr);

        new_breaker_ptr.* = try CircuitBreaker.init(
            self.allocator,
            service_name,
            failure_threshold,
            success_threshold,
            timeout_ms,
        );
        errdefer new_breaker_ptr.deinit();

        // Duplicate service_name for the hash map key so callers can pass temporary strings safely
        const key = try self.allocator.dupe(u8, service_name);
        errdefer self.allocator.free(key);

        try self.breakers.put(key, new_breaker_ptr);
        return self.breakers.getPtr(key).?.*;
    }

    /// Get existing breaker (returns null if not found)
    pub fn getExisting(self: *@This(), service_name: []const u8) ?*CircuitBreaker {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.breakers.getPtr(service_name)) |breaker_slot| {
            return breaker_slot.*;
        }
        return null;
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
    const now0 = std.time.milliTimestamp();
    std.debug.assert(breaker.canExecuteAt(now0));
    slog.info("Circuit breaker test: closed state allows requests", &.{});

    // Test 2: Failures accumulate
    const now1 = std.time.milliTimestamp();
    breaker.recordFailureAt(now1);
    breaker.recordFailureAt(now1);
    std.debug.assert(breaker.getState() == .Closed); // Still closed, threshold is 3
    breaker.recordFailureAt(now1); // Third failure
    std.debug.assert(breaker.getState() == .Open); // Now open
    slog.info("Circuit breaker test: circuit opens after failure threshold", &.{});

    // Test 3: Open state blocks requests
    std.debug.assert(!breaker.canExecuteAt(std.time.milliTimestamp()));
    slog.info("Circuit breaker test: open state blocks requests", &.{});

    // Test 4: Half-open after timeout
    std.time.sleep(1100 * std.time.ns_per_ms); // Wait for timeout
    const after_timeout = std.time.milliTimestamp();
    std.debug.assert(breaker.canExecuteAt(after_timeout)); // Can attempt
    std.debug.assert(breaker.getState() == .HalfOpen);
    slog.info("Circuit breaker test: transitions to half-open after timeout", &.{});

    // Test 5: Successes in half-open close the circuit
    breaker.recordSuccessAt(after_timeout);
    breaker.recordSuccessAt(after_timeout); // Second success closes
    std.debug.assert(breaker.getState() == .Closed);
    slog.info("Circuit breaker test: successes in half-open close the circuit", &.{});

    // Test 6: Failure in half-open reopens immediately
    // Re-open the circuit
    const reopen_now = std.time.milliTimestamp();
    breaker.recordFailureAt(reopen_now);
    breaker.recordFailureAt(reopen_now);
    breaker.recordFailureAt(reopen_now);
    std.debug.assert(breaker.getState() == .Open);

    std.time.sleep(1100 * std.time.ns_per_ms);
    std.debug.assert(breaker.getState() == .HalfOpen);
    breaker.recordFailureAt(std.time.milliTimestamp()); // Fail in half-open
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

    const pool_now = std.time.milliTimestamp();
    std.debug.assert(db_breaker.canExecuteAt(pool_now));
    std.debug.assert(http_breaker.canExecuteAt(pool_now));

    // Simulate failures on HTTP service
    http_breaker.recordFailureAt(pool_now);
    http_breaker.recordFailureAt(pool_now);
    http_breaker.recordFailureAt(pool_now);

    std.debug.assert(http_breaker.getState() == .Open);
    std.debug.assert(!http_breaker.canExecuteAt(std.time.milliTimestamp()));

    // DB service should still be working
    std.debug.assert(db_breaker.canExecuteAt(std.time.milliTimestamp()));

    slog.info("Circuit breaker pool test: manages multiple independent breakers", &.{});
    slog.info("Circuit breaker pool tests completed successfully", &.{});
}
