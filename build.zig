const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SQLite compile flags for single-threaded use and portability
    const sqlite_flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
    };

    const exe = b.addExecutable(.{
        .name = "rig-db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add SQLite as a C source file
    exe.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });

    // Add include path for sqlite3.h
    exe.addIncludePath(b.path("deps/sqlite"));

    // Link libc (required for SQLite)
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test for main.zig
    const main_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add SQLite to main tests as well
    main_unit_tests.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
    main_unit_tests.addIncludePath(b.path("deps/sqlite"));
    main_unit_tests.linkLibC();

    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);

    // Test for paths.zig
    const paths_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/paths.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_paths_unit_tests = b.addRunArtifact(paths_unit_tests);

    // Test for daemon/server.zig
    const server_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    server_unit_tests.linkLibC();

    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    // Test for daemon/protocol.zig
    const protocol_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protocol_unit_tests.linkLibC();

    const run_protocol_unit_tests = b.addRunArtifact(protocol_unit_tests);

    // Test for daemon/queue.zig
    const queue_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/queue.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_unit_tests.linkLibC();

    const run_queue_unit_tests = b.addRunArtifact(queue_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_paths_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);
    test_step.dependOn(&run_protocol_unit_tests.step);
    test_step.dependOn(&run_queue_unit_tests.step);
    // Note: uuid and client tests are run via main_unit_tests (refAllDecls)
}
