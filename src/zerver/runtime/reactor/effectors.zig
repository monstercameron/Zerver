const std = @import("std");
const types = @import("../../core/types.zig");
const libuv = @import("libuv.zig");
const job = @import("job_system.zig");
const task_system = @import("task_system.zig");

pub const DispatchError = error{
    UnsupportedEffect,
};

pub const Context = struct {
    loop: *libuv.Loop,
    jobs: *job.JobSystem,
    compute_jobs: ?*job.JobSystem = null,
    accelerator_jobs: ?*job.JobSystem = null,
    kv_cache: ?*anyopaque = null,
    task_system: ?*task_system.TaskSystem = null,
};

pub const HttpGetHandler = *const fn (*Context, types.HttpGet) DispatchError!types.EffectResult;
pub const HttpHeadHandler = *const fn (*Context, types.HttpHead) DispatchError!types.EffectResult;
pub const HttpPostHandler = *const fn (*Context, types.HttpPost) DispatchError!types.EffectResult;
pub const HttpPutHandler = *const fn (*Context, types.HttpPut) DispatchError!types.EffectResult;
pub const HttpDeleteHandler = *const fn (*Context, types.HttpDelete) DispatchError!types.EffectResult;
pub const HttpOptionsHandler = *const fn (*Context, types.HttpOptions) DispatchError!types.EffectResult;
pub const HttpTraceHandler = *const fn (*Context, types.HttpTrace) DispatchError!types.EffectResult;
pub const HttpConnectHandler = *const fn (*Context, types.HttpConnect) DispatchError!types.EffectResult;
pub const HttpPatchHandler = *const fn (*Context, types.HttpPatch) DispatchError!types.EffectResult;
pub const DbGetHandler = *const fn (*Context, types.DbGet) DispatchError!types.EffectResult;
pub const DbPutHandler = *const fn (*Context, types.DbPut) DispatchError!types.EffectResult;
pub const DbDelHandler = *const fn (*Context, types.DbDel) DispatchError!types.EffectResult;
pub const DbScanHandler = *const fn (*Context, types.DbScan) DispatchError!types.EffectResult;
pub const FileJsonReadHandler = *const fn (*Context, types.FileJsonRead) DispatchError!types.EffectResult;
pub const FileJsonWriteHandler = *const fn (*Context, types.FileJsonWrite) DispatchError!types.EffectResult;
pub const ComputeTaskHandler = *const fn (*Context, types.ComputeTask) DispatchError!types.EffectResult;
pub const AcceleratorTaskHandler = *const fn (*Context, types.AcceleratorTask) DispatchError!types.EffectResult;
pub const KvCacheGetHandler = *const fn (*Context, types.KvCacheGet) DispatchError!types.EffectResult;
pub const KvCacheSetHandler = *const fn (*Context, types.KvCacheSet) DispatchError!types.EffectResult;
pub const KvCacheDeleteHandler = *const fn (*Context, types.KvCacheDelete) DispatchError!types.EffectResult;

pub const EffectHandlers = struct {
    http_get: HttpGetHandler = defaultHttpGetHandler,
    http_head: HttpHeadHandler = defaultHttpHeadHandler,
    http_post: HttpPostHandler = defaultHttpPostHandler,
    http_put: HttpPutHandler = defaultHttpPutHandler,
    http_delete: HttpDeleteHandler = defaultHttpDeleteHandler,
    http_options: HttpOptionsHandler = defaultHttpOptionsHandler,
    http_trace: HttpTraceHandler = defaultHttpTraceHandler,
    http_connect: HttpConnectHandler = defaultHttpConnectHandler,
    http_patch: HttpPatchHandler = defaultHttpPatchHandler,
    db_get: DbGetHandler = defaultDbGetHandler,
    db_put: DbPutHandler = defaultDbPutHandler,
    db_del: DbDelHandler = defaultDbDelHandler,
    db_scan: DbScanHandler = defaultDbScanHandler,
    file_json_read: FileJsonReadHandler = defaultFileJsonReadHandler,
    file_json_write: FileJsonWriteHandler = defaultFileJsonWriteHandler,
    compute_task: ComputeTaskHandler = defaultComputeTaskHandler,
    accelerator_task: AcceleratorTaskHandler = defaultAcceleratorTaskHandler,
    kv_cache_get: KvCacheGetHandler = defaultKvCacheGetHandler,
    kv_cache_set: KvCacheSetHandler = defaultKvCacheSetHandler,
    kv_cache_delete: KvCacheDeleteHandler = defaultKvCacheDeleteHandler,
};

