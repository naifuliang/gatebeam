#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_SOURCE="$ROOT_DIR/Tests/ReleasePipelineTests"
TEST_ROOT="$(mktemp -d "/private/tmp/Gatebeam Release Pipeline Tests.XXXXXX")"
PASSED=0
FAILED=0

cleanup() {
  if [[ "${GATEBEAM_KEEP_RELEASE_TEST_FIXTURES:-0}" == "1" ]]; then
    print -u2 -- "Kept release test fixtures: $TEST_ROOT"
    return
  fi
  rm -rf -- "$TEST_ROOT"
}
trap 'cleanup' EXIT HUP INT TERM

pass() {
  PASSED=$((PASSED + 1))
  print -r -- "PASS: $1"
}

fail_test() {
  FAILED=$((FAILED + 1))
  print -u2 -- "FAIL: $1"
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
  cp "$ROOT_DIR/scripts/release_formal.sh" "$fixture/scripts/release_formal.sh"
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

  print -r -- $'dist/\nbuild/\ncalls.log\ntest-output.log' >"$fixture/.gitignore"
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

  env \
    GATEBEAM_CODE_SIGN_IDENTITY="Developer ID Application: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_DEVELOPER_TEAM_ID="ABCDE12345" \
    GATEBEAM_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_NOTARY_PROFILE="fixture profile" \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=123457 \
    GATEBEAM_GITHUB_TOKEN=fixture_github_token_0123456789 \
    GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN=fixture_github_token_0123456789 \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$tool_dir" \
    GATEBEAM_FAKE_CALL_LOG="$fixture/calls.log" \
    "$@" \
    /bin/zsh -f "$fixture/scripts/release_formal.sh"
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
    /bin/zsh -f "$fixture/scripts/release_formal.sh" >"$output" 2>&1; then
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

  fixture="$(new_fixture missing-clean-machine-run)"
  expect_failure \
    "missing clean-machine run ID" \
    "$fixture" \
    "GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID is required" \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=

  fixture="$(new_fixture unsafe-clean-machine-run)"
  expect_failure \
    "unsafe clean-machine run ID" \
    "$fixture" \
    "must be a positive GitHub Actions run ID" \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=latest

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

  fixture="$(new_fixture github-clean-wrong-event)"
  expect_failure \
    "GitHub clean-machine wrong event" \
    "$fixture" \
    "GitHub clean-machine workflow evidence did not satisfy the release contract" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=wrong-clean-event

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
    "latest GitHub release is not a complete immutable formal release" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=mutable-release

  fixture="$(new_fixture github-rollback-mismatch)"
  expect_failure \
    "GitHub rollback asset mismatch" \
    "$fixture" \
    "previous immutable release manifest, checksum, build, or rollback asset did not validate" \
    GATEBEAM_FAKE_GITHUB_SCENARIO=rollback-mismatch

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

  if ! run_release \
       "$fixture" \
       "GATEBEAM_GITHUB_TOKEN=$token" \
       "GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN=$token" >"$fixture/test-output.log" 2>&1; then
    fail_test "GitHub token privacy fixture failed"
    return
  fi
  if /usr/bin/grep -R -Fq \
       "$token" \
       "$fixture/test-output.log" \
       "$fixture/calls.log" \
       "$fixture/dist/release-0.5.0"; then
    fail_test "GitHub token entered release logs or output"
    return
  fi
  pass "GitHub token is absent from logs and release output"
}

test_github_authentication() {
  local fixture

  fixture="$(new_fixture github-token-missing)"
  expect_failure \
    "missing GitHub token" \
    "$fixture" \
    "GATEBEAM_GITHUB_TOKEN is required for a formal release" \
    GATEBEAM_GITHUB_TOKEN=

  fixture="$(new_fixture github-token-unsafe)"
  expect_failure \
    "unsafe GitHub token" \
    "$fixture" \
    "GATEBEAM_GITHUB_TOKEN contains unsafe characters" \
    "GATEBEAM_GITHUB_TOKEN=unsafe token"

  fixture="$(new_fixture github-token-auth-failure)"
  expect_failure \
    "GitHub token authentication failure" \
    "$fixture" \
    "GitHub API request failed for immutable release policy" \
    GATEBEAM_GITHUB_TOKEN=fixture_wrong_github_token_0123456789
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
    GATEBEAM_GITHUB_TOKEN=fixture_github_token_0123456789 \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$fixture/fake tools" \
    /bin/zsh -f "$fixture/scripts/release_formal.sh" >"$output" 2>&1; then
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
    "$release_dir/notary-logs/app.json" \
    "$release_dir/notary-logs/pkg.json" \
    "$release_dir/notary-logs/dmg.json"
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
      "$(/usr/bin/plutil -extract testing.cleanMachineStatus raw -o - "$manifest")" == "Passed" &&
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
  if /usr/bin/grep -Fq "fixture profile" "$manifest" "$release_dir"/notary-logs/*.json; then
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

test_override_restriction() {
  local output="$TEST_ROOT/override-restriction.log"
  if env \
    GATEBEAM_CODE_SIGN_IDENTITY="Developer ID Application: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_DEVELOPER_TEAM_ID="ABCDE12345" \
    GATEBEAM_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Gatebeam Tests (ABCDE12345)" \
    GATEBEAM_NOTARY_PROFILE="fixture profile" \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=123457 \
    GATEBEAM_GITHUB_TOKEN=fixture_github_token_0123456789 \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$TEST_ROOT/not-used" \
    /bin/zsh -f "$ROOT_DIR/scripts/release_formal.sh" >"$output" 2>&1; then
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
    "$ROOT_DIR/scripts/release_formal.sh" \
    "$ROOT_DIR/scripts/verify_release.sh"; then
    fail_test "legacy notary tool is present"
  else
    pass "legacy notary tool is absent"
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
test_override_restriction
test_legacy_notary_tool_is_absent

print -r -- "Release pipeline tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
