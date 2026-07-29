#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV ZDOTDIR CDPATH PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PYTHONNOUSERSITE=1

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
CONTRACT="$ROOT_DIR/scripts/release_artifact_contract.py"
TEST_ROOT="$(/usr/bin/mktemp -d "/private/tmp/gatebeam-artifact-contract.XXXXXX")"
COMMIT="1111111111111111111111111111111111111111"
TAG="v0.5.0"
REPOSITORY_ID=987654321
RUN_ID=123457
RUN_ATTEMPT=1
WORKFLOW_REF="naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0"
CANDIDATE_NAME="gatebeam-final-candidate-v0.5.0-$COMMIT-run$RUN_ID-attempt$RUN_ATTEMPT"
ATTESTATION_NAME="gatebeam-clean-machine-attestation-v0.5.0-$COMMIT-run$RUN_ID-attempt$RUN_ATTEMPT"
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
}

context_args() {
  print -r -- \
    --repository-id "$REPOSITORY_ID" \
    --workflow-ref "$WORKFLOW_REF" \
    --workflow-sha "$COMMIT" \
    --run-id "$RUN_ID" \
    --run-attempt "$RUN_ATTEMPT" \
    --commit "$COMMIT" \
    --tag "$TAG" \
    --artifact-name "$CANDIDATE_NAME" \
    --attestation-name "$ATTESTATION_NAME"
}

typeset -a CONTEXT_ARGS
CONTEXT_ARGS=(
  --repository-id "$REPOSITORY_ID"
  --workflow-ref "$WORKFLOW_REF"
  --workflow-sha "$COMMIT"
  --run-id "$RUN_ID"
  --run-attempt "$RUN_ATTEMPT"
  --commit "$COMMIT"
  --tag "$TAG"
  --artifact-name "$CANDIDATE_NAME"
  --attestation-name "$ATTESTATION_NAME"
)

