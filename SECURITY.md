# Security Policy

## Supported Versions

Security fixes are made against the latest released version and the current default branch.

The `0.5.0` Developer Preview is an ad-hoc signed app with an unsigned, non-notarized PKG. No preview artifact is notarized or stapled. Treat downloaded artifacts as development material and verify the source and checksums before use.

## Reporting A Vulnerability

Please do not open a public issue for a vulnerability that could expose credentials, DNS control, router administration, or remote desktop access.

Use GitHub's private vulnerability reporting feature for this repository when it is enabled. If private reporting is not available, contact the repository maintainers through the contact method listed in the repository profile and include a concise description, affected version, reproduction steps, impact, and any suggested mitigation.

Do not include real API tokens, personal hostnames, user public IP addresses, router backups, or Keychain exports in a report. Redact logs and screenshots before sharing them.

Repository documentation and screenshots must use placeholders rather than personal domains, user IP addresses, API tokens, email addresses, or user-specific filesystem paths. Tests may contain only explicit fixtures: RFC documentation domains and address ranges, loopback/private/reserved protocol values, and a narrowly allowlisted set of non-personal public addresses needed to exercise protocol and global-address classification contracts. They must never contain addresses copied from a contributor's network.

Gatebeam 0.5.0 has no diagnostic-export command and does not persist a diagnostic log. If either capability is added later, it must redact credentials, hostnames, public addresses, and router responses by default. A local-origin TCP check, DNS update, or router mapping response is not evidence of public reachability.

If router-rule deletion fails, Gatebeam keeps access marked enabled and retains the exact failed rule for retry. A failed attempt to checkpoint and close a newly created rule is recorded in the recovery journal, and no replacement rule may be created before recovery cleanup succeeds.

Start at Login is intentionally restricted to stable installed app locations. A LaunchAgent must not be redirected to a temporary, build-output, legacy, or symbolic-link app path.

We aim to acknowledge reports promptly, validate the issue, develop a fix, and coordinate disclosure after affected users have a reasonable path to upgrade.
