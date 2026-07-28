#!/bin/zsh -f
set -euo pipefail
unsetopt BG_NICE

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DELEGATE="$ROOT_DIR/Sources/RemoteControlNetwork/AppDelegate.swift"
NETWORK_AGENT="$ROOT_DIR/Sources/RemoteControlNetwork/NetworkAgent.swift"
APP_EXECUTABLE="$ROOT_DIR/dist/Gatebeam.app/Contents/MacOS/Gatebeam"
VALIDATION_ROOT=""
APP_PID=""

if (( $+commands[rg] )); then
  TEXT_SEARCH_TOOL="$commands[rg]"
  TEXT_SEARCH_KIND="rg"
elif [[ -x /usr/bin/grep ]]; then
  TEXT_SEARCH_TOOL="/usr/bin/grep"
  TEXT_SEARCH_KIND="grep"
else
  print -u2 'UI validation contract failed: neither rg nor /usr/bin/grep is available'
  exit 1
fi

fixed_text_search_quiet() {
  local pattern="$1"
  shift

  local search_status
  if [[ "$TEXT_SEARCH_KIND" == "rg" ]]; then
    if "$TEXT_SEARCH_TOOL" --fixed-strings --quiet -- "$pattern" "$@"; then
      search_status=0
    else
      search_status="$?"
    fi
  else
    if "$TEXT_SEARCH_TOOL" -Fq -- "$pattern" "$@"; then
      search_status=0
    else
      search_status="$?"
    fi
  fi

  if (( search_status > 1 )); then
    print -u2 -- "UI validation contract failed: $TEXT_SEARCH_KIND could not search: $*"
    exit "$search_status"
  fi
  return "$search_status"
}

require_contract() {
  local pattern="$1"
  local description="$2"
  local file_path="${3:-$APP_DELEGATE}"

  if ! fixed_text_search_quiet "$pattern" "$file_path"; then
    print -u2 "UI validation contract failed: $description"
    exit 1
  fi
}

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$VALIDATION_ROOT" && -d "$VALIDATION_ROOT" ]]; then
    rm -rf "$VALIDATION_ROOT"
  fi
}

trap cleanup EXIT INT TERM

require_contract 'CommandLine.arguments.contains("--ui-validation")' 'validation mode flag is missing'
require_contract 'sideEffectsEnabled: !isUIValidationMode' 'validation mode may permit NetworkAgent side effects'
require_contract 'autoLoadCloudflare: !isUIValidationMode' 'settings window may load the Cloudflare token during validation'
require_contract 'if !isUIValidationMode {' 'validation mode lifecycle guards are missing'
require_contract 'LaunchAgentManager().migrateLegacyUserState()' 'login item migration wiring is missing'
require_contract 'agent.start()' 'agent lifecycle wiring is missing'
require_contract 'SettingsWindowController(' 'settings window construction is missing'
require_contract \
  'guard sideEffectsEnabled else { return }' \
  'NetworkAgent entry points are not side-effect gated' \
  "$NETWORK_AGENT"

"$ROOT_DIR/scripts/test_integration_contract.sh"
"$ROOT_DIR/scripts/build_app.sh"

VALIDATION_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/gatebeam-ui-validation.XXXXXX")"
VALIDATION_HOME="$VALIDATION_ROOT/home"
VALIDATION_TMP="$VALIDATION_ROOT/tmp"
PRODUCTION_SUPPORT="$VALIDATION_HOME/Library/Application Support/RemoteControlNetwork"
LAUNCH_AGENTS="$VALIDATION_HOME/Library/LaunchAgents"
LEGACY_APP="$VALIDATION_HOME/Applications/Remote Control Network.app"
APP_LOG="$VALIDATION_ROOT/gatebeam.log"
SANDBOX_PROFILE="$VALIDATION_ROOT/network-deny.sb"

mkdir -p "$VALIDATION_TMP" "$PRODUCTION_SUPPORT" "$LAUNCH_AGENTS" "$LEGACY_APP"
chmod 700 "$VALIDATION_HOME" "$VALIDATION_TMP"

print -rn -- 'production-config-must-not-change' > "$PRODUCTION_SUPPORT/config.json"
print -rn -- 'stable-launch-agent-must-not-change' > "$LAUNCH_AGENTS/com.local.RemoteControlNetwork.login.plist"
print -rn -- 'transitional-launch-agent-must-not-change' > "$LAUNCH_AGENTS/io.github.naifuliang.gatebeam.login.plist"
print -rn -- 'legacy-app-must-not-change' > "$LEGACY_APP/sentinel"

