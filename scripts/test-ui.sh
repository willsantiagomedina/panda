#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

xcrun swiftc \
  "$ROOT/app/ConfigStore.swift" \
  "$ROOT/app/ConfigStoreSmoke.swift" \
  -swift-version 5 \
  -enable-bare-slash-regex \
  -target arm64-apple-macosx13.0 \
  -o "$TMP_DIR/config-store-smoke"

PANDA_CONFIG="$TMP_DIR/config.lua" "$TMP_DIR/config-store-smoke"
printf 'test-ui: config editor smoke tests passed\n'
