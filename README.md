# 🐼 Panda

<p align="center">
  <img src="assets/pandalogonew.png" alt="Panda app logo" width="148" />
</p>

<p align="center">
  <strong>A cozy, fast macOS tiling window manager written in Zig.</strong>
  <br />
  Panda runs as a tiny CLI + background daemon, tiles your windows, gives you keyboard-first focus/swap controls,
  and adds Panda-managed virtual workspaces that do not depend on Mission Control Spaces.
</p>

<p align="center">
  <a href="https://ziglang.org/"><img alt="Zig" src="https://img.shields.io/badge/Zig-0.15.2-f7a41d?style=for-the-badge&logo=zig&logoColor=white"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-ventura%2B-111827?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Status" src="https://img.shields.io/badge/status-active-22c55e?style=for-the-badge">
</p>

---

## ✨ What Panda does

Panda is for macOS users who want a lightweight, keyboard-driven window workflow without giving up native apps.

| Feature | What it means |
| --- | --- |
| 🧱 Tiling layouts | Automatically arrange windows with BSP, grid, or master-stack layouts. |
| 🧭 Directional focus | Jump between tiled windows with `panda focus left/right/up/down`. |
| 🔁 Window swapping | Reorder tiled windows from the keyboard with `panda swap ...`. |
| 🖥️ Virtual workspaces | Use `panda desktop 1..9` as Panda-managed workspaces, independent of Mission Control. |
| 🎀 Active borders | Toggle a simple active-window border overlay from the daemon. |
| ⚙️ Lua-style config | Configure scope, layout, performance tuning, workspace chords, and global shortcuts. |
| 📦 App + CLI packaging | Ship as a CLI tarball or as `Panda.app` inside a DMG. |

Panda is intentionally small: the core is Zig, the macOS bridge is Objective-C, and the runtime control path is a local per-user Unix socket.

---

## 🚀 Install

### DMG install

Download the latest DMG and open it:

```bash
curl -fsSL https://givepanda.tech/download-dmg.sh | bash
```

If the short route is unavailable, use the script directly:

```bash
curl -fsSL https://givepanda.tech/scripts/download-dmg.sh | bash
```

Then drag `Panda.app` into `/Applications` if prompted and open it once. Opening the app starts Panda as a per-user background service.

### CLI install

```bash
curl -fsSL https://givepanda.tech/install.sh | bash
```

### Homebrew

```bash
brew install willsantiago/tap/panda
```

### Release artifacts

- DMG: `https://givepanda.tech/releases/latest/panda-macos-universal.dmg`
- CLI tarball: `https://givepanda.tech/releases/latest/panda-macos-universal.tar.gz`

---

## 🔐 Accessibility permission

Panda manages real macOS windows, so macOS must allow it to use Accessibility APIs.

After installing, open:

```text
System Settings → Privacy & Security → Accessibility
```

Enable `Panda.app` or the `panda` binary. If Panda is already listed but does not respond, remove the old entry and add `/Applications/Panda.app` again.

Check the daemon after granting permission:

```bash
panda daemon-status
```

---

## ⚡ Quick start from source

Requirements:

- macOS
- Zig `0.15.2` matching `build.zig.zon` and the current build script
- Xcode Command Line Tools for Objective-C/framework linking

