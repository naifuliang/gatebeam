#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gatebeam"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/Gatebeam-$VERSION.dmg"
BUILD_DIR="$ROOT_DIR/build"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/Resources/Info.plist")"
EXPECTED_EXECUTABLE="Gatebeam"
VALIDATE_ONLY=false

usage() {
  echo "Usage: $(basename "$0") [--validate-only]" >&2
}

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--validate-only" ) ]]; then
  usage
  exit 64
fi

[[ $# -eq 1 ]] && VALIDATE_ONLY=true

fail() {
  echo "error: $*" >&2
  exit 1
}

app_is_valid() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  local executable_name
  local actual_bundle_id
  local actual_version

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 1
  [[ -f "$plist_path" && ! -L "$plist_path" ]] || return 1

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null)" || return 1
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null)" || return 1
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist_path" 2>/dev/null)" || return 1

  [[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || return 1
  [[ "$actual_version" == "$VERSION" ]] || return 1
  [[ "$executable_name" == "$EXPECTED_EXECUTABLE" ]] || return 1
  [[ -f "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  [[ ! -L "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  [[ -x "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1
}

ensure_valid_app() {
  if app_is_valid "$APP_DIR"; then
    return
  fi

  if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    echo "Existing $APP_DIR is incomplete, invalid, or has a broken signature; rebuilding it"
  fi
  /bin/zsh -f "$ROOT_DIR/scripts/build_app.sh"

  app_is_valid "$APP_DIR" || fail "built application failed DMG validation: $APP_DIR"
}

[[ -n "$VERSION" ]] || fail "CFBundleShortVersionString is empty"
[[ "$APP_NAME" != */* && "$VERSION" != */* ]] || fail "unsafe DMG name components"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required to create a DMG"

ensure_valid_app

mkdir -p "$BUILD_DIR"
WORK_DIR="$(mktemp -d "$BUILD_DIR/dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/$APP_NAME"
TEMP_DMG_PATH="$WORK_DIR/Gatebeam-$VERSION.temp.dmg"
FINAL_TEMP_DMG_PATH="$WORK_DIR/Gatebeam-$VERSION.dmg"
LOG_PATH="$WORK_DIR/hdiutil.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap 'cleanup' EXIT HUP INT TERM

mkdir -p "$STAGING_DIR"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

[[ -d "$STAGING_DIR/$APP_NAME.app" ]] || fail "DMG staging did not contain $APP_NAME.app"
[[ -L "$STAGING_DIR/Applications" && "$(readlink "$STAGING_DIR/Applications")" == "/Applications" ]] || fail "DMG Applications shortcut is invalid"
app_is_valid "$STAGING_DIR/$APP_NAME.app" || fail "staged application failed DMG signature validation"

if "$VALIDATE_ONLY"; then
  echo "DMG staging validation passed: $STAGING_DIR"
  exit 0
fi

rm -f "$TEMP_DMG_PATH"
if hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$TEMP_DMG_PATH" >"$LOG_PATH" 2>&1; then
  :
else
  exit_code=$?
  echo "error: hdiutil create failed (exit $exit_code). This usually means the host cannot create disk-image devices." >&2
  cat "$LOG_PATH" >&2
  hdiutil info 2>&1 | sed -n '1,80p' >&2 || true
  exit "$exit_code"
fi

if hdiutil convert "$TEMP_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_TEMP_DMG_PATH" >"$LOG_PATH" 2>&1; then
  :
else
  exit_code=$?
  echo "error: hdiutil convert failed (exit $exit_code)." >&2
  cat "$LOG_PATH" >&2
  exit "$exit_code"
fi

hdiutil verify "$FINAL_TEMP_DMG_PATH" >"$LOG_PATH" 2>&1 || {
  cat "$LOG_PATH" >&2
  fail "hdiutil verify failed for $FINAL_TEMP_DMG_PATH"
}

rm -f "$TEMP_DMG_PATH"
mv -f "$FINAL_TEMP_DMG_PATH" "$DMG_PATH"

echo "Packaged DMG: $DMG_PATH"
