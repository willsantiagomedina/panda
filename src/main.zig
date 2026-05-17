const std = @import("std");
const ax = @import("ax.zig");
const config = @import("config.zig");
const events = @import("events.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");

const log = std.log.scoped(.panda);
const launch_agent_label = "dev.givepanda.panda";
const launch_agent_filename = launch_agent_label ++ ".plist";

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const maybe_command = args.next();
    if (maybe_command == null and try isRunningFromAppBundle(allocator)) {
        try launchAppDaemon(allocator);
        return;
    }
    const command = maybe_command orelse "help";

    if (std.mem.eql(u8, command, "help")) {
        try printUsage();
        return;
    }

    runCommand(command, &args, allocator) catch |err| switch (err) {
        error.InvalidArguments => {
            try printUsage();
            return;
        },
        error.AccessibilityDenied,
        error.AppNotFound,
        error.AppUnresponsive,
        error.AmbiguousTarget,
        error.AttributeUnsupported,
        error.InvalidPid,
        error.UnsupportedTarget,
        error.UnexpectedAxError,
        error.LaunchAgentFailed,
        => {
            try printCommandError(err);
            return;
        },
        else => return err,
    };
}

fn runCommand(command: []const u8, args: anytype, allocator: std.mem.Allocator) !void {
    if (std.mem.eql(u8, command, "focus")) {
        const direction = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "focus {s}", .{direction}));
        return;
    }

    if (std.mem.eql(u8, command, "swap")) {
        const direction = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "swap {s}", .{direction}));
        return;
    }

    if (std.mem.eql(u8, command, "border")) {
        const mode = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "border {s}", .{mode}));
        return;
    }

    if (std.mem.eql(u8, command, "desktop")) {
        const action = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;

        if (!isValidDesktopAction(action)) return error.InvalidArguments;

        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "desktop {s}", .{action}));
        return;
    }

    if (std.mem.eql(u8, command, "config")) {
        if (args.next() != null) return error.InvalidArguments;

        var loaded = try config.load(allocator);
        defer loaded.deinit(allocator);

        std.debug.print("config: {s}\n", .{loaded.path});
        std.debug.print("status: {s}\n", .{if (loaded.exists) "loaded" else "not found (using defaults)"});
        return;
    }

    if (std.mem.eql(u8, command, "permissions")) {
        if (args.next() != null) return error.InvalidArguments;
        try showPermissions();
        return;
    }

    if (std.mem.eql(u8, command, "install-daemon")) {
        if (args.next() != null) return error.InvalidArguments;
        try installDaemon(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "uninstall-daemon")) {
        if (args.next() != null) return error.InvalidArguments;
        try uninstallDaemon(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "daemon-status")) {
        if (args.next() != null) return error.InvalidArguments;
        try daemonStatus(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "update")) {
        if (args.next() != null) return error.InvalidArguments;
        try updateApp(allocator);
        return;
    }

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);

    if (std.mem.eql(u8, command, "list")) {
        try ax.ensureTrusted();
        const target = args.next() orelse return error.InvalidArguments;
        const pid = try ax.resolvePidForTarget(allocator, target);
        try listWindows(allocator, pid);
        return;
    }

    if (std.mem.eql(u8, command, "move")) {
        try ax.ensureTrusted();
        const target = args.next() orelse return error.InvalidArguments;
        const pid = try ax.resolvePidForTarget(allocator, target);
        const index = try parseNextInt(args.next(), usize);
        const x = try parseNextFloat(args.next());
        const y = try parseNextFloat(args.next());
        const width = try parseNextFloat(args.next());
        const height = try parseNextFloat(args.next());

        try moveWindow(allocator, pid, index, .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        });
        return;
    }

    if (std.mem.eql(u8, command, "tile")) {
        try ax.ensureTrusted();
        const target = args.next() orelse return error.InvalidArguments;
        const pid = try ax.resolvePidForTarget(allocator, target);
        const options = try parseRuntimeOptions(args, .{
            .scope = loaded_config.settings.scope orelse .focused_app,
            .layout_mode = loaded_config.settings.layout_mode orelse .bsp,
        });
        try tileWindows(allocator, pid, options);
        return;
    }

    if (std.mem.eql(u8, command, "apps")) {
        try listApps(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "active")) {
        try ax.ensureTrusted();
        try printActiveApp(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "daemon")) {
        try ax.ensureTrusted();
        const options = try parseRuntimeOptions(args, .{
            .scope = loaded_config.settings.scope orelse .all_apps_main_display,
            .layout_mode = loaded_config.settings.layout_mode orelse .bsp,
        });

        var loop = events.EventLoop.init(allocator, .{
            .scope = options.scope,
            .layout_options = .{
                .mode = options.layout_mode,
            },
            .border_enabled = loaded_config.settings.border_enabled orelse true,
            .performance = loaded_config.settings.performance,
            .hotkeys = loaded_config.settings.hotkeys,
            .desktop = loaded_config.settings.desktop,
        });
        defer loop.deinit();
        try loop.run();
        return;
    }

    return error.InvalidArguments;
}

