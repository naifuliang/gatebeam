#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
TEST_TOOL_DIR="${GATEBEAM_RELEASE_TEST_TOOL_DIR:-}"
TEST_MODE="${GATEBEAM_RELEASE_TEST_MODE:-0}"
TEST_FAILURE_POINT="${GATEBEAM_RELEASE_TEST_FAILURE_POINT:-}"
FIXTURE_MARKER=".gatebeam-release-test-fixture"
EXPECTED_BUNDLE_ID="io.github.naifuliang.gatebeam"
GITHUB_REPOSITORY="naifuliang/gatebeam"
GITHUB_API_ROOT="https://api.github.com/repos/$GITHUB_REPOSITORY"
GITHUB_WEB_ROOT="https://github.com/$GITHUB_REPOSITORY"
CI_WORKFLOW_NAME="CI"
CI_WORKFLOW_PATH=".github/workflows/ci.yml"
CI_WORKFLOW_EVENT="push"
CLEAN_WORKFLOW_NAME="Release clean-machine validation"
CLEAN_WORKFLOW_PATH=".github/workflows/release-validation.yml"
CLEAN_WORKFLOW_EVENT="workflow_dispatch"
TEMP_ROOT=""
PUBLISH_STAGING=""
PUBLISH_LOCK=""
GITHUB_CURL_CONFIG=""
PREVIOUS_BUILD_VERSION=""
PREVIOUS_RELEASE_VERSION=""
PREVIOUS_RELEASE_TAG=""
PREVIOUS_RELEASE_COMMIT=""
PREVIOUS_RELEASE_URL=""
ROLLBACK_ASSET_NAME=""
ROLLBACK_ASSET_SHA256=""
ROLLBACK_AVAILABLE=0

fail() {
  print -u2 -- "error: $*"
  exit 1
}

cleanup() {
  [[ -z "$PUBLISH_STAGING" ]] || rm -rf -- "$PUBLISH_STAGING"
  [[ -z "$PUBLISH_LOCK" ]] || rmdir -- "$PUBLISH_LOCK" 2>/dev/null || true
  [[ -z "$TEMP_ROOT" ]] || rm -rf -- "$TEMP_ROOT"
}

handle_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
}

tool_path() {
  local name="$1"
  local system_path="$2"
  local candidate

  if [[ -z "$TEST_TOOL_DIR" ]]; then
    print -r -- "$system_path"
    return
  fi

  validate_fixture_mode
  [[ -d "$TEST_TOOL_DIR" && ! -L "$TEST_TOOL_DIR" ]] ||
    fail "release tool override directory is invalid"
  [[ -f "$TEST_TOOL_DIR/$FIXTURE_MARKER" &&
      ! -L "$TEST_TOOL_DIR/$FIXTURE_MARKER" ]] ||
    fail "release tool override directory is not a marked fixture"

  candidate="$TEST_TOOL_DIR/$name"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    fail "release test tool is missing or unsafe: $name"
  print -r -- "$candidate"
}

