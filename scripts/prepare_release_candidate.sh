#!/bin/zsh -f
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV ZDOTDIR CDPATH

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
RELEASE_DRIVER="$ROOT_DIR/scripts/release_candidate_internal.sh"

[[ -f "$RELEASE_DRIVER" && ! -L "$RELEASE_DRIVER" ]] || {
  print -u2 -- "error: release candidate driver is missing or unsafe"
  exit 1
}

exec /bin/zsh -f "$RELEASE_DRIVER" "$@"