fn isRunningFromAppBundle(allocator: std.mem.Allocator) !bool {
    const path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(path);
    return std.mem.indexOf(u8, path, "/Panda.app/Contents/MacOS/") != null;
}

fn launchAppDaemon(allocator: std.mem.Allocator) !void {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const quoted_exe = try shellQuote(allocator, exe_path);
    defer allocator.free(quoted_exe);

    const script = try std.fmt.allocPrint(allocator,
        \\set -euo pipefail
        \\LOG_DIR="$HOME/Library/Logs"
        \\mkdir -p "$LOG_DIR"
        \\if ! {0s} permissions >/dev/null 2>&1; then
        \\  {0s} permissions >/dev/null 2>&1 || true
        \\  exit 0
        \\fi
        \\{0s} uninstall-daemon >/dev/null 2>&1 || true
        \\pkill -f '/Applications/Panda.app/Contents/MacOS/panda-cli daemon' >/dev/null 2>&1 || true
        \\nohup {0s} daemon >>"$LOG_DIR/panda.log" 2>>"$LOG_DIR/panda.err.log" &
    , .{quoted_exe});
    defer allocator.free(script);

    _ = try runProcess(allocator, &.{ "/bin/zsh", "-lc", script });
}

fn isValidDesktopAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "next") or
        std.mem.eql(u8, action, "prev") or
        std.mem.eql(u8, action, "move-next") or
        std.mem.eql(u8, action, "move-prev") or
        parseDesktopIndex(action) != null or
        parseDesktopMoveIndex(action) != null;
}

fn parseDesktopIndex(raw: []const u8) ?usize {
    const parsed = std.fmt.parseUnsigned(usize, raw, 10) catch return null;
    if (parsed < 1 or parsed > 9) return null;
    return parsed;
}

fn parseDesktopMoveIndex(raw: []const u8) ?usize {
    if (!std.mem.startsWith(u8, raw, "move-")) return null;
    return parseDesktopIndex(raw[5..]);
}

