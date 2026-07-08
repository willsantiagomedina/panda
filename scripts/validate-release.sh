#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
PANDA_VERSION="${PANDA_VERSION:-}"
DMG_NAME="panda-macos-arm64.dmg"
ARCHIVE_NAME="panda-macos-arm64.tar.gz"
MANIFEST_NAME="panda-release.json"

fail() { printf 'validate-release: %s\n' "$*" >&2; exit 1; }
[[ "$PANDA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "PANDA_VERSION must be MAJOR.MINOR.PATCH"

for file in "$DMG_NAME" "$DMG_NAME.sha256" "$ARCHIVE_NAME" "$ARCHIVE_NAME.sha256" "$MANIFEST_NAME"; do
  [[ -s "$DIST_DIR/$file" ]] || fail "missing artifact: $file"
done

(
  cd "$DIST_DIR"
  shasum -a 256 -c "$DMG_NAME.sha256"
  shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)
hdiutil verify "$DIST_DIR/$DMG_NAME" >/dev/null

mount_dir="$(mktemp -d)"
extract_dir="$(mktemp -d)"
cleanup() {
  hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  rm -rf "$mount_dir" "$extract_dir"
}
trap cleanup EXIT
hdiutil attach "$DIST_DIR/$DMG_NAME" -mountpoint "$mount_dir" -nobrowse -quiet

app="$mount_dir/Panda.app"
[[ -d "$app" ]] || fail "DMG does not contain Panda.app"
[[ -L "$mount_dir/Applications" ]] || fail "DMG does not contain Applications symlink"
[[ "$(file -b "$app/Contents/MacOS/Panda")" == *"arm64"* ]] || fail "Panda executable is not arm64"
[[ -x "$app/Contents/MacOS/PandaUI" ]] || fail "PandaUI executable is missing"
[[ "$(file -b "$app/Contents/MacOS/PandaUI")" == *"arm64"* ]] || fail "PandaUI executable is not arm64"
[[ -s "$app/Contents/Resources/PandaMascot.png" ]] || fail "Panda mascot resource is missing"
[[ -s "$app/Contents/Resources/PandaChangelog.json" ]] || fail "Panda changelog resource is missing"
/usr/bin/python3 -m json.tool "$app/Contents/Resources/PandaChangelog.json" >/dev/null || fail "Panda changelog is invalid JSON"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "$PANDA_VERSION" ]] || fail "bundle short version mismatch"
[[ "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" == "$PANDA_VERSION" ]] || fail "bundle version mismatch"
[[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")" == "13.0" ]] || fail "minimum macOS mismatch"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict "$app/Contents/MacOS/Panda"
codesign --verify --strict "$app/Contents/MacOS/panda-cli"
codesign --verify --strict "$app/Contents/MacOS/PandaUI"
"$app/Contents/MacOS/panda-cli" help >/dev/null 2>&1

minos="$(otool -l "$app/Contents/MacOS/Panda" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
[[ "$minos" == "13.0" ]] || fail "binary deployment target is $minos, expected 13.0"

tar -xzf "$DIST_DIR/$ARCHIVE_NAME" -C "$extract_dir"
[[ -x "$extract_dir/panda" ]] || fail "CLI archive is missing panda"
[[ "$(file -b "$extract_dir/panda")" == *"arm64"* ]] || fail "CLI archive is not arm64"
codesign --verify --strict "$extract_dir/panda"
"$extract_dir/panda" help >/dev/null 2>&1

[[ "$(plutil -extract version raw -o - "$DIST_DIR/$MANIFEST_NAME")" == "$PANDA_VERSION" ]] || fail "manifest version mismatch"
[[ "$(plutil -extract architecture raw -o - "$DIST_DIR/$MANIFEST_NAME")" == "arm64" ]] || fail "manifest architecture mismatch"
[[ "$(plutil -extract minimum_macos raw -o - "$DIST_DIR/$MANIFEST_NAME")" == "13.0" ]] || fail "manifest minimum macOS mismatch"

expected_dmg_sha="$(plutil -extract dmg.sha256 raw -o - "$DIST_DIR/$MANIFEST_NAME")"
expected_archive_sha="$(plutil -extract archive.sha256 raw -o - "$DIST_DIR/$MANIFEST_NAME")"
actual_dmg_sha="$(shasum -a 256 "$DIST_DIR/$DMG_NAME" | awk '{print $1}')"
actual_archive_sha="$(shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME" | awk '{print $1}')"
[[ "$expected_dmg_sha" == "$actual_dmg_sha" ]] || fail "manifest DMG checksum mismatch"
[[ "$expected_archive_sha" == "$actual_archive_sha" ]] || fail "manifest archive checksum mismatch"

printf 'validate-release: all release artifacts are valid\n'
