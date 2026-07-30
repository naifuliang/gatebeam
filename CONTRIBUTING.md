# Contributing

Thanks for improving Gatebeam.

## Before You Start

- Keep changes narrowly scoped and explain the network or security behavior they affect.
- Never commit API tokens, domains, hostnames, public IP addresses, router exports,
  Keychain data, signing credentials, or screenshots containing private details.
- Do not add a mapping, pinhole, or DNS update that runs without the user's explicit enablement.
- Preserve the distinction between local-router protocols and internet-facing requests. PCP, NAT-PMP, and UPnP must remain direct LAN traffic.
- Treat a DNS update, router response, local TCP check, and test fixture as
  diagnostics, not as proof of public reachability.
- Report vulnerabilities and possible unintended remote exposure through
  [SECURITY.md](SECURITY.md), not a public issue.

## Development Workflow

1. Create a branch from the current default branch.
2. Use a dedicated Git worktree when developing or independently reviewing a
   change. Do not share generated state between implementation and review.
3. Make focused commits with regression tests proportional to behavior and risk.
4. Run every applicable local gate listed below.
5. Open a pull request that describes behavior, test coverage, migration,
   rollback, privacy impact, and any network hardware required for validation.
6. Obtain independent review for security-sensitive, network-facing, Keychain,
   installer, upgrade, or release changes.

## Required Gates

Run the complete suite before requesting final review:

```sh
./scripts/test_backend.sh
./scripts/test_proxy_policy.sh
./scripts/test_integration_contract.sh
./scripts/test_integration_tsan.sh
./scripts/test_keychain_identity.sh
./scripts/test_upgrade.sh
./scripts/test_ui_validation.sh
./scripts/test_build_assets.sh
./scripts/test_release_pipeline.sh
./scripts/build_app.sh
codesign --verify --deep --strict ./dist/Gatebeam.app
./scripts/test_privacy.sh --range main..HEAD
git diff --check
```

The privacy gate scans tracked and untracked worktree sources, every Git blob in
the requested `main..HEAD` history range, and the final built executable.

The Keychain/signing tests must remain fixture-based and non-interactive. Tests
must not query a contributor's login Keychain, display SecurityAgent prompts,
install Gatebeam, change a real router, or update a real DNS record unless the
test is explicitly isolated, manually authorized, and documented in the PR.

For release changes, also follow [docs/RELEASING.md](docs/RELEASING.md). A green
Developer Preview build does not satisfy Formal Release signing, notarization,
stapling, clean-machine, manifest, or checksum requirements.

## Visual Acceptance

For every AppKit change:

- Capture all affected menu-bar and settings states in Aqua and Dark Aqua.
- Inspect every screenshot, including bottom-scroll states.
- Check alignment, stable dimensions, clipping, overlap, legibility, disabled
  controls, focus rings, scroll reachability, and long localized content.
- Verify that display text does not claim public reachability from local or
  protocol-level evidence.
- Include a concise visual-acceptance summary in the pull request.

## Pull Request Expectations

- Add regression tests for protocol parsing, address selection, and DNS behavior where practical.
- State whether the change was tested with IPv4-only, IPv6-only, dual-stack, a
  VPN/TUN, system/direct/custom proxy policy, PCP, NAT-PMP, UPnP, or a real
  router. Redact all identifying details.
- Do not claim that a router protocol works on all hardware. Vendor implementations vary.
- Keep accessibility labels, fixed control dimensions, and alignment intact for AppKit UI changes.
- Explain configuration, Keychain, installation, upgrade, and rollback effects.
- Describe fail-closed behavior for uncertain DNS, address, router, and temporary
  access state.
- Keep fixtures and screenshots synthetic. Never use a real token, domain,
  hostname, public address, router backup, serial number, or account identifier.

## Review and Merge Policy

- Reviewers prioritize behavioral regressions, exposure risk, credential access,
  migration, rollback, privacy, and missing tests.
- The author resolves all P0 and P1 findings before merge. Document accepted P2
  risks and any follow-up.
- Required CI and independent review must pass on the exact commit being merged.
- Pull requests are integrated with a **merge commit**. Do not squash or rebase
  merge; preserving reviewed commits supports audit, rollback, and release
  traceability.
- Do not force-move a published release tag or silently replace a published
  artifact.

## Reporting Bugs

Use the matching GitHub issue form for reproducible, non-sensitive bugs, router
compatibility reports, or feature requests. Include the app and macOS versions,
sanitized network characteristics, and affected protocol. Do not paste an API
token, domain, hostname, public IP address, router backup, Keychain content, or
personal data.
