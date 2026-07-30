#!/usr/bin/python3
"""Fail-closed contract for Gatebeam release candidates and attestations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
import zipfile
from typing import BinaryIO


REPOSITORY = "naifuliang/gatebeam"
WORKFLOW_NAME = "Release final-artifact validation"
WORKFLOW_PATH = ".github/workflows/release-validation.yml"
BUILD_JOB = "build-candidate"
VALIDATION_JOB = "clean-machine"
BUNDLE_ID = "io.github.naifuliang.gatebeam"
CANDIDATE_KIND = "io.github.naifuliang.gatebeam.final-candidate"
ATTESTATION_KIND = "io.github.naifuliang.gatebeam.clean-machine-attestation"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)"
    r"(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:[.](?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:[+][0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*)?"
)
POSITIVE_RE = re.compile(r"[1-9][0-9]*")
TEAM_RE = re.compile(r"[A-Z0-9]{10}")
SAFE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,239}")
BASE_VALIDATIONS = [
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
    "uninstall",
]


def expected_validations(bootstrap: bool) -> list[str]:
    history_validation = (
        "bootstrap-no-rollback-history"
        if bootstrap
        else "published-rollback"
    )
    return [*BASE_VALIDATIONS[:-1], history_validation, BASE_VALIDATIONS[-1]]


class ContractError(ValueError):
    pass


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_string(value: object, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ContractError(f"{label} is invalid")
    return value


def require_positive(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ContractError(f"{label} is invalid")
    return value


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def secure_descriptor(path: pathlib.Path, maximum: int) -> tuple[int, os.stat_result]:
    if not path.is_absolute():
        raise ContractError("release path must be absolute")
    parent = path.parent
    parent_stat = parent.lstat()
    if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
        raise ContractError(f"unsafe parent directory: {path}")
    if parent.resolve(strict=True) != parent.absolute():
        raise ContractError(f"non-canonical parent directory: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        try:
            descriptor = os.open(path.name, flags, dir_fd=parent_descriptor)
        except OSError as error:
            raise ContractError(f"unsafe release file: {path}") from error
    finally:
        os.close(parent_descriptor)
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum
    ):
        os.close(descriptor)
        raise ContractError(f"unsafe release file: {path}")
    return descriptor, before


def verify_stable_descriptor(
    descriptor: int,
    before: os.stat_result,
    path: pathlib.Path,
) -> None:
    after = os.fstat(descriptor)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise ContractError(f"release file changed while reading: {path}")


def secure_read(path: pathlib.Path, maximum: int) -> bytes:
    descriptor, before = secure_descriptor(path, maximum)
    try:
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ContractError(f"short read from release file: {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ContractError(f"release file grew while reading: {path}")
        verify_stable_descriptor(descriptor, before, path)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def secure_digest(path: pathlib.Path, maximum: int) -> tuple[int, str]:
    descriptor, before = secure_descriptor(path, maximum)
    digest = hashlib.sha256()
    try:
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ContractError(f"short read from release file: {path}")
            digest.update(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ContractError(f"release file grew while reading: {path}")
        verify_stable_descriptor(descriptor, before, path)
        return before.st_size, digest.hexdigest()
    finally:
        os.close(descriptor)


def secure_digest_stream(
    path: pathlib.Path,
    maximum: int,
) -> tuple[BinaryIO, os.stat_result, str]:
    descriptor, before = secure_descriptor(path, maximum)
    stream = os.fdopen(descriptor, "rb", closefd=True)
    digest = hashlib.sha256()
    try:
        remaining = before.st_size
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ContractError(f"short read from release file: {path}")
            digest.update(chunk)
            remaining -= len(chunk)
        if stream.read(1):
            raise ContractError(f"release file grew while reading: {path}")
        verify_stable_descriptor(stream.fileno(), before, path)
        stream.seek(0)
        if stream.tell() != 0:
            raise ContractError(f"release file could not be rewound: {path}")
        return stream, before, digest.hexdigest()
    except Exception:
        stream.close()
        raise


def load_json(path: pathlib.Path, maximum: int = 1024 * 1024) -> dict[str, object]:
    try:
        document = json.loads(
            secure_read(path, maximum),
            object_pairs_hook=reject_duplicates,
        )
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ContractError(f"invalid JSON: {path.name}") from error
    if not isinstance(document, dict):
        raise ContractError(f"JSON root must be an object: {path.name}")
    return document


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def file_record(root: pathlib.Path, relative: str, role: str) -> dict[str, object]:
    byte_count, digest = secure_digest(
        root / relative,
        4 * 1024 * 1024 * 1024,
    )
    return {
        "path": relative,
        "role": role,
        "byteCount": byte_count,
        "sha256": digest,
    }


def write_json_exclusive(path: pathlib.Path, document: dict[str, object]) -> None:
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink() or parent.resolve() != parent.absolute():
        raise ContractError("output parent is unsafe")
    payload = (
        json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        descriptor = os.open(path.name, flags, 0o600, dir_fd=parent_descriptor)
    finally:
        os.close(parent_descriptor)
    try:
        written = 0
        while written < len(payload):
            written += os.write(descriptor, payload[written:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def replace_regular_file(path: pathlib.Path, payload: bytes) -> None:
    descriptor, before = secure_descriptor(path, 10 * 1024 * 1024)
    os.close(descriptor)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        output = os.open(temporary.name, flags, 0o600, dir_fd=parent_descriptor)
        try:
            written = 0
            while written < len(payload):
                written += os.write(output, payload[written:])
            os.fsync(output)
        finally:
            os.close(output)
        current = path.lstat()
        if any(
            getattr(before, field) != getattr(current, field)
            for field in ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        ):
            raise ContractError(f"release file changed before replacement: {path}")
        os.replace(temporary.name, path.name, src_dir_fd=parent_descriptor, dst_dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    finally:
        try:
            os.unlink(temporary.name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass
        os.close(parent_descriptor)


def parse_checksums(payload: bytes) -> dict[str, str]:
    try:
        text = payload.decode("ascii")
    except UnicodeDecodeError as error:
        raise ContractError("SHA256SUMS is not ASCII") from error
    result: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]{0,239})", line)
        if match is None or match.group(2) in result:
            raise ContractError("SHA256SUMS has an invalid or duplicate entry")
        result[match.group(2)] = match.group(1)
    if not result:
        raise ContractError("SHA256SUMS is empty")
    return result


def expected_publish_paths(version: str, finalized: bool = True) -> dict[str, str]:
    paths = {
        f"Gatebeam-{version}.zip": "app-archive",
        f"Gatebeam-{version}.pkg": "installer-package",
        f"Gatebeam-{version}.dmg": "disk-image",
    }
    if finalized:
        paths["candidate-envelope.json"] = "candidate-envelope"
    return paths


def validate_release_manifest(
    root: pathlib.Path,
    expected: dict[str, object] | None = None,
    *,
    allow_unfinalized: bool = False,
    allow_legacy_envelope: bool = False,
) -> tuple[dict[str, object], list[dict[str, object]], bool]:
    manifest = load_json(root / "release-manifest.json", 10 * 1024 * 1024)
    if manifest.get("schemaVersion") != 4 or manifest.get("product") != "Gatebeam":
        raise ContractError("release manifest schema or product is invalid")
    version = require_string(manifest.get("version"), VERSION_RE, "release version")
    build = require_string(manifest.get("buildVersion"), POSITIVE_RE, "build version")
    commit = require_string(manifest.get("commit"), COMMIT_RE, "release commit")
    tag = require_string(manifest.get("tag"), re.compile(r"v" + VERSION_RE.pattern), "release tag")
    team = require_string(manifest.get("teamIdentifier"), TEAM_RE, "Team ID")
    if tag != f"v{version}" or manifest.get("bundleIdentifier") != BUNDLE_ID:
        raise ContractError("release identity is inconsistent")

    testing = manifest.get("testing")
    if not isinstance(testing, dict):
        raise ContractError("release testing contract is missing")
    clean = testing.get("finalArtifactValidation")
    if not isinstance(clean, dict) or clean.get("required") is not True:
        raise ContractError("final-artifact validation is not required")
    expected_clean = {
        "repository": REPOSITORY,
        "workflowName": WORKFLOW_NAME,
        "workflowPath": WORKFLOW_PATH,
        "event": "workflow_dispatch",
        "buildJob": BUILD_JOB,
        "validationJob": VALIDATION_JOB,
        "commit": commit,
        "tag": tag,
    }
    for key, value in expected_clean.items():
        if clean.get(key) != value:
            raise ContractError(f"release validation binding is wrong: {key}")
    require_positive(clean.get("repositoryId"), "release repository ID")
    require_positive(clean.get("runId"), "release run ID")
    require_positive(clean.get("runAttempt"), "release run attempt")
    require_string(clean.get("workflowRef"), re.compile(r".{1,500}"), "workflow ref")
    require_string(clean.get("workflowSHA"), COMMIT_RE, "workflow SHA")
    require_string(clean.get("candidateArtifactName"), SAFE_NAME_RE, "candidate artifact name")
    require_string(clean.get("attestationArtifactName"), SAFE_NAME_RE, "attestation artifact name")

    artifacts = manifest.get("artifacts")
    finalized = not allow_unfinalized
    if allow_legacy_envelope and isinstance(artifacts, list) and len(artifacts) == 3:
        finalized = False
    expected_artifacts = expected_publish_paths(version, finalized=finalized)
    if not isinstance(artifacts, list) or len(artifacts) != len(expected_artifacts):
        raise ContractError("release manifest has the wrong artifact count")
    seen: set[str] = set()
    records: list[dict[str, object]] = []
    for entry in artifacts:
        if not isinstance(entry, dict):
            raise ContractError("release artifact entry is invalid")
        name = require_string(entry.get("name"), SAFE_NAME_RE, "release artifact name")
        if name not in expected_artifacts or name in seen:
            raise ContractError("release artifact set is invalid")
        if entry.get("type") != expected_artifacts[name]:
            raise ContractError("release artifact type is invalid")
        digest = require_string(entry.get("sha256"), SHA256_RE, "release artifact digest")
        size = require_positive(entry.get("byteCount"), "release artifact byte count")
        actual_size, actual_digest = secure_digest(
            root / name,
            4 * 1024 * 1024 * 1024,
        )
        if actual_size != size or actual_digest != digest:
            raise ContractError(f"release artifact bytes do not match manifest: {name}")
        seen.add(name)
        records.append(
            {
                "path": name,
                "role": expected_artifacts[name],
                "byteCount": size,
                "sha256": digest,
            }
        )
    if seen != set(expected_artifacts):
        raise ContractError("release manifest artifact set is incomplete")
    checksums = parse_checksums(secure_read(root / "SHA256SUMS", 10 * 1024 * 1024))
    expected_checksums = {
        record["path"]: record["sha256"]
        for record in records
    }
    if checksums != expected_checksums:
        raise ContractError("SHA256SUMS does not match final artifacts")

    rollback = manifest.get("rollback")
    if not isinstance(rollback, dict) or not isinstance(rollback.get("available"), bool):
        raise ContractError("rollback contract is invalid")
    bootstrap = not rollback["available"]
    if bootstrap:
        if rollback.get("bootstrap") is not True or manifest.get("previousBuildVersion") != "0":
            raise ContractError("bootstrap rollback contract is invalid")
    else:
        require_string(rollback.get("version"), VERSION_RE, "rollback version")
        require_string(rollback.get("assetSHA256"), SHA256_RE, "rollback digest")
        require_string(rollback.get("sourceCommit"), COMMIT_RE, "rollback commit")

    if expected is not None:
        pairs = {
            "repositoryId": clean.get("repositoryId"),
            "workflowRef": clean.get("workflowRef"),
            "workflowSHA": clean.get("workflowSHA"),
            "runId": clean.get("runId"),
            "runAttempt": clean.get("runAttempt"),
            "commit": commit,
            "tag": tag,
            "candidateArtifactName": clean.get("candidateArtifactName"),
            "attestationArtifactName": clean.get("attestationArtifactName"),
        }
        for key, value in pairs.items():
            if expected.get(key) != value:
                raise ContractError(f"candidate context mismatch: {key}")
    manifest["_validatedVersion"] = version
    manifest["_validatedBuildVersion"] = build
    manifest["_validatedTeamIdentifier"] = team
    return manifest, records, bootstrap


def envelope_context(arguments: argparse.Namespace) -> dict[str, object]:
    return {
        "repositoryId": int(arguments.repository_id),
        "workflowRef": arguments.workflow_ref,
        "workflowSHA": arguments.workflow_sha,
        "runId": int(arguments.run_id),
        "runAttempt": int(arguments.run_attempt),
        "commit": arguments.commit,
        "tag": arguments.tag,
        "candidateArtifactName": arguments.artifact_name,
        "attestationArtifactName": arguments.attestation_name,
    }


def create_envelope(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    context = envelope_context(arguments)
    manifest, artifact_records, bootstrap = validate_release_manifest(
        root,
        context,
        allow_unfinalized=True,
    )
    version = str(manifest["_validatedVersion"])
    files = list(artifact_records)
    if not bootstrap:
        validation_paths = {
            "validation/previous-Gatebeam.pkg": "rollback-package",
            "validation/previous-release-manifest.json": "rollback-manifest",
            "validation/previous-SHA256SUMS": "rollback-checksums",
        }
        for path, role in validation_paths.items():
            files.append(file_record(root, path, role))
        rollback = manifest["rollback"]
        previous_package = next(
            record for record in files if record["role"] == "rollback-package"
        )
        if previous_package["sha256"] != rollback["assetSHA256"]:
            raise ContractError("rollback package does not match the release manifest")

    document = {
        "schemaVersion": 1,
        "kind": CANDIDATE_KIND,
        "repository": {"fullName": REPOSITORY, "id": context["repositoryId"]},
        "workflow": {
            "name": WORKFLOW_NAME,
            "path": WORKFLOW_PATH,
            "ref": context["workflowRef"],
            "sha": context["workflowSHA"],
            "runId": context["runId"],
            "runAttempt": context["runAttempt"],
            "event": "workflow_dispatch",
            "job": BUILD_JOB,
        },
        "source": {
            "commit": context["commit"],
            "tag": context["tag"],
            "ref": f"refs/tags/{context['tag']}",
        },
        "release": {
            "version": version,
            "buildVersion": manifest["_validatedBuildVersion"],
            "bundleIdentifier": BUNDLE_ID,
            "teamIdentifier": manifest["_validatedTeamIdentifier"],
            "bootstrap": bootstrap,
        },
        "candidateArtifactName": context["candidateArtifactName"],
        "attestationArtifactName": context["attestationArtifactName"],
        "files": sorted(files, key=lambda entry: str(entry["path"])),
    }
    write_json_exclusive(root / "candidate-envelope.json", document)
    envelope_record = file_record(root, "candidate-envelope.json", "candidate-envelope")
    manifest["artifacts"] = [
        *manifest["artifacts"],
        {
            "name": envelope_record["path"],
            "type": envelope_record["role"],
            "byteCount": envelope_record["byteCount"],
            "sha256": envelope_record["sha256"],
        },
    ]
    for private_key in (
        "_validatedVersion",
        "_validatedBuildVersion",
        "_validatedTeamIdentifier",
    ):
        manifest.pop(private_key, None)
    manifest_payload = (
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    replace_regular_file(root / "release-manifest.json", manifest_payload)
    checksum_records = [*artifact_records, envelope_record]
    checksum_payload = "".join(
        f"{record['sha256']}  {record['path']}\n"
        for record in checksum_records
    ).encode("ascii")
    replace_regular_file(root / "SHA256SUMS", checksum_payload)
    validate_release_manifest(root, context)


def expected_context_from_envelope(envelope: dict[str, object]) -> dict[str, object]:
    repository = envelope.get("repository")
    workflow = envelope.get("workflow")
    source = envelope.get("source")
    if not isinstance(repository, dict) or not isinstance(workflow, dict) or not isinstance(source, dict):
        raise ContractError("candidate provenance is missing")
    return {
        "repositoryId": repository.get("id"),
        "workflowRef": workflow.get("ref"),
        "workflowSHA": workflow.get("sha"),
        "runId": workflow.get("runId"),
        "runAttempt": workflow.get("runAttempt"),
        "commit": source.get("commit"),
        "tag": source.get("tag"),
        "candidateArtifactName": envelope.get("candidateArtifactName"),
        "attestationArtifactName": envelope.get("attestationArtifactName"),
    }


def validate_candidate(
    root: pathlib.Path,
    expected: dict[str, object] | None = None,
) -> tuple[dict[str, object], dict[str, object], bool]:
    root = root.absolute()
    root_stat = root.lstat()
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise ContractError("candidate root is unsafe")
    if root.resolve(strict=True) != root:
        raise ContractError("candidate root is not canonical")
    envelope = load_json(root / "candidate-envelope.json", 10 * 1024 * 1024)
    if envelope.get("schemaVersion") != 1 or envelope.get("kind") != CANDIDATE_KIND:
        raise ContractError("candidate envelope schema is invalid")
    repository = envelope.get("repository")
    workflow = envelope.get("workflow")
    source = envelope.get("source")
    release = envelope.get("release")
    if (
        not isinstance(repository, dict)
        or repository != {"fullName": REPOSITORY, "id": repository.get("id")}
        or not isinstance(workflow, dict)
        or not isinstance(source, dict)
        or not isinstance(release, dict)
    ):
        raise ContractError("candidate envelope provenance is invalid")
    require_positive(repository.get("id"), "candidate repository ID")
    workflow_expected = {
        "name": WORKFLOW_NAME,
        "path": WORKFLOW_PATH,
        "event": "workflow_dispatch",
        "job": BUILD_JOB,
    }
    for key, value in workflow_expected.items():
        if workflow.get(key) != value:
            raise ContractError(f"candidate workflow binding is wrong: {key}")
    require_string(workflow.get("ref"), re.compile(r".{1,500}"), "candidate workflow ref")
    require_string(workflow.get("sha"), COMMIT_RE, "candidate workflow SHA")
    require_positive(workflow.get("runId"), "candidate run ID")
    require_positive(workflow.get("runAttempt"), "candidate run attempt")
    commit = require_string(source.get("commit"), COMMIT_RE, "candidate commit")
    tag = require_string(source.get("tag"), re.compile(r"v" + VERSION_RE.pattern), "candidate tag")
    if source.get("ref") != f"refs/tags/{tag}":
        raise ContractError("candidate tag ref is invalid")
    require_string(envelope.get("candidateArtifactName"), SAFE_NAME_RE, "candidate artifact name")
    require_string(envelope.get("attestationArtifactName"), SAFE_NAME_RE, "attestation artifact name")
    context = expected_context_from_envelope(envelope)
    if expected is not None:
        for key, value in expected.items():
            if context.get(key) != value:
                raise ContractError(f"candidate provenance mismatch: {key}")

    manifest, manifest_records, bootstrap = validate_release_manifest(root, context)
    if (
        release.get("version") != manifest["_validatedVersion"]
        or release.get("buildVersion") != manifest["_validatedBuildVersion"]
        or release.get("bundleIdentifier") != BUNDLE_ID
        or release.get("teamIdentifier") != manifest["_validatedTeamIdentifier"]
        or release.get("bootstrap") is not bootstrap
        or source.get("commit") != manifest.get("commit")
        or source.get("tag") != manifest.get("tag")
    ):
        raise ContractError("candidate envelope and release manifest disagree")

    records = envelope.get("files")
    if not isinstance(records, list) or not records:
        raise ContractError("candidate file inventory is missing")
    inventory: dict[str, dict[str, object]] = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "role", "byteCount", "sha256"}:
            raise ContractError("candidate file record is invalid")
        relative = record.get("path")
        if (
            not isinstance(relative, str)
            or pathlib.PurePosixPath(relative).is_absolute()
            or "\\" in relative
            or ".." in pathlib.PurePosixPath(relative).parts
            or relative in inventory
        ):
            raise ContractError("candidate file path is unsafe or duplicated")
        require_positive(record.get("byteCount"), "candidate file byte count")
        require_string(record.get("sha256"), SHA256_RE, "candidate file digest")
        require_string(record.get("role"), SAFE_NAME_RE, "candidate file role")
        actual = file_record(root, relative, str(record["role"]))
        if actual != record:
            raise ContractError(f"candidate file inventory mismatch: {relative}")
        inventory[relative] = record

    version = str(manifest["_validatedVersion"])
    required_inventory = {
        f"Gatebeam-{version}.zip",
        f"Gatebeam-{version}.pkg",
        f"Gatebeam-{version}.dmg",
    }
    if not bootstrap:
        required_inventory.update(
            {
                "validation/previous-Gatebeam.pkg",
                "validation/previous-release-manifest.json",
                "validation/previous-SHA256SUMS",
            }
        )
    if set(inventory) != required_inventory:
        raise ContractError("candidate file inventory has missing or extra paths")
    required_files = required_inventory | {
        "candidate-envelope.json",
        "SHA256SUMS",
        "release-manifest.json",
    }

    actual_files: set[str] = set()
    for directory, names, filenames in os.walk(root, topdown=True, followlinks=False):
        directory_path = pathlib.Path(directory)
        directory_stat = directory_path.lstat()
        if stat.S_ISLNK(directory_stat.st_mode) or not stat.S_ISDIR(directory_stat.st_mode):
            raise ContractError("candidate contains an unsafe directory")
        for name in names:
            child = directory_path / name
            child_stat = child.lstat()
            if stat.S_ISLNK(child_stat.st_mode) or not stat.S_ISDIR(child_stat.st_mode):
                raise ContractError("candidate contains an unsafe directory entry")
        for name in filenames:
            child = directory_path / name
            relative = child.relative_to(root).as_posix()
            entry = child.lstat()
            if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
                raise ContractError("candidate contains a linked or non-regular file")
            actual_files.add(relative)
    if actual_files != required_files:
        raise ContractError("candidate transport contains untracked files")
    return envelope, manifest, bootstrap


def attested_file_records(
    root: pathlib.Path,
    envelope: dict[str, object],
) -> list[dict[str, object]]:
    records = envelope.get("files")
    if not isinstance(records, list):
        raise ContractError("candidate file inventory is missing")
    return sorted(
        [
            *records,
            file_record(root, "candidate-envelope.json", "candidate-envelope"),
            file_record(root, "SHA256SUMS", "checksums"),
            file_record(root, "release-manifest.json", "release-manifest"),
        ],
        key=lambda entry: str(entry["path"]),
    )


def create_attestation(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    expected = envelope_context(arguments)
    envelope, manifest, bootstrap = validate_candidate(root, expected)
    candidate_digest = require_string(arguments.artifact_digest, SHA256_RE, "candidate artifact digest")
    artifact_id = int(arguments.artifact_id)
    if artifact_id <= 0:
        raise ContractError("candidate artifact ID is invalid")
    envelope_payload = secure_read(root / "candidate-envelope.json", 10 * 1024 * 1024)
    document = {
        "schemaVersion": 1,
        "kind": ATTESTATION_KIND,
        "result": "Passed",
        "repository": envelope["repository"],
        "workflow": {
            **envelope["workflow"],
            "job": VALIDATION_JOB,
        },
        "source": envelope["source"],
        "release": envelope["release"],
        "candidateArtifact": {
            "name": arguments.artifact_name,
            "id": artifact_id,
            "digest": f"sha256:{candidate_digest}",
        },
        "candidateEnvelopeSHA256": sha256_bytes(envelope_payload),
        "files": attested_file_records(root, envelope),
        "validations": [
            {"name": name, "passed": True}
            for name in expected_validations(bootstrap)
        ],
        "rollbackTested": not bootstrap,
        "attestationArtifactName": arguments.attestation_name,
        "releaseManifestSHA256": sha256_bytes(
            secure_read(root / "release-manifest.json", 10 * 1024 * 1024)
        ),
        "releaseVersion": manifest["_validatedVersion"],
        "releaseBuildVersion": manifest["_validatedBuildVersion"],
    }
    write_json_exclusive(pathlib.Path(arguments.output).absolute(), document)


def validate_attestation(
    root: pathlib.Path,
    attestation_path: pathlib.Path,
    expected: dict[str, object],
    artifact_id: int,
    artifact_digest: str,
) -> tuple[dict[str, object], dict[str, object]]:
    envelope, manifest, bootstrap = validate_candidate(root, expected)
    attestation = load_json(attestation_path.absolute(), 10 * 1024 * 1024)
    if (
        attestation.get("schemaVersion") != 1
        or attestation.get("kind") != ATTESTATION_KIND
        or attestation.get("result") != "Passed"
        or attestation.get("repository") != envelope.get("repository")
        or attestation.get("source") != envelope.get("source")
        or attestation.get("release") != envelope.get("release")
        or attestation.get("files") != attested_file_records(root, envelope)
        or attestation.get("rollbackTested") is not (not bootstrap)
        or attestation.get("releaseVersion") != manifest["_validatedVersion"]
        or attestation.get("releaseBuildVersion") != manifest["_validatedBuildVersion"]
    ):
        raise ContractError("clean-machine attestation does not match the candidate")
    workflow = attestation.get("workflow")
    envelope_workflow = envelope.get("workflow")
    if not isinstance(workflow, dict) or not isinstance(envelope_workflow, dict):
        raise ContractError("attestation workflow binding is missing")
    if workflow != {**envelope_workflow, "job": VALIDATION_JOB}:
        raise ContractError("attestation workflow binding is invalid")
    candidate_artifact = attestation.get("candidateArtifact")
    if candidate_artifact != {
        "name": expected["candidateArtifactName"],
        "id": artifact_id,
        "digest": f"sha256:{artifact_digest}",
    }:
        raise ContractError("attestation candidate artifact binding is invalid")
    envelope_hash = sha256_bytes(
        secure_read(root / "candidate-envelope.json", 10 * 1024 * 1024)
    )
    manifest_hash = sha256_bytes(
        secure_read(root / "release-manifest.json", 10 * 1024 * 1024)
    )
    if (
        attestation.get("candidateEnvelopeSHA256") != envelope_hash
        or attestation.get("releaseManifestSHA256") != manifest_hash
        or attestation.get("attestationArtifactName") != expected["attestationArtifactName"]
        or attestation.get("validations")
        != [
            {"name": name, "passed": True}
            for name in expected_validations(bootstrap)
        ]
    ):
        raise ContractError("attestation evidence is incomplete or stale")
    return envelope, manifest


def validate_published_release(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    manifest, records, bootstrap = validate_release_manifest(
        root,
        allow_legacy_envelope=True,
    )
    commit = require_string(arguments.commit, COMMIT_RE, "published release commit")
    tag = require_string(
        arguments.tag,
        re.compile(r"v" + VERSION_RE.pattern),
        "published release tag",
    )
    if manifest.get("commit") != commit or manifest.get("tag") != tag:
        raise ContractError("published release source does not match its immutable tag")

    clean = manifest["testing"]["finalArtifactValidation"]
    repository_id = require_positive(clean.get("repositoryId"), "published repository ID")
    run_id = require_positive(clean.get("runId"), "published validation run ID")
    run_attempt = require_positive(
        clean.get("runAttempt"),
        "published validation run attempt",
    )
    expected_ref = f"{REPOSITORY}/{WORKFLOW_PATH}@refs/tags/{tag}"
    if clean.get("workflowRef") != expected_ref or clean.get("workflowSHA") != commit:
        raise ContractError("published validation workflow is not bound to tagged bytes")
    candidate_name = (
        f"gatebeam-final-candidate-{tag}-{commit}-"
        f"run{run_id}-attempt{run_attempt}"
    )
    attestation_name = (
        f"gatebeam-clean-machine-attestation-{tag}-{commit}-"
        f"run{run_id}-attempt{run_attempt}"
    )
    if (
        clean.get("candidateArtifactName") != candidate_name
        or clean.get("attestationArtifactName") != attestation_name
    ):
        raise ContractError("published workflow artifact names are not canonical")

    attestation_path = pathlib.Path(arguments.attestation).absolute()
    attestation = load_json(attestation_path, 10 * 1024 * 1024)
    repository = {"fullName": REPOSITORY, "id": repository_id}
    workflow = {
        "name": WORKFLOW_NAME,
        "path": WORKFLOW_PATH,
        "ref": expected_ref,
        "sha": commit,
        "runId": run_id,
        "runAttempt": run_attempt,
        "event": "workflow_dispatch",
        "job": VALIDATION_JOB,
    }
    source = {"commit": commit, "tag": tag, "ref": f"refs/tags/{tag}"}
    release = {
        "version": manifest["_validatedVersion"],
        "buildVersion": manifest["_validatedBuildVersion"],
        "bundleIdentifier": BUNDLE_ID,
        "teamIdentifier": manifest["_validatedTeamIdentifier"],
        "bootstrap": bootstrap,
    }
    if (
        attestation.get("schemaVersion") != 1
        or attestation.get("kind") != ATTESTATION_KIND
        or attestation.get("result") != "Passed"
        or attestation.get("repository") != repository
        or attestation.get("workflow") != workflow
        or attestation.get("source") != source
        or attestation.get("release") != release
        or attestation.get("rollbackTested") is not (not bootstrap)
        or attestation.get("attestationArtifactName") != attestation_name
        or attestation.get("releaseVersion") != manifest["_validatedVersion"]
        or attestation.get("releaseBuildVersion")
        != manifest["_validatedBuildVersion"]
    ):
        raise ContractError("published clean-machine attestation provenance is invalid")

    candidate_artifact = attestation.get("candidateArtifact")
    if not isinstance(candidate_artifact, dict):
        raise ContractError("published candidate artifact binding is missing")
    require_positive(candidate_artifact.get("id"), "published candidate artifact ID")
    if (
        candidate_artifact.get("name") != candidate_name
        or not isinstance(candidate_artifact.get("digest"), str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", candidate_artifact["digest"]) is None
    ):
        raise ContractError("published candidate artifact binding is invalid")
    published_envelope_hash = require_string(
        attestation.get("candidateEnvelopeSHA256"),
        SHA256_RE,
        "published candidate envelope digest",
    )
    envelope_records = [
        record for record in records
        if record.get("path") == "candidate-envelope.json"
    ]
    if envelope_records and envelope_records[0].get("sha256") != published_envelope_hash:
        raise ContractError("published envelope hash is not publicly recomputable")
    manifest_payload = secure_read(root / "release-manifest.json", 10 * 1024 * 1024)
    if attestation.get("releaseManifestSHA256") != sha256_bytes(manifest_payload):
        raise ContractError("published attestation does not bind the release manifest")
    if attestation.get("validations") != [
        {"name": name, "passed": True}
        for name in expected_validations(bootstrap)
    ]:
        raise ContractError("published attestation validation set is incomplete")

    expected_records = records + [
        file_record(root, "SHA256SUMS", "checksums"),
        file_record(root, "release-manifest.json", "release-manifest"),
    ]
    expected_by_path = {
        str(record["path"]): record
        for record in expected_records
    }
    expected_roles = {
        **{path: str(record["role"]) for path, record in expected_by_path.items()},
    }
    if not bootstrap:
        expected_roles.update(
            {
                "validation/previous-Gatebeam.pkg": "rollback-package",
                "validation/previous-release-manifest.json": "rollback-manifest",
                "validation/previous-SHA256SUMS": "rollback-checksums",
            }
        )
    attested_records = attestation.get("files")
    if not isinstance(attested_records, list):
        raise ContractError("published attestation file inventory is missing")
    inventory: dict[str, dict[str, object]] = {}
    for record in attested_records:
        if not isinstance(record, dict) or set(record) != {
            "path",
            "role",
            "byteCount",
            "sha256",
        }:
            raise ContractError("published attestation file record is invalid")
        path = record.get("path")
        if (
            not isinstance(path, str)
            or path not in expected_roles
            or path in inventory
            or record.get("role") != expected_roles[path]
        ):
            raise ContractError("published attestation file inventory is invalid")
        require_positive(record.get("byteCount"), "published file byte count")
        require_string(record.get("sha256"), SHA256_RE, "published file digest")
        if path in expected_by_path and record != expected_by_path[path]:
            raise ContractError(f"published attestation file bytes disagree: {path}")
        inventory[path] = record
    if set(inventory) != set(expected_roles):
        raise ContractError("published attestation file inventory is incomplete")


def validate_archive_member(info: zipfile.ZipInfo) -> tuple[pathlib.PurePosixPath, bool]:
    name = info.filename
    if (
        not name
        or "\x00" in name
        or "\\" in name
        or name.startswith("/")
        or re.match(r"^[A-Za-z]:", name)
    ):
        raise ContractError("artifact archive contains an unsafe path")
    relative = pathlib.PurePosixPath(name)
    if any(part in ("", ".", "..") for part in relative.parts):
        raise ContractError("artifact archive contains path traversal")
    mode = (info.external_attr >> 16) & 0xFFFF
    is_directory = info.is_dir()
    if mode:
        file_type = stat.S_IFMT(mode)
        expected_type = stat.S_IFDIR if is_directory else stat.S_IFREG
        if file_type not in (0, expected_type):
            raise ContractError("artifact archive contains a linked or special entry")
    if info.flag_bits & 0x1:
        raise ContractError("artifact archive contains an encrypted entry")
    return relative, is_directory


def extract_archive_stream(
    stream: BinaryIO,
    before: os.stat_result,
    archive: pathlib.Path,
    output: pathlib.Path,
    kind: str,
) -> None:
    if output.exists() or output.is_symlink():
        raise ContractError("artifact extraction destination already exists")
    output.mkdir(mode=0o700)
    maximum_files = 64 if kind == "candidate" else 4
    maximum_total = 4 * 1024 * 1024 * 1024 if kind == "candidate" else 10 * 1024 * 1024
    seen: set[str] = set()
    total = 0
    try:
        with zipfile.ZipFile(stream, "r") as bundle:
            infos = bundle.infolist()
            if not infos or len(infos) > maximum_files:
                raise ContractError("artifact archive entry count is invalid")
            for info in infos:
                relative, is_directory = validate_archive_member(info)
                canonical_name = relative.as_posix().rstrip("/")
                if canonical_name in seen:
                    raise ContractError("artifact archive has duplicate paths")
                seen.add(canonical_name)
                total += info.file_size
                if total > maximum_total or info.file_size > maximum_total:
                    raise ContractError("artifact archive is too large")
                destination = output.joinpath(*relative.parts)
                if is_directory:
                    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
                    continue
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                if destination.exists() or destination.is_symlink():
                    raise ContractError("artifact extraction path already exists")
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                descriptor = os.open(destination, flags, 0o600)
                try:
                    with bundle.open(info, "r") as source:
                        remaining = info.file_size
                        while remaining:
                            chunk = source.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise ContractError("artifact archive entry was truncated")
                            os.write(descriptor, chunk)
                            remaining -= len(chunk)
                        if source.read(1):
                            raise ContractError("artifact archive entry exceeded metadata")
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
        verify_stable_descriptor(stream.fileno(), before, archive)
    except (zipfile.BadZipFile, OSError) as error:
        raise ContractError("artifact archive extraction failed") from error


def extract_archive(arguments: argparse.Namespace) -> None:
    archive = pathlib.Path(arguments.archive).absolute()
    output = pathlib.Path(arguments.output).absolute()
    stream, before, archive_digest = secure_digest_stream(
        archive,
        4 * 1024 * 1024 * 1024,
    )
    if archive_digest != arguments.expected_digest:
        stream.close()
        raise ContractError("downloaded artifact archive digest is wrong")
    with stream:
        extract_archive_stream(
            stream,
            before,
            archive,
            output,
            arguments.kind,
        )


def metadata(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    _, manifest, bootstrap = validate_candidate(root)
    rollback = manifest["rollback"]
    app_archive = next(
        entry
        for entry in manifest["artifacts"]
        if entry["type"] == "app-archive"
    )
    fields = {
        "version": str(manifest["_validatedVersion"]),
        "build-version": str(manifest["_validatedBuildVersion"]),
        "team-id": str(manifest["_validatedTeamIdentifier"]),
        "bootstrap": "1" if bootstrap else "0",
        "previous-version": "" if bootstrap else str(rollback["version"]),
        "previous-build-version": "" if bootstrap else str(manifest["previousBuildVersion"]),
        "previous-package": "" if bootstrap else "validation/previous-Gatebeam.pkg",
        "previous-commit": "" if bootstrap else str(rollback["sourceCommit"]),
        "app-archive-sha256": str(app_archive["sha256"]),
    }
    value = fields[arguments.field]
    if "\n" in value:
        raise ContractError("candidate metadata is unsafe")
    print(value)


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_context(target: argparse.ArgumentParser) -> None:
        target.add_argument("--repository-id", required=True, type=int)
        target.add_argument("--workflow-ref", required=True)
        target.add_argument("--workflow-sha", required=True)
        target.add_argument("--run-id", required=True, type=int)
        target.add_argument("--run-attempt", required=True, type=int)
        target.add_argument("--commit", required=True)
        target.add_argument("--tag", required=True)
        target.add_argument("--artifact-name", required=True)
        target.add_argument("--attestation-name", required=True)

    create = subparsers.add_parser("create-envelope")
    create.add_argument("--root", required=True)
    add_context(create)

    validate = subparsers.add_parser("validate-candidate")
    validate.add_argument("--root", required=True)
    add_context(validate)

    attest = subparsers.add_parser("create-attestation")
    attest.add_argument("--root", required=True)
    attest.add_argument("--output", required=True)
    attest.add_argument("--artifact-id", required=True, type=int)
    attest.add_argument("--artifact-digest", required=True)
    add_context(attest)

    verify = subparsers.add_parser("verify-attestation")
    verify.add_argument("--root", required=True)
    verify.add_argument("--attestation", required=True)
    verify.add_argument("--artifact-id", required=True, type=int)
    verify.add_argument("--artifact-digest", required=True)
    add_context(verify)

    published = subparsers.add_parser("validate-published")
    published.add_argument("--root", required=True)
    published.add_argument("--attestation", required=True)
    published.add_argument("--commit", required=True)
    published.add_argument("--tag", required=True)

    extract = subparsers.add_parser("extract")
    extract.add_argument("--archive", required=True)
    extract.add_argument("--output", required=True)
    extract.add_argument("--expected-digest", required=True)
    extract.add_argument("--kind", choices=("candidate", "attestation"), required=True)

    metadata_parser = subparsers.add_parser("metadata")
    metadata_parser.add_argument("--root", required=True)
    metadata_parser.add_argument(
        "--field",
        choices=(
            "version",
            "build-version",
            "team-id",
            "bootstrap",
            "previous-version",
            "previous-build-version",
            "previous-package",
            "previous-commit",
            "app-archive-sha256",
        ),
        required=True,
    )

    arguments = parser.parse_args()
    try:
        if arguments.command == "create-envelope":
            create_envelope(arguments)
        elif arguments.command == "validate-candidate":
            validate_candidate(pathlib.Path(arguments.root), envelope_context(arguments))
        elif arguments.command == "create-attestation":
            create_attestation(arguments)
        elif arguments.command == "verify-attestation":
            expected = envelope_context(arguments)
            validate_attestation(
                pathlib.Path(arguments.root),
                pathlib.Path(arguments.attestation),
                expected,
                arguments.artifact_id,
                require_string(arguments.artifact_digest, SHA256_RE, "candidate artifact digest"),
            )
        elif arguments.command == "validate-published":
            validate_published_release(arguments)
        elif arguments.command == "extract":
            require_string(arguments.expected_digest, SHA256_RE, "artifact archive digest")
            extract_archive(arguments)
        elif arguments.command == "metadata":
            metadata(arguments)
    except (ContractError, OSError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
