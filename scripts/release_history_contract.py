#!/usr/bin/python3
"""Validate Gatebeam immutable release history and produce a stable snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys


SEMVER = re.compile(
    r"(?P<major>0|[1-9][0-9]*)[.]"
    r"(?P<minor>0|[1-9][0-9]*)[.]"
    r"(?P<patch>0|[1-9][0-9]*)"
    r"(?:-(?P<prerelease>"
    r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:[.](?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*"
    r"))?"
    r"(?:[+](?P<build>[0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?"
)
SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
REPOSITORY = "naifuliang/gatebeam"


class HistoryError(ValueError):
    pass


def parse_semver(value: object) -> dict[str, object]:
    if not isinstance(value, str):
        raise HistoryError("release version is not a string")
    match = SEMVER.fullmatch(value)
    if match is None:
        raise HistoryError(f"invalid SemVer 2.0 version: {value}")
    prerelease = tuple((match.group("prerelease") or "").split("."))
    if prerelease == ("",):
        prerelease = ()
    identifiers: tuple[tuple[int, object], ...] = tuple(
        (0, int(identifier)) if identifier.isdecimal() else (1, identifier)
        for identifier in prerelease
    )
    core = tuple(int(match.group(name)) for name in ("major", "minor", "patch"))
    precedence = (core, (1, ())) if not identifiers else (core, (0, identifiers))
    return {
        "text": value,
        "core": core,
        "prerelease": prerelease,
        "build": tuple((match.group("build") or "").split("."))
        if match.group("build")
        else (),
        "precedence": precedence,
    }


def release_version(entry: dict[str, object]) -> dict[str, object] | None:
    tag = entry.get("tag_name")
    if not isinstance(tag, str) or not tag.startswith("v"):
        return None
    return parse_semver(tag[1:])


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise HistoryError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path: pathlib.Path) -> object:
    try:
        with path.open("rb") as stream:
            return json.load(stream, object_pairs_hook=reject_duplicates)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise HistoryError(f"invalid JSON: {path.name}") from error


def releases(path: pathlib.Path) -> list[dict[str, object]]:
    document = load(path)
    if not isinstance(document, list) or len(document) > 10000:
        raise HistoryError("release history response is invalid or unbounded")
    if any(not isinstance(entry, dict) for entry in document):
        raise HistoryError("release history contains an invalid entry")
    ids = [entry.get("id") for entry in document]
    if (
        any(isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in ids)
        or len(ids) != len(set(ids))
    ):
        raise HistoryError("release history contains invalid or duplicate IDs")
    return document


def formal_release(entry: dict[str, object]) -> bool:
    try:
        return release_version(entry) is not None
    except HistoryError:
        return False


def validate_release_state(
    entry: dict[str, object],
    version: dict[str, object],
) -> None:
    if (
        entry.get("immutable") is not True
        or entry.get("draft") is not False
        or entry.get("prerelease") is not bool(version["prerelease"])
    ):
        raise HistoryError("formal release history contains an invalid immutable state")


def asset_map(entry: dict[str, object], version: str) -> dict[str, dict[str, object]]:
    values = entry.get("assets")
    if not isinstance(values, list) or any(not isinstance(asset, dict) for asset in values):
        raise HistoryError("immutable release asset list is invalid")
    result: dict[str, dict[str, object]] = {}
    for asset in values:
        name = asset.get("name")
        asset_id = asset.get("id")
        size = asset.get("size")
        digest = asset.get("digest")
        if (
            not isinstance(name, str)
            or name in result
            or isinstance(asset_id, bool)
            or not isinstance(asset_id, int)
            or asset_id <= 0
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size <= 0
            or size > 4 * 1024 * 1024 * 1024
            or not isinstance(digest, str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None
            or asset.get("state") != "uploaded"
            or asset.get("url")
            != f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{asset_id}"
            or asset.get("browser_download_url")
            != (
                f"https://github.com/{REPOSITORY}/releases/download/"
                f"v{version}/{name}"
            )
        ):
            raise HistoryError("immutable release asset metadata is invalid")
        result[name] = asset
    base = {
        f"Gatebeam-{version}.zip",
        f"Gatebeam-{version}.pkg",
        f"Gatebeam-{version}.dmg",
        "SHA256SUMS",
        "release-manifest.json",
    }
    accepted = (
        base,
        base | {"clean-machine-attestation.json"},
        base | {"candidate-envelope.json", "clean-machine-attestation.json"},
    )
    if set(result) not in accepted:
        raise HistoryError("immutable release asset allowlist is invalid")
    return result


def select(arguments: argparse.Namespace) -> None:
    for entry in releases(pathlib.Path(arguments.releases)):
        if entry.get("draft") is True:
            continue
        try:
            parsed = release_version(entry)
        except HistoryError:
            if str(entry.get("tag_name", "")).startswith("v"):
                raise
            continue
        if parsed is None:
            continue
        validate_release_state(entry, parsed)
        version = str(parsed["text"])
        assets = asset_map(entry, version)
        manifest = assets["release-manifest.json"]
        print(
            "\t".join(
                (
                    str(manifest["id"]),
                    str(manifest["size"]),
                    str(manifest["digest"])[7:],
                )
            )
        )


def highest_selection(arguments: argparse.Namespace) -> None:
    candidates: list[tuple[object, dict[str, object], dict[str, object]]] = []
    for entry in releases(pathlib.Path(arguments.releases)):
        if entry.get("draft") is True:
            continue
        try:
            parsed = release_version(entry)
        except HistoryError:
            if str(entry.get("tag_name", "")).startswith("v"):
                raise
            continue
        if parsed is None:
            continue
        validate_release_state(entry, parsed)
        candidates.append((parsed["precedence"], parsed, entry))
    if not candidates:
        raise HistoryError("published immutable history has no formal release")
    candidates.sort(key=lambda item: item[0])
    if len({item[0] for item in candidates}) != len(candidates):
        raise HistoryError("formal release history has duplicate SemVer precedence")
    current = parse_semver(arguments.current_version)
    if current["precedence"] <= candidates[-1][0]:
        raise HistoryError("candidate is not newer than the highest immutable release")
    _, parsed, release = candidates[-1]
    version = str(parsed["text"])
    tag = f"v{version}"
    if (
        release.get("html_url")
        != f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
        or isinstance(release.get("id"), bool)
        or not isinstance(release.get("id"), int)
        or int(release["id"]) <= 0
    ):
        raise HistoryError("highest immutable release metadata is invalid")
    assets = asset_map(release, version)

    def selected(name: str) -> dict[str, object]:
        asset = assets[name]
        return {
            "id": asset["id"],
            "digest": str(asset["digest"])[7:],
            "size": asset["size"],
            "name": name,
        }

    base_names = {
        f"Gatebeam-{version}.zip",
        f"Gatebeam-{version}.pkg",
        f"Gatebeam-{version}.dmg",
        "SHA256SUMS",
        "release-manifest.json",
    }
    output: dict[str, object] = {
        "tag": tag,
        "version": version,
        "releaseURL": release["html_url"],
        "manifest": selected("release-manifest.json"),
        "checksums": selected("SHA256SUMS"),
        "appArchive": selected(f"Gatebeam-{version}.zip"),
        "rollback": selected(f"Gatebeam-{version}.pkg"),
        "diskImage": selected(f"Gatebeam-{version}.dmg"),
    }
    if set(assets) != base_names:
        output["attestation"] = selected("clean-machine-attestation.json")
    if "candidate-envelope.json" in assets:
        output["envelope"] = selected("candidate-envelope.json")
    ids = [
        value["id"]
        for value in output.values()
        if isinstance(value, dict) and "id" in value
    ]
    if len(ids) != len(set(ids)):
        raise HistoryError("highest immutable release reuses an asset ID")
    pathlib.Path(arguments.output).write_text(
        json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def analyze(arguments: argparse.Namespace) -> None:
    values = releases(pathlib.Path(arguments.releases))
    current = load(pathlib.Path(arguments.current_manifest))
    if not isinstance(current, dict):
        raise HistoryError("current release manifest is invalid")
    current_version = current.get("version")
    current_build = current.get("buildVersion")
    current_commit = current.get("commit")
    current_tag = current.get("tag")
    current_parsed = parse_semver(current_version)
    if (
        current_tag != f"v{current_version}"
        or not isinstance(current_build, str)
        or re.fullmatch(r"[1-9][0-9]*", current_build) is None
        or not isinstance(current_commit, str)
        or COMMIT.fullmatch(current_commit) is None
    ):
        raise HistoryError("formal release version, build, tag, or commit is invalid")

    drafts = [entry for entry in values if entry.get("draft") is True]
    expected_draft = int(arguments.expected_draft_id)
    if expected_draft == 0:
        if drafts:
            raise HistoryError("another formal release draft holds the remote publication lock")
    elif (
        len(drafts) != 1
        or drafts[0].get("id") != expected_draft
        or drafts[0].get("tag_name") != current_tag
        or drafts[0].get("name") != f"Gatebeam {current_version}"
    ):
        raise HistoryError("remote publication lock is missing, duplicated, or stale")

    history: list[dict[str, object]] = []
    for entry in values:
        if entry.get("draft") is True:
            continue
        try:
            parsed = release_version(entry)
        except HistoryError:
            if str(entry.get("tag_name", "")).startswith("v"):
                raise
            continue
        if parsed is None:
            continue
        validate_release_state(entry, parsed)
        tag = entry["tag_name"]
        version = str(parsed["text"])
        if entry.get("html_url") != (
            f"https://github.com/{REPOSITORY}/releases/tag/v{version}"
        ):
            raise HistoryError("immutable release URL is not canonical")
        assets = asset_map(entry, version)
        manifest_asset = assets["release-manifest.json"]
        manifest_path = pathlib.Path(arguments.manifests) / f"{manifest_asset['id']}.json"
        manifest = load(manifest_path)
        if not isinstance(manifest, dict):
            raise HistoryError("historical release manifest is invalid")
        build = manifest.get("buildVersion")
        commit = manifest.get("commit")
        if (
            manifest.get("version") != version
            or manifest.get("tag") != tag
            or not isinstance(build, str)
            or re.fullmatch(r"[1-9][0-9]*", build) is None
            or not isinstance(commit, str)
            or COMMIT.fullmatch(commit) is None
        ):
            raise HistoryError("historical release manifest identity is invalid")
        history.append(
            {
                "id": entry["id"],
                "tag": tag,
                "version": version,
                "versionKey": parsed["precedence"],
                "build": int(build),
                "commit": commit,
                "url": entry.get("html_url"),
                "assets": {
                    name: {
                        "id": asset["id"],
                        "size": asset["size"],
                        "digest": asset["digest"],
                    }
                    for name, asset in sorted(assets.items())
                },
            }
        )
    history.sort(key=lambda entry: entry["versionKey"])
    versions = [entry["versionKey"] for entry in history]
    builds = [entry["build"] for entry in history]
    if len(versions) != len(set(versions)) or len(builds) != len(set(builds)):
        raise HistoryError("formal release history duplicates SemVer precedence or build")
    if any(left >= right for left, right in zip(builds, builds[1:])):
        raise HistoryError("formal release versions and builds have forked ordering")
    current_key = current_parsed["precedence"]
    if history and (current_key <= history[-1]["versionKey"] or int(str(current_build)) <= history[-1]["build"]):
        raise HistoryError("candidate is not newer than the highest immutable release")

    rollback = current.get("rollback")
    if not isinstance(rollback, dict):
        raise HistoryError("candidate rollback binding is missing")
    if not history:
        if rollback.get("available") is not False or rollback.get("bootstrap") is not True:
            raise HistoryError("bootstrap candidate disagrees with empty immutable history")
    else:
        highest = history[-1]
        package = highest["assets"][f"Gatebeam-{highest['version']}.pkg"]
        if (
            rollback.get("available") is not True
            or rollback.get("version") != highest["version"]
            or rollback.get("sourceCommit") != highest["commit"]
            or rollback.get("assetSHA256") != str(package["digest"])[7:]
            or rollback.get("releaseURL") != highest["url"]
            or current.get("previousBuildVersion") != str(highest["build"])
        ):
            raise HistoryError("candidate rollback binding does not match highest immutable history")

    snapshot_records = [
        {
            key: value
            for key, value in entry.items()
            if key != "versionKey"
        }
        for entry in history
    ]
    snapshot_payload = json.dumps(snapshot_records, sort_keys=True, separators=(",", ":")).encode("utf-8")
    output = {
        "schemaVersion": 1,
        "repository": REPOSITORY,
        "snapshotSHA256": hashlib.sha256(snapshot_payload).hexdigest(),
        "releaseCount": len(history),
        "commits": [entry["commit"] for entry in history],
        "highestVersion": "" if not history else history[-1]["version"],
        "highestBuild": 0 if not history else history[-1]["build"],
        "remoteDraftId": expected_draft,
    }
    pathlib.Path(arguments.output).write_text(
        json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    select_parser = subparsers.add_parser("select-manifests")
    select_parser.add_argument("--releases", required=True)
    highest_parser = subparsers.add_parser("select-highest")
    highest_parser.add_argument("--releases", required=True)
    highest_parser.add_argument("--current-version", required=True)
    highest_parser.add_argument("--output", required=True)
    analyze_parser = subparsers.add_parser("analyze")
    analyze_parser.add_argument("--releases", required=True)
    analyze_parser.add_argument("--manifests", required=True)
    analyze_parser.add_argument("--current-manifest", required=True)
    analyze_parser.add_argument("--expected-draft-id", required=True)
    analyze_parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "select-manifests":
            select(arguments)
        elif arguments.command == "select-highest":
            highest_selection(arguments)
        else:
            analyze(arguments)
    except (HistoryError, OSError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
