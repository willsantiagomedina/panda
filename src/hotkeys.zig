const std = @import("std");

pub const mod_command: u32 = 1 << 0;
pub const mod_control: u32 = 1 << 1;
pub const mod_option: u32 = 1 << 2;
pub const mod_shift: u32 = 1 << 3;

pub const key_left_arrow: u16 = 123;
pub const key_right_arrow: u16 = 124;
pub const key_down_arrow: u16 = 125;
pub const key_up_arrow: u16 = 126;

pub const KeyChord = struct {
    key_code: u16,
    modifiers: u32,
};

pub const DesktopBindings = struct {
    switch_prev: KeyChord = .{ .key_code = key_left_arrow, .modifiers = mod_control },
    switch_next: KeyChord = .{ .key_code = key_right_arrow, .modifiers = mod_control },
    move_prev: KeyChord = .{ .key_code = key_left_arrow, .modifiers = mod_control | mod_shift },
    move_next: KeyChord = .{ .key_code = key_right_arrow, .modifiers = mod_control | mod_shift },
    switch_to: [9]KeyChord = .{
        .{ .key_code = 18, .modifiers = mod_control },
        .{ .key_code = 19, .modifiers = mod_control },
        .{ .key_code = 20, .modifiers = mod_control },
        .{ .key_code = 21, .modifiers = mod_control },
        .{ .key_code = 23, .modifiers = mod_control },
        .{ .key_code = 22, .modifiers = mod_control },
        .{ .key_code = 26, .modifiers = mod_control },
        .{ .key_code = 28, .modifiers = mod_control },
        .{ .key_code = 25, .modifiers = mod_control },
    },
    move_to: [9]KeyChord = .{
        .{ .key_code = 18, .modifiers = mod_control | mod_shift },
        .{ .key_code = 19, .modifiers = mod_control | mod_shift },
        .{ .key_code = 20, .modifiers = mod_control | mod_shift },
        .{ .key_code = 21, .modifiers = mod_control | mod_shift },
        .{ .key_code = 23, .modifiers = mod_control | mod_shift },
        .{ .key_code = 22, .modifiers = mod_control | mod_shift },
        .{ .key_code = 26, .modifiers = mod_control | mod_shift },
        .{ .key_code = 28, .modifiers = mod_control | mod_shift },
        .{ .key_code = 25, .modifiers = mod_control | mod_shift },
    },
};

pub const HotkeyAction = enum {
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    swap_left,
    swap_right,
    swap_up,
    swap_down,
    border_toggle,
    desktop_next,
    desktop_prev,
    desktop_move_next,
    desktop_move_prev,
    desktop_1,
    desktop_2,
    desktop_3,
    desktop_4,
    desktop_5,
    desktop_6,
    desktop_7,
    desktop_8,
    desktop_9,
    desktop_move_1,
    desktop_move_2,
    desktop_move_3,
    desktop_move_4,
    desktop_move_5,
    desktop_move_6,
    desktop_move_7,
    desktop_move_8,
    desktop_move_9,
};

pub const HotkeyBinding = struct {
    id: u32,
    action: HotkeyAction,
    chord: KeyChord,
};

