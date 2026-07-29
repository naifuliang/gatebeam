#!/bin/zsh -f
set -euo pipefail

readonly PRIVACY_SCRIPT="${0:A}"
privacy_root="$(cd "$(dirname "$0")/.." && pwd)"
privacy_range=""
run_history_fixture=true

usage() {
  print -u2 'Usage: test_privacy.sh [--range <revision-range>] [--repo <path>] [--skip-history-fixture]'
}

while (( $# > 0 )); do
  case "$1" in
    --range)
      (( $# >= 2 )) || {
        usage
        exit 2
      }
      privacy_range="$2"
      shift 2
      ;;
    --repo)
      (( $# >= 2 )) || {
        usage
        exit 2
      }
      privacy_root="$(cd "$2" && pwd)"
      shift 2
      ;;
    --skip-history-fixture)
      run_history_fixture=false
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

readonly PRIVACY_ROOT="$privacy_root"
readonly PRIVACY_TEMP="$(mktemp -d "${TMPDIR:-/private/tmp}/gatebeam-privacy.XXXXXX")"
readonly PRIVACY_SOURCES="$PRIVACY_TEMP/sources"
readonly PRIVACY_CANDIDATES="$PRIVACY_TEMP/candidates"
readonly PRIVACY_COMMITS="$PRIVACY_TEMP/commits"
readonly PRIVACY_BLOBS="$PRIVACY_TEMP/blobs"

cleanup() {
  /bin/rm -rf "$PRIVACY_TEMP"
}
trap cleanup EXIT INT TERM

cd "$PRIVACY_ROOT"
/usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  print -u2 -- "Privacy scan failed: not a Git worktree: $PRIVACY_ROOT"
  exit 1
}

/bin/mkdir -p "$PRIVACY_BLOBS"
: > "$PRIVACY_SOURCES"

register_source() {
  local display_path="$1"
  local logical_path="$2"
  local content_path="$3"

  if LC_ALL=C /usr/bin/grep -Iq . "$content_path"; then
    print -r -- "$display_path"$'\t'"$logical_path"$'\t'"$content_path" >> "$PRIVACY_SOURCES"
  fi
}

collect_worktree_sources() {
  local source_path

  /usr/bin/git ls-files --cached --others --exclude-standard -z |
    while IFS= read -r -d '' source_path; do
      [[ -f "$source_path" ]] || continue
      register_source "$source_path" "$source_path" "$PRIVACY_ROOT/$source_path"
    done
}

collect_history_sources() {
  local revision_range="$1"
  local commit
  local record
  local metadata
  local logical_path
  local object_id
  local blob_path
  local display_path
  local blob_index=0

  if ! /usr/bin/git rev-list --reverse "$revision_range" -- > "$PRIVACY_COMMITS"; then
    print -u2 -- "Privacy scan failed: invalid Git revision range: $revision_range"
    exit 1
  fi
  [[ -s "$PRIVACY_COMMITS" ]] || {
    print -u2 -- "Privacy scan failed: Git revision range contains no commits: $revision_range"
    exit 1
  }

  while IFS= read -r commit; do
    while IFS= read -r -d '' record; do
      metadata="${record%%$'\t'*}"
      logical_path="${record#*$'\t'}"
      object_id="${metadata##* }"
      (( blob_index += 1 ))
      blob_path="$PRIVACY_BLOBS/$blob_index"
      if ! /usr/bin/git cat-file blob "$object_id" > "$blob_path"; then
        print -u2 -- "Privacy scan failed: could not read Git blob $object_id from $commit"
        exit 1
      fi
      display_path="${commit[1,12]}:$logical_path"
      register_source "$display_path" "$logical_path" "$blob_path"
    done < <(/usr/bin/git ls-tree -rz --full-tree "$commit")
  done < "$PRIVACY_COMMITS"
}

collect_worktree_sources
if [[ -n "$privacy_range" ]]; then
  collect_history_sources "$privacy_range"
fi

scan_for_secret() {
  local pattern="$1"
  local description="$2"
  local display_path
  local logical_path
  local content_path
  local matches=""

  while IFS=$'\t' read -r display_path logical_path content_path; do
    matches+="$(
      LC_ALL=C /usr/bin/grep -nE -- "$pattern" "$content_path" 2>/dev/null |
        /usr/bin/sed "s|^|$display_path:|" ||
        true
    )"
  done < "$PRIVACY_SOURCES"

  if [[ -n "$matches" ]]; then
    print -u2 "Privacy scan failed: $description"
    print -u2 -- "$matches"
    exit 1
  fi
}

