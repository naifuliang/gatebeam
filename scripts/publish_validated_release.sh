#!/bin/zsh -f
set -euo pipefail
umask 077

GITHUB_TOKEN_FILE="${GATEBEAM_RELEASE_PUBLISH_TOKEN_FILE:-}"
[[ -n "$GITHUB_TOKEN_FILE" ]] ||
  GITHUB_TOKEN_FILE="${GATEBEAM_GITHUB_TOKEN_FILE:-}"
GITHUB_API_TOKEN=""
ACTIONS_REPOSITORY="${GITHUB_REPOSITORY:-}"
unset \
  GATEBEAM_GITHUB_TOKEN \
  GATEBEAM_GITHUB_TOKEN_FILE \
  GATEBEAM_RELEASE_PUBLISH_TOKEN_FILE \
  GITHUB_TOKEN \
  GH_TOKEN
typeset +x GITHUB_API_TOKEN

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
CONTRACT="$ROOT_DIR/scripts/release_artifact_contract.py"
HISTORY_CONTRACT="$ROOT_DIR/scripts/release_history_contract.py"
TEST_TOOL_DIR="${GATEBEAM_RELEASE_TEST_TOOL_DIR:-}"
TEST_MODE="${GATEBEAM_RELEASE_TEST_MODE:-0}"
TEST_FAILURE_POINT="${GATEBEAM_RELEASE_TEST_FAILURE_POINT:-}"
FIXTURE_MARKER=".gatebeam-release-test-fixture"
EXPECTED_BUNDLE_ID="io.github.naifuliang.gatebeam"
GITHUB_REPOSITORY="naifuliang/gatebeam"
GITHUB_API_ROOT="https://api.github.com/repos/$GITHUB_REPOSITORY"
GITHUB_UPLOAD_ROOT="https://uploads.github.com/repos/$GITHUB_REPOSITORY"
GITHUB_WEB_ROOT="https://github.com/$GITHUB_REPOSITORY"
CI_WORKFLOW_NAME="CI"
CI_WORKFLOW_PATH=".github/workflows/ci.yml"
CLEAN_WORKFLOW_NAME="Release final-artifact validation"
CLEAN_WORKFLOW_PATH=".github/workflows/release-validation.yml"
TEMP_ROOT=""
PUBLISH_STAGING=""
PUBLISH_LOCK=""
REMOTE_DRAFT_ID=""
REMOTE_PUBLISHED=0
GITHUB_HTTP_STATUS="000"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