validate_fixture_mode() {
  local canonical_tool_dir
  local fake_call_log="${GATEBEAM_FAKE_CALL_LOG:-}"
  local fake_call_log_parent

  [[ "$TEST_MODE" == "1" && -n "$TEST_TOOL_DIR" ]] ||
    fail "release tool overrides require explicit fixture mode"
  [[ "$ROOT_DIR" == /private/tmp/* &&
      -f "$ROOT_DIR/$FIXTURE_MARKER" &&
      ! -L "$ROOT_DIR/$FIXTURE_MARKER" &&
      "$(<"$ROOT_DIR/$FIXTURE_MARKER")" == "Gatebeam release test fixture v1" ]] ||
    fail "release tool overrides are restricted to marked /private/tmp fixtures"
  canonical_tool_dir="$(cd -P "$TEST_TOOL_DIR" 2>/dev/null && pwd -P)" ||
    fail "release tool override directory is invalid"
  [[ "$canonical_tool_dir" == "$TEST_TOOL_DIR" &&
      "$canonical_tool_dir" == /private/tmp/* ]] ||
    fail "release tool overrides are restricted to canonical /private/tmp fixtures"

  if [[ -n "$fake_call_log" ]]; then
    fake_call_log_parent="$(
      cd -P "${fake_call_log:h}" 2>/dev/null && pwd -P
    )" || fail "release fixture call log has an invalid parent"
    [[ "$fake_call_log" == "$fake_call_log_parent/${fake_call_log:t}" &&
        "$fake_call_log_parent" == /private/tmp/* &&
        -f "$fake_call_log_parent/$FIXTURE_MARKER" &&
        ! -L "$fake_call_log_parent/$FIXTURE_MARKER" &&
        ! -L "$fake_call_log" ]] ||
      fail "release fixture call log must remain inside a marked /private/tmp fixture"
  fi
}

sanitize_environment() {
  unset \
    BASH_ENV ENV ZDOTDIR CDPATH \
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    LD_PRELOAD LD_LIBRARY_PATH \
    PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
    RUBYOPT RUBYLIB PERL5OPT PERL5LIB \
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_REPLACE_REF_BASE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
    GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_EXTERNAL_DIFF \
    http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
    CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR \
    GITHUB_TOKEN GH_TOKEN \
    GATEBEAM_PREVIOUS_PUBLIC_BUILD_VERSION \
    GATEBEAM_RELEASE_TEST_EVIDENCE_URL \
    GATEBEAM_RELEASE_CLEAN_MACHINE_EVIDENCE_URL \
    GATEBEAM_RELEASE_ROLLBACK_VERSION \
    GATEBEAM_RELEASE_ROLLBACK_URL \
    GATEBEAM_PACKAGE_TMPDIR GATEBEAM_TEST_TMPDIR \
    GATEBEAM_TEST_PKG_FAILURE_POINT GATEBEAM_TEST_PKG_SIGNAL_POINT

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1
  export PYTHONNOUSERSITE=1
  export NO_PROXY="*"
  export no_proxy="*"
}

git_safe() {
  /usr/bin/git \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.attributesfile=/dev/null \
    "$@"
}

assert_safe_dist() {
  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] ||
    fail "dist is not a safe release directory"
}

require_environment() {
  local variable_name="$1"
  [[ -n "${(P)variable_name:-}" ]] ||
    fail "$variable_name is required for a formal release"
}

validate_positive_decimal() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ '^[1-9][0-9]*$' ]] ||
    fail "$label must be a positive decimal integer without leading zeroes"
}

decimal_is_greater() {
  local current="$1"
  local previous="$2"

  if (( ${#current} != ${#previous} )); then
    (( ${#current} > ${#previous} ))
    return
  fi
  [[ "$current" > "$previous" ]]
}

validate_certificate_name() {
  local value="$1"
  local certificate_class="$2"
  local team_id="$3"

  [[ ${#value} -le 200 &&
      "$value" =~ '^[A-Za-z0-9][A-Za-z0-9 .,&()_+:-]*$' &&
      "$value" == "$certificate_class: "* &&
      "$value" == *"($team_id)" ]]
}

validate_identity_input() {
  local value="$1"
  local certificate_class="$2"
  local team_id="$3"

  if [[ "$value" =~ '^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$' ]]; then
    return
  fi
  if ! validate_certificate_name "$value" "$certificate_class" "$team_id"; then
    fail "$certificate_class identity has the wrong class or Team ID"
  fi
}

validate_run_id() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ '^[1-9][0-9]*$' ]] ||
    fail "$label must be a positive GitHub Actions run ID"
}

prepare_github_auth() {
  local token="$GATEBEAM_GITHUB_TOKEN"

  [[ ${#token} -le 255 && "$token" =~ '^[A-Za-z0-9_.=-]+$' ]] ||
    fail "GATEBEAM_GITHUB_TOKEN contains unsafe characters"
  GITHUB_CURL_CONFIG="$TEMP_ROOT/github-auth.conf"
  print -r -- "header = \"Authorization: Bearer $token\"" \
    >"$GITHUB_CURL_CONFIG"
  chmod 0600 "$GITHUB_CURL_CONFIG"
  unset GATEBEAM_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN
}

github_api_json() {
  local url="$1"
  local output_path="$2"
  local label="$3"
  local -a curl_arguments

  [[ "$url" == "$GITHUB_API_ROOT/"* ]] ||
    fail "internal GitHub API endpoint escaped the fixed repository"
  curl_arguments=(
    --disable
    --silent
    --show-error
    --fail
    --noproxy '*'
    --proto '=https'
    --max-redirs 0
    --connect-timeout 10
    --max-time 30
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2026-03-10'
  )
  curl_arguments+=(--config "$GITHUB_CURL_CONFIG")
  curl_arguments+=(--output "$output_path" "$url")

  if ! "$CURL" "${curl_arguments[@]}"; then
    rm -f -- "$output_path"
    fail "GitHub API request failed for $label"
  fi
  [[ -f "$output_path" && ! -L "$output_path" && -s "$output_path" ]] ||
    fail "GitHub API returned no safe JSON for $label"
  (( $(/usr/bin/stat -f '%z' "$output_path") <= 10485760 )) ||
    fail "GitHub API response was too large for $label"
}

github_asset_download() {
  local asset_id="$1"
  local expected_size="$2"
  local output_path="$3"
  local label="$4"
  local url="$GITHUB_API_ROOT/releases/assets/$asset_id"
  local -a curl_arguments

  [[ "$asset_id" =~ '^[1-9][0-9]*$' &&
      "$expected_size" =~ '^[1-9][0-9]*$' &&
      "$expected_size" -le 1073741824 ]] ||
    fail "GitHub release asset metadata is unsafe for $label"
  curl_arguments=(
    --disable
    --silent
    --show-error
    --fail
    --noproxy '*'
    --proto '=https'
    --proto-redir '=https'
    --location
    --max-redirs 3
    --connect-timeout 10
    --max-time 300
    --header 'Accept: application/octet-stream'
    --header 'X-GitHub-Api-Version: 2026-03-10'
  )
  curl_arguments+=(--config "$GITHUB_CURL_CONFIG")
  curl_arguments+=(--output "$output_path" "$url")

  if ! "$CURL" "${curl_arguments[@]}"; then
    rm -f -- "$output_path"
    fail "GitHub release asset download failed for $label"
  fi
  [[ -f "$output_path" && ! -L "$output_path" &&
      "$(/usr/bin/stat -f '%z' "$output_path")" == "$expected_size" ]] ||
    fail "GitHub release asset size did not match protected metadata for $label"
}

validate_workflow_evidence() {
  local evidence_kind="$1"
  local run_id="$2"
  local workflow_name="$3"
  local workflow_path="$4"
  local workflow_event="$5"
  local job_name="$6"
  shift 6
  local run_json="$TEMP_ROOT/github-$evidence_kind-run.json"
  local jobs_json="$TEMP_ROOT/github-$evidence_kind-jobs.json"
  local run_url="$GITHUB_API_ROOT/actions/runs/$run_id"
  local jobs_url="$run_url/jobs?per_page=100"

  github_api_json "$run_url" "$run_json" "$evidence_kind workflow run"
  github_api_json "$jobs_url" "$jobs_json" "$evidence_kind workflow jobs"
  /usr/bin/python3 -I -E -s -c '
import json
import sys

run_path, jobs_path, repository, run_id, head_sha, workflow_name, workflow_path, workflow_event, job_name, *required_steps = sys.argv[1:]
with open(run_path, "rb") as stream:
    run = json.load(stream)
with open(jobs_path, "rb") as stream:
    jobs_document = json.load(stream)

api_root = f"https://api.github.com/repos/{repository}"
web_root = f"https://github.com/{repository}"
expected_run_url = f"{api_root}/actions/runs/{run_id}"
if not isinstance(run, dict):
    raise SystemExit(1)
if run.get("id") != int(run_id):
    raise SystemExit(2)
repo = run.get("repository")
if not isinstance(repo, dict) or repo.get("full_name") != repository or repo.get("private") is not False:
    raise SystemExit(3)
if run.get("url") != expected_run_url or run.get("html_url") != f"{web_root}/actions/runs/{run_id}":
    raise SystemExit(4)
if run.get("jobs_url") != f"{expected_run_url}/jobs":
    raise SystemExit(5)
if run.get("name") != workflow_name or str(run.get("path", "")).split("@", 1)[0] != workflow_path:
    raise SystemExit(6)
if run.get("event") != workflow_event:
    raise SystemExit(7)
if run.get("head_sha") != head_sha or run.get("status") != "completed" or run.get("conclusion") != "success":
    raise SystemExit(8)

if not isinstance(jobs_document, dict) or not isinstance(jobs_document.get("jobs"), list):
    raise SystemExit(9)
jobs = jobs_document["jobs"]
if jobs_document.get("total_count") != len(jobs) or len(jobs) > 100:
    raise SystemExit(10)
matching_jobs = [job for job in jobs if isinstance(job, dict) and job.get("name") == job_name]
if len(matching_jobs) != 1:
    raise SystemExit(11)
job = matching_jobs[0]
if job.get("head_sha") != head_sha or job.get("status") != "completed" or job.get("conclusion") != "success":
    raise SystemExit(12)
if job.get("workflow_name") != workflow_name or job.get("run_url") != expected_run_url:
    raise SystemExit(13)
steps = job.get("steps")
if not isinstance(steps, list):
    raise SystemExit(14)
for required_name in required_steps:
    matching_steps = [step for step in steps if isinstance(step, dict) and step.get("name") == required_name]
    if len(matching_steps) != 1:
        raise SystemExit(15)
    step = matching_steps[0]
    if step.get("status") != "completed" or step.get("conclusion") != "success":
        raise SystemExit(16)
' \
    "$run_json" \
    "$jobs_json" \
    "$GITHUB_REPOSITORY" \
    "$run_id" \
    "$HEAD_COMMIT" \
    "$workflow_name" \
    "$workflow_path" \
    "$workflow_event" \
    "$job_name" \
    "$@" ||
    fail "GitHub $evidence_kind workflow evidence did not satisfy the release contract"
}

validate_immutable_release_policy() {
  local policy_json="$TEMP_ROOT/github-immutable-release-policy.json"

  github_api_json \
    "$GITHUB_API_ROOT/immutable-releases" \
    "$policy_json" \
    "immutable release policy"
  /usr/bin/python3 -I -E -s -c '
import json
import sys

with open(sys.argv[1], "rb") as stream:
    policy = json.load(stream)
if not isinstance(policy, dict) or policy.get("enabled") is not True:
    raise SystemExit(1)
' "$policy_json" ||
    fail "GitHub immutable releases are not enabled for the fixed repository"
}

validate_release_history() {
  local releases_json="$TEMP_ROOT/github-releases.json"
  local latest_json="$TEMP_ROOT/github-latest-release.json"
  local selection_json="$TEMP_ROOT/github-release-selection.json"
  local commit_json="$TEMP_ROOT/github-previous-release-commit.json"
  local manifest_path="$TEMP_ROOT/previous-release-manifest.json"
  local checksums_path="$TEMP_ROOT/previous-release-SHA256SUMS"
  local app_archive_path="$TEMP_ROOT/previous-release-app.zip"
  local rollback_path="$TEMP_ROOT/previous-release-rollback.pkg"
  local disk_image_path="$TEMP_ROOT/previous-release-disk-image.dmg"
  local expanded_package_path="$TEMP_ROOT/previous-release-expanded-pkg"
  local rollback_app_list="$TEMP_ROOT/previous-release-app-paths"
  local validated_json="$TEMP_ROOT/github-validated-history.json"
  local manifest_id manifest_digest manifest_size
  local checksums_id checksums_digest checksums_size
  local app_archive_id app_archive_digest app_archive_size
  local rollback_id rollback_digest rollback_size
  local disk_image_id disk_image_digest disk_image_size
  local rollback_app_path rollback_app_count

  if [[ "$GATEBEAM_RELEASE_BOOTSTRAP" == "1" ]]; then
    github_api_json \
      "$GITHUB_API_ROOT/releases?per_page=1" \
      "$releases_json" \
      "published release list"
    /usr/bin/python3 -I -E -s -c '
import json
import sys

with open(sys.argv[1], "rb") as stream:
    releases = json.load(stream)
if not isinstance(releases, list) or releases:
    raise SystemExit(1)
' "$releases_json" ||
      fail "bootstrap requires proof that the repository has no published release"
    PREVIOUS_BUILD_VERSION=0
    ROLLBACK_AVAILABLE=0
    return
  fi

  github_api_json \
    "$GITHUB_API_ROOT/releases/latest" \
    "$latest_json" \
    "latest published release"
  /usr/bin/python3 -I -E -s -c '
import json
import re
import sys

source_path, output_path, repository = sys.argv[1:]
with open(source_path, "rb") as stream:
    release = json.load(stream)
if not isinstance(release, dict):
    raise SystemExit(1)
if release.get("immutable") is not True or release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit(2)
tag = release.get("tag_name")
if not isinstance(tag, str) or re.fullmatch(r"v[0-9]+(?:[.][0-9]+){2}(?:[-.][A-Za-z0-9.]+)?", tag) is None:
    raise SystemExit(3)
version = tag[1:]
web_root = f"https://github.com/{repository}"
api_root = f"https://api.github.com/repos/{repository}"
if release.get("html_url") != f"{web_root}/releases/tag/{tag}":
    raise SystemExit(4)
if not isinstance(release.get("id"), int) or release["id"] <= 0:
    raise SystemExit(5)
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit(6)
expected_names = {
    "release-manifest.json",
    "SHA256SUMS",
    f"Gatebeam-{version}.zip",
    f"Gatebeam-{version}.pkg",
    f"Gatebeam-{version}.dmg",
}
if (
    len(assets) != len(expected_names)
    or any(not isinstance(asset, dict) for asset in assets)
    or {asset.get("name") for asset in assets} != expected_names
):
    raise SystemExit(7)

def select_asset(name, maximum_size):
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(8)
    asset = matches[0]
    asset_id = asset.get("id")
    digest = asset.get("digest")
    size = asset.get("size")
    if not isinstance(asset_id, int) or asset_id <= 0:
        raise SystemExit(9)
    if not isinstance(size, int) or size <= 0 or size > maximum_size:
        raise SystemExit(10)
    if not isinstance(digest, str) or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise SystemExit(11)
    if asset.get("state") != "uploaded":
        raise SystemExit(12)
    if asset.get("url") != f"{api_root}/releases/assets/{asset_id}":
        raise SystemExit(13)
    if asset.get("browser_download_url") != f"{web_root}/releases/download/{tag}/{name}":
        raise SystemExit(14)
    return {"id": asset_id, "digest": digest[7:], "size": size, "name": name}

selection = {
    "tag": tag,
    "version": version,
    "releaseURL": release["html_url"],
    "manifest": select_asset("release-manifest.json", 10485760),
    "checksums": select_asset("SHA256SUMS", 10485760),
    "appArchive": select_asset(f"Gatebeam-{version}.zip", 1073741824),
    "rollback": select_asset(f"Gatebeam-{version}.pkg", 1073741824),
    "diskImage": select_asset(f"Gatebeam-{version}.dmg", 1073741824),
}
selected_ids = [entry["id"] for key, entry in selection.items() if isinstance(entry, dict)]
if len(selected_ids) != len(set(selected_ids)):
    raise SystemExit(15)
with open(output_path, "w", encoding="utf-8") as stream:
    json.dump(selection, stream, sort_keys=True)
' "$latest_json" "$selection_json" "$GITHUB_REPOSITORY" ||
    fail "latest GitHub release is not a complete immutable formal release"

  PREVIOUS_RELEASE_TAG="$(/usr/bin/plutil -extract tag raw -o - "$selection_json")"
  PREVIOUS_RELEASE_VERSION="$(/usr/bin/plutil -extract version raw -o - "$selection_json")"
  PREVIOUS_RELEASE_URL="$(/usr/bin/plutil -extract releaseURL raw -o - "$selection_json")"
  ROLLBACK_ASSET_NAME="$(/usr/bin/plutil -extract rollback.name raw -o - "$selection_json")"
  ROLLBACK_ASSET_SHA256="$(/usr/bin/plutil -extract rollback.digest raw -o - "$selection_json")"
  manifest_id="$(/usr/bin/plutil -extract manifest.id raw -o - "$selection_json")"
  manifest_digest="$(/usr/bin/plutil -extract manifest.digest raw -o - "$selection_json")"
  manifest_size="$(/usr/bin/plutil -extract manifest.size raw -o - "$selection_json")"
  checksums_id="$(/usr/bin/plutil -extract checksums.id raw -o - "$selection_json")"
  checksums_digest="$(/usr/bin/plutil -extract checksums.digest raw -o - "$selection_json")"
  checksums_size="$(/usr/bin/plutil -extract checksums.size raw -o - "$selection_json")"
  app_archive_id="$(/usr/bin/plutil -extract appArchive.id raw -o - "$selection_json")"
  app_archive_digest="$(/usr/bin/plutil -extract appArchive.digest raw -o - "$selection_json")"
  app_archive_size="$(/usr/bin/plutil -extract appArchive.size raw -o - "$selection_json")"
  rollback_id="$(/usr/bin/plutil -extract rollback.id raw -o - "$selection_json")"
  rollback_digest="$(/usr/bin/plutil -extract rollback.digest raw -o - "$selection_json")"
  rollback_size="$(/usr/bin/plutil -extract rollback.size raw -o - "$selection_json")"
  disk_image_id="$(/usr/bin/plutil -extract diskImage.id raw -o - "$selection_json")"
  disk_image_digest="$(/usr/bin/plutil -extract diskImage.digest raw -o - "$selection_json")"
  disk_image_size="$(/usr/bin/plutil -extract diskImage.size raw -o - "$selection_json")"

  github_api_json \
    "$GITHUB_API_ROOT/commits/$PREVIOUS_RELEASE_TAG" \
    "$commit_json" \
    "previous release tag commit"
  github_asset_download \
    "$manifest_id" "$manifest_size" "$manifest_path" "previous release manifest"
  github_asset_download \
    "$checksums_id" "$checksums_size" "$checksums_path" "previous release checksums"
  github_asset_download \
    "$app_archive_id" "$app_archive_size" "$app_archive_path" "previous release app archive"
  github_asset_download \
    "$rollback_id" "$rollback_size" "$rollback_path" "previous release rollback package"
  github_asset_download \
    "$disk_image_id" "$disk_image_size" "$disk_image_path" "previous release disk image"
  [[ "$(/usr/bin/shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}')" == "$manifest_digest" ]] ||
    fail "previous release manifest did not match its protected GitHub digest"
  [[ "$(/usr/bin/shasum -a 256 "$checksums_path" | /usr/bin/awk '{print $1}')" == "$checksums_digest" ]] ||
    fail "previous release checksums did not match their protected GitHub digest"
  [[ "$(/usr/bin/shasum -a 256 "$app_archive_path" | /usr/bin/awk '{print $1}')" == "$app_archive_digest" ]] ||
    fail "previous release app archive did not match its protected GitHub digest"
  [[ "$(/usr/bin/shasum -a 256 "$rollback_path" | /usr/bin/awk '{print $1}')" == "$rollback_digest" ]] ||
    fail "previous release rollback package did not match its protected GitHub digest"
  [[ "$(/usr/bin/shasum -a 256 "$disk_image_path" | /usr/bin/awk '{print $1}')" == "$disk_image_digest" ]] ||
    fail "previous release disk image did not match its protected GitHub digest"

  /usr/bin/python3 -I -E -s -c '
import json
import re
import sys

manifest_path, checksums_path, commit_path, selection_path, output_path = sys.argv[1:]
with open(manifest_path, "rb") as stream:
    manifest = json.load(stream)
with open(commit_path, "rb") as stream:
    commit_document = json.load(stream)
with open(selection_path, "rb") as stream:
    selection = json.load(stream)

commit = commit_document.get("sha") if isinstance(commit_document, dict) else None
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40,64}", commit) is None:
    raise SystemExit(1)
if (
    not isinstance(manifest, dict)
    or manifest.get("schemaVersion") not in (2, 3)
    or manifest.get("product") != "Gatebeam"
    or manifest.get("bundleIdentifier") != "io.github.naifuliang.gatebeam"
):
    raise SystemExit(2)
if manifest.get("tag") != selection["tag"] or manifest.get("version") != selection["version"] or manifest.get("commit") != commit:
    raise SystemExit(3)
build = manifest.get("buildVersion")
if not isinstance(build, str) or re.fullmatch(r"[1-9][0-9]*", build) is None:
    raise SystemExit(4)
older_build = manifest.get("previousBuildVersion", manifest.get("previousPublicBuildVersion"))
if older_build is not None:
    if not isinstance(older_build, str) or re.fullmatch(r"(?:0|[1-9][0-9]*)", older_build) is None:
        raise SystemExit(5)
    if int(older_build) >= int(build):
        raise SystemExit(6)

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, list) or len(artifacts) != 3:
    raise SystemExit(7)
expected_artifacts = {
    selection["appArchive"]["name"]: ("app-archive", selection["appArchive"]),
    selection["rollback"]["name"]: ("installer-package", selection["rollback"]),
    selection["diskImage"]["name"]: ("disk-image", selection["diskImage"]),
}
seen_artifacts = set()
for artifact in artifacts:
    if not isinstance(artifact, dict):
        raise SystemExit(8)
    name = artifact.get("name")
    if name not in expected_artifacts or name in seen_artifacts:
        raise SystemExit(9)
    artifact_type, selected_asset = expected_artifacts[name]
    if (
        artifact.get("type") != artifact_type
        or artifact.get("sha256") != selected_asset["digest"]
        or artifact.get("byteCount") != selected_asset["size"]
    ):
        raise SystemExit(10)
    seen_artifacts.add(name)
if seen_artifacts != set(expected_artifacts):
    raise SystemExit(11)

checksums = {}
with open(checksums_path, "r", encoding="utf-8") as stream:
    for raw_line in stream:
        line = raw_line.rstrip("\n")
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        if match is None or match.group(2) in checksums:
            raise SystemExit(12)
        checksums[match.group(2)] = match.group(1)
expected_checksums = {
    name: selected_asset["digest"]
    for name, (_, selected_asset) in expected_artifacts.items()
}
if checksums != expected_checksums:
    raise SystemExit(13)

with open(output_path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "bundleIdentifier": manifest["bundleIdentifier"],
            "commit": commit,
            "previousBuildVersion": build,
            "previousVersion": manifest["version"],
        },
        stream,
        sort_keys=True,
    )
' "$manifest_path" "$checksums_path" "$commit_json" "$selection_json" "$validated_json" ||
    fail "previous immutable release manifest, checksum, build, or rollback asset did not validate"

  PREVIOUS_RELEASE_COMMIT="$(/usr/bin/plutil -extract commit raw -o - "$validated_json")"
  PREVIOUS_BUILD_VERSION="$(/usr/bin/plutil -extract previousBuildVersion raw -o - "$validated_json")"
  /bin/zsh -f "$ROOT_DIR/scripts/verify_release.sh" \
    pkg-signature \
    "$rollback_path" \
    "$PREVIOUS_RELEASE_VERSION" \
    "$PREVIOUS_BUILD_VERSION" \
    "$EXPECTED_BUNDLE_ID" \
    "$GATEBEAM_DEVELOPER_TEAM_ID" ||
    fail "previous release rollback package signature did not validate"
  "$PKGUTIL" --expand-full "$rollback_path" "$expanded_package_path" >/dev/null ||
    fail "previous release rollback package could not be expanded"
  /usr/bin/find \
    "$expanded_package_path" \
    -type d \
    -name Gatebeam.app \
    -prune \
    -print >"$rollback_app_list"
  rollback_app_count="$(/usr/bin/wc -l <"$rollback_app_list" | /usr/bin/tr -d '[:space:]')"
  [[ "$rollback_app_count" == "1" ]] ||
    fail "previous release rollback package must contain exactly one Gatebeam app"
  rollback_app_path="$(/usr/bin/head -n 1 "$rollback_app_list")"
  /bin/zsh -f "$ROOT_DIR/scripts/verify_release.sh" \
    app-signature \
    "$rollback_app_path" \
    "$PREVIOUS_RELEASE_VERSION" \
    "$PREVIOUS_BUILD_VERSION" \
    "$EXPECTED_BUNDLE_ID" \
    "$GATEBEAM_DEVELOPER_TEAM_ID" ||
    fail "previous release rollback app contents or signature did not validate"
  git_safe -C "$ROOT_DIR" cat-file -e "$PREVIOUS_RELEASE_COMMIT^{commit}" 2>/dev/null ||
    fail "previous immutable release commit is unavailable in the release worktree"
  git_safe -C "$ROOT_DIR" merge-base --is-ancestor \
    "$PREVIOUS_RELEASE_COMMIT" "$HEAD_COMMIT" ||
    fail "previous immutable release commit is not an ancestor of HEAD"
  ROLLBACK_AVAILABLE=1
}

inject_test_failure() {
  local point="$1"

  [[ -z "$TEST_FAILURE_POINT" || "$TEST_FAILURE_POINT" != "$point" ]] &&
    return
  [[ "$TEST_MODE" == "1" && "$ROOT_DIR" == /private/tmp/* ]] ||
    fail "release failure injection is restricted to /private/tmp fixtures"
  fail "injected release failure at $point"
}

verify_notarized_app_unchanged() {
  local label="$1"

  if ! /bin/zsh -f "$VERIFY_SCRIPT" \
    app-stapled \
    "$APP_PATH" \
    "$VERSION" \
    "$BUILD_VERSION" \
    "$BUNDLE_ID" \
    "$GATEBEAM_DEVELOPER_TEAM_ID"; then
    fail "$label packaging modified the notarized application"
  fi
}

notarize_and_review() {
  local label="$1"
  local artifact_path="$2"
  local response_path="$TEMP_ROOT/notary-$label-submit.json"
  local log_path="$WORKSPACE_ROOT/build/formal-notary-logs/$label.json"
  local submission_status
  local submission_id

  print -u2 -- "Submitting $label for notarization"
  "$XCRUN" notarytool submit \
    --keychain-profile "$GATEBEAM_NOTARY_PROFILE" \
    --wait \
    --output-format json \
    --no-progress \
    "$artifact_path" >"$response_path" ||
    fail "notary submission failed for $label"

  submission_status="$(
    /usr/bin/plutil -extract status raw -o - "$response_path"
  )" || fail "notary response omitted status for $label"
  submission_id="$(
    /usr/bin/plutil -extract id raw -o - "$response_path"
  )" || fail "notary response omitted submission id for $label"

  [[ "$submission_status" == "Accepted" ]] ||
    fail "notary submission for $label was not Accepted"
  [[ "$submission_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] ||
    fail "notary submission returned an invalid id for $label"

  mkdir -p "${log_path:h}"
  "$XCRUN" notarytool log \
    --keychain-profile "$GATEBEAM_NOTARY_PROFILE" \
    "$submission_id" \
    "$log_path" >/dev/null ||
    fail "could not retrieve notary log for $label"
  [[ -f "$log_path" && ! -L "$log_path" && -s "$log_path" ]] ||
    fail "notary log is missing for $label"

  /usr/bin/python3 -I -E -s -c '
import json
import sys

with open(sys.argv[1], "rb") as stream:
    result = json.load(stream)

if result.get("jobId") != sys.argv[2] or result.get("status") != "Accepted":
    raise SystemExit(1)
if "issues" not in result or result["issues"] not in (None, []):
    raise SystemExit(2)
' "$log_path" "$submission_id" ||
    fail "notary log contains warning or error issues for $label"

  print -r -- "$submission_id"
}

codesign_certificate_sha256() {
  local label="$1"
  local artifact_path="$2"
  local certificate_prefix="$TEMP_ROOT/$label-certificate-"
  local leaf_certificate="${certificate_prefix}0"
  local fingerprint

  "$CODESIGN" -d --extract-certificates "$certificate_prefix" "$artifact_path" \
    >/dev/null 2>&1 ||
    fail "could not extract the $label signing certificate"
  [[ -f "$leaf_certificate" && ! -L "$leaf_certificate" && -s "$leaf_certificate" ]] ||
    fail "$label signing certificate extraction did not produce a safe leaf certificate"
  fingerprint="$(
    /usr/bin/shasum -a 256 "$leaf_certificate" | /usr/bin/awk '{print $1}'
  )"
  [[ "$fingerprint" =~ '^[0-9A-Fa-f]{64}$' ]] ||
    fail "$label signing certificate fingerprint is invalid"
  print -r -- "$fingerprint"
}

write_manifest() {
  local output_path="$1"
  local plist_path="$TEMP_ROOT/release-manifest.plist"
  local app_name="${APP_ARCHIVE:t}"
  local pkg_name="${SIGNED_PKG:t}"
  local dmg_name="${SIGNED_DMG:t}"
  local notary_app_key="notarization"".app"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert schemaVersion -integer 3 "$plist_path"
  /usr/bin/plutil -insert product -string Gatebeam "$plist_path"
  /usr/bin/plutil -insert commit -string "$HEAD_COMMIT" "$plist_path"
  /usr/bin/plutil -insert tag -string "$RELEASE_TAG" "$plist_path"
  /usr/bin/plutil -insert version -string "$VERSION" "$plist_path"
  /usr/bin/plutil -insert buildVersion -string "$BUILD_VERSION" "$plist_path"
  /usr/bin/plutil -insert previousBuildVersion -string \
    "$PREVIOUS_BUILD_VERSION" "$plist_path"
  /usr/bin/plutil -insert bundleIdentifier -string "$BUNDLE_ID" "$plist_path"
  /usr/bin/plutil -insert teamIdentifier -string "$GATEBEAM_DEVELOPER_TEAM_ID" "$plist_path"
  /usr/bin/plutil -insert source -json '{}' "$plist_path"
  /usr/bin/plutil -insert source.mergeCommit -string "$HEAD_COMMIT" "$plist_path"
  /usr/bin/plutil -insert source.annotatedTag -string "$RELEASE_TAG" "$plist_path"
  /usr/bin/plutil -insert source.mergeParents -json '[]' "$plist_path"
  /usr/bin/plutil -insert source.mergeParents.0 -string "$MERGE_PARENT_ONE" "$plist_path"
  /usr/bin/plutil -insert source.mergeParents.1 -string "$MERGE_PARENT_TWO" "$plist_path"

  /usr/bin/plutil -insert artifacts -json '[]' "$plist_path"
  /usr/bin/plutil -insert artifacts.0 -json '{}' "$plist_path"
  /usr/bin/plutil -insert artifacts.0.name -string "$app_name" "$plist_path"
  /usr/bin/plutil -insert artifacts.0.type -string app-archive "$plist_path"
  /usr/bin/plutil -insert artifacts.0.byteCount -integer "$APP_BYTE_COUNT" "$plist_path"
  /usr/bin/plutil -insert artifacts.0.sha256 -string "$APP_SHA256" "$plist_path"
  /usr/bin/plutil -insert artifacts.0.signingCertificateName -string \
    "$APP_CERTIFICATE_NAME" "$plist_path"
  /usr/bin/plutil -insert artifacts.0.signingCertificateSHA256 -string \
    "$APP_CERTIFICATE_SHA256" "$plist_path"
  /usr/bin/plutil -insert artifacts.0.cdhash -string "$APP_CDHASH" "$plist_path"

  /usr/bin/plutil -insert artifacts.1 -json '{}' "$plist_path"
  /usr/bin/plutil -insert artifacts.1.name -string "$pkg_name" "$plist_path"
  /usr/bin/plutil -insert artifacts.1.type -string installer-package "$plist_path"
  /usr/bin/plutil -insert artifacts.1.byteCount -integer "$PKG_BYTE_COUNT" "$plist_path"
  /usr/bin/plutil -insert artifacts.1.sha256 -string "$PKG_SHA256" "$plist_path"
  /usr/bin/plutil -insert artifacts.1.signingCertificateName -string \
    "$PKG_CERTIFICATE_NAME" "$plist_path"
  /usr/bin/plutil -insert artifacts.1.signingCertificateSHA256 -string \
    "$PKG_CERTIFICATE_SHA256" "$plist_path"

  /usr/bin/plutil -insert artifacts.2 -json '{}' "$plist_path"
  /usr/bin/plutil -insert artifacts.2.name -string "$dmg_name" "$plist_path"
  /usr/bin/plutil -insert artifacts.2.type -string disk-image "$plist_path"
  /usr/bin/plutil -insert artifacts.2.byteCount -integer "$DMG_BYTE_COUNT" "$plist_path"
  /usr/bin/plutil -insert artifacts.2.sha256 -string "$DMG_SHA256" "$plist_path"
  /usr/bin/plutil -insert artifacts.2.signingCertificateName -string \
    "$DMG_CERTIFICATE_NAME" "$plist_path"
  /usr/bin/plutil -insert artifacts.2.signingCertificateSHA256 -string \
    "$DMG_CERTIFICATE_SHA256" "$plist_path"
  /usr/bin/plutil -insert artifacts.2.cdhash -string "$DMG_CDHASH" "$plist_path"

  /usr/bin/plutil -insert notarization -json '{}' "$plist_path"
  /usr/bin/plutil -insert "$notary_app_key" -json '{}' "$plist_path"
  /usr/bin/plutil -insert "$notary_app_key.submissionId" -string \
    "$APP_SUBMISSION_ID" "$plist_path"
  /usr/bin/plutil -insert "$notary_app_key.status" -string Accepted "$plist_path"
  /usr/bin/plutil -insert "$notary_app_key.log" -string notary-logs/app.json "$plist_path"
  /usr/bin/plutil -insert notarization.pkg -json '{}' "$plist_path"
  /usr/bin/plutil -insert notarization.pkg.submissionId -string \
    "$PKG_SUBMISSION_ID" "$plist_path"
  /usr/bin/plutil -insert notarization.pkg.status -string Accepted "$plist_path"
  /usr/bin/plutil -insert notarization.pkg.log -string notary-logs/pkg.json "$plist_path"
  /usr/bin/plutil -insert notarization.dmg -json '{}' "$plist_path"
  /usr/bin/plutil -insert notarization.dmg.submissionId -string \
    "$DMG_SUBMISSION_ID" "$plist_path"
  /usr/bin/plutil -insert notarization.dmg.status -string Accepted "$plist_path"
  /usr/bin/plutil -insert notarization.dmg.log -string notary-logs/dmg.json "$plist_path"

  /usr/bin/plutil -insert platform -json '{}' "$plist_path"
  /usr/bin/plutil -insert platform.name -string macOS "$plist_path"
  /usr/bin/plutil -insert platform.buildHostVersion -string "$PLATFORM_VERSION" "$plist_path"
  /usr/bin/plutil -insert platform.architecture -string "$PLATFORM_ARCHITECTURE" "$plist_path"
  /usr/bin/plutil -insert platform.minimumSystemVersion -string \
    "$MINIMUM_SYSTEM_VERSION" "$plist_path"
  /usr/bin/plutil -insert platform.supportedMacOSVersionRange -string \
    "$MINIMUM_SYSTEM_VERSION or later" "$plist_path"
  /usr/bin/plutil -insert platform.supportedArchitectures -json '[]' "$plist_path"
  /usr/bin/plutil -insert platform.supportedArchitectures.0 -string \
    "$SUPPORTED_ARCHITECTURES[1]" "$plist_path"
  if [[ ${#SUPPORTED_ARCHITECTURES[@]} -eq 2 ]]; then
    /usr/bin/plutil -insert platform.supportedArchitectures.1 -string \
      "$SUPPORTED_ARCHITECTURES[2]" "$plist_path"
  fi
  /usr/bin/plutil -insert toolchain -json '{}' "$plist_path"
  /usr/bin/plutil -insert toolchain.xcodeVersion -string "$XCODE_VERSION" "$plist_path"
  /usr/bin/plutil -insert toolchain.xcodeBuildVersion -string \
    "$XCODE_BUILD_VERSION" "$plist_path"
  /usr/bin/plutil -insert toolchain.swiftVersion -string "$SWIFT_VERSION" "$plist_path"
  /usr/bin/plutil -insert toolchain.swiftTarget -string "$SWIFT_TARGET" "$plist_path"

  /usr/bin/plutil -insert testing -json '{}' "$plist_path"
  /usr/bin/plutil -insert testing.evidenceURL -string \
    "$RELEASE_TEST_EVIDENCE_URL" "$plist_path"
  /usr/bin/plutil -insert testing.cleanMachineEvidenceURL -string \
    "$RELEASE_CLEAN_MACHINE_EVIDENCE_URL" "$plist_path"
  /usr/bin/plutil -insert testing.workflow -string "$CI_WORKFLOW_PATH" "$plist_path"
  /usr/bin/plutil -insert testing.workflowName -string \
    "$CI_WORKFLOW_NAME" "$plist_path"
  /usr/bin/plutil -insert testing.cleanMachineWorkflow -string \
    "$CLEAN_WORKFLOW_PATH" "$plist_path"
  /usr/bin/plutil -insert testing.cleanMachineWorkflowName -string \
    "$CLEAN_WORKFLOW_NAME" "$plist_path"
  /usr/bin/plutil -insert testing.commit -string "$HEAD_COMMIT" "$plist_path"
  /usr/bin/plutil -insert testing.cleanMachineCommit -string \
    "$HEAD_COMMIT" "$plist_path"
  /usr/bin/plutil -insert testing.status -string Passed "$plist_path"
  /usr/bin/plutil -insert testing.cleanMachineStatus -string Passed "$plist_path"
  /usr/bin/plutil -insert testing.gates -json \
    '["test_backend","test_proxy_policy","test_integration_contract","test_integration_tsan","test_keychain_identity","test_upgrade","test_ui_validation","test_build_assets","test_release_pipeline","test_privacy","build_app","codesign_verify","diff_check","test_clean_machine_validation"]' \
    "$plist_path"

  /usr/bin/plutil -insert rollback -json '{}' "$plist_path"
  if (( ROLLBACK_AVAILABLE )); then
    /usr/bin/plutil -insert rollback.available -bool true "$plist_path"
    /usr/bin/plutil -insert rollback.version -string \
      "$PREVIOUS_RELEASE_VERSION" "$plist_path"
    /usr/bin/plutil -insert rollback.releaseURL -string \
      "$PREVIOUS_RELEASE_URL" "$plist_path"
    /usr/bin/plutil -insert rollback.assetName -string \
      "$ROLLBACK_ASSET_NAME" "$plist_path"
    /usr/bin/plutil -insert rollback.assetSHA256 -string \
      "$ROLLBACK_ASSET_SHA256" "$plist_path"
    /usr/bin/plutil -insert rollback.sourceCommit -string \
      "$PREVIOUS_RELEASE_COMMIT" "$plist_path"
    /usr/bin/plutil -insert rollback.sourceManifestURL -string \
      "$GITHUB_WEB_ROOT/releases/download/$PREVIOUS_RELEASE_TAG/release-manifest.json" \
      "$plist_path"
    /usr/bin/plutil -insert rollback.sourceChecksumsURL -string \
      "$GITHUB_WEB_ROOT/releases/download/$PREVIOUS_RELEASE_TAG/SHA256SUMS" \
      "$plist_path"
  else
    /usr/bin/plutil -insert rollback.available -bool false "$plist_path"
    /usr/bin/plutil -insert rollback.bootstrap -bool true "$plist_path"
  fi
  /usr/bin/plutil -insert rollback.procedure -string \
    "docs/RELEASING.md#rollback-and-revocation" "$plist_path"
  /usr/bin/plutil -insert knownLimitations -json \
    '["Local-origin diagnostics do not prove public reachability.","Router protocol compatibility varies by device and firmware."]' \
    "$plist_path"

  /usr/bin/plutil -convert json -o "$output_path" "$plist_path"
  /usr/bin/plutil -p "$output_path" >/dev/null
}

sanitize_environment

trap 'cleanup' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

require_environment GATEBEAM_CODE_SIGN_IDENTITY
require_environment GATEBEAM_DEVELOPER_TEAM_ID
require_environment GATEBEAM_INSTALLER_SIGN_IDENTITY
require_environment GATEBEAM_NOTARY_PROFILE
require_environment GATEBEAM_RELEASE_CI_RUN_ID
require_environment GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID
require_environment GATEBEAM_GITHUB_TOKEN

GATEBEAM_RELEASE_BOOTSTRAP="${GATEBEAM_RELEASE_BOOTSTRAP:-0}"

[[ "$TEST_MODE" == "0" || "$TEST_MODE" == "1" ]] ||
  fail "GATEBEAM_RELEASE_TEST_MODE must be 0 or 1"
[[ "$GATEBEAM_RELEASE_BOOTSTRAP" == "0" ||
    "$GATEBEAM_RELEASE_BOOTSTRAP" == "1" ]] ||
  fail "GATEBEAM_RELEASE_BOOTSTRAP must be 0 or 1"
[[ -z "$TEST_FAILURE_POINT" || "$TEST_FAILURE_POINT" == "before-publish" ]] ||
  fail "GATEBEAM_RELEASE_TEST_FAILURE_POINT is invalid"

if [[ "$TEST_MODE" == "1" || -n "$TEST_TOOL_DIR" ]]; then
  validate_fixture_mode
fi

XCRUN="$(tool_path xcrun /usr/bin/xcrun)"
CODESIGN="$(tool_path codesign /usr/bin/codesign)"
PKGUTIL="$(tool_path pkgutil /usr/sbin/pkgutil)"
LIPO="$(tool_path lipo /usr/bin/lipo)"
PRODUCTSIGN="$(tool_path productsign /usr/bin/productsign)"
DITTO="$(tool_path ditto /usr/bin/ditto)"
CURL="$(tool_path curl /usr/bin/curl)"

[[ "$GATEBEAM_DEVELOPER_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] ||
  fail "GATEBEAM_DEVELOPER_TEAM_ID must be a 10-character Apple Team ID"
validate_identity_input \
  "$GATEBEAM_CODE_SIGN_IDENTITY" \
  "Developer ID Application" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
validate_identity_input \
  "$GATEBEAM_INSTALLER_SIGN_IDENTITY" \
  "Developer ID Installer" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
[[ ${#GATEBEAM_NOTARY_PROFILE} -le 64 &&
    "$GATEBEAM_NOTARY_PROFILE" =~ '^[A-Za-z0-9][A-Za-z0-9._ -]*$' ]] ||
  fail "GATEBEAM_NOTARY_PROFILE is invalid"
validate_run_id "$GATEBEAM_RELEASE_CI_RUN_ID" "GATEBEAM_RELEASE_CI_RUN_ID"
validate_run_id \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID"

[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] ||
  fail "Gatebeam Info.plist is missing or unsafe"
VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"
)" || fail "could not read Gatebeam version"
BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST"
)" || fail "could not read Gatebeam bundle identifier"
[[ "$VERSION" =~ '^[0-9]+([.][0-9]+){2}([-.][A-Za-z0-9.]+)?$' ]] ||
  fail "CFBundleShortVersionString is not a safe release version"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] ||
  fail "Gatebeam bundle identifier does not match the formal release contract"

if [[ -e "$DIST_DIR" || -L "$DIST_DIR" ]]; then
  assert_safe_dist
else
  mkdir "$DIST_DIR" ||
    fail "could not create the release output directory"
  assert_safe_dist
fi
RELEASE_DIR="$DIST_DIR/release-$VERSION"
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  fail "release destination already exists and will not be overwritten: $RELEASE_DIR"

WORKTREE_STATUS="$(git_safe -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"
[[ -z "$WORKTREE_STATUS" ]] ||
  fail "formal releases require a clean worktree"
HEAD_COMMIT="$(git_safe -C "$ROOT_DIR" rev-parse --verify HEAD^{commit})"
RELEASE_TAG="v$VERSION"
TAG_OBJECT_TYPE="$(
  git_safe -C "$ROOT_DIR" cat-file -t "refs/tags/$RELEASE_TAG" 2>/dev/null
)" || fail "required release tag is missing: $RELEASE_TAG"
[[ "$TAG_OBJECT_TYPE" == "tag" ]] ||
  fail "$RELEASE_TAG must be an annotated tag"
TAG_COMMIT="$(
  git_safe -C "$ROOT_DIR" rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}" 2>/dev/null
)" || fail "required release tag is missing: $RELEASE_TAG"
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] ||
  fail "$RELEASE_TAG does not point exactly to HEAD"
HEAD_AND_PARENTS=(${(s: :)$(git_safe -C "$ROOT_DIR" rev-list --parents -n 1 "$HEAD_COMMIT")})
[[ ${#HEAD_AND_PARENTS[@]} -eq 3 ]] ||
  fail "formal release HEAD must be a standard merge commit with exactly two parents"
MERGE_PARENT_ONE="${HEAD_AND_PARENTS[2]}"
MERGE_PARENT_TWO="${HEAD_AND_PARENTS[3]}"

PUBLISH_LOCK="$DIST_DIR/.release-$VERSION.lock"
assert_safe_dist
mkdir "$PUBLISH_LOCK" 2>/dev/null ||
  fail "another formal release is active or left a stale lock: $PUBLISH_LOCK"

TEMP_ROOT="$(mktemp -d "/private/tmp/gatebeam-formal-release.XXXXXX")"
prepare_github_auth
validate_immutable_release_policy
validate_workflow_evidence \
  ci \
  "$GATEBEAM_RELEASE_CI_RUN_ID" \
  "$CI_WORKFLOW_NAME" \
  "$CI_WORKFLOW_PATH" \
  "$CI_WORKFLOW_EVENT" \
  "Test, isolate, and build Gatebeam" \
  "Check out repository" \
  "Run backend tests" \
  "Run proxy policy tests" \
  "Run integration contract tests" \
  "Run integration contract tests with Thread Sanitizer" \
  "Run formal release pipeline tests" \
  "Verify Keychain and code-signing identity" \
  "Run upgrade compatibility tests" \
  "Run UI validation isolation tests" \
  "Validate build assets" \
  "Build complete app" \
  "Verify app signature" \
  "Scan source and app for private material" \
  "Check committed patch whitespace"
validate_workflow_evidence \
  clean-machine \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "$CLEAN_WORKFLOW_NAME" \
  "$CLEAN_WORKFLOW_PATH" \
  "$CLEAN_WORKFLOW_EVENT" \
  "Validate install, upgrade, rollback, and uninstall" \
  "Check out repository" \
  "Build and validate isolated install, upgrade, rollback, and uninstall"
RELEASE_TEST_EVIDENCE_URL="$GITHUB_WEB_ROOT/actions/runs/$GATEBEAM_RELEASE_CI_RUN_ID"
RELEASE_CLEAN_MACHINE_EVIDENCE_URL="$GITHUB_WEB_ROOT/actions/runs/$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID"
validate_release_history

SOURCE_ARCHIVE="$TEMP_ROOT/source.tar"
WORKSPACE_ROOT="$TEMP_ROOT/source"
mkdir -p "$WORKSPACE_ROOT"
git_safe -C "$ROOT_DIR" archive --format=tar "$HEAD_COMMIT" -o "$SOURCE_ARCHIVE"
/usr/bin/tar -xf "$SOURCE_ARCHIVE" -C "$WORKSPACE_ROOT"
rm -f -- "$SOURCE_ARCHIVE"

if [[ "$TEST_MODE" == "1" ]]; then
  TEST_TOOL_DIR="$WORKSPACE_ROOT/fake tools"
fi
export GATEBEAM_CODE_SIGN_IDENTITY
export GATEBEAM_DEVELOPER_TEAM_ID
export GATEBEAM_RELEASE_TEST_MODE="$TEST_MODE"
export GATEBEAM_RELEASE_TEST_TOOL_DIR="$TEST_TOOL_DIR"

print -u2 -- "Building Gatebeam $VERSION from $HEAD_COMMIT"
/bin/zsh -f "$WORKSPACE_ROOT/scripts/build_app.sh"

APP_PATH="$WORKSPACE_ROOT/dist/Gatebeam.app"
APP_ARCHIVE="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.zip"
UNSIGNED_PKG="$WORKSPACE_ROOT/build/Gatebeam-$VERSION.unsigned.pkg"
SIGNED_PKG="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.pkg"
SIGNED_PKG_CANDIDATE="$TEMP_ROOT/Gatebeam-$VERSION.signed.pkg"
SIGNED_DMG="$WORKSPACE_ROOT/dist/Gatebeam-$VERSION.dmg"
VERIFY_SCRIPT="$WORKSPACE_ROOT/scripts/verify_release.sh"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Gatebeam"

[[ -f "$APP_INFO_PLIST" && ! -L "$APP_INFO_PLIST" ]] ||
  fail "built application Info.plist is missing or unsafe"
BUILD_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO_PLIST"
)" || fail "could not read built application CFBundleVersion"
validate_positive_decimal "$BUILD_VERSION" "built application CFBundleVersion"
decimal_is_greater \
  "$BUILD_VERSION" \
  "$PREVIOUS_BUILD_VERSION" ||
  fail "built application CFBundleVersion must be greater than the latest immutable release build"
MINIMUM_SYSTEM_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_INFO_PLIST"
)" || fail "could not read built application minimum macOS version"
[[ "$MINIMUM_SYSTEM_VERSION" =~ '^[0-9]+([.][0-9]+){1,2}$' ]] ||
  fail "built application minimum macOS version is invalid"
[[ -f "$APP_EXECUTABLE" && ! -L "$APP_EXECUTABLE" && -x "$APP_EXECUTABLE" ]] ||
  fail "built application executable is missing or unsafe"
ARCHITECTURE_OUTPUT="$("$LIPO" -archs "$APP_EXECUTABLE")" ||
  fail "could not read built application architectures"
SUPPORTED_ARCHITECTURES=(${=ARCHITECTURE_OUTPUT})
[[ ${#SUPPORTED_ARCHITECTURES[@]} -ge 1 &&
    ${#SUPPORTED_ARCHITECTURES[@]} -le 2 ]] ||
  fail "built application architecture list is invalid"
for architecture in "${SUPPORTED_ARCHITECTURES[@]}"; do
  [[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] ||
    fail "built application contains an unsupported architecture"
done
if [[ ${#SUPPORTED_ARCHITECTURES[@]} -eq 2 &&
      "$SUPPORTED_ARCHITECTURES[1]" == "$SUPPORTED_ARCHITECTURES[2]" ]]; then
  fail "built application architecture list contains a duplicate"
fi

PLATFORM_VERSION="$(/usr/bin/sw_vers -productVersion)" ||
  fail "could not read the release platform version"
PLATFORM_ARCHITECTURE="$(/usr/bin/uname -m)" ||
  fail "could not read the release platform architecture"
XCODE_DETAILS="$(/usr/bin/xcodebuild -version)" ||
  fail "could not read the Xcode toolchain version"
SWIFT_DETAILS="$(/usr/bin/swiftc --version)" ||
  fail "could not read the Swift toolchain version"
XCODE_VERSION="$(
  print -r -- "$XCODE_DETAILS" | /usr/bin/sed -n 's/^Xcode //p' | /usr/bin/head -n 1
)"
XCODE_BUILD_VERSION="$(
  print -r -- "$XCODE_DETAILS" | /usr/bin/sed -n 's/^Build version //p' | /usr/bin/head -n 1
)"
SWIFT_VERSION="$(
  print -r -- "$SWIFT_DETAILS" |
    /usr/bin/awk '
      /Apple Swift version/ {
        for (field = 1; field < NF; field++) {
          if ($field == "version") {
            print $(field + 1)
            exit
          }
        }
      }
    ' |
    /usr/bin/head -n 1
)"
SWIFT_TARGET="$(
  print -r -- "$SWIFT_DETAILS" | /usr/bin/sed -n 's/^Target: //p' | /usr/bin/head -n 1
)"
[[ "$PLATFORM_VERSION" =~ '^[0-9]+([.][0-9]+){1,2}$' &&
    "$PLATFORM_ARCHITECTURE" =~ '^(arm64|x86_64)$' &&
    "$XCODE_VERSION" =~ '^[0-9]+([.][0-9]+){1,2}$' &&
    "$XCODE_BUILD_VERSION" =~ '^[A-Za-z0-9.]+$' &&
    "$SWIFT_VERSION" =~ '^[0-9]+([.][0-9]+){1,3}$' &&
    "$SWIFT_TARGET" =~ '^[A-Za-z0-9._-]+$' ]] ||
  fail "release platform or toolchain metadata is invalid"

/bin/zsh -f "$VERIFY_SCRIPT" \
  app-signature \
  "$APP_PATH" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

"$DITTO" -c -k --keepParent "$APP_PATH" "$APP_ARCHIVE"
APP_SUBMISSION_ID="$(notarize_and_review app "$APP_ARCHIVE")"
"$XCRUN" stapler staple "$APP_PATH" ||
  fail "could not staple the application"
/bin/zsh -f "$VERIFY_SCRIPT" \
  app-stapled \
  "$APP_PATH" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

rm -f -- "$APP_ARCHIVE"
"$DITTO" -c -k --keepParent "$APP_PATH" "$APP_ARCHIVE"

/bin/zsh -f "$WORKSPACE_ROOT/scripts/package_pkg.sh"
verify_notarized_app_unchanged "PKG"
mv -f -- "$SIGNED_PKG" "$UNSIGNED_PKG"
if ! "$PRODUCTSIGN" \
  --sign "$GATEBEAM_INSTALLER_SIGN_IDENTITY" \
  --timestamp \
  "$UNSIGNED_PKG" \
  "$SIGNED_PKG_CANDIDATE"; then
  rm -f -- "$SIGNED_PKG_CANDIDATE"
  fail "could not sign the installer package"
fi
/bin/zsh -f "$VERIFY_SCRIPT" \
  pkg-signature \
  "$SIGNED_PKG_CANDIDATE" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
PKG_SUBMISSION_ID="$(notarize_and_review pkg "$SIGNED_PKG_CANDIDATE")"
"$XCRUN" stapler staple "$SIGNED_PKG_CANDIDATE" ||
  fail "could not staple the installer package"
/bin/zsh -f "$VERIFY_SCRIPT" \
  pkg-stapled \
  "$SIGNED_PKG_CANDIDATE" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
mv -- "$SIGNED_PKG_CANDIDATE" "$SIGNED_PKG"

/bin/zsh -f "$WORKSPACE_ROOT/scripts/package_dmg.sh"
verify_notarized_app_unchanged "DMG"
"$CODESIGN" \
  --force \
  --sign "$GATEBEAM_CODE_SIGN_IDENTITY" \
  --timestamp \
  "$SIGNED_DMG"
/bin/zsh -f "$VERIFY_SCRIPT" \
  dmg-signature \
  "$SIGNED_DMG" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"
DMG_SUBMISSION_ID="$(notarize_and_review dmg "$SIGNED_DMG")"
"$XCRUN" stapler staple "$SIGNED_DMG" ||
  fail "could not staple the disk image"
/bin/zsh -f "$VERIFY_SCRIPT" \
  dmg-stapled \
  "$SIGNED_DMG" \
  "$VERSION" \
  "$BUILD_VERSION" \
  "$BUNDLE_ID" \
  "$GATEBEAM_DEVELOPER_TEAM_ID"

APP_SIGNING_DETAILS="$("$CODESIGN" -d --verbose=4 "$APP_PATH" 2>&1)" ||
  fail "could not read final application cdhash"
APP_CDHASH="$(
  print -r -- "$APP_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^CDHash=//p' |
    /usr/bin/head -n 1
)"
[[ "$APP_CDHASH" =~ '^[0-9A-Fa-f]{40,128}$' ]] ||
  fail "final application cdhash is missing or invalid"
APP_CERTIFICATE_NAME="$(
  print -r -- "$APP_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^Authority=//p' |
    /usr/bin/head -n 1
)"
validate_certificate_name \
  "$APP_CERTIFICATE_NAME" \
  "Developer ID Application" \
  "$GATEBEAM_DEVELOPER_TEAM_ID" ||
  fail "final application signing certificate name is invalid"
APP_CERTIFICATE_SHA256="$(codesign_certificate_sha256 app "$APP_PATH")"

DMG_SIGNING_DETAILS="$("$CODESIGN" -d --verbose=4 "$SIGNED_DMG" 2>&1)" ||
  fail "could not read final disk image signing details"
DMG_CDHASH="$(
  print -r -- "$DMG_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^CDHash=//p' |
    /usr/bin/head -n 1
)"
DMG_CERTIFICATE_NAME="$(
  print -r -- "$DMG_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^Authority=//p' |
    /usr/bin/head -n 1
)"
[[ "$DMG_CDHASH" =~ '^[0-9A-Fa-f]{40,128}$' ]] ||
  fail "final disk image cdhash is missing or invalid"
validate_certificate_name \
  "$DMG_CERTIFICATE_NAME" \
  "Developer ID Application" \
  "$GATEBEAM_DEVELOPER_TEAM_ID" ||
  fail "final disk image signing certificate name is invalid"
DMG_CERTIFICATE_SHA256="$(codesign_certificate_sha256 dmg "$SIGNED_DMG")"

PKG_SIGNING_DETAILS="$("$PKGUTIL" --check-signature "$SIGNED_PKG" 2>&1)" ||
  fail "could not read final installer signing details"
PKG_CERTIFICATE_NAME="$(
  print -r -- "$PKG_SIGNING_DETAILS" |
    /usr/bin/sed -n 's/^[[:space:]]*1[.][[:space:]]*//p' |
    /usr/bin/head -n 1
)"
PKG_CERTIFICATE_SHA256="$(
  print -r -- "$PKG_SIGNING_DETAILS" |
    /usr/bin/awk '
      fingerprint_label {
        gsub(/[^0-9A-Fa-f]/, "")
        if (length($0) > 0) {
          print
          exit
        }
      }
      /SHA256 Fingerprint:/ {
        fingerprint_label = 1
      }
    '
)"
validate_certificate_name \
  "$PKG_CERTIFICATE_NAME" \
  "Developer ID Installer" \
  "$GATEBEAM_DEVELOPER_TEAM_ID" ||
  fail "final installer signing certificate name is invalid"
[[ "$PKG_CERTIFICATE_SHA256" =~ '^[0-9A-Fa-f]{64}$' ]] ||
  fail "final installer signing certificate fingerprint is invalid"

assert_safe_dist
PUBLISH_STAGING="$(mktemp -d "$DIST_DIR/.release-$VERSION.XXXXXX")"
mkdir -p "$PUBLISH_STAGING/notary-logs"
"$DITTO" "$APP_ARCHIVE" "$PUBLISH_STAGING/${APP_ARCHIVE:t}"
"$DITTO" "$SIGNED_PKG" "$PUBLISH_STAGING/${SIGNED_PKG:t}"
"$DITTO" "$SIGNED_DMG" "$PUBLISH_STAGING/${SIGNED_DMG:t}"
"$DITTO" \
  "$WORKSPACE_ROOT/build/formal-notary-logs" \
  "$PUBLISH_STAGING/notary-logs"

APP_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${APP_ARCHIVE:t}" | /usr/bin/awk '{print $1}')"
PKG_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${SIGNED_PKG:t}" | /usr/bin/awk '{print $1}')"
DMG_SHA256="$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/${SIGNED_DMG:t}" | /usr/bin/awk '{print $1}')"
APP_BYTE_COUNT="$(/usr/bin/stat -f '%z' "$PUBLISH_STAGING/${APP_ARCHIVE:t}")"
PKG_BYTE_COUNT="$(/usr/bin/stat -f '%z' "$PUBLISH_STAGING/${SIGNED_PKG:t}")"
DMG_BYTE_COUNT="$(/usr/bin/stat -f '%z' "$PUBLISH_STAGING/${SIGNED_DMG:t}")"
validate_positive_decimal "$APP_BYTE_COUNT" "application archive byte count"
validate_positive_decimal "$PKG_BYTE_COUNT" "installer package byte count"
validate_positive_decimal "$DMG_BYTE_COUNT" "disk image byte count"

(
  cd "$PUBLISH_STAGING"
  /usr/bin/shasum -a 256 \
    "${APP_ARCHIVE:t}" \
    "${SIGNED_PKG:t}" \
    "${SIGNED_DMG:t}" > SHA256SUMS
)
write_manifest "$PUBLISH_STAGING/release-manifest.json"
if /usr/bin/grep -Fq \
  "$GATEBEAM_NOTARY_PROFILE" \
  "$PUBLISH_STAGING/release-manifest.json" \
  "$PUBLISH_STAGING"/notary-logs/*.json; then
  fail "release metadata leaked the notary credential profile"
fi

inject_test_failure before-publish

assert_safe_dist
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  fail "release destination already exists and will not be overwritten: $RELEASE_DIR"
mv -- "$PUBLISH_STAGING" "$RELEASE_DIR"
PUBLISH_STAGING=""
rmdir -- "$PUBLISH_LOCK"
PUBLISH_LOCK=""

print -r -- "Formal release published: $RELEASE_DIR"
