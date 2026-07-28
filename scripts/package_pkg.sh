#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Gatebeam"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
PKG_PATH="$ROOT_DIR/dist/Gatebeam-$VERSION.pkg"
PKG_DIR="${PKG_PATH:h}"
PACKAGE_SCRIPTS_DIR="$ROOT_DIR/scripts/pkg"
BUNDLE_ID="com.local.RemoteControlNetwork"
STAGING_PARENT="${GATEBEAM_PACKAGE_TMPDIR:-/private/tmp}"
EXPECTED_EXECUTABLE="Gatebeam"
TEMP_PKG_PATH=""
staging_dir=""

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  [[ -z "$TEMP_PKG_PATH" ]] || rm -f -- "$TEMP_PKG_PATH"
  [[ -z "$staging_dir" ]] || rm -rf -- "$staging_dir"
}

handle_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
}

test_injection_allowed() {
  [[ "$ROOT_DIR" == /private/tmp/* ]]
}

inject_test_event() {
  local point="$1"
  local failure_point="${GATEBEAM_TEST_PKG_FAILURE_POINT:-}"
  local signal_point="${GATEBEAM_TEST_PKG_SIGNAL_POINT:-}"

  if [[ "$failure_point" == "$point" ]]; then
    test_injection_allowed || fail "package failure injection is restricted to a temporary fixture"
    fail "injected package failure at $point"
  fi
  if [[ "$signal_point" == "$point" ]]; then
    test_injection_allowed || fail "package signal injection is restricted to a temporary fixture"
    kill -TERM "$$"
  fi
}

app_is_valid() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  local executable_name
  local actual_bundle_id
  local actual_version

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 1
  [[ -f "$plist_path" && ! -L "$plist_path" ]] || return 1

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null)" || return 1
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null)" || return 1
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist_path" 2>/dev/null)" || return 1

  [[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || return 1
  [[ "$actual_version" == "$VERSION" ]] || return 1
  [[ "$executable_name" == "$EXPECTED_EXECUTABLE" ]] || return 1
  [[ -f "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  [[ ! -L "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  [[ -x "$app_path/Contents/MacOS/$executable_name" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1
}

archive_tree_without_metadata() {
  local source_root="$1"
  local output_path="$2"
  local archive_log="$staging_dir/cpio.log"

  if ! (
    cd "$source_root"
    find . -print |
      LC_ALL=C sort |
      env COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
        cpio -o -H odc -R root:wheel -z -O "$output_path"
  ) 2>"$archive_log"; then
    cat "$archive_log" >&2
    return 1
  fi
}

raw_archive_paths() {
  local archive_path="$1"
  gzip -dc "$archive_path" | cpio -it 2>/dev/null
}

validate_raw_package() {
  local package_path="$1"
  local raw_dir="$staging_dir/raw-validation"
  local bom_paths="$staging_dir/bom-paths"
  local payload_paths="$staging_dir/payload-paths"
  local payload_verbose="$staging_dir/payload-verbose"
  local scripts_paths="$staging_dir/scripts-paths"

  rm -rf "$raw_dir"
  mkdir -p "$raw_dir"
  xar -xf "$package_path" -C "$raw_dir" || return 1

  [[ "$(file -b "$raw_dir/Payload")" == gzip\ compressed\ data* ]] || return 1
  [[ "$(file -b "$raw_dir/Scripts")" == gzip\ compressed\ data* ]] || return 1

  lsbom -s "$raw_dir/Bom" | LC_ALL=C sort > "$bom_paths" || return 1
  raw_archive_paths "$raw_dir/Payload" | LC_ALL=C sort > "$payload_paths" || return 1
  raw_archive_paths "$raw_dir/Scripts" | LC_ALL=C sort > "$scripts_paths" || return 1

  if grep -E '(^|/)\._|(^|/)\.DS_Store$' "$bom_paths" "$payload_paths" "$scripts_paths" >/dev/null; then
    return 1
  fi
  cmp -s "$bom_paths" "$payload_paths" || return 1

  if lsbom "$raw_dir/Bom" | awk '$3 != "0/0" { exit 1 }'; then
    :
  else
    return 1
  fi

  gzip -dc "$raw_dir/Payload" | cpio -itv > "$payload_verbose" 2>/dev/null || return 1
  if awk 'NF >= 4 && ($3 != "root" || $4 != "wheel") { exit 1 }' "$payload_verbose"; then
    :
  else
    return 1
  fi
}

validate_expanded_package() {
  local expanded_dir="$1"
  local package_info="$expanded_dir/PackageInfo"
  local payload_dir="$expanded_dir/Payload"
  local payload_app="$payload_dir/$APP_NAME.app"
  local identifier
  local package_version
  local install_location
  local auth
  local payload_entry_count

  [[ -f "$package_info" && ! -L "$package_info" ]] || return 1
  [[ -d "$payload_dir" && ! -L "$payload_dir" ]] || return 1

  identifier="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$package_info" 2>/dev/null)" || return 1
  package_version="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@version)' "$package_info" 2>/dev/null)" || return 1
  install_location="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$package_info" 2>/dev/null)" || return 1
  auth="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@auth)' "$package_info" 2>/dev/null)" || return 1

  [[ "$identifier" == "$BUNDLE_ID" ]] || return 1
  [[ "$package_version" == "$VERSION" ]] || return 1
  [[ "$install_location" == "/Applications" ]] || return 1
  [[ "$auth" == "root" ]] || return 1

  payload_entry_count="$(find "$payload_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
  [[ "$payload_entry_count" == "1" ]] || return 1
  if find "$payload_dir" \( -name '._*' -o -name '.DS_Store' \) -print -quit | grep -q .; then
    return 1
  fi
  app_is_valid "$payload_app" || return 1

  [[ -f "$expanded_dir/Scripts/postinstall" ]] || return 1
  [[ -f "$expanded_dir/Scripts/migrate_legacy_install.sh" ]] || return 1
  cmp -s "$PACKAGE_SCRIPTS_DIR/postinstall" "$expanded_dir/Scripts/postinstall" || return 1
  cmp -s "$PACKAGE_SCRIPTS_DIR/migrate_legacy_install.sh" "$expanded_dir/Scripts/migrate_legacy_install.sh"
}

if ! app_is_valid "$APP_DIR"; then
  if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    echo "Existing $APP_DIR is incomplete, invalid, or has a broken signature; rebuilding it"
  fi
  /bin/zsh -f "$ROOT_DIR/scripts/build_app.sh"
fi

if ! app_is_valid "$APP_DIR"; then
  echo "Built application failed package validation: $APP_DIR" >&2
  exit 1
fi

mkdir -p "$STAGING_PARENT" "$PKG_DIR"
staging_dir="$(mktemp -d "$STAGING_PARENT/gatebeam-pkg-staging.XXXXXX")"
payload_root="$staging_dir/PayloadRoot"
staged_app="$payload_root/$APP_NAME.app"
staged_scripts="$staging_dir/Scripts"
expanded_package="$staging_dir/expanded"
signature_log="$staging_dir/package-signature.log"
package_components="$staging_dir/package-components"
repacked_package="$staging_dir/repacked.pkg"
clean_bom_list="$staging_dir/clean-bom-list"
TEMP_PKG_PATH="$(mktemp "$PKG_DIR/.Gatebeam-$VERSION.pkg.XXXXXX")"
trap 'cleanup' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

mkdir -p "$payload_root"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_DIR" "$staged_app"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$PACKAGE_SCRIPTS_DIR" "$staged_scripts"
xattr -cr "$staged_app"
xattr -cr "$staged_scripts"
find "$staged_app" "$staged_scripts" \( -name '._*' -o -name '.DS_Store' \) -delete
if ! app_is_valid "$staged_app"; then
  echo "Staged application failed package signature validation: $staged_app" >&2
  exit 1
fi

COPYFILE_DISABLE=1 pkgbuild \
  --component "$staged_app" \
  --install-location /Applications \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --scripts "$staged_scripts" \
  "$TEMP_PKG_PATH" >/dev/null

[[ -s "$TEMP_PKG_PATH" ]] || fail "pkgbuild produced an empty package"
inject_test_event after-build

mkdir -p "$package_components"
xar -xf "$TEMP_PKG_PATH" -C "$package_components" ||
  fail "could not extract pkgbuild output for metadata-free repacking"

mkbom "$payload_root" "$package_components/Bom" ||
  fail "could not inventory the metadata-free payload"
lsbom "$package_components/Bom" |
  awk 'BEGIN { OFS = "\t" } { $3 = "0/0"; print }' > "$clean_bom_list"
mkbom -i "$clean_bom_list" "$package_components/Bom" ||
  fail "could not create a metadata-free package BOM"

archive_tree_without_metadata "$payload_root" "$package_components/Payload" ||
  fail "could not create a metadata-free payload archive"
archive_tree_without_metadata "$staged_scripts" "$package_components/Scripts" ||
  fail "could not create a metadata-free scripts archive"

(
  cd "$package_components"
  env COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
    xar -cf "$repacked_package" \
      --distribution \
      --no-compress Payload \
      --no-compress Scripts \
      Bom Payload Scripts PackageInfo
) || fail "could not repack the metadata-free package"

mv -f -- "$repacked_package" "$TEMP_PKG_PATH"
validate_raw_package "$TEMP_PKG_PATH" ||
  fail "raw package BOM, cpio payload, ownership, or metadata validation failed"

if pkgutil --check-signature "$TEMP_PKG_PATH" >"$signature_log" 2>&1; then
  :
elif ! grep -Fq "Status: no signature" "$signature_log"; then
  cat "$signature_log" >&2
  fail "package signature inspection failed"
fi

pkgutil --expand-full "$TEMP_PKG_PATH" "$expanded_package" ||
  fail "could not expand the newly built package"
validate_expanded_package "$expanded_package" ||
  fail "expanded package failed metadata, payload, script, or app signature validation"

inject_test_event before-publish
mv -f -- "$TEMP_PKG_PATH" "$PKG_PATH"
TEMP_PKG_PATH=""

echo "Packaged PKG: $PKG_PATH"
