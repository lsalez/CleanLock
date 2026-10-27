#!/bin/zsh
# Thin wrapper kept for convenience. The real implementation lives in build.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

exec "$ROOT_DIR/Scripts/build.sh" debug "$@"
