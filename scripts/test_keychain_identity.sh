#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/keychain-identity-tests"
APP_PATH="$ROOT_DIR/dist/Gatebeam.app"
PROBE_SOURCE="$ROOT_DIR/Tests/KeychainIdentityTests/KeychainACLProbe.swift"
TRUSTED_PROBE="$BUILD_DIR/trusted-probe"
SPOOF_PROBE="$BUILD_DIR/spoof-probe"
SPOOF_APP="$BUILD_DIR/SpoofedGatebeam.bundle-fixture"
TEST_KEYCHAIN="$BUILD_DIR/acl-fixture.keychain"
PERSISTENT_REF="$BUILD_DIR/acl-fixture.persistent-ref"
TEST_SERVICE="io.github.naifuliang.gatebeam.keychain-acl-fixture"
TEST_PASSWORD="gatebeam-keychain-fixture"

cleanup() {
  /usr/bin/security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1 || true
  /bin/rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$BUILD_DIR" "$SPOOF_APP/Contents/MacOS"

/bin/zsh -f "$ROOT_DIR/scripts/build_app.sh"

requirement_output="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)"
requirement="${requirement_output##*designated => }"
if [[ "$requirement" != *"cdhash "* ]]; then
  print -u2 "Developer Preview is not protected by an exact-build cdhash requirement."
  print -u2 "$requirement_output"
  exit 1
fi

/bin/cp /usr/bin/true "$SPOOF_APP/Contents/MacOS/Gatebeam"
/usr/bin/plutil -create xml1 "$SPOOF_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.local.RemoteControlNetwork "$SPOOF_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Gatebeam "$SPOOF_APP/Contents/Info.plist"
/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --identifier com.local.RemoteControlNetwork \
  "$SPOOF_APP" >/dev/null

/usr/bin/codesign --verify --deep --strict -R="$requirement" "$APP_PATH"
if /usr/bin/codesign --verify --deep --strict -R="$requirement" "$SPOOF_APP" >/dev/null 2>&1; then
  print -u2 "A spoofed same-identifier app satisfied Gatebeam's exact-build requirement."
  exit 1
fi
/usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  -R='identifier "com.local.RemoteControlNetwork"' \
  "$SPOOF_APP"

if /usr/bin/grep -F -- '--requirements' "$ROOT_DIR/scripts/build_app.sh" >/dev/null; then
  print -u2 "build_app.sh must not override the system-generated designated requirement."
  exit 1
fi
if ! /usr/bin/grep -F 'anchor apple generic' "$ROOT_DIR/scripts/build_app.sh" >/dev/null ||
   ! /usr/bin/grep -F 'certificate leaf[subject.OU]' "$ROOT_DIR/scripts/build_app.sh" >/dev/null ||
   ! /usr/bin/grep -F 'TeamIdentifier=' "$ROOT_DIR/scripts/build_app.sh" >/dev/null; then
  print -u2 "Developer ID builds must verify the Apple anchor and expected Team ID."
  exit 1
fi

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -O \
  -D TRUSTED_BUILD \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework LocalAuthentication \
  -framework Security \
  "$PROBE_SOURCE" \
  -o "$TRUSTED_PROBE"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -O \
  -D SPOOF_BUILD \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework LocalAuthentication \
  -framework Security \
  "$PROBE_SOURCE" \
  -o "$SPOOF_PROBE"

/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.local.RemoteControlNetwork \
  "$TRUSTED_PROBE" >/dev/null
/usr/bin/codesign \
  --force \
  --sign - \
  --identifier com.local.RemoteControlNetwork \
  "$SPOOF_PROBE" >/dev/null

/usr/bin/security create-keychain -p "$TEST_PASSWORD" "$TEST_KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 21600 "$TEST_KEYCHAIN"
/usr/bin/security unlock-keychain -p "$TEST_PASSWORD" "$TEST_KEYCHAIN"

"$TRUSTED_PROBE" create "$TEST_KEYCHAIN" "$TEST_SERVICE" "$PERSISTENT_REF"
"$TRUSTED_PROBE" read "$TEST_KEYCHAIN" "$TEST_SERVICE" "$PERSISTENT_REF"
if "$SPOOF_PROBE" read "$TEST_KEYCHAIN" "$TEST_SERVICE" "$PERSISTENT_REF" >/dev/null 2>&1; then
  print -u2 "A spoofed same-identifier binary read an exact-build ACL item."
  exit 1
fi
"$TRUSTED_PROBE" delete "$TEST_KEYCHAIN" "$TEST_SERVICE" "$PERSISTENT_REF"

print "Keychain identity contract passed: default DR, exact-build ACL, and spoof rejection."
