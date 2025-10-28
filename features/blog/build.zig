// features/blog/build.zig
/// Build script for blog feature DLL

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build as shared library (.so/.dylib/.dll)
    const lib = b.addSharedLibrary(.{
        .name = "blog",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install to features output directory
    b.installArtifact(lib);

    // Create a step for building the DLL
    const dll_step = b.step("dll", "Build blog feature DLL");
    dll_step.dependOn(&lib.step);
}
