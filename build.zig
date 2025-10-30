// build.zig
const std = @import("std");

// libuv source files - common to all platforms
const libuv_common_sources = [_][]const u8{
    "third_party/libuv/src/fs-poll.c",
    "third_party/libuv/src/idna.c",
    "third_party/libuv/src/inet.c",
    "third_party/libuv/src/random.c",
    "third_party/libuv/src/strscpy.c",
    "third_party/libuv/src/strtok.c",
    "third_party/libuv/src/thread-common.c",
    "third_party/libuv/src/threadpool.c",
    "third_party/libuv/src/timer.c",
    "third_party/libuv/src/uv-common.c",
    "third_party/libuv/src/uv-data-getter-setters.c",
    "third_party/libuv/src/version.c",
};

// libuv source files - Unix/POSIX platforms (Linux, macOS, BSD)
const libuv_unix_sources = [_][]const u8{
    "third_party/libuv/src/unix/async.c",
    "third_party/libuv/src/unix/core.c",
    "third_party/libuv/src/unix/dl.c",
    "third_party/libuv/src/unix/fs.c",
    "third_party/libuv/src/unix/getaddrinfo.c",
    "third_party/libuv/src/unix/getnameinfo.c",
    "third_party/libuv/src/unix/loop-watcher.c",
    "third_party/libuv/src/unix/loop.c",
    "third_party/libuv/src/unix/pipe.c",
    "third_party/libuv/src/unix/poll.c",
    "third_party/libuv/src/unix/process.c",
    "third_party/libuv/src/unix/random-devurandom.c",
    "third_party/libuv/src/unix/signal.c",
    "third_party/libuv/src/unix/stream.c",
    "third_party/libuv/src/unix/tcp.c",
    "third_party/libuv/src/unix/thread.c",
    "third_party/libuv/src/unix/tty.c",
    "third_party/libuv/src/unix/udp.c",
};

// libuv source files - macOS/Darwin specific
const libuv_darwin_sources = [_][]const u8{
    "third_party/libuv/src/unix/proctitle.c",
    "third_party/libuv/src/unix/bsd-ifaddrs.c",
    "third_party/libuv/src/unix/kqueue.c",
    "third_party/libuv/src/unix/random-getentropy.c",
    "third_party/libuv/src/unix/darwin-proctitle.c",
    "third_party/libuv/src/unix/darwin.c",
    "third_party/libuv/src/unix/fsevents.c",
};

// libuv source files - Linux specific
const libuv_linux_sources = [_][]const u8{
    "third_party/libuv/src/unix/proctitle.c",
    "third_party/libuv/src/unix/linux.c",
    "third_party/libuv/src/unix/procfs-exepath.c",
    "third_party/libuv/src/unix/random-getrandom.c",
    "third_party/libuv/src/unix/random-sysctl-linux.c",
};

// libuv source files - Windows specific
const libuv_windows_sources = [_][]const u8{
    "third_party/libuv/src/win/async.c",
    "third_party/libuv/src/win/core.c",
    "third_party/libuv/src/win/detect-wakeup.c",
    "third_party/libuv/src/win/dl.c",
    "third_party/libuv/src/win/error.c",
    "third_party/libuv/src/win/fs.c",
    "third_party/libuv/src/win/fs-event.c",
    "third_party/libuv/src/win/getaddrinfo.c",
    "third_party/libuv/src/win/getnameinfo.c",
    "third_party/libuv/src/win/handle.c",
    "third_party/libuv/src/win/loop-watcher.c",
    "third_party/libuv/src/win/pipe.c",
    "third_party/libuv/src/win/thread.c",
    "third_party/libuv/src/win/poll.c",
    "third_party/libuv/src/win/process.c",
    "third_party/libuv/src/win/process-stdio.c",
    "third_party/libuv/src/win/signal.c",
    "third_party/libuv/src/win/snprintf.c",
    "third_party/libuv/src/win/stream.c",
    "third_party/libuv/src/win/tcp.c",
    "third_party/libuv/src/win/tty.c",
    "third_party/libuv/src/win/udp.c",
    "third_party/libuv/src/win/util.c",
    "third_party/libuv/src/win/winapi.c",
    "third_party/libuv/src/win/winsock.c",
};

// libuv system libraries - Windows only
const libuv_windows_libs = [_][]const u8{
    "psapi",
    "user32",
    "advapi32",
    "iphlpapi",
    "userenv",
    "ws2_32",
    "dbghelp",
    "ole32",
    "shell32",
};

