# panda

A fast macOS tiling window manager CLI/daemon written in Zig.

## Quick start

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/panda daemon
```

In another shell:

```bash
panda focus right
panda swap right
panda border toggle
panda desktop next
```

## Config (Lua-style)

panda reads:

- `~/.config/panda/config.lua`
- or `$PANDA_CONFIG` if set

A ready-to-copy example is in `examples/config.lua`.

Config supports:

- default `scope` and `layout`
- `border` default
- performance timing knobs
- desktop key chord mappings (`desktop` table)
- optional global daemon hotkeys (`shortcuts` table)

## Packaging

- `scripts/package-release.sh` builds the universal tarball artifact (+ DMG by default).
- `scripts/package-dmg.sh` builds `Panda.app` + `.dmg` (using `assets/Pandalogo.png`).
- `scripts/download-dmg.sh` downloads the latest DMG to `~/Downloads`.

Online DMG download script:

```bash
curl -fsSL https://givepanda.tech/download-dmg.sh | bash
```

If the short download route is unavailable, the script is also served directly:

```bash
curl -fsSL https://givepanda.tech/scripts/download-dmg.sh | bash
```

Stable release artifact URLs:

- `https://givepanda.tech/releases/latest/panda-macos-universal.dmg`
- `https://givepanda.tech/releases/latest/panda-macos-universal.tar.gz`
