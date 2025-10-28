// features/todos/build.zig
/// Build script for todos feature DLL

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build as shared library (.so/.dylib/.dll)
    const lib = b.addSharedLibrary(.{
        .name = "todos",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install to features output directory
    b.installArtifact(lib);

    // Create a step for building the DLL
    const dll_step = b.step("dll", "Build todos feature DLL");
    dll_step.dependOn(&lib.step);
}
