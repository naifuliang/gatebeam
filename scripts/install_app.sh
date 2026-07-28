#!/bin/zsh -f
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CDPATH ENV BASH_ENV
IFS=$' \t\n'

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP_NAME="Gatebeam"
readonly BUNDLE_ID="com.local.RemoteControlNetwork"
readonly STABLE_LABEL="com.local.RemoteControlNetwork.login"
readonly TRANSITIONAL_LABEL="io.github.naifuliang.gatebeam.login"
readonly APP_DIR="${GATEBEAM_APP_DIR:-$ROOT_DIR/dist/$APP_NAME.app}"
readonly USER_HOME="${GATEBEAM_USER_HOME:-$HOME}"
readonly INSTALL_DIR="${GATEBEAM_INSTALL_DIR:-$USER_HOME/Applications}"
readonly DESTINATION="$INSTALL_DIR/$APP_NAME.app"
readonly LEGACY_APP="$USER_HOME/Applications/Remote Control Network.app"
readonly AGENTS_DIR="$USER_HOME/Library/LaunchAgents"
readonly STABLE_PLIST="$AGENTS_DIR/$STABLE_LABEL.plist"
readonly TRANSITIONAL_PLIST="$AGENTS_DIR/$TRANSITIONAL_LABEL.plist"

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

fail() {
  /bin/echo "$*" >&2
  return 1
}

is_symbolic_link_free_path() {
  local base="$1"
  local target="$2"
  local relative
  local current
  local component
  local -a components

  [[ "$target" == "$base" || "$target" == "$base/"* ]] || return 1
  [[ ! -L "$base" ]] || return 1
  relative="${target#$base}"
  relative="${relative#/}"
  [[ -n "$relative" ]] || return 0
  components=("${(@s:/:)relative}")
  current="$base"
  for component in "${components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

bundle_value() {
  local app_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist" 2>/dev/null
}

is_recognized_app() {
  local app_path="$1"
  local expected_executable="$2"
  local executable_path="$app_path/Contents/MacOS/$expected_executable"

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 1
  [[ -d "$app_path/Contents" && ! -L "$app_path/Contents" ]] || return 1
  [[ -f "$app_path/Contents/Info.plist" && ! -L "$app_path/Contents/Info.plist" ]] || return 1
  [[ -d "$app_path/Contents/MacOS" && ! -L "$app_path/Contents/MacOS" ]] || return 1
  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] || return 1
  [[ "$(bundle_value "$app_path" CFBundleIdentifier || true)" == "$BUNDLE_ID" ]] || return 1
  [[ "$(bundle_value "$app_path" CFBundleExecutable || true)" == "$expected_executable" ]]
}

has_valid_code_signature() {
  /usr/bin/codesign --verify --deep --strict "$1" >/dev/null 2>&1
}

validate_legacy_code_signature() {
  has_valid_code_signature "$LEGACY_APP" && return 0
  /bin/echo \
    "Preserving legacy app because its code signature is missing or invalid: $LEGACY_APP. Remove or repair the legacy app manually, then run the Gatebeam installer again." \
    >&2
  return 1
}

