#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gatebeam"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_DIR" "$INSTALL_DIR/"

echo "Installed: $INSTALL_DIR/$APP_NAME.app"
