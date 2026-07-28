#!/bin/zsh -f
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset CDPATH ENV BASH_ENV

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d "/private/tmp/gatebeam-clean-machine.XXXXXX")"

cleanup() {
  chmod -R u+rwx -- "$FIXTURE_ROOT" 2>/dev/null || true
  rm -rf -- "$FIXTURE_ROOT"
}
trap 'cleanup' EXIT HUP INT TERM

"$ROOT_DIR/scripts/build_app.sh"
"$ROOT_DIR/scripts/test_upgrade.sh"

TEST_HOME="$FIXTURE_ROOT/home"
TEST_APPLICATIONS="$TEST_HOME/Applications"
INSTALLED_APP="$TEST_APPLICATIONS/Gatebeam.app"
LAUNCH_AGENT="$TEST_HOME/Library/LaunchAgents/com.local.RemoteControlNetwork.login.plist"
mkdir -p "$TEST_HOME"

GATEBEAM_APP_DIR="$ROOT_DIR/dist/Gatebeam.app" \
GATEBEAM_INSTALL_DIR="$TEST_APPLICATIONS" \
GATEBEAM_USER_HOME="$TEST_HOME" \
  "$ROOT_DIR/scripts/install_app.sh" >/dev/null

[[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" &&
    -z "$(find "$TEST_HOME" -maxdepth 1 -type d -name '.gatebeam-install.*' -print -quit)" ]] || {
  print -u2 -- "FAIL: isolated clean-machine installation did not complete"
  exit 1
}

rm -rf -- "$INSTALLED_APP"
rm -f -- "$LAUNCH_AGENT"

[[ ! -e "$INSTALLED_APP" && ! -L "$INSTALLED_APP" &&
    ! -e "$LAUNCH_AGENT" && ! -L "$LAUNCH_AGENT" &&
    -z "$(find "$TEST_HOME" -maxdepth 1 -type d -name '.gatebeam-install.*' -print -quit)" ]] || {
  print -u2 -- "FAIL: isolated clean-machine uninstall left managed state"
  exit 1
}

print -r -- "Clean-machine install, upgrade, failure rollback, and uninstall validation passed"
