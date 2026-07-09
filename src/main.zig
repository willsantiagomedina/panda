const std = @import("std");
const builtin = @import("builtin");
const ax = @import("ax.zig");
const config = @import("config.zig");
const events = @import("events.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");
const workspaces = @import("workspaces.zig");

const log = std.log.scoped(.panda);
const launch_agent_label = "dev.givepanda.panda";
const launch_agent_filename = launch_agent_label ++ ".plist";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
            std.process.exit(1);
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
        error.UpdateFailed,
        error.DoctorFailed,
        error.DaemonUnavailable,
        error.DaemonCommandFailed,
        => {
            try printCommandError(err);
            std.process.exit(1);
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

    if (std.mem.eql(u8, command, "debug")) {
        const subject = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        if (!std.mem.eql(u8, subject, "windows")) return error.InvalidArguments;
        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "debug {s}", .{subject}));
        return;
    }

    if (std.mem.eql(u8, command, "reload")) {
        if (args.next() != null) return error.InvalidArguments;
        try sendDaemonCommand(allocator, try allocator.dupe(u8, "reload"));
        return;
    }

    if (std.mem.eql(u8, command, "hotkeys")) {
        const action = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        if (!std.mem.eql(u8, action, "pause") and !std.mem.eql(u8, action, "resume")) return error.InvalidArguments;
        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "hotkeys {s}", .{action}));
        return;
    }

    if (std.mem.eql(u8, command, "restart")) {
        if (args.next() != null) return error.InvalidArguments;
        try installDaemon(allocator);
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

    if (std.mem.eql(u8, command, "doctor")) {
        if (args.next() != null) return error.InvalidArguments;
        try runDoctor(allocator);
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
        const maybe_flag = args.next();
        const force = if (maybe_flag) |flag|
            std.mem.eql(u8, flag, "--force")
        else
            false;
        if (maybe_flag != null and !force) return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        try updateApp(allocator, force);
        return;
    }

    if (std.mem.eql(u8, command, "notify-updated")) {
        if (args.next() != null) return error.InvalidArguments;
        ax.postUserNotification("Panda updated", "Your new workspace powers are ready.");
        return;
    }

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);

    if (std.mem.eql(u8, command, "list")) {
        const target = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        try ax.ensureTrusted();
        const pid = try ax.resolvePidForTarget(allocator, target);
        try listWindows(allocator, pid);
        return;
    }

    if (std.mem.eql(u8, command, "move")) {
        const target = args.next() orelse return error.InvalidArguments;
        const index = try parseNextInt(args.next(), usize);
        const x = try parseNextFloat(args.next());
        const y = try parseNextFloat(args.next());
        const width = try parseNextFloat(args.next());
        const height = try parseNextFloat(args.next());
        if (args.next() != null) return error.InvalidArguments;

        try ax.ensureTrusted();
        const pid = try ax.resolvePidForTarget(allocator, target);
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
        if (args.next() != null) return error.InvalidArguments;
        try listApps(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "active")) {
        if (args.next() != null) return error.InvalidArguments;
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

    if (std.mem.indexOf(u8, exe_path, "/Applications/Panda.app/Contents/MacOS/") == null) {
        const app_root = appBundleRoot(exe_path) orelse return;
        const quoted_app = try shellQuote(allocator, app_root);
        defer allocator.free(quoted_app);
        const install_script = try std.fmt.allocPrint(allocator,
            \\set -euo pipefail
            \\INSTALLED_APP="/Applications/Panda.app"
            \\rm -rf "$INSTALLED_APP"
            \\cp -R {0s} "$INSTALLED_APP"
            \\xattr -dr com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1 || true
            \\open "$INSTALLED_APP"
        , .{quoted_app});
        defer allocator.free(install_script);
        _ = try runProcess(allocator, &.{ "/bin/zsh", "-lc", install_script });
        return;
    }

    const quoted_exe = try shellQuote(allocator, exe_path);
    defer allocator.free(quoted_exe);

    if (!ax.isProcessTrusted()) {
        _ = ax.promptForAccessibility();
        const script =
            \\set -euo pipefail
            \\LOG_DIR="$HOME/Library/Logs"
            \\mkdir -p "$LOG_DIR"
            \\{
            \\  printf 'Panda needs Accessibility access for this installed app binary.\\n'
            \\  printf 'If Panda is already listed but still does not open, remove the old Panda entry and add /Applications/Panda.app again.\\n'
            \\} >>"$LOG_DIR/panda.err.log"
            \\open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true
        ;
        _ = try runProcess(allocator, &.{ "/bin/zsh", "-lc", script });
        return;
    }

    const script = try std.fmt.allocPrint(allocator,
        \\set -euo pipefail
        \\LOG_DIR="$HOME/Library/Logs"
        \\mkdir -p "$LOG_DIR"
        \\{0s} uninstall-daemon >/dev/null 2>&1 || true
        \\pkill -f '/Applications/Panda.app/Contents/MacOS/Panda daemon' >/dev/null 2>&1 || true
        \\pkill -f '/Applications/Panda.app/Contents/MacOS/panda-cli daemon' >/dev/null 2>&1 || true
        \\nohup {0s} daemon >>"$LOG_DIR/panda.log" 2>>"$LOG_DIR/panda.err.log" &
    , .{quoted_exe});
    defer allocator.free(script);

    _ = try runProcess(allocator, &.{ "/bin/zsh", "-lc", script });
}

