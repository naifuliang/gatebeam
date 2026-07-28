#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_PARENT="${GATEBEAM_TEST_TMPDIR:-${TMPDIR:-/private/tmp}}"
BUILD_DIR="$(mktemp -d "$FIXTURE_PARENT/gatebeam-library-validation.XXXXXX")"
HOST_SOURCE="$ROOT_DIR/Tests/KeychainIdentityTests/LibraryValidationHost.c"
INJECTION_SOURCE="$ROOT_DIR/Tests/KeychainIdentityTests/DYLDInjectionProbe.c"
HOST_EXECUTABLE="$BUILD_DIR/library-validation-host"
INJECTION_DYLIB="$BUILD_DIR/libLibraryValidationProbe.dylib"
SENTINEL="$BUILD_DIR/dyld-injection-loaded"
RUN_LOG="$BUILD_DIR/host.log"
SIGNING_CONTRACT="$ROOT_DIR/scripts/signing_contract.sh"

if (( $# != 0 )); then
  print -u2 "Usage: $0"
  exit 2
fi

cleanup() {
  /bin/rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

source "$SIGNING_CONTRACT"

/usr/bin/xcrun clang -O2 "$HOST_SOURCE" -o "$HOST_EXECUTABLE"
/usr/bin/xcrun clang -dynamiclib -O2 "$INJECTION_SOURCE" -o "$INJECTION_DYLIB"
/usr/bin/codesign --force --sign - "$INJECTION_DYLIB" >/dev/null

run_injection_fixture() {
  /bin/rm -f "$SENTINEL"
  set +e
  GATEBEAM_DYLD_INJECTION_SENTINEL="$SENTINEL" \
  DYLD_INSERT_LIBRARIES="$INJECTION_DYLIB" \
    "$HOST_EXECUTABLE" >"$RUN_LOG" 2>&1
  local run_status=$?
  set -e

  if [[ -e "$SENTINEL" ]]; then
    if (( run_status != 0 )) ||
       [[ "$(<"$RUN_LOG")" != "library-validation-host-ready" ]]; then
      print -u2 "Injected library loaded, but its control host did not complete normally."
      return 1
    fi
    print -r -- "loaded"
    return
  fi

  if (( run_status == 0 )) &&
     [[ "$(<"$RUN_LOG")" != "library-validation-host-ready" ]]; then
    print -u2 "Library-validation fixture returned unexpected clean output."
    return 1
  fi
  print -r -- "rejected"
}

# First prove that the fixture and DYLD environment can load the library at all.
/usr/bin/codesign --force --sign - "$HOST_EXECUTABLE" >/dev/null
/usr/bin/codesign --verify --strict "$HOST_EXECUTABLE"
control_result="$(run_injection_fixture)"

# Then change only the host signature policy and observe the platform behavior.
/usr/bin/codesign \
  --force \
  --sign - \
  --options runtime \
  "$HOST_EXECUTABLE" >/dev/null
/usr/bin/codesign --verify --strict "$HOST_EXECUTABLE"
host_signing_details="$(
  /usr/bin/codesign -d --verbose=4 "$HOST_EXECUTABLE" 2>&1
)"
host_entitlements="$(
  /usr/bin/codesign -d --entitlements - "$HOST_EXECUTABLE" 2>/dev/null || true
)"
gatebeam_validate_hardened_runtime "$host_signing_details"
gatebeam_validate_safe_entitlements "$host_entitlements"

host_cdhash="$(
  /usr/bin/codesign -d --verbose=4 "$HOST_EXECUTABLE" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p'
)"
injection_cdhash="$(
  /usr/bin/codesign -d --verbose=4 "$INJECTION_DYLIB" 2>&1 |
    /usr/bin/sed -n 's/^CDHash=//p'
)"
if [[ -z "$host_cdhash" ||
      -z "$injection_cdhash" ||
      "$host_cdhash" == "$injection_cdhash" ]]; then
  print -u2 "Library-validation capability fixtures must have different code identities."
  exit 1
fi

hardened_result="$(run_injection_fixture)"

gatebeam_classify_ad_hoc_library_validation \
  "$control_result" \
  "$hardened_result"
