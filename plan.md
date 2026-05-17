# Panda Virtual Workspaces Plan (AeroSpace-style)

## Goal

Implement true Panda-managed virtual workspaces, inspired by AeroSpace’s model, instead of relying on macOS Mission Control Spaces. Panda should provide fast, reliable, customizable workspaces that work from the app daemon/background process, independent of macOS desktop-switching shortcuts.

This document is intended for a future Pi coding agent. Read it fully before implementing.

## Current State / Context

Panda is a macOS tiling window manager written in Zig with a small Objective-C bridge in `src/frontmost.m` / `src/frontmost.h`.

Important files:

- `src/main.zig` — CLI commands, daemon install/update, command dispatch.
- `src/events.zig` — daemon event loop, hotkeys, control socket, tiling orchestration.
- `src/state.zig` — window discovery and in-memory space/window state.
- `src/layout.zig` — BSP/grid/master-stack placement calculation and AX movement.
- `src/ax.zig` — Zig wrapper around Accessibility/CoreGraphics/Objective-C helpers.
- `src/hotkeys.zig` — hotkey definitions, default bindings, chord parser.
- `src/frontmost.m` — AppKit/AX/Carbon bridge, hotkey registration, border overlays, screen/window queries.
- `scripts/package-dmg.sh` — builds `Panda.app` and DMG.

Recent fixes:

- `Panda.app` now starts the daemon directly when opened, instead of depending on LaunchAgent startup.
- Desktop switching currently relies on hotkeys/Mission Control shortcuts and is unreliable.
- We attempted native SkyLight space switching, but it returned `ok` without visibly switching on the user’s machine.
- AeroSpace does **not** rely on macOS Spaces for its core workspace model. It maintains virtual workspaces and hides inactive workspace windows offscreen/in corners.

## High-Level Product Requirements

Panda should support up to 9 virtual workspaces by default:

- `panda desktop 1` through `panda desktop 9`
- `panda desktop next`
- `panda desktop prev`
- `panda desktop move-1` through `panda desktop move-9`
- `panda desktop move-next`
- `panda desktop move-prev`

Default hotkeys requested by the user:

- `Option + !` → workspace 1
- `Option + @` → workspace 2
- `Option + #` → workspace 3
- `Option + $` → workspace 4
- `Option + %` → workspace 5
- `Option + ^` → workspace 6
- `Option + &` → workspace 7
- `Option + *` → workspace 8
- `Option + (` → workspace 9

The implementation should be configurable, useful, smooth, and robust.

## What “AeroSpace-style” Means Here

AeroSpace workspaces are logical/virtual. The app tracks which windows belong to which workspace. Only windows in the active workspace are visible and tiled. Windows in inactive workspaces are moved out of view in a controlled way, then restored when the workspace becomes active.

Important AeroSpace ideas to borrow:

1. **Logical workspace model**
   - Workspaces are app-owned entities, not necessarily macOS Spaces.
   - A workspace has a name/id and a set/order/tree of windows.
   - Workspaces can exist even if empty.

2. **Window assignment**
   - Every managed window belongs to exactly one workspace.
   - New windows should be assigned to the active workspace by default.
   - Moving a window to another workspace should not require macOS Spaces APIs.

3. **Hide inactive workspace windows offscreen**
   - AeroSpace hides inactive workspace windows in corners/offscreen rather than minimizing them.
   - Do **not** use AXMinimized for virtual workspaces; minimizing caused apps/windows to pop open and led to bad behavior.
   - Store enough prior geometry to restore windows cleanly.

4. **Visible workspace per monitor** (future/phase 2)
   - AeroSpace supports monitor-aware workspaces.
   - Panda can start with one global active workspace for the main display, then evolve to per-monitor active workspace.

5. **No dependence on Mission Control shortcuts**
   - User should not need System Settings > Keyboard > Mission Control shortcuts.
   - Panda owns switching.

## Current Problems to Avoid

### 1. Minimize/unminimize workspace hiding

A previous implementation assigned windows to workspaces and called `AXMinimized` for inactive windows. This was bad:

- It reopened/minimized apps unexpectedly.
- It changed macOS/app state too aggressively.
- It created confusing behavior where apps “opened all at once.”

Do not do this.

### 2. Moving a window to a tiny corner and accidentally tiling it

The current tiling logic filters visible/current-space windows after recent fixes. For virtual workspaces, hidden offscreen windows must be excluded from tiling for the active workspace. A hidden workspace window should not be treated as an active tile candidate.

