#!/bin/zsh -f
set -euo pipefail
unsetopt BG_NICE

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_SOURCE="$ROOT_DIR/Tests/ReleasePipelineTests"
TEST_ROOT="$(mktemp -d "/private/tmp/Gatebeam Release Pipeline Tests.XXXXXX")"
PASSED=0
FAILED=0
typeset -a EXTRA_CLEANUP_PATHS=()

cleanup() {
  local cleanup_status=0
  local cleanup_path

  if [[ "${GATEBEAM_KEEP_RELEASE_TEST_FIXTURES:-0}" == "1" ]]; then
    print -u2 -- "Kept release test fixtures: $TEST_ROOT"
    return
  fi
  if [[ "${GATEBEAM_RELEASE_TEST_CLEANUP_FAILURE:-0}" == "1" ]]; then
    return 70
  fi
  rm -rf -- "$TEST_ROOT" || cleanup_status=$?
  for cleanup_path in "${EXTRA_CLEANUP_PATHS[@]}"; do
    rm -rf -- "$cleanup_path" || cleanup_status=$?
  done
  return "$cleanup_status"
}

handle_signal() {
  local signal_name="$1"
  local signal_status="$2"
  local cleanup_status=0

  trap - EXIT HUP INT TERM
  cleanup || cleanup_status=$?
  if (( cleanup_status != 0 )); then
    print -u2 -- \
      "error: fixture cleanup failed while handling $signal_name (status $cleanup_status)" ||
      true
  fi
  trap - "$signal_name"
  if [[ "$signal_name" == "HUP" ]]; then
    # Non-interactive zsh maps a default HUP termination to 1, unlike 128+signal.
    trap 'trap - HUP; exit 129' HUP
  fi
  /bin/kill -s "$signal_name" "$$" || {
    print -u2 -- "error: could not re-deliver $signal_name; preserving exit status" ||
      true
    exit "$signal_status"
  }
  exit "$signal_status"
}

trap 'cleanup' EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

if [[ "${GATEBEAM_RELEASE_TEST_SIGNAL_HARNESS:-0}" == "1" ]]; then
  signal_ready_file="${GATEBEAM_RELEASE_TEST_SIGNAL_READY_FILE:?}"
  print -r -- "live" >"$TEST_ROOT/.signal-harness-live"
  print -r -- "$TEST_ROOT" >"$signal_ready_file"
  while true; do
    /bin/sleep 1
  done
fi

pass() {
  PASSED=$((PASSED + 1))
  print -r -- "PASS: $1"
}