Build and start the daemon:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/panda install-daemon
```

Try a few runtime commands:

```bash
panda focus right
panda swap right
panda border toggle
panda desktop next
panda desktop move-2
panda desktop status
```

Install the development binary into `~/.local/bin`:

```bash
zig build install-cli -Doptimize=ReleaseFast
```

---

## 🕹️ Everyday commands

| Command | Description |
| --- | --- |
| `panda install-daemon` | Install and start Panda as a per-user LaunchAgent. |
| `panda uninstall-daemon` | Stop and remove the LaunchAgent. |
| `panda daemon-status` | Check LaunchAgent and control socket health. |
| `panda permissions` | Prompt/open Accessibility permission help. |
| `panda focus left\|right\|up\|down` | Focus the nearest tiled window in a direction. |
| `panda swap left\|right\|up\|down` | Swap/reorder the focused window in a direction. |
| `panda border on\|off\|toggle\|status` | Control active-window border overlays. |
| `panda desktop 1..9` | Switch to a Panda virtual workspace. |
| `panda desktop next\|prev` | Cycle virtual workspaces. |
| `panda desktop move-1..move-9` | Move the focused window to another workspace. |
| `panda desktop move-next\|move-prev` | Move the focused window to the next/previous workspace. |
| `panda desktop status` | Print active workspace and window counts. |
| `panda tile PID_OR_APP` | Manually tile a target app/window scope. |
| `panda apps` | List running GUI apps Panda can target. |
| `panda active` | Show the current frontmost app. |
| `panda config` | Show the resolved config path and load status. |

---

## 🖥️ Virtual workspaces

Panda's `desktop` commands are logical workspaces owned by Panda, not macOS Mission Control Spaces.

- `panda desktop 1` through `panda desktop 9` switch workspaces.
- `panda desktop move-3` moves the focused window to workspace 3.
- `panda desktop next` / `prev` wrap through all 9 workspaces.
- Workspace state is in memory and resets when the daemon restarts.

Default workspace hotkeys:

| Action | Default chord |
| --- | --- |
| Switch workspace 1–9 | `Option` + `1` … `9` |
| Move focused window to workspace 1–9 | `Option` + `Shift` + `1` … `9` |
| Previous / next workspace | `Control` + `Left` / `Right` |
| Move to previous / next workspace | `Control` + `Shift` + `Left` / `Right` |

You can override these in `~/.config/panda/config.lua`.

---

## 🎛️ Configuration

Panda reads configuration from:

1. `$PANDA_CONFIG`, if set
2. `~/.config/panda/config.lua`

A complete starter config lives at `examples/config.lua`.

```lua
return {
  scope = "all-main-display", -- focused-app | all-main-display
  layout = "bsp",             -- bsp | grid | master-stack
  border = true,

  desktop = {
    switch_1 = "option+1",
    switch_2 = "option+2",
    move_1 = "option+shift+1",
    move_2 = "option+shift+2",
  },

  shortcuts = {
    focus_left = "alt+h",
    focus_down = "alt+j",
    focus_up = "alt+k",
    focus_right = "alt+l",
    border_toggle = "alt+b",
  },
}
```

Config supports:

- default tiling `scope`
- default `layout`
- border visibility
- performance/debounce timings
- virtual workspace key chords via `desktop`
- optional daemon-managed global shortcuts via `shortcuts`

---

## 🧩 Layout modes

Panda currently ships three layout modes:

| Layout | Best for |
| --- | --- |
| `bsp` | Balanced recursive splits with cozy gaps; the default. |
| `grid` | Evenly distributed windows. |
| `master-stack` | One primary window plus a stack of secondary windows. |

Use a layout at runtime:

```bash
panda tile active --layout grid
panda tile Safari --scope focused-app --layout master-stack
```

Or make it the default in config:

```lua
return {
  layout = "master-stack",
}
```

---

## 🛠️ Development

### Build

```bash
zig build
```

### Compile check

```bash
zig build check
```

### Test

```bash
zig build test
```

### Run the daemon locally

```bash
zig build run -- daemon --scope all-main-display --layout bsp
```

### Useful project paths

| Path | Purpose |
| --- | --- |
| `src/main.zig` | CLI parsing, daemon install/update, app-bundle startup behavior. |
| `src/events.zig` | Daemon event loop, control socket, hotkeys, focus/swap/workspace orchestration. |
| `src/workspaces.zig` | In-memory Panda virtual workspace model. |
| `src/state.zig` | Window discovery, filtering, ordering, and space state. |
| `src/layout.zig` | Layout placement calculation and application. |
| `src/ax.zig` | Zig wrapper around Accessibility, CoreGraphics, and Objective-C helpers. |
| `src/frontmost.m` / `src/frontmost.h` | AppKit, AX, Carbon hotkeys, desktop/window queries, and border overlays. |
| `examples/config.lua` | Full Lua-style config example. |
| `scripts/package-release.sh` | Build CLI tarball and, by default, the DMG. |
| `scripts/package-dmg.sh` | Build `Panda.app` and `panda-macos-universal.dmg` using the app logo. |

---

## 📦 Packaging

Build the release tarball and DMG:

```bash
scripts/package-release.sh
```

Build only the app DMG from an existing binary:

```bash
SKIP_BUILD=1 scripts/package-dmg.sh
```

Packaging outputs land in `dist/`:

- `panda-macos-universal.tar.gz`
- `panda-macos-universal.tar.gz.sha256`
- `panda-macos-universal.dmg`
- `panda-macos-universal.dmg.sha256`

`scripts/package-dmg.sh` uses `assets/pandalogonew.png` to generate the `Panda.app` icon set.

---

## 🧯 Troubleshooting

### `panda daemon is not running`

Start or restart the LaunchAgent:

```bash
panda install-daemon
panda daemon-status
```

### Panda cannot move or focus windows

Re-check Accessibility permissions:

```bash
panda permissions
```

Then enable Panda in:

```text
System Settings → Privacy & Security → Accessibility
```

### Check logs

```bash
tail -f ~/Library/Logs/panda.log
tail -f ~/Library/Logs/panda.err.log
```

### Reset the service

```bash
panda uninstall-daemon
panda install-daemon
```

---

## 🌐 Distribution site

The release site is served from this repo with Vercel rewrites:

- `/download-dmg.sh` → `scripts/download-dmg.sh`
- `/releases/latest/*` → `dist/*`

See `vercel.json` for the current routing.

---

<p align="center">
  <img src="assets/pandalogonew.png" alt="Panda icon" width="72" />
  <br />
  <strong>Make your windows behave. Keep your desktop cute.</strong>
</p>
