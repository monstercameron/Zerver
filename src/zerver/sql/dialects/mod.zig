// src/zerver/sql/dialects/mod.zig
pub const interface = @import("dialect.zig");
pub const sqlite = @import("sqlite/mod.zig");

// No direct unit test found in tests/unit/
