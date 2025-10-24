const std = @import("std");

pub fn build(b: *std.Build) void {
    // Check Zig version compatibility (build-time check)
    comptime {
        const min_zig_version = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 0 };
        const current_zig_version = std.SemanticVersion.parse(@import("builtin").zig_version_string) catch unreachable;
        if (current_zig_version.order(min_zig_version) == .lt) {
            @compileError("Zerver requires Zig version 0.15.0 or higher. Current version: " ++ @import("builtin").zig_version_string);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main example executable
    const exe = b.addExecutable(.{
        .name = "zerver_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add SQLite as a C library
    exe.addCSourceFile(.{
        .file = b.path("src/zerver/sql/dialects/sqlite/c/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    exe.linkLibC();

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Development helper steps
    // Create zerver module with proper paths
    const zerver_mod = b.createModule(.{
        .root_source_file = b.path("src/zerver/root.zig"),
    });

    // Development helper steps
    const test_step = b.step("test", "Run all tests");
    const test_exe = b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zerver/core/reqtest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("zerver", zerver_mod);
    // Add SQLite to test executable
    test_exe.addCSourceFile(.{
        .file = b.path("src/zerver/sql/dialects/sqlite/c/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    test_exe.linkLibC();
    test_step.dependOn(&b.addRunArtifact(test_exe).step);

    const fmt_step = b.step("fmt", "Format all Zig files");
    const fmt_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "fmt", "." });
    fmt_step.dependOn(&fmt_cmd.step);

    const clean_step = b.step("clean", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", "zig-cache", "zig-out" });
    clean_step.dependOn(&clean_cmd.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "docs" });
    docs_step.dependOn(&docs_cmd.step);

    // Blog CRUD example executable
    const blog_exe = b.addExecutable(.{
        .name = "blog_crud_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blog_crud.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    blog_exe.root_module.addImport("zerver", zerver_mod);
    // Add SQLite to blog example
    blog_exe.addCSourceFile(.{
        .file = b.path("src/zerver/sql/dialects/sqlite/c/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    blog_exe.linkLibC();

    b.installArtifact(blog_exe);

    const blog_run_cmd = b.addRunArtifact(blog_exe);
    blog_run_cmd.step.dependOn(b.getInstallStep());

    const blog_run_step = b.step("run_blog", "Run the blog CRUD example");
    blog_run_step.dependOn(&blog_run_cmd.step);

    // Teams example executable - commented out due to compilation errors
    // const teams_exe = b.addExecutable(.{
    //     .name = "zerver_teams",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("examples/teams/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });

    // // Create zerver module with proper paths
    // const zerver_mod = b.createModule(.{
    //     .root_source_file = b.path("src/zerver/root.zig"),
    // });

    // teams_exe.root_module.addImport("zerver", zerver_mod);

    // b.installArtifact(teams_exe);

    // const teams_run_cmd = b.addRunArtifact(teams_exe);
    // teams_run_cmd.step.dependOn(b.getInstallStep());

    // const teams_run_step = b.step("run_teams", "Run the teams example on port 8081");
    // teams_run_step.dependOn(&teams_run_cmd.step);
}