fail_test() {
  local diagnostic_log=""

  FAILED=$((FAILED + 1))
  print -u2 -- "FAIL: $1"
  if (( $# >= 2 )); then
    diagnostic_log="$2"
  elif [[ -n "${fixture:-}" ]]; then
    diagnostic_log="$fixture/test-output.log"
  fi
  print_safe_log_tail "$diagnostic_log"
}

print_safe_log_tail() {
  local log_path="$1"

  [[ -n "$log_path" ]] || return
  print -u2 -- "--- redacted diagnostic tail ---"
  if ! /usr/bin/python3 -I -E -s - "$TEST_ROOT" "$log_path" <<'PY'
import errno
import os
import re
import stat
import sys

LOG_LIMIT = 1024 * 1024
SECRET_LIMIT = 4 * 1024
root_path = os.path.abspath(sys.argv[1])
log_path = os.path.abspath(sys.argv[2])
open_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
directory_flags = open_flags | os.O_DIRECTORY


def checked_stat(file_descriptor, size_limit):
    metadata = os.fstat(file_descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size < 0
        or metadata.st_size > size_limit
    ):
        raise ValueError("unsafe diagnostic file")
    return metadata


def secure_read(parent_descriptor, name, size_limit, required):
    try:
        descriptor = os.open(
            name,
            open_flags,
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        if required:
            raise
        return None
    try:
        before = checked_stat(descriptor, size_limit)
        chunks = []
        byte_count = 0
        while True:
            chunk = os.read(descriptor, min(65536, size_limit + 1 - byte_count))
            if not chunk:
                break
            chunks.append(chunk)
            byte_count += len(chunk)
            if byte_count > size_limit:
                raise ValueError("oversized diagnostic file")
        after = checked_stat(descriptor, size_limit)
        if (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise ValueError("diagnostic file changed while reading")
        if byte_count != before.st_size:
            raise ValueError("diagnostic file size changed while reading")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


root_descriptor = None
parent_descriptor = None
try:
    if os.path.commonpath((root_path, log_path)) != root_path:
        raise ValueError("diagnostic path escaped test root")
    relative_path = os.path.relpath(log_path, root_path)
    components = relative_path.split(os.sep)
    if (
        relative_path == os.curdir
        or any(component in ("", os.curdir, os.pardir) for component in components)
    ):
        raise ValueError("invalid diagnostic path")

    root_descriptor = os.open(root_path, directory_flags)
    root_metadata = os.fstat(root_descriptor)
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise ValueError("test root is not a directory")

    parent_descriptor = os.dup(root_descriptor)
    for component in components[:-1]:
        next_descriptor = os.open(
            component,
            directory_flags,
            dir_fd=parent_descriptor,
        )
        next_metadata = os.fstat(next_descriptor)
        if not stat.S_ISDIR(next_metadata.st_mode):
            os.close(next_descriptor)
            raise ValueError("diagnostic parent is not a directory")
        os.close(parent_descriptor)
        parent_descriptor = next_descriptor

    secrets = []
    for candidate in ("github-token", ".diagnostic-redactions"):
        payload = secure_read(
            parent_descriptor,
            candidate,
            SECRET_LIMIT,
            required=False,
        )
        if payload is None:
            continue
        for value in payload.decode("utf-8", errors="replace").splitlines():
            if value:
                secrets.append(value)

    log_payload = secure_read(
        parent_descriptor,
        components[-1],
        LOG_LIMIT,
        required=True,
    )
    text = log_payload.decode("utf-8", errors="replace")
    for secret in sorted(set(secrets), key=len, reverse=True):
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(
        r"(?i)(Authorization:\s*(?:Bearer|token)\s+)[^\s\"']+",
        r"\1[REDACTED]",
        text,
    )
    text = re.sub(
        r"(?i)(GATEBEAM_NOTARY_PROFILE=)(?:\"[^\"]*\"|'[^']*'|[^\s]+)",
        r"\1[REDACTED]",
        text,
    )
    for line in text.splitlines()[-80:]:
        print(line)
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if parent_descriptor is not None:
        os.close(parent_descriptor)
    if root_descriptor is not None:
        os.close(root_descriptor)
PY
  then
    print -u2 -- "Diagnostic log rejected by secure reader."
  fi
  print -u2 -- "--- end redacted diagnostic tail ---"
}

new_fixture() {
  local name="$1"
  local fixture="$TEST_ROOT/$name/Gatebeam Fixture"
  local tool_dir="$fixture/fake tools"

  mkdir -p \
    "$fixture/scripts" \
    "$fixture/Resources" \
    "$fixture/Tests/ReleasePipelineTests" \
    "$tool_dir"
  cp \
    "$ROOT_DIR/scripts/release_candidate_internal.sh" \
    "$fixture/scripts/release_candidate_internal.sh"
  cp \
    "$ROOT_DIR/scripts/prepare_release_candidate.sh" \
    "$fixture/scripts/prepare_release_candidate.sh"
  cp \
    "$ROOT_DIR/scripts/release_artifact_contract.py" \
    "$fixture/scripts/release_artifact_contract.py"
  cp \
    "$ROOT_DIR/scripts/release_history_contract.py" \
    "$fixture/scripts/release_history_contract.py"
  cp "$ROOT_DIR/scripts/verify_release.sh" "$fixture/scripts/verify_release.sh"
  cp "$ROOT_DIR/scripts/signing_contract.sh" "$fixture/scripts/signing_contract.sh"
  cp "$FIXTURE_SOURCE/fake_build_app.sh" "$fixture/scripts/build_app.sh"
  cp "$FIXTURE_SOURCE/fake_package_pkg.sh" "$fixture/scripts/package_pkg.sh"
  cp "$FIXTURE_SOURCE/fake_package_dmg.sh" "$fixture/scripts/package_dmg.sh"
  cp "$FIXTURE_SOURCE/fake_release_tool.sh" "$tool_dir/release-tool"
  cp "$FIXTURE_SOURCE/fake_github_api.py" "$tool_dir/fake_github_api.py"
  print -r -- "Gatebeam release test fixture v1" \
    >"$fixture/.gatebeam-release-test-fixture"
  cp \
    "$fixture/.gatebeam-release-test-fixture" \
    "$tool_dir/.gatebeam-release-test-fixture"
  chmod +x "$fixture/scripts/"*.sh "$tool_dir/release-tool"

  for tool in codesign curl ditto hdiutil lipo pkgutil productsign spctl xcrun; do
    cp "$tool_dir/release-tool" "$tool_dir/$tool"
  done

  /usr/libexec/PlistBuddy \
    -c 'Clear dict' \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleIdentifier string io.github.naifuliang.gatebeam' \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleShortVersionString string 0.5.0' \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleVersion string 5' \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleExecutable string Gatebeam' \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c 'Add :LSMinimumSystemVersion string 13.0' \
    "$fixture/Resources/Info.plist" >/dev/null

  print -r -- $'dist/\nbuild/\ncalls.log\ntest-output.log\ngithub-token\ncurl-argv.log\ncurl-env.log\n.diagnostic-redactions' >"$fixture/.gitignore"
  print -r -- "fixture profile" >"$fixture/.diagnostic-redactions"
  chmod 600 "$fixture/.diagnostic-redactions"
  /usr/bin/git -C "$fixture" init -q -b main
  /usr/bin/git -C "$fixture" config user.name "Gatebeam Release Tests"
  /usr/bin/git -C "$fixture" config user.email "release-tests@invalid"
  /usr/bin/git -C "$fixture" add .
  /usr/bin/git -C "$fixture" commit -qm "fixture"
  /usr/bin/git -C "$fixture" checkout -qb release-parent
  print -r -- "release parent" >"$fixture/.fixture-release-parent"
  /usr/bin/git -C "$fixture" add .fixture-release-parent
  /usr/bin/git -C "$fixture" commit -qm "release parent"
  /usr/bin/git -C "$fixture" checkout -q main
  print -r -- "main parent" >"$fixture/.fixture-main-parent"
  /usr/bin/git -C "$fixture" add .fixture-main-parent
  /usr/bin/git -C "$fixture" commit -qm "main parent"
  /usr/bin/git -C "$fixture" merge -q --no-ff release-parent -m "merge release"
  /usr/bin/git -C "$fixture" tag -a v0.5.0 -m "Gatebeam 0.5.0"

  print -r -- "$fixture"
}

run_release() {
  local fixture="$1"
  shift
  local tool_dir="$fixture/fake tools"
  local token_file="$fixture/github-token"
  local notary_profile="fixture profile"
  local assignment

  if [[ ! -e "$token_file" ]]; then
    print -r -- "fixture_github_token_0123456789" >"$token_file"
    chmod 600 "$token_file"
  fi
  for assignment in "$@"; do
    if [[ "$assignment" == GATEBEAM_NOTARY_PROFILE=* ]]; then
      notary_profile="${assignment#GATEBEAM_NOTARY_PROFILE=}"
    fi
  done
  print -r -- "$notary_profile" >"$fixture/.diagnostic-redactions"
  chmod 600 "$fixture/.diagnostic-redactions"

  /usr/bin/env -u CURL_HOME \
    GATEBEAM_CODE_SIGN_IDENTITY="Developer ID Application: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_DEVELOPER_TEAM_ID="ABCDE12345" \
    GATEBEAM_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_NOTARY_PROFILE="fixture profile" \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_GITHUB_TOKEN_FILE="$token_file" \
    GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN_FILE="$token_file" \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$tool_dir" \
    GATEBEAM_FAKE_CALL_LOG="$fixture/calls.log" \
    GITHUB_ACTIONS=true \
    GITHUB_REPOSITORY=naifuliang/gatebeam \
    GITHUB_REPOSITORY_ID=987654321 \
    GITHUB_WORKFLOW="Release final-artifact validation" \
    GITHUB_WORKFLOW_REF="naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0" \
    GITHUB_WORKFLOW_SHA="$(/usr/bin/git -C "$fixture" rev-parse HEAD)" \
    GITHUB_RUN_ID=123457 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_JOB=build-candidate \
    GITHUB_REF=refs/tags/v0.5.0 \
    GITHUB_REF_TYPE=tag \
    GITHUB_REF_NAME=v0.5.0 \
    GITHUB_SHA="$(/usr/bin/git -C "$fixture" rev-parse HEAD)" \
    "$@" \
    /bin/zsh -f "$fixture/scripts/prepare_release_candidate.sh"
}

expect_failure() {
  local name="$1"
  local fixture="$2"
  local expected="$3"
  shift 3
  local output="$fixture/test-output.log"

  if run_release "$fixture" "$@" >"$output" 2>&1; then
    fail_test "$name unexpectedly succeeded"
    return
  fi
  if ! /usr/bin/grep -Fq "$expected" "$output"; then
    fail_test "$name did not report its fail-closed reason"
    return
  fi
  pass "$name"
}

test_missing_environment() {
  local fixture
  local output
  fixture="$(new_fixture missing-environment)"
  output="$fixture/test-output.log"

  if env \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$fixture/fake tools" \
    /bin/zsh -f "$fixture/scripts/prepare_release_candidate.sh" >"$output" 2>&1; then
    fail_test "missing environment unexpectedly succeeded"
  elif /usr/bin/grep -Fq "GATEBEAM_CODE_SIGN_IDENTITY is required" "$output"; then
    pass "missing environment"
  else
    fail_test "missing environment reported the wrong error"
  fi
}

test_dirty_worktree() {
  local fixture
  fixture="$(new_fixture dirty-worktree)"
  print -r -- "dirty" >"$fixture/untracked.txt"
  expect_failure \
    "dirty worktree" \
    "$fixture" \
    "formal releases require a clean worktree"
}

test_git_environment_cannot_hide_dirty_state() {
  local fixture
  local alternate
  fixture="$(new_fixture git-environment-bypass)"
  alternate="$(new_fixture git-environment-alternate)"
  print -r -- "dirty" >"$fixture/untracked.txt"
  expect_failure \
    "Git environment cannot hide dirty worktree" \
    "$fixture" \
    "formal releases require a clean worktree" \
    "GIT_DIR=$alternate/.git" \
    "GIT_WORK_TREE=$alternate" \
    "GIT_INDEX_FILE=$alternate/.git/index"
}

test_unsafe_version_rejected() {
  local fixture
  fixture="$(new_fixture unsafe-version)"
  /usr/libexec/PlistBuddy \
    -c 'Set :CFBundleShortVersionString 0.5.0/../../escape' \
    "$fixture/Resources/Info.plist"
  expect_failure \
    "unsafe release version" \
    "$fixture" \
    "CFBundleShortVersionString is not a safe release version"
  [[ ! -e "$TEST_ROOT/escape" ]] ||
    fail_test "unsafe release version escaped the fixture"
}

test_tag_mismatch() {
  local fixture
  fixture="$(new_fixture tag-mismatch)"
  print -r -- "next" >"$fixture/tracked.txt"
  /usr/bin/git -C "$fixture" add tracked.txt
  /usr/bin/git -C "$fixture" commit -qm "move head"
  expect_failure \
    "tag mismatch" \
    "$fixture" \
    "v0.5.0 does not point exactly to HEAD"
}

test_annotated_tag_required() {
  local fixture
  fixture="$(new_fixture lightweight-tag)"
  /usr/bin/git -C "$fixture" tag -d v0.5.0 >/dev/null
  /usr/bin/git -C "$fixture" tag v0.5.0
  expect_failure \
    "lightweight release tag" \
    "$fixture" \
    "v0.5.0 must be an annotated tag"
}

test_two_parent_merge_required() {
  local fixture

  fixture="$(new_fixture non-merge-head)"
  print -r -- "ordinary commit" >"$fixture/ordinary-commit"
  /usr/bin/git -C "$fixture" add ordinary-commit
  /usr/bin/git -C "$fixture" commit -qm "ordinary commit"
  /usr/bin/git -C "$fixture" tag -fa v0.5.0 -m "retag fixture"
  expect_failure \
    "non-merge release HEAD" \
    "$fixture" \
    "formal release HEAD must be a standard merge commit with exactly two parents"

  fixture="$(new_fixture octopus-merge-head)"
  /usr/bin/git -C "$fixture" checkout -qb octopus-one
  print -r -- "one" >"$fixture/octopus-one"
  /usr/bin/git -C "$fixture" add octopus-one
  /usr/bin/git -C "$fixture" commit -qm "octopus one"
  /usr/bin/git -C "$fixture" checkout -q main
  /usr/bin/git -C "$fixture" checkout -qb octopus-two
  print -r -- "two" >"$fixture/octopus-two"
  /usr/bin/git -C "$fixture" add octopus-two
  /usr/bin/git -C "$fixture" commit -qm "octopus two"
  /usr/bin/git -C "$fixture" checkout -q main
  /usr/bin/git -C "$fixture" merge -q --no-ff octopus-one octopus-two \
    -m "octopus release"
  /usr/bin/git -C "$fixture" tag -fa v0.5.0 -m "retag fixture"
  expect_failure \
    "octopus release HEAD" \
    "$fixture" \
    "formal release HEAD must be a standard merge commit with exactly two parents"
}

test_release_metadata_inputs() {
  local fixture

  fixture="$(new_fixture missing-ci-run)"
  expect_failure \
    "missing CI run ID" \
    "$fixture" \
    "GATEBEAM_RELEASE_CI_RUN_ID is required" \
    GATEBEAM_RELEASE_CI_RUN_ID=

  fixture="$(new_fixture unsafe-ci-run)"
  expect_failure \
    "unsafe CI run ID" \
    "$fixture" \
    "must be a positive GitHub Actions run ID" \
    GATEBEAM_RELEASE_CI_RUN_ID="https://github.com/attacker/gatebeam/actions/runs/1"

  fixture="$(new_fixture missing-actions-run)"
  expect_failure \
    "missing current Actions run ID" \
    "$fixture" \
    "GitHub Actions run ID must be a positive GitHub Actions run ID" \
    GITHUB_RUN_ID=

  fixture="$(new_fixture unsafe-actions-attempt)"
  expect_failure \
    "unsafe current Actions run attempt" \
    "$fixture" \
    "GitHub Actions run attempt must be a positive decimal integer without leading zeroes" \
    GITHUB_RUN_ATTEMPT=latest

  fixture="$(new_fixture unsafe-bootstrap-mode)"
  expect_failure \
    "unsafe bootstrap mode" \
    "$fixture" \
    "GATEBEAM_RELEASE_BOOTSTRAP must be 0 or 1" \
    GATEBEAM_RELEASE_BOOTSTRAP=yes

  fixture="$(new_fixture unsafe-notary-profile)"
  expect_failure \
    "unsafe notary profile" \
    "$fixture" \
    "GATEBEAM_NOTARY_PROFILE is invalid" \
    GATEBEAM_NOTARY_PROFILE="--fixture-profile"
}

test_github_evidence_binding() {
  local fixture

  fixture="$(new_fixture github-wrong-repository)"
  expect_failure \
    "GitHub workflow wrong repository" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-repo

  fixture="$(new_fixture github-wrong-head)"
  expect_failure \
    "GitHub workflow wrong HEAD" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-head

  fixture="$(new_fixture github-pull-request-merge-ref)"
  expect_failure \
    "GitHub pull request merge-ref evidence" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=pull-request-merge-ref

  fixture="$(new_fixture current-workflow-wrong-event)"
  expect_failure \
    "current final-artifact workflow wrong event" \
    "$fixture" \
    "formal candidate preparation has the wrong workflow, event, or job" \
    GITHUB_EVENT_NAME=push

  fixture="$(new_fixture github-wrong-conclusion)"
  expect_failure \
    "GitHub workflow wrong conclusion" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-conclusion

  fixture="$(new_fixture github-wrong-workflow)"
  expect_failure \
    "GitHub workflow wrong path and name" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-workflow

  fixture="$(new_fixture github-missing-step)"
  expect_failure \
    "GitHub workflow missing required step" \
    "$fixture" \
    "GitHub ci workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=missing-step

  fixture="$(new_fixture github-immutable-disabled)"
  expect_failure \
    "GitHub immutable release setting disabled" \
    "$fixture" \
    "GitHub immutable releases are not enabled for the fixed repository" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=immutable-disabled

  fixture="$(new_fixture github-mutable-release)"
  expect_failure \
    "GitHub mutable previous release" \
    "$fixture" \
    "formal release history contains an invalid immutable state" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=mutable-release

  fixture="$(new_fixture github-rollback-mismatch)"
  expect_failure \
    "GitHub rollback asset mismatch" \
    "$fixture" \
    "previous immutable release manifest, checksum, build, or rollback asset did not validate" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=rollback-mismatch

  fixture="$(new_fixture github-schema4-history)"
  if run_release \
       "$fixture" \
       GATEBEAM_FAKE_GITHUB_SCENARIO=schema4-valid \
       >"$fixture/test-output.log" 2>&1; then
    pass "schema 4 immutable release and clean-machine attestation history"
  else
    fail_test \
      "schema 4 immutable release and clean-machine attestation history" \
      "$fixture/test-output.log"
  fi

  fixture="$(new_fixture github-schema4-missing-attestation)"
  expect_failure \
    "schema 4 history missing clean-machine attestation" \
    "$fixture" \
    "previous immutable release manifest, checksum, build, or rollback asset did not validate" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=schema4-missing-attestation

  fixture="$(new_fixture github-schema4-tampered-attestation)"
  expect_failure \
    "schema 4 history with stale clean-machine attestation" \
    "$fixture" \
    "previous release clean-machine attestation did not validate" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=schema4-tampered-attestation

  local scenario
  local label
  for scenario label in \
    missing-artifact "missing previous artifact" \
    duplicate-artifact "duplicate previous artifact" \
    extra-artifact "extra previous artifact" \
    mismatched-artifact "mismatched previous artifact" \
    missing-checksum "missing previous checksum" \
    duplicate-checksum "duplicate previous checksum" \
    extra-checksum "extra previous checksum" \
    mismatched-checksum "mismatched previous checksum"; do
    fixture="$(new_fixture "github-$scenario")"
    expect_failure \
      "$label" \
      "$fixture" \
      "previous immutable release manifest, checksum, build, or rollback asset did not validate" \
      "GATEBEAM_FAKE_GITHUB_SCENARIO=$scenario"
  done

  for scenario label in \
    missing-release-asset "missing immutable release asset" \
    duplicate-release-asset "duplicate immutable release asset" \
    extra-release-asset "extra immutable release asset"; do
    fixture="$(new_fixture "github-$scenario")"
    expect_failure \
      "$label" \
      "$fixture" \
      "latest GitHub release is not a complete immutable formal release" \
      "GATEBEAM_FAKE_GITHUB_SCENARIO=$scenario"
  done

  fixture="$(new_fixture github-network-failure)"
  expect_failure \
    "GitHub network failure" \
    "$fixture" \
    "GitHub API request failed for immutable release policy" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=network-failure

  fixture="$(new_fixture github-malformed-json)"
  expect_failure \
    "GitHub malformed JSON" \
    "$fixture" \
    "GitHub immutable releases are not enabled for the fixed repository" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=malformed-json

  fixture="$(new_fixture github-asset-failure)"
  expect_failure \
    "GitHub release asset failure" \
    "$fixture" \
    "GitHub release asset download failed for previous release manifest" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=asset-failure

  fixture="$(new_fixture github-app-asset-failure)"
  expect_failure \
    "GitHub app archive download failure" \
    "$fixture" \
    "GitHub release asset download failed for previous release app archive" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=app-asset-failure

  fixture="$(new_fixture github-dmg-asset-failure)"
  expect_failure \
    "GitHub disk image download failure" \
    "$fixture" \
    "GitHub release asset download failed for previous release disk image" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=dmg-asset-failure

  for scenario label in \
    scripts-decoy "rollback Scripts app decoy" \
    resources-decoy "rollback Resources app decoy" \
    internal-contents-symlink "rollback internal Contents symlink" \
    nested-symlink "rollback nested app symlink" \
    canonical-escape "rollback canonical payload escape" \
    app-hardlink "rollback app hardlink" \
    second-payload-app "rollback payload second app" \
    second-component-package "rollback second component package" \
    wrong-package-identifier "rollback package wrong identifier" \
    wrong-package-version "rollback package wrong version" \
    wrong-install-location "rollback package wrong install location" \
    wrong-payload "rollback package wrong payload"; do
    fixture="$(new_fixture "github-$scenario")"
    expect_failure \
      "$label" \
      "$fixture" \
      "previous release rollback package metadata or payload did not validate" \
      "GATEBEAM_FAKE_GITHUB_SCENARIO=$scenario"
  done

  for scenario label in \
    wrong-internal-bundle-id "rollback app wrong internal bundle identifier" \
    wrong-internal-version "rollback app wrong internal version" \
    wrong-internal-build "rollback app wrong internal build"; do
    fixture="$(new_fixture "github-$scenario")"
    expect_failure \
      "$label" \
      "$fixture" \
      "previous release rollback app contents or signature did not validate" \
      "GATEBEAM_FAKE_GITHUB_SCENARIO=$scenario"
  done

  fixture="$(new_fixture github-wrong-rollback-signature)"
  expect_failure \
    "rollback package wrong signature" \
    "$fixture" \
    "previous release rollback package signature did not validate" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-rollback-signature

  fixture="$(new_fixture bootstrap-existing-release)"
  expect_failure \
    "bootstrap with existing release" \
    "$fixture" \
    "bootstrap requires proof that the repository has no published release" \
    GATEBEAM_RELEASE_BOOTSTRAP=1 \
    GATEBEAM_FAKE_GITHUB_SCENARIO=bootstrap-existing-release
}

test_build_version_contract() {
  local fixture

  fixture="$(new_fixture non-increasing-build)"
  expect_failure \
    "non-increasing application build version" \
    "$fixture" \
    "must be greater than the latest immutable release build" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=stale-build

  fixture="$(new_fixture unsafe-built-build-version)"
  expect_failure \
    "unsafe built application build version" \
    "$fixture" \
    "built application CFBundleVersion must be a positive decimal integer without leading zeroes" \
    GATEBEAM_FAKE_APP_BUILD_VERSION=05
}

test_bootstrap_success() {
  local fixture
  local manifest
  fixture="$(new_fixture bootstrap-success)"
  manifest="$fixture/dist/release-0.5.0/release-manifest.json"

  if ! run_release \
       "$fixture" \
       GATEBEAM_RELEASE_BOOTSTRAP=1 >"$fixture/test-output.log" 2>&1; then
    fail_test "bootstrap without published releases failed"
    return
  fi
  if [[ "$(/usr/bin/plutil -extract previousBuildVersion raw -o - "$manifest")" != "0" ||
        "$(/usr/bin/plutil -extract rollback.available raw -o - "$manifest")" != "false" ||
        "$(/usr/bin/plutil -extract rollback.bootstrap raw -o - "$manifest")" != "true" ]]; then
    fail_test "bootstrap manifest did not record zero history and no rollback"
    return
  fi
  if /usr/bin/plutil -extract rollback.version raw -o - "$manifest" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract rollback.releaseURL raw -o - "$manifest" >/dev/null 2>&1; then
    fail_test "bootstrap manifest invented historical rollback metadata"
    return
  fi
  pass "bootstrap without published releases"
}

test_github_token_not_logged() {
  local fixture
  local token="fixture_secret_github_token"
  fixture="$(new_fixture github-token-privacy)"
  print -r -- "$token" >"$fixture/github-token"
  chmod 600 "$fixture/github-token"

  if ! run_release "$fixture" >"$fixture/test-output.log" 2>&1; then
    fail_test "GitHub token privacy fixture failed"
    return
  fi
  if /usr/bin/grep -R -Fq \
       "$token" \
       "$fixture/test-output.log" \
       "$fixture/calls.log" \
       "$fixture/curl-argv.log" \
       "$fixture/curl-env.log" \
       "$fixture/dist/release-0.5.0"; then
    fail_test "GitHub token entered release logs or output"
    return
  fi
  if ! /usr/bin/python3 -I -E -s -c '
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    invocations = [json.loads(line) for line in stream]
valid = (
    invocations
    and all(
        arguments[1:3] == ["--disable", "--config"]
        and len(arguments) == 4
        for arguments in invocations
    )
)
paths = [pathlib.Path(arguments[3]) for arguments in invocations] if valid else []
raise SystemExit(0 if valid and all(not path.exists() for path in paths) else 1)
' "$fixture/curl-argv.log"; then
    fail_test "curl did not disable defaults first or private config was not cleaned up"
    return
  fi
  pass "GitHub token is absent from curl argv, environment, logs, and release output"
}

test_malicious_curlrc_is_ignored() {
  local mode
  local fixture
  local attack_root
  local home_dir
  local curl_home_dir
  local active_config_dir
  local extra_config
  local trace_path
  local extra_trace_path
  local system_config
  local token="fixture_secret_curlrc_token"
  local -a environment

  for mode in HOME CURL_HOME; do
    fixture="$(new_fixture "malicious-${mode:l}-curlrc")"
    attack_root="${fixture:h}/malicious curl defaults"
    home_dir="$attack_root/home"
    curl_home_dir="$attack_root/curl-home"
    active_config_dir="$home_dir"
    [[ "$mode" == "HOME" ]] || active_config_dir="$curl_home_dir"
    extra_config="$attack_root/extra.conf"
    trace_path="$attack_root/default.trace"
    extra_trace_path="$attack_root/extra.trace"
    system_config="$attack_root/system-curl.conf"
    mkdir -p "$home_dir" "$curl_home_dir"

    {
      print -r -- "trace-ascii = \"$extra_trace_path\""
      print -r -- "verbose"
    } >"$extra_config"
    {
      print -r -- "trace = \"$trace_path\""
      print -r -- "verbose"
      print -r -- "config = \"$extra_config\""
    } >"$active_config_dir/.curlrc"
    {
      print -r -- "silent"
      print -r -- "show-error"
      print -r -- 'url = "file:///dev/null"'
      print -r -- 'output = "/dev/null"'
    } >"$system_config"

    print -r -- "$token" >"$fixture/github-token"
    chmod 600 "$fixture/github-token"
    if [[ "$mode" == "HOME" ]]; then
      environment=("HOME=$home_dir")
      if ! /usr/bin/env -u CURL_HOME \
           HOME="$home_dir" \
           /usr/bin/curl --disable --config "$system_config"; then
        fail_test "system curl did not ignore malicious HOME .curlrc"
        continue
      fi
    else
      environment=("HOME=$home_dir" "CURL_HOME=$curl_home_dir")
      if ! /usr/bin/env \
           HOME="$home_dir" \
           CURL_HOME="$curl_home_dir" \
           /usr/bin/curl --disable --config "$system_config"; then
        fail_test "system curl did not ignore malicious CURL_HOME .curlrc"
        continue
      fi
    fi

    if ! run_release \
         "$fixture" \
         "${environment[@]}" >"$fixture/test-output.log" 2>&1; then
      fail_test "release did not ignore malicious $mode .curlrc"
      continue
    fi
    if [[ -e "$trace_path" || -e "$extra_trace_path" ]]; then
      fail_test "malicious $mode .curlrc created a curl trace"
      continue
    fi
    if /usr/bin/grep -R -Fq \
         "$token" \
         "$fixture/test-output.log" \
         "$fixture/calls.log" \
         "$fixture/curl-argv.log" \
         "$fixture/curl-env.log" \
         "$fixture/dist/release-0.5.0" \
         "$attack_root"; then
      fail_test "malicious $mode .curlrc exposed the GitHub token"
      continue
    fi
    if ! /usr/bin/python3 -I -E -s -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    invocations = [json.loads(line) for line in stream]
raise SystemExit(
    0
    if invocations
    and all(
        len(arguments) == 4
        and arguments[1:3] == ["--disable", "--config"]
        for arguments in invocations
    )
    else 1
)
' "$fixture/curl-argv.log"; then
      fail_test "release curl did not place --disable first for $mode"
      continue
    fi
    pass "malicious $mode .curlrc is ignored before GitHub authorization"
  done
}

test_failure_diagnostics_are_redacted() {
  local fixture
  local source_log
  local rendered_log
  local token="fixture_secret_diagnostic_token"
  local notary_profile="fixture private notary profile"

  fixture="$(new_fixture redacted-failure-diagnostics)"
  source_log="$fixture/test-output.log"
  rendered_log="${fixture:h}/rendered-diagnostic.log"
  print -r -- "$token" >"$fixture/github-token"
  print -r -- "$notary_profile" >"$fixture/.diagnostic-redactions"
  chmod 600 "$fixture/github-token" "$fixture/.diagnostic-redactions"
  {
    print -r -- "safe diagnostic context"
    print -r -- "token=$token"
    print -r -- "Authorization: Bearer $token"
    print -r -- "GATEBEAM_NOTARY_PROFILE=\"$notary_profile\""
    print -r -- "profile=$notary_profile"
  } >"$source_log"

  print_safe_log_tail "$source_log" >"$rendered_log" 2>&1
  if /usr/bin/grep -Fq "$token" "$rendered_log" ||
     /usr/bin/grep -Fq "$notary_profile" "$rendered_log"; then
    fail_test "failure diagnostics exposed a credential" "$source_log"
    return
  fi
  if ! /usr/bin/grep -Fq "safe diagnostic context" "$rendered_log" ||
     ! /usr/bin/grep -Fq "[REDACTED]" "$rendered_log"; then
    fail_test "failure diagnostics omitted safe context or redaction markers" "$source_log"
    return
  fi
  pass "failure diagnostics retain context and redact credentials"
}

expect_secure_diagnostic_rejection() {
  local name="$1"
  local log_path="$2"
  local rendered_log="$3"
  local forbidden
  shift 3

  print_safe_log_tail "$log_path" >"$rendered_log" 2>&1
  if ! /usr/bin/grep -Fq \
       "Diagnostic log rejected by secure reader." \
       "$rendered_log"; then
    fail_test "$name was not rejected" "$log_path"
    return
  fi
  for forbidden in "$@"; do
    [[ -n "$forbidden" ]] || continue
    if /usr/bin/grep -Fq "$forbidden" "$rendered_log"; then
      fail_test "$name exposed rejected content" "$log_path"
      return
    fi
  done
  pass "$name is rejected without exposing content"
}

test_unsafe_failure_diagnostic_files_are_rejected() {
  local fixture
  local outside_root
  local outside_log
  local outside_secret
  local outside_log_marker="ROOT_OUTSIDE_LOG_CONTENT_MUST_NEVER_RENDER"
  local outside_secret_marker="ROOT_OUTSIDE_SECRET_MUST_NEVER_RENDER"
  local inside_log_marker="INSIDE_LOG_MUST_STAY_HIDDEN_WITH_UNSAFE_REDACTION"
  local log_path
  local rendered_log

  fixture="$(new_fixture unsafe-failure-diagnostics)"
  outside_root="$(
    mktemp -d "/private/tmp/Gatebeam Diagnostic Outside.XXXXXX"
  )"
  EXTRA_CLEANUP_PATHS+=("$outside_root")
  outside_log="$outside_root/outside.log"
  outside_secret="$outside_root/outside.secret"
  print -r -- "$outside_log_marker" >"$outside_log"
  print -r -- "$outside_secret_marker" >"$outside_secret"

  log_path="$fixture/symlink.log"
  rendered_log="${fixture:h}/symlink-log-output.log"
  ln -s "$outside_log" "$log_path"
  expect_secure_diagnostic_rejection \
    "symlink diagnostic log" \
    "$log_path" \
    "$rendered_log" \
    "$outside_log_marker"

  log_path="$fixture/hardlink.log"
  rendered_log="${fixture:h}/hardlink-log-output.log"
  ln "$outside_log" "$log_path"
  expect_secure_diagnostic_rejection \
    "hard-linked diagnostic log" \
    "$log_path" \
    "$rendered_log" \
    "$outside_log_marker"

  log_path="$fixture/oversized.log"
  rendered_log="${fixture:h}/oversized-log-output.log"
  /bin/dd if=/dev/zero of="$log_path" bs=1048577 count=1 2>/dev/null
  expect_secure_diagnostic_rejection \
    "oversized diagnostic log" \
    "$log_path" \
    "$rendered_log"

  log_path="$fixture/test-output.log"
  print -r -- "$inside_log_marker" >"$log_path"
  rm -f -- "$fixture/.diagnostic-redactions"
  ln -s "$outside_secret" "$fixture/.diagnostic-redactions"
  rendered_log="${fixture:h}/symlink-secret-output.log"
  expect_secure_diagnostic_rejection \
    "symlink diagnostic redaction file" \
    "$log_path" \
    "$rendered_log" \
    "$inside_log_marker" \
    "$outside_secret_marker"

  rm -f -- "$fixture/.diagnostic-redactions"
  ln "$outside_secret" "$fixture/.diagnostic-redactions"
  rendered_log="${fixture:h}/hardlink-secret-output.log"
  expect_secure_diagnostic_rejection \
    "hard-linked diagnostic redaction file" \
    "$log_path" \
    "$rendered_log" \
    "$inside_log_marker" \
    "$outside_secret_marker"

  rm -f -- "$fixture/.diagnostic-redactions"
  /bin/dd \
    if=/dev/zero \
    of="$fixture/.diagnostic-redactions" \
    bs=4097 \
    count=1 \
    2>/dev/null
  rendered_log="${fixture:h}/oversized-secret-output.log"
  expect_secure_diagnostic_rejection \
    "oversized diagnostic redaction file" \
    "$log_path" \
    "$rendered_log" \
    "$inside_log_marker"
}

test_github_authentication() {
  local fixture

  fixture="$(new_fixture github-token-missing)"
  expect_failure \
    "missing GitHub token" \
    "$fixture" \
    "GATEBEAM_GITHUB_TOKEN_FILE is required for a formal release" \
    GATEBEAM_GITHUB_TOKEN_FILE=

  fixture="$(new_fixture github-token-unsafe)"
  print -r -- "unsafe token" >"$fixture/github-token"
  chmod 600 "$fixture/github-token"
  expect_failure \
    "unsafe GitHub token" \
    "$fixture" \
    "GATEBEAM_GITHUB_TOKEN_FILE contains an invalid token"

  fixture="$(new_fixture github-token-auth-failure)"
  expect_failure \
    "GitHub token authentication failure" \
    "$fixture" \
    "GitHub API request failed for immutable release policy" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=auth-failure
}

test_wrong_identity() {
  local fixture
  local output
  fixture="$(new_fixture wrong-identity)"
  output="$fixture/test-output.log"

  if env \
    GATEBEAM_CODE_SIGN_IDENTITY="Apple Development: Wrong (ABCDE12345)" \
    GATEBEAM_DEVELOPER_TEAM_ID="ABCDE12345" \
    GATEBEAM_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_NOTARY_PROFILE="fixture profile" \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=123457 \
    GATEBEAM_GITHUB_TOKEN_FILE="$fixture/github-token" \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$fixture/fake tools" \
    /bin/zsh -f "$fixture/scripts/prepare_release_candidate.sh" >"$output" 2>&1; then
    fail_test "wrong identity unexpectedly succeeded"
  elif /usr/bin/grep -Fq "Developer ID Application identity has the wrong class" "$output"; then
    pass "wrong identity"
  else
    fail_test "wrong identity reported the wrong error"
  fi
}

test_wrong_signed_identity() {
  local fixture
  fixture="$(new_fixture wrong-signed-identity)"
  expect_failure \
    "wrong signed identity" \
    "$fixture" \
    "application does not satisfy the Developer ID release contract" \
    GATEBEAM_FAKE_WRONG_APP_AUTHORITY=1
}

test_hardened_runtime() {
  local fixture
  fixture="$(new_fixture hardened-runtime)"
  expect_failure \
    "missing hardened runtime" \
    "$fixture" \
    "application does not satisfy the Developer ID release contract" \
    GATEBEAM_FAKE_NO_RUNTIME=1
}

test_app_secure_timestamp() {
  local fixture
  fixture="$(new_fixture app-timestamp)"
  expect_failure \
    "missing app secure timestamp" \
    "$fixture" \
    "application does not satisfy the Developer ID release contract" \
    GATEBEAM_FAKE_NO_TIMESTAMP=1
}

test_forbidden_entitlement() {
  local entitlement
  local fixture
  local fixture_index=0

  for entitlement in \
    com.apple.security.get-task-allow \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.cs.disable-library-validation
  do
    fixture_index=$((fixture_index + 1))
    fixture="$(new_fixture forbidden-entitlement-$fixture_index)"
    expect_failure \
      "forbidden release entitlement: $entitlement" \
      "$fixture" \
      "application does not satisfy the Developer ID release contract" \
      "GATEBEAM_FAKE_FORBIDDEN_ENTITLEMENT=$entitlement"
  done
}

test_app_metadata_consistency() {
  local fixture

  fixture="$(new_fixture wrong-app-version)"
  expect_failure \
    "built app version mismatch" \
    "$fixture" \
    "application version does not match the release contract" \
    GATEBEAM_FAKE_APP_VERSION=9.9.9

  fixture="$(new_fixture wrong-app-bundle)"
  expect_failure \
    "built app bundle mismatch" \
    "$fixture" \
    "application bundle identifier does not match the release contract" \
    GATEBEAM_FAKE_APP_BUNDLE_ID=invalid.bundle
}

test_notary_invalid() {
  local fixture
  fixture="$(new_fixture notary-invalid)"
  expect_failure \
    "notary Invalid" \
    "$fixture" \
    "notary submission for app was not Accepted" \
    GATEBEAM_FAKE_NOTARY_STATUS=Invalid
  [[ ! -e "$fixture/dist/release-0.5.0" ]] ||
    fail_test "notary Invalid published release output"
}

test_notary_log_failure() {
  local fixture
  fixture="$(new_fixture notary-log-failure)"
  expect_failure \
    "notary log retrieval failure" \
    "$fixture" \
    "could not retrieve notary log for app" \
    GATEBEAM_FAKE_FAIL_NOTARY_LOG=app
}

test_notary_warning_log() {
  local fixture
  fixture="$(new_fixture notary-warning)"
  expect_failure \
    "notary warning log" \
    "$fixture" \
    "notary log contains warning or error issues for app" \
    GATEBEAM_FAKE_NOTARY_ISSUE=warning
  /usr/bin/grep -Fq "notarytool log" "$fixture/calls.log" ||
    fail_test "notary warning test did not retrieve the submission log"
}

test_notary_profile_leak() {
  local fixture
  fixture="$(new_fixture notary-profile-leak)"
  expect_failure \
    "notary credential profile leak" \
    "$fixture" \
    "release metadata leaked the notary credential profile" \
    GATEBEAM_FAKE_LEAK_PROFILE=1
  [[ ! -e "$fixture/dist/release-0.5.0" ]] ||
    fail_test "credential profile leak published release output"
}

test_staple_failure() {
  local fixture
  fixture="$(new_fixture staple-failure)"
  expect_failure \
    "staple failure" \
    "$fixture" \
    "could not staple the application" \
    GATEBEAM_FAKE_FAIL_STAPLE=app
}

test_stapler_state_validation() {
  local fixture
  local fake_xcrun
  local unstapled_pkg

  fixture="$(new_fixture stapler-wrong-path)"
  fake_xcrun="$fixture/fake tools/xcrun"
  if env \
       GATEBEAM_FAKE_CALL_LOG="$fixture/calls.log" \
       "$fake_xcrun" stapler validate "$fixture/dist/missing.pkg" \
       >"$fixture/test-output.log" 2>&1; then
    fail_test "fake stapler accepted a missing validation path"
  else
    pass "fake stapler rejects a missing validation path"
  fi

  fixture="$(new_fixture stapler-unstapled)"
  unstapled_pkg="$fixture/unstapled.pkg"
  print -r -- "not stapled" >"$unstapled_pkg"
  if env \
       GATEBEAM_FAKE_CALL_LOG="$fixture/calls.log" \
       "$fixture/fake tools/xcrun" stapler validate "$unstapled_pkg" \
       >"$fixture/test-output.log" 2>&1; then
    fail_test "fake stapler accepted an unstapled artifact"
  else
    pass "fake stapler rejects an unstapled artifact"
  fi

  fixture="$(new_fixture stapler-missing-state)"
  expect_failure \
    "release rejects missing staple state" \
    "$fixture" \
    "application notarization ticket validation failed" \
    GATEBEAM_FAKE_STAPLE_WITHOUT_STATE=app
}

test_gatekeeper_failure() {
  local fixture
  fixture="$(new_fixture gatekeeper-failure)"
  expect_failure \
    "Gatekeeper failure" \
    "$fixture" \
    "Gatekeeper rejected the application" \
    GATEBEAM_FAKE_FAIL_GATEKEEPER=execute
}

test_installer_identity() {
  local fixture
  fixture="$(new_fixture installer-identity)"
  expect_failure \
    "wrong installer identity" \
    "$fixture" \
    "installer package is not signed with Developer ID Installer" \
    GATEBEAM_FAKE_WRONG_INSTALLER_AUTHORITY=1
}

test_installer_timestamp() {
  local fixture
  fixture="$(new_fixture installer-timestamp)"
  expect_failure \
    "missing installer secure timestamp" \
    "$fixture" \
    "installer package is missing a secure timestamp" \
    GATEBEAM_FAKE_NO_PKG_TIMESTAMP=1
}

test_installer_gatekeeper_failure() {
  local fixture
  fixture="$(new_fixture installer-gatekeeper)"
  expect_failure \
    "installer Gatekeeper failure" \
    "$fixture" \
    "Gatekeeper rejected the installer package" \
    GATEBEAM_FAKE_FAIL_GATEKEEPER=install
}

test_dmg_verification_failure() {
  local fixture
  fixture="$(new_fixture dmg-verification)"
  expect_failure \
    "DMG verification failure" \
    "$fixture" \
    "disk image verification failed" \
    GATEBEAM_FAKE_FAIL_HDIUTIL=1
}

test_dmg_signing_contract() {
  local fixture
  fixture="$(new_fixture dmg-certificate-oid)"
  expect_failure \
    "DMG Developer ID certificate OID" \
    "$fixture" \
    "disk image is not signed with the required Developer ID Application chain" \
    GATEBEAM_FAKE_WRONG_DMG_OID=1

  fixture="$(new_fixture dmg-forbidden-entitlement)"
  expect_failure \
    "DMG forbidden entitlement" \
    "$fixture" \
    "disk image contains a forbidden signing entitlement" \
    GATEBEAM_FAKE_DMG_FORBIDDEN_ENTITLEMENT=com.apple.security.get-task-allow
}

test_atomic_rollback() {
  local fixture
  local release_dir
  fixture="$(new_fixture atomic-rollback)"
  release_dir="$fixture/dist/release-0.5.0"
  mkdir -p "$release_dir"
  print -r -- "keep-old-release" >"$release_dir/sentinel"

  expect_failure \
    "existing release is never overwritten" \
    "$fixture" \
    "release destination already exists and will not be overwritten"
  [[ "$(<"$release_dir/sentinel")" == "keep-old-release" ]] &&
    [[ "$(find "$release_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')" == "1" ]] ||
    fail_test "existing release failure modified the previous release"
}

test_failure_before_publish() {
  local fixture
  fixture="$(new_fixture failure-before-publish)"
  expect_failure \
    "failure before publish" \
    "$fixture" \
    "injected release failure at before-publish" \
    GATEBEAM_RELEASE_TEST_FAILURE_POINT=before-publish
  [[ ! -e "$fixture/dist/release-0.5.0" ]] ||
    fail_test "failure before publish exposed a partial release"
}

test_productsign_atomic_failure() {
  local fixture
  fixture="$(new_fixture productsign-partial-failure)"
  expect_failure \
    "partial productsign failure" \
    "$fixture" \
    "could not sign the installer package" \
    GATEBEAM_FAKE_PRODUCTSIGN_PARTIAL_FAILURE=1
  [[ ! -e "$fixture/dist/release-0.5.0" ]] ||
    fail_test "partial productsign failure exposed release output"
}

test_packagers_cannot_rebuild_app() {
  local fixture

  fixture="$(new_fixture pkg-rebuilds-app)"
  expect_failure \
    "PKG cannot rebuild notarized app" \
    "$fixture" \
    "PKG packaging modified the notarized application" \
    GATEBEAM_FAKE_PKG_REBUILDS_APP=1

  fixture="$(new_fixture dmg-rebuilds-app)"
  expect_failure \
    "DMG cannot rebuild notarized app" \
    "$fixture" \
    "DMG packaging modified the notarized application" \
    GATEBEAM_FAKE_DMG_REBUILDS_APP=1
}

test_release_output_symlinks() {
  local fixture
  local outside

  fixture="$(new_fixture dist-symlink)"
  outside="$TEST_ROOT/dist-symlink-target"
  mkdir -p "$outside"
  ln -s "$outside" "$fixture/dist"
  expect_failure \
    "dist symlink" \
    "$fixture" \
    "dist is not a safe release directory"
  [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]] ||
    fail_test "dist symlink test wrote outside its fixture"

  fixture="$(new_fixture release-symlink)"
  mkdir -p "$fixture/dist"
  ln -s "$outside" "$fixture/dist/release-0.5.0"
  expect_failure \
    "release destination symlink" \
    "$fixture" \
    "release destination already exists and will not be overwritten"
}

test_unmarked_fixture_rejected() {
  local fixture
  fixture="$(new_fixture unmarked-fixture)"
  rm -f \
    "$fixture/.gatebeam-release-test-fixture" \
    "$fixture/fake tools/.gatebeam-release-test-fixture"
  /usr/bin/git -C "$fixture" add -u
  /usr/bin/git -C "$fixture" commit -qm "remove fixture markers"
  /usr/bin/git -C "$fixture" tag -f v0.5.0
  expect_failure \
    "unmarked fixture override" \
    "$fixture" \
    "restricted to marked /private/tmp fixtures"
}

test_success_and_order() {
  local fixture
  local release_dir
  local manifest
  local actual_order
  local expected_order
  local manifest_app_submission_key="notarization"".app"".submissionId"
  local manifest_app_status_key="notarization"".app"".status"
  local manifest_pkg_status_key="notarization"".pkg"".status"
  local manifest_dmg_status_key="notarization"".dmg"".status"
  fixture="$(new_fixture success-order)"
  release_dir="$fixture/dist/release-0.5.0"

  if ! run_release "$fixture" >"$fixture/test-output.log" 2>&1; then
    fail_test "successful release fixture failed"
    return
  fi

  local artifact_path
  for artifact_path in \
    "$release_dir/Gatebeam-0.5.0.zip" \
    "$release_dir/Gatebeam-0.5.0.pkg" \
    "$release_dir/Gatebeam-0.5.0.dmg" \
    "$release_dir/SHA256SUMS" \
    "$release_dir/release-manifest.json" \
    "$release_dir/candidate-envelope.json" \
    "$release_dir/validation/previous-Gatebeam.pkg" \
    "$release_dir/validation/previous-release-manifest.json" \
    "$release_dir/validation/previous-SHA256SUMS"
  do
    [[ -s "$artifact_path" ]] || {
      fail_test "successful release omitted ${artifact_path:t}"
      return
    }
  done

  (
    cd "$release_dir"
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
  ) || {
    fail_test "successful release checksums did not verify"
    return
  }

  /usr/bin/grep -Fq \
    "fixture-stapled-app" \
    <(/usr/bin/unzip -p \
      "$release_dir/Gatebeam-0.5.0.zip" \
      "Gatebeam.app/Contents/_CodeSignature/fixture-stapled-ticket") ||
    {
      fail_test "final app archive predates stapling"
      return
    }
  /usr/bin/grep -Fq "fixture-stapled-pkg" \
    "$release_dir/Gatebeam-0.5.0.pkg" ||
    {
      fail_test "final PKG predates stapling"
      return
    }
  /usr/bin/grep -Fq "fixture-stapled-dmg" \
    "$release_dir/Gatebeam-0.5.0.dmg" ||
    {
      fail_test "final DMG predates stapling"
      return
    }

  manifest="$release_dir/release-manifest.json"
  [[ "$(/usr/bin/plutil -extract version raw -o - "$manifest")" == "0.5.0" &&
      "$(/usr/bin/plutil -extract buildVersion raw -o - "$manifest")" == "5" &&
      "$(/usr/bin/plutil -extract previousBuildVersion raw -o - "$manifest")" == "4" &&
      "$(/usr/bin/plutil -extract bundleIdentifier raw -o - "$manifest")" == "io.github.naifuliang.gatebeam" &&
      "$(/usr/bin/plutil -extract teamIdentifier raw -o - "$manifest")" == "ABCDE12345" &&
      "$(/usr/bin/plutil -extract "$manifest_app_submission_key" raw -o - "$manifest")" == "11111111-1111-1111-1111-111111111111" &&
      "$(/usr/bin/plutil -extract "$manifest_app_status_key" raw -o - "$manifest")" == "Accepted" &&
      "$(/usr/bin/plutil -extract "$manifest_pkg_status_key" raw -o - "$manifest")" == "Accepted" &&
      "$(/usr/bin/plutil -extract "$manifest_dmg_status_key" raw -o - "$manifest")" == "Accepted" &&
      "$(/usr/bin/plutil -extract testing.evidenceURL raw -o - "$manifest")" == "https://github.com/naifuliang/gatebeam/actions/runs/123456" &&
      "$(/usr/bin/plutil -extract testing.cleanMachineEvidenceURL raw -o - "$manifest")" == "https://github.com/naifuliang/gatebeam/actions/runs/123457" &&
      "$(/usr/bin/plutil -extract rollback.version raw -o - "$manifest")" == "0.4.0" &&
      "$(/usr/bin/plutil -extract rollback.releaseURL raw -o - "$manifest")" == "https://github.com/naifuliang/gatebeam/releases/tag/v0.4.0" &&
      "$(/usr/bin/plutil -extract rollback.assetName raw -o - "$manifest")" == "Gatebeam-0.4.0.pkg" &&
      "$(/usr/bin/plutil -extract platform.name raw -o - "$manifest")" == "macOS" &&
      "$(/usr/bin/plutil -extract platform.supportedMacOSVersionRange raw -o - "$manifest")" == "13.0 or later" &&
      "$(/usr/bin/plutil -extract testing.status raw -o - "$manifest")" == "Passed" &&
      "$(/usr/bin/plutil -extract testing.cleanMachineStatus raw -o - "$manifest")" == "RequiresAttestation" &&
      "$(/usr/bin/plutil -extract testing.finalArtifactValidation.runId raw -o - "$manifest")" == "123457" &&
      "$(/usr/bin/plutil -extract testing.finalArtifactValidation.runAttempt raw -o - "$manifest")" == "1" &&
      -n "$(/usr/bin/plutil -extract toolchain.xcodeVersion raw -o - "$manifest")" &&
      -n "$(/usr/bin/plutil -extract toolchain.swiftVersion raw -o - "$manifest")" ]] || {
    fail_test "successful release manifest is incomplete"
    return
  }
  [[ "$(/usr/bin/plutil -extract platform.supportedArchitectures.0 raw -o - "$manifest")" == "arm64" ]] || {
    fail_test "successful release manifest omitted built application architectures"
    return
  }
  local manifest_parent_one
  local manifest_parent_two
  manifest_parent_one="$(
    /usr/bin/plutil -extract source.mergeParents.0 raw -o - "$manifest"
  )"
  manifest_parent_two="$(
    /usr/bin/plutil -extract source.mergeParents.1 raw -o - "$manifest"
  )"
  [[ "$manifest_parent_one" =~ '^[0-9a-f]{40,64}$' &&
      "$manifest_parent_two" =~ '^[0-9a-f]{40,64}$' &&
      "$manifest_parent_one" != "$manifest_parent_two" ]] || {
    fail_test "successful release manifest omitted merge parents"
    return
  }
  [[ "$(/usr/bin/plutil -extract testing.gates.3 raw -o - "$manifest")" == "test_integration_tsan" &&
      "$(/usr/bin/plutil -extract testing.gates.8 raw -o - "$manifest")" == "test_release_pipeline" ]] || {
    fail_test "successful release manifest omitted required gate evidence"
    return
  }
  if [[ -e "$release_dir/notary-logs" ]] ||
     /usr/bin/grep -R -Fq "fixture profile" "$release_dir"; then
    fail_test "successful release leaked the notary profile"
    return
  fi
  local index
  local artifact_name
  local expected_sha
  local manifest_sha
  local expected_byte_count
  local manifest_byte_count
  local certificate_name
  local certificate_sha256
  for index in 0 1 2; do
    artifact_name="$(
      /usr/bin/plutil -extract "artifacts.$index.name" raw -o - "$manifest"
    )"
    manifest_sha="$(
      /usr/bin/plutil -extract "artifacts.$index.sha256" raw -o - "$manifest"
    )"
    manifest_byte_count="$(
      /usr/bin/plutil -extract "artifacts.$index.byteCount" raw -o - "$manifest"
    )"
    certificate_name="$(
      /usr/bin/plutil -extract "artifacts.$index.signingCertificateName" raw -o - "$manifest"
    )"
    certificate_sha256="$(
      /usr/bin/plutil -extract "artifacts.$index.signingCertificateSHA256" raw -o - "$manifest"
    )"
    expected_sha="$(
      /usr/bin/shasum -a 256 "$release_dir/$artifact_name" |
        /usr/bin/awk '{print $1}'
    )"
    expected_byte_count="$(/usr/bin/stat -f '%z' "$release_dir/$artifact_name")"
    [[ "$manifest_sha" == "$expected_sha" &&
        "$manifest_byte_count" == "$expected_byte_count" &&
        "$certificate_name" == "Developer ID "* &&
        "$certificate_sha256" =~ '^[0-9A-Fa-f]{64}$' ]] || {
      fail_test "manifest artifact audit metadata does not describe final stapled bytes"
      return
    }
  done

  actual_order="$(
    /usr/bin/grep -E \
      '^(build_app|notarytool submit (app|pkg|dmg)|stapler (staple|validate) (app|pkg|dmg)|package_(pkg|dmg)|productsign|codesign dmg)$' \
      "$fixture/calls.log"
  )"
  expected_order=$'build_app\nnotarytool submit app\nstapler staple app\nstapler validate app\npackage_pkg\nstapler validate app\nproductsign\nnotarytool submit pkg\nstapler staple pkg\nstapler validate pkg\npackage_dmg\nstapler validate app\ncodesign dmg\nnotarytool submit dmg\nstapler staple dmg\nstapler validate dmg'
  [[ "$actual_order" == "$expected_order" ]] || {
    print -u2 -- "Expected call order:"
    print -u2 -- "$expected_order"
    print -u2 -- "Actual call order:"
    print -u2 -- "$actual_order"
    fail_test "successful release call order is wrong"
    return
  }

  pass "successful release and call order"
}

