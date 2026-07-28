#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/upgrade-tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
TEST_BINARY="$BUILD_DIR/launch-agent-tests"
MIGRATOR="$ROOT_DIR/scripts/pkg/migrate_legacy_install.sh"
POSTINSTALL="$ROOT_DIR/scripts/pkg/postinstall"
INSTALLER="$ROOT_DIR/scripts/install_app.sh"

if (( $+commands[rg] )); then
  TEXT_SEARCH_TOOL="$commands[rg]"
  TEXT_SEARCH_KIND="rg"
elif [[ -x /usr/bin/grep ]]; then
  TEXT_SEARCH_TOOL="/usr/bin/grep"
  TEXT_SEARCH_KIND="grep"
else
  print -u2 -- "FAIL: neither rg nor /usr/bin/grep is available"
  exit 1
fi

text_search_quiet() {
  local mode="$1"
  local pattern="$2"
  shift 2

  local search_status
  if [[ "$TEXT_SEARCH_KIND" == "rg" ]]; then
    case "$mode" in
      regex)
        if "$TEXT_SEARCH_TOOL" --quiet -- "$pattern" "$@"; then
          search_status=0
        else
          search_status="$?"
        fi
        ;;
      fixed)
        if "$TEXT_SEARCH_TOOL" --fixed-strings --quiet -- "$pattern" "$@"; then
          search_status=0
        else
          search_status="$?"
        fi
        ;;
      *)
        print -u2 -- "FAIL: unsupported text search mode: $mode"
        exit 1
        ;;
    esac
  else
    case "$mode" in
      regex)
        if "$TEXT_SEARCH_TOOL" -Eq -- "$pattern" "$@"; then
          search_status=0
        else
          search_status="$?"
        fi
        ;;
      fixed)
        if "$TEXT_SEARCH_TOOL" -Fq -- "$pattern" "$@"; then
          search_status=0
        else
          search_status="$?"
        fi
        ;;
      *)
        print -u2 -- "FAIL: unsupported text search mode: $mode"
        exit 1
        ;;
    esac
  fi

  if (( search_status > 1 )); then
    print -u2 -- "FAIL: $TEXT_SEARCH_KIND could not search: $*"
    exit "$search_status"
  fi
  return "$search_status"
}

assert_text_present() {
  local mode="$1"
  local pattern="$2"
  shift 2

  if ! text_search_quiet "$mode" "$pattern" "$@"; then
    print -u2 -- "FAIL: expected text was not found in: $*"
    exit 1
  fi
}

assert_text_absent() {
  local mode="$1"
  local pattern="$2"
  shift 2

  if text_search_quiet "$mode" "$pattern" "$@"; then
    print -u2 -- "FAIL: forbidden text was found in: $*"
    exit 1
  fi
}

assert_adjacent_lines() {
  local first_pattern="$1"
  local second_pattern="$2"
  local file_path="$3"
  local context
  local search_status

  if [[ "$TEXT_SEARCH_KIND" == "rg" ]]; then
    if "$TEXT_SEARCH_TOOL" --multiline --quiet -- \
      "${first_pattern}"$'\n'"${second_pattern}" \
      "$file_path"; then
      search_status=0
    else
      search_status="$?"
    fi
  else
    if context="$("$TEXT_SEARCH_TOOL" -A 1 -E -- "$first_pattern" "$file_path")"; then
      search_status=0
    else
      search_status="$?"
    fi
    if (( search_status == 0 )); then
      if print -r -- "$context" | "$TEXT_SEARCH_TOOL" -Eq -- "$second_pattern"; then
        search_status=0
      else
        search_status="$?"
      fi
    fi
  fi

  if (( search_status > 1 )); then
    print -u2 -- "FAIL: $TEXT_SEARCH_KIND could not search adjacent lines in: $file_path"
    exit "$search_status"
  fi
  if (( search_status == 1 )); then
    print -u2 -- "FAIL: expected adjacent lines were not found in: $file_path"
    exit 1
  fi
}

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/LaunchAgentManager.swift" \
  "$ROOT_DIR/Tests/UpgradeTests/main.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"

fixture_root="$(mktemp -d "/private/tmp/gatebeam-upgrade.XXXXXX")"
trap 'chmod -R u+rwx -- "$fixture_root" 2>/dev/null || true; rm -rf -- "$fixture_root"' EXIT

sign_app() {
  local app_path="$1"
  local identifier="$2"
  codesign \
    --force \
    --deep \
    --sign - \
    --requirements "=designated => identifier \"$identifier\"" \
    "$app_path" >/dev/null
}

make_app() {
  local app_path="$1"
  local identifier="$2"
  local executable="$3"
  local sign_app="${4:-false}"
  mkdir -p "$app_path/Contents/MacOS"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$app_path/Contents/Info.plist"
  cp /usr/bin/true "$app_path/Contents/MacOS/$executable"
  chmod 0755 "$app_path/Contents/MacOS/$executable"
  if [[ "$sign_app" == true ]]; then
    sign_app "$app_path" "$identifier"
  fi
}

