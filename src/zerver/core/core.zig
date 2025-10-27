/// Core helpers: step trampoline, effect constructors, decision utilities.
const std = @import("std");
const types = @import("types.zig");
const ctx_module = @import("ctx.zig");

/// Wrap a typed step function into a Step struct.
/// This allows the framework to call typed step functions through a generic interface.
///
/// Expected function signature: fn (*CtxBase) !Decision
/// Or: fn (*CtxView(spec)) !Decision (with spec containing reads/writes)
pub fn step(comptime name: []const u8, comptime F: anytype) types.Step {
    const fn_type = switch (@typeInfo(@TypeOf(F))) {
        .@"fn" => |info| info,
        else => @compileError("step expects a function value"),
    };
    // TODO: Safety - Step metadata stores raw slices; callers must pass string literals for `name` or we risk dangling pointers if the slice comes from a temporary allocation.
    // TODO: Perf - Cache generated trampolines per function pointer; recompiling the wrapper for every call site bloats codegen and increases compile times.

    if (fn_type.params.len == 0 or fn_type.params[0].type == null) {
        @compileError("step function must accept a context parameter");
    }

    const param_type = fn_type.params[0].type.?;
    const param_info = switch (@typeInfo(param_type)) {
        .pointer => |info| info,
        else => @compileError("step function must accept a pointer parameter"),
    };

    const child_type = param_info.child;

    if (child_type == ctx_module.CtxBase) {
        return types.Step{
            .name = name,
            .call = F,
            .reads = &.{},
            .writes = &.{},
        };
    }

    if (!isCtxViewType(child_type)) {
        @compileError("step function parameter must be *CtxBase or *CtxView(...) type");
    }

    const metadata = extractReadsWrites(child_type);
    const trampoline = makeTrampolineFor(F, param_type);

    return types.Step{
        .name = name,
        .call = trampoline,
        .reads = metadata.reads,
        .writes = metadata.writes,
    };
}

/// Extract reads and writes from a CtxView type by inspecting its public decls.
fn extractReadsWrites(comptime _CtxViewType: type) struct { reads: []const u32, writes: []const u32 } {
    if (!@hasDecl(_CtxViewType, "__reads") or !@hasDecl(_CtxViewType, "__writes")) {
        return .{ .reads = &.{}, .writes = &.{} };
    }

    return .{
        .reads = convertSlotsToIds(_CtxViewType.__reads),
        .writes = convertSlotsToIds(_CtxViewType.__writes),
    };
}

/// Create a wrapper function that adapts from *CtxBase to the typed view expected by F.
fn makeTrampolineFor(comptime F: anytype, comptime CtxViewPtr: type) *const fn (*ctx_module.CtxBase) anyerror!types.Decision {
    const ptr_info = @typeInfo(CtxViewPtr);
    if (ptr_info != .Pointer) {
        @compileError("CtxView trampoline expects a pointer type");
    }
    const CtxViewType = ptr_info.Pointer.child;

    return struct {
        pub fn wrapper(base: *ctx_module.CtxBase) anyerror!types.Decision {
            var view = CtxViewType{
                .base = base,
            };
            return F(&view);
        }
    }.wrapper;
}

fn isCtxViewType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .Struct) return false;

    inline for (info.Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, "base") and field.type == *ctx_module.CtxBase) {
            return true;
        }
    }

    return false;
}

fn convertSlotsToIds(comptime slots_ptr: anytype) []const u32 {
    const ptr_info = @typeInfo(@TypeOf(slots_ptr));
    if (ptr_info != .Pointer) return &.{};

    const child_type = ptr_info.Pointer.child;
    const child_info = @typeInfo(child_type);
    if (child_info != .Array) return &.{};

    const slots_array = slots_ptr.*;
    if (slots_array.len == 0) return &.{};

    const ids_array = comptime buildIdArray(slots_array);
    return ids_array[0..];
}

fn buildIdArray(comptime slots_array: anytype) [slots_array.len]u32 {
    var ids = std.mem.zeroes([slots_array.len]u32);
    inline for (slots_array, 0..) |slot, idx| {
        ids[idx] = @intFromEnum(slot);
    }
    return ids;
}
// TODO: Perf - Precompute and memoize slot id arrays for common views; recomputing them at compile time for every route contributes to longer incremental builds.

/// Helper to create a Decision.Continue.
pub fn continue_() types.Decision {
    return .Continue;
}

/// Helper to create a Decision.Done.
pub fn done(resp: types.Response) types.Decision {
    return .{ .Done = resp };
}

/// Helper to create a Decision.Fail.
pub fn fail(kind: u16, what: []const u8, key: []const u8) types.Decision {
    return .{ .Fail = .{
        .kind = kind,
        .ctx = .{ .what = what, .key = key },
    } };
}

/// Re-export ErrorCode for convenience
pub const ErrorCode = types.ErrorCode;
