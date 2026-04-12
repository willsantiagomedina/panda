const std = @import("std");
const ax = @import("ax.zig");
const state = @import("state.zig");

pub const GapConfig = struct {
    outer: f64 = 6,
    inner: f64 = 8,
};

pub const MasterStackOptions = struct {
    master_ratio: f64 = 0.6,
    gaps: GapConfig = .{},
};

pub const GridOptions = struct {
    gaps: GapConfig = .{},
};

pub const BspOptions = struct {
    gaps: GapConfig = .{},
};

pub const LayoutMode = enum {
    master_stack,
    grid,
    bsp,
};

pub const LayoutOptions = struct {
    mode: LayoutMode = .bsp,
    master_stack: MasterStackOptions = .{},
    grid: GridOptions = .{},
    bsp: BspOptions = .{},
};

pub const Placement = struct {
    window_id: u64,
    frame: state.Rect,
};

pub fn apply(space: *state.SpaceState, screen: state.Rect, options: LayoutOptions) !void {
    const placements = try computePlacements(space.allocator, space, screen, options);
    defer space.allocator.free(placements);
    try applyPlacements(space, placements);
}

pub fn computePlacements(
    allocator: std.mem.Allocator,
    space: *const state.SpaceState,
    screen: state.Rect,
    options: LayoutOptions,
) ![]Placement {
    const tiled_count = countTiledWindows(space);
    var placements = try allocator.alloc(Placement, tiled_count);
    errdefer allocator.free(placements);

    if (tiled_count == 0) return placements;

    var tiled_ids = try allocator.alloc(u64, tiled_count);
    defer allocator.free(tiled_ids);

    var tiled_index: usize = 0;
    for (space.window_order.items) |window_id| {
        const window = space.windows.get(window_id) orelse continue;
        if (window.floating) continue;
        tiled_ids[tiled_index] = window_id;
        tiled_index += 1;
    }

    switch (options.mode) {
        .master_stack => {
            for (tiled_ids, 0..) |window_id, index| {
                placements[index] = .{
                    .window_id = window_id,
                    .frame = masterStackRect(screen, index, tiled_count, options.master_stack.master_ratio, options.master_stack.gaps),
                };
            }
        },
        .grid => {
            for (tiled_ids, 0..) |window_id, index| {
                placements[index] = .{
                    .window_id = window_id,
                    .frame = gridRect(screen, index, tiled_count, options.grid.gaps),
                };
            }
        },
        .bsp => {
            const usable = insetRect(screen, options.bsp.gaps.outer);
            fillBspPlacements(placements, tiled_ids, usable, options.bsp.gaps.inner, 0);
        },
    }

    return placements;
}

fn insetRect(screen: state.Rect, inset: f64) state.Rect {
    return .{
        .x = screen.x + inset,
        .y = screen.y + inset,
        .width = @max(0, screen.width - (inset * 2)),
        .height = @max(0, screen.height - (inset * 2)),
    };
}

pub fn applyPlacements(space: *state.SpaceState, placements: []const Placement) !void {
    for (placements) |placement| {
        const window = space.windows.getPtr(placement.window_id) orelse continue;
        if (!rectChanged(window.frame, placement.frame)) {
            continue;
        }

        ax.moveResizeWindow(window.element, .{
            .x = placement.frame.x,
            .y = placement.frame.y,
            .width = placement.frame.width,
            .height = placement.frame.height,
        }) catch |err| switch (err) {
            error.UnexpectedAxError,
            error.AttributeUnsupported,
            error.AppUnresponsive,
            error.InvalidPid,
            => continue,
            else => return err,
        };
        window.frame = placement.frame;
    }
}

pub fn masterStackRect(screen: state.Rect, index: usize, count: usize, master_ratio: f64, gaps: GapConfig) state.Rect {
    const outer = gaps.outer;
    const inner = gaps.inner;
    const usable = insetRect(screen, outer);

    if (count <= 1 or index == 0) {
        const width = if (count <= 1) usable.width else (usable.width * master_ratio) - (inner / 2);
        return .{
            .x = usable.x,
            .y = usable.y,
            .width = @max(0, width),
            .height = usable.height,
        };
    }

    const stack_count = count - 1;
    const stack_x = usable.x + (usable.width * master_ratio) + (inner / 2);
    const stack_width = @max(0, usable.width - (usable.width * master_ratio) - (inner / 2));
    const slot_height = (usable.height - (inner * @as(f64, @floatFromInt(stack_count - 1)))) / @as(f64, @floatFromInt(stack_count));
    const stack_index: f64 = @floatFromInt(index - 1);

    return .{
        .x = stack_x,
        .y = usable.y + (slot_height + inner) * stack_index,
        .width = stack_width,
        .height = @max(0, slot_height),
    };
}

