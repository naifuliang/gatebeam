#!/bin/zsh -f
set -euo pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV ZDOTDIR CDPATH PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PYTHONNOUSERSITE=1

ROOT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "/private/tmp/gatebeam-validator-tests.XXXXXX")"
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
  [[ $# -lt 2 ]] || /usr/bin/sed -n '1,100p' "$2" >&2
}

new_fixture() {
  local name="$1"
  local scenario="$2"
  local fixture="$TEST_ROOT/$name/Gatebeam Fixture"
  local tools="$fixture/test-tools"
  local candidate="$fixture/candidate"
  /bin/mkdir -p \
    "$fixture/scripts/pkg" \
    "$fixture/Resources" \
    "$fixture/test-system/Applications" \
    "$fixture/expanded/Payload" \
    "$fixture/expanded/Scripts" \
    "$fixture/dmg-root" \
    "$tools" \
    "$candidate"
  print -r -- "Gatebeam final artifact test fixture v1" \
    >"$fixture/.gatebeam-final-artifact-test-fixture"
  /bin/cp "$fixture/.gatebeam-final-artifact-test-fixture" \
    "$tools/.gatebeam-final-artifact-test-fixture"
  /bin/cp "$ROOT_DIR/scripts/validate_final_candidate.sh" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/release_artifact_contract.py" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/release_container_contract.py" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/verify_release.sh" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/install_app.sh" "$fixture/scripts/"
  /bin/cp "$ROOT_DIR/scripts/pkg/postinstall" "$fixture/scripts/pkg/"
  /bin/cp "$ROOT_DIR/scripts/pkg/migrate_legacy_install.sh" "$fixture/scripts/pkg/"

  /bin/mkdir -p \
    "$fixture/source-app/Contents/MacOS" \
    "$fixture/source-app/Contents/Resources" \
    "$fixture/source-app/Contents/_CodeSignature"
  print -r -- "fixture executable" >"$fixture/source-app/Contents/MacOS/Gatebeam"
  /bin/chmod 755 "$fixture/source-app/Contents/MacOS/Gatebeam"
  print -r -- "fixture icon" >"$fixture/source-app/Contents/Resources/AppIcon.icns"
  print -r -- "fixture signature resources" \
    >"$fixture/source-app/Contents/_CodeSignature/CodeResources"
  /usr/bin/python3 -I -E -s - "$fixture/source-app/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(
    plistlib.dumps(
        {
            "CFBundleExecutable": "Gatebeam",
            "CFBundleIdentifier": "io.github.naifuliang.gatebeam",
            "CFBundleShortVersionString": "0.5.0",
            "CFBundleVersion": "5",
        },
        fmt=plistlib.FMT_XML,
        sort_keys=True,
    )
)
PY
  /usr/bin/find "$fixture/source-app" -type d -exec /bin/chmod 755 {} +
  /usr/bin/find "$fixture/source-app" -type f -exec /bin/chmod 644 {} +
  /bin/chmod 755 "$fixture/source-app/Contents/MacOS/Gatebeam"
  /usr/bin/python3 -I -E -s - "$fixture/source-app" "$scenario" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
scenario = sys.argv[2]
if scenario == "app-extra-all":
    (root / "Contents/unexpected.dylib").write_bytes(b"unexpected code")
PY
  /bin/cp -Rp "$fixture/source-app" "$fixture/expanded/Payload/Gatebeam.app"
  /bin/cp -Rp "$fixture/source-app" "$fixture/dmg-root/Gatebeam.app"
  /bin/ln -s /Applications "$fixture/dmg-root/Applications"
  /bin/cp "$fixture/scripts/pkg/postinstall" "$fixture/expanded/Scripts/"
  /bin/cp "$fixture/scripts/pkg/migrate_legacy_install.sh" "$fixture/expanded/Scripts/"
  print -r -- "fixture bom" >"$fixture/expanded/Bom"
  /bin/cat >"$fixture/expanded/PackageInfo" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="io.github.naifuliang.gatebeam" postinstall-action="none" version="0.5.0" format-version="2" generator-version="Gatebeam fixture" install-location="/Applications" auth="root">
  <payload numberOfFiles="9" installKBytes="16"/>
  <bundle path="./Gatebeam.app" id="io.github.naifuliang.gatebeam" CFBundleShortVersionString="0.5.0" CFBundleVersion="5"/>
  <bundle-version><bundle id="io.github.naifuliang.gatebeam"/></bundle-version>
  <upgrade-bundle><bundle id="io.github.naifuliang.gatebeam"/></upgrade-bundle>
  <update-bundle/>
  <atomic-update-bundle/>
  <strict-identifier><bundle id="io.github.naifuliang.gatebeam"/></strict-identifier>
  <relocate><bundle id="io.github.naifuliang.gatebeam"/></relocate>
  <scripts><postinstall file="./postinstall" timeout="600"/></scripts>
</pkg-info>
XML
  printf '%s\n' \
    'Gatebeam.app' \
    'Gatebeam.app/Contents' \
    'Gatebeam.app/Contents/Info.plist' \
    'Gatebeam.app/Contents/MacOS' \
    'Gatebeam.app/Contents/MacOS/Gatebeam' \
    'Gatebeam.app/Contents/Resources' \
    'Gatebeam.app/Contents/Resources/AppIcon.icns' \
    'Gatebeam.app/Contents/_CodeSignature' \
    'Gatebeam.app/Contents/_CodeSignature/CodeResources' \
    >"$fixture/bom-list"
  /usr/bin/python3 -I -E -s - \
    "$fixture/source-app" "$fixture/scripts/pkg" "$fixture/raw-pkg" \
    "$fixture/expanded/Bom" "$fixture/expanded/PackageInfo" "$scenario" <<'PY'
import gzip
import pathlib
import stat
import sys

app, scripts, output, bom, package_info = map(pathlib.Path, sys.argv[1:6])
scenario = sys.argv[6]
output.mkdir()
(output / "Bom").write_bytes(bom.read_bytes())
(output / "PackageInfo").write_bytes(package_info.read_bytes())

def odc(entries, destination):
    with gzip.GzipFile(filename=destination, mode="wb", mtime=0) as stream:
        inode = 1
        for name, mode, data, declared_size in entries:
            encoded = name.encode("utf-8") + b"\0"
            size = len(data) if declared_size is None else declared_size
            fields = (
                b"070707",
                f"{0:06o}".encode(),
                f"{inode:06o}".encode(),
                f"{mode:06o}".encode(),
                f"{0:06o}".encode(),
                f"{0:06o}".encode(),
                f"{1 if stat.S_ISREG(mode) else 2:06o}".encode(),
                f"{0:06o}".encode(),
                f"{0:011o}".encode(),
                f"{len(encoded):06o}".encode(),
                f"{size:011o}".encode(),
            )
            stream.write(b"".join(fields))
            stream.write(encoded)
            if declared_size is None:
                stream.write(data)
            inode += 1
        trailer = b"TRAILER!!!\0"
        stream.write(
            b"".join(
                (
                    b"070707",
                    b"000000",
                    b"000000",
                    f"{stat.S_IFREG:06o}".encode(),
                    b"000000",
                    b"000000",
                    b"000001",
                    b"000000",
                    b"00000000000",
                    f"{len(trailer):06o}".encode(),
                    b"00000000000",
                )
            )
        )
        stream.write(trailer)

payload = [(".", stat.S_IFDIR | 0o755, b"", None)]
for path in [app, *sorted(app.rglob("*"))]:
    name = "Gatebeam.app"
    if path != app:
        name += "/" + path.relative_to(app).as_posix()
    if path.is_dir():
        payload.append((name, stat.S_IFDIR | 0o755, b"", None))
    else:
        size = (
            600 * 1024 * 1024
            if scenario == "pkg-cpio-bomb"
            and name == "Gatebeam.app/Contents/Resources/AppIcon.icns"
            else None
        )
        payload.append((name, stat.S_IFREG | path.stat().st_mode & 0o777, path.read_bytes(), size))
if scenario == "pkg-cpio-duplicate":
    payload.append(
        (
            "Gatebeam.app/Contents/MacOS/Gatebeam",
            stat.S_IFREG | 0o755,
            b"duplicate",
            None,
        )
    )
elif scenario == "pkg-cpio-casefold":
    payload.append(("gatebeam.app/Contents/extra", stat.S_IFREG | 0o644, b"x", None))
odc(payload, output / "Payload")

script_entries = [(".", stat.S_IFDIR | 0o755, b"", None)]
for path in sorted(scripts.iterdir()):
    script_entries.append((path.name, stat.S_IFREG | 0o755, path.read_bytes(), None))
odc(script_entries, output / "Scripts")
PY
  print -r -- "pkg bytes" >"$candidate/Gatebeam-0.5.0.pkg"
  print -r -- "dmg bytes" >"$candidate/Gatebeam-0.5.0.dmg"
  if [[ "$scenario" == "pkg-sparse" ]]; then
    /usr/bin/truncate -s 1m "$candidate/Gatebeam-0.5.0.pkg"
  elif [[ "$scenario" == "dmg-sparse" ]]; then
    /usr/bin/truncate -s 1m "$candidate/Gatebeam-0.5.0.dmg"
  fi

  /usr/bin/python3 -I -E -s - \
    "$fixture/source-app" "$candidate/Gatebeam-0.5.0.zip" "$scenario" <<'PY'
import pathlib
import stat
import sys
import zipfile
root = pathlib.Path(sys.argv[1])
archive = pathlib.Path(sys.argv[2])
scenario = sys.argv[3]
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as bundle:
    if scenario == "zip-slip":
        bundle.writestr("Gatebeam.app/../extra", b"escape")
    elif scenario == "zip-duplicate":
        bundle.writestr("Gatebeam.app/Contents/file", b"a")
        bundle.writestr("Gatebeam.app/Contents/file", b"b")
    elif scenario == "zip-symlink":
        info = zipfile.ZipInfo("Gatebeam.app/link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        bundle.writestr(info, b"/tmp")
    elif scenario in ("zip-normalized-collision", "app-casefold-collision"):
        bundle.writestr("Gatebeam.app/Contents/file", b"a")
        bundle.writestr("Gatebeam.app/contents/file", b"b")
    elif scenario == "app-unicode-collision":
        bundle.writestr("Gatebeam.app/Contents/Resources/Caf\u00e9", b"nfc")
        bundle.writestr("Gatebeam.app/Contents/Resources/Cafe\u0301", b"nfd")
    else:
        for path in [root, *sorted(root.rglob("*"))]:
            relative = pathlib.PurePosixPath("Gatebeam.app")
            if path != root:
                relative /= path.relative_to(root).as_posix()
            info = zipfile.ZipInfo(
                relative.as_posix() + ("/" if path.is_dir() else ""),
                date_time=(2026, 1, 1, 0, 0, 0),
            )
            info.create_system = 3
            mode = path.stat().st_mode
            info.external_attr = mode << 16
            bundle.writestr(info, b"" if path.is_dir() else path.read_bytes())
PY
  /usr/bin/python3 -I -E -s "$fixture/scripts/release_container_contract.py" \
    extract-app-zip \
    --archive "$candidate/Gatebeam-0.5.0.zip" \
    --output "$fixture/reference-app" \
    --expected-digest "$(
      /usr/bin/shasum -a 256 "$candidate/Gatebeam-0.5.0.zip" |
        /usr/bin/awk '{print $1}'
    )" \
    --maximum-total 4294967296 >/dev/null 2>&1 || true
  if [[ -d "$fixture/reference-app/Gatebeam.app" ]]; then
    /bin/rm -rf \
      "$fixture/source-app" \
      "$fixture/expanded/Payload/Gatebeam.app" \
      "$fixture/dmg-root/Gatebeam.app"
    /bin/cp -Rp "$fixture/reference-app/Gatebeam.app" "$fixture/source-app"
    /bin/cp -Rp "$fixture/reference-app/Gatebeam.app" \
      "$fixture/expanded/Payload/Gatebeam.app"
    /bin/cp -Rp "$fixture/reference-app/Gatebeam.app" \
      "$fixture/dmg-root/Gatebeam.app"
  fi

  /usr/bin/python3 -I -E -s - \
    "$candidate" "$(git -C "$ROOT_DIR" rev-parse HEAD)" <<'PY'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
records = []
for name, kind in (
    ("Gatebeam-0.5.0.zip", "app-archive"),
    ("Gatebeam-0.5.0.pkg", "installer-package"),
    ("Gatebeam-0.5.0.dmg", "disk-image"),
):
    payload = (root / name).read_bytes()
    records.append(
        {
            "name": name,
            "type": kind,
            "byteCount": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
    )
(root / "SHA256SUMS").write_text(
    "".join(f"{entry['sha256']}  {entry['name']}\n" for entry in records),
    encoding="ascii",
)
manifest = {
    "schemaVersion": 4,
    "product": "Gatebeam",
    "commit": commit,
    "tag": "v0.5.0",
    "version": "0.5.0",
    "buildVersion": "5",
    "previousBuildVersion": "0",
    "bundleIdentifier": "io.github.naifuliang.gatebeam",
    "teamIdentifier": "ABCDE12345",
    "artifacts": records,
    "testing": {
        "finalArtifactValidation": {
            "required": True,
            "repository": "naifuliang/gatebeam",
            "repositoryId": 987654321,
            "workflowName": "Release final-artifact validation",
            "workflowPath": ".github/workflows/release-validation.yml",
            "workflowRef": "naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0",
            "workflowSHA": commit,
            "runId": 123457,
            "runAttempt": 1,
            "event": "workflow_dispatch",
            "buildJob": "build-candidate",
            "validationJob": "clean-machine",
            "commit": commit,
            "tag": "v0.5.0",
            "candidateArtifactName": f"gatebeam-final-candidate-v0.5.0-{commit}-run123457-attempt1",
            "attestationArtifactName": f"gatebeam-clean-machine-attestation-v0.5.0-{commit}-run123457-attempt1",
        }
    },
    "rollback": {"available": False, "bootstrap": True},
}
(root / "release-manifest.json").write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  local commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  /usr/bin/python3 -I -E -s "$fixture/scripts/release_artifact_contract.py" \
    create-envelope \
    --root "$candidate" \
    --repository-id 987654321 \
    --workflow-ref "naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0" \
    --workflow-sha "$commit" \
    --run-id 123457 \
    --run-attempt 1 \
    --commit "$commit" \
    --tag v0.5.0 \
    --artifact-name "gatebeam-final-candidate-v0.5.0-${commit}-run123457-attempt1" \
    --attestation-name "gatebeam-clean-machine-attestation-v0.5.0-${commit}-run123457-attempt1"

  /usr/libexec/PlistBuddy -c "Clear dict" "$fixture/Resources/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.5.0" \
    "$fixture/Resources/Info.plist" >/dev/null

  /usr/bin/python3 -I -E -s - "$tools" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
tools = {
    "pkgutil": r'''#!/bin/zsh -f
root="${0:h:h}"
if [[ "$1" == "--forget" ]]; then exit 0; fi
if [[ "$1" == "--expand" ]]; then
  /bin/cp -Rp "$root/raw-pkg" "$3"
  exit 0
fi
[[ "$1" == "--expand-full" ]] || exit 2
/bin/cp -Rp "$root/expanded" "$3"
case "${GATEBEAM_VALIDATOR_SCENARIO:-}" in
  pkg-extra-component) /bin/mkdir "$3/Extra.pkg" ;;
  pkg-extra-payload) print -r -- extra >"$3/Payload/extra" ;;
  pkg-extra-script) print -r -- evil >"$3/Scripts/evil" ;;
  pkg-metadata) /usr/bin/sed -i '' 's/version="0.5.0"/version="9.9.9"/' "$3/PackageInfo" ;;
  pkg-external-script) /usr/bin/sed -i '' 's#file="./postinstall"#file="/tmp/evil"#' "$3/PackageInfo" ;;
  pkg-app-extra) print -r -- evil >"$3/Payload/Gatebeam.app/Contents/unexpected.dylib" ;;
  pkg-expanded-bomb) /usr/sbin/mkfile -n 1100m "$3/Payload/Gatebeam.app/Contents/Resources/AppIcon.icns" ;;
  pkg-count-bomb)
    index=0
    while [[ "$index" -lt 40 ]]; do
      print -r -- extra >"$3/Payload/Gatebeam.app/Contents/Resources/extra-$index"
      index=$((index + 1))
    done
    ;;
  distribution-js)
    print -r -- '<installer-gui-script><script>system.run("/tmp/evil")</script></installer-gui-script>' >"$3/Distribution"
    ;;
esac
''',
    "hdiutil": r'''#!/bin/zsh -f
root="${0:h:h}"
if [[ "$1" == "detach" ]]; then exit 0; fi
mountpoint=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-mountpoint" ]]; then mountpoint="$2"; shift 2; else shift; fi
done
/bin/cp -Rp "$root/dmg-root/." "$mountpoint/"
case "${GATEBEAM_VALIDATOR_SCENARIO:-}" in
  dmg-extra) print -r -- extra >"$mountpoint/extra" ;;
  dmg-wrong-applications) /bin/rm "$mountpoint/Applications"; /bin/ln -s /tmp "$mountpoint/Applications" ;;
  dmg-app-extra) print -r -- evil >"$mountpoint/Gatebeam.app/Contents/unexpected.dylib" ;;
  dmg-expanded-bomb) /usr/sbin/mkfile -n 600m "$mountpoint/Gatebeam.app/Contents/Resources/AppIcon.icns" ;;
esac
''',
    "lsbom": r'''#!/bin/zsh -f
root="${0:h:h}"
/bin/cat "$root/bom-list"
[[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" != "pkg-bom-extra" ]] || print -r -- "extra"
''',
    "codesign": r'''#!/bin/zsh -f
print -u2 -- "CDHash=0123456789abcdef0123456789abcdef01234567"
''',
    "sudo": r'''#!/bin/zsh -f
if [[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" == "uninstall-failure" &&
      "$1" == "/bin/rm" ]]; then exit 0; fi
exec "$@"
''',
    "installer": r'''#!/bin/zsh -f
root="${0:h:h}"
count_file="$root/installer-count"
count=0
[[ ! -f "$count_file" ]] || count="$(<"$count_file")"
count=$((count + 1))
print -r -- "$count" >"$count_file"
print -r -- "installer $count" >>"$root/install.log"
[[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" != "install-failure" ]] || exit 1
if [[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" == "upgrade-failure" && "$count" -ge 2 ]]; then exit 1; fi
/bin/mkdir -p "${GATEBEAM_FINAL_ARTIFACT_TEST_SYSTEM_APP:h}"
/bin/rm -rf -- "$GATEBEAM_FINAL_ARTIFACT_TEST_SYSTEM_APP"
/bin/cp -Rp "$root/source-app" "$GATEBEAM_FINAL_ARTIFACT_TEST_SYSTEM_APP"
''',
    "verify_release": r'''#!/bin/zsh -f
scenario="${GATEBEAM_VALIDATOR_SCENARIO:-}"
case "$scenario:$1" in
  signature-failure:app-stapled|staple-failure:pkg-stapled|gatekeeper-failure:dmg-stapled) exit 1 ;;
esac
[[ -e "$2" && ! -L "$2" ]]
''',
    "install_app": r'''#!/bin/zsh -f
/bin/mkdir -p "$GATEBEAM_INSTALL_DIR"
if [[ "${GATEBEAM_TEST_FAILURE_POINT:-}" == "after-app-swap" ]]; then
  if [[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" == "rollback-failure" ]]; then
    /bin/rm -rf -- "$GATEBEAM_INSTALL_DIR/Gatebeam.app"
  fi
  exit 1
fi
/bin/rm -rf -- "$GATEBEAM_INSTALL_DIR/Gatebeam.app"
/bin/cp -Rp "$GATEBEAM_APP_DIR" "$GATEBEAM_INSTALL_DIR/Gatebeam.app"
''',
    "xar": r'''#!/bin/zsh -f
scenario="${GATEBEAM_VALIDATOR_SCENARIO:-}"
output=""
destination=""
extract=0
previous=""
for argument in "$@"; do
  [[ "$argument" != --dump-toc=* ]] || output="${argument#--dump-toc=}"
  [[ "$argument" != "-x" && "$argument" != "-xf" ]] || extract=1
  [[ "$previous" != "-C" ]] || destination="$argument"
  previous="$argument"
done
if [[ "$extract" == "1" ]]; then
  [[ -n "$destination" ]] || exit 2
  /bin/cp -Rp "${0:h:h}/raw-pkg/." "$destination/"
  exit 0
fi
[[ -n "$output" ]] || exit 2
{
  print -r -- '<?xml version="1.0" encoding="UTF-8"?><xar><toc><checksum style="sha1"><size>20</size><offset>0</offset></checksum><creation-time>2026-01-01T00:00:00Z</creation-time>'
  print -r -- '<signature style="RSA"><offset>20</offset><size>256</size><KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>MAMCAQA=</X509Certificate></X509Data></KeyInfo></signature>'
  print -r -- '<x-signature style="CMS"><offset>276</offset><size>1024</size><KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>MAMCAQA=</X509Certificate></X509Data></KeyInfo></x-signature>'
  identifier=1
  for name in Bom Payload Scripts PackageInfo; do
    size=100
    [[ "$scenario" != "pkg-xar-bomb" || "$name" != "Payload" ]] || size=2147483649
    offset=$((1300 + identifier))
    print -r -- "<file id=\"$identifier\"><name>$name</name><type>file</type><mode>0644</mode><data><archived-checksum style=\"sha1\">0000000000000000000000000000000000000000</archived-checksum><extracted-checksum style=\"sha1\">0000000000000000000000000000000000000000</extracted-checksum><encoding style=\"application/octet-stream\"/><size>$size</size><offset>$offset</offset><length>1</length></data></file>"
    identifier=$((identifier + 1))
  done
  [[ "$scenario" != "pkg-xar-duplicate" ]] ||
    print -r -- '<file id="5"><name>Payload</name><type>file</type><mode>0644</mode><data><archived-checksum style="sha1">0000000000000000000000000000000000000000</archived-checksum><extracted-checksum style="sha1">0000000000000000000000000000000000000000</extracted-checksum><encoding style="application/octet-stream"/><size>1</size><offset>1400</offset><length>1</length></data></file>'
  print -r -- '</toc></xar>'
} >"$output"
''',
    "post_extract": r'''#!/bin/zsh -f
[[ "${GATEBEAM_VALIDATOR_SCENARIO:-}" == "zip-hardlink" ]] || exit 0
/bin/ln "$1/Gatebeam.app/Contents/MacOS/Gatebeam" "$1/Gatebeam.app/Contents/MacOS/Hardlink"
''',
}
for name, payload in tools.items():
    path = root / name
    path.write_text(payload, encoding="utf-8")
    path.chmod(0o755)
PY
  /bin/chmod 755 "$fixture/scripts/"*.sh "$fixture/scripts/"*.py
  print -r -- "$fixture"
}

run_validator() {
  local fixture="$1"
  local scenario="$2"
  local commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  local digest="$(/usr/bin/shasum -a 256 "$fixture/candidate/Gatebeam-0.5.0.zip" | /usr/bin/awk '{print $1}')"
  /usr/bin/env \
    GITHUB_ACTIONS=true \
    GITHUB_REPOSITORY=naifuliang/gatebeam \
    GITHUB_REPOSITORY_ID=987654321 \
    GITHUB_WORKFLOW="Release final-artifact validation" \
    GITHUB_WORKFLOW_REF="naifuliang/gatebeam/.github/workflows/release-validation.yml@refs/tags/v0.5.0" \
    GITHUB_WORKFLOW_SHA="$commit" \
    GITHUB_RUN_ID=123457 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_JOB=clean-machine \
    GITHUB_REF=refs/tags/v0.5.0 \
    GITHUB_REF_TYPE=tag \
    GITHUB_REF_NAME=v0.5.0 \
    GITHUB_SHA="$commit" \
    GATEBEAM_CANDIDATE_ARTIFACT_ID=201 \
    GATEBEAM_CANDIDATE_ARTIFACT_DIGEST="$digest" \
    GATEBEAM_CANDIDATE_ARTIFACT_NAME="gatebeam-final-candidate-v0.5.0-${commit}-run123457-attempt1" \
    GATEBEAM_ATTESTATION_ARTIFACT_NAME="gatebeam-clean-machine-attestation-v0.5.0-${commit}-run123457-attempt1" \
    GATEBEAM_FINAL_ARTIFACT_TEST_MODE=1 \
    GATEBEAM_FINAL_ARTIFACT_TEST_TOOL_DIR="$fixture/test-tools" \
    GATEBEAM_FINAL_ARTIFACT_TEST_SYSTEM_APP="$fixture/test-system/Applications/Gatebeam.app" \
    GATEBEAM_FINAL_ARTIFACT_TEST_ZIP_MAXIMUM="$([[ "$scenario" == "zip-oversize" ]] && print 8 || print 4294967296)" \
    GATEBEAM_VALIDATOR_SCENARIO="$scenario" \
    /bin/zsh -f "$fixture/scripts/validate_final_candidate.sh" \
      "$fixture/candidate" "$fixture/attestation.json"
}

expect_failure() {
  local label="$1"
  local scenario="$2"
  local preinstall="$3"
  local fixture="$(new_fixture "$label" "$scenario")"
  local output="$fixture/output.log"
  if run_validator "$fixture" "$scenario" >"$output" 2>&1; then
    fail_test "$label unexpectedly succeeded" "$output"
  elif [[ -e "$fixture/attestation.json" || -L "$fixture/attestation.json" ]]; then
    fail_test "$label emitted an attestation" "$output"
  elif [[ "$preinstall" == "1" && -s "$fixture/install.log" ]]; then
    fail_test "$label reached installer before allowlist rejection" "$output"
  else
    pass "$label"
  fi
}

signed_toc="$ROOT_DIR/Tests/ReleasePipelineTests/Fixtures/productsign-flat-toc.xml"
if /usr/bin/python3 -I -E -s "$ROOT_DIR/scripts/release_container_contract.py" \
     validate-pkg-toc --toc "$signed_toc"; then
  pass "fixed productsign flat-PKG signature and timestamp TOC"
else
  fail_test "fixed productsign flat-PKG TOC was rejected"
fi

host_signed_pkg="/Applications/Xcode.app/Contents/Resources/Packages/MobileDeviceDevelopment.pkg"
if [[ -f "$host_signed_pkg" && ! -L "$host_signed_pkg" ]]; then
  host_signed_toc="$TEST_ROOT/host-signed-flat-toc.xml"
  if /usr/bin/xar --dump-toc="$host_signed_toc" -f "$host_signed_pkg" &&
     /usr/bin/python3 -I -E -s "$ROOT_DIR/scripts/release_container_contract.py" \
       validate-pkg-toc --toc "$host_signed_toc"; then
    pass "host Apple-signed flat-PKG XAR TOC compatibility"
  else
    fail_test "host Apple-signed flat-PKG XAR TOC was rejected"
  fi
fi

signed_toc_attacks="$TEST_ROOT/signed-toc-attacks"
/bin/mkdir "$signed_toc_attacks"
if /usr/bin/python3 -I -E -s - "$signed_toc" "$signed_toc_attacks" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
root = pathlib.Path(sys.argv[2])
mutations = {
    "wrong-rsa.xml": source.replace('signature style="RSA"', 'signature style="DSA"', 1),
    "wrong-cms-offset.xml": source.replace(
        "<x-signature style=\"CMS\">\n      <offset>276</offset>",
        "<x-signature style=\"CMS\">\n      <offset>277</offset>",
        1,
    ),
    "mismatched-chain.xml": source.replace(
        "<X509Certificate>MAMCAQA=</X509Certificate>",
        "<X509Certificate>MAUCAgEA</X509Certificate>",
        1,
    ),
    "overlapping-data.xml": source.replace(
        "<size>100</size><offset>1303</offset><length>1</length>",
        "<size>100</size><offset>1302</offset><length>1</length>",
        1,
    ),
}
for name, payload in mutations.items():
    (root / name).write_text(payload, encoding="utf-8")
PY
then
  signed_toc_matrix_ok=1
  for toc in "$signed_toc_attacks/"*.xml; do
    if /usr/bin/python3 -I -E -s "$ROOT_DIR/scripts/release_container_contract.py" \
         validate-pkg-toc --toc "$toc" >/dev/null 2>&1; then
      signed_toc_matrix_ok=0
    fi
  done
  if [[ "$signed_toc_matrix_ok" == "1" ]]; then
    pass "signed XAR algorithm, range, chain, and overlap attacks fail closed"
  else
    fail_test "signed XAR negative matrix accepted an invalid TOC"
  fi
else
  fail_test "signed XAR negative fixture generation"
fi

fixture="$(new_fixture success success)"
if run_validator "$fixture" success >"$fixture/output.log" 2>&1 &&
   [[ -s "$fixture/attestation.json" ]]; then
  pass "valid candidate installs, rolls back safely, uninstalls, and attests"
else
  fail_test "valid candidate validation failed" "$fixture/output.log"
fi

for scenario in \
  zip-slip zip-duplicate zip-normalized-collision zip-symlink zip-hardlink zip-oversize \
  app-extra-all app-casefold-collision app-unicode-collision \
  pkg-sparse pkg-xar-duplicate pkg-xar-bomb \
  pkg-cpio-duplicate pkg-cpio-casefold pkg-cpio-bomb pkg-extra-component \
  pkg-extra-payload pkg-extra-script pkg-external-script pkg-metadata pkg-bom-extra \
  pkg-app-extra pkg-expanded-bomb pkg-count-bomb distribution-js \
  dmg-sparse dmg-extra dmg-wrong-applications dmg-app-extra dmg-expanded-bomb \
  signature-failure staple-failure gatekeeper-failure
do
  expect_failure "$scenario" "$scenario" 1
done
for scenario in install-failure upgrade-failure rollback-failure uninstall-failure; do
  expect_failure "$scenario" "$scenario" 0
done

print -r -- "Final candidate validator tests: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
