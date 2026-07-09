#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'usage: %s VERSION URL SHA256\n' "$0" >&2
  exit 1
fi

VERSION="$1"
URL="$2"
SHA256="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/packaging/homebrew/panda.rb.in"

python3 - "$TEMPLATE" "$VERSION" "$URL" "$SHA256" <<'PY'
import sys
from pathlib import Path

template_path, version, url, sha256 = sys.argv[1:]
content = Path(template_path).read_text()
for placeholder, value in {
    "__PANDA_VERSION__": version,
    "__PANDA_URL__": url,
    "__PANDA_SHA256__": sha256,
}.items():
    content = content.replace(placeholder, value)
print(content, end="")
PY
