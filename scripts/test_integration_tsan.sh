#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

exec /bin/zsh -f "$ROOT_DIR/scripts/test_integration_contract.sh" \
  --thread-sanitizer
