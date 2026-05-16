const std = @import("std");
const events = @import("events.zig");
const hotkeys = @import("hotkeys.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");

pub const max_config_bytes: usize = 256 * 1024;

pub const Settings = struct {
    scope: ?state.SpaceState.WindowScope = null,
    layout_mode: ?layout.LayoutMode = null,
    border_enabled: ?bool = null,
    performance: events.PerformanceOptions = .{},
    desktop: hotkeys.DesktopBindings = .{},
    hotkeys: []hotkeys.HotkeyBinding = &.{},

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.hotkeys.len != 0) {
            allocator.free(self.hotkeys);
        }
        self.hotkeys = &.{};
    }
};

pub const LoadedConfig = struct {
    path: []u8,
    exists: bool = false,
    settings: Settings = .{},

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        allocator.free(self.path);
    }
};

pub fn load(allocator: std.mem.Allocator) !LoadedConfig {
    var loaded = LoadedConfig{
        .path = try resolvePath(allocator),
    };

    const file = std.fs.openFileAbsolute(loaded.path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            loaded.settings.hotkeys = try hotkeys.buildBindings(allocator, loaded.settings.desktop, &.{});
            return loaded;
        },
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_config_bytes);
    defer allocator.free(bytes);

    loaded.exists = true;
    try parseConfigBytes(&loaded.settings, allocator, bytes);
    return loaded;
}

pub fn resolvePath(allocator: std.mem.Allocator) ![]u8 {
    const maybe_env: ?[]u8 = std.process.getEnvVarOwned(allocator, "PANDA_CONFIG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    if (maybe_env) |value| {
        defer allocator.free(value);
        const expanded = try expandHome(allocator, value);
        return makeAbsolutePath(allocator, expanded);
    }

    const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const joined = try std.fs.path.join(allocator, &.{ home, ".config", "panda", "config.lua" });
    return makeAbsolutePath(allocator, joined);
}

fn parseConfigBytes(settings: *Settings, allocator: std.mem.Allocator, bytes: []const u8) !void {
    settings.deinit(allocator);

    var parsed_hotkeys = std.ArrayList(hotkeys.HotkeyBinding){};
    defer parsed_hotkeys.deinit(allocator);

    var section_stack = std.ArrayList(Section){};
    defer section_stack.deinit(allocator);
    try section_stack.append(allocator, .root);

    var next_hotkey_id: u32 = 1;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        var line = std.mem.trim(u8, stripLineComment(line_raw), " \t\r\n");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "return")) {
            line = std.mem.trimLeft(u8, line["return".len..], " \t");
        }
        if (line.len == 0) continue;

        while (line.len > 0 and line[0] == '}') {
            if (section_stack.items.len > 1) {
                _ = section_stack.pop();
            }
            line = std.mem.trimLeft(u8, line[1..], " \t\r\n");
            if (line.len > 0 and line[0] == ',') {
                line = std.mem.trimLeft(u8, line[1..], " \t\r\n");
            }
        }
        if (line.len == 0) continue;

        if (line[0] == '{') {
            if (section_stack.items.len > 1) {
                try section_stack.append(allocator, .unknown);
            }
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t\r\n");
        var value = std.mem.trim(u8, line[eq_index + 1 ..], " \t\r\n");
        if (key.len == 0 or value.len == 0) continue;

        if (value[0] == '{') {
            try section_stack.append(allocator, sectionForKey(key));
            continue;
        }

        value = trimTrailingComma(value);
        if (value.len == 0) continue;

        const current_section = section_stack.items[section_stack.items.len - 1];
        switch (current_section) {
            .root => applyRootSetting(settings, key, value),
            .performance => applyPerformanceSetting(settings, key, value),
            .desktop => applyDesktopSetting(settings, key, value),
            .shortcuts => try applyShortcutSetting(
                &parsed_hotkeys,
                key,
                value,
                &next_hotkey_id,
                allocator,
            ),
            .unknown => {},
        }
    }

    settings.hotkeys = try hotkeys.buildBindings(allocator, settings.desktop, parsed_hotkeys.items);
}