pub fn actionFromConfigKey(name: []const u8) ?HotkeyAction {
    if (normalizedEq(name, "focus_left")) return .focus_left;
    if (normalizedEq(name, "focus_right")) return .focus_right;
    if (normalizedEq(name, "focus_up")) return .focus_up;
    if (normalizedEq(name, "focus_down")) return .focus_down;

    if (normalizedEq(name, "swap_left")) return .swap_left;
    if (normalizedEq(name, "swap_right")) return .swap_right;
    if (normalizedEq(name, "swap_up")) return .swap_up;
    if (normalizedEq(name, "swap_down")) return .swap_down;

    if (normalizedEq(name, "border_toggle")) return .border_toggle;

    if (normalizedEq(name, "desktop_next")) return .desktop_next;
    if (normalizedEq(name, "desktop_prev")) return .desktop_prev;
    if (normalizedEq(name, "desktop_move_next") or normalizedEq(name, "move_desktop_next")) return .desktop_move_next;
    if (normalizedEq(name, "desktop_move_prev") or normalizedEq(name, "move_desktop_prev")) return .desktop_move_prev;

    if (normalizedEq(name, "desktop_1")) return .desktop_1;
    if (normalizedEq(name, "desktop_2")) return .desktop_2;
    if (normalizedEq(name, "desktop_3")) return .desktop_3;
    if (normalizedEq(name, "desktop_4")) return .desktop_4;
    if (normalizedEq(name, "desktop_5")) return .desktop_5;
    if (normalizedEq(name, "desktop_6")) return .desktop_6;
    if (normalizedEq(name, "desktop_7")) return .desktop_7;
    if (normalizedEq(name, "desktop_8")) return .desktop_8;
    if (normalizedEq(name, "desktop_9")) return .desktop_9;

    if (normalizedEq(name, "desktop_move_1") or normalizedEq(name, "move_desktop_1")) return .desktop_move_1;
    if (normalizedEq(name, "desktop_move_2") or normalizedEq(name, "move_desktop_2")) return .desktop_move_2;
    if (normalizedEq(name, "desktop_move_3") or normalizedEq(name, "move_desktop_3")) return .desktop_move_3;
    if (normalizedEq(name, "desktop_move_4") or normalizedEq(name, "move_desktop_4")) return .desktop_move_4;
    if (normalizedEq(name, "desktop_move_5") or normalizedEq(name, "move_desktop_5")) return .desktop_move_5;
    if (normalizedEq(name, "desktop_move_6") or normalizedEq(name, "move_desktop_6")) return .desktop_move_6;
    if (normalizedEq(name, "desktop_move_7") or normalizedEq(name, "move_desktop_7")) return .desktop_move_7;
    if (normalizedEq(name, "desktop_move_8") or normalizedEq(name, "move_desktop_8")) return .desktop_move_8;
    if (normalizedEq(name, "desktop_move_9") or normalizedEq(name, "move_desktop_9")) return .desktop_move_9;

    return null;
}

pub fn parseKeyChord(raw_value: []const u8) ?KeyChord {
    const raw = std.mem.trim(u8, raw_value, " \t\r\n");
    if (raw.len == 0) return null;

    var chord = KeyChord{
        .key_code = 0,
        .modifiers = 0,
    };
    var has_key = false;

    var tokens = std.mem.tokenizeScalar(u8, raw, '+');
    while (tokens.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;

        if (parseModifier(token)) |modifier| {
            chord.modifiers |= modifier;
            continue;
        }

        if (has_key) return null;

        const key_code = parseKeyCode(token) orelse return null;
        chord.key_code = key_code;
        has_key = true;
    }

    if (!has_key) return null;
    return chord;
}

fn parseModifier(token: []const u8) ?u32 {
    if (normalizedEq(token, "cmd") or normalizedEq(token, "command") or normalizedEq(token, "super")) {
        return mod_command;
    }
    if (normalizedEq(token, "ctrl") or normalizedEq(token, "control") or normalizedEq(token, "ctl")) {
        return mod_control;
    }
    if (normalizedEq(token, "alt") or normalizedEq(token, "option") or normalizedEq(token, "opt")) {
        return mod_option;
    }
    if (normalizedEq(token, "shift")) {
        return mod_shift;
    }

    return null;
}

