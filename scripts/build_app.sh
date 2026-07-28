#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Gatebeam"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/Gatebeam"
BUILT_ICON="$BUILD_DIR/app-assets/AppIcon.icns"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

/bin/zsh -f "$ROOT_DIR/scripts/build_icon.sh" "$BUILT_ICON"

swiftc \
  -swift-version 5 \
  -O \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework Security \
  "$ROOT_DIR"/Sources/RemoteControlNetwork/*.swift \
  -o "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILT_ICON" "$RESOURCES_DIR/AppIcon.icns"
chmod +x "$EXECUTABLE"

if command -v codesign >/dev/null 2>&1; then
  codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.local.RemoteControlNetwork"' \
    "$APP_DIR" >/dev/null
fi

echo "Built: $APP_DIR"