pub const EffectDispatcher = struct {
    handlers: EffectHandlers,

    pub fn init() EffectDispatcher {
        return .{ .handlers = .{} };
    }

    pub fn setHttpGetHandler(self: *EffectDispatcher, handler: HttpGetHandler) void {
        self.handlers.http_get = handler;
    }

    pub fn setHttpHeadHandler(self: *EffectDispatcher, handler: HttpHeadHandler) void {
        self.handlers.http_head = handler;
    }

    pub fn setHttpPostHandler(self: *EffectDispatcher, handler: HttpPostHandler) void {
        self.handlers.http_post = handler;
    }

    pub fn setHttpPutHandler(self: *EffectDispatcher, handler: HttpPutHandler) void {
        self.handlers.http_put = handler;
    }

    pub fn setHttpDeleteHandler(self: *EffectDispatcher, handler: HttpDeleteHandler) void {
        self.handlers.http_delete = handler;
    }

    pub fn setHttpOptionsHandler(self: *EffectDispatcher, handler: HttpOptionsHandler) void {
        self.handlers.http_options = handler;
    }

    pub fn setHttpTraceHandler(self: *EffectDispatcher, handler: HttpTraceHandler) void {
        self.handlers.http_trace = handler;
    }

    pub fn setHttpConnectHandler(self: *EffectDispatcher, handler: HttpConnectHandler) void {
        self.handlers.http_connect = handler;
    }

    pub fn setHttpPatchHandler(self: *EffectDispatcher, handler: HttpPatchHandler) void {
        self.handlers.http_patch = handler;
    }

    pub fn setDbGetHandler(self: *EffectDispatcher, handler: DbGetHandler) void {
        self.handlers.db_get = handler;
    }

    pub fn setDbPutHandler(self: *EffectDispatcher, handler: DbPutHandler) void {
        self.handlers.db_put = handler;
    }

    pub fn setDbDelHandler(self: *EffectDispatcher, handler: DbDelHandler) void {
        self.handlers.db_del = handler;
    }

    pub fn setDbScanHandler(self: *EffectDispatcher, handler: DbScanHandler) void {
        self.handlers.db_scan = handler;
    }

    pub fn setFileJsonReadHandler(self: *EffectDispatcher, handler: FileJsonReadHandler) void {
        self.handlers.file_json_read = handler;
    }

    pub fn setFileJsonWriteHandler(self: *EffectDispatcher, handler: FileJsonWriteHandler) void {
        self.handlers.file_json_write = handler;
    }

    pub fn setComputeTaskHandler(self: *EffectDispatcher, handler: ComputeTaskHandler) void {
        self.handlers.compute_task = handler;
    }

    pub fn setAcceleratorTaskHandler(self: *EffectDispatcher, handler: AcceleratorTaskHandler) void {
        self.handlers.accelerator_task = handler;
    }

    pub fn setKvCacheGetHandler(self: *EffectDispatcher, handler: KvCacheGetHandler) void {
        self.handlers.kv_cache_get = handler;
    }

    pub fn setKvCacheSetHandler(self: *EffectDispatcher, handler: KvCacheSetHandler) void {
        self.handlers.kv_cache_set = handler;
    }

    pub fn setKvCacheDeleteHandler(self: *EffectDispatcher, handler: KvCacheDeleteHandler) void {
        self.handlers.kv_cache_delete = handler;
    }

    pub fn dispatch(self: *EffectDispatcher, ctx: *Context, effect: types.Effect) DispatchError!types.EffectResult {
        return switch (effect) {
            .http_get => |payload| try self.handlers.http_get(ctx, payload),
            .http_head => |payload| try self.handlers.http_head(ctx, payload),
            .http_post => |payload| try self.handlers.http_post(ctx, payload),
            .http_put => |payload| try self.handlers.http_put(ctx, payload),
            .http_delete => |payload| try self.handlers.http_delete(ctx, payload),
            .http_options => |payload| try self.handlers.http_options(ctx, payload),
            .http_trace => |payload| try self.handlers.http_trace(ctx, payload),
            .http_connect => |payload| try self.handlers.http_connect(ctx, payload),
            .http_patch => |payload| try self.handlers.http_patch(ctx, payload),
            .db_get => |payload| try self.handlers.db_get(ctx, payload),
            .db_put => |payload| try self.handlers.db_put(ctx, payload),
            .db_del => |payload| try self.handlers.db_del(ctx, payload),
            .db_scan => |payload| try self.handlers.db_scan(ctx, payload),
            .file_json_read => |payload| try self.handlers.file_json_read(ctx, payload),
            .file_json_write => |payload| try self.handlers.file_json_write(ctx, payload),
            .compute_task => |payload| try self.handlers.compute_task(ctx, payload),
            .accelerator_task => |payload| try self.handlers.accelerator_task(ctx, payload),
            .kv_cache_get => |payload| try self.handlers.kv_cache_get(ctx, payload),
            .kv_cache_set => |payload| try self.handlers.kv_cache_set(ctx, payload),
            .kv_cache_delete => |payload| try self.handlers.kv_cache_delete(ctx, payload),
        };
    }
};