### 3. Losing user geometry

If a floating or hidden workspace window is later restored, it should return to a sensible position. For tiled windows, restoring means re-applying the layout. For floating windows, preserve pre-hide proportional location/size.

### 4. Trusting unstable private macOS APIs

Avoid relying on SkyLight/CGS APIs for switching. If any private APIs are retained for introspection, they must be optional/fallback only.

## Proposed Architecture

Introduce a first-class virtual workspace subsystem, ideally in a new file:

- `src/workspaces.zig`

This should contain:

```zig
pub const WorkspaceId = u8; // 1..9 initially

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
    hidden: bool,
    hidden_geometry: ?HiddenGeometry,
    last_known_frame: state.Rect,
    floating: bool,
};

pub const Workspace = struct {
    id: WorkspaceId,
    window_order: std.ArrayList(u64),
};

pub const WorkspaceManager = struct {
    active_workspace: WorkspaceId,
    workspaces: [9]Workspace,
    windows: std.AutoHashMap(u64, ManagedWindow),
    // methods...
};
```

Do not over-type everything upfront if Zig inference makes better sense, but the conceptual model should be explicit.

## Data Ownership Decision

Currently `state.SpaceState` is ephemeral: each relayout loads windows fresh via AX, applies layout, then stores `current_space` in `EventLoop`.

For virtual workspaces, Panda needs persistent metadata across relayouts:

- window → workspace assignment
- hidden/restored state
- order per workspace
- optional saved floating geometry

This persistent metadata belongs in `EventLoop` or a new `WorkspaceManager` owned by `EventLoop`.

Recommendation:

- Add `workspace_manager: workspaces.WorkspaceManager` to `events.EventLoop`.
- Keep `state.SpaceState` as the per-relayout live AX snapshot.
- `WorkspaceManager` should never retain AXUIElementRefs long-term unless absolutely necessary. It should store IDs, pid, frames, and metadata. Live elements come from fresh `SpaceState` snapshots.

## Window Identity

Panda currently uses `ax.windowId(summary.element)` which uses `_AXUIElementGetWindow` if available, falling back to `CFHash`.

For virtual workspaces, stable IDs are crucial. The fallback `CFHash` may not be stable across snapshots. The implementation should:

1. Prefer `_AXUIElementGetWindow` / CGWindow ID.
2. For windows without a CGWindow ID, consider excluding from virtual workspace management.
3. Add debug logging when a window has only fallback ID.

Potential function:

```zig
pub fn stableWindowId(window: NativeWindowRef) ?u64
```

This can return null if `_AXUIElementGetWindow` fails. Then tile/virtual workspace logic can ignore unstable windows.

## Workspace Lifecycle

### Startup

When daemon starts:

1. Initialize workspaces 1..9.
2. Active workspace defaults to 1.
3. Capture current visible windows on current display/current macOS Space.
4. Assign all currently visible tileable windows to workspace 1.
5. Tile workspace 1.

Question: Should workspace state persist across daemon restarts?

Phase 1: no persistence. All visible windows go to workspace 1 on startup.

Phase 2: persist window assignments by app/window signatures. This is harder and can wait.

### New windows

When a new tileable window appears:

- Assign it to the active workspace.
- Append to active workspace order.
- Tile active workspace.

If a hidden workspace window reappears from AX/CG snapshots, preserve existing assignment.

### Closed windows

When a window disappears:

- Remove it from global map.
- Remove it from any workspace order.
- If it was focused, choose a new focus in active workspace.
- Retile active workspace.

### Active workspace switching

`switchWorkspace(target)` should:

1. If target == current, no-op.
2. Capture live frames for active workspace windows.
3. Hide all windows assigned to old workspace.
4. Set active workspace = target.
5. Unhide all windows assigned to target.
6. Rebuild a `SpaceState` containing only target workspace windows.
7. Apply layout.
8. Focus most recent or first window in target workspace.
9. Sync borders.

Important: hide old first or unhide new first? AeroSpace does “unhide visible workspaces first, then hide invisible” to reduce flicker in some contexts. For a single active workspace model, probably:

- Unhide target windows first if target has windows, then hide old windows.
- But to avoid overlap/flicker, old hide first may be acceptable.
- Test both. Prefer minimal visual chaos.

### Move focused window to workspace

`moveFocusedWindowToWorkspace(target)`:

1. Find currently focused managed window.
2. If absent, no-op.
3. Remove from current workspace order.
4. Add to target workspace order.
5. Update assignment.
6. If target != active:
   - Hide that window offscreen.
   - Focus another window in active workspace.
   - Retile active workspace.
7. If target == active:
   - Retile active workspace.

`move-next` / `move-prev` wrap around 1..9.

## Hiding Strategy

Do not minimize. Move windows just outside the visible area.

AeroSpace has `hideInCorner` logic. It chooses a bottom-left or bottom-right offscreen position and stores proportional pre-hide position.

Panda can implement a simple version:

- Main display visible frame: `screen`.
- Get window size from live frame.
- Hide positions:
  - bottom-right: `x = screen.x + screen.width + 1`, `y = screen.y + screen.height - height - 1`
  - bottom-left: `x = screen.x - width - 1`, `y = screen.y + screen.height - height - 1`

Coordinate caveat: Panda uses top-left-ish CG/AX coordinates in several places. Verify with existing `layout.applyPlacements` coordinate system. The current tiling places windows correctly, so use the same `state.Rect` coordinate convention.

Potential functions:

```zig
fn hideWindowInCorner(window: ax.NativeWindowRef, current_frame: state.Rect, screen: state.Rect) !HiddenGeometry
fn unhideWindowFromCorner(window: ax.NativeWindowRef, hidden: HiddenGeometry) !void
```

But for tiled windows, unhide can simply move them to layout placement. For floating windows, restore saved proportional frame.

Phase 1 can treat all windows as tiled and restore by layout. Still store hidden geometry for safety/debug.

## Floating Windows

Current Panda has `floating: bool` in `state.WindowInfo` but no robust float rules.

Phase 1:

- All standard tileable windows are tiled.
- Popups/dialogs are filtered by `ax.isWindowStandard` and min size.

Phase 2:

- Add config rules for floating apps/window titles.
- Floating windows assigned to workspace should hide/unhide with workspace but not tile.
- Floating windows should restore to last proportional location.

## EventLoop Integration

### Current flow

`EventLoop.reconcileFocusedApp()` polls frontmost app and triggers `relayoutPid(pid)`.

`relayoutPid` currently:

1. Loads windows for scope.
2. Applies order overrides.
3. Computes placements.
4. Applies layout.
5. Stores current space/layout.
6. Syncs borders.

### Proposed new flow

Add a mode/config option:

```zig
workspace_mode = .virtual // default eventually
```

But since user explicitly wants virtual workspaces, implement as default for desktop commands. Tiling can still use current scope.

`relayoutPid` should become:

1. Load live windows for current display/current macOS Space.
2. Reconcile live windows with `WorkspaceManager`:
   - Add new live visible windows to active workspace.
   - Remove disappeared windows.
   - Do not add hidden offscreen windows to active workspace if already assigned elsewhere.
3. Build an active workspace `SpaceState` containing only windows assigned to active workspace and not hidden, or assigned active and live.
4. Apply layout only to active workspace windows.
5. Keep hidden workspace windows hidden and excluded.

This might require a helper to create a filtered `SpaceState` from a broader live snapshot. Options:

- Add `SpaceState.filterToWindowIds(ids)` or `copySubset`.
- Or modify `state.loadWindowsForScope` to accept an optional predicate.

Recommended: add a method:

```zig
pub fn retainOnlyWindowIds(self: *SpaceState, allowed: *const std.AutoHashMap(u64, void)) void
```

Need to carefully deinit removed `WindowInfo` values.

Alternative: build active `SpaceState` from scratch by moving/copying entries from live snapshot. Be careful with AXUIElement ownership; `WindowInfo.deinit` releases elements.

## WorkspaceManager API Sketch

Create `src/workspaces.zig`.

Suggested API:

```zig
pub const WorkspaceManager = struct {
    allocator: std.mem.Allocator,
    active: WorkspaceId = 1,
    workspaces: [9]Workspace,
    windows: std.AutoHashMap(u64, ManagedWindow),
    recent_focus: [9]?u64,

    pub fn init(allocator: std.mem.Allocator) WorkspaceManager
    pub fn deinit(self: *WorkspaceManager) void

    pub fn activeWorkspace(self: *const WorkspaceManager) WorkspaceId
    pub fn switchTo(self: *WorkspaceManager, target: WorkspaceId) !void
    pub fn next(self: *const WorkspaceManager) WorkspaceId
    pub fn prev(self: *const WorkspaceManager) WorkspaceId

    pub fn ensureWindow(self: *WorkspaceManager, window_id: u64, pid: i32, frame: state.Rect) !void
    pub fn removeMissing(self: *WorkspaceManager, live_ids: []const u64) void
    pub fn moveWindowTo(self: *WorkspaceManager, window_id: u64, target: WorkspaceId) !void
    pub fn activeWindowIds(self: *WorkspaceManager) []const u64
    pub fn isActiveWindow(self: *WorkspaceManager, window_id: u64) bool
};
```

