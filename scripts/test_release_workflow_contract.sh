#!/bin/zsh -f
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV ZDOTDIR CDPATH PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PYTHONNOUSERSITE=1

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"

/usr/bin/python3 -I -E -s - \
  "$ROOT_DIR/.github/workflows/release-validation.yml" \
  "$ROOT_DIR/.github/workflows/ci.yml" \
  "$ROOT_DIR/scripts/release_formal.sh" \
  "$ROOT_DIR/scripts/publish_validated_release.sh" \
  "$ROOT_DIR/scripts/prepare_release_candidate.sh" \
  "$ROOT_DIR/scripts/release_candidate_internal.sh" \
  "$ROOT_DIR/scripts/validate_final_candidate.sh" \
  "$ROOT_DIR/scripts/release_container_contract.py" \
  "$ROOT_DIR/scripts/release_history_contract.py" \
  "$ROOT_DIR/scripts/test_final_candidate_validator.sh" \
  "$ROOT_DIR/scripts/test_formal_publish.sh" <<'PY'
import pathlib
import re
import sys

(
    workflow_path,
    ci_path,
    release_path,
    publisher_path,
    prepare_path,
    driver_path,
    validator_path,
    container_path,
    history_path,
    validator_test_path,
    publisher_test_path,
) = [
    pathlib.Path(value) for value in sys.argv[1:]
]
workflow = workflow_path.read_text(encoding="utf-8")
ci = ci_path.read_text(encoding="utf-8")
release = release_path.read_text(encoding="utf-8")
publisher = publisher_path.read_text(encoding="utf-8")
prepare = prepare_path.read_text(encoding="utf-8")
driver = driver_path.read_text(encoding="utf-8")
validator = validator_path.read_text(encoding="utf-8")
container = container_path.read_text(encoding="utf-8")
history = history_path.read_text(encoding="utf-8")
validator_test = validator_test_path.read_text(encoding="utf-8")
publisher_test = publisher_test_path.read_text(encoding="utf-8")

if ci.count("- name: Run final candidate validator behavior tests") != 1 or (
    ci.count("run: ./scripts/test_final_candidate_validator.sh") != 1
):
    raise SystemExit("CI does not execute the final candidate validator behavior suite")

required_workflow_fragments = [
    "name: Release final-artifact validation",
    "workflow_dispatch:",
    "ci_run_id:",
    "bootstrap:",
    "group: gatebeam-formal-release",
    "cancel-in-progress: false",
    "contents: read",
    "build-candidate:",
    "name: Build, sign, notarize, and freeze final candidate",
    "clean-machine:",
    "name: Validate frozen candidate on clean macOS",
    "needs: build-candidate",
    "attestation-artifact-id: ${{ steps.upload-attestation.outputs.artifact-id }}",
    "attestation-artifact-digest: ${{ steps.upload-attestation.outputs.artifact-digest }}",
    "artifact-ids: ${{ needs.build-candidate.outputs.artifact-id }}",
    "GATEBEAM_CANDIDATE_ARTIFACT_DIGEST: ${{ needs.build-candidate.outputs.artifact-digest }}",
    "./scripts/validate_final_candidate.sh",
    "publish-release:",
    "contents: write",
    "GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID: ${{ github.run_id }}",
    "./scripts/release_formal.sh",
]
for fragment in required_workflow_fragments:
    if workflow.count(fragment) != 1:
        raise SystemExit(f"workflow contract missing or duplicated: {fragment}")

step_order = [
    "Check out release source",
    "Verify release invocation",
    "Configure signing and notarization credentials",
    "Prepare hash-bound final candidate",
    "Upload final candidate",
    "Cleanup signing credentials",
    "Check out release source",
    "Download exact final candidate",
    "Validate signature, notarization, install, upgrade, rollback, and uninstall",
    "Upload clean-machine attestation",
    "Check out release source for publisher",
    "Configure private publisher token",
    "Publish exact validated bytes immutably",
    "Cleanup publisher token",
]
cursor = -1
for step in step_order:
    next_cursor = workflow.find(f"- name: {step}", cursor + 1)
    if next_cursor <= cursor:
        raise SystemExit(f"workflow step order is wrong: {step}")
    cursor = next_cursor

