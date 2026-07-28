#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
TEST_TOOL_DIR="${GATEBEAM_RELEASE_TEST_TOOL_DIR:-}"
TEST_MODE="${GATEBEAM_RELEASE_TEST_MODE:-0}"
TEST_FAILURE_POINT="${GATEBEAM_RELEASE_TEST_FAILURE_POINT:-}"
FIXTURE_MARKER=".gatebeam-release-test-fixture"
EXPECTED_BUNDLE_ID="io.github.naifuliang.gatebeam"
TEMP_ROOT=""
PUBLISH_STAGING=""
PUBLISH_LOCK=""

fail() {
  print -u2 -- "error: $*"
  exit 1
}

cleanup() {
  [[ -z "$PUBLISH_STAGING" ]] || rm -rf -- "$PUBLISH_STAGING"
  [[ -z "$PUBLISH_LOCK" ]] || rmdir -- "$PUBLISH_LOCK" 2>/dev/null || true
  [[ -z "$TEMP_ROOT" ]] || rm -rf -- "$TEMP_ROOT"
}

handle_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
}

tool_path() {
  local name="$1"
  local system_path="$2"
  local candidate

  if [[ -z "$TEST_TOOL_DIR" ]]; then
    print -r -- "$system_path"
    return
  fi

  validate_fixture_mode
  [[ -d "$TEST_TOOL_DIR" && ! -L "$TEST_TOOL_DIR" ]] ||
    fail "release tool override directory is invalid"
  [[ -f "$TEST_TOOL_DIR/$FIXTURE_MARKER" &&
      ! -L "$TEST_TOOL_DIR/$FIXTURE_MARKER" ]] ||
    fail "release tool override directory is not a marked fixture"

  candidate="$TEST_TOOL_DIR/$name"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    fail "release test tool is missing or unsafe: $name"
  print -r -- "$candidate"
}

