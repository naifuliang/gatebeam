#!/bin/zsh -f
set -euo pipefail

TOOL_NAME="${0:t}"
CALL_LOG="${GATEBEAM_FAKE_CALL_LOG:?}"

artifact_kind() {
  local path="$1"
  case "$path" in
    *.zip|*.app) print -r -- app ;;
    *.pkg) print -r -- pkg ;;
    *.dmg) print -r -- dmg ;;
    *) print -r -- unknown ;;
  esac
}

notary_id() {
  case "$1" in
    app) print -r -- "11111111-1111-1111-1111-111111111111" ;;
    pkg) print -r -- "22222222-2222-2222-2222-222222222222" ;;
    dmg) print -r -- "33333333-3333-3333-3333-333333333333" ;;
    *) print -r -- "99999999-9999-9999-9999-999999999999" ;;
  esac
}

case "$TOOL_NAME" in
  ditto)
    if [[ "$1" == "-c" ]]; then
      source_path="${@: -2:1}"
      destination_path="${@: -1}"
      /usr/bin/ditto -c -k --keepParent "$source_path" "$destination_path"
    else
      /usr/bin/ditto "$@"
    fi
    ;;
  codesign)
    if [[ "$1" == "--force" ]]; then
      print -r -- "codesign dmg" >>"$CALL_LOG"
      exit 0
    fi
    if [[ "$1" == "--verify" ]]; then
      [[ "${GATEBEAM_FAKE_BAD_APP_IDENTITY:-0}" != "1" ]]
      target="${@: -1}"
      if [[ "$target" == *.app &&
            -f "$target/Contents/MacOS/Gatebeam" ]] &&
         /usr/bin/grep -Fq "rebuilt" "$target/Contents/MacOS/Gatebeam"; then
        exit 1
      fi
      if [[ "$target" == *.dmg &&
            "$*" == *" -R="* &&
            "${GATEBEAM_FAKE_WRONG_DMG_OID:-0}" == "1" ]]; then
        exit 1
      fi
      exit
    fi
    if [[ "$*" == *" -r- "* ]]; then
      ca_oid="1.2.840.113635.100.6.""2.6"
      leaf_oid="1.2.840.113635.100.6.""1.13"
      print -u2 -- "designated => anchor apple generic and identifier \"io.github.naifuliang.gatebeam\" and certificate 1[field.$ca_oid] exists and certificate leaf[field.$leaf_oid] exists and certificate leaf[subject.OU] = \"ABCDE12345\""
      exit 0
    fi
    if [[ "$*" == *"--entitlements -"* ]]; then
      entitlement="${GATEBEAM_FAKE_FORBIDDEN_ENTITLEMENT:-}"
      if [[ "${@: -1}" == *.dmg ]]; then
        entitlement="${GATEBEAM_FAKE_DMG_FORBIDDEN_ENTITLEMENT:-}"
      fi
      if [[ -n "$entitlement" ]]; then
        print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>$entitlement</key><true/></dict></plist>"
      else
        print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
      fi
      exit 0
    fi
    if [[ "$*" == *"--verbose=4"* ]]; then
      if [[ "${@: -1}" == *.dmg ]]; then
        print -u2 -- "Executable=${@: -1}"
      else
        print -u2 -- "Executable=${@: -1}/Contents/MacOS/Gatebeam"
        print -u2 -- "Identifier=io.github.naifuliang.gatebeam"
        if [[ "${GATEBEAM_FAKE_NO_RUNTIME:-0}" != "1" ]]; then
          print -u2 -- "Runtime Version=13.0.0"
          print -u2 -- "flags=0x10000(runtime)"
        fi
      fi
      if [[ "${GATEBEAM_FAKE_WRONG_APP_AUTHORITY:-0}" == "1" ]]; then
        print -u2 -- "Authority=Apple Development: Gatebeam Tests (ABCDE12345)"
      else
        print -u2 -- "Authority=Developer ID Application: Gatebeam Tests (ABCDE12345)"
      fi
      print -u2 -- "TeamIdentifier=ABCDE12345"
      if [[ "${GATEBEAM_FAKE_NO_TIMESTAMP:-0}" != "1" ]]; then
        print -u2 -- "Timestamp=Jul 28, 2026 at 12:00:00"
      fi
      print -u2 -- "CDHash=0123456789abcdef0123456789abcdef01234567"
      exit 0
    fi
    ;;
  productsign)
    print -r -- "productsign" >>"$CALL_LOG"
    if [[ "${GATEBEAM_FAKE_PRODUCTSIGN_PARTIAL_FAILURE:-0}" == "1" ]]; then
      print -r -- "partial" >"${@: -1}"
      exit 1
    fi
    cp "${@: -2:1}" "${@: -1}"
    ;;
  pkgutil)
    print -r -- "Package ${@: -1}:"
    print -r -- "   Status: signed by a certificate trusted by macOS"
    if [[ "${GATEBEAM_FAKE_NO_PKG_TIMESTAMP:-0}" != "1" ]]; then
      print -r -- "   Signed with a trusted timestamp"
    fi
    print -r -- "   Certificate Chain:"
    if [[ "${GATEBEAM_FAKE_WRONG_INSTALLER_AUTHORITY:-0}" == "1" ]]; then
      print -r -- "    1. Developer ID Application: Gatebeam Tests (ABCDE12345)"
    else
      print -r -- "    1. Developer ID Installer: Gatebeam Tests (ABCDE12345)"
    fi
    ;;
  hdiutil)
    [[ "$1" == "verify" && "${GATEBEAM_FAKE_FAIL_HDIUTIL:-0}" != "1" ]]
    ;;
  spctl)
    kind=unknown
    if [[ "$*" == *"--type execute"* ]]; then
      kind=execute
    elif [[ "$*" == *"--type install"* ]]; then
      kind=install
    elif [[ "$*" == *"--type open"* ]]; then
      kind=open
    fi
    [[ "${GATEBEAM_FAKE_FAIL_GATEKEEPER:-}" != "$kind" ]]
    ;;
  xcrun)
    subcommand="$1"
    action="$2"
    shift 2
    case "$subcommand:$action" in
      notarytool:submit)
        artifact="${@: -1}"
        kind="$(artifact_kind "$artifact")"
        submission_id="$(notary_id "$kind")"
        print -r -- "notarytool submit $kind" >>"$CALL_LOG"
        print -r -- "{\"id\":\"$submission_id\",\"status\":\"${GATEBEAM_FAKE_NOTARY_STATUS:-Accepted}\"}"
        ;;
      notarytool:log)
        submission_id="${@: -2:1}"
        output_path="${@: -1}"
        kind=unknown
        case "$submission_id" in
          11111111-*) kind=app ;;
          22222222-*) kind=pkg ;;
          33333333-*) kind=dmg ;;
        esac
        print -r -- "notarytool log $kind" >>"$CALL_LOG"
        [[ "${GATEBEAM_FAKE_FAIL_NOTARY_LOG:-}" != "$kind" ]] || exit 1
        issues='null'
        if [[ "${GATEBEAM_FAKE_NOTARY_ISSUE:-}" == "warning" ]]; then
          issues='[{"severity":"warning","message":"fixture warning"}]'
        elif [[ "${GATEBEAM_FAKE_NOTARY_EMPTY_ISSUES:-0}" == "1" ]]; then
          issues='[]'
        fi
        profile_field=""
        if [[ "${GATEBEAM_FAKE_LEAK_PROFILE:-0}" == "1" ]]; then
          profile_field=",\"credentialProfile\":\"$GATEBEAM_NOTARY_PROFILE\""
        fi
        print -r -- "{\"jobId\":\"$submission_id\",\"status\":\"Accepted\",\"issues\":$issues$profile_field}" >"$output_path"
        ;;
      stapler:staple)
        artifact="${@: -1}"
        kind="$(artifact_kind "$artifact")"
        print -r -- "stapler staple $kind" >>"$CALL_LOG"
        [[ "${GATEBEAM_FAKE_FAIL_STAPLE:-}" != "$kind" ]]
        if [[ "$kind" == "app" ]]; then
          mkdir -p "$artifact/Contents/_CodeSignature"
          print -r -- "fixture-stapled-app" \
            >"$artifact/Contents/_CodeSignature/fixture-stapled-ticket"
        else
          print -r -- "fixture-stapled-$kind" >>"$artifact"
        fi
        ;;
      stapler:validate)
        exit 0
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
