const std = @import("std");

const ax = @import("ax.zig");
const config = @import("config.zig");
const events = @import("events.zig");
const hotkeys = @import("hotkeys.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");
const workspaces = @import("workspaces.zig");

test {
    std.testing.refAllDecls(ax);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(events);
    std.testing.refAllDecls(hotkeys);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(state);
    std.testing.refAllDecls(workspaces);
}
