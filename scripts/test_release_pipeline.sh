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
  print -r -- "Gatebeam release test fixture v1" \
    >"$fixture/.gatebeam-release-test-fixture"
  cp \
    "$fixture/.gatebeam-release-test-fixture" \
    "$tool_dir/.gatebeam-release-test-fixture"
  chmod +x "$fixture/scripts/"*.sh "$tool_dir/release-tool"

  for tool in codesign ditto hdiutil pkgutil productsign spctl xcrun; do
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
    -c 'Add :CFBundleExecutable string Gatebeam' \
    "$fixture/Resources/Info.plist" >/dev/null

  print -r -- $'dist/\nbuild/\ncalls.log\ntest-output.log' >"$fixture/.gitignore"
  /usr/bin/git -C "$fixture" init -q
  /usr/bin/git -C "$fixture" config user.name "Gatebeam Release Tests"
  /usr/bin/git -C "$fixture" config user.email "release-tests@invalid"
  /usr/bin/git -C "$fixture" add .
  /usr/bin/git -C "$fixture" commit -qm "fixture"
  /usr/bin/git -C "$fixture" tag v0.5.0

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
      "$(/usr/bin/plutil -extract bundleIdentifier raw -o - "$manifest")" == "io.github.naifuliang.gatebeam" &&
      "$(/usr/bin/plutil -extract teamIdentifier raw -o - "$manifest")" == "ABCDE12345" &&
      "$(/usr/bin/plutil -extract "$manifest_app_submission_key" raw -o - "$manifest")" == "11111111-1111-1111-1111-111111111111" ]] || {
    fail_test "successful release manifest is incomplete"
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
  for index in 0 1 2; do
    artifact_name="$(
      /usr/bin/plutil -extract "artifacts.$index.name" raw -o - "$manifest"
    )"
    manifest_sha="$(
      /usr/bin/plutil -extract "artifacts.$index.sha256" raw -o - "$manifest"
    )"
    expected_sha="$(
      /usr/bin/shasum -a 256 "$release_dir/$artifact_name" |
        /usr/bin/awk '{print $1}'
    )"
    [[ "$manifest_sha" == "$expected_sha" ]] || {
      fail_test "manifest checksum does not describe final stapled bytes"
      return
    }
  done

  actual_order="$(
    /usr/bin/grep -E \
      '^(build_app|notarytool submit (app|pkg|dmg)|stapler staple (app|pkg|dmg)|package_(pkg|dmg)|productsign|codesign dmg)$' \
      "$fixture/calls.log"
  )"
  expected_order=$'build_app\nnotarytool submit app\nstapler staple app\npackage_pkg\nproductsign\nnotarytool submit pkg\nstapler staple pkg\npackage_dmg\ncodesign dmg\nnotarytool submit dmg\nstapler staple dmg'
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
