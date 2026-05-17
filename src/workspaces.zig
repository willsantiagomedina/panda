const std = @import("std");
const state = @import("state.zig");

pub const WorkspaceId = u8;
pub const workspace_count = 6;

pub const HiddenGeometry = struct {
    frame: state.Rect,
    screen: state.Rect,
    proportional_x: f64,
    proportional_y: f64,
};

pub const ManagedWindow = struct {
    window_id: u64,
    pid: i32,
    workspace: WorkspaceId,
    hidden: bool = false,
    hidden_geometry: ?HiddenGeometry = null,
    last_known_frame: state.Rect,
    floating: bool = false,
};

pub const Workspace = struct {
    id: WorkspaceId,
    window_order: std.ArrayList(u64),

    fn init(id: WorkspaceId) Workspace {
        return .{ .id = id, .window_order = .empty };
    }

    fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.window_order.deinit(allocator);
    }
};

pub const WorkspaceManager = struct {
    allocator: std.mem.Allocator,
    active: WorkspaceId = 1,
    workspaces: [workspace_count]Workspace,
    windows: std.AutoHashMap(u64, ManagedWindow),
    recent_focus: [workspace_count]?u64 = [_]?u64{null} ** workspace_count,

    pub fn init(allocator: std.mem.Allocator) WorkspaceManager {
        var spaces: [workspace_count]Workspace = undefined;
        for (&spaces, 0..) |*space, index| space.* = Workspace.init(@intCast(index + 1));
        return .{ .allocator = allocator, .workspaces = spaces, .windows = std.AutoHashMap(u64, ManagedWindow).init(allocator) };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        for (&self.workspaces) |*space| space.deinit(self.allocator);
        self.windows.deinit();
    }

    pub fn switchTo(self: *WorkspaceManager, target: WorkspaceId) !void {
        try validate(target);
        self.active = target;
    }

    pub fn next(self: *const WorkspaceManager) WorkspaceId {
        return if (self.active >= workspace_count) 1 else self.active + 1;
    }

    pub fn prev(self: *const WorkspaceManager) WorkspaceId {
        return if (self.active <= 1) workspace_count else self.active - 1;
    }

    pub fn ensureWindow(self: *WorkspaceManager, window_id: u64, pid: i32, frame: state.Rect, floating: bool) !void {
        if (self.windows.getPtr(window_id)) |managed| {
            managed.pid = pid;
            managed.last_known_frame = frame;
            managed.floating = floating;
            return;
        }
        try self.windows.put(window_id, .{ .window_id = window_id, .pid = pid, .workspace = self.active, .last_known_frame = frame, .floating = floating });
        try self.workspacePtr(self.active).window_order.append(self.allocator, window_id);
    }

    pub fn removeMissing(self: *WorkspaceManager, live_ids: []const u64) !void {
        var missing = std.ArrayList(u64).empty;
        defer missing.deinit(self.allocator);

        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (!contains(live_ids, entry.key_ptr.*) and !entry.value_ptr.hidden) {
                try missing.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (missing.items) |id| {
            const managed = self.windows.get(id) orelse continue;
            self.removeFromOrder(managed.workspace, id);
            _ = self.windows.remove(id);
        }
        for (&self.recent_focus) |*recent| {
            if (recent.* != null and !self.windows.contains(recent.*.?)) recent.* = null;
        }
    }

    pub fn moveWindowTo(self: *WorkspaceManager, window_id: u64, target: WorkspaceId) !void {
        try validate(target);
        const managed = self.windows.getPtr(window_id) orelse return;
        if (managed.workspace == target) return;
        self.removeFromOrder(managed.workspace, window_id);
        managed.workspace = target;
        try self.workspacePtr(target).window_order.append(self.allocator, window_id);
    }

    pub fn activeWindowIds(self: *WorkspaceManager) []const u64 {
        return self.workspacePtr(self.active).window_order.items;
    }

    pub fn replaceActiveOrder(self: *WorkspaceManager, preferred_order: []const u64) !void {
        const order = &self.workspacePtr(self.active).window_order;
        var reordered = std.ArrayList(u64).empty;
        defer reordered.deinit(self.allocator);

        for (preferred_order) |window_id| {
            const managed = self.windows.get(window_id) orelse continue;
            if (managed.workspace != self.active or contains(reordered.items, window_id)) continue;
            try reordered.append(self.allocator, window_id);
        }

        for (order.items) |window_id| {
            if (!contains(reordered.items, window_id)) try reordered.append(self.allocator, window_id);
        }

        order.clearRetainingCapacity();
        try order.appendSlice(self.allocator, reordered.items);
    }

    pub fn isActiveWindow(self: *WorkspaceManager, window_id: u64) bool {
        const managed = self.windows.get(window_id) orelse return false;
        return managed.workspace == self.active and !managed.hidden;
    }

    pub fn setHidden(self: *WorkspaceManager, window_id: u64, hidden: bool, geometry: ?HiddenGeometry) void {
        if (self.windows.getPtr(window_id)) |managed| {
            managed.hidden = hidden;
            if (geometry) |g| managed.hidden_geometry = g;
        }
    }

    pub fn setRecentFocus(self: *WorkspaceManager, window_id: u64) void {
        if (self.isActiveWindow(window_id)) self.recent_focus[self.active - 1] = window_id;
    }

    pub fn recentFocus(self: *WorkspaceManager, id: WorkspaceId) ?u64 {
        return self.recent_focus[id - 1];
    }

    fn workspacePtr(self: *WorkspaceManager, id: WorkspaceId) *Workspace {
        return &self.workspaces[id - 1];
    }

    fn removeFromOrder(self: *WorkspaceManager, workspace: WorkspaceId, window_id: u64) void {
        const order = &self.workspacePtr(workspace).window_order;
        for (order.items, 0..) |id, index| if (id == window_id) {
            _ = order.orderedRemove(index);
            break;
        };
    }
};

fn validate(id: WorkspaceId) !void {
    if (id < 1 or id > workspace_count) return error.InvalidWorkspace;
}

fn contains(ids: []const u64, needle: u64) bool {
    for (ids) |id| if (id == needle) return true;
    return false;
}

test "workspace manager basic operations" {
    var wm = WorkspaceManager.init(std.testing.allocator);
    defer wm.deinit();
    try std.testing.expectEqual(@as(WorkspaceId, 1), wm.active);
    try wm.ensureWindow(10, 1, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, false);
    try std.testing.expectEqual(@as(usize, 1), wm.activeWindowIds().len);
    try wm.switchTo(6);
    try std.testing.expectEqual(@as(WorkspaceId, 1), wm.next());
    try wm.moveWindowTo(10, 6);
    try std.testing.expect(wm.isActiveWindow(10));
    try wm.replaceActiveOrder(&.{10});
    try wm.removeMissing(&.{});
    try std.testing.expectEqual(@as(usize, 0), wm.windows.count());
}
