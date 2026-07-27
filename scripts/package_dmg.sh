#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gatebeam"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
STAGING_DIR="$ROOT_DIR/build/dmg/$APP_NAME"
DMG_PATH="$ROOT_DIR/dist/Gatebeam-$VERSION.dmg"
TEMP_DMG_PATH="$ROOT_DIR/build/Gatebeam-$VERSION.temp.dmg"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$TEMP_DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$TEMP_DMG_PATH" >/dev/null

hdiutil convert "$TEMP_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

rm -f "$TEMP_DMG_PATH"

echo "Packaged DMG: $DMG_PATH"