validate_fixture_mode() {
  local canonical_tool_dir
  local fake_call_log="${GATEBEAM_FAKE_CALL_LOG:-}"
  local fake_call_log_parent

  [[ "$TEST_MODE" == "1" && -n "$TEST_TOOL_DIR" ]] ||
    fail "release tool overrides require explicit fixture mode"
  [[ "$ROOT_DIR" == /private/tmp/* &&
      -f "$ROOT_DIR/$FIXTURE_MARKER" &&
      ! -L "$ROOT_DIR/$FIXTURE_MARKER" &&
      "$(<"$ROOT_DIR/$FIXTURE_MARKER")" == "Gatebeam release test fixture v1" ]] ||
    fail "release tool overrides are restricted to marked /private/tmp fixtures"
  canonical_tool_dir="$(cd -P "$TEST_TOOL_DIR" 2>/dev/null && pwd -P)" ||
    fail "release tool override directory is invalid"
  [[ "$canonical_tool_dir" == "$TEST_TOOL_DIR" &&
      "$canonical_tool_dir" == /private/tmp/* ]] ||
    fail "release tool overrides are restricted to canonical /private/tmp fixtures"

  if [[ -n "$fake_call_log" ]]; then
    fake_call_log_parent="$(
      cd -P "${fake_call_log:h}" 2>/dev/null && pwd -P
    )" || fail "release fixture call log has an invalid parent"
    [[ "$fake_call_log" == "$fake_call_log_parent/${fake_call_log:t}" &&
        "$fake_call_log_parent" == /private/tmp/* &&
        -f "$fake_call_log_parent/$FIXTURE_MARKER" &&
        ! -L "$fake_call_log_parent/$FIXTURE_MARKER" &&
        ! -L "$fake_call_log" ]] ||
      fail "release fixture call log must remain inside a marked /private/tmp fixture"
  fi
}

sanitize_environment() {
  unset \
    BASH_ENV ENV ZDOTDIR CDPATH \
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    LD_PRELOAD LD_LIBRARY_PATH \
    PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
    RUBYOPT RUBYLIB PERL5OPT PERL5LIB \
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_REPLACE_REF_BASE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
    GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_EXTERNAL_DIFF \
    GATEBEAM_PACKAGE_TMPDIR GATEBEAM_TEST_TMPDIR \
    GATEBEAM_TEST_PKG_FAILURE_POINT GATEBEAM_TEST_PKG_SIGNAL_POINT

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1
  export PYTHONNOUSERSITE=1
}

git_safe() {
  /usr/bin/git \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.attributesfile=/dev/null \
    "$@"
}

assert_safe_dist() {
  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] ||
    fail "dist is not a safe release directory"
}

require_environment() {
  local variable_name="$1"
  [[ -n "${(P)variable_name:-}" ]] ||
    fail "$variable_name is required for a formal release"
}

validate_identity_input() {
  local value="$1"
  local certificate_class="$2"
  local team_id="$3"

  if [[ "$value" =~ '^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$' ]]; then
    return
  fi
  [[ "$value" == "$certificate_class: "* &&
      "$value" == *"($team_id)" ]] ||
    fail "$certificate_class identity has the wrong class or Team ID"
}

inject_test_failure() {
  local point="$1"

  [[ -z "$TEST_FAILURE_POINT" || "$TEST_FAILURE_POINT" != "$point" ]] &&
    return
  [[ "$TEST_MODE" == "1" && "$ROOT_DIR" == /private/tmp/* ]] ||
    fail "release failure injection is restricted to /private/tmp fixtures"
  fail "injected release failure at $point"
}

verify_notarized_app_unchanged() {
  local label="$1"

  if ! /bin/zsh -f "$VERIFY_SCRIPT" \
    app-stapled \
    "$APP_PATH" \
    "$VERSION" \
    "$BUNDLE_ID" \
    "$GATEBEAM_DEVELOPER_TEAM_ID"; then
    fail "$label packaging modified the notarized application"
  fi
}

notarize_and_review() {
  local label="$1"
  local artifact_path="$2"
  local response_path="$TEMP_ROOT/notary-$label-submit.json"
  local log_path="$WORKSPACE_ROOT/build/formal-notary-logs/$label.json"
  local submission_status
  local submission_id

  print -u2 -- "Submitting $label for notarization"
  "$XCRUN" notarytool submit \
    --keychain-profile "$GATEBEAM_NOTARY_PROFILE" \
    --wait \
    --output-format json \
    --no-progress \
    "$artifact_path" >"$response_path" ||
    fail "notary submission failed for $label"

  submission_status="$(
    /usr/bin/plutil -extract status raw -o - "$response_path"
  )" || fail "notary response omitted status for $label"
  submission_id="$(
    /usr/bin/plutil -extract id raw -o - "$response_path"
  )" || fail "notary response omitted submission id for $label"

  [[ "$submission_status" == "Accepted" ]] ||
    fail "notary submission for $label was not Accepted"
  [[ "$submission_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] ||
    fail "notary submission returned an invalid id for $label"

  mkdir -p "${log_path:h}"
  "$XCRUN" notarytool log \
    --keychain-profile "$GATEBEAM_NOTARY_PROFILE" \
    "$submission_id" \
    "$log_path" >/dev/null ||
    fail "could not retrieve notary log for $label"
  [[ -f "$log_path" && ! -L "$log_path" && -s "$log_path" ]] ||
    fail "notary log is missing for $label"

  /usr/bin/python3 -I -E -s -c '
import json
import sys

with open(sys.argv[1], "rb") as stream:
    result = json.load(stream)

if result.get("jobId") != sys.argv[2] or result.get("status") != "Accepted":
    raise SystemExit(1)
if "issues" not in result or result["issues"] not in (None, []):
    raise SystemExit(2)
' "$log_path" "$submission_id" ||
    fail "notary log contains warning or error issues for $label"

  print -r -- "$submission_id"
}

write_manifest() {
  local output_path="$1"
  local plist_path="$TEMP_ROOT/release-manifest.plist"
  local app_name="${APP_ARCHIVE:t}"
  local pkg_name="${SIGNED_PKG:t}"
  local dmg_name="${SIGNED_DMG:t}"
  local artifacts_key="artifacts"
  local notarization_key="notarization"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert schemaVersion -integer 1 "$plist_path"
  /usr/bin/plutil -insert product -string Gatebeam "$plist_path"
  /usr/bin/plutil -insert commit -string "$HEAD_COMMIT" "$plist_path"
  /usr/bin/plutil -insert tag -string "$RELEASE_TAG" "$plist_path"
  /usr/bin/plutil -insert version -string "$VERSION" "$plist_path"
  /usr/bin/plutil -insert bundleIdentifier -string "$BUNDLE_ID" "$plist_path"
  /usr/bin/plutil -insert teamIdentifier -string "$GATEBEAM_DEVELOPER_TEAM_ID" "$plist_path"
  /usr/bin/plutil -insert cdhash -string "$APP_CDHASH" "$plist_path"
  /usr/bin/plutil -insert "$artifacts_key" -json '[]' "$plist_path"
  /usr/bin/plutil -insert "$artifacts_key.0" -json \
    "{\"name\":\"$app_name\",\"type\":\"app-archive\",\"sha256\":\"$APP_SHA256\"}" \
    "$plist_path"
  /usr/bin/plutil -insert "$artifacts_key.1" -json \
    "{\"name\":\"$pkg_name\",\"type\":\"installer-package\",\"sha256\":\"$PKG_SHA256\"}" \
    "$plist_path"
  /usr/bin/plutil -insert "$artifacts_key.2" -json \
    "{\"name\":\"$dmg_name\",\"type\":\"disk-image\",\"sha256\":\"$DMG_SHA256\"}" \
    "$plist_path"
  /usr/bin/plutil -insert "$notarization_key" -json '{}' "$plist_path"
  /usr/bin/plutil -insert "$notarization_key.app" -json \
    "{\"submissionId\":\"$APP_SUBMISSION_ID\",\"log\":\"notary-logs/app.json\"}" \
    "$plist_path"
  /usr/bin/plutil -insert "$notarization_key.pkg" -json \
    "{\"submissionId\":\"$PKG_SUBMISSION_ID\",\"log\":\"notary-logs/pkg.json\"}" \
    "$plist_path"
  /usr/bin/plutil -insert "$notarization_key.dmg" -json \
    "{\"submissionId\":\"$DMG_SUBMISSION_ID\",\"log\":\"notary-logs/dmg.json\"}" \
    "$plist_path"
  /usr/bin/plutil -convert json -o "$output_path" "$plist_path"
  /usr/bin/plutil -p "$output_path" >/dev/null
}

sanitize_environment

trap 'cleanup' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

require_environment GATEBEAM_CODE_SIGN_IDENTITY
require_environment GATEBEAM_DEVELOPER_TEAM_ID
require_environment GATEBEAM_INSTALLER_SIGN_IDENTITY
require_environment GATEBEAM_NOTARY_PROFILE

if [[ "$TEST_MODE" != "0" || -n "$TEST_TOOL_DIR" ]]; then
  validate_fixture_mode
fi

XCRUN="$(tool_path xcrun /usr/bin/xcrun)"
CODESIGN="$(tool_path codesign /usr/bin/codesign)"
PRODUCTSIGN="$(tool_path productsign /usr/bin/productsign)"
DITTO="$(tool_path ditto /usr/bin/ditto)"

[[ "$GATEBEAM_DEVELOPER_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] ||
  fail "GATEBEAM_DEVELOPER_TEAM_ID must be a 10-character Apple Team ID"
validate_identity_input \
  "$GATEBEAM_CODE_SIGN_IDENTITY" \
  "Developer ID Application" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
validate_identity_input \
  "$GATEBEAM_INSTALLER_SIGN_IDENTITY" \
  "Developer ID Installer" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
[[ "$GATEBEAM_NOTARY_PROFILE" != -* &&
    "$GATEBEAM_NOTARY_PROFILE" != *$'\n'* &&
    "$GATEBEAM_NOTARY_PROFILE" != *$'\r'* ]] ||
  fail "GATEBEAM_NOTARY_PROFILE is invalid"

[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] ||
  fail "Gatebeam Info.plist is missing or unsafe"
VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"
)" || fail "could not read Gatebeam version"
BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST"
)" || fail "could not read Gatebeam bundle identifier"
[[ "$VERSION" =~ '^[0-9]+([.][0-9]+){2}([-.][A-Za-z0-9.]+)?$' ]] ||
  fail "CFBundleShortVersionString is not a safe release version"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] ||
  fail "Gatebeam bundle identifier does not match the formal release contract"

if [[ -e "$DIST_DIR" || -L "$DIST_DIR" ]]; then
  assert_safe_dist
else
  mkdir "$DIST_DIR" ||
    fail "could not create the release output directory"
  assert_safe_dist
fi
RELEASE_DIR="$DIST_DIR/release-$VERSION"
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  fail "release destination already exists and will not be overwritten: $RELEASE_DIR"

WORKTREE_STATUS="$(git_safe -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"
[[ -z "$WORKTREE_STATUS" ]] ||
  fail "formal releases require a clean worktree"
HEAD_COMMIT="$(git_safe -C "$ROOT_DIR" rev-parse --verify HEAD^{commit})"
RELEASE_TAG="v$VERSION"
TAG_COMMIT="$(
  git_safe -C "$ROOT_DIR" rev-parse --verify "$RELEASE_TAG^{commit}" 2>/dev/null
)" || fail "required release tag is missing: $RELEASE_TAG"
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] ||
  fail "$RELEASE_TAG does not point exactly to HEAD"

PUBLISH_LOCK="$DIST_DIR/.release-$VERSION.lock"
assert_safe_dist
mkdir "$PUBLISH_LOCK" 2>/dev/null ||
  fail "another formal release is active or left a stale lock: $PUBLISH_LOCK"

TEMP_ROOT="$(mktemp -d "/private/tmp/gatebeam-formal-release.XXXXXX")"
SOURCE_ARCHIVE="$TEMP_ROOT/source.tar"
WORKSPACE_ROOT="$TEMP_ROOT/source"
mkdir -p "$WORKSPACE_ROOT"
git_safe -C "$ROOT_DIR" archive --format=tar "$HEAD_COMMIT" -o "$SOURCE_ARCHIVE"
/usr/bin/tar -xf "$SOURCE_ARCHIVE" -C "$WORKSPACE_ROOT"
rm -f -- "$SOURCE_ARCHIVE"

if [[ "$TEST_MODE" == "1" ]]; then
  TEST_TOOL_DIR="$WORKSPACE_ROOT/fake tools"
fi
export GATEBEAM_CODE_SIGN_IDENTITY
export GATEBEAM_DEVELOPER_TEAM_ID
export GATEBEAM_RELEASE_TEST_MODE="$TEST_MODE"
export GATEBEAM_RELEASE_TEST_TOOL_DIR="$TEST_TOOL_DIR"

print -u2 -- "Building Gatebeam $VERSION from $HEAD_COMMIT"
/bin/zsh -f "$WORKSPACE_ROOT/scripts/build_app.sh"

APP_PATH="$WORKSPACE_ROOT/dist/Gatebeam.app"
APP_ARCHIVE="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.zip"
UNSIGNED_PKG="$WORKSPACE_ROOT/build/Gatebeam-$VERSION.unsigned.pkg"
SIGNED_PKG="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.pkg"
SIGNED_PKG_CANDIDATE="$TEMP_ROOT/Gatebeam-$VERSION.signed.pkg"
SIGNED_DMG="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.dmg"
VERIFY_SCRIPT="$WORKSPACE_ROOT/scripts/verify_release.sh"

/bin/zsh -f "$VERIFY_SCRIPT" \
  app-signature \
  "$APP_PATH" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

"$DITTO" -c -k --keepParent "$APP_PATH" "$APP_ARCHIVE"
APP_SUBMISSION_ID="$(notarize_and_review app "$APP_ARCHIVE")"
"$XCRUN" stapler staple "$APP_PATH" ||
  fail "could not staple the application"
/bin/zsh -f "$VERIFY_SCRIPT" \
  app-stapled \
  "$APP_PATH" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

rm -f -- "$APP_ARCHIVE"
"$DITTO" -c -k --keepParent "$APP_PATH" "$APP_ARCHIVE"

/bin/zsh -f "$WORKSPACE_ROOT/scripts/package_pkg.sh"
verify_notarized_app_unchanged "PKG"
mv -f -- "$SIGNED_PKG" "$UNSIGNED_PKG"
if ! "$PRODUCTSIGN" \
  --sign "$GATEBEAM_INSTALLER_SIGN_IDENTITY" \
  --timestamp \
  "$UNSIGNED_PKG" \
  "$SIGNED_PKG_CANDIDATE"; then
  rm -f -- "$SIGNED_PKG_CANDIDATE"
  fail "could not sign the installer package"
fi
/bin/zsh -f "$VERIFY_SCRIPT" \
  pkg-signature \
  "$SIGNED_PKG_CANDIDATE" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
PKG_SUBMISSION_ID="$(notarize_and_review pkg "$SIGNED_PKG_CANDIDATE")"
"$XCRUN" stapler staple "$SIGNED_PKG_CANDIDATE" ||
  fail "could not staple the installer package"
/bin/zsh -f "$VERIFY_SCRIPT" \
  pkg-stapled \
  "$SIGNED_PKG_CANDIDATE" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
mv -- "$SIGNED_PKG_CANDIDATE" "$SIGNED_PKG"

/bin/zsh -f "$WORKSPACE_ROOT/scripts/package_dmg.sh"
verify_notarized_app_unchanged "DMG"
"$CODESIGN" \
  --force \
  --sign "$GATEBEAM_CODE_SIGN_IDENTITY" \
  --timestamp \
  "$SIGNED_DMG"
/bin/zsh -f "$VERIFY_SCRIPT" \
  dmg-signature \
  "$SIGNED_DMG" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
DMG_SUBMISSION_ID="$(notarize_and_review dmg "$SIGNED_DMG")"
"$XCRUN" stapler staple "$SIGNED_DMG" ||
  fail "could not staple the disk image"
/bin/zsh -f "$VERIFY_SCRIPT" \
  dmg-stapled \
  "$SIGNED_DMG" \
  "$VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

APP_SIGNING_DETAILS="$("$CODESIGN" -d --verbose=4 "$APP_PATH" 2>&1)" ||
  fail "could not read final application cdhash"
APP_CDHASH="$(
  print -r -- "$APP_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^CDHash=//p' |
    /usr/bin/head -n 1
)"
[[ "$APP_CDHASH" =~ '^[0-9A-Fa-f]{40,128}$' ]] ||
  fail "final application cdhash is missing or invalid"

assert_safe_dist
PUBLISH_STAGING="$(mktemp -d "$DIST_DIR/.release-$VERSION.XXXXXX")"
mkdir -p "$PUBLISH_STAGING/notary-logs"
"$DITTO" "$APP_ARCHIVE" "$PUBLISH_STAGING/${APP_ARCHIVE:t}"
"$DITTO" "$SIGNED_PKG" "$PUBLISH_STAGING/${SIGNED_PKG:t}"
"$DITTO" "$SIGNED_DMG" "$PUBLISH_STAGING/${SIGNED_DMG:t}"
"$DITTO" \
  "$WORKSPACE_ROOT/build/formal-notary-logs" \
  "$PUBLISH_STAGING/notary-logs"

APP_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${APP_ARCHIVE:t}" | /usr/bin/awk '{print $1}')"
PKG_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${SIGNED_PKG:t}" | /usr/bin/awk '{print $1}')"
DMG_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${SIGNED_DMG:t}" | /usr/bin/awk '{print $1}')"

(
  cd "$PUBLISH_STAGING"
  /usr/bin/shasum -a 256 \
    "${APP_ARCHIVE:t}" \
    "${SIGNED_PKG:t}" \
    "${SIGNED_DMG:t}" > SHA256SUMS
)
write_manifest "$PUBLISH_STAGING/release-manifest.json"
if /usr/bin/grep -Fq \
  "$GATEBEAM_NOTARY_PROFILE" \
  "$PUBLISH_STAGING/release-manifest.json" \
  "$PUBLISH_STAGING"/notary-logs/*.json; then
  fail "release metadata leaked the notary credential profile"
fi

inject_test_failure before-publish

assert_safe_dist
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  fail "release destination already exists and will not be overwritten: $RELEASE_DIR"
mv -- "$PUBLISH_STAGING" "$RELEASE_DIR"
PUBLISH_STAGING=""
rmdir -- "$PUBLISH_LOCK"
PUBLISH_LOCK=""

print -r -- "Formal release published: $RELEASE_DIR"