fn parseKeyCode(token: []const u8) ?u16 {
    if (token.len == 1) {
        return switch (std.ascii.toLower(token[0])) {
            'a' => 0,
            's' => 1,
            'd' => 2,
            'f' => 3,
            'h' => 4,
            'g' => 5,
            'z' => 6,
            'x' => 7,
            'c' => 8,
            'v' => 9,
            'b' => 11,
            'q' => 12,
            'w' => 13,
            'e' => 14,
            'r' => 15,
            'y' => 16,
            't' => 17,
            '1' => 18,
            '2' => 19,
            '3' => 20,
            '4' => 21,
            '6' => 22,
            '5' => 23,
            '=' => 24,
            '9' => 25,
            '7' => 26,
            '-' => 27,
            '8' => 28,
            '0' => 29,
            ']' => 30,
            'o' => 31,
            'u' => 32,
            '[' => 33,
            'i' => 34,
            'p' => 35,
            '\n' => 36,
            'l' => 37,
            'j' => 38,
            '\'' => 39,
            'k' => 40,
            ';' => 41,
            '\\' => 42,
            ',' => 43,
            '/' => 44,
            'n' => 45,
            'm' => 46,
            '.' => 47,
            '\t' => 48,
            ' ' => 49,
            '`' => 50,
            else => null,
        };
    }

    if (normalizedEq(token, "left")) return key_left_arrow;
    if (normalizedEq(token, "right")) return key_right_arrow;
    if (normalizedEq(token, "down")) return key_down_arrow;
    if (normalizedEq(token, "up")) return key_up_arrow;

    if (normalizedEq(token, "return") or normalizedEq(token, "enter")) return 36;
    if (normalizedEq(token, "tab")) return 48;
    if (normalizedEq(token, "space")) return 49;
    if (normalizedEq(token, "escape") or normalizedEq(token, "esc")) return 53;
    if (normalizedEq(token, "delete") or normalizedEq(token, "backspace")) return 51;

    if (normalizedEq(token, "minus")) return 27;
    if (normalizedEq(token, "equal") or normalizedEq(token, "equals")) return 24;
    if (normalizedEq(token, "left_bracket") or normalizedEq(token, "lbracket")) return 33;
    if (normalizedEq(token, "right_bracket") or normalizedEq(token, "rbracket")) return 30;
    if (normalizedEq(token, "semicolon")) return 41;
    if (normalizedEq(token, "quote") or normalizedEq(token, "apostrophe")) return 39;
    if (normalizedEq(token, "backslash")) return 42;
    if (normalizedEq(token, "comma")) return 43;
    if (normalizedEq(token, "period") or normalizedEq(token, "dot")) return 47;
    if (normalizedEq(token, "slash")) return 44;
    if (normalizedEq(token, "grave") or normalizedEq(token, "backtick")) return 50;

    if (normalizedEq(token, "f1")) return 122;
    if (normalizedEq(token, "f2")) return 120;
    if (normalizedEq(token, "f3")) return 99;
    if (normalizedEq(token, "f4")) return 118;
    if (normalizedEq(token, "f5")) return 96;
    if (normalizedEq(token, "f6")) return 97;
    if (normalizedEq(token, "f7")) return 98;
    if (normalizedEq(token, "f8")) return 100;
    if (normalizedEq(token, "f9")) return 101;
    if (normalizedEq(token, "f10")) return 109;
    if (normalizedEq(token, "f11")) return 103;
    if (normalizedEq(token, "f12")) return 111;

    return null;
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

test "parse key chords and action aliases" {
    const chord = parseKeyChord("alt+cmd+shift+right").?;
    try std.testing.expectEqual(key_right_arrow, chord.key_code);
    try std.testing.expectEqual(mod_option | mod_command | mod_shift, chord.modifiers);

    const letter = parseKeyChord("ctrl+h").?;
    try std.testing.expectEqual(@as(u16, 4), letter.key_code);
    try std.testing.expectEqual(mod_control, letter.modifiers);

    try std.testing.expectEqual(HotkeyAction.desktop_move_next, actionFromConfigKey("move-desktop-next").?);
    try std.testing.expectEqual(HotkeyAction.desktop_move_prev, actionFromConfigKey("desktop_move_prev").?);
    try std.testing.expect(parseKeyChord("cmd+left+right") == null);
}