make_agent() {
  local plist_path="$1"
  local label="$2"
  local app_path="$3"
  mkdir -p "${plist_path:h}"
  /usr/libexec/PlistBuddy -c "Add :Label string $label" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/open" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $app_path" "$plist_path"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$plist_path"
  chmod 0644 "$plist_path"
}

assert_exists() {
  [[ -e "$1" || -L "$1" ]] || {
    print -u2 -- "FAIL: expected path to exist: $1"
    exit 1
  }
}

assert_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || {
    print -u2 -- "FAIL: expected path to be absent: $1"
    exit 1
  }
}

assert_same_file() {
  local expected="$1"
  local actual="$2"
  cmp -s "$expected" "$actual" || {
    print -u2 -- "FAIL: files differ: $expected $actual"
    exit 1
  }
}

assert_file_content() {
  local expected="$1"
  local file_path="$2"
  local actual
  actual="$(<"$file_path")"
  [[ "$actual" == "$expected" ]] || {
    print -u2 -- "FAIL: expected '$expected' in $file_path, got '$actual'"
    exit 1
  }
}

assert_mode() {
  local expected="$1"
  local file_path="$2"
  local actual
  actual="$(stat -f '%Lp' "$file_path")"
  [[ "$actual" == "$expected" ]] || {
    print -u2 -- "FAIL: expected mode $expected for $file_path, got $actual"
    exit 1
  }
}

assert_owner_group() {
  local expected="$1"
  local file_path="$2"
  local actual
  actual="$(stat -f '%u:%g' "$file_path")"
  [[ "$actual" == "$expected" ]] || {
    print -u2 -- "FAIL: expected owner/group $expected for $file_path, got $actual"
    exit 1
  }
}

snapshot_tree() {
  local tree_root="$1"
  local manifest_path="$2"

  (
    cd "$tree_root"
    find . -print | LC_ALL=C sort | while IFS= read -r relative_path; do
      local kind
      local payload="-"
      local metadata

      if [[ -L "$relative_path" ]]; then
        kind="symlink"
        payload="$(readlink "$relative_path")"
      elif [[ -d "$relative_path" ]]; then
        kind="directory"
      elif [[ -f "$relative_path" ]]; then
        kind="file"
        payload="$(shasum -a 256 "$relative_path" | awk '{ print $1 }')"
      else
        kind="other"
      fi

      metadata="$(stat -f '%u:%g:%Lp' "$relative_path")"
      print -r -- "$relative_path	$kind	$metadata	$payload"
    done
  ) > "$manifest_path"
}

assert_tree_snapshot() {
  local expected_manifest="$1"
  local tree_root="$2"
  local actual_manifest
  actual_manifest="$(mktemp "$fixture_root/tree-manifest.XXXXXX")"
  snapshot_tree "$tree_root" "$actual_manifest"
  assert_same_file "$expected_manifest" "$actual_manifest"
  rm -f -- "$actual_manifest"
}

assert_no_transaction() {
  local home="$1"
  local transaction
  transaction="$(find "$home" -maxdepth 1 -name '.gatebeam-install.*' -print -quit)"
  if [[ -n "$transaction" ]]; then
    print -u2 -- "FAIL: install left a transaction directory in $home"
    exit 1
  fi
}

assert_rejected_destination_unchanged() {
  local case_name="$1"
  local source="$2"
  local destination="$3"
  local home="$4"
  local before_manifest="$5"

  if GATEBEAM_APP_DIR="$source" \
    GATEBEAM_INSTALL_DIR="${destination:h}" \
    GATEBEAM_USER_HOME="$home" \
      "$INSTALLER" >/dev/null 2>&1; then
    print -u2 -- "FAIL: installer accepted unsafe legacy Gatebeam destination: $case_name"
    exit 1
  fi
  assert_tree_snapshot "$before_manifest" "$home"
  assert_no_transaction "$home"
}

assert_rollback_state() {
  local rollback_root="$1"
  local destination="$2"
  local legacy="$3"
  local stable="$4"
  local transitional="$5"
  local home="$6"

  assert_file_content "old-destination" "$destination/Contents/Resources/old-marker"
  assert_file_content "old-legacy" "$legacy/Contents/Resources/old-marker"
  assert_tree_snapshot "$rollback_root/destination-before.manifest" "$destination"
  assert_tree_snapshot "$rollback_root/legacy-before.manifest" "$legacy"
  assert_same_file "$rollback_root/stable-before.plist" "$stable"
  assert_same_file "$rollback_root/transitional-before.plist" "$transitional"
  assert_mode 711 "$destination"
  assert_mode 750 "$legacy"
  assert_mode 600 "$stable"
  assert_mode 640 "$transitional"
  assert_owner_group "$(<"$rollback_root/stable-before.owner-group")" "$stable"
  assert_owner_group "$(<"$rollback_root/transitional-before.owner-group")" "$transitional"
  assert_no_transaction "$home"
}