test_path_with_spaces() {
  local fixture
  fixture="$(new_fixture path-with-spaces)"
  if run_release \
       "$fixture" \
       GATEBEAM_FAKE_NOTARY_EMPTY_ISSUES=1 >"$fixture/test-output.log" 2>&1 &&
     [[ -s "$fixture/dist/release-0.5.0/Gatebeam-0.5.0.dmg" ]]; then
    pass "paths with spaces"
  else
    fail_test "paths with spaces"
  fi
}

test_signal_cleanup_and_exit_status() {
  local cleanup_mode
  local signal_name
  local expected_status
  local ready_file
  local child_log
  local child_root
  local child_pid
  local child_status
  local attempt
  local -a environment

  for cleanup_mode in success failure; do
    for signal_name in HUP INT TERM; do
      case "$signal_name" in
        HUP) expected_status=129 ;;
        INT) expected_status=130 ;;
        TERM) expected_status=143 ;;
      esac
      ready_file="$TEST_ROOT/signal-$cleanup_mode-$signal_name.ready"
      child_log="$TEST_ROOT/signal-$cleanup_mode-$signal_name.log"
      environment=(
        GATEBEAM_RELEASE_TEST_SIGNAL_HARNESS=1
        "GATEBEAM_RELEASE_TEST_SIGNAL_READY_FILE=$ready_file"
      )
      if [[ "$cleanup_mode" == "failure" ]]; then
        environment+=(GATEBEAM_RELEASE_TEST_CLEANUP_FAILURE=1)
      fi
      /usr/bin/env \
        "${environment[@]}" \
        /bin/zsh -f "$ROOT_DIR/scripts/test_release_pipeline.sh" \
        >"$child_log" 2>&1 &
      child_pid=$!

      for attempt in {1..100}; do
        [[ -s "$ready_file" ]] && break
        /bin/sleep 0.05
      done
      if [[ ! -s "$ready_file" ]]; then
        /bin/kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        fail_test \
          "$cleanup_mode $signal_name signal harness did not become ready" \
          "$child_log"
        continue
      fi
      child_root="$(<"$ready_file")"
      /bin/kill -s "$signal_name" "$child_pid"
      if wait "$child_pid"; then
        child_status=0
      else
        child_status=$?
      fi
      if [[ "$child_status" != "$expected_status" ]]; then
        fail_test \
          "$cleanup_mode $signal_name trap exited with $child_status instead of $expected_status" \
          "$child_log"
        rm -rf -- "$child_root"
        continue
      fi

      if [[ "$cleanup_mode" == "success" ]]; then
        if [[ -e "$child_root" || -L "$child_root" ]]; then
          fail_test \
            "$signal_name trap did not clean its fixture root" \
            "$child_log"
          rm -rf -- "$child_root"
          continue
        fi
        if /usr/bin/grep -Fq "fixture cleanup failed" "$child_log"; then
          fail_test \
            "$signal_name trap falsely reported cleanup failure" \
            "$child_log"
          continue
        fi
        pass "$signal_name trap cleans fixtures and preserves signal exit status"
      else
        if [[ ! -d "$child_root" ||
              -L "$child_root" ||
              ! -f "$child_root/.signal-harness-live" ]]; then
          fail_test \
            "$signal_name cleanup-failure fixture state was not preserved" \
            "$child_log"
          rm -rf -- "$child_root"
          continue
        fi
        if ! /usr/bin/grep -Fq \
             "error: fixture cleanup failed while handling $signal_name (status 70)" \
             "$child_log"; then
          fail_test \
            "$signal_name cleanup failure was not explicitly reported" \
            "$child_log"
          rm -rf -- "$child_root"
          continue
        fi
        rm -rf -- "$child_root"
        pass "$signal_name cleanup failure is reported without changing signal status"
      fi
    done
  done
}

