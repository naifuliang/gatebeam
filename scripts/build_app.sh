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
CODE_SIGN_IDENTITY="${GATEBEAM_CODE_SIGN_IDENTITY:--}"
DEVELOPER_TEAM_ID="${GATEBEAM_DEVELOPER_TEAM_ID:-}"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

/bin/zsh -f "$ROOT_DIR/scripts/build_icon.sh" "$BUILT_ICON"

swiftc \
  -swift-version 5 \
  -O \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework LocalAuthentication \
  -framework Security \
  "$ROOT_DIR"/Sources/RemoteControlNetwork/*.swift \
  -o "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILT_ICON" "$RESOURCES_DIR/AppIcon.icns"
chmod +x "$EXECUTABLE"

if command -v codesign >/dev/null 2>&1; then
  sign_arguments=(
    --force
    --deep
    --sign "$CODE_SIGN_IDENTITY"
  )
  if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    if [[ -z "$DEVELOPER_TEAM_ID" ]]; then
      print -u2 "GATEBEAM_DEVELOPER_TEAM_ID is required for Developer ID signing."
      exit 1
    fi
    sign_arguments+=(--options runtime --timestamp)
  fi

  /usr/bin/codesign "${sign_arguments[@]}" "$APP_DIR" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$APP_DIR"

  designated_requirement="$(/usr/bin/codesign -d -r- "$APP_DIR" 2>&1)"
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    if [[ "$designated_requirement" != *"cdhash "* ||
          "$designated_requirement" == *"identifier "* ||
          "$designated_requirement" == *"anchor "* ]]; then
      print -u2 "Ad-hoc Developer Preview must use the default exact-build cdhash requirement."
      print -u2 "$designated_requirement"
      exit 1
    fi
  else
    signing_details="$(/usr/bin/codesign -d --verbose=4 "$APP_DIR" 2>&1)"
    if [[ "$designated_requirement" != *"anchor apple generic"* ||
          "$designated_requirement" == *" or "* ||
          "$designated_requirement" != *"certificate leaf[subject.OU] = \"$DEVELOPER_TEAM_ID\""* ]]; then
      print -u2 "Developer ID designated requirement is missing the Apple anchor or expected Team ID."
      print -u2 "$designated_requirement"
      exit 1
    fi
    if [[ "$signing_details" != *"TeamIdentifier=$DEVELOPER_TEAM_ID"* ]]; then
      print -u2 "Developer ID signature TeamIdentifier does not match $DEVELOPER_TEAM_ID."
      exit 1
    fi
  fi
fi

echo "Built: $APP_DIR"