CONFIG_BEFORE="$(shasum -a 256 "$PRODUCTION_SUPPORT/config.json")"
STABLE_AGENT_BEFORE="$(shasum -a 256 "$LAUNCH_AGENTS/com.local.RemoteControlNetwork.login.plist")"
TRANSITIONAL_AGENT_BEFORE="$(shasum -a 256 "$LAUNCH_AGENTS/io.github.naifuliang.gatebeam.login.plist")"
LEGACY_APP_BEFORE="$(shasum -a 256 "$LEGACY_APP/sentinel")"

cat > "$SANDBOX_PROFILE" <<'PROFILE'
(version 1)
(allow default)
(deny network*)
PROFILE

APP_ARGUMENTS=(--ui-validation)
if pgrep -x WindowServer >/dev/null 2>&1; then
  APP_ARGUMENTS+=(--show-settings)
  print 'WindowServer available: exercising AppDelegate and settings presentation.'
else
  print 'WindowServer unavailable: skipping visual presentation; exercising AppDelegate wiring headlessly.'
fi

HOME="$VALIDATION_HOME" \
CFFIXED_USER_HOME="$VALIDATION_HOME" \
TMPDIR="$VALIDATION_TMP/" \
XDG_CONFIG_HOME="$VALIDATION_HOME/.config" \
/usr/bin/sandbox-exec -f "$SANDBOX_PROFILE" \
  "$APP_EXECUTABLE" "${APP_ARGUMENTS[@]}" >"$APP_LOG" 2>&1 &
APP_PID=$!

# A healthy menu bar app remains in NSApplication.run after AppDelegate
# finishes wiring. Bound the probe so a launch regression cannot hang CI.
for _ in {1..30}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    print -u2 'UI validation failed: Gatebeam exited before AppDelegate validation completed.'
    sed -n '1,160p' "$APP_LOG" >&2
    exit 1
  fi
  sleep 0.1
done

NETWORK_HANDLES="$(lsof -nP -a -p "$APP_PID" -iTCP -iUDP 2>/dev/null || true)"
if [[ -n "$NETWORK_HANDLES" ]]; then
  print -u2 'UI validation failed: Gatebeam opened an IP socket in validation mode.'
  print -u2 -- "$NETWORK_HANDLES"
  exit 1
fi

kill -TERM "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

[[ "$(shasum -a 256 "$PRODUCTION_SUPPORT/config.json")" == "$CONFIG_BEFORE" ]] || {
  print -u2 'UI validation failed: production configuration changed.'
  exit 1
}
[[ "$(shasum -a 256 "$LAUNCH_AGENTS/com.local.RemoteControlNetwork.login.plist")" == "$STABLE_AGENT_BEFORE" ]] || {
  print -u2 'UI validation failed: stable LaunchAgent changed.'
  exit 1
}
[[ "$(shasum -a 256 "$LAUNCH_AGENTS/io.github.naifuliang.gatebeam.login.plist")" == "$TRANSITIONAL_AGENT_BEFORE" ]] || {
  print -u2 'UI validation failed: transitional LaunchAgent changed.'
  exit 1
}
[[ "$(shasum -a 256 "$LEGACY_APP/sentinel")" == "$LEGACY_APP_BEFORE" ]] || {
  print -u2 'UI validation failed: legacy app migration ran.'
  exit 1
}

KEYCHAIN_FILE=""
if [[ -d "$VALIDATION_HOME/Library/Keychains" ]]; then
  KEYCHAIN_FILE="$(find "$VALIDATION_HOME/Library/Keychains" -type f -print -quit)"
fi
if [[ -n "$KEYCHAIN_FILE" ]]; then
  print -u2 'UI validation failed: validation created a Keychain file.'
  exit 1
fi

UNEXPECTED_LAUNCH_AGENT="$(
  find "$LAUNCH_AGENTS" \
    -mindepth 1 \
    -maxdepth 1 \
    -type f \
    ! -name 'com.local.RemoteControlNetwork.login.plist' \
    ! -name 'io.github.naifuliang.gatebeam.login.plist' \
    -print \
    -quit
)"
if [[ -n "$UNEXPECTED_LAUNCH_AGENT" ]]; then
  print -u2 'UI validation failed: validation created an unexpected LaunchAgent.'
  exit 1
fi

print 'UI validation isolation contract passed: AppDelegate launched with no config, Keychain, LaunchAgent, or IP network side effects.'