new_candidate() {
  local name="$1"
  local bootstrap="${2:-0}"
  local candidate="$TEST_ROOT/$name"
  /bin/mkdir -p "$candidate"
  /usr/bin/python3 -I -E -s - \
    "$candidate" "$bootstrap" "$COMMIT" "$TAG" \
    "$REPOSITORY_ID" "$RUN_ID" "$RUN_ATTEMPT" \
    "$WORKFLOW_REF" "$CANDIDATE_NAME" "$ATTESTATION_NAME" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

(
    root_value,
    bootstrap_value,
    commit,
    tag,
    repository_id,
    run_id,
    run_attempt,
    workflow_ref,
    candidate_name,
    attestation_name,
) = sys.argv[1:]
root = pathlib.Path(root_value)
bootstrap = bootstrap_value == "1"
version = tag[1:]
artifacts = {
    f"Gatebeam-{version}.zip": ("app-archive", b"fixture final app archive\n"),
    f"Gatebeam-{version}.pkg": ("installer-package", b"fixture final installer\n"),
    f"Gatebeam-{version}.dmg": ("disk-image", b"fixture final disk image\n"),
}
manifest_artifacts = []
checksums = []
for name, (kind, payload) in artifacts.items():
    (root / name).write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    checksums.append(f"{digest}  {name}")
    manifest_artifacts.append(
        {
            "name": name,
            "type": kind,
            "byteCount": len(payload),
            "sha256": digest,
        }
    )
(root / "SHA256SUMS").write_text("\n".join(checksums) + "\n", encoding="ascii")

rollback = {
    "available": not bootstrap,
    "procedure": "docs/RELEASING.md#rollback-and-revocation",
}
previous_build = "0"
if bootstrap:
    rollback["bootstrap"] = True
else:
    validation = root / "validation"
    validation.mkdir()
    previous_package = b"fixture immutable previous package\n"
    previous_digest = hashlib.sha256(previous_package).hexdigest()
    (validation / "previous-Gatebeam.pkg").write_bytes(previous_package)
    (validation / "previous-release-manifest.json").write_text(
        json.dumps(
            {
                "schemaVersion": 3,
                "product": "Gatebeam",
                "version": "0.4.0",
                "buildVersion": "4",
                "commit": "2" * 40,
            },
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    (validation / "previous-SHA256SUMS").write_text(
        f"{previous_digest}  Gatebeam-0.4.0.pkg\n",
        encoding="ascii",
    )
    previous_build = "4"
    rollback.update(
        {
            "version": "0.4.0",
            "releaseURL": "https://github.com/naifuliang/gatebeam/releases/tag/v0.4.0",
            "assetName": "Gatebeam-0.4.0.pkg",
            "assetSHA256": previous_digest,
            "sourceCommit": "2" * 40,
            "sourceManifestURL": "https://github.com/naifuliang/gatebeam/releases/download/v0.4.0/release-manifest.json",
            "sourceChecksumsURL": "https://github.com/naifuliang/gatebeam/releases/download/v0.4.0/SHA256SUMS",
        }
    )

manifest = {
    "schemaVersion": 4,
    "product": "Gatebeam",
    "commit": commit,
    "tag": tag,
    "version": version,
    "buildVersion": "5",
    "previousBuildVersion": previous_build,
    "bundleIdentifier": "io.github.naifuliang.gatebeam",
    "teamIdentifier": "ABCDE12345",
    "artifacts": manifest_artifacts,
    "testing": {
        "finalArtifactValidation": {
            "required": True,
            "repository": "naifuliang/gatebeam",
            "repositoryId": int(repository_id),
            "workflowName": "Release final-artifact validation",
            "workflowPath": ".github/workflows/release-validation.yml",
            "workflowRef": workflow_ref,
            "workflowSHA": commit,
            "runId": int(run_id),
            "runAttempt": int(run_attempt),
            "event": "workflow_dispatch",
            "buildJob": "build-candidate",
            "validationJob": "clean-machine",
            "commit": commit,
            "tag": tag,
            "candidateArtifactName": candidate_name,
            "attestationArtifactName": attestation_name,
        }
    },
    "rollback": rollback,
}
(root / "release-manifest.json").write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
for path in root.rglob("*"):
    if path.is_file():
        os.chmod(path, 0o600)
PY
  print -r -- "$candidate"
}

create_envelope() {
  /usr/bin/python3 -I -E -s "$CONTRACT" create-envelope \
    --root "$1" \
    "${CONTEXT_ARGS[@]}"
}

validate_candidate() {
  /usr/bin/python3 -I -E -s "$CONTRACT" validate-candidate \
    --root "$1" \
    "${CONTEXT_ARGS[@]}"
}

expect_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local output="$TEST_ROOT/failure.log"
  if "$@" >"$output" 2>&1; then
    fail_test "$label unexpectedly succeeded"
  elif /usr/bin/grep -Fq "$expected" "$output"; then
    pass "$label"
  else
    fail_test "$label reported the wrong fail-closed reason"
  fi
}

candidate="$(new_candidate valid-history)"
create_envelope "$candidate"
if validate_candidate "$candidate"; then
  pass "non-bootstrap candidate contract"
else
  fail_test "non-bootstrap candidate contract"
fi

bootstrap_candidate="$(new_candidate valid-bootstrap 1)"
create_envelope "$bootstrap_candidate"
if validate_candidate "$bootstrap_candidate"; then
  pass "bootstrap candidate contract"
else
  fail_test "bootstrap candidate contract"
fi

attestation_parent="$TEST_ROOT/attestation"
/bin/mkdir "$attestation_parent"
attestation="$attestation_parent/clean-machine-attestation.json"
/usr/bin/python3 -I -E -s "$CONTRACT" create-attestation \
  --root "$candidate" \
  --output "$attestation" \
  --artifact-id 777 \
  --artifact-digest "$(printf 'a%.0s' {1..64})" \
  "${CONTEXT_ARGS[@]}"
if /usr/bin/python3 -I -E -s "$CONTRACT" verify-attestation \
     --root "$candidate" \
     --attestation "$attestation" \
     --artifact-id 777 \
     --artifact-digest "$(printf 'a%.0s' {1..64})" \
     "${CONTEXT_ARGS[@]}"; then
  pass "attestation binds exact candidate bytes"
else
  fail_test "attestation binds exact candidate bytes"
fi
if /usr/bin/python3 -I -E -s - "$candidate" "$attestation" <<'PY'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
with (root / "release-manifest.json").open("rb") as stream:
    manifest = json.load(stream)
with pathlib.Path(sys.argv[2]).open("rb") as stream:
    attestation = json.load(stream)
envelope = (root / "candidate-envelope.json").read_bytes()
digest = hashlib.sha256(envelope).hexdigest()
records = [
    entry for entry in manifest["artifacts"]
    if entry.get("name") == "candidate-envelope.json"
]
checksums = dict(
    line.rstrip("\n").split("  ", 1)[::-1]
    for line in (root / "SHA256SUMS").read_text(encoding="ascii").splitlines(True)
)
if (
    len(records) != 1
    or records[0].get("type") != "candidate-envelope"
    or records[0].get("sha256") != digest
    or records[0].get("byteCount") != len(envelope)
    or checksums.get("candidate-envelope.json") != digest
    or attestation.get("candidateEnvelopeSHA256") != digest
):
    raise SystemExit(1)
PY
then
  pass "public assets recompute candidate envelope SHA-256"
else
  fail_test "public assets recompute candidate envelope SHA-256"
fi

expect_failure \
  "attestation artifact ID replay" \
  "attestation candidate artifact binding is invalid" \
  /usr/bin/python3 -I -E -s "$CONTRACT" verify-attestation \
    --root "$candidate" \
    --attestation "$attestation" \
    --artifact-id 778 \
    --artifact-digest "$(printf 'a%.0s' {1..64})" \
    "${CONTEXT_ARGS[@]}"

expect_failure \
  "cross-attempt candidate replay" \
  "candidate provenance mismatch: runAttempt" \
  /usr/bin/python3 -I -E -s "$CONTRACT" validate-candidate \
    --root "$candidate" \
    --repository-id "$REPOSITORY_ID" \
    --workflow-ref "$WORKFLOW_REF" \
    --workflow-sha "$COMMIT" \
    --run-id "$RUN_ID" \
    --run-attempt 2 \
    --commit "$COMMIT" \
    --tag "$TAG" \
    --artifact-name "$CANDIDATE_NAME" \
    --attestation-name "$ATTESTATION_NAME"

expect_failure \
  "cross-repository candidate replay" \
  "candidate provenance mismatch: repositoryId" \
  /usr/bin/python3 -I -E -s "$CONTRACT" validate-candidate \
    --root "$candidate" \
    --repository-id 42 \
    --workflow-ref "$WORKFLOW_REF" \
    --workflow-sha "$COMMIT" \
    --run-id "$RUN_ID" \
    --run-attempt "$RUN_ATTEMPT" \
    --commit "$COMMIT" \
    --tag "$TAG" \
    --artifact-name "$CANDIDATE_NAME" \
    --attestation-name "$ATTESTATION_NAME"

tampered="$(new_candidate tampered)"
create_envelope "$tampered"
print -r -- "changed" >>"$tampered/Gatebeam-0.5.0.pkg"
expect_failure \
  "candidate byte tampering" \
  "release artifact bytes do not match manifest" \
  validate_candidate "$tampered"

extra="$(new_candidate extra-file)"
create_envelope "$extra"
print -r -- "unexpected" >"$extra/untracked.txt"
expect_failure \
  "untracked candidate file" \
  "candidate transport contains untracked files" \
  validate_candidate "$extra"

linked="$(new_candidate linked-file)"
create_envelope "$linked"
/bin/rm "$linked/Gatebeam-0.5.0.dmg"
/bin/ln -s Gatebeam-0.5.0.pkg "$linked/Gatebeam-0.5.0.dmg"
expect_failure \
  "candidate symbolic link" \
  "unsafe release file" \
  validate_candidate "$linked"

hardlinked="$(new_candidate hardlinked-file)"
create_envelope "$hardlinked"
/bin/rm "$hardlinked/Gatebeam-0.5.0.dmg"
/bin/ln "$hardlinked/Gatebeam-0.5.0.pkg" "$hardlinked/Gatebeam-0.5.0.dmg"
expect_failure \
  "candidate hard link" \
  "unsafe release file" \
  validate_candidate "$hardlinked"

archive="$TEST_ROOT/candidate.zip"
/usr/bin/python3 -I -E -s - "$candidate" "$archive" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_STORED) as bundle:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            bundle.write(path, path.relative_to(root).as_posix())
PY
archive_digest="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
extracted="$TEST_ROOT/extracted"
if /usr/bin/python3 -I -E -s "$CONTRACT" extract \
     --archive "$archive" \
     --output "$extracted" \
     --expected-digest "$archive_digest" \
     --kind candidate &&
   validate_candidate "$extracted"; then
  pass "safe candidate artifact extraction"