stable_label="com.local.RemoteControlNetwork.login"
transitional_label="io.github.naifuliang.gatebeam.login"
current_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/Resources/Info.plist")"

root_fixture="$fixture_root/root"
applications="$root_fixture/Applications"
mkdir -p "$applications"
chmod 0755 "$applications"

startup_fixture="$root_fixture/startup-files"
startup_applications="$startup_fixture/Applications"
startup_marker="$startup_fixture/zshenv-ran"
mkdir -p "$startup_applications" "$startup_fixture/zdotdir"
chmod 0755 "$startup_applications"
print -r -- "/usr/bin/touch ${(q)startup_marker}" > "$startup_fixture/zdotdir/.zshenv"

for root_script in "$POSTINSTALL" "$MIGRATOR" "$INSTALLER"; do
  [[ "$(<"$root_script")" != "" ]]
  [[ "$(head -n 1 "$root_script")" == "#!/bin/zsh -f" ]] || {
    print -u2 -- "FAIL: install script does not disable zsh startup files: $root_script"
    exit 1
  }
done

ZDOTDIR="$startup_fixture/zdotdir" \
  "$MIGRATOR" --test-applications-dir "$startup_applications"
assert_missing "$startup_marker"

ZDOTDIR="$startup_fixture/zdotdir" \
  "$POSTINSTALL" >/dev/null 2>&1 || true
assert_missing "$startup_marker"

startup_home="$startup_fixture/home"
startup_installer_apps="$startup_home/Applications"
startup_source="$startup_fixture/source/Gatebeam.app"
mkdir -p "$startup_home"
make_app "$startup_source" "$current_bundle_id" "Gatebeam" true
ZDOTDIR="$startup_fixture/zdotdir" \
GATEBEAM_APP_DIR="$startup_source" \
GATEBEAM_INSTALL_DIR="$startup_installer_apps" \
GATEBEAM_USER_HOME="$startup_home" \
GATEBEAM_TEST_FAILURE_POINT=before-backup \
  "$INSTALLER" >/dev/null 2>&1 || true
assert_missing "$startup_marker"
assert_no_transaction "$startup_home"

valid_legacy="$applications/Remote Control Network.app"
make_app "$valid_legacy" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
"$MIGRATOR" --test-applications-dir "$applications"
assert_missing "$valid_legacy"

forged_legacy="$applications/Remote Control Network.app"
make_app "$forged_legacy" "com.example.Forged" "RemoteControlNetwork" true
"$MIGRATOR" --test-applications-dir "$applications"
assert_exists "$forged_legacy"
rm -rf "$forged_legacy"

wrong_executable="$applications/Remote Control Network.app"
make_app "$wrong_executable" "com.local.RemoteControlNetwork" "Gatebeam" true
"$MIGRATOR" --test-applications-dir "$applications"
assert_exists "$wrong_executable"
rm -rf "$wrong_executable"

outside_app="$root_fixture/outside/Remote Control Network.app"
make_app "$outside_app" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
ln -s "$outside_app" "$applications/Remote Control Network.app"
"$MIGRATOR" --test-applications-dir "$applications"
assert_exists "$outside_app"
[[ -L "$applications/Remote Control Network.app" ]] || {
  print -u2 -- "FAIL: root migration replaced a final symlink"
  exit 1
}
rm "$applications/Remote Control Network.app"

symlink_target="$root_fixture/symlink-target"
mkdir -p "$symlink_target"
make_app "$symlink_target/Remote Control Network.app" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
ln -s "$symlink_target" "$root_fixture/Applications-link"
"$MIGRATOR" --test-applications-dir "$root_fixture/Applications-link"
assert_exists "$symlink_target/Remote Control Network.app"

unsafe_mode_dir="$root_fixture/unsafe-mode"
mkdir -p "$unsafe_mode_dir"
chmod 0777 "$unsafe_mode_dir"
make_app "$unsafe_mode_dir/Remote Control Network.app" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
"$MIGRATOR" --test-applications-dir "$unsafe_mode_dir"
assert_exists "$unsafe_mode_dir/Remote Control Network.app"
chmod 0755 "$unsafe_mode_dir"

injected_target="$root_fixture/injected/Applications"
mkdir -p "$injected_target"
make_app "$injected_target/Remote Control Network.app" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
malicious_buddy="$root_fixture/malicious-plist-buddy"
malicious_marker="$root_fixture/malicious-command-ran"
print '#!/bin/zsh' > "$malicious_buddy"
print "touch ${(q)malicious_marker}" >> "$malicious_buddy"
chmod 0755 "$malicious_buddy"
GATEBEAM_APPLICATIONS_DIR="$injected_target" \
GATEBEAM_USER_HOME="$root_fixture/fake-home" \
GATEBEAM_USER_NAME="missing-console-user" \
GATEBEAM_PLIST_BUDDY="$malicious_buddy" \
  "$MIGRATOR" --test-applications-dir "$applications"