managed_plist_label() {
  local plist_path="$1"
  [[ -f "$plist_path" && ! -L "$plist_path" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :Label' "$plist_path" 2>/dev/null
}

write_launch_agent() {
  local output_path="$1"
  /usr/libexec/PlistBuddy -c "Add :Label string $STABLE_LABEL" "$output_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$output_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/open" "$output_path"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $DESTINATION" "$output_path"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$output_path"
  /bin/chmod 0644 "$output_path"
  /usr/sbin/chown "$(/usr/bin/id -u):$(/usr/bin/id -g)" "$output_path"
}

transaction_state="inactive"
transaction_dir=""
temporary_destination=""
destination_backup=""
legacy_backup=""
stable_backup=""
transitional_backup=""
generated_stable_plist=""
destination_install_started=false
stable_install_started=false
created_install_dir=false
created_agents_dir=false
transaction_exit_code=0
rollback_failed=false

report_rollback_failure() {
  rollback_failed=true
  fail "Rollback step failed: $1"
}

inject_rollback_failure() {
  local point="$1"
  local failure_point="${GATEBEAM_TEST_ROLLBACK_FAILURE_POINT:-}"

  [[ "$failure_point" == "$point" ]] || return 0
  test_injection_allowed || {
    fail "Test rollback failure injection is restricted to a temporary fixture"
    return 1
  }
  fail "Injected rollback failure at $point"
  return 97
}

rollback_transaction() {
  [[ "$transaction_state" == "active" ]] || return 0
  set +e
  rollback_failed=false

  if [[ "$stable_install_started" == true ]]; then
    /bin/rm -f -- "$STABLE_PLIST" ||
      report_rollback_failure "remove the newly installed login item"
  fi
  if [[ "$destination_install_started" == true ]]; then
    /bin/rm -rf -- "$DESTINATION" ||
      report_rollback_failure "remove the newly installed application"
  fi

  if path_exists "$destination_backup"; then
    if ! inject_rollback_failure restore-destination; then
      report_rollback_failure "restore the previous application"
    elif ! /bin/rm -rf -- "$DESTINATION"; then
      report_rollback_failure "prepare the previous application destination"
    elif ! /bin/mv -- "$destination_backup" "$DESTINATION"; then
      report_rollback_failure "restore the previous application"
    fi
  fi
  if path_exists "$legacy_backup"; then
    /bin/mv -- "$legacy_backup" "$LEGACY_APP" ||
      report_rollback_failure "restore the legacy application"
  fi
  if path_exists "$stable_backup"; then
    if ! /bin/rm -f -- "$STABLE_PLIST"; then
      report_rollback_failure "prepare the previous login item destination"
    elif ! /bin/mv -- "$stable_backup" "$STABLE_PLIST"; then
      report_rollback_failure "restore the previous login item"
    fi
  fi
  if path_exists "$transitional_backup"; then
    /bin/mv -- "$transitional_backup" "$TRANSITIONAL_PLIST" ||
      report_rollback_failure "restore the transitional login item"
  fi

  if [[ "$rollback_failed" == true ]]; then
    transaction_state="rollback-failed"
    fail "Gatebeam could not fully restore the previous installation."
    fail "Recovery files were preserved at: $transaction_dir"
    fail "Keep this directory until the previous application and login item have been recovered."
    return 1
  fi

  /bin/rm -rf -- "$transaction_dir" || {
    transaction_state="rollback-failed"
    fail "Rollback completed, but the transaction directory could not be removed: $transaction_dir"
    return 1
  }
  if [[ "$created_agents_dir" == true ]]; then
    /bin/rmdir -- "$AGENTS_DIR" 2>/dev/null || true
  fi
  if [[ "$created_install_dir" == true ]]; then
    /bin/rmdir -- "$INSTALL_DIR" 2>/dev/null || true
  fi
  transaction_state="rolled-back"
  return 0
}

finish_with_rollback() {
  transaction_exit_code="$1"
  trap - EXIT HUP INT TERM
  rollback_transaction
  if [[ "$?" -ne 0 ]]; then
    exit 98
  fi
  exit "$transaction_exit_code"
}

exit_with_rollback() {
  finish_with_rollback "$1"
}

handle_transaction_exit() {
  finish_with_rollback "$1"
}

handle_transaction_signal() {
  finish_with_rollback "$1"
}

test_injection_allowed() {
  [[ "$USER_HOME" == /private/tmp/* ]]
}

inject_test_event() {
  local point="$1"
  local failure_point="${GATEBEAM_TEST_FAILURE_POINT:-}"
  local signal_point="${GATEBEAM_TEST_SIGNAL_POINT:-}"
  local signal_name="${GATEBEAM_TEST_SIGNAL:-TERM}"

  if [[ "$failure_point" == "$point" ]]; then
    test_injection_allowed || {
      fail "Test failure injection is restricted to a temporary fixture"
      return 1
    }
    fail "Injected install failure at $point"
    return 97
  fi

  if [[ "$signal_point" == "$point" ]]; then
    test_injection_allowed || {
      fail "Test signal injection is restricted to a temporary fixture"
      return 1
    }
    case "$signal_name" in
      HUP) /bin/kill -HUP "$$" ;;
      INT) /bin/kill -INT "$$" ;;
      TERM) /bin/kill -TERM "$$" ;;
      *)
        fail "Unsupported test signal: $signal_name"
        return 1
        ;;
    esac
  fi
}

[[ "$USER_HOME" == /* && "$INSTALL_DIR" == /* ]] || {
  fail "Installation paths must be absolute"
  exit 1
}
[[ -d "$USER_HOME" && ! -L "$USER_HOME" && "${USER_HOME:A}" == "$USER_HOME" ]] || {
  fail "Refusing an unsafe user home: $USER_HOME"
  exit 1
}
[[ "$INSTALL_DIR" == "$USER_HOME/Applications" ]] || {
  fail "Refusing an install directory outside the user's Applications folder"
  exit 1
}
is_symbolic_link_free_path "$USER_HOME" "$INSTALL_DIR" || {
  fail "Refusing a symbolic-link Applications path"
  exit 1
}
is_symbolic_link_free_path "$USER_HOME" "$AGENTS_DIR" || {
  fail "Refusing a symbolic-link LaunchAgents path"
  exit 1
}

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi
is_recognized_app "$APP_DIR" "Gatebeam" || {
  fail "Refusing to install an unrecognized source application: $APP_DIR"
  exit 1
}
has_valid_code_signature "$APP_DIR" || {
  fail "Refusing to install an application with an invalid code signature: $APP_DIR"
  exit 1
}

if path_exists "$DESTINATION"; then
  is_recognized_app "$DESTINATION" "Gatebeam" || {
    fail "Refusing to replace an unrecognized app: $DESTINATION"
    exit 1
  }
fi
if path_exists "$LEGACY_APP"; then
  is_recognized_app "$LEGACY_APP" "RemoteControlNetwork" || {
    fail "Refusing to migrate an unrecognized legacy app: $LEGACY_APP"
    exit 1
  }
  validate_legacy_code_signature || {
    exit 1
  }
fi
if path_exists "$STABLE_PLIST"; then
  [[ "$(managed_plist_label "$STABLE_PLIST" || true)" == "$STABLE_LABEL" ]] || {
    fail "Refusing to replace an unrecognized LaunchAgent: $STABLE_PLIST"
    exit 1
  }
fi
if path_exists "$TRANSITIONAL_PLIST"; then
  [[ "$(managed_plist_label "$TRANSITIONAL_PLIST" || true)" == "$TRANSITIONAL_LABEL" ]] || {
    fail "Refusing to replace an unrecognized LaunchAgent: $TRANSITIONAL_PLIST"
    exit 1
  }
fi

login_item_enabled=false
if path_exists "$STABLE_PLIST" || path_exists "$TRANSITIONAL_PLIST"; then
  login_item_enabled=true
fi

transaction_dir="$(/usr/bin/mktemp -d "$USER_HOME/.gatebeam-install.XXXXXX")"
temporary_destination="$transaction_dir/new.app"
destination_backup="$transaction_dir/previous.app"
legacy_backup="$transaction_dir/legacy.app"
stable_backup="$transaction_dir/stable.plist"
transitional_backup="$transaction_dir/transitional.plist"
generated_stable_plist="$transaction_dir/new-stable.plist"
transaction_state="active"
trap 'handle_transaction_exit $?' EXIT
trap 'handle_transaction_signal 129' HUP
trap 'handle_transaction_signal 130' INT
trap 'handle_transaction_signal 143' TERM

if [[ ! -d "$INSTALL_DIR" ]]; then
  created_install_dir=true
  /bin/mkdir -- "$INSTALL_DIR" || exit_with_rollback "$?"
fi
if [[ "$login_item_enabled" == true && ! -d "$AGENTS_DIR" ]]; then
  [[ -d "$USER_HOME/Library" && ! -L "$USER_HOME/Library" ]] || {
    fail "Refusing to create LaunchAgents below an unsafe Library directory"
    exit_with_rollback 1
  }
  created_agents_dir=true
  /bin/mkdir -- "$AGENTS_DIR" || exit_with_rollback "$?"
fi

COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$APP_DIR" "$temporary_destination" ||
  exit_with_rollback "$?"
is_recognized_app "$temporary_destination" "Gatebeam" || {
  fail "Copied application failed validation"
  exit_with_rollback 1
}
has_valid_code_signature "$temporary_destination" || {
  fail "Copied application failed code signature validation"
  exit_with_rollback 1
}

inject_test_event before-backup || exit_with_rollback "$?"

if path_exists "$DESTINATION"; then
  /bin/mv -- "$DESTINATION" "$destination_backup" || exit_with_rollback "$?"
fi
if path_exists "$LEGACY_APP"; then
  validate_legacy_code_signature || exit_with_rollback 1
  /bin/mv -- "$LEGACY_APP" "$legacy_backup" || exit_with_rollback "$?"
fi
if path_exists "$STABLE_PLIST"; then
  /bin/mv -- "$STABLE_PLIST" "$stable_backup" || exit_with_rollback "$?"
fi
if path_exists "$TRANSITIONAL_PLIST"; then
  /bin/mv -- "$TRANSITIONAL_PLIST" "$transitional_backup" || exit_with_rollback "$?"
fi

inject_test_event after-backups || exit_with_rollback "$?"

destination_install_started=true
/bin/mv -- "$temporary_destination" "$DESTINATION" || exit_with_rollback "$?"

if [[ "${GATEBEAM_TEST_FAIL_AFTER_APP_SWAP:-0}" == "1" ]]; then
  GATEBEAM_TEST_FAILURE_POINT=after-app-swap
fi
inject_test_event after-app-swap || exit_with_rollback "$?"

if [[ "$login_item_enabled" == true ]]; then
  write_launch_agent "$generated_stable_plist" || exit_with_rollback "$?"
  stable_install_started=true
  /bin/mv -- "$generated_stable_plist" "$STABLE_PLIST" || exit_with_rollback "$?"
fi

inject_test_event after-launch-agent || exit_with_rollback "$?"

transaction_state="committed"
trap - EXIT HUP INT TERM
/bin/rm -rf -- "$transaction_dir" || {
  fail "Installed successfully, but could not remove transaction backups: $transaction_dir"
  exit 1
}

/bin/echo "Installed: $DESTINATION"