fn unsupported(comptime label: []const u8) DispatchError {
    _ = label;
    return DispatchError.UnsupportedEffect;
}

fn defaultHttpGetHandler(_: *Context, _: types.HttpGet) DispatchError!types.EffectResult {
    return unsupported("http_get");
}

fn defaultHttpHeadHandler(_: *Context, _: types.HttpHead) DispatchError!types.EffectResult {
    return unsupported("http_head");
}

fn defaultHttpPostHandler(_: *Context, _: types.HttpPost) DispatchError!types.EffectResult {
    return unsupported("http_post");
}

fn defaultHttpPutHandler(_: *Context, _: types.HttpPut) DispatchError!types.EffectResult {
    return unsupported("http_put");
}

fn defaultHttpDeleteHandler(_: *Context, _: types.HttpDelete) DispatchError!types.EffectResult {
    return unsupported("http_delete");
}

fn defaultHttpOptionsHandler(_: *Context, _: types.HttpOptions) DispatchError!types.EffectResult {
    return unsupported("http_options");
}

fn defaultHttpTraceHandler(_: *Context, _: types.HttpTrace) DispatchError!types.EffectResult {
    return unsupported("http_trace");
}

fn defaultHttpConnectHandler(_: *Context, _: types.HttpConnect) DispatchError!types.EffectResult {
    return unsupported("http_connect");
}

fn defaultHttpPatchHandler(_: *Context, _: types.HttpPatch) DispatchError!types.EffectResult {
    return unsupported("http_patch");
}

fn defaultDbGetHandler(_: *Context, _: types.DbGet) DispatchError!types.EffectResult {
    return unsupported("db_get");
}

fn defaultDbPutHandler(_: *Context, _: types.DbPut) DispatchError!types.EffectResult {
    return unsupported("db_put");
}

fn defaultDbDelHandler(_: *Context, _: types.DbDel) DispatchError!types.EffectResult {
    return unsupported("db_del");
}

fn defaultDbScanHandler(_: *Context, _: types.DbScan) DispatchError!types.EffectResult {
    return unsupported("db_scan");
}

fn defaultFileJsonReadHandler(_: *Context, _: types.FileJsonRead) DispatchError!types.EffectResult {
    return unsupported("file_json_read");
}

fn defaultFileJsonWriteHandler(_: *Context, _: types.FileJsonWrite) DispatchError!types.EffectResult {
    return unsupported("file_json_write");
}

fn defaultComputeTaskHandler(_: *Context, _: types.ComputeTask) DispatchError!types.EffectResult {
    return unsupported("compute_task");
}

fn defaultAcceleratorTaskHandler(_: *Context, _: types.AcceleratorTask) DispatchError!types.EffectResult {
    return unsupported("accelerator_task");
}

fn defaultKvCacheGetHandler(_: *Context, _: types.KvCacheGet) DispatchError!types.EffectResult {
    return unsupported("kv_cache_get");
}

fn defaultKvCacheSetHandler(_: *Context, _: types.KvCacheSet) DispatchError!types.EffectResult {
    return unsupported("kv_cache_set");
}

fn defaultKvCacheDeleteHandler(_: *Context, _: types.KvCacheDelete) DispatchError!types.EffectResult {
    return unsupported("kv_cache_delete");
}
