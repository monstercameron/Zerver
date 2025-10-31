// src/zerver/runtime/compute_budget.zig
/// Compute Budget System - Track and enforce CPU time budgets for compute tasks
///
/// Prevents runaway CPU-bound tasks from monopolizing resources by:
/// - Tracking actual CPU time consumption vs estimated budget
/// - Parking tasks that exceed budget limits
/// - Priority-based scheduling for fairness
/// - Cooperative yielding for long-running tasks

const std = @import("std");
const types = @import("../core/types.zig");
const slog = @import("../observability/slog.zig");

/// Global compute budget configuration
pub const ComputeBudgetConfig = struct {
    /// Maximum total CPU time per request (milliseconds)
    max_request_cpu_ms: u32 = 2000,

    /// Maximum CPU time for a single compute task (milliseconds)
    max_task_cpu_ms: u32 = 500,

    /// Whether to enforce budgets (can be disabled for testing)
    enforce_budgets: bool = true,

    /// Whether to park tasks that exceed budgets
    park_on_exceeded: bool = true,

    /// Default priority for tasks without explicit priority
    default_priority: u8 = 128,

    /// Cooperative yield interval for long-running tasks (milliseconds)
    default_yield_interval_ms: u32 = 10,

    pub fn fromEnv() ComputeBudgetConfig {
        var config = ComputeBudgetConfig{};

        if (std.posix.getenv("ZER_VER_MAX_REQUEST_CPU_MS")) |val| {
            config.max_request_cpu_ms = std.fmt.parseInt(u32, val, 10) catch config.max_request_cpu_ms;
        }

        if (std.posix.getenv("ZER_VER_MAX_TASK_CPU_MS")) |val| {
            config.max_task_cpu_ms = std.fmt.parseInt(u32, val, 10) catch config.max_task_cpu_ms;
        }

        if (std.posix.getenv("ZER_VER_ENFORCE_BUDGETS")) |val| {
            config.enforce_budgets = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }

        if (std.posix.getenv("ZER_VER_PARK_ON_EXCEEDED")) |val| {
            config.park_on_exceeded = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }

        return config;
    }
};