pins = {
    "actions/checkout": "11d5960a326750d5838078e36cf38b85af677262",
    "actions/upload-artifact": "ea165f8d65b6e75b540449e92b4886f43607fa02",
    "actions/download-artifact": "d3f86a106a0bac45b974a628896c90dbdf5c8093",
}
for action, commit in pins.items():
    uses = re.findall(rf"uses: {re.escape(action)}@([A-Za-z0-9._-]+)", workflow)
    if not uses or any(value != commit for value in uses):
        raise SystemExit(f"{action} is not pinned to the reviewed commit")
if re.search(r"uses:\s+[^@\s]+@v[0-9]", workflow):
    raise SystemExit("release workflow contains a mutable major-version action ref")

build_start = workflow.index("  build-candidate:")
clean_start = workflow.index("  clean-machine:")
publish_start = workflow.index("  publish-release:")
build_job = workflow[build_start:clean_start]
clean_job = workflow[clean_start:publish_start]
publish_job = workflow[publish_start:]
if "environment: formal-release" not in build_job or "environment:" in clean_job:
    raise SystemExit("signing environment is not isolated to the build job")
if (
    "environment: formal-release" not in publish_job
    or "actions: read" not in publish_job
    or "contents: write" not in publish_job
):
    raise SystemExit("publisher is not isolated in the protected write environment")
for forbidden in (
    "GATEBEAM_DEVELOPER_ID_P12_BASE64",
    "GATEBEAM_DEVELOPER_ID_P12_PASSWORD",
    "GATEBEAM_NOTARY_PRIVATE_KEY_BASE64",
    "GATEBEAM_NOTARY_KEY_ID",
    "GATEBEAM_NOTARY_ISSUER_ID",
    "notarytool",
    "codesign",
    "productsign",
    "build_app.sh",
    "package_pkg.sh",
    "package_dmg.sh",
):
    if forbidden in clean_job:
        raise SystemExit(f"clean job can access build/signing behavior: {forbidden}")
    if forbidden in publish_job:
        raise SystemExit(f"publisher can access build/signing behavior: {forbidden}")
if "artifact-ids:" not in clean_job or "name: ${{ needs.build-candidate.outputs.artifact-name }}" in clean_job:
    raise SystemExit("clean job is not downloading by immutable artifact ID")
if clean_job.index("Download exact final candidate") > clean_job.index("Validate signature, notarization"):
    raise SystemExit("clean job validates before downloading the frozen candidate")
if "if-no-files-found: error" not in build_job or "compression-level: 0" not in build_job:
    raise SystemExit("candidate upload is not fail-closed and byte-stable")
if (
    "needs:\n      - build-candidate\n      - clean-machine" not in publish_job
    or "GATEBEAM_RELEASE_CI_RUN_ID: ${{ inputs.ci_run_id }}" not in publish_job
    or "GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID: ${{ github.run_id }}" not in publish_job
):
    raise SystemExit("publisher is not bound to both successful upstream jobs and this run")
if (
    'print -rn -- "$GITHUB_RUNTIME_TOKEN" >"$token_path"' not in publish_job
    or '/bin/chmod 600 "$token_path"' not in publish_job
    or "./scripts/release_formal.sh" not in publish_job
):
    raise SystemExit("publisher does not use the private file-backed token entry")

if 'exec /bin/zsh -f "$PUBLISH_SCRIPT" "$@"' not in release:
    raise SystemExit("release_formal does not route its public entry to the validated publisher")
if 'exec /bin/zsh -f "$RELEASE_DRIVER" "$@"' not in prepare:
    raise SystemExit("candidate entry no longer calls the private release driver")