assert_exists "$injected_target/Remote Control Network.app"
assert_missing "$malicious_marker"

assert_text_absent \
  regex \
  '(/dev/console|LaunchAgents|NFSHomeDirectory|GATEBEAM_USER_HOME|GATEBEAM_USER_NAME|GATEBEAM_PLIST_BUDDY)' \
  "$MIGRATOR"

developer_root="$fixture_root/developer-success"
developer_home="$developer_root/home"
developer_apps="$developer_home/Applications"
developer_agents="$developer_home/Library/LaunchAgents"
source_app="$developer_root/source/Gatebeam.app"
destination_app="$developer_apps/Gatebeam.app"
developer_legacy="$developer_apps/Remote Control Network.app"
stable_plist="$developer_agents/$stable_label.plist"
transitional_plist="$developer_agents/$transitional_label.plist"
mkdir -p "$developer_apps" "$developer_agents"
make_app "$source_app" "$current_bundle_id" "Gatebeam" true
make_app "$developer_legacy" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
make_agent "$transitional_plist" "$transitional_label" "$developer_legacy"

GATEBEAM_APP_DIR="$source_app" \
GATEBEAM_INSTALL_DIR="$developer_apps" \
GATEBEAM_USER_HOME="$developer_home" \
  "$INSTALLER"

assert_exists "$destination_app"
assert_missing "$developer_legacy"
assert_missing "$transitional_plist"
assert_exists "$stable_plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$stable_plist")" == "$destination_app" ]]
[[ "$(stat -f '%Lp' "$stable_plist")" == "644" ]]
[[ "$(stat -f '%u' "$stable_plist")" == "$(id -u)" ]]
[[ "$(stat -f '%g' "$stable_plist")" == "$(id -g)" ]]

signature_root="$fixture_root/developer-signature-rejection"
signature_home="$signature_root/home"
signature_apps="$signature_home/Applications"
signature_agents="$signature_home/Library/LaunchAgents"
signature_source="$signature_root/source/Gatebeam.app"
signature_destination="$signature_apps/Gatebeam.app"
signature_stable="$signature_agents/$stable_label.plist"
signature_before="$signature_root/before.manifest"
mkdir -p "$signature_apps" "$signature_agents"
make_app "$signature_source" "$current_bundle_id" "Gatebeam" true
make_app "$signature_destination" "$current_bundle_id" "Gatebeam"
print -r -- "previous-install" > "$signature_destination/old-marker"
make_agent "$signature_stable" "$stable_label" "$signature_destination"
snapshot_tree "$signature_home" "$signature_before"
print -n -- "tampered" >> "$signature_source/Contents/MacOS/Gatebeam"
if /usr/bin/codesign --verify --deep --strict "$signature_source" >/dev/null 2>&1; then
  print -u2 -- "FAIL: tampered installer source retained a valid signature"
  exit 1
fi
if GATEBEAM_APP_DIR="$signature_source" \
  GATEBEAM_INSTALL_DIR="$signature_apps" \
  GATEBEAM_USER_HOME="$signature_home" \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: installer accepted a source with a damaged signature"
  exit 1
fi
assert_tree_snapshot "$signature_before" "$signature_home"
assert_file_content "previous-install" "$signature_destination/old-marker"
assert_exists "$signature_stable"
assert_no_transaction "$signature_home"

legacy_gatebeam_root="$fixture_root/developer-legacy-gatebeam"
legacy_gatebeam_home="$legacy_gatebeam_root/home"
legacy_gatebeam_apps="$legacy_gatebeam_home/Applications"
legacy_gatebeam_source="$legacy_gatebeam_root/source/Gatebeam.app"
legacy_gatebeam_destination="$legacy_gatebeam_apps/Gatebeam.app"
mkdir -p "$legacy_gatebeam_apps"
make_app "$legacy_gatebeam_source" "$current_bundle_id" "Gatebeam" true
make_app "$legacy_gatebeam_destination" "com.local.RemoteControlNetwork" "Gatebeam" true
mkdir -p "$legacy_gatebeam_destination/Contents/Resources"
print -r -- "legacy-gatebeam-install" > "$legacy_gatebeam_destination/Contents/Resources/old-marker"
sign_app "$legacy_gatebeam_destination" "com.local.RemoteControlNetwork"

GATEBEAM_APP_DIR="$legacy_gatebeam_source" \
GATEBEAM_INSTALL_DIR="$legacy_gatebeam_apps" \
GATEBEAM_USER_HOME="$legacy_gatebeam_home" \
  "$INSTALLER" >/dev/null

