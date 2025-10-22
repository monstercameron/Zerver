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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Development helper steps
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zerver/core/reqtest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    })).step);

    const fmt_step = b.step("fmt", "Format all Zig files");
    const fmt_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "fmt", "." });
    fmt_step.dependOn(&fmt_cmd.step);

    const clean_step = b.step("clean", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", "zig-cache", "zig-out" });
    clean_step.dependOn(&clean_cmd.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "build", "docs" });
    docs_step.dependOn(&docs_cmd.step);

    // Create zerver module with proper paths
    const zerver_mod = b.createModule(.{
        .root_source_file = b.path("src/zerver/root.zig"),
    });

    // Streaming JSON example
    const streaming_exe = b.addExecutable(.{
        .name = "streaming_json_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/advanced/05_streaming_json_in_steps.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    streaming_exe.root_module.addImport("zerver", zerver_mod);

    b.installArtifact(streaming_exe);

    const streaming_run_cmd = b.addRunArtifact(streaming_exe);
    streaming_run_cmd.step.dependOn(b.getInstallStep());

    const streaming_run_step = b.step("run_streaming", "Run the streaming JSON example");
    streaming_run_step.dependOn(&streaming_run_cmd.step);

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
