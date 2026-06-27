const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "panda",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/frontmost.m"),
        .flags = &.{},
    });

    exe.root_module.linkFramework("ApplicationServices", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("Carbon", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("UserNotifications", .{});
    exe.root_module.linkSystemLibrary("objc", .{});
    exe.root_module.linkSystemLibrary("proc", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run panda");
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "Compile panda");
    check_step.dependOn(&exe.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addIncludePath(b.path("src"));
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/frontmost.m"),
        .flags = &.{},
    });
    tests.root_module.linkFramework("ApplicationServices", .{});
    tests.root_module.linkFramework("AppKit", .{});
    tests.root_module.linkFramework("CoreFoundation", .{});
    tests.root_module.linkFramework("CoreGraphics", .{});
    tests.root_module.linkFramework("Carbon", .{});
    tests.root_module.linkFramework("Foundation", .{});
    tests.root_module.linkFramework("QuartzCore", .{});
    tests.root_module.linkFramework("UserNotifications", .{});
    tests.root_module.linkSystemLibrary("objc", .{});
    tests.root_module.linkSystemLibrary("proc", .{});
    tests.root_module.link_libc = true;

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const home = b.graph.environ_map.get("HOME") orelse @panic("HOME is required for install-cli");
    const install_dir = b.fmt("{s}/.local/bin", .{home});
    const installed_bin = b.getInstallPath(.bin, "panda");
    const install_dest = b.fmt("{s}/panda", .{install_dir});

    const mkdir_cli_dir = b.addSystemCommand(&.{ "/bin/mkdir", "-p", install_dir });

    const install_cli = b.addSystemCommand(&.{ "/bin/ln", "-sf", installed_bin, install_dest });
    install_cli.step.dependOn(&mkdir_cli_dir.step);
    install_cli.step.dependOn(b.getInstallStep());

    const install_cli_step = b.step("install-cli", "Install panda into ~/.local/bin/panda");
    install_cli_step.dependOn(&install_cli.step);
}
