const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the blog DLL by temporarily moving sources to src/
    const lib_name = if (target.result.os.tag == .macos or target.result.os.tag == .ios)
        "blog.dylib"
    else if (target.result.os.tag == .windows)
        "blog.dll"
    else
        "blog.so";

    // Copy blog sources to src/features/blog/ with flattened structure
    const setup_src = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "mkdir -p ../../src/features/blog && " ++
        // Copy blog source files directly (flatten src/ directory)
        "cp src/*.zig ../../src/features/blog/ 2>/dev/null || true && " ++
        "cp main.zig ../../src/features/blog/ && " ++
        // Fix import paths for flattened location
        "find ../../src/features/blog -name '*.zig' -type f -exec sed -i.bak " ++
        // Fix imports to zerver and shared (../../zerver -> ../zerver)
        "-e 's|@import(\"../../../src/zerver/|@import(\"../zerver/|g' " ++
        "-e 's|@import(\"../../zerver/|@import(\"../zerver/|g' " ++
        "-e 's|@import(\"../../../src/shared/|@import(\"../shared/|g' " ++
        "-e 's|@import(\"../../shared/|@import(\"../shared/|g' " ++
        // Fix imports to local files (src/routes.zig -> routes.zig)
        "-e 's|@import(\"src/\\([^\"]*\\)\")|@import(\"\\1\")|g' " ++
        "{} \\;",
    });

    // Build from src/features/blog/ where imports work correctly
    const build_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build-lib",
        "-dynamic",
        "-lc",
        "-target",
    });

    // Add target triple
    const target_query_str = b.fmt("{s}", .{target.result.zigTriple(b.allocator) catch @panic("failed to get triple")});
    build_cmd.addArg(target_query_str);

    // Add optimization
    build_cmd.addArg("-O");
    build_cmd.addArg(switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    });

    build_cmd.addArg("src/features/blog/main.zig");
    build_cmd.addArg("--name");
    build_cmd.addArg("blog");

    // Run from project root
    build_cmd.setCwd(b.path("../../"));
    build_cmd.step.dependOn(&setup_src.step);

    // Move DLL to features/blog/ and clean up temp src
    const cleanup = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        b.fmt("mv ../../{s} . && rm -rf ../../src/features/blog", .{lib_name}),
    });
    cleanup.step.dependOn(&build_cmd.step);

    // Install the resulting library
    const install_step = b.addInstallBinFile(
        b.path(lib_name),
        lib_name,
    );
    install_step.step.dependOn(&cleanup.step);

    b.getInstallStep().dependOn(&install_step.step);
}
