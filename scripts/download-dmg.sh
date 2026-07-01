#!/usr/bin/env bash

set -euo pipefail

printf 'Panda now uses a verified installer. Continuing with https://givepanda.tech/install.sh\n' >&2
curl -fsSL https://givepanda.tech/install.sh | bash