assert_exists "$legacy_gatebeam_destination"
assert_missing "$legacy_gatebeam_destination/Contents/Resources/old-marker"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_gatebeam_destination/Contents/Info.plist")" == "$current_bundle_id" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$legacy_gatebeam_destination/Contents/Info.plist")" == "Gatebeam" ]]
/usr/bin/codesign --verify --deep --strict "$legacy_gatebeam_destination"
assert_no_transaction "$legacy_gatebeam_home"

legacy_gatebeam_rollback_root="$fixture_root/developer-legacy-gatebeam-rollback"
legacy_gatebeam_rollback_home="$legacy_gatebeam_rollback_root/home"
legacy_gatebeam_rollback_apps="$legacy_gatebeam_rollback_home/Applications"
legacy_gatebeam_rollback_source="$legacy_gatebeam_rollback_root/source/Gatebeam.app"
legacy_gatebeam_rollback_destination="$legacy_gatebeam_rollback_apps/Gatebeam.app"
legacy_gatebeam_rollback_before="$legacy_gatebeam_rollback_root/before.manifest"
mkdir -p "$legacy_gatebeam_rollback_apps"
make_app "$legacy_gatebeam_rollback_source" "$current_bundle_id" "Gatebeam" true
make_app "$legacy_gatebeam_rollback_destination" "com.local.RemoteControlNetwork" "Gatebeam" true
mkdir -p "$legacy_gatebeam_rollback_destination/Contents/Resources"
print -r -- "restore-legacy-gatebeam" > "$legacy_gatebeam_rollback_destination/Contents/Resources/old-marker"
sign_app "$legacy_gatebeam_rollback_destination" "com.local.RemoteControlNetwork"
snapshot_tree "$legacy_gatebeam_rollback_home" "$legacy_gatebeam_rollback_before"

if GATEBEAM_APP_DIR="$legacy_gatebeam_rollback_source" \
  GATEBEAM_INSTALL_DIR="$legacy_gatebeam_rollback_apps" \
  GATEBEAM_USER_HOME="$legacy_gatebeam_rollback_home" \
  GATEBEAM_TEST_FAILURE_POINT=after-app-swap \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: injected legacy Gatebeam upgrade failure unexpectedly succeeded"
  exit 1
fi
assert_tree_snapshot "$legacy_gatebeam_rollback_before" "$legacy_gatebeam_rollback_home"
assert_file_content \
  "restore-legacy-gatebeam" \
  "$legacy_gatebeam_rollback_destination/Contents/Resources/old-marker"
assert_no_transaction "$legacy_gatebeam_rollback_home"

for rejection_case in unsigned-legacy unsigned-current forged-executable wrong-identifier symlink; do
  rejection_root="$fixture_root/developer-legacy-gatebeam-$rejection_case"
  rejection_home="$rejection_root/home"
  rejection_apps="$rejection_home/Applications"
  rejection_source="$rejection_root/source/Gatebeam.app"
  rejection_destination="$rejection_apps/Gatebeam.app"
  rejection_before="$rejection_root/before.manifest"
  mkdir -p "$rejection_apps"
  make_app "$rejection_source" "$current_bundle_id" "Gatebeam" true

  case "$rejection_case" in
    unsigned-legacy)
      make_app "$rejection_destination" "com.local.RemoteControlNetwork" "Gatebeam"
      ;;
    unsigned-current)
      make_app "$rejection_destination" "$current_bundle_id" "Gatebeam"
      ;;
    forged-executable)
      make_app "$rejection_destination" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
      ;;
    wrong-identifier)
      make_app "$rejection_destination" "com.example.Forged" "Gatebeam" true
      ;;
    symlink)
      make_app "$rejection_root/outside/Gatebeam.app" "com.local.RemoteControlNetwork" "Gatebeam" true
      snapshot_tree "$rejection_root/outside" "$rejection_root/outside-before.manifest"
      ln -s "$rejection_root/outside/Gatebeam.app" "$rejection_destination"
      ;;
  esac

  snapshot_tree "$rejection_home" "$rejection_before"
  assert_rejected_destination_unchanged \
    "$rejection_case" \
    "$rejection_source" \
    "$rejection_destination" \
    "$rejection_home" \
    "$rejection_before"
  if [[ "$rejection_case" == symlink ]]; then
    assert_tree_snapshot "$rejection_root/outside-before.manifest" "$rejection_root/outside"
  fi
done

legacy_source_root="$fixture_root/developer-legacy-source-rejection"
legacy_source_home="$legacy_source_root/home"
legacy_source_apps="$legacy_source_home/Applications"
legacy_source_app="$legacy_source_root/source/Gatebeam.app"
legacy_source_destination="$legacy_source_apps/Gatebeam.app"
legacy_source_before="$legacy_source_root/before.manifest"
mkdir -p "$legacy_source_apps"
make_app "$legacy_source_app" "com.local.RemoteControlNetwork" "Gatebeam" true
make_app "$legacy_source_destination" "$current_bundle_id" "Gatebeam" true
mkdir -p "$legacy_source_destination/Contents/Resources"
print -r -- "preserve-current-gatebeam" > "$legacy_source_destination/Contents/Resources/old-marker"
sign_app "$legacy_source_destination" "$current_bundle_id"
snapshot_tree "$legacy_source_home" "$legacy_source_before"

