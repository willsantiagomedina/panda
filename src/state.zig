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
    pid: i32,
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
        try self.loadWindowsForPidOnScreen(pid, null);
    }

    pub fn loadWindowsForPidOnScreen(self: *SpaceState, pid: i32, screen: ?Rect) !void {
        const summaries = try ax.listWindows(self.allocator, pid);
        defer self.allocator.free(summaries);

        for (summaries) |*summary| {
            const id = ax.windowId(summary.element);
            if (!isTileableWindow(summary.*, screen)) {
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
                .pid = pid,
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
            .focused_app => try self.loadWindowsForPidOnScreen(focused_pid, screen),
            .all_apps_main_display => try self.loadWindowsOnCurrentSpace(screen),
        }
    }

    pub fn retainOnlyWindowIds(self: *SpaceState, allowed: *const std.AutoHashMap(u64, void)) !void {
        var ids_to_remove = std.ArrayList(u64).empty;
        defer ids_to_remove.deinit(self.allocator);

        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (!allowed.contains(entry.key_ptr.*)) try ids_to_remove.append(self.allocator, entry.key_ptr.*);
        }

        for (ids_to_remove.items) |id| {
            if (self.windows.fetchRemove(id)) |entry| {
                var value = entry.value;
                value.deinit(self.allocator);
            }
        }

        var kept = std.ArrayList(u64).empty;
        defer kept.deinit(self.allocator);
        for (self.window_order.items) |id| {
            if (self.windows.contains(id)) try kept.append(self.allocator, id);
        }
        self.window_order.clearRetainingCapacity();
        try self.window_order.appendSlice(self.allocator, kept.items);
        try self.rebuildLinearTree();
    }

    pub fn applyOrderOverride(self: *SpaceState, preferred_order: []const u64) !void {
        if (self.window_order.items.len <= 1 or preferred_order.len == 0) return;

        var reordered = std.ArrayList(u64).empty;
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

    pub fn loadAllTileableWindowsForRunningApps(self: *SpaceState) !void {
        const panda_pid: i32 = @intCast(ax.c.pandaCurrentProcessId());
        const apps = try ax.listRunningGuiApps(self.allocator);
        defer {
            for (apps) |*app| app.deinit(self.allocator);
            self.allocator.free(apps);
        }

        for (apps) |app| {
            const pid = app.pid;
            if (pid == panda_pid) continue;
            const summaries = ax.listWindows(self.allocator, pid) catch |err| switch (err) {
                error.AppUnresponsive, error.AttributeUnsupported, error.InvalidPid, error.UnsupportedTarget => continue,
                else => return err,
            };
            defer self.allocator.free(summaries);

            for (summaries) |*summary| {
                const id = ax.windowId(summary.element);
                if (ax.isWindowMinimized(summary.element) or !isTileableWindow(summary.*, null) or self.windows.contains(id)) {
                    summary.deinit(self.allocator);
                    continue;
                }
                const bundle_id = try self.allocator.dupe(u8, "");
                try self.windows.put(id, .{
                    .id = id,
                    .element = summary.element,
                    .frame = .{ .x = summary.frame.x, .y = summary.frame.y, .width = summary.frame.width, .height = summary.frame.height },
                    .title = summary.title,
                    .bundle_id = bundle_id,
                    .pid = pid,
                    .floating = false,
                });
                try self.window_order.append(self.allocator, id);
            }
        }

        sortWindowOrder(self.window_order.items);
        try self.rebuildLinearTree();
    }

    fn loadWindowsOnCurrentSpace(self: *SpaceState, screen: Rect) !void {
        const panda_pid: i32 = @intCast(ax.c.pandaCurrentProcessId());
        const visible_windows = try ax.listWindowsOnCurrentSpace(self.allocator);
        defer self.allocator.free(visible_windows);

        var visible_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer visible_ids.deinit();
        for (visible_windows) |window| {
            if (window.pid == panda_pid) continue;
            if (!rectIntersects(window.bounds, screen)) continue;
            try visible_ids.put(window.window_id, {});
        }

        const apps = try ax.listRunningGuiApps(self.allocator);
        defer {
            for (apps) |*app| {
                app.deinit(self.allocator);
            }
            self.allocator.free(apps);
        }

        for (apps) |app| {
            const pid = app.pid;
            if (pid == panda_pid) continue;

            const summaries = ax.listWindows(self.allocator, pid) catch |err| switch (err) {
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
                if (!visible_ids.contains(id) or ax.isWindowMinimized(summary.element) or !isTileableWindow(summary.*, screen)) {
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
                    .pid = pid,
                    .floating = false,
                });
                try self.window_order.append(self.allocator, id);
            }
        }

        sortWindowOrder(self.window_order.items);
        try self.rebuildLinearTree();
    }

    pub fn rebuildLinearTree(self: *SpaceState) !void {
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

fn isTileableWindow(
    summary: ax.WindowSummary,
    screen: ?Rect,
) bool {
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
