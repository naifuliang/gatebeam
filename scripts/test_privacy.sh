#!/bin/zsh -f
set -euo pipefail

readonly PRIVACY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly PRIVACY_TEMP="$(mktemp -d "${TMPDIR:-/private/tmp}/gatebeam-privacy.XXXXXX")"
readonly PRIVACY_TEXT_FILES="$PRIVACY_TEMP/text-files"
readonly PRIVACY_CANDIDATES="$PRIVACY_TEMP/candidates"

cleanup() {
  /bin/rm -rf "$PRIVACY_TEMP"
}
trap cleanup EXIT INT TERM

cd "$PRIVACY_ROOT"

git ls-files --cached --others --exclude-standard -z |
  while IFS= read -r -d '' source_path; do
    [[ -f "$source_path" ]] || continue
    if LC_ALL=C /usr/bin/grep -Iq . "$source_path"; then
      print -r -- "$source_path"
    fi
  done > "$PRIVACY_TEXT_FILES"

scan_for_secret() {
  local pattern="$1"
  local description="$2"
  local source_path
  local matches=""

  while IFS= read -r source_path; do
    matches+="$(
      LC_ALL=C /usr/bin/grep -nE -- "$pattern" "$source_path" 2>/dev/null |
        /usr/bin/sed "s|^|$source_path:|" ||
        true
    )"
  done < "$PRIVACY_TEXT_FILES"

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
while IFS= read -r source_path; do
  /usr/bin/perl -MSocket=AF_INET,AF_INET6,inet_pton -ne '
    my $line_number = $.;

    while (/([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/g) {
      print join("\t", "email", $ARGV, $line_number, lc($1)), "\n";
    }

    while (/\b((?:[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:app|ai|biz|cc|cn|co|com|dev|example|info|io|live|me|mobi|net|network|online|org|pro|sh|site|so|systems|tech|test|top|tv|uk|us|world|xyz))\b/ig) {
      print join("\t", "domain", $ARGV, $line_number, lc($1)), "\n";
    }

    while (/(?<![0-9])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9])/g) {
      my $candidate = $1;
      next unless inet_pton(AF_INET, $candidate);
      print join("\t", "ipv4", $ARGV, $line_number, $candidate), "\n";
    }

    while (/(?<![0-9A-Fa-f:])([0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)(?![0-9A-Fa-f:])/g) {
      my $candidate = lc($1);
      next unless $candidate =~ /:/;
      next unless inet_pton(AF_INET6, $candidate);
      print join("\t", "ipv6", $ARGV, $line_number, $candidate), "\n";
    }
  ' "$source_path" >> "$PRIVACY_CANDIDATES"
done < "$PRIVACY_TEXT_FILES"

privacy_failure() {
  local kind="$1"
  local source_path="$2"
  local line_number="$3"
  local value="$4"
  print -u2 "Privacy scan failed: unapproved $kind literal $value in $source_path:$line_number"
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
  local value="$1"

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

  if [[ "$source_path" == "Tests/BackendTests/main.swift" ]]; then
    [[ "$octet1" == 01 && "$octet2" == 2 && "$octet3" == 3 && "$octet4" == 4 ]] && return 0
    (( octet1 == 0 )) && return 0
    (( octet1 == 192 && octet2 == 88 && octet3 == 99 )) && return 0
    (( octet1 == 198 && (octet2 == 18 || octet2 == 19) )) && return 0
    (( octet1 >= 240 )) && return 0
    (( octet1 == 8 && octet2 == 8 && octet3 == 4 && octet4 == 4 )) && return 0
  fi

  if [[ "$source_path" == "Tests/IntegrationContractTests/main.swift" ]]; then
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

while IFS=$'\t' read -r kind source_path line_number value; do
  case "$kind" in
    email)
      is_allowed_email "$source_path" "$value" ||
        privacy_failure "$kind" "$source_path" "$line_number" "$value"
      ;;
    domain)
      is_allowed_domain "$value" ||
        privacy_failure "$kind" "$source_path" "$line_number" "$value"
      ;;
    ipv4)
      is_allowed_ipv4 "$source_path" "$value" ||
        privacy_failure "$kind" "$source_path" "$line_number" "$value"
      ;;
    ipv6)
      is_allowed_ipv6 "$source_path" "$value" ||
        privacy_failure "$kind" "$source_path" "$line_number" "$value"
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

print 'Privacy scan passed'
