#!/bin/zsh -f
set -euo pipefail
unsetopt BG_NICE
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV ZDOTDIR CDPATH PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PYTHONNOUSERSITE=1

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "/private/tmp/gatebeam-formal-publish-tests.XXXXXX")"
PASSED=0
FAILED=0

cleanup() {
  /bin/chmod -R u+rwx -- "$TEST_ROOT" 2>/dev/null || true
  /bin/rm -rf -- "$TEST_ROOT"
}
trap 'cleanup' EXIT HUP INT TERM

pass() {
  PASSED=$((PASSED + 1))
  print -r -- "PASS: $1"
}

fail_test() {
  FAILED=$((FAILED + 1))
  print -u2 -- "FAIL: $1"
  [[ $# -lt 2 ]] || /usr/bin/sed -n '1,120p' "$2" >&2
}

new_fixture() {
  local name="$1"
  local fixture="$TEST_ROOT/$name/Gatebeam Fixture"
  local tool_dir="$fixture/fake tools"
  /bin/mkdir -p \
    "$fixture/scripts" \
    "$fixture/Resources" \
    "$fixture/Tests/ReleasePipelineTests" \
    "$tool_dir" \
    "$fixture/fake-api"
  /bin/cp "$ROOT_DIR/scripts/release_formal.sh" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/publish_validated_release.sh" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/release_artifact_contract.py" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/release_history_contract.py" "$fixture/scripts/"
  /bin/cp \
    "$ROOT_DIR/Tests/ReleasePipelineTests/fake_final_artifact_api.py" \
    "$tool_dir/curl"
  print -r -- "Gatebeam release test fixture v1" \
    >"$fixture/.gatebeam-release-test-fixture"
  /bin/cp \
    "$fixture/.gatebeam-release-test-fixture" \
    "$tool_dir/.gatebeam-release-test-fixture"
  /bin/chmod 755 \
    "$fixture/scripts/release_formal.sh" \
    "$fixture/scripts/publish_validated_release.sh" \
    "$fixture/scripts/release_artifact_contract.py" \
    "$fixture/scripts/release_history_contract.py" \
    "$tool_dir/curl"

  /usr/libexec/PlistBuddy -c "Clear dict" "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string io.github.naifuliang.gatebeam" \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleShortVersionString string 0.5.0" \
    "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleVersion string 5" \
    "$fixture/Resources/Info.plist" >/dev/null
  print -r -- $'dist/\nfake-api/\ncalls.log\ntest-output.log\ngithub-token\n' \
    >"$fixture/.gitignore"

  /usr/bin/git -C "$fixture" init -q -b main
  /usr/bin/git -C "$fixture" config user.name "Gatebeam Publish Tests"
  /usr/bin/git -C "$fixture" config user.email "publish-tests@invalid"
  /usr/bin/git -C "$fixture" add .
  /usr/bin/git -C "$fixture" commit -qm "fixture"
  /usr/bin/git -C "$fixture" checkout -qb release-parent
  print -r -- "release parent" >"$fixture/.release-parent"
  /usr/bin/git -C "$fixture" add .release-parent
  /usr/bin/git -C "$fixture" commit -qm "release parent"
  /usr/bin/git -C "$fixture" checkout -q main
  print -r -- "main parent" >"$fixture/.main-parent"
  /usr/bin/git -C "$fixture" add .main-parent
  /usr/bin/git -C "$fixture" commit -qm "main parent"
  /usr/bin/git -C "$fixture" merge -q --no-ff release-parent -m "merge release"
  /usr/bin/git -C "$fixture" tag -a v0.5.0 -m "Gatebeam 0.5.0"

  create_artifacts "$fixture"
  print -r -- "fixture_github_token_0123456789" >"$fixture/github-token"
  /bin/chmod 600 "$fixture/github-token"
  print -r -- "$fixture"
}

create_artifacts() {
  local fixture="$1"
  local commit
  local candidate
  local candidate_archive
  local candidate_digest
  local attestation
  local attestation_archive
  local candidate_name
  local attestation_name
  commit="$(/usr/bin/git -C "$fixture" rev-parse HEAD)"
  candidate="$fixture/fake-api/candidate"
  candidate_archive="$fixture/fake-api/candidate.zip"
  attestation="$fixture/fake-api/clean-machine-attestation.json"
  attestation_archive="$fixture/fake-api/attestation.zip"
  candidate_name="gatebeam-final-candidate-v0.5.0-${commit}-run123457-attempt1"
  attestation_name="gatebeam-clean-machine-attestation-v0.5.0-${commit}-run123457-attempt1"
  /bin/mkdir "$candidate"

  /usr/bin/python3 -I -E -s - \
    "$candidate" "$commit" "$candidate_name" "$attestation_name" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
candidate_name = sys.argv[3]
attestation_name = sys.argv[4]
artifacts = {
    "Gatebeam-0.5.0.zip": ("app-archive", b"final app archive bytes\n"),
    "Gatebeam-0.5.0.pkg": ("installer-package", b"final installer package bytes\n"),
    "Gatebeam-0.5.0.dmg": ("disk-image", b"final disk image bytes\n"),
}
records = []
checksums = []
for name, (kind, payload) in artifacts.items():
    (root / name).write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    records.append(
        {
            "name": name,
            "type": kind,
            "byteCount": len(payload),
            "sha256": digest,
        }
    )
    checksums.append(f"{digest}  {name}")
(root / "SHA256SUMS").write_text("\n".join(checksums) + "\n", encoding="ascii")
manifest = {
    "schemaVersion": 4,
    "product": "Gatebeam",
    "commit": commit,
    "tag": "v0.5.0",
    "version": "0.5.0",
    "buildVersion": "5",
    "previousBuildVersion": "0",
    "bundleIdentifier": "io.github.naifuliang.gatebeam",
    "teamIdentifier": "ABCDE12345",
    "artifacts": records,
    "testing": {
        "finalArtifactValidation": {
            "required": True,
            "repository": "naifuliang/gatebeam",
            "repositoryId": 987654321,
            "workflowName": "Release final-artifact validation",
            "workflowPath": ".github/workflows/release-validation.yml",
            "workflowRef": "naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0",
            "workflowSHA": commit,
            "runId": 123457,
            "runAttempt": 1,
            "event": "workflow_dispatch",
            "buildJob": "build-candidate",
            "validationJob": "clean-machine",
            "commit": commit,
            "tag": "v0.5.0",
            "candidateArtifactName": candidate_name,
            "attestationArtifactName": attestation_name,
        }
    },
    "rollback": {
        "available": False,
        "bootstrap": True,
        "procedure": "docs/RELEASING.md#rollback-and-revocation",
    },
}
(root / "release-manifest.json").write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
for path in root.iterdir():
    os.chmod(path, 0o600)
PY

  /usr/bin/python3 -I -E -s "$fixture/scripts/release_artifact_contract.py" \
    create-envelope \
    --root "$candidate" \
    --repository-id 987654321 \
    --workflow-ref "naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0" \
    --workflow-sha "$commit" \
    --run-id 123457 \
    --run-attempt 1 \
    --commit "$commit" \
    --tag v0.5.0 \
    --artifact-name "$candidate_name" \
    --attestation-name "$attestation_name"

  /usr/bin/python3 -I -E -s - "$candidate" "$candidate_archive" <<'PY'
import pathlib
import sys
import zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_STORED) as bundle:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            bundle.write(path, path.relative_to(root).as_posix())
PY
  candidate_digest="$(/usr/bin/shasum -a 256 "$candidate_archive" | /usr/bin/awk '{print $1}')"

  /usr/bin/python3 -I -E -s "$fixture/scripts/release_artifact_contract.py" \
    create-attestation \
    --root "$candidate" \
    --output "$attestation" \
    --artifact-id 201 \
    --artifact-digest "$candidate_digest" \
    --repository-id 987654321 \
    --workflow-ref "naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0" \
    --workflow-sha "$commit" \
    --run-id 123457 \
    --run-attempt 1 \
    --commit "$commit" \
    --tag v0.5.0 \
    --artifact-name "$candidate_name" \
    --attestation-name "$attestation_name"
  (
    cd "$fixture/fake-api"
    /usr/bin/zip -q -0 "$attestation_archive" clean-machine-attestation.json
  )
  /usr/bin/python3 -I -E -s - \
    "$fixture/fake-api/metadata.json" "$commit" <<'PY'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(
        {
            "commit": sys.argv[2],
            "tag": "v0.5.0",
            "ciRunId": "123456",
            "cleanRunId": "123457",
        },
        stream,
        sort_keys=True,
    )
PY
}

run_publish() {
  local fixture="$1"
  shift
  /usr/bin/env -u CURL_HOME \
    GATEBEAM_RELEASE_CI_RUN_ID=123456 \
    GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID=123457 \
    GATEBEAM_GITHUB_TOKEN_FILE="$fixture/github-token" \
    GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN_FILE="$fixture/github-token" \
    GATEBEAM_RELEASE_TEST_MODE=1 \
    GATEBEAM_RELEASE_TEST_TOOL_DIR="$fixture/fake tools" \
    GATEBEAM_FAKE_CALL_LOG="$fixture/calls.log" \
    "$@" \
    /bin/zsh -f "$fixture/scripts/release_formal.sh"
}

expect_failure() {
  local label="$1"
  local scenario="$2"
  local expected="$3"
  local fixture
  local output
  fixture="$(new_fixture "$label")"
  output="$fixture/test-output.log"
  if run_publish \
       "$fixture" \
       "GATEBEAM_FAKE_FINAL_SCENARIO=$scenario" >"$output" 2>&1; then
    fail_test "$label unexpectedly succeeded" "$output"
  elif ! /usr/bin/grep -Fq "$expected" "$output"; then
    fail_test "$label reported the wrong fail-closed reason" "$output"
  elif [[ -e "$fixture/dist/release-0.5.0" ||
          -L "$fixture/dist/release-0.5.0" ]]; then
    fail_test "$label exposed a partial formal release" "$output"
  elif [[ -f "$fixture/fake-api/remote-release-state.json" ]] &&
       ! /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    state = json.load(stream)
raise SystemExit(
    0 if (
        state.get("release") is None
        and state.get("assets") == []
    ) else 1
)
' "$fixture/fake-api/remote-release-state.json"; then
    fail_test "$label left a remote draft, asset, or published release" "$output"
  else
    pass "$label"
  fi
}

expect_success() {
  local label="$1"
  local scenario="$2"
  local fixture
  local output
  fixture="$(new_fixture "$label")"
  output="$fixture/test-output.log"
  if run_publish \
       "$fixture" \
       "GATEBEAM_FAKE_FINAL_SCENARIO=$scenario" >"$output" 2>&1 &&
     [[ -d "$fixture/dist/release-0.5.0" ]] &&
     /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    state = json.load(stream)
release = state.get("release")
raise SystemExit(
    0 if (
        isinstance(release, dict)
        and release.get("draft") is False
        and release.get("immutable") is True
        and len(state.get("assets", [])) == 7
    ) else 1
)
' "$fixture/fake-api/remote-release-state.json"; then
    pass "$label"
  else
    fail_test "$label failed to reconcile a successful mutation" "$output"
  fi
}

fixture="$(new_fixture successful-publish)"
if run_publish "$fixture" >"$fixture/test-output.log" 2>&1; then
  release_dir="$fixture/dist/release-0.5.0"
  candidate_dir="$fixture/fake-api/candidate"
  good=true
  for name in \
    Gatebeam-0.5.0.zip \
    Gatebeam-0.5.0.pkg \
    Gatebeam-0.5.0.dmg \
    SHA256SUMS \
    release-manifest.json \
    candidate-envelope.json
  do
    [[ -f "$release_dir/$name" && ! -L "$release_dir/$name" &&
        "$(/usr/bin/shasum -a 256 "$release_dir/$name" | /usr/bin/awk '{print $1}')" ==
        "$(/usr/bin/shasum -a 256 "$candidate_dir/$name" | /usr/bin/awk '{print $1}')" ]] ||
      good=false
  done
  [[ -f "$release_dir/clean-machine-attestation.json" &&
      "$(/usr/bin/shasum -a 256 "$release_dir/clean-machine-attestation.json" | /usr/bin/awk '{print $1}')" ==
      "$(/usr/bin/shasum -a 256 "$fixture/fake-api/clean-machine-attestation.json" | /usr/bin/awk '{print $1}')" ]] ||
    good=false
  /usr/bin/python3 -I -E -s - \
    "$fixture/fake-api/remote-release-state.json" "$release_dir" <<'PY' ||
import hashlib
import json
import pathlib
import sys
with open(sys.argv[1], "rb") as stream:
    state = json.load(stream)
root = pathlib.Path(sys.argv[2])
if (
    state["release"]["draft"] is not False
    or state["release"]["immutable"] is not True
    or len(state["assets"]) != 7
):
    raise SystemExit(1)
for asset in state["assets"]:
    payload = (root / asset["name"]).read_bytes()
    if (
        asset["size"] != len(payload)
        or asset["digest"] != f"sha256:{hashlib.sha256(payload).hexdigest()}"
    ):
        raise SystemExit(2)
PY
    good=false
  if "$good"; then
    pass "publisher preserves exact attested bytes"
  else
    fail_test "publisher changed or omitted attested bytes" "$fixture/test-output.log"
  fi
else
  fail_test "valid formal publish failed" "$fixture/test-output.log"
fi

expect_failure \
  "wrong final repository" \
  wrong-final-repository \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "wrong final repository ID" \
  wrong-final-repository-id \
  "GitHub final-artifact metadata did not satisfy the release contract"
expect_failure \
  "wrong final event" \
  wrong-final-event \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "wrong final HEAD" \
  wrong-final-head \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "wrong final tag" \
  wrong-final-tag \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "missing final job" \
  missing-final-job \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "missing final step" \
  missing-final-step \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "completed final run cannot be replayed by a manual publisher" \
  final-run-completed \
  "GitHub final-artifact workflow evidence did not satisfy the release contract"
expect_failure \
  "cross-attempt artifact replay" \
  replayed-attempt \
  "GitHub final-artifact metadata did not satisfy the release contract"
expect_failure \
  "cross-run artifact replay" \
  cross-run-artifact \
  "GitHub final-artifact metadata did not satisfy the release contract"
expect_failure \
  "expired candidate artifact" \
  expired-artifact \
  "GitHub final-artifact metadata did not satisfy the release contract"
expect_failure \
  "duplicate candidate artifact" \
  duplicate-candidate-artifact \
  "GitHub final-artifact metadata did not satisfy the release contract"
expect_failure \
  "protected candidate digest mismatch" \
  wrong-protected-digest \
  "GitHub artifact digest did not match protected metadata"
expect_failure \
  "candidate transport path traversal" \
  candidate-path-traversal \
  "final candidate transport archive is unsafe"
expect_failure \
  "candidate bytes changed after validation" \
  tampered-candidate \
  "clean-machine attestation does not authorize these exact candidate bytes"
expect_failure \
  "attestation bytes changed after validation" \
  tampered-attestation \
  "clean-machine attestation does not authorize these exact candidate bytes"
expect_failure \
  "bootstrap replay after published release" \
  bootstrap-existing-release \
  "immutable release manifest selection failed"
expect_failure \
  "remote publication lock race" \
  remote-lock-race \
  "immutable release history, version, build, or rollback binding is invalid"
expect_failure \
  "remote draft DELETE response loss still cleans locally" \
  remote-lock-race-delete-loss \
  "immutable release history, version, build, or rollback binding is invalid"
expect_failure \
  "remote publication lock changed before publish" \
  remote-lock-late \
  "immutable release history, version, build, or rollback binding is invalid"
expect_failure \
  "remote tag moved" \
  remote-tag-moved \
  "remote annotated release tag does not peel exactly to HEAD"
expect_failure \
  "remote uploaded digest mismatch" \
  remote-upload-digest \
  "remote asset name exists but does not match frozen bytes"
expect_failure \
  "published release remained mutable" \
  remote-publish-mutable \
  "GitHub publication result is neither the exact draft nor immutable release"

expect_success "draft POST response loss recovery" post-response-loss
expect_success "asset upload response loss recovery" upload-response-loss
expect_success "publish PATCH response loss recovery" patch-response-loss
expect_success "response loss recovery across release page two" post-loss-page2
expect_success "draft POST applied before HTTP 500 recovery" post-http-500-applied
expect_success "asset upload applied before HTTP 500 recovery" upload-http-500-applied
expect_success "publish PATCH applied before HTTP 500 recovery" patch-http-500-applied
for mutation in post upload patch; do
  case "$mutation" in
    post)
      mutation_label="draft POST"
      request_label="formal release draft"
      unresolved="GitHub draft creation result could not be reconciled safely"
      ;;
    upload)
      mutation_label="asset upload"
      request_label="Gatebeam-0.5.0.zip"
      unresolved="GitHub asset upload result could not be reconciled safely: Gatebeam-0.5.0.zip"
      ;;
    patch)
      mutation_label="publish PATCH"
      request_label="immutable formal release publication"
      unresolved="GitHub publication response loss could not be reconciled safely"
      ;;
  esac
  for code in 401 403 404 500; do
    case "$code" in
      401|403)
        expected="GitHub authorization was rejected for $request_label (HTTP $code)"
        ;;
      404)
        expected="GitHub resource was not found for $request_label (HTTP 404)"
        ;;
      500)
        expected="$unresolved"
        ;;
    esac
    expect_failure \
      "$mutation_label HTTP $code without server-side execution" \
      "$mutation-http-$code" \
      "$expected"
  done
