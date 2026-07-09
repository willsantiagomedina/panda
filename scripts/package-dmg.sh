#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="${APP_NAME:-Panda}"
BUNDLE_ID="${BUNDLE_ID:-dev.givepanda.app}"
DMG_NAME="${DMG_NAME:-panda-macos-arm64.dmg}"
DMG_VOLNAME="${DMG_VOLNAME:-Panda}"
ICON_PNG="${ICON_PNG:-$ROOT/assets/pandalogonew.png}"
PANDA_VERSION="${PANDA_VERSION:-}"
PANDA_MACOS_VERSION="${PANDA_MACOS_VERSION:-13.0}"
PANDA_CODESIGN_IDENTITY="${PANDA_CODESIGN_IDENTITY:-}"
PANDA_MACOS_SDK="${PANDA_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
ZIG_TARGET="aarch64-macos.$PANDA_MACOS_VERSION"

fail() { printf 'package-dmg: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

[[ "$PANDA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "PANDA_VERSION must be MAJOR.MINOR.PATCH"
[[ -n "$PANDA_CODESIGN_IDENTITY" ]] || fail "PANDA_CODESIGN_IDENTITY is required (use '-' explicitly for local ad-hoc builds)"
[[ -f "$ICON_PNG" ]] || fail "icon not found: $ICON_PNG"

for command in zig xcrun clang sips iconutil hdiutil shasum codesign; do need_cmd "$command"; done

mkdir -p "$DIST_DIR" "$ROOT/zig-out/bin"
tmp_build_dir=""
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
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
    -lobjc -lproc \
    -o "$ROOT/zig-out/bin/panda"
fi

BIN_PATH="$ROOT/zig-out/bin/panda"
[[ -x "$BIN_PATH" ]] || fail "binary not found after build: $BIN_PATH"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir" "$tmp_build_dir"' EXIT
APP_DIR="$tmp_dir/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$BIN_PATH" "$MACOS_DIR/panda-cli"
cp "$ICON_PNG" "$RESOURCES_DIR/PandaMascot.png"
cp "$ROOT/app/PandaChangelog.json" "$RESOURCES_DIR/PandaChangelog.json"
xcrun swiftc "$ROOT/app/PandaUI.swift" "$ROOT/app/ConfigStore.swift" \
  -parse-as-library \
  -swift-version 5 \
  -enable-bare-slash-regex \
  -target "arm64-apple-macosx$PANDA_MACOS_VERSION" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -o "$MACOS_DIR/PandaUI"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/panda-cli" "$MACOS_DIR/PandaUI"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>PandaUI</string>
  <key>CFBundleIconFile</key><string>PandaLogo</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$PANDA_VERSION</string>
  <key>CFBundleVersion</key><string>$PANDA_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$PANDA_MACOS_VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
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

codesign --force --options runtime --timestamp=none --sign "$PANDA_CODESIGN_IDENTITY" "$MACOS_DIR/Panda"
codesign --force --options runtime --timestamp=none --sign "$PANDA_CODESIGN_IDENTITY" "$MACOS_DIR/panda-cli"
codesign --force --options runtime --timestamp=none --sign "$PANDA_CODESIGN_IDENTITY" "$MACOS_DIR/PandaUI"
codesign --force --deep --options runtime --timestamp=none --sign "$PANDA_CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

stage_dir="$tmp_dir/stage"
mkdir -p "$stage_dir"
cp -R "$APP_DIR" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"

DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$stage_dir" -ov -format UDZO "$DMG_PATH" >/dev/null
(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

printf 'dmg: %s\n' "$DMG_PATH"
printf 'sha256: %s\n' "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
