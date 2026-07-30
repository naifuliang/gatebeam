#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
print -r -- "unsigned-pkg" >"$ROOT_DIR/dist/Gatebeam-0.5.0.pkg"
if [[ "${GATEBEAM_FAKE_PKG_REBUILDS_APP:-0}" == "1" ]]; then
  print -r -- "rebuilt" >>"$ROOT_DIR/dist/Gatebeam.app/Contents/MacOS/Gatebeam"
fi
print -r -- "package_pkg" >>"$GATEBEAM_FAKE_CALL_LOG"