Because `Workspace.window_order` is an ArrayList, `activeWindowIds` may simply return `workspaces[active-1].window_order.items`.

## Config Changes

Update config support in `src/config.zig` and `examples/config.lua`.

Proposed config:

```lua
return {
  workspaces = {
    enabled = true,
    count = 9,
    hide_strategy = "corner", -- corner | offscreen
    switch_1 = "option+!",
    switch_2 = "option+@",
    -- ...
    move_1 = "option+cmd+!",
    -- ...
  }
}
```

But avoid breaking existing config. The existing `desktop` table can map to workspace commands.

Suggested naming:

- Keep CLI command as `desktop` for compatibility.
- Internally call them `workspaces`.
- Docs can explain: “Panda desktops are virtual workspaces.”

## Hotkeys

Currently `hotkeys.zig` builds default desktop bindings and optional shortcuts.

Modify semantics:

- `desktop_1..9` hotkey actions call virtual workspace switching.
- `desktop_next/prev` call virtual next/prev.
- `desktop_move_1..9` moves focused window to target virtual workspace.

Do not send Mission Control shortcuts for virtual workspace switching.

Potential cleanup:

- Remove or demote `desktopChordForCommand` usage.
- Keep chord parsing for registering hotkeys.
- `desktop` config values are hotkeys handled by Panda, not chords sent to macOS.

## CLI Commands

Update `src/main.zig` usage:

```txt
panda desktop next|prev|1..9|move-next|move-prev|move-1..9
```

Potential additional commands:

- `panda desktop list`
- `panda desktop current`
- `panda desktop status`

Need to update parser `isValidDesktopAction`. `list/status/current` could be new verbs but not required for phase 1.

Recommended phase 1 additions:

- `panda desktop status` returns active workspace and window counts.

Control command response examples:

```txt
workspace: 3
1: 2 windows
2: 0 windows
3: 4 windows active
...
```

## Borders and Focus

When switching workspaces:

- Clear borders before hide/unhide if needed.
- After layout target workspace, sync borders for target windows only.
- Focus target workspace’s recent focused window, else first tiled window.

Add `recent_focus` tracking:

- On `syncFocusedWindowState`, if focused window belongs to active workspace, set `recent_focus[active-1] = focused_id`.
- On switch, use recent focus if it still exists in target workspace.

## Persistence

Phase 1: in-memory only.

Phase 2: write session state to e.g.

`~/Library/Application Support/Panda/workspaces.json`

But persistence is tricky because window IDs change across app restarts. Prefer no persistence initially.

## Multi-Monitor Design

Phase 1: one global active workspace, main display only.

Phase 2:

- Workspace has assigned monitor point/display ID.
- Each monitor has active workspace.
- A workspace can be visible on one monitor at a time.
- Switching workspace changes active workspace for focused/current monitor.

Potential structs:

```zig
const MonitorId = u32;
const MonitorState = struct {
    id: MonitorId,
    frame: state.Rect,
    visible_frame: state.Rect,
    active_workspace: WorkspaceId,
};
```

Need Objective-C helpers for listing screens/display IDs.

## Testing Strategy

### Unit Tests

Add tests to `workspaces.zig`:

- initialization creates 9 workspaces
- new windows go to active workspace
- switch active workspace
- move window to workspace removes from old/adds to new
- next/prev wrap
- remove missing windows cleans all orders
- recent focus falls back if missing

### Integration / Manual Tests

1. Start daemon.
2. Open 2–3 normal windows.
3. Verify they tile on workspace 1.
4. Run `panda desktop 2`.
   - Workspace 1 windows disappear offscreen.
   - Workspace 2 is empty.
   - No apps open unexpectedly.
5. Open a new window on workspace 2.
   - It is assigned to workspace 2.
6. Run `panda desktop 1`.
   - Workspace 1 windows reappear and tile.
   - Workspace 2 window hides.
