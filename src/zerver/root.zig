/// Zerver: A backend framework for Zig with observability and composable orchestration.
///
/// This is the main library root that exports the public API surface.
pub const core = @import("core/core.zig");
pub const ctx_module = @import("core/ctx.zig");
pub const types = @import("core/types.zig");
pub const error_renderer_module = @import("core/error_renderer.zig");
pub const server = @import("impure/server.zig");
pub const router = @import("routes/router.zig");
pub const executor = @import("impure/executor.zig");
pub const tracer_module = @import("observability/tracer.zig");
pub const reqtest_module = @import("core/reqtest.zig");

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

// Observability
pub const slog = @import("observability/slog.zig");

// Helpers
pub const step = core.step;
pub const continue_ = core.continue_;
pub const done = core.done;
pub const fail = core.fail;

// Error handling
pub const ErrorRenderer = error_renderer_module.ErrorRenderer;

// Server & Router & Executor & Testing
pub const Server = server.Server;
pub const Config = server.Config;
pub const Address = server.Address;
pub const Router = router.Router;
pub const Executor = executor.Executor;
pub const Tracer = tracer_module.Tracer;
pub const ReqTest = reqtest_module.ReqTest;
