#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
PANDA_VERSION="${PANDA_VERSION:-}"
PANDA_GIT_SHA="${PANDA_GIT_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
PANDA_MACOS_VERSION="${PANDA_MACOS_VERSION:-13.0}"
PANDA_CODESIGN_IDENTITY="${PANDA_CODESIGN_IDENTITY:-}"
ARCHIVE_NAME="${ARCHIVE_NAME:-panda-macos-arm64.tar.gz}"
BUILD_DMG="${BUILD_DMG:-1}"
PANDA_MACOS_SDK="${PANDA_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
ZIG_TARGET="aarch64-macos.$PANDA_MACOS_VERSION"

fail() { printf 'package-release: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

[[ "$PANDA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "PANDA_VERSION must be MAJOR.MINOR.PATCH"
[[ "$PANDA_GIT_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || fail "PANDA_GIT_SHA must be a full commit SHA"
[[ -n "$PANDA_CODESIGN_IDENTITY" ]] || fail "PANDA_CODESIGN_IDENTITY is required (use '-' explicitly for local ad-hoc builds)"

need_cmd zig
need_cmd xcrun
need_cmd clang
need_cmd shasum

mkdir -p "$DIST_DIR" "$ROOT/zig-out/bin"
rm -f \
  "$DIST_DIR/$ARCHIVE_NAME" \
  "$DIST_DIR/$ARCHIVE_NAME.sha256" \
  "$DIST_DIR/panda-macos-arm64.dmg" \
  "$DIST_DIR/panda-macos-arm64.dmg.sha256" \
  "$DIST_DIR/panda-release.json"

tmp_build_dir="$(mktemp -d)"
tmp_archive_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_build_dir" "$tmp_archive_dir"' EXIT

zig build-obj \
  "$ROOT/src/main.zig" \
  -I "$ROOT/src" \
  -target "$ZIG_TARGET" \
  -O ReleaseFast \
  -F "$PANDA_MACOS_SDK/System/Library/Frameworks" \
  -I "$PANDA_MACOS_SDK/usr/include" \
  -femit-bin="$tmp_build_dir/main.o"

clang -c "$ROOT/src/frontmost.m" \
  -I "$ROOT/src" \
  -isysroot "$PANDA_MACOS_SDK" \
  -arch arm64 \
  -mmacosx-version-min="$PANDA_MACOS_VERSION" \
  -o "$tmp_build_dir/frontmost.o"

clang "$tmp_build_dir/main.o" "$tmp_build_dir/frontmost.o" \
  -isysroot "$PANDA_MACOS_SDK" \
  -arch arm64 \
  -mmacosx-version-min="$PANDA_MACOS_VERSION" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework Carbon \
  -framework Foundation \
  -framework QuartzCore \
  -framework UserNotifications \
  -lobjc \
  -lproc \
  -o "$ROOT/zig-out/bin/panda"

cp "$ROOT/zig-out/bin/panda" "$tmp_archive_dir/panda"
chmod +x "$tmp_archive_dir/panda"
codesign --force --options runtime --timestamp=none --sign "$PANDA_CODESIGN_IDENTITY" "$tmp_archive_dir/panda"

tar -C "$tmp_archive_dir" -czf "$DIST_DIR/$ARCHIVE_NAME" panda
(
  cd "$DIST_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

if [[ "$BUILD_DMG" == "1" ]]; then
  SKIP_BUILD=1 \
    DIST_DIR="$DIST_DIR" \
    PANDA_VERSION="$PANDA_VERSION" \
    PANDA_MACOS_VERSION="$PANDA_MACOS_VERSION" \
    PANDA_CODESIGN_IDENTITY="$PANDA_CODESIGN_IDENTITY" \
    "$ROOT/scripts/package-dmg.sh"
fi

archive_sha="$(shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME" | awk '{print $1}')"
dmg_name="panda-macos-arm64.dmg"
dmg_sha=""
if [[ "$BUILD_DMG" == "1" ]]; then
  dmg_sha="$(shasum -a 256 "$DIST_DIR/$dmg_name" | awk '{print $1}')"
fi

cat > "$DIST_DIR/panda-release.json" <<EOF
{
  "schema_version": 1,
  "version": "$PANDA_VERSION",
  "git_sha": "$PANDA_GIT_SHA",
  "architecture": "arm64",
  "minimum_macos": "$PANDA_MACOS_VERSION",
  "dmg": {
    "filename": "$dmg_name",
    "sha256": "$dmg_sha"
  },
  "archive": {
    "filename": "$ARCHIVE_NAME",
    "sha256": "$archive_sha"
  }
}
EOF

printf 'archive: %s\n' "$DIST_DIR/$ARCHIVE_NAME"
printf 'archive sha256: %s\n' "$archive_sha"
if [[ "$BUILD_DMG" == "1" ]]; then
  printf 'dmg: %s\n' "$DIST_DIR/$dmg_name"
  printf 'dmg sha256: %s\n' "$dmg_sha"
fi
printf 'manifest: %s\n' "$DIST_DIR/panda-release.json"
