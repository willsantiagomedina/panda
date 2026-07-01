<p align="center">
  <img src="assets/pandalogonew.png" alt="Panda app logo" width="148" />
</p>
<h1 align="center">Panda</h1>
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

Panda supports Apple Silicon Macs running macOS 13 Ventura or newer.

### Recommended

```bash
curl -fsSL https://givepanda.tech/install.sh | bash
```

The installer uses the Panda Homebrew cask when Homebrew is available. Otherwise it downloads the DMG, verifies its release-manifest SHA-256, validates the app signature, and installs it directly.

### Homebrew

```bash
brew trust --cask willsantiagomedina/tap/panda-app
brew install --cask willsantiagomedina/tap/panda-app
```

The compatibility URL `https://givepanda.tech/download-dmg.sh` invokes the same verified installer.

### Release artifacts

- DMG: `https://givepanda.tech/releases/latest/panda-macos-arm64.dmg`
- CLI tarball: `https://givepanda.tech/releases/latest/panda-macos-arm64.tar.gz`
- Manifest: `https://givepanda.tech/releases/latest/panda-release.json`

---

## 🔐 Accessibility permission

Panda manages real macOS windows, so macOS must allow it to use Accessibility APIs.

After installing, open:

```text
System Settings → Privacy & Security → Accessibility
```

Enable `Panda.app` or the `panda` binary. If Panda is already listed but does not respond, remove the old entry and add `/Applications/Panda.app` again.

Panda uses a stable self-signed code identity so macOS can preserve this approval across updates. Homebrew removes the quarantine attribute, but neither Homebrew nor Panda can grant Accessibility automatically. Panda is not Apple-notarized.

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
| `panda update [--force]` | Upgrade through Homebrew or the verified direct installer. |

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
| `scripts/package-dmg.sh` | Build and sign `Panda.app` inside the arm64 DMG. |
| `scripts/validate-release.sh` | Validate release checksums, architecture, versions, signatures, and DMG layout. |

---

## 📦 Packaging

Build an ad-hoc signed local release for validation:

```bash
PANDA_VERSION=0.1.0 PANDA_CODESIGN_IDENTITY=- scripts/package-release.sh
PANDA_VERSION=0.1.0 scripts/validate-release.sh
```

Production tags use the long-lived `panda-codesign-certificate` imported by GitHub Actions. Build only the app DMG from an existing binary with:

```bash
PANDA_VERSION=0.1.0 \
PANDA_CODESIGN_IDENTITY=panda-codesign-certificate \
SKIP_BUILD=1 scripts/package-dmg.sh
```

Packaging outputs land in `dist/`:

- `panda-macos-arm64.tar.gz`
- `panda-macos-arm64.tar.gz.sha256`
- `panda-macos-arm64.dmg`
- `panda-macos-arm64.dmg.sha256`
- `panda-release.json`

`scripts/package-dmg.sh` uses `assets/pandalogonew.png` to generate the `Panda.app` icon set.

### Publishing a release

Releases are created only from semantic-version tags reachable from `main`:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow tests and packages Panda on GitHub's macOS ARM runner, publishes a GitHub Release, marks it latest, and updates `willsantiagomedina/homebrew-tap`.

Required repository secrets:

- `PANDA_CODESIGN_P12_BASE64` — base64-encoded export of the stable self-signed certificate and private key.
- `PANDA_CODESIGN_P12_PASSWORD` — the export password.
- `HOMEBREW_TAP_DEPLOY_KEY` — an SSH deploy key whose public half has write access to the tap repository.

The signing certificate must retain the name `panda-codesign-certificate`. Back it up securely; replacing it changes Panda's macOS code identity.

See [`docs/releasing.md`](docs/releasing.md) for certificate creation, deploy-key setup, local validation, and release recovery instructions.

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

- `/install.sh` serves the verified installer.
- `/download-dmg.sh` remains a compatibility installer alias.
- `/releases/latest/*` redirects to the latest GitHub Release assets.
- Legacy `panda-macos-universal.*` URLs redirect to the arm64 artifacts.

See `vercel.json` for the current routing.

---

<p align="center">
  <img src="assets/pandalogonew.png" alt="Panda icon" width="72" />
  <br />
  <strong>Make your windows behave. Keep your desktop cute.</strong>
</p>
