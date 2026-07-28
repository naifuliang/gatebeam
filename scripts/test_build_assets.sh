#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/Gatebeam.app"
BUILT_ICON="$ROOT_DIR/build/icon/AppIcon.icns"
FIXTURE_PARENT="${GATEBEAM_TEST_TMPDIR:-/private/tmp}"
FIXTURE_ROOT="$(mktemp -d "$FIXTURE_PARENT/gatebeam-package-tests.XXXXXX")"
TRACKED_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon-Source.png"
TRACKED_ICON_PRODUCT="$ROOT_DIR/Resources/AppIcon.icns"
TRACKED_ICON_HASH_BEFORE="$(
  git -C "$ROOT_DIR" hash-object -- "$TRACKED_ICON_SOURCE" "$TRACKED_ICON_PRODUCT"
)"
TRACKED_ICON_DIFF_BEFORE="$FIXTURE_ROOT/tracked-icon-before.diff"
git -C "$ROOT_DIR" diff --binary -- \
  "$TRACKED_ICON_SOURCE" "$TRACKED_ICON_PRODUCT" > "$TRACKED_ICON_DIFF_BEFORE"
HARDENED_SCRIPTS=(
  build_app.sh
  build_backend_diagnostics.sh
  build_icon.sh
  package_dmg.sh
  package_pkg.sh
  probe_library_validation.sh
  render_ui_snapshots.sh
  test_backend.sh
  test_build_assets.sh
  test_integration_contract.sh
  test_privacy.sh
  test_proxy_policy.sh
  test_ui_validation.sh
  test_upgrade.sh
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  rm -rf -- "$FIXTURE_ROOT"
}
trap 'cleanup' EXIT HUP INT TERM

copy_fixture() {
  mkdir -p "$FIXTURE_ROOT/project"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$ROOT_DIR/Resources" "$FIXTURE_ROOT/project/Resources"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$ROOT_DIR/Sources" "$FIXTURE_ROOT/project/Sources"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$ROOT_DIR/scripts" "$FIXTURE_ROOT/project/scripts"
}

assert_valid_app() {
  local app_path="$1"
  [[ -x "$app_path/Contents/MacOS/Gatebeam" ]] || fail "missing rebuilt Gatebeam executable"
  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
    fail "rebuilt Gatebeam app failed signature validation"
}

assert_raw_package_clean() {
  local package_path="$1"
  local raw_dir="$FIXTURE_ROOT/raw-package"
  local bom_paths="$FIXTURE_ROOT/raw-bom-paths"
  local payload_paths="$FIXTURE_ROOT/raw-payload-paths"
  local scripts_paths="$FIXTURE_ROOT/raw-scripts-paths"
  local payload_verbose="$FIXTURE_ROOT/raw-payload-verbose"

  rm -rf "$raw_dir"
  mkdir -p "$raw_dir"
  xar -xf "$package_path" -C "$raw_dir"

  [[ "$(file -b "$raw_dir/Payload")" == gzip\ compressed\ data* ]] ||
    fail "raw PKG Payload is not gzip cpio"
  [[ "$(file -b "$raw_dir/Scripts")" == gzip\ compressed\ data* ]] ||
    fail "raw PKG Scripts is not gzip cpio"

  lsbom -s "$raw_dir/Bom" | LC_ALL=C sort > "$bom_paths"
  gzip -dc "$raw_dir/Payload" | cpio -it 2>/dev/null | LC_ALL=C sort > "$payload_paths"
  gzip -dc "$raw_dir/Scripts" | cpio -it 2>/dev/null | LC_ALL=C sort > "$scripts_paths"

  if grep -E '(^|/)\._|(^|/)\.DS_Store$' "$bom_paths" "$payload_paths" "$scripts_paths" >/dev/null; then
    fail "raw PKG BOM or cpio contains AppleDouble or Finder metadata"
  fi
  cmp -s "$bom_paths" "$payload_paths" ||
    fail "raw PKG BOM and Payload path lists differ"

  lsbom "$raw_dir/Bom" | awk '$3 != "0/0" { exit 1 }' ||
    fail "raw PKG BOM contains non-root ownership"
  gzip -dc "$raw_dir/Payload" | cpio -itv > "$payload_verbose" 2>/dev/null
  awk 'NF >= 4 && ($3 != "root" || $4 != "wheel") { exit 1 }' "$payload_verbose" ||
    fail "raw PKG Payload contains non-root ownership"
}

run_with_hostile_zshenv() {
  local script_path="$1"
  shift
  env \
    HOME="$FIXTURE_ROOT/home" \
    CFFIXED_USER_HOME="$FIXTURE_ROOT/home" \
    TMPDIR="$FIXTURE_ROOT/tmp" \
    ZDOTDIR="$FIXTURE_ROOT/hostile-zdotdir" \
    GATEBEAM_ZSHENV_SENTINEL="$FIXTURE_ROOT/zshenv-was-loaded" \
    "$script_path" "$@"
}

for script_name in "${HARDENED_SCRIPTS[@]}"; do
  [[ "$(head -n 1 "$ROOT_DIR/scripts/$script_name")" == "#!/bin/zsh -f" ]] ||
    fail "$script_name does not disable zsh startup files"
done

/bin/zsh -f "$ROOT_DIR/scripts/build_icon.sh"
/bin/zsh -f "$ROOT_DIR/scripts/build_app.sh"
/bin/zsh -f "$ROOT_DIR/scripts/package_dmg.sh" --validate-only

[[ -s "$BUILT_ICON" ]]
file "$BUILT_ICON" | grep -q 'Mac OS X icon'
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

