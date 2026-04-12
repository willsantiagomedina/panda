#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'usage: %s VERSION URL SHA256\n' "$0" >&2
  exit 1
fi

VERSION="$1"
URL="$2"
SHA256="$3"

sed \
  -e "s|__PANDA_VERSION__|$VERSION|g" \
  -e "s|__PANDA_URL__|$URL|g" \
  -e "s|__PANDA_SHA256__|$SHA256|g" \
  "$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/panda.rb.in"
