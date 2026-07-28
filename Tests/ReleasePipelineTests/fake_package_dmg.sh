#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
print -r -- "unsigned-dmg" >"$ROOT_DIR/dist/Gatebeam-0.5.0.dmg"
if [[ "${GATEBEAM_FAKE_DMG_REBUILDS_APP:-0}" == "1" ]]; then
  print -r -- "rebuilt" >>"$ROOT_DIR/dist/Gatebeam.app/Contents/MacOS/Gatebeam"
fi
print -r -- "package_dmg" >>"$GATEBEAM_FAKE_CALL_LOG"