fn appBundleRoot(exe_path: []const u8) ?[]const u8 {
    const marker = "/Contents/MacOS/";
    const index = std.mem.indexOf(u8, exe_path, marker) orelse return null;
    return exe_path[0..index];
}

fn isValidDesktopAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "next") or
        std.mem.eql(u8, action, "prev") or
        std.mem.eql(u8, action, "move-next") or
        std.mem.eql(u8, action, "move-prev") or
        std.mem.eql(u8, action, "status") or
        parseDesktopIndex(action) != null or
        parseDesktopMoveIndex(action) != null;
}

fn parseDesktopIndex(raw: []const u8) ?usize {
    const parsed = std.fmt.parseUnsigned(usize, raw, 10) catch return null;
    if (parsed < 1 or parsed > workspaces.workspace_count) return null;
    return parsed;
}

fn parseDesktopMoveIndex(raw: []const u8) ?usize {
    if (!std.mem.startsWith(u8, raw, "move-")) return null;
    return parseDesktopIndex(raw[5..]);
}

fn sendDaemonCommand(allocator: std.mem.Allocator, command: []const u8) !void {
    defer allocator.free(command);
    const response = events.sendControlCommand(allocator, command) catch |err| switch (err) {
        error.DaemonUnavailable => return error.DaemonUnavailable,
        else => return err,
    };
    defer allocator.free(response);
    std.debug.print("{s}", .{response});
    if (std.mem.startsWith(u8, response, "error:")) return error.DaemonCommandFailed;
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

fn runDoctor(allocator: std.mem.Allocator) !void {
    var failures: usize = 0;
    var warnings: usize = 0;

    std.debug.print("Panda doctor\n\n", .{});
    if (builtin.cpu.arch == .aarch64) {
        doctorLine("ok", "architecture", "Apple Silicon arm64");
    } else {
        doctorLine("fail", "architecture", "Panda releases require Apple Silicon arm64");
        failures += 1;
    }

    const displays = ax.displayCount();
    if (displays > 0) {
        var message_buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "{d} display{s} detected", .{ displays, if (displays == 1) "" else "s" }) catch "display detection succeeded";
        doctorLine("ok", "displays", message);
        if (ax.focusedApplicationPid() catch null) |pid| {
            if (ax.focusedWindowFrame(pid) catch null) |frame| {
                const target = ax.visibleFrameForRect(frame);
                var target_buffer: [160]u8 = undefined;
                const target_message = std.fmt.bufPrint(&target_buffer, "x={d:.0} y={d:.0} width={d:.0} height={d:.0}", .{ target.x, target.y, target.width, target.height }) catch "focused display detected";
                doctorLine("ok", "focused display", target_message);
            }
        }
    } else {
        doctorLine("fail", "displays", "macOS returned no active displays");
        failures += 1;
    }

    if (ax.isProcessTrusted()) {
        doctorLine("ok", "accessibility", "permission is enabled");
    } else {
        doctorLine("fail", "accessibility", "enable Panda in System Settings > Privacy & Security > Accessibility");
        failures += 1;
    }

    if (config.load(allocator)) |loaded_value| {
        var loaded = loaded_value;
        defer loaded.deinit(allocator);
        doctorLine("ok", "configuration", if (loaded.exists) loaded.path else "not present; defaults are valid");
    } else |err| {
        doctorLine("fail", "configuration", @errorName(err));
        failures += 1;
    }

    const app_path = "/Applications/Panda.app";
    const app_executable = app_path ++ "/Contents/MacOS/Panda";
    const info_plist = app_path ++ "/Contents/Info.plist";
    if (!isExecutableFile(app_executable)) {
        doctorLine("fail", "application", "/Applications/Panda.app is missing or not executable");
        failures += 1;
    } else {
        doctorLine("ok", "application", app_path);
        if (try readBundleVersion(allocator, info_plist)) |version| {
            defer allocator.free(version);
            doctorLine("ok", "version", version);
        } else {
            doctorLine("warn", "version", "CFBundleShortVersionString could not be read");
            warnings += 1;
        }

        if ((try runProcess(allocator, &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", app_path })) != null) {
            doctorLine("ok", "signature", "bundle signature is structurally valid");
        } else {
            doctorLine("fail", "signature", "codesign verification failed");
            failures += 1;
        }
    }

    const brew: ?[]const u8 = if (isExecutableFile("/opt/homebrew/bin/brew"))
        "/opt/homebrew/bin/brew"
    else if (isExecutableFile("/usr/local/bin/brew"))
        "/usr/local/bin/brew"
    else
        null;
    if (brew) |brew_path| {
        if ((try runProcess(allocator, &.{ brew_path, "list", "--cask", "panda-app" })) != null) {
            doctorLine("ok", "installation", "Homebrew cask");
        } else {
            doctorLine("ok", "installation", "direct installer");
        }
    } else {
        doctorLine("ok", "installation", "direct installer (Homebrew not installed)");
    }

    const service = try launchctlService(allocator);
    defer allocator.free(service);
    if ((try runProcess(allocator, &.{ "/bin/launchctl", "print", service })) != null) {
        doctorLine("ok", "daemon", "LaunchAgent is loaded");
    } else {
        doctorLine("fail", "daemon", "run `panda install-daemon`");
        failures += 1;
    }

    const error_log = try userPath(allocator, "Library/Logs/panda.err.log");
    defer allocator.free(error_log);
    if (std.fs.openFileAbsolute(error_log, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.size > 0) {
            doctorLine("warn", "error log", error_log);
            warnings += 1;
        } else {
            doctorLine("ok", "error log", "empty");
        }
    } else |_| {
        doctorLine("ok", "error log", "not created");
    }

    try doctorSummary(failures, warnings);
}

fn doctorLine(status: []const u8, name: []const u8, detail: []const u8) void {
    std.debug.print("[{s}] {s}: {s}\n", .{ status, name, detail });
}

fn doctorSummary(failures: usize, warnings: usize) !void {
    std.debug.print("\nsummary: {d} failure{s}, {d} warning{s}\n", .{ failures, if (failures == 1) "" else "s", warnings, if (warnings == 1) "" else "s" });
    if (failures != 0) return error.DoctorFailed;
}

fn readBundleVersion(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    const value = plistStringValue(bytes, "CFBundleShortVersionString") orelse return null;
    return try allocator.dupe(u8, value);
}

fn plistStringValue(bytes: []const u8, key_name: []const u8) ?[]const u8 {
    var key_buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "<key>{s}</key>", .{key_name}) catch return null;
    const key_index = std.mem.indexOf(u8, bytes, key) orelse return null;
    const tail = bytes[key_index + key.len ..];
    const start_marker = "<string>";
    const start = std.mem.indexOf(u8, tail, start_marker) orelse return null;
    const value_tail = tail[start + start_marker.len ..];
    const end = std.mem.indexOf(u8, value_tail, "</string>") orelse return null;
    return value_tail[0..end];
}

test "plist string extraction reads bundle version" {
    const plist = "<dict><key>CFBundleShortVersionString</key><string>0.1.0</string></dict>";
    try std.testing.expectEqualStrings("0.1.0", plistStringValue(plist, "CFBundleShortVersionString").?);
    try std.testing.expect(plistStringValue(plist, "Missing") == null);
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
    _ = runProcess(allocator, &.{ "/usr/bin/pkill", "-f", "/Applications/Panda.app/Contents/MacOS/Panda daemon" }) catch {};
    _ = runProcess(allocator, &.{ "/usr/bin/pkill", "-f", "/Applications/Panda.app/Contents/MacOS/panda-cli daemon" }) catch {};
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
    _ = runProcess(allocator, &.{ "/usr/bin/pkill", "-f", "/Applications/Panda.app/Contents/MacOS/Panda daemon" }) catch {};
    _ = runProcess(allocator, &.{ "/usr/bin/pkill", "-f", "/Applications/Panda.app/Contents/MacOS/panda-cli daemon" }) catch {};
    std.fs.deleteFileAbsolute(plist_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.debug.print("panda daemon uninstalled.\n", .{});
}

fn updateApp(allocator: std.mem.Allocator, force: bool) !void {
    const script =
        \\set -euo pipefail
        \\INSTALLER_URL="${PANDA_INSTALLER_URL:-https://givepanda.tech/install.sh}"
        \\TMP_DIR="$(mktemp -d)"
        \\trap 'rm -rf "$TMP_DIR"' EXIT
        \\cute() {
        \\  printf "\033[1;95mʕ•ᴥ•ʔ\033[0m %s\n" "$1"
        \\}
        \\cute "fetching Panda's verified installer..."
        \\curl -fsSL "$INSTALLER_URL" -o "$TMP_DIR/install.sh"
        \\chmod +x "$TMP_DIR/install.sh"
        \\INSTALL_METHOD=direct
        \\if command -v brew >/dev/null 2>&1 && brew list --cask panda-app >/dev/null 2>&1; then
        \\  INSTALL_METHOD=homebrew
        \\fi
        \\PANDA_INSTALL_METHOD="$INSTALL_METHOD" PANDA_FORCE_INSTALL="$1" "$TMP_DIR/install.sh"
    ;

    try runUpdateProcess(allocator, &.{ "/bin/zsh", "-f", "-c", script, "panda-update", if (force) "1" else "0" });
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
    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), suffix });
}