/// Add libuv to the build with proper cross-platform detection
fn addLibuv(b: *std.Build, artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const os_tag = target.result.os.tag;

    // Add include paths (common to all platforms)
    artifact.root_module.addIncludePath(b.path("third_party/libuv/include"));
    artifact.root_module.addIncludePath(b.path("third_party/libuv/src"));

    // Add common sources (all platforms)
    inline for (libuv_common_sources) |path| {
        artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
    }

    // Add platform-specific sources and configuration
    if (os_tag == .windows) {
        // Windows-specific configuration
        artifact.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        artifact.root_module.addCMacro("_WIN32_WINNT", "0x0A00");
        artifact.root_module.addCMacro("_CRT_DECLARE_NONSTDC_NAMES", "0");

        // Add Windows sources
        inline for (libuv_windows_sources) |path| {
            artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
        }

        // Link Windows system libraries
        inline for (libuv_windows_libs) |name| {
            artifact.linkSystemLibrary(name);
        }
    } else if (os_tag == .macos) {
        // macOS-specific configuration
        artifact.root_module.addCMacro("_DARWIN_UNLIMITED_SELECT", "1");
        artifact.root_module.addCMacro("_DARWIN_USE_64_BIT_INODE", "1");

        // Add Unix base sources
        inline for (libuv_unix_sources) |path| {
            artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
        }

        // Add Darwin-specific sources
        inline for (libuv_darwin_sources) |path| {
            artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
        }

        // macOS doesn't need explicit pthread linking (part of libSystem)
    } else if (os_tag == .linux) {
        // Linux-specific configuration
        artifact.root_module.addCMacro("_GNU_SOURCE", "1");
        artifact.root_module.addCMacro("_POSIX_C_SOURCE", "200112");

        // Add Unix base sources
        inline for (libuv_unix_sources) |path| {
            artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
        }

        // Add Linux-specific sources
        inline for (libuv_linux_sources) |path| {
            artifact.addCSourceFile(.{ .file = b.path(path), .flags = &[_][]const u8{} });
        }

        // Link pthread on Linux
        artifact.linkSystemLibrary("pthread");
    } else {
        std.debug.print("ERROR: Unsupported platform '{s}'. Zerver currently supports Windows, macOS, and Linux.\n", .{@tagName(os_tag)});
        std.process.exit(1);
    }
}