fn sendDaemonCommand(allocator: std.mem.Allocator, command: []const u8) !void {
    defer allocator.free(command);
    const response = events.sendControlCommand(allocator, command) catch |err| switch (err) {
        error.DaemonUnavailable => {
            std.debug.print("panda daemon is not running.\nStart it with `panda install-daemon`, then retry.\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(response);
    std.debug.print("{s}", .{response});
}

fn showPermissions() !void {
    if (ax.isProcessTrusted()) {
        std.debug.print("Accessibility access is enabled for panda.\n", .{});
        return;
    }

    _ = ax.promptForAccessibility();
    std.debug.print(
        \\Accessibility access is not enabled for panda.
        \\macOS may have opened the permission prompt. If it did not, open:
        \\System Settings > Privacy & Security > Accessibility
        \\Then enable Panda or panda for this user.
        \\
    , .{});
}

fn installDaemon(allocator: std.mem.Allocator) !void {
    const self_executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_executable_path);
    const executable_path = try launchAgentExecutablePath(allocator, self_executable_path);
    defer allocator.free(executable_path);

    const plist_path = try launchAgentPath(allocator);
    defer allocator.free(plist_path);
    const log_path = try userPath(allocator, "Library/Logs/panda.log");
    defer allocator.free(log_path);
    const err_path = try userPath(allocator, "Library/Logs/panda.err.log");
    defer allocator.free(err_path);

    try ensureParentDir(plist_path);
    try ensureParentDir(log_path);

    const executable_xml = try xmlEscape(allocator, executable_path);
    defer allocator.free(executable_xml);
    const log_xml = try xmlEscape(allocator, log_path);
    defer allocator.free(log_xml);
    const err_xml = try xmlEscape(allocator, err_path);
    defer allocator.free(err_xml);

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>daemon</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\  <key>StandardOutPath</key>
        \\  <string>{s}</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>{s}</string>
        \\  <key>ProcessType</key>
        \\  <string>Interactive</string>
        \\</dict>
        \\</plist>
        \\
    , .{ launch_agent_label, executable_xml, log_xml, err_xml });
    defer allocator.free(plist);

    {
        var plist_file = try std.fs.createFileAbsolute(plist_path, .{ .truncate = true });
        defer plist_file.close();
        try plist_file.writeAll(plist);
    }

    const domain = try launchctlDomain(allocator);
    defer allocator.free(domain);
    const service = try launchctlService(allocator);
    defer allocator.free(service);

    _ = runProcess(allocator, &.{ "launchctl", "bootout", domain, plist_path }) catch {};
    try expectProcess(allocator, &.{ "launchctl", "bootstrap", domain, plist_path }, "load LaunchAgent");
    try expectProcess(allocator, &.{ "launchctl", "enable", service }, "enable LaunchAgent");
    try expectProcess(allocator, &.{ "launchctl", "kickstart", "-k", service }, "start daemon");

    std.debug.print("panda daemon installed and started.\nLaunchAgent: {s}\n", .{plist_path});
    if (!ax.isProcessTrusted()) {
        _ = ax.promptForAccessibility();
        std.debug.print("Accessibility access is still required. Enable Panda or panda in System Settings > Privacy & Security > Accessibility.\n", .{});
    }
}

fn uninstallDaemon(allocator: std.mem.Allocator) !void {
    const plist_path = try launchAgentPath(allocator);
    defer allocator.free(plist_path);
    const domain = try launchctlDomain(allocator);
    defer allocator.free(domain);

    _ = runProcess(allocator, &.{ "launchctl", "bootout", domain, plist_path }) catch {};
    std.fs.deleteFileAbsolute(plist_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.debug.print("panda daemon uninstalled.\n", .{});
}

fn updateApp(allocator: std.mem.Allocator) !void {
    const script =
        \\set -euo pipefail
        \\DMG_URL="${PANDA_DMG_URL:-https://givepanda.tech/releases/latest/panda-macos-universal.dmg}"
        \\TMP_DIR="$(mktemp -d)"
        \\cleanup() {
        \\  hdiutil detach "$TMP_DIR/mount" >/dev/null 2>&1 || true
        \\  rm -rf "$TMP_DIR"
        \\}
        \\trap cleanup EXIT
        \\cute() {
        \\  printf "\033[1;95mʕ•ᴥ•ʔ\033[0m %s\n" "$1"
        \\}
        \\cute "scampering off to fetch the freshest Panda..."
        \\curl -fsSL "$DMG_URL" -o "$TMP_DIR/panda.dmg"
        \\mkdir -p "$TMP_DIR/mount"
        \\cute "opening the bamboo crate..."
        \\hdiutil attach "$TMP_DIR/panda.dmg" -mountpoint "$TMP_DIR/mount" -nobrowse -quiet
        \\test -d "$TMP_DIR/mount/Panda.app"
        \\cute "putting the old panda down for a nap..."
        \\/Applications/Panda.app/Contents/MacOS/panda-cli uninstall-daemon >/dev/null 2>&1 || true
        \\pkill -f '/Applications/Panda.app/Contents/MacOS/panda-cli daemon' >/dev/null 2>&1 || true
        \\cute "moving the new panda into /Applications..."
        \\rm -rf /Applications/Panda.app
        \\cp -R "$TMP_DIR/mount/Panda.app" /Applications/Panda.app
        \\xattr -dr com.apple.quarantine /Applications/Panda.app >/dev/null 2>&1 || true
        \\cute "waking panda back up..."
        \\/Applications/Panda.app/Contents/MacOS/panda-cli install-daemon
        \\printf "\033[1;92mʕっ•ᴥ•ʔっ Panda is up to date!\033[0m\n"
    ;

    try expectProcessInherit(allocator, &.{ "/bin/zsh", "-lc", script }, "update Panda.app");
}

fn daemonStatus(allocator: std.mem.Allocator) !void {
    const service = try launchctlService(allocator);
    defer allocator.free(service);

    const loaded = (runProcess(allocator, &.{ "launchctl", "print", service }) catch null) != null;
    std.debug.print("LaunchAgent: {s}\n", .{if (loaded) "loaded" else "not loaded"});

    const response = events.sendControlCommand(allocator, "border status") catch |err| switch (err) {
        error.DaemonUnavailable => {
            std.debug.print("Control socket: unavailable\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(response);
    std.debug.print("Control socket: responsive\n{s}", .{response});
}

fn launchAgentPath(allocator: std.mem.Allocator) ![]u8 {
    return userPath(allocator, "Library/LaunchAgents/" ++ launch_agent_filename);
}

fn launchAgentExecutablePath(allocator: std.mem.Allocator, self_executable_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, self_executable_path, "/Contents/MacOS/panda-cli")) {
        const app_executable = try std.mem.concat(allocator, u8, &.{ self_executable_path[0 .. self_executable_path.len - "panda-cli".len], "Panda" });
        if (isExecutableFile(app_executable)) return app_executable;
        allocator.free(app_executable);
    }

    return allocator.dupe(u8, self_executable_path);
}

fn isExecutableFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    return (stat.mode & 0o111) != 0;
}

fn userPath(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, suffix });
}