done

concurrent_one="$(new_fixture concurrent-publisher-one)"
concurrent_two="$TEST_ROOT/concurrent-publisher-two/Gatebeam Fixture"
/bin/mkdir -p "${concurrent_two:h}"
/usr/bin/ditto "$concurrent_one" "$concurrent_two"
shared_remote="$TEST_ROOT/shared-remote"
/bin/mkdir "$shared_remote"
print -r -- "Gatebeam shared remote fixture v1" \
  >"$shared_remote/.gatebeam-shared-remote-fixture"
(
  if run_publish \
      "$concurrent_one" \
      "GATEBEAM_FAKE_REMOTE_STATE_DIR=$shared_remote" \
      >"$concurrent_one/test-output.log" 2>&1; then
    print -r -- 0 >"$concurrent_one/result"
  else
    print -r -- $? >"$concurrent_one/result"
  fi
) &
concurrent_pid_one=$!
(
  if run_publish \
      "$concurrent_two" \
      "GATEBEAM_FAKE_REMOTE_STATE_DIR=$shared_remote" \
      >"$concurrent_two/test-output.log" 2>&1; then
    print -r -- 0 >"$concurrent_two/result"
  else
    print -r -- $? >"$concurrent_two/result"
  fi
) &
concurrent_pid_two=$!
wait "$concurrent_pid_one" || true
wait "$concurrent_pid_two" || true
concurrent_successes=0
[[ "$(<"$concurrent_one/result")" != "0" ]] || concurrent_successes=$((concurrent_successes + 1))
[[ "$(<"$concurrent_two/result")" != "0" ]] || concurrent_successes=$((concurrent_successes + 1))
if [[ "$concurrent_successes" == "1" ]] &&
   /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    state = json.load(stream)
