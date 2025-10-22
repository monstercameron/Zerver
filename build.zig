const std = @import("std");

pub fn build(b: *std.Build) void {
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