if GATEBEAM_APP_DIR="$legacy_source_app" \
  GATEBEAM_INSTALL_DIR="$legacy_source_apps" \
  GATEBEAM_USER_HOME="$legacy_source_home" \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: installer accepted a legacy Bundle ID as the source package"
  exit 1
fi
assert_tree_snapshot "$legacy_source_before" "$legacy_source_home"
assert_file_content \
  "preserve-current-gatebeam" \
  "$legacy_source_destination/Contents/Resources/old-marker"
assert_no_transaction "$legacy_source_home"

legacy_signature_root="$fixture_root/developer-legacy-signature-rejection"
legacy_signature_home="$legacy_signature_root/home"
legacy_signature_apps="$legacy_signature_home/Applications"
legacy_signature_agents="$legacy_signature_home/Library/LaunchAgents"
legacy_signature_source="$legacy_signature_root/source/Gatebeam.app"
legacy_signature_destination="$legacy_signature_apps/Gatebeam.app"
legacy_signature_app="$legacy_signature_apps/Remote Control Network.app"
legacy_signature_stable="$legacy_signature_agents/$stable_label.plist"
legacy_signature_log="$legacy_signature_root/install.log"
legacy_signature_before="$legacy_signature_root/before.manifest"
mkdir -p "$legacy_signature_apps" "$legacy_signature_agents"
make_app "$legacy_signature_source" "$current_bundle_id" "Gatebeam" true
make_app "$legacy_signature_destination" "$current_bundle_id" "Gatebeam" true
make_app "$legacy_signature_app" "com.local.RemoteControlNetwork" "RemoteControlNetwork"
print -r -- "preserve-unsigned-legacy" > "$legacy_signature_app/legacy-marker"
make_agent "$legacy_signature_stable" "$stable_label" "$legacy_signature_app"
snapshot_tree "$legacy_signature_home" "$legacy_signature_before"
if GATEBEAM_APP_DIR="$legacy_signature_source" \
  GATEBEAM_INSTALL_DIR="$legacy_signature_apps" \
  GATEBEAM_USER_HOME="$legacy_signature_home" \
    "$INSTALLER" >"$legacy_signature_log" 2>&1; then
  print -u2 -- "FAIL: installer deleted an unsigned metadata-matching legacy app"
  exit 1
fi
assert_tree_snapshot "$legacy_signature_before" "$legacy_signature_home"
assert_file_content "preserve-unsigned-legacy" "$legacy_signature_app/legacy-marker"
assert_text_present \
  fixed \
  "Preserving legacy app because its code signature is missing or invalid: $legacy_signature_app" \
  "$legacy_signature_log"
assert_text_present \
  fixed \
  "Remove or repair the legacy app manually, then run the Gatebeam installer again." \
  "$legacy_signature_log"
assert_no_transaction "$legacy_signature_home"

rm -rf -- "$legacy_signature_app"
make_app "$legacy_signature_app" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
print -n -- "tampered" >> "$legacy_signature_app/Contents/MacOS/RemoteControlNetwork"
print -r -- "preserve-damaged-legacy" > "$legacy_signature_app/legacy-marker"
snapshot_tree "$legacy_signature_home" "$legacy_signature_before"
if GATEBEAM_APP_DIR="$legacy_signature_source" \
  GATEBEAM_INSTALL_DIR="$legacy_signature_apps" \
  GATEBEAM_USER_HOME="$legacy_signature_home" \
    "$INSTALLER" >"$legacy_signature_log" 2>&1; then
  print -u2 -- "FAIL: installer deleted a damaged metadata-matching legacy app"
  exit 1
fi
assert_tree_snapshot "$legacy_signature_before" "$legacy_signature_home"
assert_file_content "preserve-damaged-legacy" "$legacy_signature_app/legacy-marker"
assert_text_present \
  fixed \
  "Preserving legacy app because its code signature is missing or invalid: $legacy_signature_app" \
  "$legacy_signature_log"
assert_no_transaction "$legacy_signature_home"

