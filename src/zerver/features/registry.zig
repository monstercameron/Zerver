// src/zerver/features/registry.zig
/// Automatic feature registration system with compile-time token assignment
const std = @import("std");
const types = @import("../core/types.zig");
const slog = @import("../observability/slog.zig");

/// Tokens per feature (each feature gets 100 token slots)
pub const TOKENS_PER_FEATURE = 100;

/// Simple token generator for a feature at a given index
pub fn TokenFor(comptime feature_idx: usize) type {
    const base = feature_idx * TOKENS_PER_FEATURE;
    return struct {
        pub fn token(comptime slot_idx: u32) u32 {
            return base + slot_idx;
        }
    };
}

/// Feature registry that automatically assigns token ranges and routes effects
pub fn FeatureRegistry(comptime features: anytype) type {
    const features_type_info = @typeInfo(@TypeOf(features));
    comptime {
        if (features_type_info != .@"struct") {
            @compileError("FeatureRegistry expects a tuple of features");
        }
        if (!features_type_info.@"struct".is_tuple) {
            @compileError("FeatureRegistry expects a tuple, not a regular struct");
        }
    }
    const num_features = features_type_info.@"struct".fields.len;

    return struct {
        /// Automatically generated routing effect handler
        pub fn effectHandler(effect: *const types.Effect, timeout_ms: u32) anyerror!types.EffectResult {
            slog.info("🚀 FEATURE REGISTRY CALLED 🚀", &.{});
            const token = switch (effect.*) {
                .db_get => |e| e.token,
                .db_put => |e| e.token,
                .db_del => |e| e.token,
                else => 0,
            };

            const feature_idx = token / TOKENS_PER_FEATURE;

            slog.info("=== FEATURE REGISTRY ROUTING ===", &.{
                slog.Attr.uint("token", token),
                slog.Attr.uint("feature_idx", feature_idx),
                slog.Attr.uint("num_features", num_features),
            });

            inline for (0..num_features) |idx| {
                if (idx == feature_idx) {
                    const feature = @field(features, std.fmt.comptimePrint("{d}", .{idx}));
                    slog.debug("Routing to feature", &.{
                        slog.Attr.uint("feature_idx", idx),
                        slog.Attr.uint("token", token),
                    });
                    return feature.effectHandler(effect, timeout_ms);
                }
            }

            slog.err("No feature found for token", &.{
                slog.Attr.uint("token", token),
                slog.Attr.uint("feature_idx", feature_idx),
            });
            return types.EffectResult{ .failure = types.Error{
                .kind = 404,
                .ctx = .{ .what = "unknown_feature", .key = "invalid_token" },
            } };
        }

    };
}
// FORCE_RECOMPILE_$(date +%s)
