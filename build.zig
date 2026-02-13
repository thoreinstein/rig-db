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

    // PCRE2 compile flags
    const pcre2_flags = &[_][]const u8{
        "-DHAVE_CONFIG_H",
        "-DPCRE2_CODE_UNIT_WIDTH=8",
        "-DPCRE2_STATIC",
        "-DSUPPORT_UNICODE",
    };

    // PCRE2 source files
    const pcre2_sources = &[_][]const u8{
        "deps/pcre2/src/pcre2_auto_possess.c",
        "deps/pcre2/src/pcre2_chartables.c",
        "deps/pcre2/src/pcre2_chkdint.c",
        "deps/pcre2/src/pcre2_compile.c",
        "deps/pcre2/src/pcre2_config.c",
        "deps/pcre2/src/pcre2_context.c",
        "deps/pcre2/src/pcre2_convert.c",
        "deps/pcre2/src/pcre2_dfa_match.c",
        "deps/pcre2/src/pcre2_error.c",
        "deps/pcre2/src/pcre2_extuni.c",
        "deps/pcre2/src/pcre2_find_bracket.c",
        "deps/pcre2/src/pcre2_maketables.c",
        "deps/pcre2/src/pcre2_match.c",
        "deps/pcre2/src/pcre2_match_data.c",
        "deps/pcre2/src/pcre2_newline.c",
        "deps/pcre2/src/pcre2_ord2utf.c",
        "deps/pcre2/src/pcre2_pattern_info.c",
        "deps/pcre2/src/pcre2_script_run.c",
        "deps/pcre2/src/pcre2_serialize.c",
        "deps/pcre2/src/pcre2_string_utils.c",
        "deps/pcre2/src/pcre2_study.c",
        "deps/pcre2/src/pcre2_substitute.c",
        "deps/pcre2/src/pcre2_substring.c",
        "deps/pcre2/src/pcre2_tables.c",
        "deps/pcre2/src/pcre2_ucd.c",
        // pcre2_ucptables.c is #included by pcre2_tables.c, not compiled separately
        "deps/pcre2/src/pcre2_valid_utf.c",
        "deps/pcre2/src/pcre2_xclass.c",
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
    exe.addIncludePath(b.path("deps/sqlite"));

    // Add PCRE2
    addPcre2(exe, pcre2_sources, pcre2_flags);

    // Link libc (required for SQLite and PCRE2)
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

    // Add SQLite to main tests
    main_unit_tests.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
    main_unit_tests.addIncludePath(b.path("deps/sqlite"));

    // Add PCRE2 to main tests
    addPcre2(main_unit_tests, pcre2_sources, pcre2_flags);

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

    // Test for daemon/sanitizer.zig
    const sanitizer_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/sanitizer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addPcre2(sanitizer_unit_tests, pcre2_sources, pcre2_flags);
    sanitizer_unit_tests.linkLibC();

    const run_sanitizer_unit_tests = b.addRunArtifact(sanitizer_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_paths_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);
    test_step.dependOn(&run_protocol_unit_tests.step);
    test_step.dependOn(&run_queue_unit_tests.step);
    test_step.dependOn(&run_sanitizer_unit_tests.step);
    // Note: uuid, client, daemon, and writer tests are run via main_unit_tests (refAllDecls)
}

fn addPcre2(step: *std.Build.Step.Compile, sources: []const []const u8, flags: []const []const u8) void {
    const b = step.step.owner;
    for (sources) |src| {
        step.addCSourceFile(.{
            .file = b.path(src),
            .flags = flags,
        });
    }
    step.addIncludePath(b.path("deps/pcre2/src"));
}
