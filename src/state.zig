const std = @import("std");
const ax = @import("ax.zig");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const Axis = enum {
    horizontal,
    vertical,
};

pub const NodeHandle = u32;

pub const Split = struct {
    axis: Axis,
    ratio: f64,
    left: NodeHandle,
    right: NodeHandle,
};

pub const Leaf = struct {
    window_id: u64,
};

pub const BspNode = union(enum) {
    split: Split,
    leaf: Leaf,
};

pub const WindowInfo = struct {
    id: u64,
    element: ax.NativeWindowRef,
    frame: Rect,
    title: []u8,
    bundle_id: []u8,
    floating: bool,

    pub fn deinit(self: *WindowInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.bundle_id);
        ax.c.CFRelease(self.element);
    }
};

pub const SpaceState = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(BspNode),
    windows: std.AutoHashMap(u64, WindowInfo),
    window_order: std.ArrayList(u64),
    root: ?NodeHandle = null,

    pub fn init(allocator: std.mem.Allocator) SpaceState {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .windows = std.AutoHashMap(u64, WindowInfo).init(allocator),
            .window_order = .empty,
        };
    }

    pub fn deinit(self: *SpaceState) void {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.windows.deinit();
        self.window_order.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    pub fn loadWindowsForPid(self: *SpaceState, pid: i32) !void {
        var current_space_ids = try currentSpaceWindowIds(self.allocator);
        defer current_space_ids.deinit();

        const summaries = try ax.listWindows(self.allocator, pid);
        defer self.allocator.free(summaries);

        for (summaries) |*summary| {
            const id = ax.windowId(summary.element);
            if (!isTileableWindow(summary.*, id, &current_space_ids, null)) {
                summary.deinit(self.allocator);
                continue;
            }

            if (self.windows.contains(id)) {
                summary.deinit(self.allocator);
                continue;
            }
            const bundle_id = try self.allocator.dupe(u8, "");

            try self.windows.put(id, .{
                .id = id,
                .element = summary.element,
                .frame = .{
                    .x = summary.frame.x,
                    .y = summary.frame.y,
                    .width = summary.frame.width,
                    .height = summary.frame.height,
                },
                .title = summary.title,
                .bundle_id = bundle_id,
                .floating = false,
            });
            try self.window_order.append(self.allocator, id);
        }

        sortWindowOrder(self.window_order.items);
        try self.rebuildLinearTree();
    }

    pub const WindowScope = enum {
        focused_app,
        all_apps_main_display,
    };

    pub fn loadWindowsForScope(self: *SpaceState, scope: WindowScope, focused_pid: i32, screen: Rect) !void {
        switch (scope) {
            .focused_app => try self.loadWindowsForPid(focused_pid),
            .all_apps_main_display => try self.loadWindowsOnCurrentSpace(screen),
        }
    }

    pub fn applyOrderOverride(self: *SpaceState, preferred_order: []const u64) !void {
        if (self.window_order.items.len <= 1 or preferred_order.len == 0) return;

        var reordered = std.ArrayList(u64){};
        defer reordered.deinit(self.allocator);

        for (preferred_order) |window_id| {
            if (!self.windows.contains(window_id)) continue;
            try reordered.append(self.allocator, window_id);
        }

        for (self.window_order.items) |window_id| {
            if (containsWindowId(reordered.items, window_id)) continue;
            try reordered.append(self.allocator, window_id);
        }

        @memcpy(self.window_order.items, reordered.items);
        try self.rebuildLinearTree();
    }

    fn loadWindowsOnCurrentSpace(self: *SpaceState, screen: Rect) !void {
        const panda_pid: i32 = @intCast(ax.c.pandaCurrentProcessId());
        var current_space_ids = try currentSpaceWindowIds(self.allocator);
        defer current_space_ids.deinit();

        // Build a set of PIDs that have windows on the current Space
        var pids_on_space = std.AutoHashMap(i32, void).init(self.allocator);
        defer pids_on_space.deinit();

        var current_space_iter = current_space_ids.iterator();
        while (current_space_iter.next()) |entry| {
            const pid = entry.value_ptr.*;
            if (pid == panda_pid) continue;
            try pids_on_space.put(pid, {});
        }

        // Now get AX window elements only for apps with windows on current Space
        const apps = try ax.listRunningGuiApps(self.allocator);
        defer {
            for (apps) |*app| app.deinit(self.allocator);
            self.allocator.free(apps);
        }

        for (apps) |app| {
            if (app.pid == panda_pid) continue;

            // Skip apps that don't have windows on the current Space
            if (!pids_on_space.contains(app.pid)) continue;

            const summaries = ax.listWindows(self.allocator, app.pid) catch |err| switch (err) {
                error.AppUnresponsive,
                error.AttributeUnsupported,
                error.InvalidPid,
                error.UnsupportedTarget,
                => continue,
                else => return err,
            };
            defer self.allocator.free(summaries);

            for (summaries) |*summary| {
                const id = ax.windowId(summary.element);
                if (!isTileableWindow(summary.*, id, &current_space_ids, screen)) {
                    summary.deinit(self.allocator);
                    continue;
                }

                if (self.windows.contains(id)) {
                    summary.deinit(self.allocator);
                    continue;
                }
                const bundle_id = try self.allocator.dupe(u8, "");

                try self.windows.put(id, .{
                    .id = id,
                    .element = summary.element,
                    .frame = .{
                        .x = summary.frame.x,
                        .y = summary.frame.y,
                        .width = summary.frame.width,
                        .height = summary.frame.height,
                    },
                    .title = summary.title,
                    .bundle_id = bundle_id,
                    .floating = false,
                });
                try self.window_order.append(self.allocator, id);
            }
        }

        sortWindowOrder(self.window_order.items);
        try self.rebuildLinearTree();
    }

    fn rebuildLinearTree(self: *SpaceState) !void {
        self.nodes.clearRetainingCapacity();
        self.root = null;

        if (self.window_order.items.len == 0) {
            return;
        }

        var current_root = try self.appendLeaf(self.window_order.items[0]);
        for (self.window_order.items[1..], 1..) |window_id, index| {
            const leaf = try self.appendLeaf(window_id);
            const axis: Axis = if (index == 1) .vertical else .horizontal;
            current_root = try self.appendSplit(.{
                .axis = axis,
                .ratio = if (index == 1) 0.6 else 0.5,
                .left = current_root,
                .right = leaf,
            });
        }

        self.root = current_root;
    }

    fn appendLeaf(self: *SpaceState, window_id: u64) !NodeHandle {
        const handle: NodeHandle = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .leaf = .{ .window_id = window_id } });
        return handle;
    }

    fn appendSplit(self: *SpaceState, split: Split) !NodeHandle {
        const handle: NodeHandle = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .split = split });
        return handle;
    }
};

