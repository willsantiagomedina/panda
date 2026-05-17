const std = @import("std");
const ax = @import("ax.zig");
const hotkeys = @import("hotkeys.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");

const log = std.log.scoped(.events);

pub const PerformanceOptions = struct {
    focus_poll_interval_seconds: f64 = 0.08,
    fallback_snapshot_poll_interval_seconds: f64 = 0.75,
    observer_backstop_snapshot_poll_interval_seconds: f64 = 0.20,
    control_poll_interval_seconds: f64 = 0.02,
    immediate_relayout_delay_seconds: f64 = 0.01,
    burst_relayout_delay_seconds: f64 = 0.04,
    burst_window_seconds: f64 = 0.12,
    min_relayout_interval_seconds: f64 = 0.03,
    self_event_suppression_window_seconds: f64 = 0.20,
    swap_double_tap_window_seconds: f64 = 0.35,
};

const max_command_length = 128;
const max_hotkey_events_per_tick = 32;

pub const CommandError = error{
    DaemonUnavailable,
    InvalidCommand,
};

pub fn controlSocketPath(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/panda-{d}.sock", .{std.posix.getuid()});
}

pub fn sendControlCommand(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const socket_path = try controlSocketPath(allocator);
    defer allocator.free(socket_path);

    var stream = std.net.connectUnixSocket(socket_path) catch return CommandError.DaemonUnavailable;
    defer stream.close();

    _ = try std.posix.write(stream.handle, command);
    _ = try std.posix.write(stream.handle, "\n");

    var response = std.ArrayList(u8){};
    defer response.deinit(allocator);

    var buffer: [256]u8 = undefined;
    while (true) {
        const read = stream.read(&buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (read == 0) break;
        try response.appendSlice(allocator, buffer[0..read]);
    }

    if (response.items.len == 0) {
        return allocator.dupe(u8, "daemon did not respond\n");
    }

    return response.toOwnedSlice(allocator);
}

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    options: Options = .{},
    run_loop: ?ax.c.CFRunLoopRef = null,
    focus_timer: ?ax.c.CFRunLoopTimerRef = null,
    relayout_timer: ?ax.c.CFRunLoopTimerRef = null,
    command_timer: ?ax.c.CFRunLoopTimerRef = null,
    current_pid: ?i32 = null,
    current_observer: ?ax.c.AXObserverRef = null,
    current_app: ?ax.c.AXUIElementRef = null,
    current_space: ?state.SpaceState = null,
    current_layout: std.ArrayList(layout.Placement) = .empty,
    current_screen: state.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    focused_window_id: ?u64 = null,
    previous_focused_window_id: ?u64 = null,
    last_navigation: ?NavigationRecord = null,
    last_snapshot: WindowSnapshot = .{},
    notifications_enabled: bool = false,
    relayout_pending: bool = false,
    border_enabled: bool = true,
    control_socket_fd: ?std.posix.socket_t = null,
    control_socket_path: ?[]u8 = null,
    order_overrides: std.AutoHashMap(i32, []u64),
    last_snapshot_poll_at: f64 = 0,
    last_observed_change_at: f64 = 0,
    last_relayout_at: f64 = 0,
    suppress_hotkey_action: ?hotkeys.HotkeyAction = null,
    suppress_hotkeys_until: f64 = 0,

    pub const Options = struct {
        scope: state.SpaceState.WindowScope = .focused_app,
        layout_options: layout.LayoutOptions = .{},
        border_enabled: bool = true,
        performance: PerformanceOptions = .{},
        hotkeys: []const hotkeys.HotkeyBinding = &.{},
        desktop: hotkeys.DesktopBindings = .{},
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) EventLoop {
        return .{
            .allocator = allocator,
            .options = options,
            .border_enabled = options.border_enabled,
            .order_overrides = std.AutoHashMap(i32, []u64).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.clearCurrentSpace();
        self.current_layout.deinit(self.allocator);
        self.freeOrderOverrides();
        ax.c.pandaClearBorders();
        ax.c.pandaClearHotkeys();

        if (self.command_timer) |timer| {
            self.removeTimer(timer);
            self.command_timer = null;
        }
        if (self.focus_timer) |timer| {
            self.removeTimer(timer);
            self.focus_timer = null;
        }
        if (self.relayout_timer) |timer| {
            self.removeTimer(timer);
            self.relayout_timer = null;
        }

        self.teardownObserver();
        self.teardownControlSocket();
    }

    pub fn run(self: *EventLoop) !void {
        log.info("starting panda daemon event loop", .{});

        ax.c.pandaEnsureAppKitReady();

        self.run_loop = ax.c.CFRunLoopGetCurrent();
        try self.installFocusTimer();
        try self.installRelayoutTimer();
        try self.installCommandTimer();
        try self.setupControlSocket();
        self.installHotkeys();
        try self.reconcileFocusedApp();

        ax.c.CFRunLoopRun();
    }

    fn installFocusTimer(self: *EventLoop) !void {
        self.focus_timer = try self.createTimer(
            self.options.performance.focus_poll_interval_seconds,
            self.options.performance.focus_poll_interval_seconds,
            focusTimerCallback,
        );
    }

    fn installRelayoutTimer(self: *EventLoop) !void {
        self.relayout_timer = try self.createTimer(
            60.0 * 60.0 * 24.0 * 365.0,
            0,
            relayoutTimerCallback,
        );
    }

    fn installCommandTimer(self: *EventLoop) !void {
        self.command_timer = try self.createTimer(
            self.options.performance.control_poll_interval_seconds,
            self.options.performance.control_poll_interval_seconds,
            commandTimerCallback,
        );
    }

    fn installHotkeys(self: *EventLoop) void {
        ax.c.pandaHotkeysInitialize();
        ax.c.pandaClearHotkeys();

        if (self.options.hotkeys.len == 0) {
            return;
        }

        for (self.options.hotkeys) |binding| {
            if (!ax.c.pandaRegisterHotkey(binding.id, binding.chord.key_code, binding.chord.modifiers)) {
                log.warn("failed to register hotkey {d} ({s})", .{ binding.id, @tagName(binding.action) });
            } else {
                log.info("registered hotkey {d} ({s})", .{ binding.id, @tagName(binding.action) });
            }
        }
    }

    fn createTimer(
        self: *EventLoop,
        start_after_seconds: f64,
        interval_seconds: f64,
        callback: ax.c.CFRunLoopTimerCallBack,
    ) !ax.c.CFRunLoopTimerRef {
        const context = ax.c.CFRunLoopTimerContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        const timer = ax.c.CFRunLoopTimerCreate(
            ax.c.kCFAllocatorDefault,
            ax.c.CFAbsoluteTimeGetCurrent() + start_after_seconds,
            interval_seconds,
            0,
            0,
            callback,
            @constCast(&context),
        ) orelse return error.UnexpectedAxError;

        ax.c.CFRunLoopAddTimer(self.run_loop.?, timer, ax.c.kCFRunLoopDefaultMode);
        return timer;
    }

    fn removeTimer(self: *EventLoop, timer: ax.c.CFRunLoopTimerRef) void {
        if (self.run_loop) |run_loop| {
            ax.c.CFRunLoopRemoveTimer(run_loop, timer, ax.c.kCFRunLoopDefaultMode);
        }
        ax.c.CFRunLoopTimerInvalidate(timer);
        ax.c.CFRelease(timer);
    }

    fn reconcileFocusedApp(self: *EventLoop) !void {
        const pid = ax.focusedApplicationPid() catch |err| switch (err) {
            error.AccessibilityDenied => return err,
            error.AppNotFound,
            error.AppUnresponsive,
            error.InvalidPid,
            error.UnsupportedTarget,
            error.UnexpectedAxError,
            => {
                self.resetCurrentApp();
                return;
            },
            else => return err,
        };

        if (self.current_pid == null or self.current_pid.? != pid) {
            try self.attachToPid(pid);
            try self.logFocusChange(pid);
            try self.relayoutPid(pid);
            return;
        }

        self.syncFocusedWindowState(pid);

        const snapshot_poll_interval: f64 = if (!self.notifications_enabled or
            self.options.scope == .all_apps_main_display)
            self.options.performance.fallback_snapshot_poll_interval_seconds
        else
            self.options.performance.observer_backstop_snapshot_poll_interval_seconds;

        const now = ax.c.CFAbsoluteTimeGetCurrent();
        if ((now - self.last_snapshot_poll_at) >= snapshot_poll_interval) {
            self.last_snapshot_poll_at = now;
            try self.refreshSnapshotIfNeeded(pid);
        }
    }

    fn attachToPid(self: *EventLoop, pid: i32) !void {
        self.teardownObserver();
        self.focused_window_id = null;
        self.previous_focused_window_id = null;
        self.last_navigation = null;

        const app = try ax.createApplication(pid);
        errdefer ax.c.CFRelease(app);

        const observer = ax.createObserver(pid, notificationCallback) catch |err| switch (err) {
            error.UnsupportedTarget,
            error.InvalidPid,
            => {
                self.current_pid = pid;
                self.current_app = app;
                self.current_observer = null;
                self.notifications_enabled = false;
                self.relayout_pending = false;
                self.last_snapshot = .{};
                self.last_snapshot_poll_at = 0;
                self.last_observed_change_at = 0;
                return;
            },
            else => return err,
        };
        errdefer ax.c.CFRelease(observer);

        const source = ax.c.AXObserverGetRunLoopSource(observer);
        ax.c.CFRunLoopAddSource(self.run_loop.?, source, ax.c.kCFRunLoopDefaultMode);

        self.current_pid = pid;
        self.current_app = app;
        self.current_observer = observer;
        self.notifications_enabled = false;

        var registered_any = false;
        inline for ([_][]const u8{
            "AXWindowCreated",
            "AXUIElementDestroyed",
            "AXMoved",
            "AXResized",
            "AXMainWindowChanged",
            "AXFocusedWindowChanged",
        }) |notification_name| {
            if (registerNotification(observer, app, notification_name, self)) {
                registered_any = true;
            }
        }

        self.notifications_enabled = registered_any;
        self.relayout_pending = false;
        self.last_snapshot = .{};
        self.last_snapshot_poll_at = 0;
        self.last_observed_change_at = 0;
    }

    fn refreshSnapshotIfNeeded(self: *EventLoop, pid: i32) !void {
        const snapshot = self.captureSnapshot(pid) catch |err| switch (err) {
            error.AppUnresponsive,
            error.AttributeUnsupported,
            error.InvalidPid,
            error.UnsupportedTarget,
            error.UnexpectedAxError,
            => return,
            else => return err,
        };

        if (!snapshot.eql(self.last_snapshot)) {
            try self.relayoutPid(pid);
        }
    }

    fn relayoutPid(self: *EventLoop, pid: i32) !void {
        var space = state.SpaceState.init(self.allocator);
        errdefer space.deinit();

        const screen_bounds = ax.mainDisplayVisibleFrame();
        const screen = state.Rect{
            .x = screen_bounds.x,
            .y = screen_bounds.y,
            .width = screen_bounds.width,
            .height = screen_bounds.height,
        };

        space.loadWindowsForScope(self.options.scope, pid, screen) catch |err| switch (err) {
            error.AppUnresponsive,
            error.AttributeUnsupported,
            error.InvalidPid,
            error.UnsupportedTarget,
            error.UnexpectedAxError,
            => {
                self.last_snapshot = .{};
                self.clearCurrentSpace();
                self.current_layout.clearRetainingCapacity();
                self.syncBorders();
                return;
            },
            else => return err,
        };

        if (space.window_order.items.len == 0) {
            self.last_snapshot = .{};
            self.clearCurrentSpace();
            self.current_layout.clearRetainingCapacity();
            self.syncBorders();
            return;
        }

        var active_order = std.ArrayList(u64){};
        defer active_order.deinit(self.allocator);
        try active_order.appendSlice(self.allocator, space.window_order.items);

        if (self.order_overrides.get(pid)) |override| {
            var filtered = std.ArrayList(u64){};
            defer filtered.deinit(self.allocator);
            for (override) |window_id| {
                if (containsWindowId(active_order.items, window_id)) {
                    try filtered.append(self.allocator, window_id);
                }
            }
            for (active_order.items) |window_id| {
                if (!containsWindowId(filtered.items, window_id)) {
                    try filtered.append(self.allocator, window_id);
                }
            }
            @memcpy(active_order.items, filtered.items);
        } else if (self.current_pid == pid) {
            if (self.current_space) |*current| {
                var filtered = std.ArrayList(u64){};
                defer filtered.deinit(self.allocator);
                for (current.window_order.items) |window_id| {
                    if (containsWindowId(active_order.items, window_id)) {
                        try filtered.append(self.allocator, window_id);
                    }
                }
                for (active_order.items) |window_id| {
                    if (!containsWindowId(filtered.items, window_id)) {
                        try filtered.append(self.allocator, window_id);
                    }
                }
                @memcpy(active_order.items, filtered.items);
            }
        }

        space.window_order.clearRetainingCapacity();
        try space.window_order.appendSlice(self.allocator, active_order.items);
        try space.rebuildLinearTree();

        const placements = try layout.computePlacements(self.allocator, &space, screen, self.options.layout_options);
        defer self.allocator.free(placements);

        layout.applyPlacements(&space, placements) catch |err| switch (err) {
            error.AppUnresponsive,
            error.AttributeUnsupported,
            error.InvalidPid,
            error.UnsupportedTarget,
            error.UnexpectedAxError,
            error.ConversionFailed,
            => return,
            else => return err,
        };

        try self.replaceCurrentSpace(space, screen, placements);
        self.last_snapshot = snapshotForWindowIds(self.current_space.?.window_order.items);
        self.last_relayout_at = ax.c.CFAbsoluteTimeGetCurrent();
        self.syncFocusedWindowState(pid);
        self.ensureActiveWorkspaceFocus() catch {};
    }

    fn replaceCurrentSpace(
        self: *EventLoop,
        new_space: state.SpaceState,
        screen: state.Rect,
        placements: []const layout.Placement,
    ) !void {
        self.clearCurrentSpace();
        self.current_space = new_space;
        self.current_screen = screen;
        self.current_layout.clearRetainingCapacity();
        try self.current_layout.appendSlice(self.allocator, placements);
        self.syncBorders();
    }

    fn clearCurrentSpace(self: *EventLoop) void {
        if (self.current_space) |*space| {
            space.deinit();
            self.current_space = null;
        }
    }

    fn handleObservedChange(self: *EventLoop, kind: NotificationKind) void {
        const now = ax.c.CFAbsoluteTimeGetCurrent();
        if (kind != .focus and
            (now - self.last_relayout_at) <= self.options.performance.self_event_suppression_window_seconds)
        {
            return;
        }

        if (kind == .focus) {
            if (self.current_pid) |pid| self.syncFocusedWindowState(pid);
            return;
        }

        const since_last_relayout = now - self.last_relayout_at;
        const since_last_event = now - self.last_observed_change_at;
        self.last_observed_change_at = now;

        const delay: f64 = if (self.relayout_pending or
            since_last_event <= self.options.performance.burst_window_seconds or
            since_last_relayout < self.options.performance.min_relayout_interval_seconds)
            self.options.performance.burst_relayout_delay_seconds
        else
            self.options.performance.immediate_relayout_delay_seconds;

        self.scheduleRelayout(delay);
    }

    fn scheduleRelayout(self: *EventLoop, delay_seconds: f64) void {
        const timer = self.relayout_timer orelse return;
        self.relayout_pending = true;
        ax.c.CFRunLoopTimerSetNextFireDate(timer, ax.c.CFAbsoluteTimeGetCurrent() + delay_seconds);
    }

    fn flushScheduledRelayout(self: *EventLoop) void {
        if (!self.relayout_pending) return;
        self.relayout_pending = false;

        const pid = self.current_pid orelse return;
        self.relayoutPid(pid) catch |err| switch (err) {
            error.AppUnresponsive,
            error.AttributeUnsupported,
            error.InvalidPid,
            error.UnsupportedTarget,
            error.UnexpectedAxError,
            => return,
            else => log.err("relayout failed: {s}", .{@errorName(err)}),
        };
    }

    fn syncFocusedWindowState(self: *EventLoop, pid: i32) void {
        const maybe_id = ax.focusedWindowId(pid) catch return;
        const focused_id = maybe_id orelse return;
        if (!self.hasPlacement(focused_id)) return;
        if (self.focused_window_id != null and self.focused_window_id.? != focused_id) {
            self.previous_focused_window_id = self.focused_window_id;
        }
        self.focused_window_id = focused_id;
    }

    fn hasPlacement(self: *const EventLoop, window_id: u64) bool {
        for (self.current_layout.items) |placement| {
            if (placement.window_id == window_id) return true;
        }
        return false;
    }

    fn captureSnapshot(self: *EventLoop, pid: i32) !WindowSnapshot {
        var space = state.SpaceState.init(self.allocator);
        defer space.deinit();

        const screen_bounds = ax.mainDisplayVisibleFrame();
        const screen = state.Rect{
            .x = screen_bounds.x,
            .y = screen_bounds.y,
            .width = screen_bounds.width,
            .height = screen_bounds.height,
        };

        try space.loadWindowsForScope(self.options.scope, pid, screen);
        return snapshotForWindowIds(space.window_order.items);
    }

    fn setupControlSocket(self: *EventLoop) !void {
        const socket_path = try controlSocketPath(self.allocator);
        errdefer self.allocator.free(socket_path);

        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const listener = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(listener);

        var address = try std.net.Address.initUnix(socket_path);
        try std.posix.bind(listener, &address.any, address.getOsSockLen());
        try std.posix.listen(listener, 8);

        self.control_socket_fd = listener;
        self.control_socket_path = socket_path;
    }

    fn teardownControlSocket(self: *EventLoop) void {
        if (self.control_socket_fd) |fd| {
            std.posix.close(fd);
            self.control_socket_fd = null;
        }
        if (self.control_socket_path) |path| {
            std.fs.deleteFileAbsolute(path) catch {};
            self.allocator.free(path);
            self.control_socket_path = null;
        }
    }

    fn pollControlSocket(self: *EventLoop) void {
        const listener = self.control_socket_fd orelse return;

        while (true) {
            const client = std.posix.accept(listener, null, null, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.err("control accept failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            self.handleClient(client);
        }
    }

    fn pollHotkeys(self: *EventLoop) void {
        if (self.options.hotkeys.len == 0) return;

        var ids: [max_hotkey_events_per_tick]u32 = undefined;
        while (true) {
            const count = ax.c.pandaDrainHotkeys(&ids[0], @intCast(ids.len));
            if (count <= 0) return;

            for (ids[0..@intCast(count)]) |hotkey_id| {
                self.handleHotkeyTrigger(hotkey_id);
            }
        }
    }

    fn handleHotkeyTrigger(self: *EventLoop, hotkey_id: u32) void {
        for (self.options.hotkeys) |binding| {
            if (binding.id != hotkey_id) continue;

            const now = ax.c.CFAbsoluteTimeGetCurrent();
            if (self.suppress_hotkey_action != null and
                self.suppress_hotkey_action.? == binding.action and
                now <= self.suppress_hotkeys_until)
            {
                self.suppress_hotkey_action = null;
                return;
            }

            self.runHotkeyAction(binding.action) catch |err| {
                log.warn("hotkey action failed ({s}): {s}", .{ @tagName(binding.action), @errorName(err) });
            };
            return;
        }
    }

    fn runHotkeyAction(self: *EventLoop, action: hotkeys.HotkeyAction) !void {
        switch (action) {
            .focus_left => try self.focusDirection(.left, false),
            .focus_right => try self.focusDirection(.right, false),
            .focus_up => try self.focusDirection(.up, false),
            .focus_down => try self.focusDirection(.down, false),
            .swap_left => try self.swapDirection(.left),
            .swap_right => try self.swapDirection(.right),
            .swap_up => try self.swapDirection(.up),
            .swap_down => try self.swapDirection(.down),
            .border_toggle => {
                self.border_enabled = !self.border_enabled;
                ax.c.pandaSetBordersVisible(self.border_enabled);
                if (self.border_enabled) {
                    self.syncBorders();
                }
            },
            .desktop_next => try self.performDesktopCommand(.next),
            .desktop_prev => try self.performDesktopCommand(.prev),
            .desktop_move_next => try self.performDesktopCommand(.move_next),
            .desktop_move_prev => try self.performDesktopCommand(.move_prev),
            .desktop_1 => try self.performDesktopCommand(.{ .switch_to = 1 }),
            .desktop_2 => try self.performDesktopCommand(.{ .switch_to = 2 }),
            .desktop_3 => try self.performDesktopCommand(.{ .switch_to = 3 }),
            .desktop_4 => try self.performDesktopCommand(.{ .switch_to = 4 }),
            .desktop_5 => try self.performDesktopCommand(.{ .switch_to = 5 }),
            .desktop_6 => try self.performDesktopCommand(.{ .switch_to = 6 }),
            .desktop_7 => try self.performDesktopCommand(.{ .switch_to = 7 }),
            .desktop_8 => try self.performDesktopCommand(.{ .switch_to = 8 }),
            .desktop_9 => try self.performDesktopCommand(.{ .switch_to = 9 }),
            .desktop_move_1 => try self.performDesktopCommand(.{ .move_to = 1 }),
            .desktop_move_2 => try self.performDesktopCommand(.{ .move_to = 2 }),
            .desktop_move_3 => try self.performDesktopCommand(.{ .move_to = 3 }),
            .desktop_move_4 => try self.performDesktopCommand(.{ .move_to = 4 }),
            .desktop_move_5 => try self.performDesktopCommand(.{ .move_to = 5 }),
            .desktop_move_6 => try self.performDesktopCommand(.{ .move_to = 6 }),
            .desktop_move_7 => try self.performDesktopCommand(.{ .move_to = 7 }),
            .desktop_move_8 => try self.performDesktopCommand(.{ .move_to = 8 }),
            .desktop_move_9 => try self.performDesktopCommand(.{ .move_to = 9 }),
        }
    }

    fn performDesktopCommand(self: *EventLoop, command: DesktopCommand) !void {
        const command_to_send = resolveDesktopCommand(command) orelse command;
        const chord = desktopChordForCommand(self.options.desktop, command_to_send) orelse return;
        self.suppress_hotkey_action = hotkeyActionForDesktopCommand(command_to_send);
        self.suppress_hotkeys_until = ax.c.CFAbsoluteTimeGetCurrent() + 0.25;
        if (!ax.postKeyChord(chord.key_code, chord.modifiers)) return error.UnexpectedAxError;
        self.last_snapshot_poll_at = 0;
    }

    fn ensureActiveWorkspaceFocus(self: *EventLoop) !void {
        if (self.focused_window_id) |focused| {
            if (self.hasPlacement(focused)) return;
        }

        const first = if (self.current_layout.items.len == 0)
            return
        else
            self.current_layout.items[0].window_id;

        try self.focusManagedWindow(first);
        self.focused_window_id = first;
        self.previous_focused_window_id = null;
        self.last_navigation = null;
    }

    fn handleClient(self: *EventLoop, client: std.posix.socket_t) void {
        defer std.posix.close(client);

        var buffer: [max_command_length]u8 = undefined;
        const read = std.posix.read(client, &buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                _ = std.posix.write(client, "error: failed to read command\n") catch {};
                log.err("control read failed: {s}", .{@errorName(err)});
                return;
            },
        };
        if (read == 0) return;

        const raw = std.mem.trim(u8, buffer[0..read], " \t\r\n");
        if (raw.len == 0) return;

        const response = self.executeControlCommand(raw) catch |err| switch (err) {
            CommandError.InvalidCommand => "error: invalid command\n",
            else => "error: command failed\n",
        };
        _ = std.posix.write(client, response) catch {};
    }

    fn executeControlCommand(self: *EventLoop, raw: []const u8) ![]const u8 {
        var parts = std.mem.tokenizeScalar(u8, raw, ' ');
        const verb = parts.next() orelse return CommandError.InvalidCommand;

        if (std.mem.eql(u8, verb, "focus")) {
            const direction = parseDirection(parts.next() orelse return CommandError.InvalidCommand) orelse return CommandError.InvalidCommand;
            try self.focusDirection(direction, false);
            return "ok\n";
        }

        if (std.mem.eql(u8, verb, "swap")) {
            const direction = parseDirection(parts.next() orelse return CommandError.InvalidCommand) orelse return CommandError.InvalidCommand;
            try self.swapDirection(direction);
            return "ok\n";
        }

        if (std.mem.eql(u8, verb, "border")) {
            const mode = parts.next() orelse return CommandError.InvalidCommand;
            if (std.mem.eql(u8, mode, "on")) {
                self.border_enabled = true;
                ax.c.pandaSetBordersVisible(true);
                self.syncBorders();
                return "borders: on\n";
            }
            if (std.mem.eql(u8, mode, "off")) {
                self.border_enabled = false;
                ax.c.pandaSetBordersVisible(false);
                return "borders: off\n";
            }
            if (std.mem.eql(u8, mode, "toggle")) {
                self.border_enabled = !self.border_enabled;
                ax.c.pandaSetBordersVisible(self.border_enabled);
                if (self.border_enabled) self.syncBorders();
                return if (self.border_enabled) "borders: on\n" else "borders: off\n";
            }
            if (std.mem.eql(u8, mode, "status")) {
                return if (self.border_enabled) "borders: on\n" else "borders: off\n";
            }
            return CommandError.InvalidCommand;
        }

        if (std.mem.eql(u8, verb, "desktop")) {
            const action = parts.next() orelse return CommandError.InvalidCommand;
            if (parts.next() != null) return CommandError.InvalidCommand;
            const desktop_command = parseDesktopCommand(action) orelse return CommandError.InvalidCommand;
            try self.performDesktopCommand(desktop_command);
            return "ok\n";
        }

        return CommandError.InvalidCommand;
    }

    fn focusDirection(self: *EventLoop, direction: ax.Direction, arm_swap: bool) !void {
        if (self.current_layout.items.len == 0) return;

        const source_id = self.focused_window_id orelse self.current_layout.items[0].window_id;
        const target_id = self.findDirectionalNeighbor(source_id, direction) orelse return;
        if (target_id == source_id) return;

        try self.focusManagedWindow(target_id);

        self.previous_focused_window_id = source_id;
        self.focused_window_id = target_id;
        self.last_navigation = .{
            .from = source_id,
            .to = target_id,
            .direction = direction,
            .at = ax.c.CFAbsoluteTimeGetCurrent(),
            .armed_by_swap = arm_swap,
        };
    }

    fn swapDirection(self: *EventLoop, direction: ax.Direction) !void {
        const pid = self.current_pid orelse return;
        const focused_id = self.focused_window_id orelse if (self.current_layout.items.len != 0)
            self.current_layout.items[0].window_id
        else
            return;

        if (self.last_navigation) |navigation| {
            const now = ax.c.CFAbsoluteTimeGetCurrent();
            if (navigation.armed_by_swap and
                navigation.direction == direction and
                navigation.to == focused_id and
                (now - navigation.at) <= self.options.performance.swap_double_tap_window_seconds)
            {
                try self.swapWindowOrder(pid, navigation.from, navigation.to);
                self.last_navigation = null;
                try self.relayoutPid(pid);
                try self.focusManagedWindow(navigation.to);
                self.focused_window_id = navigation.to;
                self.previous_focused_window_id = navigation.from;
                return;
            }
        }

        try self.focusDirection(direction, true);
    }

    fn swapWindowOrder(self: *EventLoop, pid: i32, first: u64, second: u64) !void {
        const current = self.current_space orelse return;
        var reordered = try self.allocator.dupe(u64, current.window_order.items);
        errdefer self.allocator.free(reordered);

        const first_index = indexOfWindowId(reordered, first) orelse return;
        const second_index = indexOfWindowId(reordered, second) orelse return;
        std.mem.swap(u64, &reordered[first_index], &reordered[second_index]);

        if (self.order_overrides.fetchRemove(pid)) |entry| {
            self.allocator.free(entry.value);
        }
        try self.order_overrides.put(pid, reordered);
    }

    fn focusManagedWindow(self: *EventLoop, window_id: u64) !void {
        const current = self.current_space orelse return;
        const window = current.windows.get(window_id) orelse return;
        try ax.focusWindow(window.element);
    }

    fn findDirectionalNeighbor(self: *const EventLoop, source_id: u64, direction: ax.Direction) ?u64 {
        const source = placementForWindow(self.current_layout.items, source_id) orelse return null;
        const source_center = rectCenter(source.frame);

        var best_id: ?u64 = null;
        var best_overlap: f64 = -1;
        var best_primary = std.math.inf(f64);
        var best_secondary = std.math.inf(f64);

        for (self.current_layout.items) |candidate| {
            if (candidate.window_id == source_id) continue;

            const candidate_center = rectCenter(candidate.frame);
            const delta_x = candidate_center.x - source_center.x;
            const delta_y = candidate_center.y - source_center.y;

            const primary: f64 = switch (direction) {
                .left => if (delta_x < -1) -delta_x else continue,
                .right => if (delta_x > 1) delta_x else continue,
                .up => if (delta_y < -1) -delta_y else continue,
                .down => if (delta_y > 1) delta_y else continue,
            };

            const secondary = switch (direction) {
                .left, .right => @abs(delta_y),
                .up, .down => @abs(delta_x),
            };

            const overlap = switch (direction) {
                .left, .right => intervalOverlap(source.frame.y, source.frame.y + source.frame.height, candidate.frame.y, candidate.frame.y + candidate.frame.height),
                .up, .down => intervalOverlap(source.frame.x, source.frame.x + source.frame.width, candidate.frame.x, candidate.frame.x + candidate.frame.width),
            };

            if (overlap > best_overlap + 0.5 or
                (almostEqual(overlap, best_overlap) and primary < best_primary - 0.5) or
                (almostEqual(overlap, best_overlap) and almostEqual(primary, best_primary) and secondary < best_secondary))
            {
                best_id = candidate.window_id;
                best_overlap = overlap;
                best_primary = primary;
                best_secondary = secondary;
            }
        }

        return best_id;
    }

    fn syncBorders(self: *EventLoop) void {
        if (!self.border_enabled) {
            ax.c.pandaSetBordersVisible(false);
            return;
        }

        if (self.current_layout.items.len == 0) {
            ax.c.pandaClearBorders();
            return;
        }

        var frames = self.allocator.alloc(ax.c.PandaBorderFrame, self.current_layout.items.len) catch return;
        defer self.allocator.free(frames);

        for (self.current_layout.items, 0..) |placement, index| {
            frames[index] = .{
                .window_id = @intCast(placement.window_id),
                .is_active = self.focused_window_id != null and placement.window_id == self.focused_window_id.?,
            };
        }

        ax.c.pandaSetBordersVisible(true);
        ax.c.pandaSyncBorders(frames.ptr, @intCast(frames.len));
    }

    fn resetCurrentApp(self: *EventLoop) void {
        self.teardownObserver();
        self.current_pid = null;
        self.last_snapshot = .{};
        self.last_snapshot_poll_at = 0;
        self.clearCurrentSpace();
        self.current_layout.clearRetainingCapacity();
        self.syncBorders();
    }

    fn teardownObserver(self: *EventLoop) void {
        if (self.current_observer) |observer| {
            if (self.run_loop) |run_loop| {
                const source = ax.c.AXObserverGetRunLoopSource(observer);
                ax.c.CFRunLoopRemoveSource(run_loop, source, ax.c.kCFRunLoopDefaultMode);
            }
            ax.c.CFRelease(observer);
            self.current_observer = null;
        }

        if (self.current_app) |app| {
            ax.c.CFRelease(app);
            self.current_app = null;
        }

        self.notifications_enabled = false;
        self.relayout_pending = false;
        self.last_observed_change_at = 0;
    }

    fn freeOrderOverrides(self: *EventLoop) void {
        var iterator = self.order_overrides.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.order_overrides.deinit();
    }

    fn logFocusChange(self: *EventLoop, pid: i32) !void {
        var app = ax.describeRunningApp(self.allocator, pid) catch |err| switch (err) {
            error.AppNotFound => {
                log.info("frontmost app changed to pid {d}", .{pid});
                return;
            },
            else => return err,
        };
        defer app.deinit(self.allocator);

        if (self.notifications_enabled) {
            log.info("frontmost app changed to {s} (pid {d}); observer attached", .{ app.name, pid });
        } else {
            log.info("frontmost app changed to {s} (pid {d}); using snapshot fallback", .{ app.name, pid });
        }
    }
};

const NavigationRecord = struct {
    from: u64,
    to: u64,
    direction: ax.Direction,
    at: f64,
    armed_by_swap: bool,
};

const WindowSnapshot = struct {
    count: usize = 0,
    digest: u64 = 0,

    fn eql(self: WindowSnapshot, other: WindowSnapshot) bool {
        return self.count == other.count and self.digest == other.digest;
    }
};

const NotificationKind = enum {
    focus,
    geometry,
};

const DesktopCommand = union(enum) {
    next,
    prev,
    move_next,
    move_prev,
    switch_to: usize,
    move_to: usize,
};

fn focusTimerCallback(_: ax.c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const loop: *EventLoop = @ptrCast(@alignCast(info orelse return));
    loop.reconcileFocusedApp() catch |err| switch (err) {
        error.AccessibilityDenied => log.err("accessibility permission was revoked while daemon was running", .{}),
        else => log.err("focus reconciliation failed: {s}", .{@errorName(err)}),
    };
}

fn relayoutTimerCallback(_: ax.c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const loop: *EventLoop = @ptrCast(@alignCast(info orelse return));
    loop.flushScheduledRelayout();
}

fn commandTimerCallback(_: ax.c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const loop: *EventLoop = @ptrCast(@alignCast(info orelse return));
    loop.pollControlSocket();
    loop.pollHotkeys();
}

fn notificationCallback(
    _: ax.c.AXObserverRef,
    _: ax.c.AXUIElementRef,
    notification: ax.c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void {
    const loop: *EventLoop = @ptrCast(@alignCast(refcon orelse return));
    const kind: NotificationKind = if (ax.cfStringEquals(notification, "AXFocusedWindowChanged") or
        ax.cfStringEquals(notification, "AXMainWindowChanged"))
        .focus
    else
        .geometry;
    loop.handleObservedChange(kind);
}

fn registerNotification(
    observer: ax.c.AXObserverRef,
    app: ax.c.AXUIElementRef,
    notification_name: []const u8,
    loop: *EventLoop,
) bool {
    ax.addObserverNotification(observer, app, notification_name, loop) catch |err| switch (err) {
        error.UnsupportedTarget => return false,
        else => {
            log.err("failed to register {s}: {s}", .{ notification_name, @errorName(err) });
            return false;
        },
    };
    return true;
}

fn parseDirection(raw: []const u8) ?ax.Direction {
    if (std.mem.eql(u8, raw, "left")) return .left;
    if (std.mem.eql(u8, raw, "right")) return .right;
    if (std.mem.eql(u8, raw, "up")) return .up;
    if (std.mem.eql(u8, raw, "down")) return .down;
    return null;
}

fn parseDesktopCommand(action: []const u8) ?DesktopCommand {
    if (std.mem.eql(u8, action, "next")) return .next;
    if (std.mem.eql(u8, action, "prev")) return .prev;
    if (std.mem.eql(u8, action, "move-next")) return .move_next;
    if (std.mem.eql(u8, action, "move-prev")) return .move_prev;
    if (parseDesktopIndex(action)) |index| return .{ .switch_to = index };
    if (parseDesktopMoveIndex(action)) |index| return .{ .move_to = index };
    return null;
}

fn parseDesktopIndex(raw: []const u8) ?usize {
    const value = std.fmt.parseUnsigned(usize, raw, 10) catch return null;
    if (value < 1 or value > 9) return null;
    return value;
}

fn parseDesktopMoveIndex(raw: []const u8) ?usize {
    if (!std.mem.startsWith(u8, raw, "move-")) return null;
    return parseDesktopIndex(raw[5..]);
}

fn nextWorkspace(active: u8) u8 {
    return if (active >= 9) 1 else active + 1;
}

fn previousWorkspace(active: u8) u8 {
    return if (active <= 1) 9 else active - 1;
}

fn resolveDesktopCommand(command: DesktopCommand) ?DesktopCommand {
    const current = ax.desktopState() orelse return null;
    if (current.count == 0) return null;

    return switch (command) {
        .next => .{ .switch_to = if (current.active_index >= current.count) 1 else current.active_index + 1 },
        .prev => .{ .switch_to = if (current.active_index <= 1) current.count else current.active_index - 1 },
        .move_next => .{ .move_to = if (current.active_index >= current.count) 1 else current.active_index + 1 },
        .move_prev => .{ .move_to = if (current.active_index <= 1) current.count else current.active_index - 1 },
        .switch_to, .move_to => command,
    };
}

fn desktopChordForCommand(desktop: hotkeys.DesktopBindings, command: DesktopCommand) ?hotkeys.KeyChord {
    return switch (command) {
        .next => desktop.switch_next,
        .prev => desktop.switch_prev,
        .move_next => desktop.move_next,
        .move_prev => desktop.move_prev,
        .switch_to => |index| if (index >= 1 and index <= 9) desktop.switch_to[index - 1] else null,
        .move_to => |index| if (index >= 1 and index <= 9) desktop.move_to[index - 1] else null,
    };
}

fn hotkeyActionForDesktopCommand(command: DesktopCommand) ?hotkeys.HotkeyAction {
    return switch (command) {
        .next => .desktop_next,
        .prev => .desktop_prev,
        .move_next => .desktop_move_next,
        .move_prev => .desktop_move_prev,
        .switch_to => |index| hotkeys.desktopActionForIndex(index),
        .move_to => |index| hotkeys.desktopMoveActionForIndex(index),
    };
}

const DesktopTransition = struct {
    active_workspace: u8,
    focused_workspace: ?u8,
};

fn applyDesktopTransition(state_in: DesktopTransition, command: DesktopCommand) DesktopTransition {
    var state_out = state_in;
    switch (command) {
        .next => state_out.active_workspace = nextWorkspace(state_out.active_workspace),
        .prev => state_out.active_workspace = previousWorkspace(state_out.active_workspace),
        .switch_to => |index| state_out.active_workspace = @intCast(index),
        .move_next => state_out.focused_workspace = nextWorkspace(state_out.active_workspace),
        .move_prev => state_out.focused_workspace = previousWorkspace(state_out.active_workspace),
        .move_to => |index| state_out.focused_workspace = @intCast(index),
    }
    return state_out;
}

fn placementForWindow(placements: []const layout.Placement, window_id: u64) ?layout.Placement {
    for (placements) |placement| {
        if (placement.window_id == window_id) return placement;
    }
    return null;
}

test "desktop command parser accepts legacy and indexed actions" {
    try std.testing.expect(parseDesktopCommand("next").? == .next);
    try std.testing.expect(parseDesktopCommand("prev").? == .prev);
    try std.testing.expect(parseDesktopCommand("move-next").? == .move_next);
    try std.testing.expect(parseDesktopCommand("move-prev").? == .move_prev);

    const switch_to = parseDesktopCommand("9").?;
    try std.testing.expectEqual(@as(usize, 9), switch_to.switch_to);

    const move_to = parseDesktopCommand("move-1").?;
    try std.testing.expectEqual(@as(usize, 1), move_to.move_to);

    try std.testing.expect(parseDesktopCommand("0") == null);
    try std.testing.expect(parseDesktopCommand("10") == null);
    try std.testing.expect(parseDesktopCommand("move-0") == null);
    try std.testing.expect(parseDesktopCommand("move-10") == null);
}

test "desktop workspace transitions wrap and move focused window" {
    try std.testing.expectEqual(@as(u8, 1), nextWorkspace(9));
    try std.testing.expectEqual(@as(u8, 9), previousWorkspace(1));

    const switched = applyDesktopTransition(.{
        .active_workspace = 1,
        .focused_workspace = 1,
    }, .next);
    try std.testing.expectEqual(@as(u8, 2), switched.active_workspace);
    try std.testing.expectEqual(@as(u8, 1), switched.focused_workspace.?);

    const moved = applyDesktopTransition(.{
        .active_workspace = 9,
        .focused_workspace = 9,
    }, .move_next);
    try std.testing.expectEqual(@as(u8, 9), moved.active_workspace);
    try std.testing.expectEqual(@as(u8, 1), moved.focused_workspace.?);

    const indexed = applyDesktopTransition(.{
        .active_workspace = 2,
        .focused_workspace = 2,
    }, .{ .move_to = 7 });
    try std.testing.expectEqual(@as(u8, 2), indexed.active_workspace);
    try std.testing.expectEqual(@as(u8, 7), indexed.focused_workspace.?);
}

fn rectCenter(rect: state.Rect) state.Rect {
    return .{
        .x = rect.x + (rect.width / 2.0),
        .y = rect.y + (rect.height / 2.0),
        .width = 0,
        .height = 0,
    };
}

fn intervalOverlap(start_a: f64, end_a: f64, start_b: f64, end_b: f64) f64 {
    return @max(0, @min(end_a, end_b) - @max(start_a, start_b));
}

fn almostEqual(a: f64, b: f64) bool {
    return @abs(a - b) < 0.5;
}

fn indexOfWindowId(ids: []const u64, needle: u64) ?usize {
    for (ids, 0..) |id, index| {
        if (id == needle) return index;
    }
    return null;
}

fn containsWindowId(ids: []const u64, needle: u64) bool {
    return indexOfWindowId(ids, needle) != null;
}

fn snapshotForPlacements(placements: []const layout.Placement) WindowSnapshot {
    var hasher = std.hash.Wyhash.init(0);
    for (placements) |placement| {
        std.hash.autoHash(&hasher, placement.window_id);
    }
    return .{
        .count = placements.len,
        .digest = hasher.final(),
    };
}

fn snapshotForWindowIds(ids: []const u64) WindowSnapshot {
    var hasher = std.hash.Wyhash.init(0);
    for (ids) |window_id| {
        std.hash.autoHash(&hasher, window_id);
    }
    return .{
        .count = ids.len,
        .digest = hasher.final(),
    };
}