7. Move focused window:
   - `panda desktop move-2`
   - Window disappears from workspace 1.
   - Switch to 2, it appears.
8. Test hotkeys Option+!, Option+@, etc.
9. Test closing hidden workspace windows if possible.
10. Test daemon restart: all currently visible windows reset to workspace 1.

### Safety Tests

- System Settings windows should not tile if they’re nonstandard or small.
- Finder desktop/popup windows should not tile.
- Hidden offscreen windows should not get included in current tiling pass.
- Opening Panda.app should start daemon and work.

## Implementation Phases

### Phase 0: Preserve stable app behavior

Before workspace work, ensure current main branch app-open behavior is intact:

- `open /Applications/Panda.app` starts daemon.
- `panda daemon-status` shows responsive.
- `panda focus` and tiling still work.

Do not regress this.

### Phase 1: Core virtual workspace manager

1. Add `src/workspaces.zig`.
2. Add manager to `EventLoop`.
3. Reconcile live windows into active workspace.
4. Implement switch/move commands without hiding yet, just assignment and layout filtering.
5. Unit test manager.

This phase may make inactive windows still visible if not hidden. It is an intermediate commit only if needed; ideally continue to phase 2 before final push.

### Phase 2: Hide/unhide inactive workspace windows

1. Add hide-in-corner helpers.
2. Hide old workspace windows on switch.
3. Unhide target workspace windows on switch.
4. Exclude hidden windows from active tiling.
5. Preserve last geometry.
6. Manual test heavily.

### Phase 3: Hotkeys/CLI polish

1. Wire all `desktop_*` hotkey actions to virtual workspace manager.
2. Add `desktop status` if time.
3. Update usage text.
4. Update `examples/config.lua`.
5. Update README packaging/usage docs.

### Phase 4: Robustness

1. Handle apps/windows that refuse AX movement.
2. If hide fails, keep window in active workspace or mark unmanaged.
3. Add logging for workspace transitions.
4. Avoid repeated layout loops caused by Panda’s own hide/unhide moves. Extend self-event suppression as needed.

## Detailed Event Flow Proposal

### On daemon startup

```zig
WorkspaceManager.init(allocator)
EventLoop.reconcileFocusedApp()
relayoutPid(focused_pid)
```

Inside relayout:

```zig
var live = SpaceState.init(allocator)
live.loadWindowsForScope(.all_apps_main_display, pid, screen)
workspace_manager.reconcileLive(live)
workspace_manager.activeIds -> allowed
live.retainOnlyWindowIds(allowed)
layout active live
```

### On `desktop 2`

Control socket receives `desktop 2`.

```zig
performDesktopCommand(.switch_to = 2)
old = wm.active
wm.prepareSwitch(old, 2)
hideWorkspace(old, live_snapshot)
wm.active = 2
unhideWorkspace(2, live_snapshot or refreshed snapshot)
relayoutActiveWorkspace()
focusRecentOrFirst()
```

Potential issue: hidden target windows may not appear in `CGWindowListOptionOnScreenOnly`. But AX `AXWindows` for running apps should still list them because they are offscreen, not minimized. Therefore unhide can find them by enumerating all running apps with `ax.listWindows`, not only on-screen CG windows.

Add a helper to load all managed windows by ID across running apps if needed.

## Discovering Hidden Offscreen Windows

Current `state.loadWindowsOnCurrentSpace` uses visible/current-space filtering to avoid hidden/offscreen windows. For virtual workspace unhide, we need a broader discovery function:

- `loadAllTileableWindowsForRunningApps` without current-space/visible filtering.
- Or a targeted lookup for specific window IDs.

Recommended:

Add to `state.zig`:

```zig
pub fn loadWindowsForRunningApps(self: *SpaceState, screen: ?Rect, visibility_filter: VisibilityFilter) !void
```

Where:

```zig
const VisibilityFilter = enum {
    visible_current_space,
    all_tileable,
};
```

For active tiling use `visible_current_space` plus workspace IDs.
For unhide use `all_tileable` to find hidden offscreen managed windows.

Be careful: all_tileable may include windows from other macOS Spaces. If Panda virtual workspaces coexist with macOS Spaces, this can get complex. For phase 1, assume user uses one macOS Space and Panda virtual workspaces.

## Hide Geometry Details

When hiding:

- Capture current frame.
- Capture screen frame.
- Compute proportional x/y:

