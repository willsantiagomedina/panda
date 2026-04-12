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
    exe.addCSourceFile(.{
        .file = b.path("src/frontmost.m"),
        .flags = &.{},
    });

    exe.root_module.linkFramework("ApplicationServices", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkSystemLibrary("objc", .{});
    exe.root_module.linkSystemLibrary("proc", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run panda");
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const check_step = b.step("check", "Compile panda");
    check_step.dependOn(&exe.step);

    const home = b.graph.env_map.get("HOME") orelse "/Users/willsantiago";
    const install_dir = b.fmt("{s}/.local/bin", .{home});
    const installed_bin = b.getInstallPath(.bin, "panda");
    const install_cli = b.addSystemCommand(&.{
        "/bin/zsh",
        "-lc",
        b.fmt(
            "mkdir -p {0s} && ln -sf {1s} {0s}/panda",
            .{ install_dir, installed_bin },
        ),
    });
    install_cli.step.dependOn(b.getInstallStep());

    const install_cli_step = b.step("install-cli", "Install panda into ~/.local/bin/panda");
    install_cli_step.dependOn(&install_cli.step);
}