fn launchctlDomain(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "gui/{d}", .{std.posix.getuid()});
}

fn launchctlService(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ std.posix.getuid(), launch_agent_label });
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
}

fn runProcess(allocator: std.mem.Allocator, argv: []const []const u8) !?void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| if (code == 0) {} else null,
        else => null,
    };
}

fn expectProcess(allocator: std.mem.Allocator, argv: []const []const u8, action: []const u8) !void {
    if ((try runProcess(allocator, argv)) == null) {
        std.debug.print("panda failed to {s}.\n", .{action});
        return error.LaunchAgentFailed;
    }
}

fn expectProcessInherit(allocator: std.mem.Allocator, argv: []const []const u8, action: []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("panda failed to {s}.\n", .{action});
    return error.LaunchAgentFailed;
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted = std.ArrayList(u8){};
    defer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, byte);
        }
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn xmlEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var escaped = std.ArrayList(u8){};
    defer escaped.deinit(allocator);

    for (value) |byte| {
        switch (byte) {
            '&' => try escaped.appendSlice(allocator, "&amp;"),
            '<' => try escaped.appendSlice(allocator, "&lt;"),
            '>' => try escaped.appendSlice(allocator, "&gt;"),
            '"' => try escaped.appendSlice(allocator, "&quot;"),
            '\'' => try escaped.appendSlice(allocator, "&apos;"),
            else => try escaped.append(allocator, byte),
        }
    }

    return escaped.toOwnedSlice(allocator);
}

fn listWindows(allocator: std.mem.Allocator, pid: i32) !void {
    const windows = try ax.listWindows(allocator, pid);
    defer {
        for (windows) |*window| {
            window.deinit(allocator);
        }
        allocator.free(windows);
    }

    for (windows) |window| {
        std.debug.print(
            "[{d}] {s} :: x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n",
            .{ window.index, window.title, window.frame.x, window.frame.y, window.frame.width, window.frame.height },
        );
    }
}

