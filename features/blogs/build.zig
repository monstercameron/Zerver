// features/blogs/build.zig
/// Build script for blog feature DLL

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Determine DLL extension based on target OS
    const lib_ext = switch (target.result.os.tag) {
        .macos, .ios => ".dylib",
        .linux, .freebsd, .openbsd, .netbsd => ".so",
        .windows => ".dll",
        else => ".so",
    };

    const lib_name = b.fmt("blogs{s}", .{lib_ext});

    // Build as dynamic library (using simplified approach like test.dylib)
    const lib = b.addSharedLibrary(.{
        .name = "blogs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add SQLite as a system library
    lib.linkSystemLibrary("sqlite3");
    lib.linkLibC();

    // Output to ../../zig-out/lib/
    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{
            .override = .{
                .custom = "../../zig-out/lib",
            },
        },
    });

    b.getInstallStep().dependOn(&install.step);

    // Print build info
    std.debug.print("[Blog Feature] Building {s} for {s}\n", .{
        lib_name,
        @tagName(target.result.os.tag),
    });
}