release = state.get("release")
raise SystemExit(
    0 if (
        isinstance(release, dict)
        and release.get("draft") is False
        and release.get("immutable") is True
        and len(state.get("assets", [])) == 7
    ) else 1
)
' "$shared_remote/remote-release-state.json"; then
  pass "two concurrent publishers produce one immutable winner"
else
  fail_test \
    "concurrent publishers did not serialize at the remote ownership boundary" \
    "$concurrent_one/test-output.log"
  /usr/bin/sed -n '1,120p' "$concurrent_two/test-output.log" >&2
fi

fixture="$(new_fixture atomic-failure)"
if run_publish \
     "$fixture" \
     GATEBEAM_RELEASE_TEST_FAILURE_POINT=before-publish \
     >"$fixture/test-output.log" 2>&1; then
  fail_test "injected pre-publish failure unexpectedly succeeded" "$fixture/test-output.log"
elif [[ -e "$fixture/dist/release-0.5.0" ||
        -L "$fixture/dist/release-0.5.0" ]]; then
  fail_test "pre-publish failure exposed a partial release" "$fixture/test-output.log"
else
  pass "pre-publish failure remains atomic"
fi

fixture="$(new_fixture token-privacy)"
token="$(<"$fixture/github-token")"
if run_publish "$fixture" >"$fixture/test-output.log" 2>&1 &&
   ! /usr/bin/grep -R -Fq \
     "$token" \
     "$fixture/test-output.log" \
     "$fixture/calls.log" \
     "$fixture/dist/release-0.5.0"; then
  pass "publisher token is absent from logs and release bytes"
