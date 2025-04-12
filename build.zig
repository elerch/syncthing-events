const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const mvzr_dep = b.dependency("mvzr", .{});
    const zeit_dep = b.dependency("zeit", .{});
    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("mvzr", mvzr_dep.module("mvzr"));
    lib_mod.addImport("zeit", zeit_dep.module("zeit"));

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("syncthing_events_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "syncthing_events",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "syncthing_events",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    const no_llvm = b.option(bool, "no-llvm", "skip use of llvm") orelse false;
    lib.use_llvm = !no_llvm;
    exe.use_llvm = !no_llvm;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    try docker(b, exe);
}

fn docker(b: *std.Build, compile: *std.Build.Step.Compile) !void {
    const DockerTarget = struct {
        platform: []const u8,
        target: std.Target.Query,
    };
    // From docker source:
    // https://github.com/containerd/containerd/blob/52f02c3aa1e7ccd448060375c821cae4e3300cdb/test/init-buildx.sh#L45
    // Platforms: linux/amd64, linux/arm64, linux/riscv64, linux/ppc64le, linux/s390x, linux/386, linux/arm/v7, linux/arm/v6
    const docker_targets = [_]DockerTarget{
        .{ .platform = "linux/amd64", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .platform = "linux/arm64", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .platform = "linux/riscv64", .target = .{ .cpu_arch = .riscv64, .os_tag = .linux } },
        .{ .platform = "linux/ppc64le", .target = .{ .cpu_arch = .powerpc64le, .os_tag = .linux } },
        .{ .platform = "linux/390x", .target = .{ .cpu_arch = .s390x, .os_tag = .linux } },
        .{ .platform = "linux/386", .target = .{ .cpu_arch = .x86, .os_tag = .linux } },
        .{ .platform = "linux/arm/v7", .target = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf } }, // linux/arm/v7
        .{ .platform = "linux/arm/v6", .target = .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .musleabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
        } },
    };
    const SubPath = struct {
        path: [3][]const u8,
        len: usize,
    };
    // We are going to put all the binaries in paths that will be happy with
    // the dockerfile at the end, which means we need to get all the platforms
    // into slices. We can do this at comptime, but need to use arrays, so we
    // will hard code 3 element arrays which will hold our linux/arm/v7. If
    // deeper platforms are invented by docker later, we'll need to tweak the
    // hardcoded "3" values above and below, but at least we'll throw a compile
    // error to let the maintainer of the code know they screwed up by adding
    // a hardcoded platform above without changing the hardcoded length values.
    // By having the components chopped up this way, we should be able to build
    // all this from a Windows host
    comptime var dest_sub_paths: [docker_targets.len]SubPath = undefined;
    comptime {
        for (docker_targets, 0..) |dt, inx| {
            var si = std.mem.splitScalar(u8, dt.platform, '/');
            var sub_path: SubPath = undefined;
            sub_path.len = 1 + std.mem.count(u8, dt.platform, "/");
            if (sub_path.len > 3) @compileError("Docker platform cannot have more than 2 forward slashes");
            var jnx: usize = 0;
            while (si.next()) |s| : (jnx += 1)
                sub_path.path[jnx] = s;
            dest_sub_paths[inx] = sub_path;
        }
    }

    const docker_step = b.step("docker", "Prepares the app for bundling as multi-platform docker image");
    for (docker_targets, 0..) |dt, i| {
        const target_module = b.createModule(.{
            .root_source_file = compile.root_module.root_source_file,
            .target = b.resolveTargetQuery(dt.target),
            .optimize = .ReleaseSafe,
        });
        for (compile.root_module.import_table.keys()) |k|
            target_module.addImport(k, compile.root_module.import_table.get(k).?);
        const target_exe = b.addExecutable(.{
            .name = compile.name,
            .root_module = target_module,
        });
        // We can't use our dest_sub_paths directly here, because adding
        // a value for "dest_sub_path" in the installArtifact options will also
        // override the use of the basename. So wee need to construct our own
        // slice. We know the number of path components though, so we will
        // alloc what we need (no free, since zig build uses an arena) and
        // copy our components in place
        var final_sub_path = try b.allocator.alloc([]const u8, dest_sub_paths[i].len + 1);
        for (dest_sub_paths[i].path, 0..) |p, j| final_sub_path[j] = p;
        final_sub_path[final_sub_path.len - 1] = target_exe.name; // add basename at end

        docker_step.dependOn(&b.addInstallArtifact(target_exe, .{
            .dest_sub_path = try std.fs.path.join(b.allocator, final_sub_path),
        }).step);
    }

    // The above will get us all the binaries, but we also need a dockerfile
    try dockerInstallDockerfile(b, docker_step, compile.name);
}

fn dockerInstallDockerfile(b: *std.Build, docker_step: *std.Build.Step, exe_name: []const u8) !void {
    const dockerfile_fmt =
        \\FROM alpine:latest as build
        \\RUN apk --update add ca-certificates
        \\
        \\FROM scratch
        \\ARG TARGETPLATFORM
        \\ENV PATH=/bin
        \\COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
        \\COPY bin/$TARGETPLATFORM/{s} /bin
    ;
    const dockerfile_data = try std.fmt.allocPrint(b.allocator, dockerfile_fmt, .{exe_name});
    const writefiles = b.addWriteFiles();
    const dockerfile = writefiles.add("Dockerfile", dockerfile_data);

    docker_step.dependOn(&b.addInstallFile(dockerfile, "Dockerfile").step);
}
