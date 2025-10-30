// src/zerver/root.zig
/// Zerver: A backend framework for Zig with observability and composable orchestration.
///
/// This is the main library root that exports the public API surface.
pub const core = @import("core/core.zig");
pub const circuit_breaker = @import("core/circuit_breaker.zig");
pub const ctx_module = @import("core/ctx.zig");
pub const types = @import("core/types.zig");
pub const error_renderer_module = @import("core/error_renderer.zig");
pub const http_status = @import("core/http_status.zig");
pub const server = @import("impure/server.zig");
pub const router = @import("routes/router.zig");
pub const routes = struct {
    pub const types = @import("routes/types.zig");
};
pub const executor = @import("impure/executor.zig");
pub const tracer_module = @import("observability/tracer.zig");
pub const telemetry = @import("observability/telemetry.zig");
pub const otel = @import("observability/otel.zig");
pub const reqtest_module = @import("core/reqtest.zig");
// TODO: Build: 'src/zerver/sql/mod.zig' not found in repo snapshot; gate this import behind a feature flag or add the module to avoid build failures.
pub const sql = @import("sql/mod.zig");

// Reactor Backend Abstraction Note:
// Currently, libuv is directly exposed in the public API, coupling users to this specific backend.
// Design Goal: Abstract reactor interface (Reactor trait/protocol) with multiple implementations:
//   - LibuvReactor (current, production-ready)
//   - IoUringReactor (Linux-specific, higher performance)
//   - KqueueReactor (macOS/BSD)
//   - WasiReactor (WebAssembly)
// Implementation: Create reactor.zig with interface definition, move libuv to reactor/backends/
// Benefits: Backend swapping at compile time, easier testing with mock reactor
// Tradeoff: Adds abstraction layer complexity, may incur small runtime overhead from indirection
// Current: Directly expose libuv for simplicity until multiple backends are implemented
// TODO: API stability: exporting backend-specific reactor types in the public API couples users to libuv; consider a trait-based reactor interface and feature-gated backends.
pub const libuv_reactor = @import("runtime/reactor/libuv.zig");
pub const reactor_join = @import("runtime/reactor/join.zig");
pub const reactor_job_system = @import("runtime/reactor/job_system.zig");
pub const reactor_effectors = @import("runtime/reactor/effectors.zig");
pub const reactor_saga = @import("runtime/reactor/saga.zig");
pub const reactor_task_system = @import("runtime/reactor/task_system.zig");
pub const reactor_resources = @import("runtime/reactor/resources.zig");
pub const runtime_global = @import("runtime/global.zig");
pub const runtime_config = @import("runtime/config.zig");

// Main types
pub const CtxBase = ctx_module.CtxBase;
pub const CtxView = ctx_module.CtxView;
pub const Decision = types.Decision;
pub const Effect = types.Effect;
pub const Response = types.Response;
pub const Error = types.Error;
pub const Step = types.Step;
pub const Method = types.Method;
pub const RouteSpec = types.RouteSpec;
pub const FlowSpec = types.FlowSpec;
pub const ErrorCode = types.ErrorCode;
pub const Retry = types.Retry;
pub const Timeout = types.Timeout;
pub const BackoffStrategy = types.BackoffStrategy;
pub const AdvancedRetryPolicy = types.AdvancedRetryPolicy;
pub const Header = types.Header;
pub const HttpStatus = http_status.HttpStatus;

// Observability
pub const slog = @import("observability/slog.zig");

// Runtime Resources - Explicit exports for clean architecture
const runtime_resources_mod = @import("runtime/resources.zig");
pub const RuntimeResources = runtime_resources_mod.RuntimeResources;

// Effector-only Resources - Minimal reactor without business logic types (no circular dependency)
pub const effector_resources = @import("runtime/reactor/effector_resources.zig");
pub const EffectorResources = effector_resources.EffectorResources;

// Hot Reload Plugins
pub const file_watcher = @import("plugins/file_watcher.zig");
pub const dll_loader = @import("plugins/dll_loader.zig");
pub const dll_version = @import("plugins/dll_version.zig");
pub const atomic_router = @import("plugins/atomic_router.zig");

// IPC Protocol Types (shared between Zingest and Zupervisor)
pub const ipc_types = @import("ipc/types.zig");

// Helpers
pub const step = core.step;
pub const continue_ = core.continue_;
pub const done = core.done;
pub const fail = core.fail;
pub const util_helpers = @import("util/helpers.zig");

// Error handling
pub const ErrorRenderer = error_renderer_module.ErrorRenderer;

// Server & Router & Executor & Testing
pub const Server = server.Server;
pub const Config = server.Config;
pub const Address = server.Address;

// Backward-compatible type aliases: instantiate generic Router/AtomicRouter with RouteSpec
pub const Router = router.Router(types.RouteSpec);
pub const AtomicRouter = atomic_router.AtomicRouter(types.RouteSpec);
pub const RouterLifecycle = atomic_router.RouterLifecycle(types.RouteSpec);

pub const Executor = executor.Executor;
pub const Tracer = tracer_module.Tracer;
pub const ReqTest = reqtest_module.ReqTest;