fn launchctlDomain(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "gui/{d}", .{std.c.getuid()});
}

fn launchctlService(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ std.c.getuid(), launch_agent_label });
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

fn runUpdateProcess(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.UpdateFailed;
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted = std.ArrayList(u8).empty;
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
    var escaped = std.ArrayList(u8).empty;
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

    const screen_bounds = if (ax.focusedWindowFrame(pid) catch null) |frame|
        ax.visibleFrameForRect(frame)
    else
        ax.mainDisplayVisibleFrame();
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
    return std.fmt.parseInt(T, value, 10) catch return error.InvalidArguments;
}

fn parseNextFloat(maybe_value: ?[]const u8) !f64 {
    const value = maybe_value orelse return error.InvalidArguments;
    return std.fmt.parseFloat(f64, value) catch return error.InvalidArguments;
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
        \\  panda reload
        \\  panda restart
        \\  panda hotkeys pause|resume
        \\  panda update [--force]
        \\  panda permissions
        \\  panda doctor
        \\  panda focus left|right|up|down
        \\  panda swap left|right|up|down
        \\  panda border on|off|toggle|status
        \\  panda desktop next|prev|move-next|move-prev|1..9|move-1..9|status
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
        \\         or brew trust --cask willsantiagomedina/tap/panda-app
        \\            brew install --cask willsantiagomedina/tap/panda-app
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
        \\Run `panda permissions`, then grant access to /Applications/Panda.app in System Settings > Privacy & Security > Accessibility.
        \\If Panda is already listed, remove that entry and add /Applications/Panda.app again.
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
        error.DaemonCommandFailed =>
        \\The panda daemon rejected the command.
        ,
        error.UpdateFailed =>
        \\Panda could not complete the verified update.
        \\The existing installation was left in place or restored. Review the preceding installer error and retry.
        ,
        error.DoctorFailed =>
        \\Panda doctor found one or more failures.
        \\Resolve the failed checks above, then run `panda doctor` again.
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
        "status",
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