pub fn gridRect(screen: state.Rect, index: usize, count: usize, gaps: GapConfig) state.Rect {
    const outer = gaps.outer;
    const inner = gaps.inner;
    const usable = insetRect(screen, outer);
    if (count == 0) return usable;

    const columns = ceilSqrt(count);
    const rows = @divFloor(count + columns - 1, columns);
    const col = index % columns;
    const row = @divFloor(index, columns);

    const column_count_f: f64 = @floatFromInt(columns);
    const row_count_f: f64 = @floatFromInt(rows);
    const gaps_x: f64 = @floatFromInt(columns - 1);
    const gaps_y: f64 = @floatFromInt(rows - 1);

    const slot_width = (usable.width - (inner * gaps_x)) / column_count_f;
    const slot_height = (usable.height - (inner * gaps_y)) / row_count_f;
    const col_f: f64 = @floatFromInt(col);
    const row_f: f64 = @floatFromInt(row);

    return .{
        .x = usable.x + (slot_width + inner) * col_f,
        .y = usable.y + (slot_height + inner) * row_f,
        .width = @max(0, slot_width),
        .height = @max(0, slot_height),
    };
}

fn ceilSqrt(value: usize) usize {
    var root: usize = 1;
    while (root * root < value) : (root += 1) {}
    return root;
}

fn rectChanged(current: state.Rect, target: state.Rect) bool {
    return !almostEqual(current.x, target.x) or
        !almostEqual(current.y, target.y) or
        !almostEqual(current.width, target.width) or
        !almostEqual(current.height, target.height);
}

fn almostEqual(a: f64, b: f64) bool {
    return @abs(a - b) < 0.75;
}

fn fillBspPlacements(
    placements: []Placement,
    window_ids: []const u64,
    area: state.Rect,
    gap: f64,
    depth: usize,
) void {
    if (placements.len == 0) return;
    if (placements.len == 1) {
        placements[0] = .{
            .window_id = window_ids[0],
            .frame = area,
        };
        return;
    }

    const split_vertical = (depth % 2) == 0;
    const first_area, const second_area = splitRect(area, split_vertical, gap);

    placements[0] = .{
        .window_id = window_ids[0],
        .frame = first_area,
    };
    fillBspPlacements(placements[1..], window_ids[1..], second_area, gap, depth + 1);
}

fn splitRect(area: state.Rect, split_vertical: bool, gap: f64) struct { state.Rect, state.Rect } {
    if (split_vertical) {
        const first_width = @max(0, (area.width - gap) / 2);
        const second_width = @max(0, area.width - first_width - gap);
        return .{
            .{
                .x = area.x,
                .y = area.y,
                .width = first_width,
                .height = area.height,
            },
            .{
                .x = area.x + first_width + gap,
                .y = area.y,
                .width = second_width,
                .height = area.height,
            },
        };
    }

    const first_height = @max(0, (area.height - gap) / 2);
    const second_height = @max(0, area.height - first_height - gap);
    return .{
        .{
            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = first_height,
        },
        .{
            .x = area.x,
            .y = area.y + first_height + gap,
            .width = area.width,
            .height = second_height,
        },
    };
}

fn countTiledWindows(space: *const state.SpaceState) usize {
    var count: usize = 0;
    for (space.window_order.items) |window_id| {
        const window = space.windows.get(window_id) orelse continue;
        if (window.floating) continue;
        count += 1;
    }
    return count;
}

fn rectsOverlap(lhs: state.Rect, rhs: state.Rect) bool {
    return lhs.x < rhs.x + rhs.width and
        lhs.x + lhs.width > rhs.x and
        lhs.y < rhs.y + rhs.height and
        lhs.y + lhs.height > rhs.y;
}

test "bsp placements stay inside screen and do not overlap" {
    const allocator = std.testing.allocator;
    const screen = state.Rect{
        .x = 0,
        .y = 0,
        .width = 1440,
        .height = 900,
    };

    for (1..8) |count| {
        var placements = try allocator.alloc(Placement, count);
        defer allocator.free(placements);
        const window_ids = try allocator.alloc(u64, count);
        defer allocator.free(window_ids);

        for (window_ids, 0..) |*window_id, index| {
            window_id.* = index + 1;
        }

        fillBspPlacements(placements, window_ids, insetRect(screen, 6), 8, 0);

        for (placements) |placement| {
            try std.testing.expect(placement.frame.width >= 0);
            try std.testing.expect(placement.frame.height >= 0);
            try std.testing.expect(placement.frame.x >= screen.x);
            try std.testing.expect(placement.frame.y >= screen.y);
            try std.testing.expect(placement.frame.x + placement.frame.width <= screen.x + screen.width);
            try std.testing.expect(placement.frame.y + placement.frame.height <= screen.y + screen.height);
        }

        for (placements, 0..) |placement, index| {
            for (placements[index + 1 ..]) |other| {
                try std.testing.expect(!rectsOverlap(placement.frame, other.frame));
            }
        }
    }
}
