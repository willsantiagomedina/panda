#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
ARCHIVE_NAME="${ARCHIVE_NAME:-panda-macos-universal.tar.gz}"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME.sha256"

(
  cd "$ROOT"
  zig build -Doptimize=ReleaseFast
)

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
