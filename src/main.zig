const std = @import("std");
const ax = @import("ax.zig");
const events = @import("events.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");

const log = std.log.scoped(.panda);

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse "help";

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
        => {
            try printCommandError(err);
            return;
        },
        else => return err,
    };
}

fn runCommand(command: []const u8, args: anytype, allocator: std.mem.Allocator) !void {
    try ax.ensureTrusted();

    if (std.mem.eql(u8, command, "list")) {
        const target = args.next() orelse return error.InvalidArguments;
        const pid = try ax.resolvePidForTarget(allocator, target);
        try listWindows(allocator, pid);
        return;
    }

    if (std.mem.eql(u8, command, "move")) {
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
        const target = args.next() orelse return error.InvalidArguments;
        const pid = try ax.resolvePidForTarget(allocator, target);
        const options = try parseRuntimeOptions(args, .focused_app);
        try tileWindows(allocator, pid, options);
        return;
    }

    if (std.mem.eql(u8, command, "apps")) {
        try listApps(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "active")) {
        try printActiveApp(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "daemon")) {
        const options = try parseRuntimeOptions(args, .all_apps_main_display);
        var loop = events.EventLoop.init(allocator, .{
            .scope = options.scope,
            .layout_options = .{
                .mode = options.layout_mode,
            },
            .border_enabled = true,
        });
        defer loop.deinit();
        try loop.run();
        return;
    }

    if (std.mem.eql(u8, command, "focus")) {
        const direction = args.next() orelse return error.InvalidArguments;
        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "focus {s}", .{direction}));
        return;
    }

    if (std.mem.eql(u8, command, "swap")) {
        const direction = args.next() orelse return error.InvalidArguments;
        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "swap {s}", .{direction}));
        return;
    }

    if (std.mem.eql(u8, command, "border")) {
        const mode = args.next() orelse return error.InvalidArguments;
        try sendDaemonCommand(allocator, try std.fmt.allocPrint(allocator, "border {s}", .{mode}));
        return;
    }

    return error.InvalidArguments;
}

fn sendDaemonCommand(allocator: std.mem.Allocator, command: []const u8) !void {
    defer allocator.free(command);
    const response = events.sendControlCommand(allocator, command) catch |err| switch (err) {
        error.DaemonUnavailable => {
            std.debug.print("panda daemon is not running.\nStart it first with `panda daemon`.\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(response);
    std.debug.print("{s}", .{response});
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

fn parseRuntimeOptions(args: anytype, default_scope: state.SpaceState.WindowScope) !RuntimeOptions {
    var options = RuntimeOptions{
        .scope = default_scope,
    };
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
        \\  panda focus left|right|up|down
        \\  panda swap left|right|up|down
        \\  panda border on|off|toggle|status
        \\
        \\Layouts:
        \\  bsp          - Binary space partition (like Hyprland/i3). Default.
        \\  grid         - Equal-sized grid of windows.
        \\  master-stack - Large master window with stack on right.
        \\
        \\Examples:
        \\  panda daemon                    # Auto-tile all tileable windows on the current display (default)
        \\  panda tile active               # Tile windows of the frontmost app
        \\  panda daemon --scope focused-app
        \\  panda daemon --scope all-main-display
        \\  panda focus right               # Focus the tiled window to the right
        \\  panda swap right                # Double-tap to swap with the previously focused window
        \\  panda border off                # Disable panda borders at runtime
        \\
        \\Install: curl -fsSL https://getpanda.dev/install.sh | bash
        \\         or brew install willsantiago/tap/panda
        \\
        \\skhd example:
        \\  cmd - left      : panda focus left
        \\  cmd - right     : panda focus right
        \\  cmd - up        : panda focus up
        \\  cmd - down      : panda focus down
        \\  cmd + shift - left  : panda swap left
        \\  cmd + shift - right : panda swap right
        \\  cmd + shift - up    : panda swap up
        \\  cmd + shift - down  : panda swap down
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
        \\Grant access in System Settings > Privacy & Security > Accessibility, then run the command again.
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
        error.DaemonUnavailable =>
        \\panda daemon is not running.
        \\Start it with `panda daemon`, then retry the runtime command.
        ,
        else => "panda failed.\n",
    };

    std.debug.print("{s}\n", .{message});
}
