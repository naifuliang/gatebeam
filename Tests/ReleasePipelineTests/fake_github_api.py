#!/usr/bin/python3
import hashlib
import io
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET


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


def previous_package(scenario):
    version = "9.9.9" if scenario == "wrong-internal-version" else "0.4.0"
    if scenario == "wrong-internal-build":
        build_version = "99"
    elif scenario == "stale-build":
        build_version = "5"
    else:
        build_version = "4"
    bundle_identifier = (
        "io.github.naifuliang.decoy"
        if scenario == "wrong-internal-bundle-id"
        else "io.github.naifuliang.gatebeam"
    )
    info_plist = plistlib.dumps(
        {
            "CFBundleExecutable": "Gatebeam",
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build_version,
            "GatebeamDeveloperTeamIdentifier": "ABCDE12345",
        },
        sort_keys=True,
    )
    package_identifier = (
        "io.github.naifuliang.decoy"
        if scenario == "wrong-package-identifier"
        else "io.github.naifuliang.gatebeam"
    )
    package_version = (
        "9.9.9" if scenario == "wrong-package-version" else "0.4.0"
    )
    install_location = (
        "/tmp" if scenario == "wrong-install-location" else "/Applications"
    )
    components = ["Gatebeam.pkg"]
    if scenario == "second-component-package":
        components.append("GatebeamExtras.pkg")

    distribution = ET.Element("installer-gui-script", minSpecVersion="1")
    for component in components:
        component_identifier = (
            package_identifier
            if component == "Gatebeam.pkg"
            else "io.github.naifuliang.gatebeam.extras"
        )
        reference = ET.SubElement(
            distribution,
            "pkg-ref",
            id=component_identifier,
            version=package_version,
        )
        reference.text = f"#{component}"

    package_info = ET.Element(
        "pkg-info",
        identifier=package_identifier,
        version=package_version,
        **{"install-location": install_location, "auth": "root"},
    )
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as package:
        entries = [
            ("Distribution", ET.tostring(distribution), 0o100644),
            (
                "Gatebeam.pkg/PackageInfo",
                ET.tostring(package_info),
                0o100644,
            ),
        ]
        app_root = "Gatebeam.pkg/Payload/Gatebeam.app"
        if scenario == "scripts-decoy":
            app_root = "Gatebeam.pkg/Scripts/Gatebeam.app"
        elif scenario == "resources-decoy":
            app_root = "Resources/Gatebeam.app"
        elif scenario == "wrong-payload":
            app_root = "Gatebeam.pkg/WrongPayload/Gatebeam.app"
        entries.extend(
            [
                (
                    f"{app_root}/Contents/Info.plist",
                    info_plist,
                    0o100644,
                ),
                (
                    f"{app_root}/Contents/MacOS/Gatebeam",
                    b"fixture rollback executable\n",
                    0o100755,
                ),
            ]
        )
        if scenario == "second-payload-app":
            second_app = "Other" + ".app"
            entries.append(
                (
                    f"Gatebeam.pkg/Payload/{second_app}/Contents/Info.plist",
                    info_plist,
                    0o100644,
                )
            )
        if scenario == "second-component-package":
            entries.append(
                (
                    "GatebeamExtras.pkg/PackageInfo",
                    ET.tostring(
                        ET.Element(
                            "pkg-info",
                            identifier="io.github.naifuliang.gatebeam.extras",
                            version=package_version,
                            **{
                                "install-location": "/Applications",
                                "auth": "root",
                            },
                        )
                    ),
                    0o100644,
                )
            )
        for name, payload, mode in entries:
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = mode << 16
            package.writestr(entry, payload)
    return archive.getvalue()


