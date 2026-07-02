#!/usr/bin/env bash

set -euo pipefail

PANDA_RELEASE_BASE_URL="${PANDA_RELEASE_BASE_URL:-https://givepanda.tech/releases/latest}"
PANDA_INSTALL_METHOD="${PANDA_INSTALL_METHOD:-auto}"
PANDA_FORCE_INSTALL="${PANDA_FORCE_INSTALL:-0}"
PANDA_APP_PATH="${PANDA_APP_PATH:-/Applications/Panda.app}"
PANDA_SKIP_LAUNCH="${PANDA_SKIP_LAUNCH:-0}"
PANDA_CASK="willsantiagomedina/tap/panda-app"

say() { printf 'ʕ•ᴥ•ʔ  %s\n' "$*"; }
fail() { printf 'panda install: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

start_panda() {
  if [[ "$PANDA_SKIP_LAUNCH" == "1" ]]; then return; fi
  local cli="$PANDA_APP_PATH/Contents/MacOS/panda-cli"
  [[ -x "$cli" ]] || fail "installed Panda CLI is missing"
  "$cli" install-daemon || fail "Panda was installed, but its daemon could not be started"
  open "$PANDA_APP_PATH" >/dev/null 2>&1 || true
}

require_supported_mac() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "Panda currently supports only macOS"
  [[ "$(uname -m)" == "arm64" ]] || fail "this Panda release supports Apple Silicon only"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 13 )) || fail "Panda requires macOS 13 Ventura or newer"
}

install_with_homebrew() {
  say "using Homebrew to install Panda"
  brew tap willsantiagomedina/tap
  brew update
  if brew help trust >/dev/null 2>&1; then
    brew trust --cask "$PANDA_CASK"
  fi
  if brew list --cask panda-app >/dev/null 2>&1; then
    if [[ "$PANDA_FORCE_INSTALL" == "1" ]]; then
      brew reinstall --cask "$PANDA_CASK"
    else
      brew upgrade --cask "$PANDA_CASK"
    fi
  else
    brew install --cask "$PANDA_CASK"
  fi
  xattr -dr com.apple.quarantine "$PANDA_APP_PATH" >/dev/null 2>&1 || true
  start_panda
  say "Panda is installed. Grant Accessibility once when macOS prompts."
}

