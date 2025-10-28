// src/zerver/runtime/reactor/saga.zig
const std = @import("std");
const types = @import("../../core/types.zig");

/// Saga support is deferred to a later phase; this stub exists so higher layers
/// can start threading compensation metadata without hard dependencies.
pub const SagaError = error{Unimplemented};

pub const SagaLog = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SagaLog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *SagaLog) void {}

    pub fn record(_: *SagaLog, _: types.Compensation) SagaError!void {
        return SagaError.Unimplemented;
    }

    pub fn pop(_: *SagaLog) ?types.Compensation {
        return null;
    }

    pub fn len(_: *SagaLog) usize {
        return 0;
    }

    pub fn clear(_: *SagaLog) void {}
};

// Covered by unit test: tests/unit/reactor_saga.zig