else
  fail_test "publisher leaked its GitHub token" "$fixture/test-output.log"
fi

history_fixture="$TEST_ROOT/history-contract"
/bin/mkdir -p "$history_fixture/manifests"
if /usr/bin/python3 -I -E -s - \
    "$ROOT_DIR/scripts/release_history_contract.py" "$history_fixture" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

contract = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
repository = "naifuliang/gatebeam"

def asset(asset_id, name, payload, version):
    return {
        "id": asset_id,
        "name": name,
        "size": len(payload),
        "digest": f"sha256:{hashlib.sha256(payload).hexdigest()}",
        "state": "uploaded",
        "url": f"https://api.github.com/repos/{repository}/releases/assets/{asset_id}",
        "browser_download_url": (
            f"https://github.com/{repository}/releases/download/v{version}/{name}"
        ),
    }

def release(index, version, build, commit):
    manifest = {
        "version": version,
        "tag": f"v{version}",
        "buildVersion": str(build),
        "commit": commit,
    }
    payload = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    manifest_id = 1000 + index * 10
    (root / "manifests" / f"{manifest_id}.json").write_bytes(payload)
    names = [
        f"Gatebeam-{version}.zip",
        f"Gatebeam-{version}.pkg",
        f"Gatebeam-{version}.dmg",
        "SHA256SUMS",
        "release-manifest.json",
    ]
    assets = [
        asset(manifest_id if name == "release-manifest.json" else manifest_id + offset + 1, name, payload if name == "release-manifest.json" else name.encode(), version)
        for offset, name in enumerate(names)
    ]
    return {
        "id": 5000 + index,
        "tag_name": f"v{version}",
        "draft": False,
        "prerelease": "-" in version.split("+", 1)[0],
        "immutable": True,
        "html_url": f"https://github.com/{repository}/releases/tag/v{version}",
        "assets": assets,
    }

