#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="${APP_NAME:-Panda}"
BUNDLE_ID="${BUNDLE_ID:-dev.givepanda.app}"
DMG_NAME="${DMG_NAME:-panda-macos-universal.dmg}"
DMG_VOLNAME="${DMG_VOLNAME:-Panda}"
ICON_PNG="${ICON_PNG:-$ROOT/assets/Pandalogo.png}"
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need_cmd zig
need_cmd xcrun
need_cmd sips
need_cmd iconutil
need_cmd hdiutil
need_cmd shasum

if [[ ! -f "$ICON_PNG" ]]; then
  echo "icon not found: $ICON_PNG" >&2
  exit 1
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
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
    -femit-bin="$ROOT/zig-out/bin/panda"
fi

BIN_PATH="$ROOT/zig-out/bin/panda"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "binary not found after build: $BIN_PATH" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

APP_DIR="$tmp_dir/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/panda-cli"
chmod +x "$MACOS_DIR/panda-cli"

cat > "$MACOS_DIR/$APP_NAME" <<'EOF'
#!/bin/zsh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/panda-cli" daemon
EOF
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>PandaLogo</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0</string>
  <key>CFBundleVersion</key>
  <string>0.0.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

iconset_dir="$tmp_dir/Panda.iconset"
mkdir -p "$iconset_dir"

sips -z 16 16 "$ICON_PNG" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$iconset_dir" -o "$RESOURCES_DIR/PandaLogo.icns"

stage_dir="$tmp_dir/stage"
mkdir -p "$stage_dir"
cp -R "$APP_DIR" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"

DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"

hdiutil create \
  -volname "$DMG_VOLNAME" \
  -srcfolder "$stage_dir" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$DMG_PATH.sha256"

echo "dmg: $DMG_PATH"
echo "sha256: $(cat "$DMG_PATH.sha256")"