scan_for_secret 'cfut_[A-Za-z0-9_-]{16,}' 'a Cloudflare API token was found'
scan_for_secret '(ghp|github_pat|glpat|xox[baprs]|AKIA)[_-]?[A-Za-z0-9_-]{16,}' 'a provider credential was found'
scan_for_secret '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' 'a private key was found'
scan_for_secret '/Users/[A-Za-z0-9._-]+/' 'a local macOS home path was found'
scan_for_secret '/var/folders/[A-Za-z0-9._/-]+' 'a local macOS temporary path was found'

: > "$PRIVACY_CANDIDATES"
while IFS=$'\t' read -r display_path logical_path content_path; do
  /usr/bin/perl -MSocket=AF_INET,AF_INET6,inet_pton -ne '
    my $line_number = $.;

    while (/([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/g) {
      print join("\t", "email", $line_number, lc($1)), "\n";
    }

    while (/\b((?:[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:app|ai|biz|cc|cn|co|com|dev|example|info|io|live|me|mobi|net|network|online|org|pro|sh|site|so|systems|tech|test|top|tv|uk|us|world|xyz))\b/ig) {
      print join("\t", "domain", $line_number, lc($1)), "\n";
    }

    while (/(?<![0-9])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9])/g) {
      my $candidate = $1;
      next unless inet_pton(AF_INET, $candidate);
      print join("\t", "ipv4", $line_number, $candidate), "\n";
    }

    while (/(?<![0-9A-Fa-f:])([0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)(?![0-9A-Fa-f:])/g) {
      my $candidate = lc($1);
      next unless $candidate =~ /:/;
      next unless inet_pton(AF_INET6, $candidate);
      print join("\t", "ipv6", $line_number, $candidate), "\n";
    }
  ' "$content_path" |
    while IFS=$'\t' read -r kind line_number value; do
      print -r -- "$kind"$'\t'"$display_path"$'\t'"$logical_path"$'\t'"$line_number"$'\t'"$value"
    done >> "$PRIVACY_CANDIDATES"
done < "$PRIVACY_SOURCES"

privacy_failure() {
  local kind="$1"
  local display_path="$2"
  local line_number="$3"
  local value="$4"
  print -u2 "Privacy scan failed: unapproved $kind literal $value in $display_path:$line_number"
  exit 1
}

is_allowed_email() {
  local source_path="$1"
  local value="$2"

  [[ "$value" =~ '^icon_[0-9]+x[0-9]+@2x\.png$' ]] && return 0
  [[ "$value" == *@example.test ]] && return 0
  [[ "$source_path" == Tests/* && "$value" == *@proxy.example.test ]] && return 0
  [[ "$source_path" == "Tests/ProxyPolicyTests/main.swift" && "$value" == *@127.0.0.1 ]] && return 0
  return 1
}

is_allowed_domain() {
  local source_path="$1"
  local value="$2"
  local xmlsig_domain="www.w3"".""org"
  local xcode_domain="xcode"".""app"

  case "$value" in
    example.test|*.example.test)
      return 0
      ;;
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|example|*.example)
      return 0
      ;;
    api.cloudflare.com|dash.cloudflare.com|developers.cloudflare.com)
      return 0
      ;;
    api.ipify.org|api6.ipify.org|ifconfig.me|checkip.amazonaws.com|v6.ident.me|ipv6.icanhazip.com)
      return 0
      ;;
    www.apple.com|schemas.xmlsoap.org|datatracker.ietf.org|upnp.org|github.com|*.github.com)
      return 0
      ;;
    gatebeam.app|network.app|new.app|previous.app|legacy.app|owned.app)
      return 0
      ;;
  esac

  case "$source_path" in
    Tests/ReleasePipelineTests/Fixtures/productsign-flat-toc.xml|scripts/release_container_contract.py)
      [[ "$value" == "$xmlsig_domain" ]] && return 0
      ;;
    scripts/test_final_candidate_validator.sh)
      [[ "$value" == "$xmlsig_domain" || "$value" == "$xcode_domain" ]] && return 0
      ;;
    scripts/test_keychain_identity.sh)
      local separator=.
      [[ "$value" == "subject${separator}cn" ]] && return 0
      ;;
  esac

  return 1
}

is_allowed_ipv4() {
  local source_path="$1"
  local value="$2"
  local octet1 octet2 octet3 octet4
  IFS=. read -r octet1 octet2 octet3 octet4 <<< "$value"

  (( octet1 == 0 && octet2 == 0 && octet3 == 0 && octet4 == 0 )) && return 0
  (( octet1 == 10 || octet1 == 127 )) && return 0
  (( octet1 == 172 && octet2 >= 16 && octet2 <= 31 )) && return 0
  (( octet1 == 192 && octet2 == 168 )) && return 0
  (( octet1 == 100 && octet2 >= 64 && octet2 <= 127 )) && return 0
  (( octet1 == 169 && octet2 == 254 )) && return 0
  (( octet1 == 192 && octet2 == 0 && octet3 == 0 )) && return 0
  (( octet1 == 192 && octet2 == 0 && octet3 == 2 )) && return 0
  (( octet1 == 198 && octet2 == 51 && octet3 == 100 )) && return 0
  (( octet1 == 203 && octet2 == 0 && octet3 == 113 )) && return 0
  (( octet1 >= 224 && octet1 <= 239 )) && return 0

  case "$source_path" in
    Sources/RemoteControlNetwork/KeychainStore.swift|\
    Tests/IntegrationContractTests/main.swift|\
    scripts/build_app.sh|\
    scripts/signing_contract.sh|\
    scripts/test_keychain_identity.sh|\
    scripts/test_privacy.sh)
      case "$value" in
        100.6.2.6|100.6.1.13|100.6.2.1|100.6.1.14)
          return 0
          ;;
      esac
      ;;
  esac

  if [[ "$source_path" == "Tests/BackendTests/main.swift" ]]; then
    [[ "$octet1" == 01 && "$octet2" == 2 && "$octet3" == 3 && "$octet4" == 4 ]] && return 0
    (( octet1 == 0 )) && return 0
    (( octet1 == 192 && octet2 == 88 && octet3 == 99 )) && return 0
    (( octet1 == 198 && (octet2 == 18 || octet2 == 19) )) && return 0
    (( octet1 >= 240 )) && return 0
    (( octet1 == 8 && octet2 == 8 && octet3 == 4 && octet4 == 4 )) && return 0
  fi

  if [[ "$source_path" == "Tests/IntegrationContractTests/main.swift" ]]; then
    (( octet1 == 198 && octet2 == 18 && octet3 == 0 && octet4 == 1 )) && return 0
    (( octet1 == 8 && octet2 == 8 && octet3 == 8 && octet4 == 8 )) && return 0
    (( octet1 == 8 && octet2 == 8 && octet3 == 4 && octet4 == 4 )) && return 0
    (( octet1 >= 240 )) && return 0
  fi

  return 1
}

is_allowed_ipv6() {
  local source_path="$1"
  local value="${2:l}"

  case "$value" in
    ::|::1|::ffff:*|64:ff9b:*|100::*|2000::*|2001::*|2001:db8:*|2002:*|3fff:*|5f00:*|fc*|fd*|fe8*|fe9*|fea*|feb*|ff*)
      return 0
      ;;
  esac

  if [[ "$source_path" == "Tests/BackendTests/main.swift" ]]; then
    case "$value" in
      2404:6800:*|2606:4700:*)
        return 0
        ;;
    esac
  fi

  if [[ "$source_path" == "Tests/IntegrationContractTests/main.swift" ]]; then
    local separator=:
    [[ "$value" == "2606${separator}4700${separator}4700${separator}${separator}1111" ]] &&
      return 0
  fi

  return 1
}

while IFS=$'\t' read -r kind display_path logical_path line_number value; do
  case "$kind" in
    email)
      is_allowed_email "$logical_path" "$value" ||
        privacy_failure "$kind" "$display_path" "$line_number" "$value"
      ;;
    domain)
      is_allowed_domain "$logical_path" "$value" ||
        privacy_failure "$kind" "$display_path" "$line_number" "$value"
      ;;
    ipv4)
      is_allowed_ipv4 "$logical_path" "$value" ||
        privacy_failure "$kind" "$display_path" "$line_number" "$value"
      ;;
    ipv6)
      is_allowed_ipv6 "$logical_path" "$value" ||
        privacy_failure "$kind" "$display_path" "$line_number" "$value"
      ;;
  esac
done < "$PRIVACY_CANDIDATES"

readonly PRIVACY_APP_EXECUTABLE="$PRIVACY_ROOT/dist/Gatebeam.app/Contents/MacOS/Gatebeam"
if [[ -x "$PRIVACY_APP_EXECUTABLE" ]]; then
  readonly PRIVACY_BINARY_MATCHES="$(
    strings -a "$PRIVACY_APP_EXECUTABLE" |
      /usr/bin/grep -E 'cfut_[A-Za-z0-9_-]{16,}|/Users/[A-Za-z0-9._-]+/|/var/folders/|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' ||
      true
  )"
  if [[ -n "$PRIVACY_BINARY_MATCHES" ]]; then
    print -u2 'Privacy scan failed: private material was embedded in Gatebeam.'
    print -u2 -- "$PRIVACY_BINARY_MATCHES"
    exit 1
  fi
fi

run_intermediate_commit_fixture() {
  local fixture_name="$1"
  local secret_value="$2"
  local expected_finding="$3"
  local fixture_repo="$PRIVACY_TEMP/history-$fixture_name"
  local fixture_log="$PRIVACY_TEMP/history-$fixture_name.log"
  local fixture_base
  local fixture_head

  /bin/mkdir -p "$fixture_repo"
  /usr/bin/git -C "$fixture_repo" init -q
  print -r -- 'safe fixture' > "$fixture_repo/payload.txt"
  /usr/bin/git -C "$fixture_repo" add payload.txt
  /usr/bin/git -C "$fixture_repo" \
    -c user.name='Gatebeam Privacy Test' \
    -c user.email='privacy@example.test' \
    commit -q -m 'safe base'
  fixture_base="$(/usr/bin/git -C "$fixture_repo" rev-parse HEAD)"

  print -r -- "$secret_value" > "$fixture_repo/payload.txt"
  /usr/bin/git -C "$fixture_repo" add payload.txt
  /usr/bin/git -C "$fixture_repo" \
    -c user.name='Gatebeam Privacy Test' \
    -c user.email='privacy@example.test' \
    commit -q -m 'intermediate private material'

  print -r -- 'safe fixture again' > "$fixture_repo/payload.txt"
  /usr/bin/git -C "$fixture_repo" add payload.txt
  /usr/bin/git -C "$fixture_repo" \
    -c user.name='Gatebeam Privacy Test' \
    -c user.email='privacy@example.test' \
    commit -q -m 'remove private material'
  fixture_head="$(/usr/bin/git -C "$fixture_repo" rev-parse HEAD)"

  if "$PRIVACY_SCRIPT" \
    --repo "$fixture_repo" \
    --range "$fixture_base..$fixture_head" \
    --skip-history-fixture >"$fixture_log" 2>&1; then
    print -u2 -- "Privacy scan failed: history fixture did not detect intermediate $fixture_name material"
    exit 1
  fi
  if ! /usr/bin/grep -Fq -- "$expected_finding" "$fixture_log"; then
    print -u2 -- "Privacy scan failed: history fixture did not report the expected $fixture_name finding"
    /bin/cat "$fixture_log" >&2
    exit 1
  fi
}

if [[ "$run_history_fixture" == true ]]; then
  fixture_token="cf""ut_""ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  fixture_domain="history-only"".""com"
  fixture_email="owner""@history-only"".""com"
  fixture_home="/Users/history-only""/Library/Secrets"
  fixture_private_key="-----BEGIN PRIVATE ""KEY-----"
  run_intermediate_commit_fixture token "$fixture_token" 'a Cloudflare API token was found'
  run_intermediate_commit_fixture domain "$fixture_domain" 'unapproved domain literal'
  run_intermediate_commit_fixture email "$fixture_email" 'unapproved email literal'
  run_intermediate_commit_fixture path "$fixture_home" 'a local macOS home path was found'
  run_intermediate_commit_fixture private-key "$fixture_private_key" 'a private key was found'
fi

if [[ -n "$privacy_range" ]]; then
  print -r -- "Privacy scan passed for worktree and Git range: $privacy_range"
else
  print 'Privacy scan passed'
fi