test_override_restriction() {
  local output="$TEST_ROOT/override-restriction.log"
  if env \
    GATEBEAM_CODE_SIGN_IDENTITY="Developer ID Application: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_DEVELOPER_TEAM_ID="ABCDE12345" \
    GATEBEAM_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_NOTARY_PROFILE="fixture profile" \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=123457 \
    GATEBEAM_GITHUB_TOKEN_FILE="$TEST_ROOT/override-token" \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$TEST_ROOT/not-used" \
    /bin/zsh -f "$ROOT_DIR/scripts/prepare_release_candidate.sh" >"$output" 2>&1; then
    fail_test "non-fixture command override unexpectedly succeeded"
  elif /usr/bin/grep -Fq "restricted to marked /private/tmp fixtures" "$output"; then
    pass "command override restriction"
  else
    fail_test "command override restriction reported the wrong error"
  fi
}

test_legacy_notary_tool_is_absent() {
  local forbidden_tool="al""tool"
  if /usr/bin/grep -Fq \
    "$forbidden_tool" \
    "$ROOT_DIR/scripts/prepare_release_candidate.sh" \
    "$ROOT_DIR/scripts/release_candidate_internal.sh" \
    "$ROOT_DIR/scripts/verify_release.sh"; then
    fail_test "legacy notary tool is present"
  else
    pass "legacy notary tool is absent"
  fi
}

