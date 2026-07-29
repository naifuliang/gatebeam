#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset \
  BASH_ENV ENV ZDOTDIR CDPATH \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  LD_PRELOAD LD_LIBRARY_PATH \
  PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_REPLACE_REF_BASE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_EXTERNAL_DIFF \
  GITHUB_TOKEN GH_TOKEN \
  http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export PYTHONNOUSERSITE=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_NO_REPLACE_OBJECTS=1
export NO_PROXY="*"
export no_proxy="*"

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
CONTRACT="$ROOT_DIR/scripts/release_artifact_contract.py"
CONTAINER_CONTRACT="$ROOT_DIR/scripts/release_container_contract.py"
VERIFY_RELEASE="$ROOT_DIR/scripts/verify_release.sh"
INSTALL_APP="$ROOT_DIR/scripts/install_app.sh"
PACKAGE_SCRIPTS="$ROOT_DIR/scripts/pkg"
EXPECTED_REPOSITORY="naifuliang/gatebeam"
EXPECTED_WORKFLOW="Release final-artifact validation"
EXPECTED_WORKFLOW_PATH=".github/workflows/release-validation.yml"
EXPECTED_BUNDLE_ID="io.github.naifuliang.gatebeam"
FIXTURE_MARKER=".gatebeam-final-artifact-test-fixture"
TEST_MODE="${GATEBEAM_FINAL_ARTIFACT_TEST_MODE:-0}"
TEST_TOOL_DIR="${GATEBEAM_FINAL_ARTIFACT_TEST_TOOL_DIR:-}"
ZIP_MAXIMUM="${GATEBEAM_FINAL_ARTIFACT_TEST_ZIP_MAXIMUM:-4294967296}"
TEMP_ROOT=""
DMG_MOUNT=""
SYSTEM_APP="${GATEBEAM_FINAL_ARTIFACT_TEST_SYSTEM_APP:-/Applications/Gatebeam.app}"
PKGUTIL="/usr/sbin/pkgutil"
HDIUTIL="/usr/bin/hdiutil"
LSBOM="/usr/bin/lsbom"
CODESIGN="/usr/bin/codesign"
SUDO="/usr/bin/sudo"
INSTALLER="/usr/sbin/installer"
XAR="/usr/bin/xar"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

cleanup_system_install() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -e "$SYSTEM_APP" && ! -L "$SYSTEM_APP" ]]; then
    "$SUDO" /bin/rm -rf -- "$SYSTEM_APP" 2>/dev/null || true
  fi
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    "$SUDO" "$PKGUTIL" --forget "$EXPECTED_BUNDLE_ID" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$DMG_MOUNT" && -d "$DMG_MOUNT" ]]; then
    "$HDIUTIL" detach "$DMG_MOUNT" -force >/dev/null 2>&1 || true
  fi
  cleanup_system_install
  [[ -z "$TEMP_ROOT" ]] || /bin/rm -rf -- "$TEMP_ROOT"
}

handle_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
}

require_environment() {
  local variable_name="$1"
  [[ -n "${(P)variable_name:-}" ]] ||
    fail "$variable_name is required for final candidate validation"
}

git_safe() {
  /usr/bin/git \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.attributesfile=/dev/null \
    "$@"
}