def previous_release_payloads(root, scenario):
    previous_commit = git_revision(root, "HEAD^1")
    app_archive = b"fixture previous app archive\n"
    package = previous_package(scenario)
    disk_image = b"fixture previous disk image\n"
    app_archive_digest = sha256(app_archive)
    package_digest = sha256(package)
    disk_image_digest = sha256(disk_image)
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
                "name": "Gatebeam-0.4.0.zip",
                "type": "app-archive",
                "byteCount": len(app_archive),
                "sha256": app_archive_digest,
            },
            {
                "name": "Gatebeam-0.4.0.pkg",
                "type": "installer-package",
                "byteCount": len(package),
                "sha256": manifest_digest,
            },
            {
                "name": "Gatebeam-0.4.0.dmg",
                "type": "disk-image",
                "byteCount": len(disk_image),
                "sha256": disk_image_digest,
            },
        ],
    }
    if scenario == "missing-artifact":
        manifest["artifacts"].pop(0)
    elif scenario == "duplicate-artifact":
        manifest["artifacts"].append(dict(manifest["artifacts"][1]))
    elif scenario == "extra-artifact":
        manifest["artifacts"].append(
            {
                "name": "Gatebeam-0.4.0.txt",
                "type": "release-notes",
                "byteCount": 1,
                "sha256": "0" * 64,
            }
        )
    elif scenario == "mismatched-artifact":
        manifest["artifacts"][2]["byteCount"] += 1
    manifest_bytes = json.dumps(
        manifest, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    checksum_lines = [
        f"{app_archive_digest}  Gatebeam-0.4.0.zip",
        f"{package_digest}  Gatebeam-0.4.0.pkg",
        f"{disk_image_digest}  Gatebeam-0.4.0.dmg",
    ]
    if scenario == "missing-checksum":
        checksum_lines.pop()
    elif scenario == "duplicate-checksum":
        checksum_lines.append(checksum_lines[0])
    elif scenario == "extra-checksum":
        checksum_lines.append(f'{"0" * 64}  Gatebeam-0.4.0.txt')
    elif scenario == "mismatched-checksum":
        checksum_lines[2] = f'{"0" * 64}  Gatebeam-0.4.0.dmg'
    checksums = ("\n".join(checksum_lines) + "\n").encode("utf-8")
    attestation_bytes = None
    if scenario.startswith("schema4-"):
        run_id = 999001
        run_attempt = 2
        repository_id = 987654321
        tag = "v0.4.0"
        workflow_ref = (
            f"{REPOSITORY}/.github/workflows/"
            f"release-validation.yml@refs/tags/{tag}"
        )
        candidate_name = (
            f"gatebeam-final-candidate-{tag}-{previous_commit}-"
            f"run{run_id}-attempt{run_attempt}"
        )
        attestation_name = (
            f"gatebeam-clean-machine-attestation-{tag}-{previous_commit}-"
            f"run{run_id}-attempt{run_attempt}"
        )
        manifest.update(
            {
                "schemaVersion": 4,
                "previousBuildVersion": "3",
                "teamIdentifier": "ABCDE12345",
                "testing": {
                    "finalArtifactValidation": {
                        "required": True,
                        "repository": REPOSITORY,
                        "repositoryId": repository_id,
                        "workflowName": "Release final-artifact validation",
                        "workflowPath": ".github/workflows/release-validation.yml",
                        "workflowRef": workflow_ref,
                        "workflowSHA": previous_commit,
                        "runId": run_id,
                        "runAttempt": run_attempt,
                        "event": "workflow_dispatch",
                        "buildJob": "build-candidate",
                        "validationJob": "clean-machine",
                        "commit": previous_commit,
                        "tag": tag,
                        "candidateArtifactName": candidate_name,
                        "attestationArtifactName": attestation_name,
                    }
                },
                "rollback": {
                    "available": True,
                    "version": "0.3.0",
                    "assetSHA256": "3" * 64,
                    "sourceCommit": "3" * 40,
                },
            }
        )
        manifest_bytes = (
            json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        file_records = [
            {
                "path": entry["name"],
                "role": entry["type"],
                "byteCount": entry["byteCount"],
                "sha256": entry["sha256"],
            }
            for entry in manifest["artifacts"]
        ]
        file_records.extend(
            [
                {
                    "path": "SHA256SUMS",
                    "role": "checksums",
                    "byteCount": len(checksums),
                    "sha256": sha256(checksums),
                },
                {
                    "path": "release-manifest.json",
                    "role": "release-manifest",
                    "byteCount": len(manifest_bytes),
                    "sha256": sha256(manifest_bytes),
                },
                {
                    "path": "validation/previous-Gatebeam.pkg",
                    "role": "rollback-package",
                    "byteCount": 1,
                    "sha256": "3" * 64,
                },
                {
                    "path": "validation/previous-release-manifest.json",
                    "role": "rollback-manifest",
                    "byteCount": 1,
                    "sha256": "4" * 64,
                },
                {
                    "path": "validation/previous-SHA256SUMS",
                    "role": "rollback-checksums",
                    "byteCount": 1,
                    "sha256": "5" * 64,
                },
            ]
        )
        validations = [
            "candidate-contract",
            "app-developer-id",
            "app-notarization-ticket",
            "app-gatekeeper",
            "pkg-developer-id",
            "pkg-notarization-ticket",
            "pkg-gatekeeper",
            "pkg-payload-app",
            "dmg-developer-id",
            "dmg-notarization-ticket",
            "dmg-gatekeeper",
            "dmg-contained-app",
            "fresh-install",
            "upgrade",
            "failure-rollback",
            "published-rollback",
            "uninstall",
        ]
        attestation = {
            "schemaVersion": 1,
            "kind": (
                "io.github.naifuliang.gatebeam.clean-machine-attestation"
            ),
            "result": "Passed",
            "repository": {
                "fullName": REPOSITORY,
                "id": repository_id,
            },
            "workflow": {
                "name": "Release final-artifact validation",
                "path": ".github/workflows/release-validation.yml",
                "ref": workflow_ref,
                "sha": previous_commit,
                "runId": run_id,
                "runAttempt": run_attempt,
                "event": "workflow_dispatch",
                "job": "clean-machine",
            },
            "source": {
                "commit": previous_commit,
                "tag": tag,
                "ref": f"refs/tags/{tag}",
            },
            "release": {
                "version": "0.4.0",
                "buildVersion": build_version,
                "bundleIdentifier": "io.github.naifuliang.gatebeam",
                "teamIdentifier": "ABCDE12345",
                "bootstrap": False,
            },
            "candidateArtifact": {
                "name": candidate_name,
                "id": 9001,
                "digest": f"sha256:{'6' * 64}",
            },
            "candidateEnvelopeSHA256": "7" * 64,
            "files": sorted(file_records, key=lambda entry: entry["path"]),
            "validations": [
                {"name": name, "passed": True}
                for name in validations
            ],
            "rollbackTested": True,
            "attestationArtifactName": attestation_name,
            "releaseManifestSHA256": (
                "0" * 64
                if scenario == "schema4-tampered-attestation"
                else sha256(manifest_bytes)
            ),
            "releaseVersion": "0.4.0",
            "releaseBuildVersion": build_version,
        }
        attestation_bytes = (
            json.dumps(attestation, sort_keys=True, separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
    return (
        previous_commit,
        app_archive,
        package,
        disk_image,
        manifest_bytes,
        checksums,
        attestation_bytes,
    )


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
    (
        _,
        app_archive,
        package,
        disk_image,
        manifest,
        checksums,
        attestation,
    ) = previous_release_payloads(root, scenario)
    assets = [
        asset(101, "release-manifest.json", manifest),
        asset(102, "SHA256SUMS", checksums),
        asset(103, "Gatebeam-0.4.0.zip", app_archive),
        asset(104, "Gatebeam-0.4.0.pkg", package),
        asset(105, "Gatebeam-0.4.0.dmg", disk_image),
    ]
    if attestation is not None and scenario != "schema4-missing-attestation":
        assets.append(
            asset(
                106,
                "clean-machine-attestation.json",
                attestation,
            )
        )
    if scenario == "missing-release-asset":
        assets.pop()
    elif scenario == "duplicate-release-asset":
        assets.append(asset(106, "Gatebeam-0.4.0.dmg", disk_image))
    elif scenario == "extra-release-asset":
        assets.append(asset(106, "Gatebeam-0.4.0.txt", b"notes\n"))
    return {
        "id": 44,
        "tag_name": "v0.4.0",
        "name": "Gatebeam 0.4.0",
        "draft": False,
        "prerelease": False,
        "immutable": scenario != "mutable-release",
        "html_url": f"{WEB_ROOT}/releases/tag/v0.4.0",
        "assets": assets,
    }


def workflow_run(root, run_id, scenario):
    head_sha = git_revision(root, "HEAD")
    clean = run_id == "123457"
    event = "workflow_dispatch" if clean else "push"
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
    path_ref = "refs/heads/main"
    if scenario == "wrong-workflow" and not clean:
        name = "Untrusted CI"
        path = ".github/workflows/untrusted.yml"
    if scenario == "wrong-head" and not clean:
        head_sha = "f" * 40
    if scenario == "pull-request-merge-ref" and not clean:
        event = "pull_request"
        path_ref = "refs/pull/42/merge"
    if scenario == "wrong-clean-event" and clean:
        event = "push"
    run_url = f"{API_ROOT}/actions/runs/{run_id}"
    return {
        "id": int(run_id),
        "name": name,
        "path": f"{path}@{path_ref}",
        "event": event,
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
    (
        previous_commit,
        app_archive,
        package,
        disk_image,
        manifest,
        checksums,
        attestation,
    ) = previous_release_payloads(root, scenario)
    if url == f"{API_ROOT}/immutable-releases":
        return {"enabled": scenario != "immutable-disabled"}, False
    match = re.fullmatch(re.escape(f"{API_ROOT}/releases?per_page=100&page=") + r"([0-9]+)", url)
    if match:
        if int(match.group(1)) != 1:
            return [], False
        bootstrap = os.environ.get("GATEBEAM_RELEASE_BOOTSTRAP") == "1"
        if bootstrap:
            releases = (
                [latest_release(root, scenario)]
                if scenario == "bootstrap-existing-release"
                else []
            )
        else:
            releases = [latest_release(root, scenario)]
        return releases, False
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
        return app_archive, True
    if url == f"{API_ROOT}/releases/assets/104":
        return package, True
    if url == f"{API_ROOT}/releases/assets/105":
        return disk_image, True
    if url == f"{API_ROOT}/releases/assets/106" and attestation is not None:
        return attestation, True
    fail(f"unexpected fake GitHub URL: {url}")


def main():
    root = fixture_root()
    scenario = os.environ.get("GATEBEAM_FAKE_GITHUB_SCENARIO", "success")
    arguments = sys.argv[1:]
    if (
        len(arguments) != 3
        or arguments[0] != "--disable"
        or arguments[1] != "--config"
    ):
        fail("fake curl requires --disable first and only a private config path")
    config_path = pathlib.Path(arguments[2])
    config_stat = config_path.lstat()
    if (
        not config_path.is_file()
        or config_path.is_symlink()
        or config_stat.st_mode & 0o777 != 0o600
        or config_stat.st_nlink != 1
    ):
        fail("fake curl config is not a private 0600 regular file")
    config_lines = config_path.read_text(encoding="utf-8").splitlines()
    output_path = None
    url = None
    headers = []
    for line in config_lines:
        match = re.fullmatch(r"([a-z-]+) = \"(.*)\"", line)
        if match is None:
            continue
        option, value = match.groups()
        if option == "header":
            headers.append(value)
        elif option == "output":
            output_path = pathlib.Path(value)
        elif option == "url":
            url = value
    if output_path is None or url is None:
        fail("fake curl config requires an output path and fixed HTTPS URL")
    expected_token_file = pathlib.Path(
        os.environ["GATEBEAM_FAKE_EXPECTED_GITHUB_TOKEN_FILE"]
    )
    expected_token = expected_token_file.read_text(encoding="utf-8").strip()
    if any(expected_token in argument for argument in sys.argv):
        fail("GitHub token leaked through curl argv")
    if any(
        expected_token in key or expected_token in value
        for key, value in os.environ.items()
    ):
        fail("GitHub token leaked through the API child environment")
    expected_header = f"Authorization: Bearer {expected_token}"
    authorization_headers = [
        header for header in headers
        if header.startswith("Authorization:")
    ]
    if authorization_headers != [expected_header]:
        fail("fake GitHub authentication failed")
    if (
        "GATEBEAM_GITHUB_TOKEN" in os.environ
        or "GATEBEAM_GITHUB_TOKEN_FILE" in os.environ
        or "GITHUB_API_TOKEN" in os.environ
    ):
        fail("GitHub token leaked through the API child environment")
    with open(root / "curl-argv.log", "a", encoding="utf-8") as stream:
        stream.write(json.dumps(sys.argv, sort_keys=True) + "\n")
    with open(root / "curl-env.log", "a", encoding="utf-8") as stream:
        stream.write(json.dumps(dict(os.environ), sort_keys=True) + "\n")
    with open(os.environ["GATEBEAM_FAKE_CALL_LOG"], "a", encoding="utf-8") as stream:
        stream.write(f"github {url}\n")
    if scenario == "auth-failure":
        fail("injected GitHub authentication failure")
    if scenario == "network-failure":
        fail("injected GitHub network failure")
    if scenario == "asset-failure" and "/releases/assets/" in url:
        fail("injected GitHub asset failure")
    if scenario == "app-asset-failure" and url.endswith("/releases/assets/103"):
        fail("injected GitHub app archive failure")
    if scenario == "dmg-asset-failure" and url.endswith("/releases/assets/105"):
        fail("injected GitHub disk image failure")
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
