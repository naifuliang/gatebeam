#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/Gatebeam.app"
PLIST_PATH="$APP_PATH/Contents/Info.plist"

mkdir -p "$APP_PATH/Contents/MacOS"
cp "$ROOT_DIR/Resources/Info.plist" "$PLIST_PATH"
if [[ -n "${GATEBEAM_FAKE_APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $GATEBEAM_FAKE_APP_VERSION" \
    "$PLIST_PATH"
fi
if [[ -n "${GATEBEAM_FAKE_APP_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $GATEBEAM_FAKE_APP_BUNDLE_ID" \
    "$PLIST_PATH"
fi
/usr/libexec/PlistBuddy \
  -c "Add :GatebeamDeveloperTeamIdentifier string $GATEBEAM_DEVELOPER_TEAM_ID" \
  "$PLIST_PATH"
print -r -- '#!/bin/sh' >"$APP_PATH/Contents/MacOS/Gatebeam"
print -r -- 'exit 0' >>"$APP_PATH/Contents/MacOS/Gatebeam"
chmod +x "$APP_PATH/Contents/MacOS/Gatebeam"
print -r -- "build_app" >>"$GATEBEAM_FAKE_CALL_LOG"
