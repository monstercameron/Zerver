// src/zerver/runtime/reactor/join.zig
const std = @import("std");
const types = @import("../../core/types.zig");

pub const Mode = types.Mode;
pub const Join = types.Join;

pub const Status = enum {
    success,
    failure,
};

pub const Resolution = union(enum) {
    Pending,
    Resume: struct {
        status: Status,
    },
};

pub const JoinConfig = struct {
    mode: Mode,
    join: Join,
};

pub const Completion = struct {
    required: bool,
    success: bool,
};

pub const JoinState = struct {
    config: JoinConfig,
    outstanding: usize,
    required_remaining: usize,
    success_seen: bool,
    required_failure: bool,
    resumed: bool,

    pub fn init(config: JoinConfig, total_effects: usize, required_effects: usize) JoinState {
        std.debug.assert(total_effects > 0);
        std.debug.assert(required_effects <= total_effects);
        return .{
            .config = config,
            .outstanding = total_effects,
            .required_remaining = required_effects,
            .success_seen = false,
            .required_failure = false,
            .resumed = false,
        };
    }

    pub fn record(self: *JoinState, completion: Completion) Resolution {
        if (self.resumed) return .Pending;

        std.debug.assert(self.outstanding > 0);
        self.outstanding -= 1;

        if (completion.required and self.required_remaining > 0) {
            self.required_remaining -= 1;
        }

        if (completion.success) {
            self.success_seen = true;
        } else if (completion.required) {
            self.required_failure = true;
        }

        switch (self.config.join) {
            .any => {
                self.resumed = true;
                const status: Status = if (completion.success) .success else .failure;
                return .{ .Resume = .{ .status = status } };
            },
            .first_success => {
                if (completion.success) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .success } };
                }
                if (self.required_failure) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .failure } };
                }
                if (self.outstanding == 0 and !self.success_seen) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .failure } };
                }
            },
            .all => {
                if (self.required_failure) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .failure } };
                }
                if (self.outstanding == 0) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .success } };
                }
            },
            .all_required => {
                if (self.required_failure) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .failure } };
                }
                if (self.required_remaining == 0) {
                    self.resumed = true;
                    return .{ .Resume = .{ .status = .success } };
                }
            },
        }

        return .Pending;
    }

    pub fn isResumed(self: *const JoinState) bool {
        return self.resumed;
    }
};

// Covered by unit test: tests/unit/reactor_join.zig