if "GATEBEAM_RELEASE_ENTRYPOINT" in release or "GATEBEAM_RELEASE_ENTRYPOINT" in driver:
    raise SystemExit("release entrypoint bypass is still present")
for forbidden in (
    "build_app.sh",
    "package_pkg.sh",
    "package_dmg.sh",
    "notarytool",
    "stapler staple",
    "productsign",
):
    if forbidden in publisher:
        raise SystemExit(f"publisher can rebuild or mutate candidate bytes: {forbidden}")
for required in (
    "verify-attestation",
    "actions/runs/$run_id/artifacts?per_page=100",
    "workflow_run.get(\"id\")",
    "run.get(\"run_attempt\")",
    "run.get(\"head_sha\")",
    "run.get(\"head_branch\")",
    'run.get("status") != "in_progress"',
    '"Publish exact validated bytes immutably"',
    "validate_publisher_context",
    "entry.get(\"digest\")",
    "create_remote_draft",
    "upload_remote_assets",
    "publish_remote_draft",
    "recover_remote_draft",
    "recover_uploaded_asset",
    "Publication nonce:",
    "GITHUB_HTTP_STATUS",
    "fetch_paginated_array",
    "candidate-envelope.json",
    "git/ref/tags/$RELEASE_TAG",
    "$endpoint?per_page=100&page=$page",
    "/bin/mv -- \"$PUBLISH_STAGING\" \"$RELEASE_DIR\"",
):
    if required not in publisher:
        raise SystemExit(f"publisher is missing a trust binding: {required}")
for required in (
    "app-stapled",
    "pkg-stapled",
    "dmg-stapled",
    '"$INSTALLER" -pkg',
    "after-app-swap",
    "create-attestation",
    "release_container_contract.py",
    "validate-pkg",
    "validate-pkg-toc",
    "validate-raw-pkg",
    "validate-expanded-pkg-root",
    "validate-dmg",
    "extract-app-zip",
):
    if required not in validator:
        raise SystemExit(f"clean-machine validator is missing: {required}")
for required in (
    "Distribution packages are forbidden",
    "APP_LAYOUT",
    "casefold",
    "validate_package_info",
    "parse_odc_cpio",
    "reject_sparse=True",
):
    if required not in container:
        raise SystemExit(f"container contract is missing: {required}")
for required in (
    "SEMVER",
    "parse_semver",
    "prerelease",
    "precedence",
    "select-highest",
):
    if required not in history:
        raise SystemExit(f"SemVer history contract is missing: {required}")
for required in (
    "distribution-js",
    "app-casefold-collision",
    "app-unicode-collision",
    "pkg-xar-duplicate",
    "pkg-cpio-bomb",
    "pkg-sparse",
    "dmg-sparse",
    "fixed productsign flat-PKG signature and timestamp TOC",
    "host Apple-signed flat-PKG XAR TOC compatibility",
    "signed XAR algorithm, range, chain, and overlap attacks fail closed",
):
    if required not in validator_test:
        raise SystemExit(f"validator attack matrix is missing: {required}")
for required in (
    "post-response-loss",
    "upload-response-loss",
    "patch-response-loss",
    "post-loss-page2",
    "for mutation in post upload patch",
    "for code in 401 403 404 500",
    'state.get("assets") == []',
    "two concurrent publishers produce one immutable winner",
    "completed final run cannot be replayed by a manual publisher",
    "semver-spec-precedence",
):
    if required not in publisher_test:
        raise SystemExit(f"publisher attack matrix is missing: {required}")
for source_name, source in {
    "public release entry": release,
    "private candidate driver": driver,
    "publisher": publisher,
    "validator": validator,
}.items():
    if "/usr/bin/plutil -p" in source:
        raise SystemExit(f"{source_name} uses host-dependent plutil JSON validation")
PY

print -r -- "Release workflow contract tests passed"
