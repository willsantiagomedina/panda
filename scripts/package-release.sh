#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
ARCHIVE_NAME="${ARCHIVE_NAME:-panda-macos-universal.tar.gz}"
BUILD_DMG="${BUILD_DMG:-1}"
PANDA_MACOS_VERSION="${PANDA_MACOS_VERSION:-15.4}"
PANDA_MACOS_SDK="${PANDA_MACOS_SDK:-$(xcrun --sdk "macosx$PANDA_MACOS_VERSION" --show-sdk-path 2>/dev/null || xcrun --show-sdk-path)}"
PANDA_ARCH="${PANDA_ARCH:-$(uname -m)}"

case "$PANDA_ARCH" in
  arm64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *) echo "unsupported macOS arch: $PANDA_ARCH" >&2; exit 1 ;;
esac

ZIG_TARGET="${ZIG_TARGET:-$ZIG_ARCH-macos.$PANDA_MACOS_VERSION}"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME.sha256"

mkdir -p "$ROOT/zig-out/bin"
zig build-exe \
  "$ROOT/src/main.zig" \
  "$ROOT/src/frontmost.m" \
  -I "$ROOT/src" \
  -target "$ZIG_TARGET" \
  -O ReleaseFast \
  -F "$PANDA_MACOS_SDK/System/Library/Frameworks" \
  -I "$PANDA_MACOS_SDK/usr/include" \
  -L "$PANDA_MACOS_SDK/usr/lib" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework Carbon \
  -framework Foundation \
  -framework QuartzCore \
  -lobjc \
  -lproc \
  -lc \
  -femit-bin="$ROOT/zig-out/bin/panda"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cp "$ROOT/zig-out/bin/panda" "$tmp_dir/panda"
chmod +x "$tmp_dir/panda"

(
  cd "$tmp_dir"
  tar -czf "$DIST_DIR/$ARCHIVE_NAME" panda
)

shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME" | awk '{print $1}' > "$DIST_DIR/$ARCHIVE_NAME.sha256"

printf 'archive: %s\n' "$DIST_DIR/$ARCHIVE_NAME"
printf 'sha256: %s\n' "$(cat "$DIST_DIR/$ARCHIVE_NAME.sha256")"

if [[ "$BUILD_DMG" == "1" ]]; then
  SKIP_BUILD=1 DIST_DIR="$DIST_DIR" "$ROOT/scripts/package-dmg.sh"
fi