fn currentSpaceWindowIds(allocator: std.mem.Allocator) !std.AutoHashMap(u64, i32) {
    const space_windows = try ax.listWindowsOnCurrentSpace(allocator);
    defer allocator.free(space_windows);

    var ids = std.AutoHashMap(u64, i32).init(allocator);
    errdefer ids.deinit();

    for (space_windows) |win| {
        try ids.put(win.window_id, win.pid);
    }

    return ids;
}

fn isTileableWindow(
    summary: ax.WindowSummary,
    window_id: u64,
    current_space_ids: *const std.AutoHashMap(u64, i32),
    screen: ?Rect,
) bool {
    if (!current_space_ids.contains(window_id)) return false;
    if (ax.isWindowMinimized(summary.element)) return false;
    if (!ax.isWindowStandard(summary.element)) return false;
    if (summary.frame.width < 80 or summary.frame.height < 80) return false;

    if (screen) |screen_rect| {
        if (!rectIntersects(summary.frame, screen_rect)) return false;
    }

    return true;
}

fn sortWindowOrder(window_order: []u64) void {
    std.mem.sort(u64, window_order, {}, lessWindowId);
}

fn lessWindowId(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn rectIntersects(frame: ax.Rect, screen: Rect) bool {
    const frame_right = frame.x + frame.width;
    const frame_bottom = frame.y + frame.height;
    const screen_right = screen.x + screen.width;
    const screen_bottom = screen.y + screen.height;

    return frame.x < screen_right and
        frame_right > screen.x and
        frame.y < screen_bottom and
        frame_bottom > screen.y;
}

fn containsWindowId(ids: []const u64, needle: u64) bool {
    for (ids) |id| {
        if (id == needle) return true;
    }
    return false;
}