fn applyRootSetting(settings: *Settings, key: []const u8, raw_value: []const u8) void {
    const value = stringLiteralOrRaw(raw_value);

    if (normalizedEq(key, "scope")) {
        settings.scope = parseScope(value) orelse settings.scope;
        return;
    }

    if (normalizedEq(key, "layout")) {
        settings.layout_mode = parseLayoutMode(value) orelse settings.layout_mode;
        return;
    }

    if (normalizedEq(key, "border") or normalizedEq(key, "borders")) {
        settings.border_enabled = parseBool(value) orelse settings.border_enabled;
        return;
    }
}

fn applyPerformanceSetting(settings: *Settings, key: []const u8, raw_value: []const u8) void {
    const maybe_number = parseNumber(raw_value) orelse return;
    if (maybe_number <= 0) return;

    if (normalizedEq(key, "focus_poll_interval")) {
        settings.performance.focus_poll_interval_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "snapshot_poll_interval")) {
        settings.performance.fallback_snapshot_poll_interval_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "observer_snapshot_poll_interval")) {
        settings.performance.observer_backstop_snapshot_poll_interval_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "command_poll_interval")) {
        settings.performance.control_poll_interval_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "relayout_immediate_delay")) {
        settings.performance.immediate_relayout_delay_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "relayout_burst_delay")) {
        settings.performance.burst_relayout_delay_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "burst_window")) {
        settings.performance.burst_window_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "min_relayout_interval")) {
        settings.performance.min_relayout_interval_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "self_event_suppression_window")) {
        settings.performance.self_event_suppression_window_seconds = maybe_number;
        return;
    }
    if (normalizedEq(key, "swap_double_tap_window")) {
        settings.performance.swap_double_tap_window_seconds = maybe_number;
        return;
    }
}

fn applyDesktopSetting(settings: *Settings, key: []const u8, raw_value: []const u8) void {
    const literal = parseStringLiteral(raw_value) orelse return;
    const chord = hotkeys.parseKeyChord(literal) orelse return;

    if (normalizedEq(key, "switch_next")) {
        settings.desktop.switch_next = chord;
        return;
    }
    if (normalizedEq(key, "switch_prev")) {
        settings.desktop.switch_prev = chord;
        return;
    }
    if (normalizedEq(key, "move_next")) {
        settings.desktop.move_next = chord;
        return;
    }
    if (normalizedEq(key, "move_prev")) {
        settings.desktop.move_prev = chord;
        return;
    }

    if (normalizedEq(key, "switch_1")) {
        settings.desktop.switch_to[0] = chord;
        return;
    }
    if (normalizedEq(key, "switch_2")) {
        settings.desktop.switch_to[1] = chord;
        return;
    }
    if (normalizedEq(key, "switch_3")) {
        settings.desktop.switch_to[2] = chord;
        return;
    }
    if (normalizedEq(key, "switch_4")) {
        settings.desktop.switch_to[3] = chord;
        return;
    }
    if (normalizedEq(key, "switch_5")) {
        settings.desktop.switch_to[4] = chord;
        return;
    }
    if (normalizedEq(key, "switch_6")) {
        settings.desktop.switch_to[5] = chord;
        return;
    }
    if (normalizedEq(key, "switch_7")) {
        settings.desktop.switch_to[6] = chord;
        return;
    }
    if (normalizedEq(key, "switch_8")) {
        settings.desktop.switch_to[7] = chord;
        return;
    }
    if (normalizedEq(key, "switch_9")) {
        settings.desktop.switch_to[8] = chord;
        return;
    }

    if (normalizedEq(key, "move_1")) {
        settings.desktop.move_to[0] = chord;
        return;
    }
    if (normalizedEq(key, "move_2")) {
        settings.desktop.move_to[1] = chord;
        return;
    }
    if (normalizedEq(key, "move_3")) {
        settings.desktop.move_to[2] = chord;
        return;
    }
    if (normalizedEq(key, "move_4")) {
        settings.desktop.move_to[3] = chord;
        return;
    }
    if (normalizedEq(key, "move_5")) {
        settings.desktop.move_to[4] = chord;
        return;
    }
    if (normalizedEq(key, "move_6")) {
        settings.desktop.move_to[5] = chord;
        return;
    }
    if (normalizedEq(key, "move_7")) {
        settings.desktop.move_to[6] = chord;
        return;
    }
    if (normalizedEq(key, "move_8")) {
        settings.desktop.move_to[7] = chord;
        return;
    }
    if (normalizedEq(key, "move_9")) {
        settings.desktop.move_to[8] = chord;
        return;
    }
}

