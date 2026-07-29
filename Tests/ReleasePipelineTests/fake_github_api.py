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
    return (
        previous_commit,
        app_archive,
        package,
        disk_image,
        manifest_bytes,
        checksums,
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
    ) = previous_release_payloads(root, scenario)
    assets = [
        asset(101, "release-manifest.json", manifest),
        asset(102, "SHA256SUMS", checksums),
        asset(103, "Gatebeam-0.4.0.zip", app_archive),
        asset(104, "Gatebeam-0.4.0.pkg", package),
        asset(105, "Gatebeam-0.4.0.dmg", disk_image),
    ]
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
    ) = previous_release_payloads(root, scenario)
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
        return app_archive, True
    if url == f"{API_ROOT}/releases/assets/104":
        return package, True
    if url == f"{API_ROOT}/releases/assets/105":
        return disk_image, True
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
