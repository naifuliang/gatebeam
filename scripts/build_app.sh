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
SIGNING_CONTRACT="$ROOT_DIR/scripts/signing_contract.sh"

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
  source "$SIGNING_CONTRACT"
  if [[ "$CODE_SIGN_IDENTITY" != "-" &&
        ! "$DEVELOPER_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "GATEBEAM_DEVELOPER_TEAM_ID must be a 10-character Apple Team ID."
    exit 1
  fi
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    if /usr/libexec/PlistBuddy \
      -c "Print :GatebeamDeveloperTeamIdentifier" \
      "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy \
        -c "Delete :GatebeamDeveloperTeamIdentifier" \
        "$CONTENTS_DIR/Info.plist"
    fi
  else
    if /usr/libexec/PlistBuddy \
      -c "Print :GatebeamDeveloperTeamIdentifier" \
      "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy \
        -c "Set :GatebeamDeveloperTeamIdentifier $DEVELOPER_TEAM_ID" \
        "$CONTENTS_DIR/Info.plist"
    else
      /usr/libexec/PlistBuddy \
        -c "Add :GatebeamDeveloperTeamIdentifier string $DEVELOPER_TEAM_ID" \
        "$CONTENTS_DIR/Info.plist"
    fi
  fi
  sign_arguments=(
    --force
    --sign "$CODE_SIGN_IDENTITY"
    --options runtime
  )
  if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    if [[ -z "$DEVELOPER_TEAM_ID" ]]; then
      print -u2 "GATEBEAM_DEVELOPER_TEAM_ID is required for Developer ID signing."
      exit 1
    fi
    sign_arguments+=(--timestamp)
  fi

  /usr/bin/codesign "${sign_arguments[@]}" "$APP_DIR" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$APP_DIR"

  designated_requirement="$(/usr/bin/codesign -d -r- "$APP_DIR" 2>&1)"
  signing_details="$(/usr/bin/codesign -d --verbose=4 "$APP_DIR" 2>&1)"
  entitlements="$(/usr/bin/codesign -d --entitlements - "$APP_DIR" 2>/dev/null || true)"
  bundle_identifier="$(
    /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$CONTENTS_DIR/Info.plist"
  )"
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    if ! gatebeam_validate_preview_contract \
      "$designated_requirement" \
      "$signing_details" \
      "$entitlements" \
      "$bundle_identifier"; then
      print -u2 "$designated_requirement"
      exit 1
    fi
  else
    if ! gatebeam_validate_developer_id_contract \
      "$designated_requirement" \
      "$signing_details" \
      "$entitlements" \
      "$bundle_identifier" \
      "$DEVELOPER_TEAM_ID"; then
      print -u2 "$designated_requirement"
      exit 1
    fi

    developer_id_requirement="anchor apple generic and identifier \"$bundle_identifier\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$DEVELOPER_TEAM_ID\""
    if ! /usr/bin/codesign \
      --verify \
      --deep \
      --strict \
      -R="$developer_id_requirement" \
      "$APP_DIR"; then
      print -u2 "Signature does not satisfy the required Developer ID Application certificate chain."
      exit 1
    fi

    library_validation_capability="$(
      /bin/zsh -f "$ROOT_DIR/scripts/probe_library_validation.sh"
    )"
    gatebeam_require_formal_library_validation_capability \
      "$library_validation_capability"
  fi
fi

echo "Built: $APP_DIR"
