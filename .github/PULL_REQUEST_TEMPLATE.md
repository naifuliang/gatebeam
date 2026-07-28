## Summary

<!-- What changed, why it is needed, and the user-visible or maintenance impact. -->

## Risk and Compatibility

<!-- Cover affected DDNS, proxy, address selection, router, Keychain, UI, install,
upgrade, or release behavior. State known limitations without including secrets. -->

## Verification

- [ ] `./scripts/test_backend.sh`
- [ ] `./scripts/test_proxy_policy.sh`
- [ ] `./scripts/test_integration_contract.sh`
- [ ] `./scripts/test_keychain_identity.sh`
- [ ] `./scripts/test_upgrade.sh`
- [ ] `./scripts/test_ui_validation.sh`
- [ ] `./scripts/test_build_assets.sh`
- [ ] `./scripts/test_privacy.sh`
- [ ] `./scripts/build_app.sh`
- [ ] `codesign --verify --deep --strict ./dist/Gatebeam.app`
- [ ] `git diff --check`
- [ ] Not applicable checks are explained below.

## Visual Acceptance

- [ ] No UI changed.
- [ ] Changed states were captured in Aqua and Dark Aqua.
- [ ] Every affected snapshot was inspected for alignment, clipping, overlap,
      scrolling, disabled state, and legibility.

## Network Coverage

<!-- Check only what was actually exercised; do not include hostnames or addresses. -->

- [ ] No network behavior changed.
- [ ] IPv4-only
- [ ] IPv6-only
- [ ] Dual-stack
- [ ] System proxy
- [ ] Direct/no-proxy path
- [ ] Custom HTTP or SOCKS5 proxy
- [ ] VPN/TUN
- [ ] PCP
- [ ] NAT-PMP
- [ ] UPnP
- [ ] Real router or Cloudflare testing is described with sensitive data redacted.

## Migration and Rollback

- [ ] Configuration compatibility was considered.
- [ ] Keychain authorization or migration was considered.
- [ ] Upgrade and failed-upgrade rollback were tested or are not affected.
- [ ] Router mappings and temporary access fail closed during failure or rollback.

## Privacy and Release Impact

- [ ] No API token, private hostname, domain, public IP address, router backup,
      Keychain data, signing secret, or personal data is present.
- [ ] Logs, fixtures, screenshots, and metadata are sanitized.
- [ ] Developer Preview versus Formal Release wording remains accurate.
- [ ] Developer ID signing, notarization, stapling, checksums, and release notes
      were reviewed if formal-release behavior is affected.
- [ ] This PR will be merged with a merge commit, without squash.

## Reviewer Notes

<!-- Trade-offs, unverified hardware, follow-up work, and areas needing focused review. -->