else
  fail_test "safe candidate artifact extraction"
fi

descriptor_archive="$TEST_ROOT/descriptor-bound.zip"
replacement_archive="$TEST_ROOT/replacement.zip"
descriptor_output="$TEST_ROOT/descriptor-output"
if /usr/bin/python3 -I -E -s - \
    "$CONTRACT" "$descriptor_archive" "$replacement_archive" "$descriptor_output" <<'PY'
import importlib.util
import os
import pathlib
import sys
import zipfile

sys.dont_write_bytecode = True
contract_path = pathlib.Path(sys.argv[1])
archive = pathlib.Path(sys.argv[2])
replacement = pathlib.Path(sys.argv[3])
output = pathlib.Path(sys.argv[4])
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as bundle:
    bundle.writestr("trusted.txt", b"trusted descriptor bytes\n")
with zipfile.ZipFile(replacement, "w", compression=zipfile.ZIP_STORED) as bundle:
    bundle.writestr("replaced.txt", b"path replacement bytes\n")

spec = importlib.util.spec_from_file_location("release_artifact_contract", contract_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

stream, before, digest = module.secure_digest_stream(archive, 1024 * 1024)
rejected = False
try:
    assert len(digest) == 64
    os.replace(replacement, archive)
    try:
        module.extract_archive_stream(
            stream,
            before,
            archive,
            output,
            "candidate",
        )
    except module.ContractError as error:
        assert "changed while reading" in str(error)
        rejected = True
finally:
    stream.close()
assert not (output / "replaced.txt").exists()
if not rejected:
    assert (output / "trusted.txt").read_bytes() == b"trusted descriptor bytes\n"
PY
then
  pass "archive extraction rejects os.replace or remains on the digested descriptor"
else
  fail_test "archive extraction descriptor binding"
fi

traversal_archive="$TEST_ROOT/traversal.zip"
/usr/bin/python3 -I -E -s - "$traversal_archive" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], "w") as bundle:
    bundle.writestr("../outside", b"escape")
