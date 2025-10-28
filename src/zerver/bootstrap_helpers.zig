// src/zerver/bootstrap_helpers.zig
// Re-export bootstrap helper utilities so they can be imported as a package root
pub const helpers = @import("bootstrap/helpers.zig");
pub const parseIpv4Host = helpers.parseIpv4Host;
pub const detectTempoEndpoint = helpers.detectTempoEndpoint;
pub const tempoDetectBackoff = helpers.tempoDetectBackoff;
// Covered by unit test: tests/unit/bootstrap_init_test.zig
