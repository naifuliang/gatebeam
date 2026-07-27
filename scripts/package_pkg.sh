#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gatebeam"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
PKG_PATH="$ROOT_DIR/dist/Gatebeam-$VERSION.pkg"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

rm -f "$PKG_PATH"
COPYFILE_DISABLE=1 pkgbuild \
  --component "$APP_DIR" \
  --install-location /Applications \
  --identifier com.local.RemoteControlNetwork \
  --version "$VERSION" \
  "$PKG_PATH" >/dev/null

echo "Packaged PKG: $PKG_PATH"