validate_fixture_tools() {
  local canonical_tool_dir
  [[ "$TEST_MODE" == "1" && -n "$TEST_TOOL_DIR" &&
      "$ROOT_DIR" == /private/tmp/* &&
      -f "$ROOT_DIR/$FIXTURE_MARKER" &&
      ! -L "$ROOT_DIR/$FIXTURE_MARKER" &&
      "$(<"$ROOT_DIR/$FIXTURE_MARKER")" == "Gatebeam final artifact test fixture v1" ]] ||
    fail "final artifact tool overrides require a marked /private/tmp fixture"
  canonical_tool_dir="$(cd -P "$TEST_TOOL_DIR" 2>/dev/null && pwd -P)" ||
    fail "final artifact test tool directory is invalid"
  [[ "$canonical_tool_dir" == "$TEST_TOOL_DIR" &&
      "$canonical_tool_dir" == "$ROOT_DIR/"* &&
      -f "$canonical_tool_dir/$FIXTURE_MARKER" &&
      ! -L "$canonical_tool_dir/$FIXTURE_MARKER" ]] ||
    fail "final artifact test tool directory escaped its fixture"
  [[ "$SYSTEM_APP" == "$ROOT_DIR/test-system/Applications/Gatebeam.app" ]] ||
    fail "final artifact test installation path escaped its fixture"
}

tool_path() {
  local name="$1"
  local system_path="$2"
  local candidate
  if [[ "$TEST_MODE" == "0" ]]; then
    print -r -- "$system_path"
    return
  fi
  validate_fixture_tools
  candidate="$TEST_TOOL_DIR/$name"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    fail "final artifact test tool is missing or unsafe: $name"
  print -r -- "$candidate"
}

validate_context() {
  local expected_tag="$1"
  local expected_commit="$2"
  local expected_workflow_ref="$EXPECTED_REPOSITORY/$EXPECTED_WORKFLOW_PATH@refs/tags/$expected_tag"

  if [[ "$TEST_MODE" == "1" ]]; then
    [[ "$ROOT_DIR" == /private/tmp/* &&
        -f "$ROOT_DIR/$FIXTURE_MARKER" &&
        ! -L "$ROOT_DIR/$FIXTURE_MARKER" &&
        "$(<"$ROOT_DIR/$FIXTURE_MARKER")" == "Gatebeam final artifact test fixture v1" ]] ||
      fail "final artifact test mode requires a marked /private/tmp fixture"
  else
    [[ "$TEST_MODE" == "0" ]] ||
      fail "GATEBEAM_FINAL_ARTIFACT_TEST_MODE must be 0 or 1"
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] ||
      fail "final candidate validation must run on an isolated GitHub Actions macOS runner"
  fi

  [[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" &&
      "${GITHUB_WORKFLOW:-}" == "$EXPECTED_WORKFLOW" &&
      "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" &&
      "${GITHUB_JOB:-}" == "clean-machine" ]] ||
    fail "final candidate validation has the wrong repository, workflow, event, or job"
  [[ "${GITHUB_REF_TYPE:-}" == "tag" &&
      "${GITHUB_REF_NAME:-}" == "$expected_tag" &&
      "${GITHUB_REF:-}" == "refs/tags/$expected_tag" &&
      "${GITHUB_SHA:-}" == "$expected_commit" ]] ||
    fail "final candidate validation is not bound to the exact release tag"
  [[ "${GITHUB_WORKFLOW_REF:-}" == "$expected_workflow_ref" &&
      "${GITHUB_WORKFLOW_SHA:-}" == "$expected_commit" ]] ||
    fail "final candidate validation is not using the tagged workflow bytes"
  [[ "${GITHUB_REPOSITORY_ID:-}" =~ '^[1-9][0-9]*$' &&
      "${GITHUB_RUN_ID:-}" =~ '^[1-9][0-9]*$' &&
      "${GITHUB_RUN_ATTEMPT:-}" =~ '^[1-9][0-9]*$' ]] ||
    fail "final candidate validation has invalid GitHub identity numbers"
  [[ "${GATEBEAM_CANDIDATE_ARTIFACT_ID:-}" =~ '^[1-9][0-9]*$' &&
      "${GATEBEAM_CANDIDATE_ARTIFACT_DIGEST:-}" =~ '^[0-9a-f]{64}$' &&
      "${GATEBEAM_CANDIDATE_ARTIFACT_NAME:-}" =~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,239}$' &&
      "${GATEBEAM_ATTESTATION_ARTIFACT_NAME:-}" =~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,239}$' ]] ||
    fail "final candidate artifact identity is invalid"
}

metadata() {
  /usr/bin/python3 -I -E -s "$CONTRACT" metadata \
    --root "$CANDIDATE_ROOT" \
    --field "$1"
}

validate_app_tree() {
  /usr/bin/python3 -I -E -s - "$1" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
if not root.is_absolute() or root.is_symlink() or not root.is_dir():
    raise SystemExit(1)
if root.resolve(strict=True) != root:
    raise SystemExit(2)
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    directory_path = pathlib.Path(directory)
    directory_stat = directory_path.lstat()
    if not stat.S_ISDIR(directory_stat.st_mode) or stat.S_ISLNK(directory_stat.st_mode):
        raise SystemExit(3)
    for name in [*names, *files]:
        entry = (directory_path / name).lstat()
        if stat.S_ISLNK(entry.st_mode):
            raise SystemExit(4)
        if not stat.S_ISDIR(entry.st_mode) and (
            not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1
        ):
            raise SystemExit(5)
PY
}

find_payload_app() {
  /usr/bin/python3 -I -E -s - "$1" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
matches = [
    path
    for path in root.rglob("Gatebeam.app")
    if path.parent.name == "Payload" and path.is_dir() and not path.is_symlink()
]
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0].resolve(strict=True))
PY
}

app_cdhash() {
  "$CODESIGN" -d --verbose=4 "$1" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p' |
    /usr/bin/head -n 1
}

verify_same_app_identity() {
  local candidate="$1"
  local label="$2"
  local candidate_hash

  candidate_hash="$(app_cdhash "$candidate")" ||
    fail "could not read $label application cdhash"
  [[ "$candidate_hash" == "$FINAL_APP_CDHASH" ]] ||
    fail "$label does not contain the exact signed application identity"
}

verify_installed_app() {
  local expected_version="$1"
  local expected_build="$2"

  [[ -d "$SYSTEM_APP" && ! -L "$SYSTEM_APP" ]] ||
    fail "Installer did not create the expected application"
  /bin/zsh -f "$VERIFY_RELEASE" app-stapled \
    "$SYSTEM_APP" \
    "$expected_version" \
    "$expected_build" \
    "$EXPECTED_BUNDLE_ID" \
    "$TEAM_ID"
}

install_package() {
  local package_path="$1"
  "$SUDO" "$INSTALLER" -pkg "$package_path" -target / >/dev/null ||
    fail "macOS Installer rejected ${package_path:t}"
}

uninstall_system_app() {
  "$SUDO" /bin/rm -rf -- "$SYSTEM_APP"
  "$SUDO" "$PKGUTIL" --forget "$EXPECTED_BUNDLE_ID" >/dev/null 2>&1 || true
  [[ ! -e "$SYSTEM_APP" && ! -L "$SYSTEM_APP" ]] ||
    fail "uninstall left the system application behind"
}

[[ $# -eq 2 ]] ||
  fail "usage: validate_final_candidate.sh <candidate-root> <attestation-output>"

[[ "$1" == /* && "$1" != */ && -d "$1" && ! -L "$1" ]] ||
  fail "candidate root is missing or unsafe"
candidate_parent="$(cd -P "${1:h}" && pwd -P)" ||
  fail "candidate root parent could not be resolved"
[[ "$1" == "$candidate_parent/${1:t}" ]] ||
  fail "candidate root must use a canonical path without linked parents"
CANDIDATE_ROOT="$1"

[[ "$2" == /* && "$2" != */ ]] ||
  fail "attestation output path is unsafe"
attestation_parent="$(cd -P "${2:h}" && pwd -P)" ||
  fail "attestation output parent could not be resolved"
[[ "$2" == "$attestation_parent/${2:t}" ]] ||
  fail "attestation output must use a canonical path without linked parents"
ATTESTATION_OUTPUT="$2"
[[ ! -e "$ATTESTATION_OUTPUT" && ! -L "$ATTESTATION_OUTPUT" ]] ||
  fail "attestation output already exists"
[[ -d "${ATTESTATION_OUTPUT:h}" && ! -L "${ATTESTATION_OUTPUT:h}" ]] ||
  fail "attestation output parent is unsafe"
[[ -f "$CONTRACT" && ! -L "$CONTRACT" &&
    -f "$CONTAINER_CONTRACT" && ! -L "$CONTAINER_CONTRACT" &&
    -f "$VERIFY_RELEASE" && ! -L "$VERIFY_RELEASE" &&
    -f "$INSTALL_APP" && ! -L "$INSTALL_APP" &&
    -d "$PACKAGE_SCRIPTS" && ! -L "$PACKAGE_SCRIPTS" ]] ||
  fail "final artifact validation scripts are missing or unsafe"

require_environment GITHUB_REPOSITORY
require_environment GITHUB_REPOSITORY_ID
require_environment GITHUB_WORKFLOW
require_environment GITHUB_WORKFLOW_REF
require_environment GITHUB_WORKFLOW_SHA
require_environment GITHUB_RUN_ID
require_environment GITHUB_RUN_ATTEMPT
require_environment GITHUB_EVENT_NAME
require_environment GITHUB_JOB
require_environment GITHUB_REF
require_environment GITHUB_REF_TYPE
require_environment GITHUB_REF_NAME
require_environment GITHUB_SHA
require_environment GATEBEAM_CANDIDATE_ARTIFACT_ID
require_environment GATEBEAM_CANDIDATE_ARTIFACT_DIGEST
require_environment GATEBEAM_CANDIDATE_ARTIFACT_NAME
require_environment GATEBEAM_ATTESTATION_ARTIFACT_NAME
validate_context "$GITHUB_REF_NAME" "$GITHUB_SHA"
if [[ "$TEST_MODE" == "1" || -n "$TEST_TOOL_DIR" ||
      "$SYSTEM_APP" != "/Applications/Gatebeam.app" ]]; then
  validate_fixture_tools
fi
[[ "$ZIP_MAXIMUM" =~ '^[1-9][0-9]*$' && "$ZIP_MAXIMUM" -le 4294967296 ]] ||
  fail "application ZIP extraction limit is invalid"
if [[ "$TEST_MODE" == "0" && "$ZIP_MAXIMUM" != "4294967296" ]]; then
  fail "application ZIP extraction limit override is restricted to marked fixtures"
fi
PKGUTIL="$(tool_path pkgutil /usr/sbin/pkgutil)"
HDIUTIL="$(tool_path hdiutil /usr/bin/hdiutil)"
LSBOM="$(tool_path lsbom /usr/bin/lsbom)"
CODESIGN="$(tool_path codesign /usr/bin/codesign)"
SUDO="$(tool_path sudo /usr/bin/sudo)"
INSTALLER="$(tool_path installer /usr/sbin/installer)"
XAR="$(tool_path xar /usr/bin/xar)"
if [[ "$TEST_MODE" == "1" ]]; then
  VERIFY_RELEASE="$(tool_path verify_release /bin/false)"
  INSTALL_APP="$(tool_path install_app /bin/false)"
fi

typeset -a CONTEXT_ARGS
CONTEXT_ARGS=(
  --repository-id "$GITHUB_REPOSITORY_ID"
  --workflow-ref "$GITHUB_WORKFLOW_REF"
  --workflow-sha "$GITHUB_WORKFLOW_SHA"
  --run-id "$GITHUB_RUN_ID"
  --run-attempt "$GITHUB_RUN_ATTEMPT"
  --commit "$GITHUB_SHA"
  --tag "$GITHUB_REF_NAME"
  --artifact-name "$GATEBEAM_CANDIDATE_ARTIFACT_NAME"
  --attestation-name "$GATEBEAM_ATTESTATION_ARTIFACT_NAME"
)
/usr/bin/python3 -I -E -s "$CONTRACT" validate-candidate \
  --root "$CANDIDATE_ROOT" \
  "${CONTEXT_ARGS[@]}" ||
  fail "downloaded final candidate failed its byte contract"

VERSION="$(metadata version)"
BUILD_VERSION="$(metadata build-version)"
TEAM_ID="$(metadata team-id)"
BOOTSTRAP="$(metadata bootstrap)"
PREVIOUS_VERSION="$(metadata previous-version)"
PREVIOUS_BUILD_VERSION="$(metadata previous-build-version)"
PREVIOUS_PACKAGE_RELATIVE="$(metadata previous-package)"
PREVIOUS_COMMIT="$(metadata previous-commit)"
CURRENT_ZIP_SHA256="$(metadata app-archive-sha256)"
CURRENT_ZIP="$CANDIDATE_ROOT/Gatebeam-$VERSION.zip"
CURRENT_PKG="$CANDIDATE_ROOT/Gatebeam-$VERSION.pkg"
CURRENT_DMG="$CANDIDATE_ROOT/Gatebeam-$VERSION.dmg"

for container_path in "$CURRENT_ZIP" "$CURRENT_PKG" "$CURRENT_DMG"; do
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-container-file \
    --path "$container_path" ||
    fail "final candidate contains an unsafe or oversized sparse container"
done

TEMP_ROOT="$(/usr/bin/mktemp -d "/private/tmp/gatebeam-final-candidate.XXXXXX")"
trap 'cleanup' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

APP_EXTRACT_ROOT="$TEMP_ROOT/app"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" extract-app-zip \
  --archive "$CURRENT_ZIP" \
  --output "$APP_EXTRACT_ROOT" \
  --expected-digest "$CURRENT_ZIP_SHA256" \
  --maximum-total "$ZIP_MAXIMUM" ||
  fail "application archive failed its structural allowlist"
if [[ "$TEST_MODE" == "1" && -x "$TEST_TOOL_DIR/post_extract" ]]; then
  "$TEST_TOOL_DIR/post_extract" "$APP_EXTRACT_ROOT"
fi
FINAL_APP="$APP_EXTRACT_ROOT/Gatebeam.app"
FINAL_TREE_DIGEST_PATH="$TEMP_ROOT/final-app-tree-digest"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-app \
  --root "$FINAL_APP" \
  --identifier "$EXPECTED_BUNDLE_ID" \
  --version "$VERSION" \
  --build "$BUILD_VERSION" \
  --output-digest "$FINAL_TREE_DIGEST_PATH" ||
  fail "application archive failed the exact Gatebeam app allowlist"
FINAL_TREE_DIGEST="$(<"$FINAL_TREE_DIGEST_PATH")"
/bin/zsh -f "$VERIFY_RELEASE" app-stapled \
  "$FINAL_APP" "$VERSION" "$BUILD_VERSION" "$EXPECTED_BUNDLE_ID" "$TEAM_ID"
FINAL_APP_CDHASH="$(app_cdhash "$FINAL_APP")"
[[ "$FINAL_APP_CDHASH" =~ '^[0-9A-Fa-f]{40,128}$' ]] ||
  fail "final application cdhash is invalid"

/bin/zsh -f "$VERIFY_RELEASE" pkg-stapled \
  "$CURRENT_PKG" "$VERSION" "$BUILD_VERSION" "$EXPECTED_BUNDLE_ID" "$TEAM_ID"
PKG_TOC="$TEMP_ROOT/current-pkg-toc.xml"
"$XAR" --dump-toc="$PKG_TOC" -f "$CURRENT_PKG" >/dev/null ||
  fail "final installer package XAR TOC could not be read"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-pkg-toc \
  --toc "$PKG_TOC" ||
  fail "final installer package failed its raw XAR allowlist or budget"
PKG_RAW="$TEMP_ROOT/current-pkg-raw"
/bin/mkdir "$PKG_RAW"
"$XAR" -xf "$CURRENT_PKG" -C "$PKG_RAW" >/dev/null ||
  fail "final installer package raw component could not be expanded"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-raw-pkg \
  --root "$PKG_RAW" ||
  fail "final installer package failed its pre-extraction payload budget or allowlist"
PKG_EXPANDED="$TEMP_ROOT/current-pkg"
"$PKGUTIL" --expand-full "$CURRENT_PKG" "$PKG_EXPANDED" >/dev/null ||
  fail "final installer package could not be expanded"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-expanded-pkg-root \
  --root "$PKG_EXPANDED" ||
  fail "final installer package exceeded its expanded allowlist or budget"
typeset -a PKG_BOM_PATHS
PKG_BOM_PATHS=("${(@f)$(/usr/bin/find "$PKG_EXPANDED" -name Bom -type f -print)}")
[[ ${#PKG_BOM_PATHS[@]} -eq 1 ]] ||
  fail "final installer package must contain exactly one BOM"
PKG_BOM_LIST="$TEMP_ROOT/current-pkg-bom-list"
"$LSBOM" -s "$PKG_BOM_PATHS[1]" >"$PKG_BOM_LIST" ||
  fail "final installer package BOM could not be read"
PKG_APP_PATH="$TEMP_ROOT/current-pkg-app-path"
PKG_TREE_DIGEST_PATH="$TEMP_ROOT/current-pkg-tree-digest"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-pkg \
  --root "$PKG_EXPANDED" \
  --identifier "$EXPECTED_BUNDLE_ID" \
  --version "$VERSION" \
  --build "$BUILD_VERSION" \
  --scripts-root "$PACKAGE_SCRIPTS" \
  --bom-list "$PKG_BOM_LIST" \
  --output-app "$PKG_APP_PATH" \
  --output-digest "$PKG_TREE_DIGEST_PATH" ||
  fail "final installer package failed its component, payload, BOM, or script allowlist"
PKG_APP="$(<"$PKG_APP_PATH")"
[[ "$(<"$PKG_TREE_DIGEST_PATH")" == "$FINAL_TREE_DIGEST" ]] ||
  fail "final installer package payload differs from the app ZIP"
/bin/zsh -f "$VERIFY_RELEASE" app-stapled \
  "$PKG_APP" "$VERSION" "$BUILD_VERSION" "$EXPECTED_BUNDLE_ID" "$TEAM_ID"
verify_same_app_identity "$PKG_APP" "installer package"

/bin/zsh -f "$VERIFY_RELEASE" dmg-stapled \
  "$CURRENT_DMG" "$VERSION" "$BUILD_VERSION" "$EXPECTED_BUNDLE_ID" "$TEAM_ID"
DMG_MOUNT="$TEMP_ROOT/dmg"
/bin/mkdir "$DMG_MOUNT"
"$HDIUTIL" attach \
  -readonly -nobrowse -mountpoint "$DMG_MOUNT" "$CURRENT_DMG" >/dev/null ||
  fail "final disk image could not be mounted read-only"
DMG_APP_PATH="$TEMP_ROOT/dmg-app-path"
DMG_TREE_DIGEST_PATH="$TEMP_ROOT/dmg-tree-digest"
/usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-dmg \
  --root "$DMG_MOUNT" \
  --identifier "$EXPECTED_BUNDLE_ID" \
  --version "$VERSION" \
  --build "$BUILD_VERSION" \
  --output-app "$DMG_APP_PATH" \
  --output-digest "$DMG_TREE_DIGEST_PATH" ||
  fail "final disk image failed its root allowlist"
DMG_APP="$(<"$DMG_APP_PATH")"
[[ "$(<"$DMG_TREE_DIGEST_PATH")" == "$FINAL_TREE_DIGEST" ]] ||
  fail "final disk image app differs from the app ZIP"
/bin/zsh -f "$VERIFY_RELEASE" app-stapled \
  "$DMG_APP" "$VERSION" "$BUILD_VERSION" "$EXPECTED_BUNDLE_ID" "$TEAM_ID"
verify_same_app_identity "$DMG_APP" "disk image"
"$HDIUTIL" detach "$DMG_MOUNT" >/dev/null ||
  fail "final disk image could not be detached cleanly"
DMG_MOUNT=""

[[ ! -e "$SYSTEM_APP" && ! -L "$SYSTEM_APP" ]] ||
  fail "clean runner already contains Gatebeam in /Applications"
install_package "$CURRENT_PKG"
verify_installed_app "$VERSION" "$BUILD_VERSION"
uninstall_system_app

PREVIOUS_APP=""
PREVIOUS_PKG=""
if [[ "$BOOTSTRAP" == "0" ]]; then
  PREVIOUS_PKG="$CANDIDATE_ROOT/$PREVIOUS_PACKAGE_RELATIVE"
  /bin/zsh -f "$VERIFY_RELEASE" pkg-stapled \
    "$PREVIOUS_PKG" \
    "$PREVIOUS_VERSION" \
    "$PREVIOUS_BUILD_VERSION" \
    "$EXPECTED_BUNDLE_ID" \
    "$TEAM_ID"
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-container-file \
    --path "$PREVIOUS_PKG" ||
    fail "rollback package is unsafe, oversized, or sparse"
  PREVIOUS_PKG_TOC="$TEMP_ROOT/previous-pkg-toc.xml"
  "$XAR" --dump-toc="$PREVIOUS_PKG_TOC" -f "$PREVIOUS_PKG" >/dev/null ||
    fail "rollback package XAR TOC could not be read"
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-pkg-toc \
    --toc "$PREVIOUS_PKG_TOC" ||
    fail "rollback package failed its raw XAR allowlist or budget"
  PREVIOUS_RAW="$TEMP_ROOT/previous-pkg-raw"
  /bin/mkdir "$PREVIOUS_RAW"
  "$XAR" -xf "$PREVIOUS_PKG" -C "$PREVIOUS_RAW" >/dev/null ||
    fail "rollback package raw component could not be expanded"
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-raw-pkg \
    --root "$PREVIOUS_RAW" ||
    fail "rollback package failed its pre-extraction payload budget or allowlist"
  PREVIOUS_EXPANDED="$TEMP_ROOT/previous-pkg"
  "$PKGUTIL" --expand-full "$PREVIOUS_PKG" "$PREVIOUS_EXPANDED" >/dev/null ||
    fail "rollback package could not be expanded"
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-expanded-pkg-root \
    --root "$PREVIOUS_EXPANDED" ||
    fail "rollback package exceeded its expanded allowlist or budget"
  typeset -a PREVIOUS_BOM_PATHS
  PREVIOUS_BOM_PATHS=("${(@f)$(/usr/bin/find "$PREVIOUS_EXPANDED" -name Bom -type f -print)}")
  [[ ${#PREVIOUS_BOM_PATHS[@]} -eq 1 ]] ||
    fail "rollback package must contain exactly one BOM"
  PREVIOUS_BOM_LIST="$TEMP_ROOT/previous-pkg-bom-list"
  "$LSBOM" -s "$PREVIOUS_BOM_PATHS[1]" >"$PREVIOUS_BOM_LIST" ||
    fail "rollback package BOM could not be read"
  PREVIOUS_APP_PATH="$TEMP_ROOT/previous-pkg-app-path"
  PREVIOUS_TREE_DIGEST_PATH="$TEMP_ROOT/previous-pkg-tree-digest"
  PREVIOUS_PACKAGE_SCRIPTS="$TEMP_ROOT/previous-package-scripts"
  /bin/mkdir "$PREVIOUS_PACKAGE_SCRIPTS"
  for script_name in postinstall migrate_legacy_install.sh; do
    [[ "$(git_safe -C "$ROOT_DIR" cat-file -t "$PREVIOUS_COMMIT:scripts/pkg/$script_name")" ==
        "blob" ]] ||
      fail "rollback package script source is missing from its tagged commit"
    git_safe -C "$ROOT_DIR" show \
      "$PREVIOUS_COMMIT:scripts/pkg/$script_name" \
      >"$PREVIOUS_PACKAGE_SCRIPTS/$script_name" ||
      fail "rollback package script source could not be read"
  done
  /usr/bin/python3 -I -E -s "$CONTAINER_CONTRACT" validate-pkg \
    --root "$PREVIOUS_EXPANDED" \
    --identifier "$EXPECTED_BUNDLE_ID" \
    --version "$PREVIOUS_VERSION" \
    --build "$PREVIOUS_BUILD_VERSION" \
    --scripts-root "$PREVIOUS_PACKAGE_SCRIPTS" \
    --bom-list "$PREVIOUS_BOM_LIST" \
    --output-app "$PREVIOUS_APP_PATH" \
    --output-digest "$PREVIOUS_TREE_DIGEST_PATH" ||
    fail "rollback package failed its component, payload, BOM, or script allowlist"
  PREVIOUS_APP="$(<"$PREVIOUS_APP_PATH")"
  /bin/zsh -f "$VERIFY_RELEASE" app-stapled \
    "$PREVIOUS_APP" \
    "$PREVIOUS_VERSION" \
    "$PREVIOUS_BUILD_VERSION" \
    "$EXPECTED_BUNDLE_ID" \
    "$TEAM_ID"

  install_package "$PREVIOUS_PKG"
  verify_installed_app "$PREVIOUS_VERSION" "$PREVIOUS_BUILD_VERSION"
  install_package "$CURRENT_PKG"
  verify_installed_app "$VERSION" "$BUILD_VERSION"
  install_package "$PREVIOUS_PKG"
  verify_installed_app "$PREVIOUS_VERSION" "$PREVIOUS_BUILD_VERSION"
  install_package "$CURRENT_PKG"
  verify_installed_app "$VERSION" "$BUILD_VERSION"
else
  install_package "$CURRENT_PKG"
  verify_installed_app "$VERSION" "$BUILD_VERSION"
fi
uninstall_system_app

TEST_HOME="$TEMP_ROOT/home"
TEST_APPLICATIONS="$TEST_HOME/Applications"
/bin/mkdir -p "$TEST_HOME"
ROLLBACK_SOURCE="$FINAL_APP"
ROLLBACK_VERSION="$VERSION"
ROLLBACK_BUILD="$BUILD_VERSION"
if [[ "$BOOTSTRAP" == "0" ]]; then
  ROLLBACK_SOURCE="$PREVIOUS_APP"
  ROLLBACK_VERSION="$PREVIOUS_VERSION"
  ROLLBACK_BUILD="$PREVIOUS_BUILD_VERSION"
fi
GATEBEAM_APP_DIR="$ROLLBACK_SOURCE" \
GATEBEAM_INSTALL_DIR="$TEST_APPLICATIONS" \
GATEBEAM_USER_HOME="$TEST_HOME" \
  /bin/zsh -f "$INSTALL_APP" >/dev/null
if GATEBEAM_APP_DIR="$FINAL_APP" \
   GATEBEAM_INSTALL_DIR="$TEST_APPLICATIONS" \
   GATEBEAM_USER_HOME="$TEST_HOME" \
   GATEBEAM_TEST_FAILURE_POINT=after-app-swap \
     /bin/zsh -f "$INSTALL_APP" >/dev/null 2>&1; then
  fail "injected application upgrade failure unexpectedly succeeded"
fi
/bin/zsh -f "$VERIFY_RELEASE" app-stapled \
  "$TEST_APPLICATIONS/Gatebeam.app" \
  "$ROLLBACK_VERSION" \
  "$ROLLBACK_BUILD" \
  "$EXPECTED_BUNDLE_ID" \
  "$TEAM_ID" ||
  fail "failed upgrade did not restore the previously installed application"
/bin/rm -rf -- "$TEST_APPLICATIONS/Gatebeam.app"
/bin/rm -f -- \
  "$TEST_HOME/Library/LaunchAgents/com.local.RemoteControlNetwork.login.plist" \
  "$TEST_HOME/Library/LaunchAgents/io.github.naifuliang.gatebeam.login.plist"
[[ -z "$(/usr/bin/find "$TEST_HOME" -name '.gatebeam-install.*' -print -quit)" ]] ||
  fail "uninstall left a transaction directory"

/usr/bin/python3 -I -E -s "$CONTRACT" create-attestation \
  --root "$CANDIDATE_ROOT" \
  --output "$ATTESTATION_OUTPUT" \
  --artifact-id "$GATEBEAM_CANDIDATE_ARTIFACT_ID" \
  --artifact-digest "$GATEBEAM_CANDIDATE_ARTIFACT_DIGEST" \
  "${CONTEXT_ARGS[@]}" ||
  fail "could not create the final candidate attestation"

print -r -- "Final candidate validation passed: $VERSION ($BUILD_VERSION)"
