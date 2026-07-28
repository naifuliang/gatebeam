#!/usr/bin/python3
import hashlib
import json
import os
import pathlib
import subprocess
import sys


REPOSITORY = "naifuliang/gatebeam"
API_ROOT = f"https://api.github.com/repos/{REPOSITORY}"
WEB_ROOT = f"https://github.com/{REPOSITORY}"
CI_STEPS = [
    "Check out repository",
    "Run backend tests",
    "Run proxy policy tests",
    "Run integration contract tests",
    "Run integration contract tests with Thread Sanitizer",
    "Run formal release pipeline tests",
    "Verify Keychain and code-signing identity",
    "Run upgrade compatibility tests",
    "Run UI validation isolation tests",
    "Validate build assets",
    "Build complete app",
    "Verify app signature",
    "Scan source and app for private material",
    "Check committed patch whitespace",
]
CLEAN_STEPS = [
    "Check out repository",
    "Build and validate isolated install, upgrade, rollback, and uninstall",
]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(22)


def fixture_root():
    call_log = pathlib.Path(os.environ["GATEBEAM_FAKE_CALL_LOG"])
    root = call_log.parent.resolve()
    marker = root / ".gatebeam-release-test-fixture"
    if (
        not str(root).startswith("/private/tmp/")
        or not marker.is_file()
        or marker.is_symlink()
        or marker.read_text(encoding="utf-8").strip()
        != "Gatebeam release test fixture v1"
    ):
        fail("unsafe fake GitHub fixture")
    return root


def git_revision(root, revision):
    return subprocess.check_output(
        ["/usr/bin/git", "-C", str(root), "rev-parse", revision],
        text=True,
    ).strip()


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def previous_release_payloads(root, scenario):
    previous_commit = git_revision(root, "HEAD^1")
    package = b"fixture rollback package\n"
    package_digest = sha256(package)
    manifest_digest = (
        "0" * 64 if scenario == "rollback-mismatch" else package_digest
    )
    build_version = "5" if scenario == "stale-build" else "4"
    manifest = {
        "schemaVersion": 2,
        "product": "Gatebeam",
        "commit": previous_commit,
        "tag": "v0.4.0",
        "version": "0.4.0",
        "buildVersion": build_version,
        "previousPublicBuildVersion": "3",
        "bundleIdentifier": "io.github.naifuliang.gatebeam",
        "artifacts": [
            {
                "name": "Gatebeam-0.4.0.pkg",
                "type": "installer-package",
                "byteCount": len(package),
                "sha256": manifest_digest,
            }
        ],
    }
    manifest_bytes = json.dumps(
        manifest, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    checksums = f"{package_digest}  Gatebeam-0.4.0.pkg\n".encode("utf-8")
    return previous_commit, package, manifest_bytes, checksums


def asset(asset_id, name, payload):
    return {
        "id": asset_id,
        "name": name,
        "state": "uploaded",
        "size": len(payload),
        "digest": f"sha256:{sha256(payload)}",
        "url": f"{API_ROOT}/releases/assets/{asset_id}",
        "browser_download_url": (
            f"{WEB_ROOT}/releases/download/v0.4.0/{name}"
        ),
    }


def latest_release(root, scenario):
    _, package, manifest, checksums = previous_release_payloads(root, scenario)
    return {
        "id": 44,
        "tag_name": "v0.4.0",
        "name": "Gatebeam 0.4.0",
        "draft": False,
        "prerelease": False,
        "immutable": scenario != "mutable-release",
        "html_url": f"{WEB_ROOT}/releases/tag/v0.4.0",
        "assets": [
            asset(101, "release-manifest.json", manifest),
            asset(102, "SHA256SUMS", checksums),
            asset(103, "Gatebeam-0.4.0.pkg", package),
        ],
    }


def workflow_run(root, run_id, scenario):
    head_sha = git_revision(root, "HEAD")
    clean = run_id == "123457"
    name = (
        "Release clean-machine validation"
        if clean
        else "CI"
    )
    path = (
        ".github/workflows/release-validation.yml"
        if clean
        else ".github/workflows/ci.yml"
    )
    if scenario == "wrong-workflow" and not clean:
        name = "Untrusted CI"
        path = ".github/workflows/untrusted.yml"
    if scenario == "wrong-head" and not clean:
        head_sha = "f" * 40
    run_url = f"{API_ROOT}/actions/runs/{run_id}"
    return {
        "id": int(run_id),
        "name": name,
        "path": f"{path}@refs/heads/main",
        "head_sha": head_sha,
        "status": "completed",
        "conclusion": (
            "failure"
            if scenario == "wrong-conclusion" and not clean
            else "success"
        ),
        "url": run_url,
        "html_url": f"{WEB_ROOT}/actions/runs/{run_id}",
        "jobs_url": f"{run_url}/jobs",
        "repository": {
            "full_name": (
                "attacker/gatebeam"
                if scenario == "wrong-repo" and not clean
                else REPOSITORY
            ),
            "private": False,
        },
    }


def workflow_jobs(root, run_id, scenario):
    run = workflow_run(root, run_id, scenario)
    clean = run_id == "123457"
    step_names = list(CLEAN_STEPS if clean else CI_STEPS)
    if scenario == "missing-step" and not clean:
        step_names.remove("Run backend tests")
    job_name = (
        "Validate install, upgrade, rollback, and uninstall"
        if clean
        else "Test, isolate, and build Gatebeam"
    )
    job = {
        "id": 700 + int(run_id[-1]),
        "name": job_name,
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
                "number": index,
            }
            for index, name in enumerate(step_names, start=1)
        ],
    }
    return {"total_count": 1, "jobs": [job]}