fn moveWindow(allocator: std.mem.Allocator, pid: i32, index: usize, frame: ax.Rect) !void {
    const windows = try ax.listWindows(allocator, pid);
    defer {
        for (windows) |*window| {
            window.deinit(allocator);
        }
        allocator.free(windows);
    }

    if (index >= windows.len) {
        return error.InvalidArguments;
    }

    try ax.moveResizeWindow(windows[index].element, frame);
    std.debug.print(
        "moved [{d}] {s} to x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n",
        .{ index, windows[index].title, frame.x, frame.y, frame.width, frame.height },
    );
}

const RuntimeOptions = struct {
    scope: state.SpaceState.WindowScope = .focused_app,
    layout_mode: layout.LayoutMode = .bsp,
};

fn parseRuntimeOptions(args: anytype, defaults: RuntimeOptions) !RuntimeOptions {
    var options = defaults;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scope")) {
            const value = args.next() orelse return error.InvalidArguments;
            options.scope = parseScope(value) orelse return error.InvalidArguments;
            continue;
        }

        if (std.mem.eql(u8, arg, "--layout")) {
            const value = args.next() orelse return error.InvalidArguments;
            options.layout_mode = parseLayoutMode(value) orelse return error.InvalidArguments;
            continue;
        }

        return error.InvalidArguments;
    }
    return options;
}

fn parseScope(value: []const u8) ?state.SpaceState.WindowScope {
    if (std.mem.eql(u8, value, "focused-app")) return .focused_app;
    if (std.mem.eql(u8, value, "all-main-display")) return .all_apps_main_display;
    return null;
}

fn parseLayoutMode(value: []const u8) ?layout.LayoutMode {
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "master-stack")) return .master_stack;
    if (std.mem.eql(u8, value, "bsp")) return .bsp;
    return null;
}

fn tileWindows(allocator: std.mem.Allocator, pid: i32, options: RuntimeOptions) !void {
    var space = state.SpaceState.init(allocator);
    defer space.deinit();

    const screen_bounds = ax.mainDisplayVisibleFrame();
    const screen = state.Rect{
        .x = screen_bounds.x,
        .y = screen_bounds.y,
        .width = screen_bounds.width,
        .height = screen_bounds.height,
    };
    try space.loadWindowsForScope(options.scope, pid, screen);
    if (space.window_order.items.len == 0) {
        std.debug.print("no windows found for scope {s}\n", .{@tagName(options.scope)});
        return;
    }
    try layout.apply(&space, screen, .{
        .mode = options.layout_mode,
    });

    std.debug.print(
        "tiled {d} windows (scope={s}, layout={s})\n",
        .{ space.window_order.items.len, @tagName(options.scope), @tagName(options.layout_mode) },
    );
}

fn parseNextInt(maybe_value: ?[]const u8, comptime T: type) !T {
    const value = maybe_value orelse return error.InvalidArguments;
    return std.fmt.parseInt(T, value, 10);
}

fn parseNextFloat(maybe_value: ?[]const u8) !f64 {
    const value = maybe_value orelse return error.InvalidArguments;
    return std.fmt.parseFloat(f64, value);
}

fn listApps(allocator: std.mem.Allocator) !void {
    const apps = try ax.listRunningApps(allocator);
    defer {
        for (apps) |*app| app.deinit(allocator);
        allocator.free(apps);
    }

    if (apps.len == 0) {
        std.debug.print("no running GUI apps were found\n", .{});
        return;
    }

    for (apps) |app| {
        std.debug.print("{d: >6}  {s}  {s}\n", .{ app.pid, app.name, app.bundle_path });
    }
}

fn printActiveApp(allocator: std.mem.Allocator) !void {
    var app = try ax.focusedApplication(allocator);
    defer app.deinit(allocator);

    std.debug.print(
        "frontmost app: {s} (pid {d})\nbundle: {s}\n",
        .{ app.name, app.pid, app.bundle_path },
    );

    const windows = ax.listWindows(allocator, app.pid) catch |err| switch (err) {
        error.AppUnresponsive,
        error.AttributeUnsupported,
        error.UnsupportedTarget,
        error.InvalidPid,
        => {
            std.debug.print("windows: unavailable ({s})\n", .{@errorName(err)});
            return;
        },
        else => return err,
    };
    defer {
        for (windows) |*window| window.deinit(allocator);
        allocator.free(windows);
    }

    std.debug.print("windows: {d}\n", .{windows.len});
}

