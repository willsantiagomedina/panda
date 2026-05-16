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

command -v zig >/dev/null 2>&1 || { echo "missing required command: zig" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "missing required command: xcrun" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "missing required command: clang" >&2; exit 1; }

mkdir -p "$ROOT/zig-out/bin"
tmp_build_dir="$(mktemp -d)"
tmp_dir=""
trap 'rm -rf "$tmp_dir" "$tmp_build_dir"' EXIT

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
  -mmacosx-version-min="$PANDA_MACOS_VERSION" \
  -o "$tmp_build_dir/frontmost.o"

clang "$tmp_build_dir/main.o" "$tmp_build_dir/frontmost.o" \
  -isysroot "$PANDA_MACOS_SDK" \
  -mmacosx-version-min="$PANDA_MACOS_VERSION" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework Carbon \
  -framework Foundation \
  -framework QuartzCore \
  -lobjc \
  -lproc \
  -o "$ROOT/zig-out/bin/panda"

tmp_dir="$(mktemp -d)"
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