def response_for(root, url, scenario):
    previous_commit, package, manifest, checksums = (
        previous_release_payloads(root, scenario)
    )
    if url == f"{API_ROOT}/immutable-releases":
        return {"enabled": scenario != "immutable-disabled"}, False
    if url == f"{API_ROOT}/releases?per_page=1":
        releases = (
            [latest_release(root, scenario)]
            if scenario == "bootstrap-existing-release"
            else []
        )
        return releases, False
    if url == f"{API_ROOT}/releases/latest":
        return latest_release(root, scenario), False
    if url == f"{API_ROOT}/commits/v0.4.0":
        return {"sha": previous_commit}, False
    for run_id in ("123456", "123457"):
        if url == f"{API_ROOT}/actions/runs/{run_id}":
            return workflow_run(root, run_id, scenario), False
        if url == f"{API_ROOT}/actions/runs/{run_id}/jobs?per_page=100":
            return workflow_jobs(root, run_id, scenario), False
    if url == f"{API_ROOT}/releases/assets/101":
        return manifest, True
    if url == f"{API_ROOT}/releases/assets/102":
        return checksums, True
    if url == f"{API_ROOT}/releases/assets/103":
        return package, True
    fail(f"unexpected fake GitHub URL: {url}")


def main():
    root = fixture_root()
    scenario = os.environ.get("GATEBEAM_FAKE_GITHUB_SCENARIO", "success")
    arguments = sys.argv[1:]
    output_path = None
    url = None
    for index, argument in enumerate(arguments):
        if argument == "--output" and index + 1 < len(arguments):
            output_path = pathlib.Path(arguments[index + 1])
        if argument.startswith("https://"):
            url = argument
    if output_path is None or url is None:
        fail("fake curl requires an output path and fixed HTTPS URL")
    with open(os.environ["GATEBEAM_FAKE_CALL_LOG"], "a", encoding="utf-8") as stream:
        stream.write(f"github {url}\n")
    if scenario == "network-failure":
        fail("injected GitHub network failure")
    if scenario == "asset-failure" and "/releases/assets/" in url:
        fail("injected GitHub asset failure")
    if scenario == "malformed-json" and url.endswith("/immutable-releases"):
        output_path.write_bytes(b"{")
        return
    payload, binary = response_for(root, url, scenario)
    if binary:
        output_path.write_bytes(payload)
    else:
        output_path.write_text(
            json.dumps(payload, sort_keys=True),
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
