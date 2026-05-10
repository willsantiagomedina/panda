#!/usr/bin/env bash

set -euo pipefail

APP_NAME="${APP_NAME:-Panda}"
BUNDLE_ID="${BUNDLE_ID:-dev.givepanda.app}"
APP_PATH="${APP_PATH:-/Applications/$APP_NAME.app}"
BIN_PATH="$APP_PATH/Contents/MacOS/panda-cli"
DMG_PATH="${1:-}"

say() { printf '%s\n' "$*"; }
fail() { say "verify: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

need_cmd hdiutil

if [[ -n "$DMG_PATH" ]]; then
  [[ -f "$DMG_PATH" ]] || fail "dmg not found: $DMG_PATH"
  mnt="$(mktemp -d)"
  trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rmdir "$mnt" >/dev/null 2>&1 || true' EXIT
  hdiutil attach -nobrowse -mountpoint "$mnt" "$DMG_PATH" >/dev/null
  [[ -d "$mnt/$APP_NAME.app" ]] || fail "DMG does not contain $APP_NAME.app"
  [[ -L "$mnt/Applications" ]] || fail "DMG does not contain Applications symlink"
  say "ok: DMG layout looks correct ($DMG_PATH)"
  hdiutil detach "$mnt" >/dev/null
  rmdir "$mnt" >/dev/null 2>&1 || true
  trap - EXIT
fi

[[ -d "$APP_PATH" ]] || fail "app not installed at $APP_PATH"
[[ -x "$BIN_PATH" ]] || fail "binary missing or not executable: $BIN_PATH"

if ! pgrep -f "$BIN_PATH daemon" >/dev/null 2>&1; then
  fail "daemon process not running"
fi

say "ok: app installed: $APP_PATH"
say "ok: daemon process running"
say "ok: install verification passed"
