#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="${APP_NAME:-Panda}"
BUNDLE_ID="${BUNDLE_ID:-dev.givepanda.app}"
DMG_NAME="${DMG_NAME:-panda-macos-universal.dmg}"
DMG_VOLNAME="${DMG_VOLNAME:-Panda}"
ICON_PNG="${ICON_PNG:-$ROOT/assets/pandalogonew.png}"
PANDA_MACOS_VERSION="${PANDA_MACOS_VERSION:-15.4}"
PANDA_MACOS_SDK="${PANDA_MACOS_SDK:-$(xcrun --sdk "macosx$PANDA_MACOS_VERSION" --show-sdk-path 2>/dev/null || xcrun --show-sdk-path)}"
PANDA_ARCH="${PANDA_ARCH:-$(uname -m)}"
tmp_build_dir=""

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
need_cmd clang
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
  tmp_build_dir="$(mktemp -d)"

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
fi

BIN_PATH="$ROOT/zig-out/bin/panda"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "binary not found after build: $BIN_PATH" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir" "$tmp_build_dir"' EXIT

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
APP_DIR="$(cd "$DIR/../.." && pwd)"
INSTALLED_APP="/Applications/Panda.app"

if [[ $# -gt 0 ]]; then
  exec "$DIR/panda-cli" "$@"
fi

if [[ "$APP_DIR" != "$INSTALLED_APP" && -d /Applications ]]; then
  if [[ -w /Applications ]]; then
    rm -rf "$INSTALLED_APP"
    cp -R "$APP_DIR" "$INSTALLED_APP"
  else
    /usr/bin/osascript - "$APP_DIR" <<'APPLESCRIPT'
on run argv
  set appPath to item 1 of argv
  do shell script "rm -rf /Applications/Panda.app && cp -R " & quoted form of appPath & " /Applications/Panda.app" with administrator privileges
end run
APPLESCRIPT
  fi
  xattr -dr com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1 || true
  exec "$INSTALLED_APP/Contents/MacOS/Panda"
fi

LOG_DIR="$HOME/Library/Logs"
mkdir -p "$LOG_DIR"

"$DIR/panda-cli" uninstall-daemon >/dev/null 2>&1 || true
pkill -f '/Applications/Panda.app/Contents/MacOS/panda-cli daemon' >/dev/null 2>&1 || true
pkill -f "$DIR/panda-cli daemon" >/dev/null 2>&1 || true

if ! "$DIR/panda-cli" permissions >/dev/null 2>&1; then
  "$DIR/panda-cli" permissions >/dev/null 2>&1 || true
fi

nohup "$DIR/panda-cli" daemon >>"$LOG_DIR/panda.log" 2>>"$LOG_DIR/panda.err.log" &
disown
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
  <string>panda-cli</string>
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
