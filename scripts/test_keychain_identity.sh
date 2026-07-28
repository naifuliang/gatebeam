#!/bin/zsh -f
set -euo pipefail
unsetopt BG_NICE

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/keychain-identity-tests"
APP_PATH="$ROOT_DIR/dist/Gatebeam.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Gatebeam"
INJECTION_SOURCE="$ROOT_DIR/Tests/KeychainIdentityTests/DYLDInjectionProbe.c"
SIGNING_CONTRACT="$ROOT_DIR/scripts/signing_contract.sh"
SPOOF_APP="$BUILD_DIR/SpoofedGatebeam.bundle-fixture"
INJECTION_DYLIB="$BUILD_DIR/libGatebeamInjectionProbe.dylib"
INJECTION_SENTINEL="$BUILD_DIR/dyld-injection-loaded"
INJECTION_LOG="$BUILD_DIR/dyld-injection.log"
INJECTION_HOME="$BUILD_DIR/injection-home"
INJECTION_PID=""

if (( $# != 0 )); then
  print -u2 "Usage: $0"
  exit 2
fi

cleanup() {
  if [[ -n "$INJECTION_PID" ]] && kill -0 "$INJECTION_PID" 2>/dev/null; then
    kill -TERM "$INJECTION_PID" 2>/dev/null || true
    wait "$INJECTION_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p \
  "$BUILD_DIR" \
  "$SPOOF_APP/Contents/MacOS" \
  "$INJECTION_HOME/tmp"

source "$SIGNING_CONTRACT"

/bin/zsh -f "$ROOT_DIR/scripts/build_app.sh"

requirement_output="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)"
requirement="${requirement_output##*designated => }"
signing_details="$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)"
entitlements="$(/usr/bin/codesign -d --entitlements - "$APP_PATH" 2>/dev/null || true)"
if ! gatebeam_validate_preview_contract \
  "$requirement" \
  "$signing_details" \
  "$entitlements"; then
  print -u2 "Developer Preview does not satisfy its signing contract."
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
  --options runtime \
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

developer_id_requirement='identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TEAMID1234"'
developer_id_details=$'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (TEAMID1234)\nTeamIdentifier=TEAMID1234\nRuntime Version=15.0.0\nTimestamp=Jul 28, 2026 at 12:34:56'
empty_entitlements=""

if ! gatebeam_validate_developer_id_contract \
  "$developer_id_requirement" \
  "$developer_id_details" \
  "$empty_entitlements" \
  "com.local.RemoteControlNetwork" \
  "TEAMID1234"; then
  print -u2 "Valid Developer ID Application fixture was rejected."
  exit 1
fi

expect_developer_id_rejection() {
  local description="$1"
  local fixture_requirement="$2"
  local fixture_details="$3"
  local fixture_entitlements="$4"

  if gatebeam_validate_developer_id_contract \
    "$fixture_requirement" \
    "$fixture_details" \
    "$fixture_entitlements" \
    "com.local.RemoteControlNetwork" \
    "TEAMID1234" >/dev/null 2>&1; then
    print -u2 "Developer ID signing fixture was incorrectly accepted: $description"
    exit 1
  fi
}

expect_developer_id_rejection \
  "Apple Development certificate chain" \
  'identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.CN] = "Apple Development: Fixture" and certificate leaf[subject.OU] = "TEAMID1234"' \
  "$developer_id_details" \
  "$empty_entitlements"
expect_developer_id_rejection \
  "Developer ID Installer leaf OID" \
  'identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.14] exists and certificate leaf[subject.OU] = "TEAMID1234"' \
  "$developer_id_details" \
  "$empty_entitlements"
expect_developer_id_rejection \
  "missing secure timestamp" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (TEAMID1234)\nTeamIdentifier=TEAMID1234\nRuntime Version=15.0.0\nTimestamp=none' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "missing hardened runtime" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x0(none)\nAuthority=Developer ID Application: Fixture (TEAMID1234)\nTeamIdentifier=TEAMID1234\nRuntime Version=15.0.0\nTimestamp=Jul 28, 2026 at 12:34:56' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "missing Runtime Version" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (TEAMID1234)\nTeamIdentifier=TEAMID1234\nTimestamp=Jul 28, 2026 at 12:34:56' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "wrong bundle identifier in requirement" \
  'identifier "com.local.RemoteControlNetwork.spoof" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TEAMID1234"' \
  "$developer_id_details" \
  "$empty_entitlements"
expect_developer_id_rejection \
  "wrong signed bundle identifier" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork.spoof\nCodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (TEAMID1234)\nTeamIdentifier=TEAMID1234\nRuntime Version=15.0.0\nTimestamp=Jul 28, 2026 at 12:34:56' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "wrong Team ID in requirement" \
  'identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "OTHERTEAM1"' \
  "$developer_id_details" \
  "$empty_entitlements"
expect_developer_id_rejection \
  "wrong signed Team ID" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Fixture (OTHERTEAM1)\nTeamIdentifier=OTHERTEAM1\nRuntime Version=15.0.0\nTimestamp=Jul 28, 2026 at 12:34:56' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "missing Developer ID authority" \
  "$developer_id_requirement" \
  $'Identifier=com.local.RemoteControlNetwork\nCodeDirectory v=20500 flags=0x10000(runtime)\nTeamIdentifier=TEAMID1234\nRuntime Version=15.0.0\nTimestamp=Jul 28, 2026 at 12:34:56' \
  "$empty_entitlements"
expect_developer_id_rejection \
  "unsafe DYLD entitlement" \
  "$developer_id_requirement" \
  "$developer_id_details" \
  '<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>'
expect_developer_id_rejection \
  "disabled library validation" \
  "$developer_id_requirement" \
  "$developer_id_details" \
  '<key>com.apple.security.cs.disable-library-validation</key><true/>'
expect_developer_id_rejection \
  "debug task entitlement" \
  "$developer_id_requirement" \
  "$developer_id_details" \
  '<key>com.apple.security.get-task-allow</key><true/>'
expect_developer_id_rejection \
  "unsigned executable memory entitlement" \
  "$developer_id_requirement" \
  "$developer_id_details" \
  '<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>'

/usr/bin/xcrun clang \
  -dynamiclib \
  -O2 \
  "$INJECTION_SOURCE" \
  -o "$INJECTION_DYLIB"
/usr/bin/codesign \
  --force \
  --sign - \
  "$INJECTION_DYLIB" >/dev/null

app_cdhash="$(
  /usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p'
)"
injection_cdhash="$(
  /usr/bin/codesign -d --verbose=4 "$INJECTION_DYLIB" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p'
)"
if [[ -z "$app_cdhash" ||
      -z "$injection_cdhash" ||
      "$app_cdhash" == "$injection_cdhash" ]]; then
  print -u2 "DYLD injection fixture must have a different code identity."
  exit 1
fi

HOME="$INJECTION_HOME" \
CFFIXED_USER_HOME="$INJECTION_HOME" \
TMPDIR="$INJECTION_HOME/tmp/" \
GATEBEAM_DYLD_INJECTION_SENTINEL="$INJECTION_SENTINEL" \
DYLD_INSERT_LIBRARIES="$INJECTION_DYLIB" \
  "$APP_EXECUTABLE" --signing-runtime-probe >"$INJECTION_LOG" 2>&1 &
INJECTION_PID=$!

injection_process_survived=true
for _ in {1..40}; do
  if ! kill -0 "$INJECTION_PID" 2>/dev/null; then
    injection_process_survived=false
    break
  fi
  if [[ -e "$INJECTION_SENTINEL" ]]; then
    print -u2 "A different-cdhash library was injected into Gatebeam."
    exit 1
  fi
  /bin/sleep 0.1
done

if [[ "$injection_process_survived" == true ]]; then
  kill -TERM "$INJECTION_PID" 2>/dev/null || true
fi
wait "$INJECTION_PID" 2>/dev/null || true
INJECTION_PID=""
if [[ -e "$INJECTION_SENTINEL" ]]; then
  print -u2 "A different-cdhash library was injected into Gatebeam."
  exit 1
fi

# An ad-hoc hardened process may reject the malicious launch before main,
# while a Developer ID process can ignore the DYLD variable. Both outcomes
# are secure; the same signed executable must still pass a clean CLI-only probe.
if ! clean_probe_output="$(
  HOME="$INJECTION_HOME" \
  CFFIXED_USER_HOME="$INJECTION_HOME" \
  TMPDIR="$INJECTION_HOME/tmp/" \
    "$APP_EXECUTABLE" --signing-runtime-probe 2>"$INJECTION_LOG"
)"; then
  print -u2 "Gatebeam failed its clean signing-runtime probe."
  /usr/bin/sed -n '1,160p' "$INJECTION_LOG" >&2
  exit 1
fi
if [[ "$clean_probe_output" != "Gatebeam signing runtime probe ready" ]]; then
  print -u2 "Gatebeam returned an unexpected signing-runtime probe result."
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

print "Signing identity contract passed: hardened runtime, TN3127 fixtures, exact-build requirement, and injection rejection."