cleanup() {
  if [[ -n "$REMOTE_DRAFT_ID" && "$REMOTE_PUBLISHED" == "0" &&
        -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    github_api_no_content \
      DELETE \
      "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID" \
      "abandoned formal release draft" >/dev/null 2>&1 || true
  fi
  [[ -z "$PUBLISH_STAGING" ]] || /bin/rm -rf -- "$PUBLISH_STAGING"
  [[ -z "$PUBLISH_LOCK" ]] || /bin/rmdir -- "$PUBLISH_LOCK" 2>/dev/null || true
  [[ -z "$TEMP_ROOT" ]] || /bin/rm -rf -- "$TEMP_ROOT"
}

handle_signal() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
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
    GATEBEAM_RELEASE_TEST_EVIDENCE_URL \
    GATEBEAM_RELEASE_CLEAN_MACHINE_EVIDENCE_URL
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1
  export PYTHONNOUSERSITE=1
  export NO_PROXY="*"
  export no_proxy="*"
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
      "$canonical_tool_dir" == /private/tmp/* &&
      -f "$canonical_tool_dir/$FIXTURE_MARKER" &&
      ! -L "$canonical_tool_dir/$FIXTURE_MARKER" ]] ||
    fail "release tool override directory is invalid"
  if [[ -n "$fake_call_log" ]]; then
    fake_call_log_parent="$(
      cd -P "${fake_call_log:h}" 2>/dev/null && pwd -P
    )" || fail "release fixture call log has an invalid parent"
    [[ "$fake_call_log" == "$fake_call_log_parent/${fake_call_log:t}" &&
        "$fake_call_log_parent" == /private/tmp/* &&
        -f "$fake_call_log_parent/$FIXTURE_MARKER" &&
        ! -L "$fake_call_log" ]] ||
      fail "release fixture call log must remain inside a marked /private/tmp fixture"
  fi
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
  candidate="$TEST_TOOL_DIR/$name"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    fail "release test tool is missing or unsafe: $name"
  print -r -- "$candidate"
}

git_safe() {
  /usr/bin/git \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.attributesfile=/dev/null \
    "$@"
}

require_environment() {
  local variable_name="$1"
  [[ -n "${(P)variable_name:-}" ]] ||
    fail "$variable_name is required for a formal release"
}

validate_run_id() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ '^[1-9][0-9]*$' ]] ||
    fail "$label must be a positive GitHub Actions run ID"
}

validate_publisher_context() {
  [[ "$TEST_MODE" == "0" ]] || return 0
  [[ "${GITHUB_ACTIONS:-}" == "true" &&
      "$ACTIONS_REPOSITORY" == "$GITHUB_REPOSITORY" &&
      "${GITHUB_REPOSITORY_ID:-}" =~ '^[1-9][0-9]*$' &&
      "${GITHUB_RUN_ID:-}" == "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" &&
      "${GITHUB_RUN_ATTEMPT:-}" =~ '^[1-9][0-9]*$' &&
      "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" &&
      "${GITHUB_JOB:-}" == "publish-release" &&
      "${GITHUB_REF_TYPE:-}" == "tag" &&
      "${GITHUB_REF_NAME:-}" == "$RELEASE_TAG" &&
      "${GITHUB_REF:-}" == "refs/tags/$RELEASE_TAG" &&
      "${GITHUB_SHA:-}" == "$HEAD_COMMIT" &&
      "${GITHUB_WORKFLOW_SHA:-}" == "$HEAD_COMMIT" &&
      "${GITHUB_WORKFLOW_REF:-}" ==
        "$GITHUB_REPOSITORY/$CLEAN_WORKFLOW_PATH@refs/tags/$RELEASE_TAG" ]] ||
    fail "formal publisher is not bound to the trusted release workflow context"
}

assert_safe_dist() {
  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" &&
      "$(cd -P "$DIST_DIR" && pwd -P)" == "$DIST_DIR" ]] ||
    fail "dist is not a safe release directory"
}

prepare_github_auth() {
  local token_parent
  local token_size

  [[ -n "$GITHUB_TOKEN_FILE" && "$GITHUB_TOKEN_FILE" == /* ]] ||
    fail "GATEBEAM_GITHUB_TOKEN_FILE must be an absolute path"
  token_parent="$(
    cd -P "${GITHUB_TOKEN_FILE:h}" 2>/dev/null && pwd -P
  )" || fail "GATEBEAM_GITHUB_TOKEN_FILE has an invalid parent"
  [[ "$GITHUB_TOKEN_FILE" == "$token_parent/${GITHUB_TOKEN_FILE:t}" &&
      -f "$GITHUB_TOKEN_FILE" &&
      ! -L "$GITHUB_TOKEN_FILE" &&
      "$(/usr/bin/stat -f '%Lp' "$GITHUB_TOKEN_FILE")" == "600" &&
      "$(/usr/bin/stat -f '%u' "$GITHUB_TOKEN_FILE")" == "$EUID" &&
      "$(/usr/bin/stat -f '%l' "$GITHUB_TOKEN_FILE")" == "1" ]] ||
    fail "GATEBEAM_GITHUB_TOKEN_FILE must be a canonical, private 0600 regular file"
  token_size="$(/usr/bin/stat -f '%z' "$GITHUB_TOKEN_FILE")"
  (( token_size > 0 && token_size <= 256 )) ||
    fail "GATEBEAM_GITHUB_TOKEN_FILE contains an invalid token"
  GITHUB_API_TOKEN="$(<"$GITHUB_TOKEN_FILE")"
  [[ ${#GITHUB_API_TOKEN} -le 255 &&
      "$GITHUB_API_TOKEN" =~ '^[A-Za-z0-9_.=-]+$' ]] ||
    fail "GATEBEAM_GITHUB_TOKEN_FILE contains an invalid token"
}

github_curl() {
  local request_kind="$1"
  local url="$2"
  local output_path="$3"
  local method="${4:-GET}"
  local body_path="${5:-}"
  local upload_path="${6:-}"
  local config_path
  local status_path
  local curl_status=0

  config_path="$(/usr/bin/mktemp "$TEMP_ROOT/github-curl.XXXXXX")" ||
    fail "could not create private GitHub request config"
  status_path="$(/usr/bin/mktemp "$TEMP_ROOT/github-status.XXXXXX")" ||
    fail "could not create private GitHub status file"
  /bin/chmod 600 "$config_path" ||
    fail "could not protect private GitHub request config"
  {
    print -r -- "silent"
    print -r -- "show-error"
    print -r -- "fail"
    print -r -- 'noproxy = "*"'
    print -r -- 'proto = "=https"'
    if [[ "$request_kind" == "artifact" ]]; then
      print -r -- 'proto-redir = "=https"'
      print -r -- "location"
      print -r -- "max-redirs = 3"
      print -r -- "max-time = 600"
      print -r -- 'header = "Accept: application/vnd.github+json"'
    elif [[ "$request_kind" == "upload" ]]; then
      print -r -- "max-redirs = 0"
      print -r -- "max-time = 1800"
      print -r -- 'header = "Accept: application/vnd.github+json"'
    else
      print -r -- "max-redirs = 0"
      print -r -- "max-time = 30"
      print -r -- 'header = "Accept: application/vnd.github+json"'
    fi
    print -r -- "connect-timeout = 10"
    print -r -- 'write-out = "%{http_code}"'
    print -r -- 'header = "X-GitHub-Api-Version: 2026-03-10"'
    print -r -- "header = \"Authorization: Bearer $GITHUB_API_TOKEN\""
    if [[ "$method" != "GET" ]]; then
      print -r -- "request = \"$method\""
    fi
    if [[ -n "$body_path" ]]; then
      print -r -- 'header = "Content-Type: application/json"'
      print -r -- "data-binary = \"@$body_path\""
    fi
    if [[ -n "$upload_path" ]]; then
      print -r -- 'header = "Content-Type: application/octet-stream"'
      print -r -- "upload-file = \"$upload_path\""
    fi
    print -r -- "output = \"$output_path\""
    print -r -- "url = \"$url\""
  } >"$config_path"
  "$CURL" --disable --config "$config_path" >"$status_path" || curl_status=$?
  GITHUB_HTTP_STATUS="$(<"$status_path")"
  [[ "$GITHUB_HTTP_STATUS" =~ '^[0-9]{3}$' ]] ||
    GITHUB_HTTP_STATUS="000"
  /bin/rm -f -- "$config_path"
  /bin/rm -f -- "$status_path"
  return "$curl_status"
}

json_file_is_safe() {
  local output_path="$1"
  [[ -f "$output_path" && ! -L "$output_path" && -s "$output_path" &&
      "$(/usr/bin/stat -f '%l' "$output_path")" == "1" ]] ||
    return 1
  (( $(/usr/bin/stat -f '%z' "$output_path") <= 10485760 )) ||
    return 1
  /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
if not isinstance(value, (dict, list)):
    raise SystemExit(1)
' "$output_path" ||
    return 1
}

validate_json_file() {
  local output_path="$1"
  local label="$2"
  json_file_is_safe "$output_path" ||
    fail "GitHub API returned invalid JSON for $label"
}

fail_github_status() {
  local label="$1"
  case "$GITHUB_HTTP_STATUS" in
    401|403)
      fail "GitHub authorization was rejected for $label (HTTP $GITHUB_HTTP_STATUS)"
      ;;
    404)
      fail "GitHub resource was not found for $label (HTTP 404)"
      ;;
    4??)
      fail "GitHub rejected $label (HTTP $GITHUB_HTTP_STATUS)"
      ;;
    *)
      fail "GitHub request failed for $label (HTTP $GITHUB_HTTP_STATUS)"
      ;;
  esac
}

github_api_json() {
  local url="$1"
  local output_path="$2"
  local label="$3"

  [[ "$url" == "$GITHUB_API_ROOT/"* ]] ||
    fail "internal GitHub API endpoint escaped the fixed repository"
  if ! github_curl json "$url" "$output_path" ||
      [[ "$GITHUB_HTTP_STATUS" != "200" ]]; then
    /bin/rm -f -- "$output_path"
    fail_github_status "$label"
  fi
  validate_json_file "$output_path" "$label"
}

github_api_mutation_json() {
  local method="$1"
  local url="$2"
  local body_path="$3"
  local output_path="$4"
  local label="$5"
  [[ "$method" == "POST" || "$method" == "PATCH" ]] ||
    fail "internal GitHub mutation method is invalid"
  [[ "$url" == "$GITHUB_API_ROOT/"* ]] ||
    fail "internal GitHub mutation escaped the fixed repository"
  [[ -f "$body_path" && ! -L "$body_path" ]] ||
    fail "GitHub mutation body is unsafe for $label"
  if ! github_curl json "$url" "$output_path" "$method" "$body_path" ||
      [[ "$GITHUB_HTTP_STATUS" != 2?? ]] ||
      ! json_file_is_safe "$output_path"; then
    /bin/rm -f -- "$output_path"
    case "$GITHUB_HTTP_STATUS" in
      401|403|404) fail_github_status "$label" ;;
      *) return 2 ;;
    esac
  fi
  return 0
}

github_api_no_content() {
  local method="$1"
  local url="$2"
  local label="$3"
  local output_path="$TEMP_ROOT/no-content-$RANDOM"
  [[ "$method" == "DELETE" && "$url" == "$GITHUB_API_ROOT/"* ]] ||
    return 1
  if ! github_curl json "$url" "$output_path" "$method"; then
    /bin/rm -f -- "$output_path"
    [[ "$GITHUB_HTTP_STATUS" == "404" ]] && return 0
    return 1
  fi
  [[ "$GITHUB_HTTP_STATUS" == "204" ]] ||
    return 1
  [[ ! -s "$output_path" ]] ||
    return 1
  /bin/rm -f -- "$output_path"
}

github_release_asset_upload() {
  local release_id="$1"
  local asset_path="$2"
  local output_path="$3"
  local label="$4"
  local name="${asset_path:t}"
  local encoded_name="${name//+/%2B}"
  local url="$GITHUB_UPLOAD_ROOT/releases/$release_id/assets?name=$encoded_name"
  [[ "$release_id" =~ '^[1-9][0-9]*$' &&
      "$name" =~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,239}$' &&
      -f "$asset_path" && ! -L "$asset_path" &&
      "$(/usr/bin/stat -f '%l' "$asset_path")" == "1" ]] ||
    fail "release asset upload is unsafe for $label"
  if ! github_curl upload "$url" "$output_path" POST "" "$asset_path" ||
      [[ "$GITHUB_HTTP_STATUS" != 2?? ]] ||
      ! json_file_is_safe "$output_path"; then
    /bin/rm -f -- "$output_path"
    case "$GITHUB_HTTP_STATUS" in
      401|403|404) fail_github_status "$label" ;;
      *) return 2 ;;
    esac
  fi
  return 0
}

github_artifact_download() {
  local artifact_id="$1"
  local expected_digest="$2"
  local output_path="$3"
  local label="$4"
  local url="$GITHUB_API_ROOT/actions/artifacts/$artifact_id/zip"

  [[ "$artifact_id" =~ '^[1-9][0-9]*$' &&
      "$expected_digest" =~ '^[0-9a-f]{64}$' ]] ||
    fail "GitHub artifact metadata is unsafe for $label"
  if ! github_curl artifact "$url" "$output_path"; then
    /bin/rm -f -- "$output_path"
    fail "GitHub artifact download failed for $label"
  fi
  [[ -f "$output_path" && ! -L "$output_path" && -s "$output_path" &&
      "$(/usr/bin/stat -f '%l' "$output_path")" == "1" ]] ||
    fail "GitHub artifact download is unsafe for $label"
  (( $(/usr/bin/stat -f '%z' "$output_path") <= 4294967296 )) ||
    fail "GitHub artifact download is too large for $label"
  [[ "$(/usr/bin/shasum -a 256 "$output_path" | /usr/bin/awk '{print $1}')" ==
      "$expected_digest" ]] ||
    fail "GitHub artifact digest did not match protected metadata for $label"
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

validate_ci_evidence() {
  local run_id="$1"
  local run_json="$TEMP_ROOT/github-ci-run.json"
  local jobs_json="$TEMP_ROOT/github-ci-jobs.json"
  github_api_json \
    "$GITHUB_API_ROOT/actions/runs/$run_id" \
    "$run_json" \
    "CI workflow run"
  github_api_json \
    "$GITHUB_API_ROOT/actions/runs/$run_id/jobs?per_page=100" \
    "$jobs_json" \
    "CI workflow jobs"
  /usr/bin/python3 -I -E -s - \
    "$run_json" "$jobs_json" "$GITHUB_REPOSITORY" "$run_id" \
    "$HEAD_COMMIT" "$CI_WORKFLOW_NAME" "$CI_WORKFLOW_PATH" <<'PY' ||
import json
import sys

run_path, jobs_path, repository, run_id, head_sha, workflow_name, workflow_path = sys.argv[1:]
with open(run_path, "rb") as stream:
    run = json.load(stream)
with open(jobs_path, "rb") as stream:
    jobs_document = json.load(stream)
api_root = f"https://api.github.com/repos/{repository}"
web_root = f"https://github.com/{repository}"
run_url = f"{api_root}/actions/runs/{run_id}"
if not isinstance(run, dict) or run.get("id") != int(run_id):
    raise SystemExit(1)
repo = run.get("repository")
if not isinstance(repo, dict) or repo.get("full_name") != repository or repo.get("private") is not False:
    raise SystemExit(2)
if run.get("url") != run_url or run.get("html_url") != f"{web_root}/actions/runs/{run_id}":
    raise SystemExit(3)
if run.get("jobs_url") != f"{run_url}/jobs":
    raise SystemExit(4)
if run.get("name") != workflow_name or str(run.get("path", "")).split("@", 1)[0] != workflow_path:
    raise SystemExit(5)
if (
    run.get("event") != "push"
    or run.get("head_sha") != head_sha
    or run.get("status") != "completed"
    or run.get("conclusion") != "success"
):
    raise SystemExit(6)
jobs = jobs_document.get("jobs") if isinstance(jobs_document, dict) else None
if not isinstance(jobs, list) or jobs_document.get("total_count") != len(jobs) or len(jobs) > 100:
    raise SystemExit(7)
matches = [job for job in jobs if isinstance(job, dict) and job.get("name") == "Test, isolate, and build Gatebeam"]
if len(matches) != 1:
    raise SystemExit(8)
job = matches[0]
if (
    job.get("head_sha") != head_sha
    or job.get("status") != "completed"
    or job.get("conclusion") != "success"
    or job.get("workflow_name") != workflow_name
    or job.get("run_url") != run_url
):
    raise SystemExit(9)
required = {
    "Check out repository",
    "Run backend tests",
    "Run proxy policy tests",
    "Run integration contract tests",
    "Run integration contract tests with Thread Sanitizer",
    "Run formal release pipeline tests",
    "Run final artifact contract tests",
    "Run final candidate validator behavior tests",
    "Run formal publisher tests",
    "Validate formal release workflow contract",
    "Verify Keychain and code-signing identity",
    "Run upgrade compatibility tests",
    "Run UI validation isolation tests",
    "Validate build assets",
    "Build complete app",
    "Verify app signature",
    "Scan source and app for private material",
    "Check committed patch whitespace",
}
steps = job.get("steps")
if not isinstance(steps, list):
    raise SystemExit(10)
seen = {
    step.get("name")
    for step in steps
    if isinstance(step, dict)
    and step.get("status") == "completed"
    and step.get("conclusion") == "success"
}
if not required.issubset(seen):
    raise SystemExit(11)
PY
    fail "GitHub CI workflow evidence did not satisfy the release contract"
}

validate_final_artifact_run() {
  local run_id="$1"
  local output_path="$2"
  local run_json="$TEMP_ROOT/github-final-run.json"
  local jobs_json="$TEMP_ROOT/github-final-jobs.json"
  github_api_json \
    "$GITHUB_API_ROOT/actions/runs/$run_id" \
    "$run_json" \
    "final-artifact workflow run"
  github_api_json \
    "$GITHUB_API_ROOT/actions/runs/$run_id/jobs?per_page=100" \
    "$jobs_json" \
    "final-artifact workflow jobs"
  /usr/bin/python3 -I -E -s - \
    "$run_json" "$jobs_json" "$output_path" "$GITHUB_REPOSITORY" \
    "$run_id" "$HEAD_COMMIT" "$RELEASE_TAG" \
    "$CLEAN_WORKFLOW_NAME" "$CLEAN_WORKFLOW_PATH" <<'PY' ||
import json
import re
import sys

run_path, jobs_path, output_path, repository, run_id, head_sha, tag, workflow_name, workflow_path = sys.argv[1:]
with open(run_path, "rb") as stream:
    run = json.load(stream)
with open(jobs_path, "rb") as stream:
    jobs_document = json.load(stream)
api_root = f"https://api.github.com/repos/{repository}"
web_root = f"https://github.com/{repository}"
run_url = f"{api_root}/actions/runs/{run_id}"
if not isinstance(run, dict) or run.get("id") != int(run_id):
    raise SystemExit(1)
repo = run.get("repository")
if (
    not isinstance(repo, dict)
    or repo.get("full_name") != repository
    or repo.get("private") is not False
    or not isinstance(repo.get("id"), int)
    or repo["id"] <= 0
):
    raise SystemExit(2)
if run.get("url") != run_url or run.get("html_url") != f"{web_root}/actions/runs/{run_id}":
    raise SystemExit(3)
if run.get("jobs_url") != f"{run_url}/jobs":
    raise SystemExit(4)
if run.get("name") != workflow_name or str(run.get("path", "")).split("@", 1)[0] != workflow_path:
    raise SystemExit(5)
attempt = run.get("run_attempt")
if not isinstance(attempt, int) or attempt <= 0:
    raise SystemExit(6)
if (
    run.get("event") != "workflow_dispatch"
    or run.get("head_sha") != head_sha
    or run.get("head_branch") != tag
    or run.get("status") != "in_progress"
    or run.get("conclusion") is not None
):
    raise SystemExit(7)
jobs = jobs_document.get("jobs") if isinstance(jobs_document, dict) else None
if not isinstance(jobs, list) or jobs_document.get("total_count") != len(jobs) or len(jobs) != 3:
    raise SystemExit(8)
required_jobs = {
    "Build, sign, notarize, and freeze final candidate": {
        "Check out release source",
        "Verify release invocation",
        "Configure signing and notarization credentials",
        "Prepare hash-bound final candidate",
        "Upload final candidate",
        "Cleanup signing credentials",
    },
    "Validate frozen candidate on clean macOS": {
        "Check out release source",
        "Download exact final candidate",
        "Validate signature, notarization, install, upgrade, rollback, and uninstall",
        "Upload clean-machine attestation",
    },
    "Publish exact validated bytes immutably": {
        "Check out release source for publisher",
        "Configure private publisher token",
    },
}
if {job.get("name") for job in jobs if isinstance(job, dict)} != set(required_jobs):
    raise SystemExit(9)
for job in jobs:
    publisher = job.get("name") == "Publish exact validated bytes immutably"
    expected_status = "in_progress" if publisher else "completed"
    expected_conclusion = None if publisher else "success"
    if (
        job.get("head_sha") != head_sha
        or job.get("status") != expected_status
        or job.get("conclusion") != expected_conclusion
        or job.get("workflow_name") != workflow_name
        or job.get("run_url") != run_url
    ):
        raise SystemExit(10)
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise SystemExit(11)
    successful = {
        step.get("name")
        for step in steps
        if isinstance(step, dict)
        and step.get("status") == "completed"
        and step.get("conclusion") == "success"
    }
    if not required_jobs[job["name"]].issubset(successful):
        raise SystemExit(12)
    if publisher:
        active = [
            step
            for step in steps
            if isinstance(step, dict)
            and step.get("name") == "Publish exact validated bytes immutably"
            and step.get("status") == "in_progress"
            and step.get("conclusion") is None
        ]
        if len(active) != 1:
            raise SystemExit(13)
candidate_name = f"gatebeam-final-candidate-{tag}-{head_sha}-run{run_id}-attempt{attempt}"
attestation_name = f"gatebeam-clean-machine-attestation-{tag}-{head_sha}-run{run_id}-attempt{attempt}"
document = {
    "repositoryId": repo["id"],
    "runId": int(run_id),
    "runAttempt": attempt,
    "workflowRef": f"{repository}/{workflow_path}@refs/tags/{tag}",
    "workflowSHA": head_sha,
    "candidateArtifactName": candidate_name,
    "attestationArtifactName": attestation_name,
}
with open(output_path, "x", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
    fail "GitHub final-artifact workflow evidence did not satisfy the release contract"
}

select_run_artifacts() {
  local run_id="$1"
  local context_path="$2"
  local output_path="$3"
  local artifacts_json="$TEMP_ROOT/github-final-artifacts.json"
  github_api_json \
    "$GITHUB_API_ROOT/actions/runs/$run_id/artifacts?per_page=100" \
    "$artifacts_json" \
    "final-artifact workflow artifacts"
  /usr/bin/python3 -I -E -s - \
    "$artifacts_json" "$context_path" "$output_path" \
    "$GITHUB_REPOSITORY" "$run_id" "$HEAD_COMMIT" <<'PY' ||
import json
import re
import sys

artifacts_path, context_path, output_path, repository, run_id, head_sha = sys.argv[1:]
with open(artifacts_path, "rb") as stream:
    document = json.load(stream)
with open(context_path, "rb") as stream:
    context = json.load(stream)
artifacts = document.get("artifacts") if isinstance(document, dict) else None
if (
    not isinstance(artifacts, list)
    or document.get("total_count") != len(artifacts)
    or len(artifacts) > 100
):
    raise SystemExit(1)
expected_names = {
    "candidate": context["candidateArtifactName"],
    "attestation": context["attestationArtifactName"],
}
api_root = f"https://api.github.com/repos/{repository}"
selected = {}
for kind, name in expected_names.items():
    matches = [entry for entry in artifacts if isinstance(entry, dict) and entry.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(2)
    entry = matches[0]
    artifact_id = entry.get("id")
    digest = entry.get("digest")
    size = entry.get("size_in_bytes")
    workflow_run = entry.get("workflow_run")
    if (
        not isinstance(artifact_id, int)
        or artifact_id <= 0
        or not isinstance(digest, str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None
        or not isinstance(size, int)
        or size <= 0
        or size > 4294967296
        or entry.get("expired") is not False
        or entry.get("url") != f"{api_root}/actions/artifacts/{artifact_id}"
        or entry.get("archive_download_url") != f"{api_root}/actions/artifacts/{artifact_id}/zip"
        or not isinstance(workflow_run, dict)
        or workflow_run.get("id") != int(run_id)
        or workflow_run.get("repository_id") != context["repositoryId"]
        or workflow_run.get("head_repository_id") != context["repositoryId"]
        or workflow_run.get("head_sha") != head_sha
    ):
        raise SystemExit(3)
    selected[kind] = {
        "id": artifact_id,
        "name": name,
        "digest": digest[7:],
        "size": size,
    }
if selected["candidate"]["id"] == selected["attestation"]["id"]:
    raise SystemExit(4)
with open(output_path, "x", encoding="utf-8") as stream:
    json.dump(selected, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
    fail "GitHub final-artifact metadata did not satisfy the release contract"
}

json_field() {
  local path="$1"
  local field_path="$2"
  /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
for key in sys.argv[2].split("."):
    if not isinstance(value, dict) or key not in value:
        raise SystemExit(1)
    value = value[key]
if isinstance(value, bool) or not isinstance(value, (str, int)):
    raise SystemExit(2)
print(value)
' "$path" "$field_path"
}

github_release_asset_download() {
  local asset_id="$1"
  local expected_size="$2"
  local expected_digest="$3"
  local output_path="$4"
  local label="$5"
  [[ "$asset_id" =~ '^[1-9][0-9]*$' &&
      "$expected_size" =~ '^[1-9][0-9]*$' &&
      "$expected_digest" =~ '^[0-9a-f]{64}$' ]] ||
    fail "historical release asset metadata is unsafe for $label"
  if ! github_curl artifact \
      "$GITHUB_API_ROOT/releases/assets/$asset_id" \
      "$output_path"; then
    /bin/rm -f -- "$output_path"
    fail "historical release asset download failed for $label"
  fi
  [[ -f "$output_path" && ! -L "$output_path" &&
      "$(/usr/bin/stat -f '%l' "$output_path")" == "1" &&
      "$(/usr/bin/stat -f '%z' "$output_path")" == "$expected_size" &&
      "$(/usr/bin/shasum -a 256 "$output_path" | /usr/bin/awk '{print $1}')" ==
      "$expected_digest" ]] ||
    fail "historical release asset bytes disagree with immutable metadata for $label"
}

fetch_paginated_array() {
  local endpoint="$1"
  local output_path="$2"
  local label="$3"
  local pages_root="$TEMP_ROOT/pages-$RANDOM"
  local page=1
  local page_path
  local count
  /bin/mkdir -p "$pages_root"
  while (( page <= 100 )); do
    page_path="$pages_root/$page.json"
    github_api_json \
      "$endpoint?per_page=100&page=$page" \
      "$page_path" \
      "$label page $page"
    count="$(/usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
if not isinstance(value, list) or len(value) > 100:
    raise SystemExit(1)
print(len(value))
' "$page_path")" ||
      fail "GitHub paginated response is invalid for $label"
    (( count < 100 )) && break
    page=$((page + 1))
  done
  (( page <= 100 )) ||
    fail "GitHub pagination exceeded the fail-closed page bound for $label"
  /usr/bin/python3 -I -E -s - "$pages_root" "$output_path" <<'PY' ||
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
values = []
for path in sorted(root.glob("*.json"), key=lambda item: int(item.stem)):
    with path.open("rb") as stream:
        page = json.load(stream)
    if not isinstance(page, list):
        raise SystemExit(1)
    values.extend(page)
with open(sys.argv[2], "x", encoding="utf-8") as stream:
    json.dump(values, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
    fail "could not assemble paginated response for $label"
}

capture_release_history() {
  local manifest_path="$1"
  local expected_draft_id="$2"
  local output_path="$3"
  local history_root="$TEMP_ROOT/history-$RANDOM"
  local manifests_root="$history_root/manifests"
  local combined="$history_root/releases.json"
  local selection="$history_root/manifest-selection.tsv"
  /bin/mkdir -p "$manifests_root"
  fetch_paginated_array \
    "$GITHUB_API_ROOT/releases" \
    "$combined" \
    "immutable release history"
  /usr/bin/python3 -I -E -s "$HISTORY_CONTRACT" select-manifests \
    --releases "$combined" >"$selection" ||
    fail "immutable release manifest selection failed"
  while IFS=$'\t' read -r asset_id asset_size asset_digest; do
    [[ -n "$asset_id" ]] || continue
    github_release_asset_download \
      "$asset_id" "$asset_size" "$asset_digest" \
      "$manifests_root/$asset_id.json" \
      "immutable release manifest $asset_id"
  done <"$selection"
  /usr/bin/python3 -I -E -s "$HISTORY_CONTRACT" analyze \
    --releases "$combined" \
    --manifests "$manifests_root" \
    --current-manifest "$manifest_path" \
    --expected-draft-id "$expected_draft_id" \
    --output "$output_path" ||
    fail "immutable release history, version, build, or rollback binding is invalid"
  local commit
  for commit in ${(@f)$(/usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
for commit in value["commits"]:
    print(commit)
' "$output_path")}; do
    git_safe -C "$ROOT_DIR" merge-base --is-ancestor "$commit" "$HEAD_COMMIT" ||
      fail "immutable release history is not an ancestor of the candidate"
  done
}

validate_remote_annotated_tag() {
  local ref_json="$TEMP_ROOT/remote-tag-ref-$RANDOM.json"
  local tag_json="$TEMP_ROOT/remote-tag-object-$RANDOM.json"
  local tag_object
  github_api_json \
    "$GITHUB_API_ROOT/git/ref/tags/$RELEASE_TAG" \
    "$ref_json" \
    "remote release tag reference"
  tag_object="$(/usr/bin/python3 -I -E -s -c '
import json
import re
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
obj = value.get("object") if isinstance(value, dict) else None
if (
    value.get("ref") != f"refs/tags/{sys.argv[2]}"
    or not isinstance(obj, dict)
    or obj.get("type") != "tag"
    or not isinstance(obj.get("sha"), str)
    or re.fullmatch(r"[0-9a-f]{40}", obj["sha"]) is None
):
    raise SystemExit(1)
print(obj["sha"])
' "$ref_json" "$RELEASE_TAG")" ||
    fail "remote release tag is not an annotated tag"
  github_api_json \
    "$GITHUB_API_ROOT/git/tags/$tag_object" \
    "$tag_json" \
    "remote annotated tag object"
  /usr/bin/python3 -I -E -s -c '
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
obj = value.get("object") if isinstance(value, dict) else None
if (
    value.get("tag") != sys.argv[2]
    or not isinstance(obj, dict)
    or obj.get("type") != "commit"
    or obj.get("sha") != sys.argv[3]
):
    raise SystemExit(1)
' "$tag_json" "$RELEASE_TAG" "$HEAD_COMMIT" ||
    fail "remote annotated release tag does not peel exactly to HEAD"
}

validate_remote_release() {
  local release_json="$1"
  local assets_json="$2"
  local expected_state="$3"
  /usr/bin/python3 -I -E -s - \
    "$release_json" "$assets_json" "$PUBLISH_STAGING" \
    "$GITHUB_REPOSITORY" "$REMOTE_DRAFT_ID" "$RELEASE_TAG" \
    "$VERSION" "$expected_state" "$HEAD_COMMIT" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

release_path, assets_path, root_path, repository, release_id, tag, version, state, commit = sys.argv[1:]
with open(release_path, "rb") as stream:
    release = json.load(stream)
with open(assets_path, "rb") as stream:
    assets = json.load(stream)
root = pathlib.Path(root_path)
api_root = f"https://api.github.com/repos/{repository}"
web_root = f"https://github.com/{repository}"
if (
    not isinstance(release, dict)
    or release.get("id") != int(release_id)
    or release.get("tag_name") != tag
    or release.get("name") != f"Gatebeam {version}"
    or release.get("target_commitish") != commit
    or release.get("prerelease") is not False
    or release.get("url") != f"{api_root}/releases/{release_id}"
    or release.get("assets_url") != f"{api_root}/releases/{release_id}/assets"
):
    raise SystemExit(1)
if state == "draft":
    if release.get("draft") is not True or release.get("immutable") is not False:
        raise SystemExit(2)
elif state == "published":
    if (
        release.get("draft") is not False
        or release.get("immutable") is not True
        or release.get("html_url") != f"{web_root}/releases/tag/{tag}"
    ):
        raise SystemExit(3)
else:
    raise SystemExit(4)
if not isinstance(assets, list):
    raise SystemExit(5)
expected_names = {
    f"Gatebeam-{version}.zip",
    f"Gatebeam-{version}.pkg",
    f"Gatebeam-{version}.dmg",
    "SHA256SUMS",
    "release-manifest.json",
    "candidate-envelope.json",
    "clean-machine-attestation.json",
}
if len(assets) != len(expected_names):
    raise SystemExit(6)
seen_names = set()
seen_ids = set()
for asset in assets:
    if not isinstance(asset, dict):
        raise SystemExit(7)
    name = asset.get("name")
    asset_id = asset.get("id")
    if (
        name not in expected_names
        or name in seen_names
        or not isinstance(asset_id, int)
        or asset_id <= 0
        or asset_id in seen_ids
        or asset.get("state") != "uploaded"
        or asset.get("url") != f"{api_root}/releases/assets/{asset_id}"
        or asset.get("browser_download_url") != f"{web_root}/releases/download/{tag}/{name}"
    ):
        raise SystemExit(8)
    payload = (root / name).read_bytes()
    if (
        asset.get("size") != len(payload)
        or asset.get("digest") != f"sha256:{hashlib.sha256(payload).hexdigest()}"
    ):
        raise SystemExit(9)
    seen_names.add(name)
    seen_ids.add(asset_id)
if seen_names != expected_names:
    raise SystemExit(10)
PY
}

fetch_and_validate_remote_release() {
  local expected_state="$1"
  local release_json="$TEMP_ROOT/remote-release-$expected_state-$RANDOM.json"
  local assets_json="$TEMP_ROOT/remote-assets-$expected_state-$RANDOM.json"
  github_api_json \
    "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID" \
    "$release_json" \
    "remote $expected_state release"
  fetch_paginated_array \
    "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID/assets" \
    "$assets_json" \
    "remote $expected_state release assets"
  validate_remote_release "$release_json" "$assets_json" "$expected_state" ||
    fail "remote release or asset bytes do not match the frozen candidate"
}

draft_id_from_response() {
  local response="$1"
  local body_path="$2"
  /usr/bin/python3 -I -E -s - \
    "$response" "$body_path" "$RELEASE_TAG" "$VERSION" "$HEAD_COMMIT" <<'PY'
import json
import sys
with open(sys.argv[1], "rb") as stream:
    value = json.load(stream)
with open(sys.argv[2], "rb") as stream:
    expected_body = json.load(stream)["body"]
release_id = value.get("id") if isinstance(value, dict) else None
if (
    not isinstance(release_id, int)
    or release_id <= 0
    or value.get("tag_name") != sys.argv[3]
    or value.get("name") != f"Gatebeam {sys.argv[4]}"
    or value.get("target_commitish") != sys.argv[5]
    or value.get("body") != expected_body
    or value.get("draft") is not True
    or value.get("prerelease") is not False
    or value.get("immutable") is not False
):
    raise SystemExit(1)
print(release_id)
PY
}

recover_remote_draft() {
  local body_path="$1"
  local releases_json="$TEMP_ROOT/reconcile-releases-$RANDOM.json"
  local recovered_id
  fetch_paginated_array \
    "$GITHUB_API_ROOT/releases" \
    "$releases_json" \
    "formal draft reconciliation"
  if recovered_id="$(/usr/bin/python3 -I -E -s - \
      "$releases_json" "$body_path" "$RELEASE_TAG" "$VERSION" "$HEAD_COMMIT" <<'PY'
import json
import sys
with open(sys.argv[1], "rb") as stream:
    releases = json.load(stream)
with open(sys.argv[2], "rb") as stream:
    expected_body = json.load(stream)["body"]
drafts = [
    release for release in releases
    if isinstance(release, dict) and release.get("draft") is True
]
matches = [
    release for release in drafts
    if (
        release.get("tag_name") == sys.argv[3]
        and release.get("name") == f"Gatebeam {sys.argv[4]}"
        and release.get("target_commitish") == sys.argv[5]
        and release.get("body") == expected_body
        and release.get("prerelease") is False
        and release.get("immutable") is False
        and isinstance(release.get("id"), int)
        and release["id"] > 0
    )
]
if len(drafts) != 1 or len(matches) != 1:
    raise SystemExit(1)
print(matches[0]["id"])
PY
  )"; then
    REMOTE_DRAFT_ID="$recovered_id"
    return 0
  fi
  return 1
}

create_remote_draft() {
  local body="$TEMP_ROOT/create-release.json"
  local response="$TEMP_ROOT/create-release-response.json"
  local attempt
  local candidate_envelope_sha
  local publication_nonce
  local response_id
  candidate_envelope_sha="$(
    /usr/bin/shasum -a 256 "$PUBLISH_STAGING/candidate-envelope.json" |
      /usr/bin/awk '{print $1}'
  )"
  publication_nonce="$(/usr/bin/uuidgen)" ||
    fail "could not create a publication ownership nonce"
  [[ "$publication_nonce" =~ '^[0-9A-F-]{36}$' ]] ||
    fail "publication ownership nonce is invalid"
  /usr/bin/python3 -I -E -s - \
    "$body" "$RELEASE_TAG" "$VERSION" "$HEAD_COMMIT" \
    "$candidate_envelope_sha" "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
    "$publication_nonce" <<'PY'
import json
import sys
document = {
    "tag_name": sys.argv[2],
    "target_commitish": sys.argv[4],
    "name": f"Gatebeam {sys.argv[3]}",
    "body": (
        "Formal Gatebeam release.\n\n"
        f"Candidate envelope SHA-256: {sys.argv[5]}\n"
        f"Validation run: {sys.argv[6]}\n"
        f"Commit: {sys.argv[4]}\n"
        f"Publication nonce: {sys.argv[7]}\n"
    ),
    "draft": True,
    "prerelease": False,
}
with open(sys.argv[1], "x", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  for attempt in 1 2; do
    if github_api_mutation_json \
        POST "$GITHUB_API_ROOT/releases" "$body" "$response" \
        "formal release draft"; then
      if response_id="$(draft_id_from_response "$response" "$body")"; then
        REMOTE_DRAFT_ID="$response_id"
        return
      fi
    fi
    if recover_remote_draft "$body"; then
      return
    fi
  done
  fail "GitHub draft creation result could not be reconciled safely"
}

uploaded_asset_is_exact() {
  local response="$1"
  local path="$2"
  /usr/bin/python3 -I -E -s - \
    "$response" "$path" "$GITHUB_REPOSITORY" "$RELEASE_TAG" <<'PY'
import hashlib
import json
import pathlib
import sys
with open(sys.argv[1], "rb") as stream:
    asset = json.load(stream)
path = pathlib.Path(sys.argv[2])
repository, tag = sys.argv[3:]
payload = path.read_bytes()
asset_id = asset.get("id") if isinstance(asset, dict) else None
if (
    not isinstance(asset_id, int)
    or asset_id <= 0
    or asset.get("name") != path.name
    or asset.get("state") != "uploaded"
    or asset.get("size") != len(payload)
    or asset.get("digest") != f"sha256:{hashlib.sha256(payload).hexdigest()}"
    or asset.get("url") != f"https://api.github.com/repos/{repository}/releases/assets/{asset_id}"
    or asset.get("browser_download_url")
    != f"https://github.com/{repository}/releases/download/{tag}/{path.name}"
):
    raise SystemExit(1)
PY
}

recover_uploaded_asset() {
  local asset_path="$1"
  local output_path="$2"
  local assets_json="$TEMP_ROOT/reconcile-assets-$RANDOM.json"
  local result
  fetch_paginated_array \
    "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID/assets" \
    "$assets_json" \
    "release asset reconciliation"
  if /usr/bin/python3 -I -E -s - \
      "$assets_json" "$asset_path" "$output_path" \
      "$GITHUB_REPOSITORY" "$RELEASE_TAG" <<'PY'
import hashlib
import json
import pathlib
import sys
with open(sys.argv[1], "rb") as stream:
    assets = json.load(stream)
path = pathlib.Path(sys.argv[2])
payload = path.read_bytes()
expected_digest = f"sha256:{hashlib.sha256(payload).hexdigest()}"
same_name = [
    asset for asset in assets
    if isinstance(asset, dict) and asset.get("name") == path.name
]
matches = [
    asset for asset in same_name
    if (
        isinstance(asset.get("id"), int)
        and asset["id"] > 0
        and asset.get("state") == "uploaded"
        and asset.get("size") == len(payload)
        and asset.get("digest") == expected_digest
        and asset.get("url")
        == f"https://api.github.com/repos/{sys.argv[4]}/releases/assets/{asset['id']}"
        and asset.get("browser_download_url")
        == f"https://github.com/{sys.argv[4]}/releases/download/{sys.argv[5]}/{path.name}"
    )
]
if not same_name:
    raise SystemExit(2)
if len(same_name) != 1 or len(matches) != 1:
    raise SystemExit(3)
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(matches[0], sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  then
    return 0
  else
    result=$?
  fi
  [[ "$result" == "2" ]] && return 1
  fail "remote asset name exists but does not match frozen bytes: ${asset_path:t}"
}

upload_remote_assets() {
  local name
  local response
  local attempt
  for name in \
    "Gatebeam-$VERSION.zip" \
    "Gatebeam-$VERSION.pkg" \
    "Gatebeam-$VERSION.dmg" \
    "SHA256SUMS" \
    "release-manifest.json" \
    "candidate-envelope.json" \
    "clean-machine-attestation.json"
  do
    response="$TEMP_ROOT/upload-${name//[^A-Za-z0-9]/_}.json"
    for attempt in 1 2; do
      if github_release_asset_upload \
          "$REMOTE_DRAFT_ID" "$PUBLISH_STAGING/$name" "$response" "$name" &&
          uploaded_asset_is_exact "$response" "$PUBLISH_STAGING/$name"; then
        break
      fi
      if recover_uploaded_asset "$PUBLISH_STAGING/$name" "$response"; then
        break
      fi
      (( attempt < 2 )) ||
        fail "GitHub asset upload result could not be reconciled safely: $name"
    done
    uploaded_asset_is_exact "$response" "$PUBLISH_STAGING/$name" ||
      fail "GitHub asset response did not bind the exact frozen bytes: $name"
  done
}

publish_remote_draft() {
  local body="$TEMP_ROOT/publish-release.json"
  local response="$TEMP_ROOT/publish-release-response.json"
  local release_json
  local assets_json
  local state
  local attempt
  print -r -- '{"draft":false}' >"$body"
  for attempt in 1 2; do
    github_api_mutation_json \
      PATCH "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID" \
      "$body" "$response" "immutable formal release publication" || true
    release_json="$TEMP_ROOT/reconcile-publish-release-$attempt.json"
    assets_json="$TEMP_ROOT/reconcile-publish-assets-$attempt.json"
    github_api_json \
      "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID" \
      "$release_json" \
      "formal publication reconciliation"
    fetch_paginated_array \
      "$GITHUB_API_ROOT/releases/$REMOTE_DRAFT_ID/assets" \
      "$assets_json" \
      "formal publication asset reconciliation"
    if validate_remote_release "$release_json" "$assets_json" published; then
      REMOTE_PUBLISHED=1
      return
    fi
    if validate_remote_release "$release_json" "$assets_json" draft; then
      continue
    fi
    fail "GitHub publication result is neither the exact draft nor immutable release"
  done
  fail "GitHub publication response loss could not be reconciled safely"
}

inject_test_failure() {
  local point="$1"
  [[ -z "$TEST_FAILURE_POINT" || "$TEST_FAILURE_POINT" != "$point" ]] &&
    return
  [[ "$TEST_MODE" == "1" && "$ROOT_DIR" == /private/tmp/* ]] ||
    fail "release failure injection is restricted to /private/tmp fixtures"
  fail "injected release failure at $point"
}

sanitize_environment
trap 'cleanup' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

require_environment GATEBEAM_RELEASE_CI_RUN_ID
require_environment GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID
validate_run_id "$GATEBEAM_RELEASE_CI_RUN_ID" "GATEBEAM_RELEASE_CI_RUN_ID"
validate_run_id \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID"
[[ "$TEST_MODE" == "0" || "$TEST_MODE" == "1" ]] ||
  fail "GATEBEAM_RELEASE_TEST_MODE must be 0 or 1"
[[ -z "$TEST_FAILURE_POINT" || "$TEST_FAILURE_POINT" == "before-publish" ]] ||
  fail "GATEBEAM_RELEASE_TEST_FAILURE_POINT is invalid"
if [[ "$TEST_MODE" == "1" || -n "$TEST_TOOL_DIR" ]]; then
  validate_fixture_mode
fi
CURL="$(tool_path curl /usr/bin/curl)"

[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" &&
    -f "$CONTRACT" && ! -L "$CONTRACT" &&
    -f "$HISTORY_CONTRACT" && ! -L "$HISTORY_CONTRACT" ]] ||
  fail "release metadata or artifact contract is missing or unsafe"
VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"
)" || fail "could not read Gatebeam version"
BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST"
)" || fail "could not read Gatebeam bundle identifier"
[[ "$VERSION" =~ '^(0|[1-9][0-9]*)([.](0|[1-9][0-9]*)){2}$' &&
    "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] ||
  fail "Gatebeam release identity is invalid"

if [[ -e "$DIST_DIR" || -L "$DIST_DIR" ]]; then
  assert_safe_dist
else
  /bin/mkdir "$DIST_DIR" ||
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
[[ "$(git_safe -C "$ROOT_DIR" cat-file -t "refs/tags/$RELEASE_TAG" 2>/dev/null)" == "tag" ]] ||
  fail "$RELEASE_TAG must be an annotated tag"
[[ "$(git_safe -C "$ROOT_DIR" rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}")" ==
    "$HEAD_COMMIT" ]] ||
  fail "$RELEASE_TAG does not point exactly to HEAD"
validate_publisher_context
HEAD_AND_PARENTS=(${(s: :)$(git_safe -C "$ROOT_DIR" rev-list --parents -n 1 "$HEAD_COMMIT")})
[[ ${#HEAD_AND_PARENTS[@]} -eq 3 ]] ||
  fail "formal release HEAD must be a standard merge commit with exactly two parents"

PUBLISH_LOCK="$DIST_DIR/.formal-release.lock"
/bin/mkdir "$PUBLISH_LOCK" 2>/dev/null ||
  fail "another formal release is active or left a stale lock: $PUBLISH_LOCK"
TEMP_ROOT="$(/usr/bin/mktemp -d "/private/tmp/gatebeam-formal-publish.XXXXXX")"
prepare_github_auth
validate_immutable_release_policy
validate_ci_evidence "$GATEBEAM_RELEASE_CI_RUN_ID"

RUN_CONTEXT="$TEMP_ROOT/final-run-context.json"
ARTIFACT_SELECTION="$TEMP_ROOT/final-artifacts.json"
validate_final_artifact_run \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "$RUN_CONTEXT"
select_run_artifacts \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "$RUN_CONTEXT" \
  "$ARTIFACT_SELECTION"

REPOSITORY_ID="$(json_field "$RUN_CONTEXT" repositoryId)"
RUN_ATTEMPT="$(json_field "$RUN_CONTEXT" runAttempt)"
WORKFLOW_REF="$(json_field "$RUN_CONTEXT" workflowRef)"
WORKFLOW_SHA="$(json_field "$RUN_CONTEXT" workflowSHA)"
CANDIDATE_NAME="$(json_field "$RUN_CONTEXT" candidateArtifactName)"
ATTESTATION_NAME="$(json_field "$RUN_CONTEXT" attestationArtifactName)"
CANDIDATE_ID="$(json_field "$ARTIFACT_SELECTION" candidate.id)"
CANDIDATE_DIGEST="$(json_field "$ARTIFACT_SELECTION" candidate.digest)"
ATTESTATION_ID="$(json_field "$ARTIFACT_SELECTION" attestation.id)"
ATTESTATION_DIGEST="$(json_field "$ARTIFACT_SELECTION" attestation.digest)"

CANDIDATE_ARCHIVE="$TEMP_ROOT/candidate-artifact.zip"
ATTESTATION_ARCHIVE="$TEMP_ROOT/attestation-artifact.zip"
github_artifact_download \
  "$CANDIDATE_ID" "$CANDIDATE_DIGEST" \
  "$CANDIDATE_ARCHIVE" "final candidate"
github_artifact_download \
  "$ATTESTATION_ID" "$ATTESTATION_DIGEST" \
  "$ATTESTATION_ARCHIVE" "clean-machine attestation"

CANDIDATE_ROOT="$TEMP_ROOT/candidate"
ATTESTATION_ROOT="$TEMP_ROOT/attestation"
/usr/bin/python3 -I -E -s "$CONTRACT" extract \
  --archive "$CANDIDATE_ARCHIVE" \
  --output "$CANDIDATE_ROOT" \
  --expected-digest "$CANDIDATE_DIGEST" \
  --kind candidate ||
  fail "final candidate transport archive is unsafe"
/usr/bin/python3 -I -E -s "$CONTRACT" extract \
  --archive "$ATTESTATION_ARCHIVE" \
  --output "$ATTESTATION_ROOT" \
  --expected-digest "$ATTESTATION_DIGEST" \
  --kind attestation ||
  fail "clean-machine attestation transport archive is unsafe"
ATTESTATION_PATH="$ATTESTATION_ROOT/clean-machine-attestation.json"
[[ -f "$ATTESTATION_PATH" && ! -L "$ATTESTATION_PATH" &&
    "$(/usr/bin/find "$ATTESTATION_ROOT" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "1" ]] ||
  fail "clean-machine attestation artifact has missing or extra files"

typeset -a CONTRACT_CONTEXT
CONTRACT_CONTEXT=(
  --repository-id "$REPOSITORY_ID"
  --workflow-ref "$WORKFLOW_REF"
  --workflow-sha "$WORKFLOW_SHA"
  --run-id "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID"
  --run-attempt "$RUN_ATTEMPT"
  --commit "$HEAD_COMMIT"
  --tag "$RELEASE_TAG"
  --artifact-name "$CANDIDATE_NAME"
  --attestation-name "$ATTESTATION_NAME"
)
/usr/bin/python3 -I -E -s "$CONTRACT" verify-attestation \
  --root "$CANDIDATE_ROOT" \
  --attestation "$ATTESTATION_PATH" \
  --artifact-id "$CANDIDATE_ID" \
  --artifact-digest "$CANDIDATE_DIGEST" \
  "${CONTRACT_CONTEXT[@]}" ||
  fail "clean-machine attestation does not authorize these exact candidate bytes"

INITIAL_HISTORY="$TEMP_ROOT/initial-history.json"
capture_release_history \
  "$CANDIDATE_ROOT/release-manifest.json" \
  0 \
  "$INITIAL_HISTORY"
validate_remote_annotated_tag

assert_safe_dist
PUBLISH_STAGING="$(/usr/bin/mktemp -d "$DIST_DIR/.release-$VERSION.XXXXXX")"
for name in \
  "Gatebeam-$VERSION.zip" \
  "Gatebeam-$VERSION.pkg" \
  "Gatebeam-$VERSION.dmg" \
  "SHA256SUMS" \
  "release-manifest.json" \
  "candidate-envelope.json"
do
  [[ -f "$CANDIDATE_ROOT/$name" && ! -L "$CANDIDATE_ROOT/$name" &&
      "$(/usr/bin/stat -f '%l' "$CANDIDATE_ROOT/$name")" == "1" ]] ||
    fail "validated candidate file became unsafe before publication: $name"
  /bin/cp -p -- "$CANDIDATE_ROOT/$name" "$PUBLISH_STAGING/$name"
  [[ "$(/usr/bin/shasum -a 256 "$CANDIDATE_ROOT/$name" | /usr/bin/awk '{print $1}')" ==
      "$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/$name" | /usr/bin/awk '{print $1}')" ]] ||
    fail "staging changed validated candidate bytes: $name"
done
[[ -f "$ATTESTATION_PATH" && ! -L "$ATTESTATION_PATH" &&
    "$(/usr/bin/stat -f '%l' "$ATTESTATION_PATH")" == "1" ]] ||
  fail "validated attestation became unsafe before publication"
/bin/cp -p -- "$ATTESTATION_PATH" \
  "$PUBLISH_STAGING/clean-machine-attestation.json"
[[ "$(/usr/bin/shasum -a 256 "$ATTESTATION_PATH" | /usr/bin/awk '{print $1}')" ==
    "$(/usr/bin/shasum -a 256 "$PUBLISH_STAGING/clean-machine-attestation.json" | /usr/bin/awk '{print $1}')" ]] ||
  fail "staging changed validated attestation bytes"

inject_test_failure before-publish

create_remote_draft
LOCKED_HISTORY="$TEMP_ROOT/locked-history.json"
capture_release_history \
  "$CANDIDATE_ROOT/release-manifest.json" \
  "$REMOTE_DRAFT_ID" \
  "$LOCKED_HISTORY"
[[ "$(json_field "$INITIAL_HISTORY" snapshotSHA256)" ==
    "$(json_field "$LOCKED_HISTORY" snapshotSHA256)" ]] ||
  fail "immutable release history changed while acquiring the remote publication lock"

upload_remote_assets
fetch_and_validate_remote_release draft

validate_remote_annotated_tag
validate_immutable_release_policy
validate_ci_evidence "$GATEBEAM_RELEASE_CI_RUN_ID"
FINAL_RUN_CONTEXT="$TEMP_ROOT/final-run-context-recheck.json"
FINAL_ARTIFACT_SELECTION="$TEMP_ROOT/final-artifacts-recheck.json"
validate_final_artifact_run \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "$FINAL_RUN_CONTEXT"
select_run_artifacts \
  "$GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID" \
  "$FINAL_RUN_CONTEXT" \
  "$FINAL_ARTIFACT_SELECTION"
/usr/bin/cmp -s "$RUN_CONTEXT" "$FINAL_RUN_CONTEXT" &&
  /usr/bin/cmp -s "$ARTIFACT_SELECTION" "$FINAL_ARTIFACT_SELECTION" ||
  fail "workflow run or artifact provenance changed before publication"
/usr/bin/python3 -I -E -s "$CONTRACT" verify-attestation \
  --root "$CANDIDATE_ROOT" \
  --attestation "$ATTESTATION_PATH" \
  --artifact-id "$CANDIDATE_ID" \
  --artifact-digest "$CANDIDATE_DIGEST" \
  "${CONTRACT_CONTEXT[@]}" ||
  fail "attestation no longer authorizes the frozen candidate"
FINAL_HISTORY="$TEMP_ROOT/final-history.json"
capture_release_history \
  "$CANDIDATE_ROOT/release-manifest.json" \
  "$REMOTE_DRAFT_ID" \
  "$FINAL_HISTORY"
[[ "$(json_field "$INITIAL_HISTORY" snapshotSHA256)" ==
    "$(json_field "$FINAL_HISTORY" snapshotSHA256)" ]] ||
  fail "immutable release history changed before publication"

publish_remote_draft
validate_remote_annotated_tag

assert_safe_dist
[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  fail "release destination already exists and will not be overwritten: $RELEASE_DIR"
/bin/mv -- "$PUBLISH_STAGING" "$RELEASE_DIR"
PUBLISH_STAGING=""
/bin/rmdir -- "$PUBLISH_LOCK"
PUBLISH_LOCK=""

print -r -- "Formal release published immutably from validated candidate bytes: $RELEASE_DIR"