PY
expect_failure \
  "artifact path traversal" \
  "artifact archive contains path traversal" \
  /usr/bin/python3 -I -E -s "$CONTRACT" extract \
    --archive "$traversal_archive" \
    --output "$TEST_ROOT/traversal-output" \
    --expected-digest "$(/usr/bin/shasum -a 256 "$traversal_archive" | /usr/bin/awk '{print $1}')" \
    --kind candidate

symlink_archive="$TEST_ROOT/symlink.zip"
/usr/bin/python3 -I -E -s - "$symlink_archive" <<'PY'
import stat
import sys
import zipfile
entry = zipfile.ZipInfo("linked")
entry.create_system = 3
entry.external_attr = (stat.S_IFLNK | 0o777) << 16
with zipfile.ZipFile(sys.argv[1], "w") as bundle:
    bundle.writestr(entry, "target")
PY
expect_failure \
  "artifact symbolic-link entry" \
  "artifact archive contains a linked or special entry" \
  /usr/bin/python3 -I -E -s "$CONTRACT" extract \
    --archive "$symlink_archive" \
    --output "$TEST_ROOT/symlink-output" \
    --expected-digest "$(/usr/bin/shasum -a 256 "$symlink_archive" | /usr/bin/awk '{print $1}')" \
    --kind candidate

expect_failure \
  "artifact protected digest mismatch" \
  "downloaded artifact archive digest is wrong" \
  /usr/bin/python3 -I -E -s "$CONTRACT" extract \
    --archive "$archive" \
    --output "$TEST_ROOT/digest-output" \
    --expected-digest "$(printf 'b%.0s' {1..64})" \
    --kind candidate
if [[ -e "$TEST_ROOT/digest-output" || -L "$TEST_ROOT/digest-output" ]]; then
  fail_test "digest mismatch created an extraction destination"
fi

print -r -- "Final artifact contract tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