TRACKED_ICON_HASH_AFTER="$(
  git -C "$ROOT_DIR" hash-object -- "$TRACKED_ICON_SOURCE" "$TRACKED_ICON_PRODUCT"
)"
[[ "$TRACKED_ICON_HASH_AFTER" == "$TRACKED_ICON_HASH_BEFORE" ]] ||
  fail "build changed a tracked icon file"
TRACKED_ICON_DIFF_AFTER="$FIXTURE_ROOT/tracked-icon-after.diff"
git -C "$ROOT_DIR" diff --binary -- \
  "$TRACKED_ICON_SOURCE" "$TRACKED_ICON_PRODUCT" > "$TRACKED_ICON_DIFF_AFTER"
cmp -s "$TRACKED_ICON_DIFF_BEFORE" "$TRACKED_ICON_DIFF_AFTER" ||
  fail "build changed the tracked icon git diff"

copy_fixture
FIXTURE_PROJECT="$FIXTURE_ROOT/project"
FIXTURE_APP="$FIXTURE_PROJECT/dist/Gatebeam.app"
FIXTURE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FIXTURE_PROJECT/Resources/Info.plist")"
mkdir -p "$FIXTURE_ROOT/home" "$FIXTURE_ROOT/tmp" "$FIXTURE_ROOT/hostile-zdotdir"
cat > "$FIXTURE_ROOT/hostile-zdotdir/.zshenv" <<'EOF'
print -r -- "loaded" >> "$GATEBEAM_ZSHENV_SENTINEL"
EOF

# A directory-shaped but incomplete app must trigger a clean rebuild.
mkdir -p "$FIXTURE_APP/Contents"
print -r -- "incomplete" > "$FIXTURE_APP/Contents/Info.plist"
/bin/zsh -f "$FIXTURE_PROJECT/scripts/package_dmg.sh" --validate-only
assert_valid_app "$FIXTURE_APP"

# Tampering must invalidate the signature, and PKG packaging must rebuild first.
print -n -- "tampered" >> "$FIXTURE_APP/Contents/MacOS/Gatebeam"
if /usr/bin/codesign --verify --deep --strict "$FIXTURE_APP" >/dev/null 2>&1; then
  fail "tampered app unexpectedly retained a valid signature"
fi
/bin/zsh -f "$FIXTURE_PROJECT/scripts/package_pkg.sh"
assert_valid_app "$FIXTURE_APP"
FIXTURE_PKG="$FIXTURE_PROJECT/dist/Gatebeam-$FIXTURE_VERSION.pkg"
[[ -s "$FIXTURE_PKG" ]] || fail "PKG was not created after signature recovery"
assert_raw_package_clean "$FIXTURE_PKG"
EXPANDED_FIXTURE_PKG="$FIXTURE_ROOT/expanded-package"
pkgutil --expand-full "$FIXTURE_PKG" "$EXPANDED_FIXTURE_PKG"
if find "$EXPANDED_FIXTURE_PKG/Payload" \( -name '._*' -o -name '.DS_Store' \) -print -quit | grep -q .; then
  fail "expanded PKG payload contains AppleDouble or Finder metadata"
fi
assert_valid_app "$EXPANDED_FIXTURE_PKG/Payload/Gatebeam.app"

# A failed or interrupted replacement must preserve the previous valid package.
ORIGINAL_PKG_CHECKSUM="$(shasum -a 256 "$FIXTURE_PKG" | awk '{ print $1 }')"
set +e
GATEBEAM_TEST_PKG_FAILURE_POINT=before-publish \
  /bin/zsh -f "$FIXTURE_PROJECT/scripts/package_pkg.sh" >/dev/null 2>&1
failure_status="$?"
set -e
[[ "$failure_status" != "0" ]] || fail "injected package failure unexpectedly succeeded"
[[ "$(shasum -a 256 "$FIXTURE_PKG" | awk '{ print $1 }')" == "$ORIGINAL_PKG_CHECKSUM" ]] ||
  fail "failed package replacement changed the previous PKG"

set +e
GATEBEAM_TEST_PKG_SIGNAL_POINT=before-publish \
  /bin/zsh -f "$FIXTURE_PROJECT/scripts/package_pkg.sh" >/dev/null 2>&1
signal_status="$?"
set -e
[[ "$signal_status" == "143" ]] || fail "expected package TERM status 143, got $signal_status"
[[ "$(shasum -a 256 "$FIXTURE_PKG" | awk '{ print $1 }')" == "$ORIGINAL_PKG_CHECKSUM" ]] ||
  fail "interrupted package replacement changed the previous PKG"

if find "$FIXTURE_PROJECT/dist" -maxdepth 1 -name '.Gatebeam-*.pkg.*' -print -quit | grep -q .; then
  fail "package failure handling left a temporary PKG"
fi

# Force each package entry point through its rebuild path under a hostile ZDOTDIR.
rm -f "$FIXTURE_APP/Contents/MacOS/Gatebeam"
run_with_hostile_zshenv "$FIXTURE_PROJECT/scripts/package_dmg.sh" --validate-only
assert_valid_app "$FIXTURE_APP"

print -n -- "tampered-again" >> "$FIXTURE_APP/Contents/MacOS/Gatebeam"
run_with_hostile_zshenv "$FIXTURE_PROJECT/scripts/package_pkg.sh"
assert_valid_app "$FIXTURE_APP"
[[ ! -e "$FIXTURE_ROOT/zshenv-was-loaded" ]] ||
  fail "a packaging or build script loaded hostile .zshenv"

echo "Build asset validation passed"
