// examples/products/todos/core/domain.zig
/// Todos Product: Core Domain Models
///
/// Domain entities and value objects following Domain-Driven Design (DDD):
/// - Todo: Core aggregate root
/// - TodoStatus: Value object for state
/// - TodoId: Value object for identity
/// - Error types: Domain-specific errors
const std = @import("std");

/// Todo status enumeration
pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,
    blocked,
};

/// Todo aggregate root - central domain entity
pub const Todo = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    status: TodoStatus = .pending,
    assigned_to: []const u8 = "",
    priority: u8 = 3, // 1=critical, 5=low
    created_at: i64,
    updated_at: i64,
    created_by: []const u8,

    /// Validation: ensure todo meets invariants
    pub fn isValid(self: *const Todo) bool {
        return self.id.len > 0 and
            self.title.len > 0 and
            self.title.len <= 256 and
            self.priority >= 1 and self.priority <= 5;
    }

    /// Transition: move to next state
    pub fn transitionTo(self: *Todo, next_status: TodoStatus) !void {
        // Business rule: can't transition from completed to anything
        if (self.status == .completed and next_status != .completed) {
            return error.CompletedTodosImmutable;
        }
        self.status = next_status;
    }
};

/// Domain error codes
pub const DomainError = enum {
    InvalidInput,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    TooManyRequests,
    UpstreamUnavailable,
    Timeout,
    Internal,
    CompletedTodosImmutable,
};

/// Error context for debugging
pub const ErrorContext = struct {
    error_code: DomainError,
    message: []const u8,
    resource: []const u8,
};

/// Create error with context
pub fn makeError(code: DomainError, message: []const u8, resource: []const u8) ErrorContext {
    return .{
        .error_code = code,
        .message = message,
        .resource = resource,
    };
}

/// Simulate realistic latency for operations
pub const OperationLatency = struct {
    min_ms: u32,
    max_ms: u32,

    pub fn read() OperationLatency {
        return .{ .min_ms = 20, .max_ms = 80 };
    }

    pub fn write() OperationLatency {
        return .{ .min_ms = 50, .max_ms = 150 };
    }

    pub fn scan() OperationLatency {
        return .{ .min_ms = 100, .max_ms = 300 };
    }

    pub fn random(self: OperationLatency) u32 {
        var prng = std.Random.DefaultPrng.init(std.time.timestamp());
        const rand = prng.random();
        const range = self.max_ms - self.min_ms;
        const offset = rand.intRangeLessThan(u32, 0, range);
        return self.min_ms + offset;
    }
};

