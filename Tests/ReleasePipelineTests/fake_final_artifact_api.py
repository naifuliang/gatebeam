#!/usr/bin/python3
"""Fake GitHub API used only by marked formal-publisher fixtures."""

import hashlib
import io
import json
import os
import pathlib
import re
import sys
import zipfile
import urllib.parse
import fcntl
from contextlib import contextmanager


REPOSITORY = "naifuliang/gatebeam"
REPOSITORY_ID = 987654321
API_ROOT = f"https://api.github.com/repos/{REPOSITORY}"
WEB_ROOT = f"https://github.com/{REPOSITORY}"
CI_STEPS = [
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
]
BUILD_STEPS = [
    "Check out release source",
    "Verify release invocation",
    "Configure signing and notarization credentials",
    "Prepare hash-bound final candidate",
    "Upload final candidate",
    "Cleanup signing credentials",
]
CLEAN_STEPS = [
    "Check out release source",
    "Download exact final candidate",
    "Validate signature, notarization, install, upgrade, rollback, and uninstall",
    "Upload clean-machine attestation",
]
PUBLISHER_STEPS = [
    "Check out release source for publisher",
    "Configure private publisher token",
]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(22)


def root():
    call_log = pathlib.Path(os.environ["GATEBEAM_FAKE_CALL_LOG"])
    fixture = call_log.parent.resolve()
    marker = fixture / ".gatebeam-release-test-fixture"
    if (
        not str(fixture).startswith("/private/tmp/")
        or not marker.is_file()
        or marker.is_symlink()
        or marker.read_text(encoding="utf-8").strip()
        != "Gatebeam release test fixture v1"
    ):
        fail("unsafe final artifact API fixture")
    return fixture


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def candidate_names(fixture, attempt=1):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    commit = metadata["commit"]
    tag = metadata["tag"]
    run_id = metadata["cleanRunId"]
    return (
        f"gatebeam-final-candidate-{tag}-{commit}-run{run_id}-attempt{attempt}",
        f"gatebeam-clean-machine-attestation-{tag}-{commit}-run{run_id}-attempt{attempt}",
    )