rollback_root="$fixture_root/developer-rollback"
rollback_home="$rollback_root/home"
rollback_apps="$rollback_home/Applications"
rollback_agents="$rollback_home/Library/LaunchAgents"
rollback_source="$rollback_root/source/Gatebeam.app"
rollback_destination="$rollback_apps/Gatebeam.app"
rollback_legacy="$rollback_apps/Remote Control Network.app"
rollback_stable="$rollback_agents/$stable_label.plist"
rollback_transitional="$rollback_agents/$transitional_label.plist"
mkdir -p "$rollback_apps" "$rollback_agents"
make_app "$rollback_source" "$current_bundle_id" "Gatebeam" true
make_app "$rollback_destination" "$current_bundle_id" "Gatebeam" true
make_app "$rollback_legacy" "com.local.RemoteControlNetwork" "RemoteControlNetwork" true
mkdir -p "$rollback_destination/Contents/Resources"
print "old-destination" > "$rollback_destination/Contents/Resources/old-marker"
mkdir -p "$rollback_legacy/Contents/Resources"
print "old-legacy" > "$rollback_legacy/Contents/Resources/old-marker"
sign_app "$rollback_destination" "$current_bundle_id"
codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.local.RemoteControlNetwork"' \
  "$rollback_legacy" >/dev/null
make_agent "$rollback_stable" "$stable_label" "$rollback_legacy"
make_agent "$rollback_transitional" "$transitional_label" "$rollback_legacy"
chmod 0711 "$rollback_destination"
chmod 0750 "$rollback_legacy"
chmod 0600 "$rollback_stable"
chmod 0640 "$rollback_transitional"
cp "$rollback_stable" "$rollback_root/stable-before.plist"
cp "$rollback_transitional" "$rollback_root/transitional-before.plist"
stat -f '%u:%g' "$rollback_stable" > "$rollback_root/stable-before.owner-group"
stat -f '%u:%g' "$rollback_transitional" > "$rollback_root/transitional-before.owner-group"
snapshot_tree "$rollback_destination" "$rollback_root/destination-before.manifest"
snapshot_tree "$rollback_legacy" "$rollback_root/legacy-before.manifest"

if GATEBEAM_APP_DIR="$rollback_source" \
  GATEBEAM_INSTALL_DIR="$rollback_apps" \
  GATEBEAM_USER_HOME="$rollback_home" \
  GATEBEAM_TEST_FAILURE_POINT=before-backup \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: injected early migration failure unexpectedly succeeded"
  exit 1
fi
assert_rollback_state \
  "$rollback_root" \
  "$rollback_destination" \
  "$rollback_legacy" \
  "$rollback_stable" \
  "$rollback_transitional" \
  "$rollback_home"

if GATEBEAM_APP_DIR="$rollback_source" \
  GATEBEAM_INSTALL_DIR="$rollback_apps" \
  GATEBEAM_USER_HOME="$rollback_home" \
  GATEBEAM_TEST_FAILURE_POINT=after-backups \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: injected post-backup failure unexpectedly succeeded"
  exit 1
fi
assert_rollback_state \
  "$rollback_root" \
  "$rollback_destination" \
  "$rollback_legacy" \
  "$rollback_stable" \
  "$rollback_transitional" \
  "$rollback_home"

if GATEBEAM_APP_DIR="$rollback_source" \
  GATEBEAM_INSTALL_DIR="$rollback_apps" \
  GATEBEAM_USER_HOME="$rollback_home" \
  GATEBEAM_TEST_FAIL_AFTER_APP_SWAP=1 \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: injected developer migration failure unexpectedly succeeded"
  exit 1
fi
assert_rollback_state \
  "$rollback_root" \
  "$rollback_destination" \
  "$rollback_legacy" \
  "$rollback_stable" \
  "$rollback_transitional" \
  "$rollback_home"

if GATEBEAM_APP_DIR="$rollback_source" \
  GATEBEAM_INSTALL_DIR="$rollback_apps" \
  GATEBEAM_USER_HOME="$rollback_home" \
  GATEBEAM_TEST_FAILURE_POINT=after-launch-agent \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: injected post-LaunchAgent failure unexpectedly succeeded"
  exit 1
fi
assert_rollback_state \
  "$rollback_root" \
  "$rollback_destination" \
  "$rollback_legacy" \
  "$rollback_stable" \
  "$rollback_transitional" \
  "$rollback_home"

set +e
GATEBEAM_APP_DIR="$rollback_source" \
GATEBEAM_INSTALL_DIR="$rollback_apps" \
GATEBEAM_USER_HOME="$rollback_home" \
GATEBEAM_TEST_SIGNAL_POINT=after-backups \
GATEBEAM_TEST_SIGNAL=TERM \
  "$INSTALLER" >/dev/null 2>&1
signal_status="$?"
set -e
[[ "$signal_status" == "143" ]] || {
  print -u2 -- "FAIL: expected TERM exit status 143, got $signal_status"
  exit 1
}
assert_rollback_state \
  "$rollback_root" \
  "$rollback_destination" \
  "$rollback_legacy" \
  "$rollback_stable" \
  "$rollback_transitional" \
  "$rollback_home"

