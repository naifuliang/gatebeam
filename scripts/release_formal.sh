#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
PUBLISH_SCRIPT="$ROOT_DIR/scripts/publish_validated_release.sh"
TOKEN_FILE="${GATEBEAM_GITHUB_TOKEN_FILE:-}"

[[ -f "$PUBLISH_SCRIPT" && ! -L "$PUBLISH_SCRIPT" && -x "$PUBLISH_SCRIPT" ]] || {
  print -u2 -- "error: validated release publisher is missing or unsafe"
  exit 1
}

unset GATEBEAM_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN
export GATEBEAM_RELEASE_PUBLISH_TOKEN_FILE="$TOKEN_FILE"
exec /bin/zsh -f "$PUBLISH_SCRIPT" "$@"
