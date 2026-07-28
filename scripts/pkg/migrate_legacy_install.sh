#!/bin/zsh -f
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CDPATH ENV BASH_ENV
IFS=$' \t\n'

readonly BUNDLE_ID="com.local.RemoteControlNetwork"
readonly LEGACY_EXECUTABLE="RemoteControlNetwork"
readonly SYSTEM_APPLICATIONS_DIR="/Applications"
readonly LEGACY_APP_NAME="Remote Control Network.app"

log() {
  /bin/echo "Gatebeam upgrade: $*"
}

fail() {
  /bin/echo "Gatebeam upgrade: $*" >&2
  return 1
}

directory_mode_is_safe() {
  local directory="$1"
  local mode
  mode="$(/usr/bin/stat -f '%Lp' "$directory")" || return 1
  (( (8#$mode & 8#002) == 0 ))
}

validate_applications_directory() {
  local directory="$1"
  local expected_owner_uid="$2"
  local expected_group_gid="$3"
  local canonical
  local owner_uid
  local group_gid

  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  canonical="${directory:A}"
  [[ "$canonical" == "$directory" ]] || return 1
  owner_uid="$(/usr/bin/stat -f '%u' "$directory")" || return 1
  group_gid="$(/usr/bin/stat -f '%g' "$directory")" || return 1
  [[ "$owner_uid" == "$expected_owner_uid" ]] || return 1
  [[ "$group_gid" == "$expected_group_gid" ]] || return 1
  directory_mode_is_safe "$directory"
}

bundle_value() {
  local key="$1"
  local plist_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null
}

is_verified_legacy_app() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  local executable_dir="$app_path/Contents/MacOS"
  local executable_path="$executable_dir/$LEGACY_EXECUTABLE"
  local signed_identifier

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 1
  [[ -d "$app_path/Contents" && ! -L "$app_path/Contents" ]] || return 1
  [[ -f "$plist_path" && ! -L "$plist_path" ]] || return 1
  [[ -d "$executable_dir" && ! -L "$executable_dir" ]] || return 1
  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] || return 1
  [[ "$(bundle_value CFBundleIdentifier "$plist_path" || true)" == "$BUNDLE_ID" ]] || return 1
  [[ "$(bundle_value CFBundleExecutable "$plist_path" || true)" == "$LEGACY_EXECUTABLE" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || return 1
  signed_identifier="$(
    /usr/bin/codesign -d --verbose=4 "$app_path" 2>&1 |
      /usr/bin/awk -F= '/^Identifier=/ { print $2; exit }'
  )"
  [[ "$signed_identifier" == "$BUNDLE_ID" ]]
}

applications_dir="$SYSTEM_APPLICATIONS_DIR"
expected_owner_uid=0
expected_group_gid=80
test_mode=false

if (( EUID == 0 )); then
  (( $# == 0 )) || {
    fail "root migration does not accept arguments"
    exit 64
  }
  /usr/sbin/pkgutil --pkg-info "$BUNDLE_ID" >/dev/null 2>&1 || {
    log "package receipt is unavailable; preserved legacy application"
    exit 0
  }
else
  if [[ $# == 2 && "$1" == "--test-applications-dir" ]]; then
    test_mode=true
    applications_dir="$2"
    [[ "$applications_dir" == /* ]] || {
      fail "fixture Applications directory must be absolute"
      exit 64
    }
    expected_owner_uid="$EUID"
    expected_group_gid="$(/usr/bin/stat -f '%g' "$applications_dir" 2>/dev/null || true)"
  else
    fail "this migration is only run by Installer"
    exit 77
  fi
fi

if ! validate_applications_directory "$applications_dir" "$expected_owner_uid" "$expected_group_gid"; then
  log "unsafe Applications directory; preserved legacy application"
  exit 0
fi

legacy_app="$applications_dir/$LEGACY_APP_NAME"
if [[ ! -e "$legacy_app" && ! -L "$legacy_app" ]]; then
  exit 0
fi

if [[ -L "$legacy_app" ]]; then
  log "preserved symbolic-link legacy application"
  exit 0
fi

if ! is_verified_legacy_app "$legacy_app"; then
  log "preserved unverified legacy application"
  exit 0
fi

/bin/rm -rf -- "$legacy_app"
log "removed verified legacy application from $applications_dir"

if [[ "$test_mode" == true ]]; then
  log "completed non-root fixture migration"
fi