restore_failure_root="$fixture_root/developer-restore-failure"
restore_failure_home="$restore_failure_root/home"
restore_failure_apps="$restore_failure_home/Applications"
restore_failure_source="$restore_failure_root/source/Gatebeam.app"
restore_failure_destination="$restore_failure_apps/Gatebeam.app"
restore_failure_log="$restore_failure_root/install.log"
mkdir -p "$restore_failure_apps"
make_app "$restore_failure_source" "$current_bundle_id" "Gatebeam" true
make_app "$restore_failure_destination" "$current_bundle_id" "Gatebeam" true
mkdir -p "$restore_failure_destination/Contents/Resources"
print "recoverable-previous-app" > "$restore_failure_destination/Contents/Resources/old-marker"
sign_app "$restore_failure_destination" "$current_bundle_id"

set +e
GATEBEAM_APP_DIR="$restore_failure_source" \
GATEBEAM_INSTALL_DIR="$restore_failure_apps" \
GATEBEAM_USER_HOME="$restore_failure_home" \
GATEBEAM_TEST_FAILURE_POINT=after-app-swap \
GATEBEAM_TEST_ROLLBACK_FAILURE_POINT=restore-destination \
  "$INSTALLER" >"$restore_failure_log" 2>&1
restore_failure_status="$?"
set -e
[[ "$restore_failure_status" == "98" ]] || {
  print -u2 -- "FAIL: expected rollback failure exit status 98, got $restore_failure_status"
  exit 1
}
restore_failure_transaction="$(
  find "$restore_failure_home" -maxdepth 1 -type d -name '.gatebeam-install.*' -print -quit
)"
[[ -n "$restore_failure_transaction" ]] || {
  print -u2 -- "FAIL: rollback failure did not preserve its transaction directory"
  exit 1
}
assert_file_content \
  "recoverable-previous-app" \
  "$restore_failure_transaction/previous.app/Contents/Resources/old-marker"
assert_text_present \
  fixed \
  "Recovery files were preserved at: $restore_failure_transaction" \
  "$restore_failure_log"

GATEBEAM_APP_DIR="$rollback_source" \
GATEBEAM_INSTALL_DIR="$rollback_apps" \
GATEBEAM_USER_HOME="$rollback_home" \
  "$INSTALLER" >/dev/null
assert_exists "$rollback_destination"
assert_missing "$rollback_legacy"
assert_exists "$rollback_stable"
assert_missing "$rollback_transitional"
assert_no_transaction "$rollback_home"

GATEBEAM_APP_DIR="$rollback_source" \
GATEBEAM_INSTALL_DIR="$rollback_apps" \
GATEBEAM_USER_HOME="$rollback_home" \
  "$INSTALLER" >/dev/null
assert_exists "$rollback_destination"
assert_missing "$rollback_legacy"
assert_exists "$rollback_stable"
assert_missing "$rollback_transitional"
assert_no_transaction "$rollback_home"

symlink_home="$fixture_root/developer-symlink/home"
symlink_outside="$fixture_root/developer-symlink/outside-applications"
symlink_source="$fixture_root/developer-symlink/source/Gatebeam.app"
mkdir -p "$symlink_home" "$symlink_outside"
make_app "$symlink_source" "$current_bundle_id" "Gatebeam" true
make_app "$symlink_outside/Gatebeam.app" "com.example.Unrelated" "Gatebeam"
ln -s "$symlink_outside" "$symlink_home/Applications"
if GATEBEAM_APP_DIR="$symlink_source" \
  GATEBEAM_INSTALL_DIR="$symlink_home/Applications" \
  GATEBEAM_USER_HOME="$symlink_home" \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: developer install followed an Applications symlink"
  exit 1
fi
outside_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$symlink_outside/Gatebeam.app/Contents/Info.plist")"
[[ "$outside_identifier" == "com.example.Unrelated" ]]

fake_root="$fixture_root/developer-forged"
fake_home="$fake_root/home"
fake_apps="$fake_home/Applications"
fake_source="$fake_root/source/Gatebeam.app"
fake_legacy="$fake_apps/Remote Control Network.app"
mkdir -p "$fake_apps" "$fake_home/Library/LaunchAgents"
make_app "$fake_source" "$current_bundle_id" "Gatebeam" true
make_app "$fake_legacy" "com.local.RemoteControlNetwork" "Gatebeam"
if GATEBEAM_APP_DIR="$fake_source" \
  GATEBEAM_INSTALL_DIR="$fake_apps" \
  GATEBEAM_USER_HOME="$fake_home" \
    "$INSTALLER" >/dev/null 2>&1; then
  print -u2 -- "FAIL: developer install accepted a forged legacy executable"
  exit 1
fi
assert_exists "$fake_legacy"

assert_adjacent_lines \
  '^[[:space:]]*if !isUIValidationMode \{$' \
  '^[[:space:]]+LaunchAgentManager\(\)\.migrateLegacyUserState\(\)$' \
  "$ROOT_DIR/Sources/RemoteControlNetwork/AppDelegate.swift"

print "All package upgrade fixture tests passed"