fn printUsage() !void {
    std.debug.print(
        \\panda commands:
        \\  panda list PID_OR_APP
        \\  panda move PID_OR_APP WINDOW_INDEX X Y WIDTH HEIGHT
        \\  panda tile PID_OR_APP [--scope focused-app|all-main-display] [--layout bsp|grid|master-stack]
        \\  panda apps
        \\  panda active
        \\  panda daemon [--scope focused-app|all-main-display] [--layout bsp|grid|master-stack]
        \\  panda install-daemon
        \\  panda uninstall-daemon
        \\  panda daemon-status
        \\  panda update
        \\  panda permissions
        \\  panda focus left|right|up|down
        \\  panda swap left|right|up|down
        \\  panda border on|off|toggle|status
        \\  panda desktop next|prev|move-next|move-prev|1..9|move-1..9
        \\  panda config
        \\
        \\Config:
        \\  panda reads ~/.config/panda/config.lua (or $PANDA_CONFIG) for defaults,
        \\  runtime tuning, desktop key chords, and optional global hotkeys.
        \\
        \\Examples:
        \\  panda install-daemon
        \\  panda daemon-status
        \\  panda focus right
        \\  panda desktop next
        \\  panda config
        \\
        \\Install: curl -fsSL https://givepanda.tech/install.sh | bash
        \\         or brew install willsantiago/tap/panda
        \\
        \\Accessibility permission required in System Settings > Privacy & Security > Accessibility.
        \\
    , .{});

    _ = layout;
    _ = state;
}

fn printCommandError(err: anyerror) !void {
    const message = switch (err) {
        error.AccessibilityDenied =>
        \\Accessibility access is not enabled for panda.
        \\Run `panda permissions`, then grant access in System Settings > Privacy & Security > Accessibility.
        ,
        error.AppNotFound =>
        \\No running app matched that target.
        \\Pass a live PID, use `active` for the frontmost app, or run `panda apps` to see the exact app names panda can target.
        ,
        error.AmbiguousTarget =>
        \\More than one running app matched that target.
        \\Pass a numeric PID to disambiguate the exact process you want.
        ,
        error.InvalidPid =>
        \\The PID is not a live accessibility target.
        \\Pass the PID of a running macOS app, for example: pgrep -x Terminal
        ,
        error.AppUnresponsive =>
        \\The target app did not respond to the accessibility API.
        \\Check that the PID is correct and that the app is running with visible windows.
        ,
        error.AttributeUnsupported, error.UnsupportedTarget =>
        \\The target app does not expose the accessibility attributes panda needs for window management.
        \\Try a standard Cocoa app such as Terminal or Safari first.
        ,
        error.UnexpectedAxError =>
        \\macOS returned an unhandled accessibility error.
        \\Retry with a known app PID; if it still fails, we need to extend the AX bridge diagnostics further.
        ,
        error.LaunchAgentFailed =>
        \\panda could not install or start the LaunchAgent.
        \\Run `launchctl print gui/$UID/dev.givepanda.panda` and check ~/Library/Logs/panda.err.log for details.
        ,
        error.DaemonUnavailable =>
        \\panda daemon is not running.
        \\Start it with `panda install-daemon`, then retry the runtime command.
        ,
        error.EnvironmentVariableNotFound =>
        \\panda could not resolve a home directory for config loading.
        \\Set HOME or PANDA_CONFIG and retry.
        ,
        else => "panda failed.\n",
    };

    std.debug.print("{s}\n", .{message});
}

test "desktop cli action validation" {
    inline for ([_][]const u8{
        "next",
        "prev",
        "move-next",
        "move-prev",
        "1",
        "9",
        "move-1",
        "move-9",
    }) |action| {
        try std.testing.expect(isValidDesktopAction(action));
    }

    inline for ([_][]const u8{
        "0",
        "10",
        "move-0",
        "move-10",
        "move",
        "desktop-1",
    }) |action| {
        try std.testing.expect(!isValidDesktopAction(action));
    }
}