def workflow_run(fixture, run_id, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    clean = run_id == metadata["cleanRunId"]
    commit = metadata["commit"]
    repository_id = REPOSITORY_ID
    repository_name = REPOSITORY
    event = "workflow_dispatch" if clean else "push"
    name = "Release final-artifact validation" if clean else "CI"
    path = (
        ".github/workflows/release-validation.yml"
        if clean
        else ".github/workflows/ci.yml"
    )
    head_branch = metadata["tag"] if clean else "main"
    attempt = 1
    if scenario == "wrong-final-repository" and clean:
        repository_name = "attacker/gatebeam"
    if scenario == "wrong-final-repository-id" and clean:
        repository_id = 42
    if scenario == "wrong-final-event" and clean:
        event = "push"
    if scenario == "wrong-final-head" and clean:
        commit = "f" * 40
    if scenario == "wrong-final-tag" and clean:
        head_branch = "v9.9.9"
    if scenario == "replayed-attempt" and clean:
        attempt = 2
    run_url = f"{API_ROOT}/actions/runs/{run_id}"
    status = "in_progress" if clean else "completed"
    conclusion = None if clean else "success"
    if scenario == "final-run-completed" and clean:
        status = "completed"
        conclusion = "success"
    return {
        "id": int(run_id),
        "name": name,
        "path": f"{path}@refs/tags/{metadata['tag']}" if clean else f"{path}@refs/heads/main",
        "event": event,
        "head_sha": commit,
        "head_branch": head_branch,
        "run_attempt": attempt,
        "status": status,
        "conclusion": conclusion,
        "url": run_url,
        "html_url": f"{WEB_ROOT}/actions/runs/{run_id}",
        "jobs_url": f"{run_url}/jobs",
        "repository": {
            "id": repository_id,
            "full_name": repository_name,
            "private": False,
        },
    }


def workflow_jobs(fixture, run_id, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    run = workflow_run(fixture, run_id, scenario)
    clean = run_id == metadata["cleanRunId"]
    if not clean:
        jobs = [
            {
                "id": 701,
                "name": "Test, isolate, and build Gatebeam",
                "head_sha": run["head_sha"],
                "status": "completed",
                "conclusion": "success",
                "workflow_name": run["name"],
                "run_url": run["url"],
                "steps": [
                    {
                        "name": name,
                        "status": "completed",
                        "conclusion": "success",
                    }
                    for name in CI_STEPS
                ],
            }
        ]
        return {"total_count": 1, "jobs": jobs}

    clean_steps = list(CLEAN_STEPS)
    if scenario == "missing-final-step":
        clean_steps.remove("Upload clean-machine attestation")
    jobs = [
        {
            "id": 702,
            "name": "Build, sign, notarize, and freeze final candidate",
            "head_sha": run["head_sha"],
            "status": "completed",
            "conclusion": "success",
            "workflow_name": run["name"],
            "run_url": run["url"],
            "steps": [
                {
                    "name": name,
                    "status": "completed",
                    "conclusion": "success",
                }
                for name in BUILD_STEPS
            ],
        },
        {
            "id": 703,
            "name": "Validate frozen candidate on clean macOS",
            "head_sha": run["head_sha"],
            "status": "completed",
            "conclusion": "success",
            "workflow_name": run["name"],
            "run_url": run["url"],
            "steps": [
                {
                    "name": name,
                    "status": "completed",
                    "conclusion": "success",
                }
                for name in clean_steps
            ],
        },
        {
            "id": 704,
            "name": "Publish exact validated bytes immutably",
            "head_sha": run["head_sha"],
            "status": "in_progress",
            "conclusion": None,
            "workflow_name": run["name"],
            "run_url": run["url"],
            "steps": [
                *[
                    {
                        "name": name,
                        "status": "completed",
                        "conclusion": "success",
                    }
                    for name in PUBLISHER_STEPS
                ],
                {
                    "name": "Publish exact validated bytes immutably",
                    "status": "in_progress",
                    "conclusion": None,
                },
            ],
        },
    ]
    if scenario == "missing-final-job":
        jobs.pop()
    return {"total_count": len(jobs), "jobs": jobs}


def zip_with_mutated_candidate(payload):
    source = io.BytesIO(payload)
    output = io.BytesIO()
    with zipfile.ZipFile(source, "r") as original, zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_STORED
    ) as changed:
        for info in original.infolist():
            data = original.read(info)
            if info.filename.endswith(".pkg"):
                data += b"tampered\n"
            changed.writestr(info, data)
    return output.getvalue()


def traversal_candidate():
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as bundle:
        entry = zipfile.ZipInfo("../outside", date_time=(2026, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = 0o100600 << 16
        bundle.writestr(entry, b"escape")
    return output.getvalue()


def zip_with_mutated_attestation(payload):
    source = io.BytesIO(payload)
    output = io.BytesIO()
    with zipfile.ZipFile(source, "r") as original, zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_STORED
    ) as changed:
        for info in original.infolist():
            data = original.read(info)
            if info.filename == "clean-machine-attestation.json":
                document = json.loads(data)
                document["result"] = "Failed"
                data = (
                    json.dumps(document, sort_keys=True, separators=(",", ":"))
                    + "\n"
                ).encode("utf-8")
            changed.writestr(info, data)
    return output.getvalue()


def artifact_payloads(fixture, scenario):
    candidate = (fixture / "fake-api" / "candidate.zip").read_bytes()
    attestation = (fixture / "fake-api" / "attestation.zip").read_bytes()
    if scenario == "tampered-candidate":
        candidate = zip_with_mutated_candidate(candidate)
    elif scenario == "candidate-path-traversal":
        candidate = traversal_candidate()
    if scenario == "tampered-attestation":
        attestation = zip_with_mutated_attestation(attestation)
    return candidate, attestation


def artifacts(fixture, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    candidate_payload, attestation_payload = artifact_payloads(fixture, scenario)
    candidate_name, attestation_name = candidate_names(fixture)
    run_id = metadata["cleanRunId"]

    def artifact(artifact_id, name, payload):
        workflow_run_id = (
            999999 if scenario == "cross-run-artifact" and artifact_id == 201
            else int(run_id)
        )
        digest = sha256(payload)
        if scenario == "wrong-protected-digest" and artifact_id == 201:
            digest = "0" * 64
        return {
            "id": artifact_id,
            "name": name,
            "size_in_bytes": len(payload),
            "digest": f"sha256:{digest}",
            "expired": scenario == "expired-artifact" and artifact_id == 201,
            "url": f"{API_ROOT}/actions/artifacts/{artifact_id}",
            "archive_download_url": f"{API_ROOT}/actions/artifacts/{artifact_id}/zip",
            "workflow_run": {
                "id": workflow_run_id,
                "repository_id": REPOSITORY_ID,
                "head_repository_id": REPOSITORY_ID,
                "head_sha": metadata["commit"],
            },
        }

    values = [
        artifact(201, candidate_name, candidate_payload),
        artifact(202, attestation_name, attestation_payload),
    ]
    if scenario == "duplicate-candidate-artifact":
        values.append(artifact(203, candidate_name, candidate_payload))
    return {"total_count": len(values), "artifacts": values}


def response(fixture, url, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    ci_run_id = metadata["ciRunId"]
    clean_run_id = metadata["cleanRunId"]
    candidate_payload, attestation_payload = artifact_payloads(fixture, scenario)
    if url == f"{API_ROOT}/immutable-releases":
        return {"enabled": True}, False
    if url == f"{API_ROOT}/actions/runs/{ci_run_id}":
        return workflow_run(fixture, ci_run_id, scenario), False
    if url == f"{API_ROOT}/actions/runs/{ci_run_id}/jobs?per_page=100":
        return workflow_jobs(fixture, ci_run_id, scenario), False
    if url == f"{API_ROOT}/actions/runs/{clean_run_id}":
        return workflow_run(fixture, clean_run_id, scenario), False
    if url == f"{API_ROOT}/actions/runs/{clean_run_id}/jobs?per_page=100":
        return workflow_jobs(fixture, clean_run_id, scenario), False
    if url == f"{API_ROOT}/actions/runs/{clean_run_id}/artifacts?per_page=100":
        return artifacts(fixture, scenario), False
    if url == f"{API_ROOT}/actions/artifacts/201/zip":
        return candidate_payload, True
    if url == f"{API_ROOT}/actions/artifacts/202/zip":
        return attestation_payload, True
    if url == f"{API_ROOT}/releases?per_page=1":
        return ([{"id": 1}] if scenario == "bootstrap-existing-release" else []), False
    fail(f"unexpected final artifact API URL: {url}")


def state_path(fixture):
    return remote_state_root(fixture) / "remote-release-state.json"


def remote_state_root(fixture):
    configured = os.environ.get("GATEBEAM_FAKE_REMOTE_STATE_DIR", "")
    if not configured:
        return fixture / "fake-api"
    path = pathlib.Path(configured).resolve()
    marker = path / ".gatebeam-shared-remote-fixture"
    if (
        not str(path).startswith("/private/tmp/")
        or not path.is_dir()
        or not marker.is_file()
        or marker.is_symlink()
        or marker.read_text(encoding="utf-8").strip()
        != "Gatebeam shared remote fixture v1"
    ):
        fail("unsafe shared remote state fixture")
    return path


@contextmanager
def remote_lock(fixture):
    path = remote_state_root(fixture) / ".remote-api.lock"
    with path.open("a+b") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def load_state(fixture):
    path = state_path(fixture)
    if not path.exists():
        return {"release": None, "assets": [], "nextAssetId": 9001}
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(fixture, state):
    state_path(fixture).write_text(
        json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def release_document(fixture, state):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    release = state["release"]
    if release is None:
        return None
    release_id = release["id"]
    tag = metadata["tag"]
    return {
        "id": release_id,
        "url": f"{API_ROOT}/releases/{release_id}",
        "assets_url": f"{API_ROOT}/releases/{release_id}/assets",
        "upload_url": (
            f"https://uploads.github.com/repos/{REPOSITORY}/releases/"
            f"{release_id}/assets{{?name,label}}"
        ),
        "html_url": f"{WEB_ROOT}/releases/tag/{tag}",
        "tag_name": tag,
        "target_commitish": metadata["commit"],
        "name": "Gatebeam 0.5.0",
        "body": release["body"],
        "draft": release["draft"],
        "prerelease": False,
        "immutable": release["immutable"],
        "assets": state["assets"],
    }


def remote_asset(fixture, state, name, payload, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    asset_id = state["nextAssetId"]
    state["nextAssetId"] += 1
    digest = sha256(payload)
    if scenario == "remote-upload-digest" and name == "SHA256SUMS":
        digest = "0" * 64
    return {
        "id": asset_id,
        "url": f"{API_ROOT}/releases/assets/{asset_id}",
        "browser_download_url": (
            f"{WEB_ROOT}/releases/download/{metadata['tag']}/{name}"
        ),
        "name": name,
        "state": "uploaded",
        "size": len(payload),
        "digest": f"sha256:{digest}",
    }


def remote_response(fixture, url, method, body_path, upload_path, scenario):
    metadata = json.loads(
        (fixture / "fake-api" / "metadata.json").read_text(encoding="utf-8")
    )
    state = load_state(fixture)
    release = release_document(fixture, state)
    if url.startswith(f"{API_ROOT}/releases?per_page=100&page=") and method == "GET":
        page = int(url.rsplit("=", 1)[1])
        values = []
        paginated = scenario == "post-loss-page2"
        if page == 1 and paginated:
            values.extend(
                {
                    "id": 10000 + index,
                    "tag_name": f"note-{index}",
                    "name": f"Historical note {index}",
                    "draft": False,
                    "prerelease": False,
                    "immutable": True,
                    "assets": [],
                }
                for index in range(100)
            )
        if ((page == 2 and paginated) or (page == 1 and not paginated)) and release is not None:
            values.append(release)
        if scenario == "bootstrap-existing-release" and page == 1:
            values.append(
                {
                    "id": 7001,
                    "tag_name": "v0.4.0",
                    "draft": False,
                    "prerelease": False,
                    "immutable": True,
                    "assets": [],
                }
            )
        if (
            scenario in ("remote-lock-race", "remote-lock-race-delete-loss")
            and page == 1
            and release is not None
            and release["draft"]
        ):
            competing = dict(release)
            competing["id"] = 808080
            competing["tag_name"] = "v9.9.9"
            competing["name"] = "Gatebeam 9.9.9"
            values.append(competing)
        if (
            scenario == "remote-lock-late"
            and page == 1
            and release is not None
            and release["draft"]
            and len(state["assets"]) == 7
        ):
            competing = dict(release)
            competing["id"] = 808081
            competing["tag_name"] = "v9.9.8"
            competing["name"] = "Gatebeam 9.9.8"
            values.append(competing)
        return values, False
    if url == f"{API_ROOT}/git/ref/tags/{metadata['tag']}" and method == "GET":
        tag_sha = "e" * 40
        return {
            "ref": f"refs/tags/{metadata['tag']}",
            "object": {"type": "tag", "sha": tag_sha},
        }, False
    if url == f"{API_ROOT}/git/tags/{'e' * 40}" and method == "GET":
        commit = "f" * 40 if scenario == "remote-tag-moved" else metadata["commit"]
        return {
            "tag": metadata["tag"],
            "object": {"type": "commit", "sha": commit},
        }, False
    if url == f"{API_ROOT}/releases" and method == "POST":
        if state["release"] is not None:
            fail("duplicate fake release draft")
        body = json.loads(body_path.read_text(encoding="utf-8"))
        state["release"] = {
            "id": 8001,
            "draft": True,
            "immutable": False,
            "body": body["body"],
        }
        save_state(fixture, state)
        return release_document(fixture, state), False
    upload_match = re.fullmatch(
        rf"https://uploads[.]github[.]com/repos/{re.escape(REPOSITORY)}/"
        r"releases/8001/assets[?]name=([A-Za-z0-9._-]+)",
        url,
    )
    if upload_match and method == "POST":
        name = urllib.parse.unquote(upload_match.group(1))
        payload = upload_path.read_bytes()
        asset = remote_asset(fixture, state, name, payload, scenario)
        state["assets"].append(asset)
        (remote_state_root(fixture) / f"uploaded-{name}").write_bytes(payload)
        save_state(fixture, state)
        return asset, False
    if url == f"{API_ROOT}/releases/8001" and method == "PATCH":
        body = json.loads(body_path.read_text(encoding="utf-8"))
        if body != {"draft": False}:
            fail("invalid fake publish body")
        state["release"]["draft"] = False
        state["release"]["immutable"] = scenario != "remote-publish-mutable"
        save_state(fixture, state)
        return release_document(fixture, state), False
    if url == f"{API_ROOT}/releases/8001" and method == "GET":
        if release is None:
            fail("fake release does not exist")
        return release, False
    if (
        url.startswith(f"{API_ROOT}/releases/8001/assets?per_page=100&page=")
        and method == "GET"
    ):
        page = int(url.rsplit("=", 1)[1])
        return (state["assets"] if page == 1 else []), False
    if url == f"{API_ROOT}/releases/8001" and method == "DELETE":
        state["release"] = None
        state["assets"] = []
        save_state(fixture, state)
        return b"", True
    return None


def main():
    fixture = root()
    scenario = os.environ.get("GATEBEAM_FAKE_FINAL_SCENARIO", "success")
    arguments = sys.argv[1:]
    if (
        len(arguments) != 3
        or arguments[0] != "--disable"
        or arguments[1] != "--config"
    ):
        fail("fake final API requires only --disable and a private config")
    config_path = pathlib.Path(arguments[2])
    entry = config_path.lstat()
    if (
        not config_path.is_file()
        or config_path.is_symlink()
        or entry.st_mode & 0o777 != 0o600
        or entry.st_nlink != 1
    ):
        fail("fake final API config is unsafe")
    output_path = None
    url = None
    headers = []
    method = "GET"
    body_path = None
    upload_path = None
    for line in config_path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([a-z-]+) = \"(.*)\"", line)
        if match is None:
            continue
        option, value = match.groups()
        if option == "output":
            output_path = pathlib.Path(value)
        elif option == "url":
            url = value
        elif option == "header":
            headers.append(value)
        elif option == "request":
            method = value
        elif option == "data-binary":
            if not value.startswith("@"):
                fail("fake final API requires a file-backed JSON body")
            body_path = pathlib.Path(value[1:])
        elif option == "upload-file":
            upload_path = pathlib.Path(value)
    if output_path is None or url is None:
        fail("fake final API config omitted URL or output")
    token_file = pathlib.Path(os.environ["GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN_FILE"])
    token = token_file.read_text(encoding="utf-8").strip()
    if [header for header in headers if header.startswith("Authorization:")] != [
        f"Authorization: Bearer {token}"
    ]:
        fail("fake final API authentication failed")
    if any(token in argument for argument in sys.argv):
        fail("GitHub token leaked through final API argv")
    if any(token in key or token in value for key, value in os.environ.items()):
        fail("GitHub token leaked through final API environment")
    with open(os.environ["GATEBEAM_FAKE_CALL_LOG"], "a", encoding="utf-8") as stream:
        stream.write(f"github {url}\n")
    mutation_error = re.fullmatch(
        r"(post|upload|patch)-http-(401|403|404|500)",
        scenario,
    )
    mutation_status = int(mutation_error.group(2)) if mutation_error else None
    mutation_kind = mutation_error.group(1) if mutation_error else None
    mutation_matches = (
        mutation_kind == "post"
        and method == "POST"
        and url == f"{API_ROOT}/releases"
    ) or (
        mutation_kind == "upload"
        and method == "POST"
        and url.endswith("assets?name=Gatebeam-0.5.0.zip")
    ) or (
        mutation_kind == "patch"
        and method == "PATCH"
        and url == f"{API_ROOT}/releases/8001"
    )
    if mutation_status is not None and mutation_matches:
        output_path.write_text(
            json.dumps({"message": f"fixture HTTP {mutation_status}"}),
            encoding="utf-8",
        )
        print(f"{mutation_status:03d}", end="")
        raise SystemExit(22)
    with remote_lock(fixture):
        remote = remote_response(
            fixture,
            url,
            method,
            body_path,
            upload_path,
            scenario,
        )
    if remote is None:
        if method != "GET":
            fail(f"unexpected final artifact API mutation: {method} {url}")
        payload, binary = response(fixture, url, scenario)
    else:
        payload, binary = remote
    applied_5xx = (
        scenario == "post-http-500-applied"
        and method == "POST"
        and url == f"{API_ROOT}/releases"
    ) or (
        scenario == "upload-http-500-applied"
        and method == "POST"
        and url.endswith("assets?name=Gatebeam-0.5.0.zip")
    ) or (
        scenario == "patch-http-500-applied"
        and method == "PATCH"
        and url == f"{API_ROOT}/releases/8001"
    )
    if applied_5xx:
        output_path.write_text(
            json.dumps({"message": "fixture applied operation before HTTP 500"}),
            encoding="utf-8",
        )
        print("500", end="")
        raise SystemExit(22)
    response_lost = (
        scenario in ("post-response-loss", "post-loss-page2")
        and method == "POST"
        and url == f"{API_ROOT}/releases"
    ) or (
        scenario == "upload-response-loss"
        and method == "POST"
        and url.endswith("assets?name=Gatebeam-0.5.0.zip")
    ) or (
        scenario == "patch-response-loss"
        and method == "PATCH"
        and url == f"{API_ROOT}/releases/8001"
    ) or (
        scenario == "remote-lock-race-delete-loss"
        and method == "DELETE"
        and url == f"{API_ROOT}/releases/8001"
    )
    if response_lost:
        print("000", end="")
        raise SystemExit(52)
    if binary:
        output_path.write_bytes(payload)
    else:
        output_path.write_text(
            json.dumps(payload, sort_keys=True),
            encoding="utf-8",
        )
    if method == "DELETE":
        print("204", end="")
    elif method == "POST":
        print("201", end="")
    else:
        print("200", end="")


if __name__ == "__main__":
    main()
