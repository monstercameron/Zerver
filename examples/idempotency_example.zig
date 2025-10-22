/// Idempotency helpers: utilities for ensuring safe retries with idempotency keys
/// 
/// Idempotency keys allow clients to safely retry write operations without
/// accidentally duplicating side effects. The server must store results
/// indexed by the idempotency key and return the cached result on retry.

const std = @import("std");
const zerver = @import("../src/zerver/root.zig");

pub const IdempotencyHelper = struct {
    /// Generate a new idempotency key for this request
    /// Uses a combination of timestamp and random bytes for uniqueness
    pub fn generate(allocator: std.mem.Allocator) ![]const u8 {
        const now = std.time.nanoTimestamp();
        const random_bytes = try allocator.alloc(u8, 16);
        
        // In production, use a proper CSPRNG
        for (random_bytes, 0..) |_, i| {
            random_bytes[i] = @intCast((now +% i) >> 8);
        }
        
        const hex = try allocator.alloc(u8, 32);
        for (random_bytes, 0..) |byte, i| {
            const hex_str = try std.fmt.allocPrint(allocator, "{x:0>2}", .{byte});
            @memcpy(hex[i * 2 .. i * 2 + 2], hex_str);
            allocator.free(hex_str);
        }
        
        allocator.free(random_bytes);
        return hex;
    }

    /// Validate an idempotency key format (basic validation)
    /// Keys should be non-empty and reasonably short (< 256 chars)
    pub fn isValid(key: []const u8) bool {
        return key.len > 0 and key.len < 256;
    }

    /// Hash an idempotency key for efficient storage/lookup
    /// Returns a u64 hash suitable for use as a map key
    pub fn hash(key: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key);
        return hasher.final();
    }

    /// Create a cache key for storing idempotency results
    /// Format: "idem:<operation>:<key>"
    pub fn cacheKey(allocator: std.mem.Allocator, operation: []const u8, key: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "idem:{s}:{s}", .{ operation, key });
    }

    /// Check if request has an idempotency key header
    pub fn fromRequest(ctx: *zerver.CtxBase) ?[]const u8 {
        return ctx.header("Idempotency-Key");
    }

    /// Ensure a write effect includes an idempotency key
    /// Returns error if key is missing or invalid
    pub fn requireKey(ctx: *zerver.CtxBase) ![]const u8 {
        const key = ctx.header("Idempotency-Key") orelse {
            return error.MissingIdempotencyKey;
        };

        if (!isValid(key)) {
            return error.InvalidIdempotencyKey;
        }

        return key;
    }

    /// Pattern: Idempotent write step
    /// This demonstrates how to use idempotency keys in a step
    pub fn exampleIdempotentWrite(ctx: *zerver.CtxBase) !zerver.Decision {
        // 1. Get the idempotency key from request headers
        const idem_key = ctx.header("Idempotency-Key") orelse {
            return zerver.fail(
                zerver.ErrorCode.InvalidInput,
                "idempotency",
                "missing_key",
            );
        };

        // 2. Validate the key format
        if (!isValid(idem_key)) {
            return zerver.fail(
                zerver.ErrorCode.InvalidInput,
                "idempotency",
                "invalid_key_format",
            );
        }

        // 3. Check if we've already processed this key
        // In production, query a database or cache:
        //   cached_result = redis.get("idem:create_todo:" + idem_key)
        //   if cached_result:
        //       return cached_result (avoids duplicate write)

        // 4. Create the effect with the idempotency key
        // This tells the executor to store the result by this key
        return .{
            .Need = .{
                .effects = &.{
                    zerver.Effect{
                        .db_put = .{
                            .key = "todo:123",
                            .value = "{}",
                            .token = 0, // Or whatever slot stores the result
                            .idem = idem_key, // Idempotency key for safe retry
                            .required = true,
                        },
                    },
                },
                .mode = .Sequential,
                .join = .all,
                .continuation = @ptrCast(&resumeAfterWrite),
            },
        };
    }

    fn resumeAfterWrite(ctx: *anyopaque) !zerver.Decision {
        _ = ctx; // Context available if needed
        // After the write completes successfully:
        // - Result was stored in cache with the idempotency key
        // - Future requests with the same key get the cached result
        // - Write effects are deduped automatically
        
        return zerver.done(zerver.Response{
            .status = 201,
            .body = "{}",
        });
    }
};

/// Test idempotency helpers
pub fn testIdempotencyHelpers() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test key generation
    const key1 = try IdempotencyHelper.generate(allocator);
    defer allocator.free(key1);
    std.debug.print("Generated key: {s}\n", .{key1});

    // Test validation
    const valid = IdempotencyHelper.isValid(key1);
    std.debug.print("Key valid: {}\n", .{valid});

    // Test hashing
    const h = IdempotencyHelper.hash(key1);
    std.debug.print("Key hash: {}\n", .{h});

    // Test cache key generation
    const cache_key = try IdempotencyHelper.cacheKey(allocator, "create_todo", key1);
    defer allocator.free(cache_key);
    std.debug.print("Cache key: {s}\n", .{cache_key});

    // Test invalid keys
    const invalid_key = "";
    const is_valid = IdempotencyHelper.isValid(invalid_key);
    std.debug.print("Invalid key valid: {}\n", .{is_valid});
}

// ============================================================================
// Best practices for idempotency:
// ============================================================================
//
// 1. REQUIRE idempotency keys for all write operations (POST, PUT, PATCH, DELETE)
//    - Add middleware that enforces this on protected operations
//
// 2. STORE results with the key in a cache/database
//    - Use the pattern: `idem:<operation>:<key>` as the storage key
//    - Set a TTL (e.g., 24 hours) to clean up old entries
//
// 3. RETURN cached results on retry
//    - Check before executing the write
//    - Return the stored result with the original status code
//    - This is transparent to the client
//
// 4. USE transactional semantics
//    - Atomic: check existence, write result, store in cache
//    - Prevents double-writes due to race conditions
//
// 5. VALIDATE key format
//    - Accept UUID format, request IDs, or any unique string
//    - Reject keys that are too long (> 256 chars)
//    - Reject empty/null keys
//
// Example middleware:
//
//   pub fn enforce_idempotency_for_writes(ctx: *zerver.CtxBase) !zerver.Decision {
//       const method = ctx.method();
//       const is_write = std.mem.eql(u8, method, "POST") or
//                        std.mem.eql(u8, method, "PUT") or
//                        std.mem.eql(u8, method, "PATCH") or
//                        std.mem.eql(u8, method, "DELETE");
//       
//       if (is_write) {
//           if (IdempotencyHelper.fromRequest(ctx) == null) {
//               return zerver.fail(
//                   zerver.ErrorCode.InvalidInput,
//                   "idempotency",
//                   "required_for_writes",
//               );
//           }
//       }
//       
//       return zerver.continue_();
//   }

