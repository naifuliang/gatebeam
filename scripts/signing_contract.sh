#!/bin/zsh -f

gatebeam_signing_contract_error() {
  print -u2 -- "Gatebeam signing contract failed: $1"
}

gatebeam_signing_details_has_line() {
  local signing_details="$1"
  local expected_line="$2"
  local padded_details=$'\n'"$signing_details"$'\n'

  [[ "$padded_details" == *$'\n'"$expected_line"$'\n'* ]]
}

gatebeam_validate_safe_entitlements() {
  local entitlements="$1"
  local forbidden_key

  for forbidden_key in \
    "com.apple.security.cs.allow-jit" \
    "com.apple.security.cs.allow-unsigned-executable-memory" \
    "com.apple.security.cs.disable-executable-page-protection" \
    "com.apple.security.cs.allow-dyld-environment-variables" \
    "com.apple.security.cs.disable-library-validation" \
    "com.apple.security.cs.debugger" \
    "com.apple.security.get-task-allow"
  do
    if [[ "$entitlements" == *"$forbidden_key"* ]]; then
      gatebeam_signing_contract_error \
        "forbidden entitlement is present: $forbidden_key"
      return 1
    fi
  done
}

gatebeam_validate_hardened_runtime() {
  local signing_details="$1"

  if [[ "$signing_details" != *"flags="*"runtime"* ]]; then
    gatebeam_signing_contract_error "hardened runtime flag is missing"
    return 1
  fi
  if [[ "$signing_details" != *"Runtime Version="* ||
        "$signing_details" == *"Runtime Version=0.0.0"* ]]; then
    gatebeam_signing_contract_error "Runtime Version is missing"
    return 1
  fi
}

gatebeam_validate_preview_contract() {
  local requirement="$1"
  local signing_details="$2"
  local entitlements="$3"
  local requirement_expression="${requirement##*designated => }"

  if ! print -r -- "$requirement_expression" |
    /usr/bin/grep -Eq \
      '^cdhash H"[0-9A-Fa-f]{40,128}"( or cdhash H"[0-9A-Fa-f]{40,128}")*$'; then
    gatebeam_signing_contract_error \
      "Developer Preview must use the default exact-build cdhash requirement"
    return 1
  fi
  if ! gatebeam_signing_details_has_line "$signing_details" "Signature=adhoc" ||
     ! gatebeam_signing_details_has_line "$signing_details" "TeamIdentifier=not set"; then
    gatebeam_signing_contract_error \
      "Developer Preview must use an ad-hoc signature without a Team ID"
    return 1
  fi

  gatebeam_validate_hardened_runtime "$signing_details" || return 1
  gatebeam_validate_safe_entitlements "$entitlements" || return 1
}

gatebeam_validate_developer_id_contract() {
  local requirement="$1"
  local signing_details="$2"
  local entitlements="$3"
  local bundle_identifier="$4"
  local team_identifier="$5"
  local requirement_expression="${requirement##*designated => }"
  local unquoted_requirement="${requirement_expression//\"/}"
  local terminated_requirement="$unquoted_requirement and"
  local ca_oid="certificate 1[field.1.2.840.113635.100.6.2.6]"
  local leaf_oid="certificate leaf[field.1.2.840.113635.100.6.1.13]"
  local has_ca_oid=false
  local has_leaf_oid=false

  if [[ "$unquoted_requirement" == *"$ca_oid exists"* ||
        "$unquoted_requirement" == *"$ca_oid /* exists */"* ]]; then
    has_ca_oid=true
  fi
  if [[ "$unquoted_requirement" == *"$leaf_oid exists"* ||
        "$unquoted_requirement" == *"$leaf_oid /* exists */"* ]]; then
    has_leaf_oid=true
  fi

  if [[ "$unquoted_requirement" != *"anchor apple generic"* ||
        "$terminated_requirement" != *"identifier $bundle_identifier and"* ||
        "$has_ca_oid" != true ||
        "$has_leaf_oid" != true ||
        "$terminated_requirement" != *"certificate leaf[subject.OU] = $team_identifier and"* ||
        "$unquoted_requirement" == *" or "* ]]; then
    gatebeam_signing_contract_error \
      "Developer ID requirement is missing its identifier, certificate class, or Team ID constraint"
    return 1
  fi

  if ! gatebeam_signing_details_has_line \
    "$signing_details" \
    "Identifier=$bundle_identifier"; then
    gatebeam_signing_contract_error \
      "signed identifier does not match $bundle_identifier"
    return 1
  fi
  if ! gatebeam_signing_details_has_line \
    "$signing_details" \
    "TeamIdentifier=$team_identifier"; then
    gatebeam_signing_contract_error \
      "signature TeamIdentifier does not match $team_identifier"
    return 1
  fi
  if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
    gatebeam_signing_contract_error \
      "signature authority is not Developer ID Application"
    return 1
  fi

  gatebeam_validate_hardened_runtime "$signing_details" || return 1

  if [[ "$signing_details" != *"Timestamp="* ||
        "$signing_details" == *"Timestamp=none"* ||
        "$signing_details" == *"Signed Time="* ]]; then
    gatebeam_signing_contract_error "secure timestamp is missing"
    return 1
  fi

  gatebeam_validate_safe_entitlements "$entitlements" || return 1
}
