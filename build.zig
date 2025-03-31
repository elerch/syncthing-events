const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add mvzr dependency
    const mvzr_dep = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the library module
    const lib_mod = b.addModule("syncthing_events_lib", .{
        .source_file = .{ .path = "src/root.zig" },
        .dependencies = &.{
            .{ .name = "mvzr", .module = mvzr_dep.module("mvzr") },
        },
    });

    // Create the executable module
    const exe_mod = b.addModule("syncthing_events_exe", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "syncthing_events_lib", .module = lib_mod },
        },
    });

    // Create the library
    const lib = b.addStaticLibrary(.{
        .name = "syncthing_events",
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.addModule("mvzr", mvzr_dep.module("mvzr"));
    b.installArtifact(lib);

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "syncthing_events",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("syncthing_events_lib", lib_mod);
    b.installArtifact(exe);

    // Create run command
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Create test step
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.addModule("mvzr", mvzr_dep.module("mvzr"));

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.addModule("syncthing_events_lib", lib_mod);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}


