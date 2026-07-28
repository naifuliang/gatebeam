#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
SIGNING_CONTRACT="$ROOT_DIR/scripts/signing_contract.sh"
TEST_TOOL_DIR="${GATEBEAM_RELEASE_TEST_TOOL_DIR:-}"
TEST_MODE="${GATEBEAM_RELEASE_TEST_MODE:-0}"
FIXTURE_MARKER=".gatebeam-release-test-fixture"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

usage() {
  print -u2 -- \
    "Usage: $(basename "$0") <app-signature|app-stapled|pkg-signature|pkg-stapled|dmg-signature|dmg-stapled> <path> <version> <bundle-id> <team-id>"
  exit 64
}

tool_path() {
  local name="$1"
  local system_path="$2"
  local candidate

  if [[ -z "$TEST_TOOL_DIR" ]]; then
    print -r -- "$system_path"
    return
  fi

  [[ "$TEST_MODE" == "1" &&
      "$ROOT_DIR" == /private/tmp/* &&
      -f "$ROOT_DIR/$FIXTURE_MARKER" &&
      ! -L "$ROOT_DIR/$FIXTURE_MARKER" &&
      "$(<"$ROOT_DIR/$FIXTURE_MARKER")" == "Gatebeam release test fixture v1" ]] ||
    fail "release tool overrides are restricted to marked /private/tmp fixtures"
  [[ -d "$TEST_TOOL_DIR" && ! -L "$TEST_TOOL_DIR" ]] ||
    fail "release tool override directory is invalid"
  [[ "$(cd -P "$TEST_TOOL_DIR" 2>/dev/null && pwd -P)" == "$TEST_TOOL_DIR" &&
      -f "$TEST_TOOL_DIR/$FIXTURE_MARKER" &&
      ! -L "$TEST_TOOL_DIR/$FIXTURE_MARKER" &&
      "$(<"$TEST_TOOL_DIR/$FIXTURE_MARKER")" == "Gatebeam release test fixture v1" ]] ||
    fail "release tool override directory is not a canonical marked fixture"

  candidate="$TEST_TOOL_DIR/$name"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    fail "release test tool is missing or unsafe: $name"
  print -r -- "$candidate"
}

[[ $# -eq 5 ]] || usage

MODE="$1"
ARTIFACT_PATH="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUNDLE_ID="$4"
EXPECTED_TEAM_ID="$5"

[[ "$EXPECTED_VERSION" =~ '^[0-9]+([.][0-9]+){2}([-.][A-Za-z0-9.]+)?$' ]] ||
  fail "invalid expected version"
[[ "$EXPECTED_BUNDLE_ID" == "io.github.naifuliang.gatebeam" ]] ||
  fail "unexpected Gatebeam bundle identifier"
[[ "$EXPECTED_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] ||
  fail "invalid Apple Team ID"

CODESIGN="$(tool_path codesign /usr/bin/codesign)"
PKGUTIL="$(tool_path pkgutil /usr/sbin/pkgutil)"
SPCTL="$(tool_path spctl /usr/sbin/spctl)"
HDIUTIL="$(tool_path hdiutil /usr/bin/hdiutil)"
XCRUN="$(tool_path xcrun /usr/bin/xcrun)"

[[ -f "$SIGNING_CONTRACT" && ! -L "$SIGNING_CONTRACT" ]] ||
  fail "signing contract is missing or unsafe"
source "$SIGNING_CONTRACT"

verify_app_signature() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  local executable_name
  local actual_bundle_id
  local actual_version
  local actual_team_id
  local designated_requirement
  local signing_details
  local entitlements
  local developer_id_requirement
  local developer_id_ca_oid="1.2.840.113635.100.6.""2.6"
  local developer_id_leaf_oid="1.2.840.113635.100.6.""1.13"

  [[ -d "$app_path" && ! -L "$app_path" ]] ||
    fail "application is missing or is a symbolic link"
  [[ -f "$plist_path" && ! -L "$plist_path" ]] ||
    fail "application Info.plist is missing or unsafe"

  actual_bundle_id="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path"
  )" || fail "could not read application bundle identifier"
  actual_version="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path"
  )" || fail "could not read application version"
  actual_team_id="$(
    /usr/libexec/PlistBuddy -c 'Print :GatebeamDeveloperTeamIdentifier' "$plist_path"
  )" || fail "application does not record its release Team ID"
  executable_name="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist_path"
  )" || fail "could not read application executable name"

  [[ "$actual_bundle_id" == "$EXPECTED_BUNDLE_ID" ]] ||
    fail "application bundle identifier does not match the release contract"
  [[ "$actual_version" == "$EXPECTED_VERSION" ]] ||
    fail "application version does not match the release contract"
  [[ "$actual_team_id" == "$EXPECTED_TEAM_ID" ]] ||
    fail "application Team ID does not match the release contract"
  [[ "$executable_name" == "Gatebeam" ]] ||
    fail "unexpected application executable name"
  [[ -f "$app_path/Contents/MacOS/$executable_name" &&
      ! -L "$app_path/Contents/MacOS/$executable_name" &&
      -x "$app_path/Contents/MacOS/$executable_name" ]] ||
    fail "application executable is missing or unsafe"

  "$CODESIGN" --verify --deep --strict "$app_path" ||
    fail "application code signature is invalid"
  designated_requirement="$("$CODESIGN" -d -r- "$app_path" 2>&1)" ||
    fail "could not read application designated requirement"
  signing_details="$("$CODESIGN" -d --verbose=4 "$app_path" 2>&1)" ||
    fail "could not read application signing details"
  entitlements="$(
    "$CODESIGN" -d --entitlements - "$app_path" 2>/dev/null || true
  )"

  gatebeam_validate_developer_id_contract \
    "$designated_requirement" \
    "$signing_details" \
    "$entitlements" \
    "$EXPECTED_BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" ||
    fail "application does not satisfy the Developer ID release contract"

  developer_id_requirement="anchor apple generic and identifier \"$EXPECTED_BUNDLE_ID\" and certificate 1[field.$developer_id_ca_oid] exists and certificate leaf[field.$developer_id_leaf_oid] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
  "$CODESIGN" \
    --verify \
    --deep \
    --strict \
    -R="$developer_id_requirement" \
    "$app_path" ||
    fail "application is not signed with the required Developer ID Application chain"
}

verify_pkg_signature() {
  local package_path="$1"
  local signature_details

  [[ -f "$package_path" && ! -L "$package_path" && -s "$package_path" ]] ||
    fail "installer package is missing or unsafe"
  signature_details="$("$PKGUTIL" --check-signature "$package_path" 2>&1)" ||
    fail "installer package signature is invalid"

  [[ "$signature_details" == *"Status: signed by a certificate trusted by macOS"* ]] ||
    fail "installer package signature is not trusted by macOS"
  [[ "$signature_details" == *"Developer ID Installer:"* ]] ||
    fail "installer package is not signed with Developer ID Installer"
  [[ "$signature_details" == *"($EXPECTED_TEAM_ID)"* ]] ||
    fail "installer package Team ID does not match the release contract"
  [[ "$signature_details" == *"Signed with a trusted timestamp"* ]] ||
    fail "installer package is missing a secure timestamp"
}

verify_dmg_signature() {
  local dmg_path="$1"
  local signing_details
  local entitlements
  local developer_id_requirement
  local developer_id_ca_oid="1.2.840.113635.100.6.""2.6"
  local developer_id_leaf_oid="1.2.840.113635.100.6.""1.13"

  [[ -f "$dmg_path" && ! -L "$dmg_path" && -s "$dmg_path" ]] ||
    fail "disk image is missing or unsafe"
  "$CODESIGN" --verify --strict "$dmg_path" ||
    fail "disk image code signature is invalid"
  signing_details="$("$CODESIGN" -d --verbose=4 "$dmg_path" 2>&1)" ||
    fail "could not read disk image signing details"
  entitlements="$(
    "$CODESIGN" -d --entitlements - "$dmg_path" 2>/dev/null || true
  )"

  [[ "$signing_details" == *"Authority=Developer ID Application:"* ]] ||
    fail "disk image is not signed with Developer ID Application"
  gatebeam_signing_details_has_line \
    "$signing_details" \
    "TeamIdentifier=$EXPECTED_TEAM_ID" ||
    fail "disk image Team ID does not match the release contract"
  [[ "$signing_details" == *"Timestamp="* &&
      "$signing_details" != *"Timestamp=none"* &&
      "$signing_details" != *"Signed Time="* ]] ||
    fail "disk image is missing a secure timestamp"
  gatebeam_validate_safe_entitlements "$entitlements" ||
    fail "disk image contains a forbidden signing entitlement"
  developer_id_requirement="anchor apple generic and certificate 1[field.$developer_id_ca_oid] exists and certificate leaf[field.$developer_id_leaf_oid] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
  "$CODESIGN" \
    --verify \
    --strict \
    -R="$developer_id_requirement" \
    "$dmg_path" ||
    fail "disk image is not signed with the required Developer ID Application chain"
  "$HDIUTIL" verify "$dmg_path" >/dev/null ||
    fail "disk image verification failed"
}

case "$MODE" in
  app-signature)
    verify_app_signature "$ARTIFACT_PATH"
    ;;
  app-stapled)
    verify_app_signature "$ARTIFACT_PATH"
    "$XCRUN" stapler validate "$ARTIFACT_PATH" ||
      fail "application notarization ticket validation failed"
    "$SPCTL" --assess --type execute --verbose=4 "$ARTIFACT_PATH" ||
      fail "Gatekeeper rejected the application"
    ;;
  pkg-signature)
    verify_pkg_signature "$ARTIFACT_PATH"
    ;;
  pkg-stapled)
    verify_pkg_signature "$ARTIFACT_PATH"
    "$XCRUN" stapler validate "$ARTIFACT_PATH" ||
      fail "installer notarization ticket validation failed"
    "$SPCTL" --assess --type install --verbose=4 "$ARTIFACT_PATH" ||
      fail "Gatekeeper rejected the installer package"
    ;;
  dmg-signature)
    verify_dmg_signature "$ARTIFACT_PATH"
    ;;
  dmg-stapled)
    verify_dmg_signature "$ARTIFACT_PATH"
    "$XCRUN" stapler validate "$ARTIFACT_PATH" ||
      fail "disk image notarization ticket validation failed"
    "$SPCTL" \
      --assess \
      --type open \
      --context context:primary-signature \
      --verbose=4 \
      "$ARTIFACT_PATH" ||
      fail "Gatekeeper rejected the disk image"
    ;;
  *)
    usage
    ;;
esac

print -r -- "Verified $MODE: $ARTIFACT_PATH"