```zig
proportional_x = (frame.x - screen.x) / screen.width
proportional_y = (frame.y - screen.y) / screen.height
```

Clamp 0..1.

Move to offscreen:

```zig
hidden_x = screen.x + screen.width + 8
hidden_y = screen.y + screen.height - frame.height - 8
```

If this causes certain apps to bounce back, try bottom-left:

```zig
hidden_x = screen.x - frame.width - 8
hidden_y = screen.y + screen.height - frame.height - 8
```

Potential config:

```lua
workspaces = { hide_corner = "bottom-right" }
```

But not needed at first.

## Avoiding “tiny corner” Bug

Do not resize hidden windows to tiny sizes. Only move position; preserve size. AeroSpace sets only top-left point when hiding, not size. Panda’s `ax.moveResizeWindow` currently sets both position and size. Add a new AX helper to set position only:

In `ax.zig`:

```zig
pub fn moveWindow(window: NativeWindowRef, x: f64, y: f64) Error!void
```

Or in `moveResizeWindow`, support optional size.

Recommended: add separate `setWindowPosition`.

In Objective-C? No need; AX position is already in Zig.

## Accessibility / App Identity

The user has had recurring TCC problems. Avoid LaunchAgent for now. The app wrapper starts daemon directly. Do not undo this.

If future work wants launch-at-login, use a proper signed app helper or SMAppService, not the current flaky LaunchAgent path.

## Update Feature Considerations

`panda update` currently downloads/replaces app and restarts. Ensure it does not break virtual workspace state unexpectedly.

If update runs while daemon active:

- Stop daemon.
- Replace app.
- Start daemon.
- Workspace state resets (acceptable phase 1).

## Documentation Updates Required

After implementation, update:

- `README.md`
- `examples/config.lua`
- `panda help` in `src/main.zig`

Document:

- Panda desktops are virtual workspaces.
- They are independent of macOS Mission Control Spaces.
- Default hotkeys.
- How to move windows between workspaces.
- Known limitation: state resets on daemon restart.

## Commit/Push Expectations

When done:

1. Run formatting:

```bash
zig fmt --check src/*.zig build.zig
```

2. Build DMG/package if changing app behavior:

```bash
scripts/package-dmg.sh
```

3. Avoid committing `.zig-cache` changes.

4. Commit with a clear message, e.g.

```bash
git commit -m "Add virtual workspaces"
```

5. Push.

## Major Risks

1. **AX identity instability**
   - Some windows may lack stable CGWindow IDs.
   - Exclude unstable windows to avoid losing assignments.

2. **Apps resisting offscreen moves**
   - Some apps may clamp windows to visible display.
   - Need fallback to other corner or mark unmanaged.

3. **macOS Spaces interaction**
   - If user changes real macOS Space, hidden windows may behave unexpectedly.
   - Phase 1 should assume one real macOS Space.

4. **Focus stealing**
   - Unhide/layout/focus can trigger app activation events and relayout loops.
   - Use self-event suppression windows.

5. **Performance**
   - Scanning all running apps for hidden windows can be expensive.
   - Cache pid/window relationships; use targeted lookup if possible.

## Suggested First Implementation Path

If I were implementing next:

1. Add `workspaces.zig` with pure data model and tests.
2. Wire `EventLoop` to own `WorkspaceManager`.
3. Change `performDesktopCommand` to update `WorkspaceManager`, no macOS shortcut posting.
4. Modify relayout to filter to active workspace.
5. Add `ax.setWindowPosition`.
6. Add hide/unhide methods in `events.zig` using live snapshots.
7. Test manually with two Ghostty windows and one browser window.
8. Add `desktop status`.
9. Update docs.
10. Rebuild DMG and push.

## Minimal Acceptance Criteria

The feature is acceptable when all of these are true:

- Opening `Panda.app` starts the daemon.
- `panda daemon-status` is responsive.
- `panda desktop 1..9` switches virtual workspaces with no macOS Mission Control dependency.
- `Option+!` through `Option+(` switch workspaces.
- Windows in inactive workspaces are not visible and not tiled.
- Switching back restores/tile windows correctly.
- `panda desktop move-2` moves the focused window to workspace 2.
- No windows are minimized/unminimized by workspace switching.
- No windows are resized tiny in a corner.
- Existing focus/swap/border commands still work on the active workspace.
- DMG builds successfully.
- Changes are committed and pushed.