fn applyShortcutSetting(
    parsed_hotkeys: *std.ArrayList(hotkeys.HotkeyBinding),
    key: []const u8,
    raw_value: []const u8,
    next_hotkey_id: *u32,
    allocator: std.mem.Allocator,
) !void {
    const action = hotkeys.actionFromConfigKey(key) orelse return;
    const literal = parseStringLiteral(raw_value) orelse return;
    const chord = hotkeys.parseKeyChord(literal) orelse return;

    for (parsed_hotkeys.items) |*existing| {
        if (existing.action == action) {
            existing.chord = chord;
            return;
        }
    }

    try parsed_hotkeys.append(allocator, .{
        .id = next_hotkey_id.*,
        .action = action,
        .chord = chord,
    });
    next_hotkey_id.* += 1;
}

fn parseScope(raw: []const u8) ?state.SpaceState.WindowScope {
    if (normalizedEq(raw, "focused-app") or normalizedEq(raw, "focused_app") or normalizedEq(raw, "focused")) {
        return .focused_app;
    }
    if (normalizedEq(raw, "all-main-display") or normalizedEq(raw, "all_apps_main_display") or normalizedEq(raw, "all")) {
        return .all_apps_main_display;
    }
    return null;
}

fn parseLayoutMode(raw: []const u8) ?layout.LayoutMode {
    if (normalizedEq(raw, "grid")) return .grid;
    if (normalizedEq(raw, "master-stack") or normalizedEq(raw, "master_stack")) return .master_stack;
    if (normalizedEq(raw, "bsp")) return .bsp;
    return null;
}

fn parseBool(raw: []const u8) ?bool {
    if (normalizedEq(raw, "true") or normalizedEq(raw, "on")) return true;
    if (normalizedEq(raw, "false") or normalizedEq(raw, "off")) return false;
    return null;
}

fn parseNumber(raw: []const u8) ?f64 {
    const value = stringLiteralOrRaw(raw);
    return std.fmt.parseFloat(f64, value) catch null;
}

fn parseStringLiteral(raw: []const u8) ?[]const u8 {
    const value = trimTrailingComma(std.mem.trim(u8, raw, " \t\r\n"));
    if (value.len < 2) return null;

    const quote = value[0];
    if ((quote != '\'' and quote != '"') or value[value.len - 1] != quote) {
        return null;
    }

    return value[1 .. value.len - 1];
}

fn stringLiteralOrRaw(raw: []const u8) []const u8 {
    return parseStringLiteral(raw) orelse trimTrailingComma(std.mem.trim(u8, raw, " \t\r\n"));
}

fn trimTrailingComma(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0 and (raw[end - 1] == ',' or raw[end - 1] == ' ' or raw[end - 1] == '\t' or raw[end - 1] == '\r')) : (end -= 1) {}
    return raw[0..end];
}

fn stripLineComment(line: []const u8) []const u8 {
    var index: usize = 0;
    var quote: ?u8 = null;

    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            if (byte == active_quote and (index == 0 or line[index - 1] != '\\')) {
                quote = null;
            }
            continue;
        }

        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }

        if (byte == '-' and index + 1 < line.len and line[index + 1] == '-') {
            return line[0..index];
        }
    }

    return line;
}

fn sectionForKey(key: []const u8) Section {
    if (normalizedEq(key, "shortcuts")) return .shortcuts;
    if (normalizedEq(key, "performance")) return .performance;
    if (normalizedEq(key, "desktop")) return .desktop;
    return .unknown;
}

fn normalizedEq(lhs: []const u8, rhs: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;

    while (true) {
        while (i < lhs.len and isSkippable(lhs[i])) : (i += 1) {}
        while (j < rhs.len and isSkippable(rhs[j])) : (j += 1) {}

        if (i >= lhs.len or j >= rhs.len) break;
        if (std.ascii.toLower(lhs[i]) != std.ascii.toLower(rhs[j])) return false;

        i += 1;
        j += 1;
    }

    while (i < lhs.len and isSkippable(lhs[i])) : (i += 1) {}
    while (j < rhs.len and isSkippable(rhs[j])) : (j += 1) {}

    return i == lhs.len and j == rhs.len;
}

fn isSkippable(byte: u8) bool {
    return byte == '_' or byte == '-' or byte == ' ';
}

fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') {
        return allocator.dupe(u8, path);
    }

    if (path.len > 1 and path[1] != '/') {
        return allocator.dupe(u8, path);
    }

    const home = std.posix.getenv("HOME") orelse return allocator.dupe(u8, path);
    if (path.len == 1) {
        return allocator.dupe(u8, home);
    }

    return std.fs.path.join(allocator, &.{ home, path[2..] });
}

fn makeAbsolutePath(allocator: std.mem.Allocator, path: []u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return path;
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const absolute = try std.fs.path.join(allocator, &.{ cwd, path });
    allocator.free(path);
    return absolute;
}

const Section = enum {
    root,
    shortcuts,
    performance,
    desktop,
    unknown,
};

test "parse lua-style config table" {
    const allocator = std.testing.allocator;
    var settings = Settings{};
    defer settings.deinit(allocator);

    try parseConfigBytes(&settings, allocator,
        \\return {
        \\  scope = "all-main-display",
        \\  layout = "master-stack",
        \\  border = false,
        \\  performance = {
        \\    focus_poll_interval = 0.05,
        \\    snapshot_poll_interval = 0.60,
        \\    command_poll_interval = 0.01,
        \\  },
        \\  desktop = {
        \\    switch_prev = "ctrl+left",
        \\    switch_next = "ctrl+right",
        \\    move_prev = "ctrl+shift+left",
        \\    move_next = "ctrl+shift+right",
        \\    switch_1 = "cmd+!",
        \\    move_1 = "cmd+shift+!",
        \\  },
        \\  shortcuts = {
        \\    focus_left = "alt+h",
        \\    desktop_1 = "alt+!",
        \\    desktop_move_next = "alt+cmd+shift+right",
        \\    desktop_move_9 = "alt+cmd+shift+(",
        \\    border_toggle = "alt+b",
        \\  },
        \\}
    );

    try std.testing.expectEqual(state.SpaceState.WindowScope.all_apps_main_display, settings.scope.?);
    try std.testing.expectEqual(layout.LayoutMode.master_stack, settings.layout_mode.?);
    try std.testing.expectEqual(false, settings.border_enabled.?);
    try std.testing.expectEqual(@as(f64, 0.05), settings.performance.focus_poll_interval_seconds);
    try std.testing.expectEqual(@as(f64, 0.60), settings.performance.fallback_snapshot_poll_interval_seconds);
    try std.testing.expectEqual(@as(f64, 0.01), settings.performance.control_poll_interval_seconds);
    try std.testing.expectEqual(hotkeys.key_left_arrow, settings.desktop.switch_prev.key_code);
    try std.testing.expectEqual(hotkeys.mod_control, settings.desktop.switch_prev.modifiers);
    try std.testing.expectEqual(hotkeys.key_right_arrow, settings.desktop.move_next.key_code);
    try std.testing.expectEqual(hotkeys.mod_control | hotkeys.mod_shift, settings.desktop.move_next.modifiers);
    try std.testing.expectEqual(@as(u16, 18), settings.desktop.switch_to[0].key_code);
    try std.testing.expectEqual(hotkeys.mod_command, settings.desktop.switch_to[0].modifiers);
    try std.testing.expectEqual(@as(usize, 24), settings.hotkeys.len);
    try std.testing.expectEqual(hotkeys.HotkeyAction.desktop_prev, settings.hotkeys[0].action);
    try std.testing.expectEqual(hotkeys.HotkeyAction.desktop_1, settings.hotkeys[4].action);
    try std.testing.expectEqual(@as(u16, 18), settings.hotkeys[4].chord.key_code);
    try std.testing.expectEqual(hotkeys.mod_option, settings.hotkeys[4].chord.modifiers);
    try std.testing.expectEqual(hotkeys.HotkeyAction.desktop_move_next, settings.hotkeys[3].action);
    try std.testing.expectEqual(hotkeys.mod_option | hotkeys.mod_command | hotkeys.mod_shift, settings.hotkeys[3].chord.modifiers);
    try std.testing.expectEqual(hotkeys.HotkeyAction.desktop_move_9, settings.hotkeys[21].action);
    try std.testing.expectEqual(@as(u16, 25), settings.hotkeys[21].chord.key_code);
    try std.testing.expectEqual(hotkeys.HotkeyAction.focus_left, settings.hotkeys[22].action);
    try std.testing.expectEqual(hotkeys.HotkeyAction.border_toggle, settings.hotkeys[23].action);
}