test_manifest_validation_is_portable() {
  if /usr/bin/grep -Fq \
    "/usr/bin/plutil -p" \
    "$ROOT_DIR/scripts/release_formal.sh" \
    "$ROOT_DIR/scripts/release_candidate_internal.sh" \
    "$ROOT_DIR/scripts/publish_validated_release.sh" \
    "$ROOT_DIR/scripts/release_artifact_contract.py"; then
    fail_test "release manifest validation still depends on host plutil JSON behavior"
  else
    pass "release manifest validation is independent of host plutil JSON behavior"
  fi
}

test_missing_environment
test_dirty_worktree
test_git_environment_cannot_hide_dirty_state
test_unsafe_version_rejected
test_tag_mismatch
test_annotated_tag_required
test_two_parent_merge_required
test_release_metadata_inputs
test_github_evidence_binding
test_build_version_contract
test_bootstrap_success
test_github_authentication
test_github_token_not_logged
test_malicious_curlrc_is_ignored
test_failure_diagnostics_are_redacted
test_unsafe_failure_diagnostic_files_are_rejected
test_wrong_identity
test_wrong_signed_identity
test_hardened_runtime
test_app_secure_timestamp
test_forbidden_entitlement
test_app_metadata_consistency
test_notary_invalid
test_notary_log_failure
test_notary_warning_log
test_notary_profile_leak
test_staple_failure
test_stapler_state_validation
test_gatekeeper_failure
test_installer_identity
test_installer_timestamp
test_installer_gatekeeper_failure
test_dmg_verification_failure
test_dmg_signing_contract
test_atomic_rollback
test_failure_before_publish
test_productsign_atomic_failure
test_packagers_cannot_rebuild_app
test_release_output_symlinks
test_unmarked_fixture_rejected
test_success_and_order
test_path_with_spaces
test_signal_cleanup_and_exit_status
test_override_restriction
test_legacy_notary_tool_is_absent
test_manifest_validation_is_portable

print -r -- "Release pipeline tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
