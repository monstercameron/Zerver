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
    // For now, assume all functions take *CtxBase directly
    // TODO: Support CtxView functions in the future
    // TODO: Logical Error - The 'step' function currently sets 'reads' and 'writes' to empty arrays. This bypasses CtxView's compile-time access control. Implement a mechanism to extract 'reads' and 'writes' from the step function's CtxView specification.
    return types.Step{
        .name = name,
        .call = F,
        .reads = &.{},
        .writes = &.{},
    };
}

/// Extract reads and writes from a CtxView type by inspecting its public decls.
fn extractReadsWrites(comptime _CtxViewType: type) struct { reads: []const u32, writes: []const u32 } {
    // For now, return empty - will be populated by context when spec is available
    // The Step struct can be annotated separately, or we could enhance CtxView
    // to expose its spec via a public const field.
    _ = _CtxViewType;
    return .{
        .reads = &.{},
        .writes = &.{},
    };
}

/// Create a wrapper function that adapts from *CtxBase to the typed view expected by F.
fn makeTrampolineFor(comptime F: anytype, comptime CtxViewPtr: anytype) *const fn (*anyopaque) anyerror!types.Decision {
    return struct {
        pub fn wrapper(base: *anyopaque) anyerror!types.Decision {
            // Cast from *anyopaque back to *CtxBase, asserting the alignment is correct
            const ctx_base: *ctx_module.CtxBase = @ptrCast(@alignCast(base));

            // Create a CtxView instance - extract the type from the pointer
            const CtxViewType = @typeInfo(CtxViewPtr).Pointer.child;

            // Instantiate the CtxView with the base context
            var view: CtxViewType = undefined;

            // CtxView fields should be: base: *CtxBase
            // We set it manually
            if (@hasField(CtxViewType, "base")) {
                @field(view, "base") = ctx_base;
            } else {
                @compileError("CtxView must have a 'base' field of type *CtxBase");
            }

            // Call the typed function with the view
            return F(&view);
        }
    }.wrapper;
}

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