/// Per-request budget tracker
pub const RequestBudget = struct {
    allocator: std.mem.Allocator,
    config: ComputeBudgetConfig,

    // Tracking
    total_cpu_used_ms: std.atomic.Value(u32),
    task_count: std.atomic.Value(u32),
    budget_exceeded_count: std.atomic.Value(u32),

    // Task tracking
    task_budgets: std.AutoHashMap(u32, TaskBudget), // token -> budget
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: ComputeBudgetConfig) !*RequestBudget {
        const self = try allocator.create(RequestBudget);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .total_cpu_used_ms = std.atomic.Value(u32).init(0),
            .task_count = std.atomic.Value(u32).init(0),
            .budget_exceeded_count = std.atomic.Value(u32).init(0),
            .task_budgets = std.AutoHashMap(u32, TaskBudget).init(allocator),
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *RequestBudget) void {
        self.task_budgets.deinit();
        self.allocator.destroy(self);
    }

    /// Register a compute task and check if it can execute
    pub fn registerTask(self: *RequestBudget, task: types.ComputeTask) !BudgetDecision {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check request-level budget
        const total_used = self.total_cpu_used_ms.load(.seq_cst);
        if (self.config.enforce_budgets and total_used >= self.config.max_request_cpu_ms) {
            _ = self.budget_exceeded_count.fetchAdd(1, .seq_cst);

            slog.warn("Request CPU budget exceeded", &.{
                slog.Attr.uint("total_used_ms", total_used),
                slog.Attr.uint("max_request_ms", self.config.max_request_cpu_ms),
                slog.Attr.string("operation", task.operation),
            });

            if (self.config.park_on_exceeded and task.park_on_budget_exceeded) {
                return .{ .park = .{
                    .reason = "request_budget_exceeded",
                    .retry_after_ms = 100,
                } };
            } else {
                return .{ .reject = .{
                    .reason = "request_budget_exceeded",
                    .code = 429, // Too Many Requests
                } };
            }
        }

        // Check task-specific budget
        const task_budget_ms = if (task.cpu_budget_ms > 0)
            @min(task.cpu_budget_ms, self.config.max_task_cpu_ms)
        else
            self.config.max_task_cpu_ms;

        // Register task budget
        try self.task_budgets.put(task.token, .{
            .allocated_ms = task_budget_ms,
            .used_ms = 0,
            .priority = task.priority,
            .yield_interval_ms = task.cooperative_yield_interval_ms,
            .started_at_ns = std.time.nanoTimestamp(),
        });

        _ = self.task_count.fetchAdd(1, .seq_cst);

        return .{ .allow = .{
            .budget_ms = task_budget_ms,
            .priority = task.priority,
            .yield_interval_ms = task.cooperative_yield_interval_ms,
        } };
    }

    /// Record actual CPU time used by a task
    pub fn recordCpuTime(self: *RequestBudget, token: u32, cpu_used_ms: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.task_budgets.getPtr(token)) |budget| {
            budget.used_ms += cpu_used_ms;
            _ = self.total_cpu_used_ms.fetchAdd(cpu_used_ms, .seq_cst);

            // Check if task exceeded its budget
            if (budget.used_ms > budget.allocated_ms) {
                _ = self.budget_exceeded_count.fetchAdd(1, .seq_cst);

                slog.warn("Task CPU budget exceeded", &.{
                    slog.Attr.uint("token", token),
                    slog.Attr.uint("used_ms", budget.used_ms),
                    slog.Attr.uint("allocated_ms", budget.allocated_ms),
                });
            }
        }
    }

    /// Check if task should yield for cooperative multitasking
    pub fn shouldYield(self: *RequestBudget, token: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.task_budgets.get(token)) |budget| {
            const elapsed_ns = std.time.nanoTimestamp() - budget.started_at_ns;
            const elapsed_ms = @as(u32, @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms)));
            return elapsed_ms >= budget.yield_interval_ms;
        }
        return false;
    }

    /// Unregister a task after completion
    pub fn unregisterTask(self: *RequestBudget, token: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.task_budgets.remove(token);
    }

    /// Get budget statistics for telemetry
    pub fn getStats(self: *RequestBudget) BudgetStats {
        return .{
            .total_cpu_used_ms = self.total_cpu_used_ms.load(.seq_cst),
            .task_count = self.task_count.load(.seq_cst),
            .budget_exceeded_count = self.budget_exceeded_count.load(.seq_cst),
            .max_request_cpu_ms = self.config.max_request_cpu_ms,
        };
    }
};

/// Per-task budget tracking
const TaskBudget = struct {
    allocated_ms: u32,
    used_ms: u32,
    priority: u8,
    yield_interval_ms: u32,
    started_at_ns: i128,
};

/// Budget enforcement decision
pub const BudgetDecision = union(enum) {
    allow: struct {
        budget_ms: u32,
        priority: u8,
        yield_interval_ms: u32,
    },
    park: struct {
        reason: []const u8,
        retry_after_ms: u32,
    },
    reject: struct {
        reason: []const u8,
        code: u16,
    },
};

/// Budget statistics for telemetry
pub const BudgetStats = struct {
    total_cpu_used_ms: u32,
    task_count: u32,
    budget_exceeded_count: u32,
    max_request_cpu_ms: u32,
};

/// Test helper: stub for testing without real CPU measurement
pub fn createTestBudget(allocator: std.mem.Allocator) !*RequestBudget {
    const config = ComputeBudgetConfig{
        .max_request_cpu_ms = 1000,
        .max_task_cpu_ms = 200,
        .enforce_budgets = true,
        .park_on_exceeded = true,
    };
    return try RequestBudget.init(allocator, config);
}
