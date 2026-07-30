# Security Policy

## Supported Versions

Security fixes are made against the latest released version and the current default branch.

The `0.5.0` Developer Preview is an ad-hoc signed app with an unsigned, non-notarized PKG. No preview artifact is notarized or stapled. Treat downloaded artifacts as development material and verify the source and checksums before use. Its Keychain authorization is intentionally bound to the exact build rather than merely to the bundle identifier.

## Reporting A Vulnerability

Do not open a public issue for a vulnerability that could expose credentials, DNS control, router administration, or remote desktop access.

Report it through [GitHub Private Vulnerability Reporting](https://github.com/naifuliang/gatebeam/security/advisories/new) and include a concise description, affected version, reproduction steps, impact, and any suggested mitigation.

Do not include real API tokens, personal hostnames, user public IP addresses, router backups, or Keychain exports in a report. Redact logs and screenshots before sharing them.

Repository documentation and screenshots must use placeholders rather than personal domains, user IP addresses, API tokens, email addresses, or user-specific filesystem paths. Tests may contain only explicit fixtures: RFC documentation domains and address ranges, loopback/private/reserved protocol values, and a narrowly allowlisted set of non-personal public addresses needed to exercise protocol and global-address classification contracts. They must never contain addresses copied from a contributor's network.

## Keychain And Code-Signing Identity

Cloudflare tokens are stored only in the versioned service `io.github.naifuliang.gatebeam.cloudflare-token.v3`. New file-keychain items receive an explicit `SecAccess` ACL restricted to the calling Gatebeam build's system-generated designated requirement:

- A Developer ID build must use the default Apple-anchored requirement qualified by its leaf Team ID. `build_app.sh` refuses Developer ID signing without an expected Team ID and verifies both the Apple generic anchor and `TeamIdentifier`.
- A Developer Preview must use the default ad-hoc exact-build `cdhash` requirement. An identifier-only requirement is forbidden because any local program can ad-hoc sign itself with the same identifier.
- Background reads use a noninteractive authentication context. A denial is latched, so timers and diagnostics do not repeatedly prompt.
- Only the **Authorize Token** Settings action may present authorization UI, refresh the current item's ACL, or read the older `com.local.RemoteControlNetwork.secure-v2` item. Migration writes and verifies the new item before deleting the legacy item; cleanup failure is reported rather than hidden.
- UI validation, snapshots, and integration tests use independent injected services/backends. Current automated coverage validates the Keychain model and isolation policy, no-UI query contracts, migration behavior, and code-signing requirements. The code-signing test does not access a Keychain and does not prove that a different same-identifier build cannot read a real item. The disposable-user/VM real-Keychain matrix specified in [ADR 0001](docs/adr/0001-modern-keychain-storage.md) has not yet been run.

`SecAccess` is a deprecated but still public macOS API for file-keychain ACLs. It is used here because the preview requires unattended background access and lacks a stable Developer ID entitlement identity. If Apple removes this API before Gatebeam can require Developer ID distribution, preview storage must become session-only rather than falling back to a weak persistent identity.

Gatebeam 0.5.0 has no diagnostic-export command and does not persist a diagnostic log. If either capability is added later, it must redact credentials, hostnames, public addresses, and router responses by default. A local-origin TCP check, DNS update, or router mapping response is not evidence of public reachability.

If router-rule deletion fails, Gatebeam keeps access marked enabled and retains the exact failed rule for retry. A failed attempt to checkpoint and close a newly created rule is recorded in the recovery journal, and no replacement rule may be created before recovery cleanup succeeds.

Start at Login is intentionally restricted to stable installed app locations. A LaunchAgent must not be redirected to a temporary, build-output, legacy, or symbolic-link app path.

We aim to acknowledge reports promptly, validate the issue, develop a fix, and coordinate disclosure after affected users have a reasonable path to upgrade.