history = [
    release(1, "1.0.2", 2, "1" * 40),
    release(2, "1.0.10", 10, "2" * 40),
]
package = next(
    asset for asset in history[-1]["assets"]
    if asset["name"] == "Gatebeam-1.0.10.pkg"
)
current = {
    "version": "1.0.11",
    "tag": "v1.0.11",
    "buildVersion": "11",
    "commit": "3" * 40,
    "previousBuildVersion": "10",
    "rollback": {
        "available": True,
        "version": "1.0.10",
        "sourceCommit": "2" * 40,
        "assetSHA256": package["digest"][7:],
        "releaseURL": history[-1]["html_url"],
    },
}

def run_case(name, releases, candidate, succeeds):
    release_path = root / f"{name}-releases.json"
    current_path = root / f"{name}-current.json"
    output_path = root / f"{name}-output.json"
    release_path.write_text(json.dumps(releases), encoding="utf-8")
    current_path.write_text(json.dumps(candidate), encoding="utf-8")
    result = subprocess.run(
        [
            sys.executable, "-I", "-E", "-s", str(contract), "analyze",
            "--releases", str(release_path),
            "--manifests", str(root / "manifests"),
            "--current-manifest", str(current_path),
            "--expected-draft-id", "0",
            "--output", str(output_path),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if (result.returncode == 0) is not succeeds:
        raise SystemExit(f"history case failed: {name}")
    if not succeeds and output_path.exists():
        raise SystemExit(f"failed history case emitted output: {name}")

run_case("numeric-semver", history, current, True)
semver_versions = [
    "1.0.0-alpha",
    "1.0.0-alpha.1",
    "1.0.0-alpha.2+build.01",
    "1.0.0-alpha.10+build.99",
    "1.0.0-alpha.beta",
    "1.0.0-beta",
    "1.0.0-beta.2",
    "1.0.0-beta.11",
    "1.0.0-rc.1",
    "1.0.0",
]
semver_history = [
    release(20 + index, version, 20 + index, f"{index + 1:x}" * 40)
    for index, version in enumerate(semver_versions)
]
semver_package = next(
    asset for asset in semver_history[-1]["assets"]
    if asset["name"] == "Gatebeam-1.0.0.pkg"
)
semver_current = {
    "version": "1.0.1+publisher.7",
    "tag": "v1.0.1+publisher.7",
    "buildVersion": "40",
    "commit": "d" * 40,
    "previousBuildVersion": str(20 + len(semver_versions) - 1),
    "rollback": {
        "available": True,
        "version": "1.0.0",
        "sourceCommit": "a" * 40,
        "assetSHA256": semver_package["digest"][7:],
        "releaseURL": semver_history[-1]["html_url"],
    },
}
run_case("semver-spec-precedence", semver_history, semver_current, True)

prerelease_history = [
    release(50, "2.0.0-alpha.2+first", 50, "b" * 40),
    release(51, "2.0.0-alpha.10+second", 51, "c" * 40),
]
prerelease_package = next(
    asset for asset in prerelease_history[-1]["assets"]
    if asset["name"] == "Gatebeam-2.0.0-alpha.10+second.pkg"
)
prerelease_current = {
    "version": "2.0.0",
    "tag": "v2.0.0",
    "buildVersion": "52",
    "commit": "d" * 40,
    "previousBuildVersion": "51",
    "rollback": {
        "available": True,
        "version": "2.0.0-alpha.10+second",
        "sourceCommit": "c" * 40,
        "assetSHA256": prerelease_package["digest"][7:],
        "releaseURL": prerelease_history[-1]["html_url"],
    },
}
run_case("alpha-2-before-alpha-10", prerelease_history, prerelease_current, True)
duplicate_precedence = [
    release(52, "2.0.0-alpha.2+one", 52, "e" * 40),
    release(53, "2.0.0-alpha.2+two", 53, "f" * 40),
]
run_case("build-metadata-ignored-for-precedence", duplicate_precedence, prerelease_current, False)
wrong_prerelease_flag = [release(54, "2.0.0-alpha.1", 54, "1" * 40)]
wrong_prerelease_flag[0]["prerelease"] = False
run_case("prerelease-flag-mismatch", wrong_prerelease_flag, prerelease_current, False)
for index, malformed_version in enumerate(
    ("01.0.0", "1.01.0", "1.0.01", "1.0.0-alpha..1", "1.0.0-alpha_1")
):
    malformed = {
        "id": 9100 + index,
        "tag_name": f"v{malformed_version}",
        "draft": False,
        "prerelease": True,
        "immutable": True,
        "assets": [],
    }
    run_case(f"invalid-semver-{index}", [malformed], prerelease_current, False)
forked = [
    release(3, "2.0.0", 20, "5" * 40),
    release(4, "2.0.1", 10, "6" * 40),
]
run_case("forked-build-order", forked, current, False)
PY
then
  pass "complete SemVer 2.0 precedence and immutable-history ordering"
else
  fail_test "complete SemVer 2.0 and immutable-history ordering"
fi

print -r -- "Formal publisher tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