fn addTimedTestRun(
    b: *std.Build,
    timeout_runner: *std.Build.Step.Compile,
    artifact: *std.Build.Step.Compile,
    parents: []const *std.Build.Step,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(timeout_runner);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run.addArtifactArg(artifact);
    for (parents) |parent| {
        parent.dependOn(&run.step);
    }
    return run;
}

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
    addLibuv(b, exe, target);
    // NOTE: Disabled - main.zig uses old monolithic architecture that was replaced by DLLs
    // b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Development helper steps
    // Create zerver module with proper paths and platform-specific configuration
    const zerver_mod = b.createModule(.{
        .root_source_file = b.path("src/zerver/root.zig"),
    });
    zerver_mod.addIncludePath(b.path("third_party/libuv/include"));
    zerver_mod.addIncludePath(b.path("third_party/libuv/src"));

    // Create zupervisor module for slot-effect system
    const zupervisor_mod = b.createModule(.{
        .root_source_file = b.path("src/zupervisor/slot_effect.zig"),
    });

    // Add platform-specific macros for the zerver module
    switch (target.result.os.tag) {
        .windows => {
            zerver_mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
            zerver_mod.addCMacro("_WIN32_WINNT", "0x0A00");
            zerver_mod.addCMacro("_CRT_DECLARE_NONSTDC_NAMES", "0");
        },
        .macos => {
            zerver_mod.addCMacro("_DARWIN_UNLIMITED_SELECT", "1");
            zerver_mod.addCMacro("_DARWIN_USE_64_BIT_INODE", "1");
        },
        .linux => {
            zerver_mod.addCMacro("_GNU_SOURCE", "1");
            zerver_mod.addCMacro("_POSIX_C_SOURCE", "200112");
        },
        else => {},
    }

    // NOTE: runtime_config module commented out - files use relative imports instead
    // const runtime_config_mod = b.createModule(.{
    //     .root_source_file = b.path("src/zerver/runtime/config.zig"),
    // });

    // exe.root_module.addImport("runtime_config", runtime_config_mod);

    // zerver_mod.addImport("runtime_config", runtime_config_mod);

    const bootstrap_helpers_mod = b.createModule(.{
        .root_source_file = b.path("src/zerver/bootstrap_helpers.zig"),
    });
    // bootstrap_helpers_mod.addImport("runtime_config", runtime_config_mod);

    const timeout_runner = b.addExecutable(.{
        .name = "test_timeout_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/test_timeout_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Development helper steps
    const test_step = b.step("test", "Run all tests");
    const integration_step = b.step("integration_tests", "Run integration test suite");
    const reqtest_suite = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reqtest_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    reqtest_suite.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, reqtest_suite, &.{test_step});

    const libuv_smoke = b.addExecutable(.{
        .name = "libuv_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/libuv_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    libuv_smoke.linkLibC();
    addLibuv(b, libuv_smoke, target);
    const libuv_smoke_step = b.step("libuv_smoke", "Run the libuv smoke test");
    _ = addTimedTestRun(b, timeout_runner, libuv_smoke, &.{ test_step, libuv_smoke_step });

    const reactor_tests_step = b.step("reactor_tests", "Run reactor unit tests");

    const join_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reactor_join.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    join_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, join_tests, &.{reactor_tests_step});

    const job_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reactor_job_system.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    job_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, job_tests, &.{reactor_tests_step});

    const effectors_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reactor_effectors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    effectors_tests.root_module.addImport("zerver", zerver_mod);
    effectors_tests.linkLibC();
    addLibuv(b, effectors_tests, target);
    _ = addTimedTestRun(b, timeout_runner, effectors_tests, &.{reactor_tests_step});

    const util_helper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/util_helpers_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    util_helper_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, util_helper_tests, &.{test_step});

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/root_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    root_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, root_tests, &.{test_step});

    const circuit_breaker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/circuit_breaker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    circuit_breaker_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, circuit_breaker_tests, &.{test_step});

    const core_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/core_core_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    core_core_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, core_core_tests, &.{test_step});

    const ctx_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/ctx_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ctx_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, ctx_tests, &.{test_step});

    const reqtest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reqtest_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    reqtest_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, reqtest_tests, &.{test_step});

    const http_status_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/http_status_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_status_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, http_status_tests, &.{test_step});

    const router_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/router_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    router_unit_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, router_unit_tests, &.{test_step});

    const libuv_async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/libuv_unit_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    libuv_async_tests.root_module.addImport("zerver", zerver_mod);
    libuv_async_tests.linkLibC();
    addLibuv(b, libuv_async_tests, target);
    _ = addTimedTestRun(b, timeout_runner, libuv_async_tests, &.{reactor_tests_step});

    const sql_ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sql_ast_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sql_ast_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, sql_ast_tests, &.{test_step});

    const sql_builder_renderer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sql_builder_renderer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sql_builder_renderer_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, sql_builder_renderer_tests, &.{test_step});

    const sql_db_driver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sql_db_driver_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sql_db_driver_tests.root_module.addImport("zerver", zerver_mod);
    sql_db_driver_tests.addCSourceFile(.{
        .file = b.path("src/zerver/sql/dialects/sqlite/c/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    sql_db_driver_tests.linkLibC();
    _ = addTimedTestRun(b, timeout_runner, sql_db_driver_tests, &.{test_step});

    const sql_modules_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/sql_modules_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sql_modules_tests.root_module.addImport("zerver", zerver_mod);
    sql_modules_tests.linkLibC();
    _ = addTimedTestRun(b, timeout_runner, sql_modules_tests, &.{test_step});

    const types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/types_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    types_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, types_tests, &.{test_step});

    const error_renderer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/error_renderer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    error_renderer_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, error_renderer_tests, &.{test_step});

    const bootstrap_init_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/bootstrap_init_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bootstrap_init_tests.root_module.addImport("zerver", zerver_mod);
    bootstrap_init_tests.root_module.addImport("bootstrap_helpers", bootstrap_helpers_mod);
    // bootstrap_init_tests.root_module.addImport("runtime_config", runtime_config_mod);
    _ = addTimedTestRun(b, timeout_runner, bootstrap_init_tests, &.{test_step});

    const saga_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reactor_saga.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    saga_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, saga_tests, &.{reactor_tests_step});

    const task_system_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/reactor_task_system.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    task_system_tests.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, task_system_tests, &.{reactor_tests_step});

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

    // Slot-effect pipeline demo executable (simple self-contained version)
    const slot_effect_demo = b.addExecutable(.{
        .name = "slot_effect_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/slot_effect_simple_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    slot_effect_demo.root_module.addImport("slot_effect", zupervisor_mod);
    b.installArtifact(slot_effect_demo);

    const slot_effect_demo_run_cmd = b.addRunArtifact(slot_effect_demo);
    slot_effect_demo_run_cmd.step.dependOn(b.getInstallStep());

    const slot_effect_demo_run_step = b.step("run_slot_demo", "Run the slot-effect pipeline demo");
    slot_effect_demo_run_step.dependOn(&slot_effect_demo_run_cmd.step);

    // ========================================================================
    // Multi-Process Architecture: Zingest + Zupervisor
    // ========================================================================

    // Zingest executable (HTTP Ingest Server - Process 1)
    const zingest_exe = b.addExecutable(.{
        .name = "zingest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zingest/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    zingest_exe.root_module.addImport("zerver", zerver_mod);
    zingest_exe.linkLibC();
    addLibuv(b, zingest_exe, target);

    b.installArtifact(zingest_exe);

    const zingest_run_cmd = b.addRunArtifact(zingest_exe);
    zingest_run_cmd.step.dependOn(b.getInstallStep());

    const zingest_run_step = b.step("run_zingest", "Run the Zingest HTTP ingest server");
    zingest_run_step.dependOn(&zingest_run_cmd.step);

    // Zupervisor executable (Supervisor with Hot Reload - Process 2)
    const zupervisor_exe = b.addExecutable(.{
        .name = "zupervisor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zupervisor/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    zupervisor_exe.root_module.addImport("zerver", zerver_mod);
    zupervisor_exe.linkLibC();
    addLibuv(b, zupervisor_exe, target);

    // Add SQLite for database effect executors
    zupervisor_exe.addCSourceFile(.{
        .file = b.path("src/zerver/sql/dialects/sqlite/c/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
        },
    });

    b.installArtifact(zupervisor_exe);

    const zupervisor_run_cmd = b.addRunArtifact(zupervisor_exe);
    zupervisor_run_cmd.step.dependOn(b.getInstallStep());

    const zupervisor_run_step = b.step("run_zupervisor", "Run the Zupervisor with hot reload");
    zupervisor_run_step.dependOn(&zupervisor_run_cmd.step);

    // ========================================================================
    // Feature DLLs - Slot-Effect Architecture
    // ========================================================================

    // Note: Skipping auth DLL build for now - will add proper module support later
    // The auth_slot_effect code is complete and tested, but needs proper build integration
    const auth_dll_step = b.step("auth_dll", "Build the auth feature DLL (not implemented yet)");
    _ = auth_dll_step;

    // Teams example executable - commented out due to compilation errors
    const reqtest_runner = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reqtest_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    reqtest_runner.root_module.addImport("zerver", zerver_mod);
    _ = addTimedTestRun(b, timeout_runner, reqtest_runner, &.{test_step});

    const rfc9110_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/rfc9110_semantics_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rfc9110_tests.root_module.addImport("zerver", zerver_mod);
    rfc9110_tests.linkLibC();
    addLibuv(b, rfc9110_tests, target);
    _ = addTimedTestRun(b, timeout_runner, rfc9110_tests, &.{ test_step, integration_step });

    const rfc9112_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/rfc9112_message_format_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rfc9112_tests.root_module.addImport("zerver", zerver_mod);
    rfc9112_tests.linkLibC();
    addLibuv(b, rfc9112_tests, target);
    _ = addTimedTestRun(b, timeout_runner, rfc9112_tests, &.{ test_step, integration_step });

    const router_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/router_functionality_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    router_tests.root_module.addImport("zerver", zerver_mod);
    router_tests.linkLibC();
    addLibuv(b, router_tests, target);
    _ = addTimedTestRun(b, timeout_runner, router_tests, &.{ test_step, integration_step });
    // teams_run_cmd.step.dependOn(b.getInstallStep());

    // const teams_run_step = b.step("run_teams", "Run the teams example on port 8081");
    // teams_run_step.dependOn(&teams_run_cmd.step);
}