install_direct() {
  for command in curl plutil shasum hdiutil codesign xattr open; do need_cmd "$command"; done

  local tmp_dir mount_dir manifest expected_sha actual_sha version source_app
  tmp_dir="$(mktemp -d)"
  mount_dir="$tmp_dir/mount"
  mkdir -p "$mount_dir"
  cleanup() {
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
  }
  trap cleanup EXIT

  manifest="$tmp_dir/panda-release.json"
  say "fetching the latest release manifest"
  curl -fsSL "$PANDA_RELEASE_BASE_URL/panda-release.json" -o "$manifest"
  version="$(plutil -extract version raw -o - "$manifest")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "release manifest contains an invalid version"
  [[ "$(plutil -extract architecture raw -o - "$manifest")" == "arm64" ]] || fail "release architecture is not arm64"
  expected_sha="$(plutil -extract dmg.sha256 raw -o - "$manifest")"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || fail "release manifest contains an invalid DMG checksum"

  if [[ -f "$PANDA_APP_PATH/Contents/Info.plist" && "$PANDA_FORCE_INSTALL" != "1" ]]; then
    current_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PANDA_APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$current_version" == "$version" ]]; then
      say "Panda $version is already installed"
      cleanup
      trap - EXIT
      return
    fi
  fi

  say "downloading Panda $version"
  curl -fsSL "$PANDA_RELEASE_BASE_URL/panda-macos-arm64.dmg" -o "$tmp_dir/panda.dmg"
  actual_sha="$(shasum -a 256 "$tmp_dir/panda.dmg" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "DMG checksum verification failed; the current app was not changed"

  hdiutil verify "$tmp_dir/panda.dmg" >/dev/null
  hdiutil attach "$tmp_dir/panda.dmg" -mountpoint "$mount_dir" -nobrowse -quiet
  source_app="$mount_dir/Panda.app"
  [[ -d "$source_app" ]] || fail "DMG does not contain Panda.app"
  codesign --verify --deep --strict "$source_app" || fail "downloaded app signature verification failed"
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$source_app/Contents/Info.plist")" == "$version" ]] || fail "app version does not match release manifest"

  local app_parent
  app_parent="$(dirname "$PANDA_APP_PATH")"
  local use_sudo=0
  if [[ ! -w "$app_parent" ]]; then
    say "administrator access is required to install into $app_parent"
    sudo -v
    use_sudo=1
  fi
  install_cmd() {
    if [[ "$use_sudo" == "1" ]]; then sudo "$@"; else "$@"; fi
  }

  local staged backup
  staged="$app_parent/.Panda.app.new.$$"
  backup="$app_parent/.Panda.app.backup.$$"
  install_cmd rm -rf "$staged" "$backup"
  install_cmd cp -R "$source_app" "$staged"
  codesign --verify --deep --strict "$staged" || fail "staged app signature verification failed"

  if [[ "$PANDA_APP_PATH" == "/Applications/Panda.app" ]]; then
    if [[ -x "$PANDA_APP_PATH/Contents/MacOS/panda-cli" ]]; then
      "$PANDA_APP_PATH/Contents/MacOS/panda-cli" uninstall-daemon >/dev/null 2>&1 || true
    fi
    pkill -f '/Applications/Panda.app/Contents/MacOS/Panda daemon' >/dev/null 2>&1 || true
    pkill -f '/Applications/Panda.app/Contents/MacOS/panda-cli daemon' >/dev/null 2>&1 || true
  fi

  if [[ -e "$PANDA_APP_PATH" ]]; then
    install_cmd mv "$PANDA_APP_PATH" "$backup"
  fi
  if ! install_cmd mv "$staged" "$PANDA_APP_PATH"; then
    [[ -e "$backup" ]] && install_cmd mv "$backup" "$PANDA_APP_PATH"
    fail "installation failed; the previous app was restored"
  fi
  install_cmd xattr -dr com.apple.quarantine "$PANDA_APP_PATH" >/dev/null 2>&1 || true
  codesign --verify --deep --strict "$PANDA_APP_PATH" || {
    install_cmd rm -rf "$PANDA_APP_PATH"
    [[ -e "$backup" ]] && install_cmd mv "$backup" "$PANDA_APP_PATH"
    fail "installed app verification failed; the previous app was restored"
  }
  "$PANDA_APP_PATH/Contents/MacOS/panda-cli" help >/dev/null 2>&1 || {
    install_cmd rm -rf "$PANDA_APP_PATH"
    [[ -e "$backup" ]] && install_cmd mv "$backup" "$PANDA_APP_PATH"
    fail "the new app could not start; the previous app was restored"
  }
  if [[ "$PANDA_SKIP_LAUNCH" != "1" ]] && ! "$PANDA_APP_PATH/Contents/MacOS/panda-cli" install-daemon; then
    install_cmd rm -rf "$PANDA_APP_PATH"
    [[ -e "$backup" ]] && install_cmd mv "$backup" "$PANDA_APP_PATH"
    fail "the new daemon did not start; the previous app was restored"
  fi
  if [[ "$PANDA_SKIP_LAUNCH" != "1" ]]; then open "$PANDA_APP_PATH" >/dev/null 2>&1 || true; fi
  install_cmd rm -rf "$backup"
  say "Panda $version is installed. Grant Accessibility once when macOS prompts."
  cleanup
  trap - EXIT
}

main() {
  require_supported_mac
  case "$PANDA_INSTALL_METHOD" in
    auto)
      if command -v brew >/dev/null 2>&1; then install_with_homebrew; else install_direct; fi
      ;;
    homebrew)
      need_cmd brew
      install_with_homebrew
      ;;
    direct)
      install_direct
      ;;
    *) fail "PANDA_INSTALL_METHOD must be auto, homebrew, or direct" ;;
  esac
}

main "$@"
