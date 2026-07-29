# Gatebeam

Gatebeam is a native macOS menu bar app for Cloudflare DDNS and optional local-router port mapping for macOS Screen Sharing or Remote Management. It keeps a chosen DNS name current and can ask a compatible home router to expose the Mac's remote-desktop port.

> **Developer Preview:** Gatebeam is not a guarantee of public reachability. A DNS update, local listener check, or router mapping can still be blocked by CGNAT, double NAT, an ISP, a firewall, VPN/TUN routing, or router policy. Test from a separately controlled external network before relying on it.

> **Security:** exposing VNC or Screen Sharing to the internet is risky. Prefer a private overlay network, SSH tunnel, or managed remote-access service for long-lived access. Keep access off when it is not needed.

![Menu bar status panel](docs/screenshots/popover.png)

![Settings window](docs/screenshots/settings.png)

## First Setup

1. In macOS System Settings, enable **Screen Sharing** or **Remote Management** and confirm the intended account may sign in.
2. Create a scoped Cloudflare API token following [Cloudflare setup](docs/cloudflare-setup.md). Do not use a Global API Key.
3. Open Gatebeam from the menu bar, open **Settings**, and choose Cloudflare. For an existing saved token, use **Authorize Token** when available. For a new or replacement token, complete the token-save action offered by your build. Save the remaining settings, then click **Verify** to load the zones the token can read.
4. Choose a **Domain** (the Cloudflare zone) and enter a **Subdomain**. For example, choose `example.com` and enter `remote`, `remote.example.com`, or `@`.
5. Choose the address mode, network paths, router protocol, ports, and lease. See [Networking and remote access](docs/networking.md).
6. Save the configuration, review the displayed status, then explicitly turn on remote access.
7. From an external network, test the displayed connection address. A successful local check is not an external test.

The app creates missing records as **DNS only** `A` and/or `AAAA` records. Cloudflare's orange-cloud proxy does not proxy arbitrary VNC TCP traffic.

## What Verify Means

**Verify** confirms only that the token is active and can read one or more Cloudflare zones. It does not prove that the token may edit DNS. DNS Edit is confirmed only when Gatebeam first creates or updates the selected `A` or `AAAA` record. If that write is rejected, correct the token permissions in Cloudflare and try the update again.

## Network Paths

Cloudflare/DDNS and public-IP probing each have their own **System**, **Direct**, or **Custom** mode. The current preview has one shared Custom proxy URL: every service set to Custom uses the same URL. Router protocols always use the local network directly.

- **System** follows macOS proxy settings.
- **Direct** bypasses URLSession HTTP, HTTPS, SOCKS, PAC, and proxy auto-discovery. It does not bypass a route-level VPN/TUN, firewall, or transparent interception.
- **Custom** accepts a validated `http://` or `socks5://` proxy URL. Do not put proxy credentials in it.

For the complete contract and diagnosis path, read [Proxy policy](docs/proxy-policy.md) and [Networking and remote access](docs/networking.md).

## Keychain

Gatebeam stores the Cloudflare token in the macOS Keychain, never in its normal configuration file. The candidate credential-safety release introduces explicit token controls:

- **Save Changes** keeps an existing saved token and does not read, write, or delete it.
- **Authorize Token** is the intentional path to let the current build access an existing token, including after an app upgrade.
- **Replace Token** intentionally writes a non-empty replacement.
- **Remove Token** requires confirmation and deletes only the saved token.

These controls may cause a one-time macOS Keychain authorization prompt. Background checks, launch, timers, diagnostics, and normal saves should not prompt. If macOS denies or cancels a prompt, do not keep retrying: open Settings and use the explicit authorization action when ready. This behavior applies only after the candidate credential-safety change is included. Older preview builds may access Keychain during Verify or Save; upgrade to the candidate release before relying on the explicit-control contract.

## Safety Checklist

- Use a strong macOS account password and keep macOS updated.
- Use a high, random external IPv4 port instead of publicly exposing TCP `5900`.
- Treat an IPv6 firewall pinhole to the inside port as public exposure too.
- Keep mapping leases finite and enable renewal only when continued access is intended.
- Close remote access in Gatebeam before quitting for an extended period, uninstalling, or rolling back. Confirm that mapping removal succeeded.
- Do not assume LAN hairpin NAT proves outside connectivity.

## Detailed Guides

- [Cloudflare setup](docs/cloudflare-setup.md): permissions, zones, records, rotation, and record cleanup.
- [Networking and remote access](docs/networking.md): address modes, proxy paths, router protocols, ports, leases, and troubleshooting.
- [Proxy policy](docs/proxy-policy.md): precise request-path behavior.
- [Architecture](docs/architecture.md): implementation overview.
- [Releasing](docs/RELEASING.md): maintainer release process.

## Build And Test

Requirements: macOS with Xcode Command Line Tools or Xcode.

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
./scripts/test_final_artifact_contract.sh
./scripts/test_final_candidate_validator.sh
./scripts/test_formal_publish.sh
./scripts/test_release_workflow_contract.sh
./scripts/build_app.sh
./scripts/test_privacy.sh
```

The validation suite is split by contract:

- `test_backend.sh`: Cloudflare, address-family, router mapping, IPv6, and status behavior.
- `test_proxy_policy.sh`: system/direct/custom routing, direct-proxy disabling, supported `http://` / `socks5://` forms, invalid proxy rejection, and direct-only LAN control.
- `test_integration_contract.sh`: configuration normalization, non-Custom proxy URL clearing, injected-store isolation, explicit Keychain migration/failure latching, local-origin status semantics, and stable login-path behavior.
- `test_integration_tsan.sh`: the integration-contract suite compiled and run with Thread Sanitizer enabled.
- `test_keychain_identity.sh`: Developer Preview and Developer ID signing-contract validation, exact-build identity rejection, and host-aware hardened-runtime library-validation evidence. It does not access any Keychain.
- `test_upgrade.sh`: migration, rollback, symlink/path safety, and stable LaunchAgent installation behavior.
- `test_ui_validation.sh`: isolated AppKit validation mode, no network side effects, no Keychain prompts, and UI contract coverage.
- `test_build_assets.sh`: icon, app bundle, PKG, and DMG staging/build-asset checks.
- `test_release_pipeline.sh`: fixture-based, fail-closed validation of the formal release pipeline and its publication gates.
- `test_final_artifact_contract.sh`: exact-byte candidate and attestation binding, descriptor-bound extraction under path replacement, safe extraction, replay prevention, and linked-path rejection.
- `test_final_candidate_validator.sh`: actual validator behavior for exact APP/ZIP/flat-PKG/DMG allowlists, productsign RSA/CMS XAR structure, XAR/cpio and sparse-file budgets, signing gates, install/upgrade/rollback/uninstall failures, and no-attestation failure semantics.
- `test_formal_publish.sh`: trusted GitHub Actions evidence, complete SemVer 2.0 immutable history, the POST/upload/PATCH by 401/403/404/5xx mutation matrix, response-loss recovery, concurrent remote draft ownership, exact API asset upload, immutable publication, and atomic failure cases.
- `test_release_workflow_contract.sh`: pinned Actions, job ordering, signing-secret isolation, and no-rebuild publication policy.
- `test_privacy.sh`: credentials, email addresses, bare domains, IPv4/IPv6 literals, user-specific paths, and built-binary private material against explicit fixture allowlists.

Automated tests use injected stores or signing fixtures and do not access a contributor's login Keychain.

Formal releases use a three-stage, fail-closed path: the tagged workflow signs,
notarizes, staples, and freezes one candidate; a second clean macOS job validates
those exact bytes and emits a hash-bound attestation without signing secrets;
`release_formal.sh` then creates the GitHub draft, uploads and verifies the
seven exact frozen assets, rechecks all evidence, and publishes only that
attested candidate as an immutable release without rebuilding or rewriting it.
The publisher is the third job of the same globally serialized tagged workflow;
there is no manual upload or publish handoff.
Every GitHub mutation is assigned an exact byte identity and publication nonce;
if a POST, upload, or PATCH response is lost, the publisher paginates remote
state and resumes only from one exact matching draft, asset, or immutable
release.
See [Releasing Gatebeam](docs/RELEASING.md).

The built app is written to `dist/Gatebeam.app`. `test_ui_validation.sh` is a UI contract check; the final preview should also be visually inspected from rendered screenshots for both Aqua and Dark Aqua states.

By default, `build_app.sh` creates a Developer Preview with the system-generated ad-hoc designated requirement. That requirement must contain an exact-build `cdhash`; the script refuses identifier-only signing. For a production Developer ID build, leave requirement synthesis to `codesign` and provide both values:

```sh
GATEBEAM_CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
GATEBEAM_DEVELOPER_TEAM_ID='TEAMID' \
./scripts/build_app.sh
```

The build then enables hardened runtime and timestamping and verifies that the resulting designated requirement contains the Apple generic anchor and expected leaf Team ID. Gatebeam does not accept a manually weakened identifier-only requirement. A formal Developer ID build also runs an independent CLI fixture to confirm that the host can enforce library validation; if the host cannot provide that runtime evidence, the formal build is blocked instead of silently weakening the release gate.

Developer Preview validation uses the same independent fixture to classify the host before testing Gatebeam. On hosts that enforce library validation for ad-hoc hardened-runtime processes, a different-identity library must be rejected by Gatebeam. Some CI hosts do not enforce that ad-hoc policy; they emit an explicit warning and retain all static runtime, identifier, strict-signature, and entitlement checks without claiming that runtime injection rejection was proven.

For a distributable artifact:

```sh
./scripts/package_pkg.sh
./scripts/package_dmg.sh
```

The PKG supports installation and upgrade, but the preview PKG is unsigned. A DMG is release-valid only after a real `hdiutil create`, `hdiutil convert`, and `hdiutil verify` run on a macOS environment that can create disk images; staging or `--validate-only` checks do not replace that verification.

## Installation And Trust

The 0.5.0 Developer Preview app uses an ad-hoc signature. The PKG is unsigned, and the app, PKG, and DMG are not notarized or stapled. macOS may therefore show a security warning on first launch. Build from source when you need a fully auditable local artifact.

Gatebeam stores new tokens under the versioned service `io.github.naifuliang.gatebeam.cloudflare-token.v3`. A Developer ID release uses the Apple-anchored, Team-ID-qualified default designated requirement, so ordinary updates signed by the same developer remain trusted. A Developer Preview has no durable developer identity, so its ACL intentionally trusts only that exact build's `cdhash`. Background checks never display Keychain authorization UI. If a replacement build needs access, the user must click **Authorize Token** in Settings; this refreshes the ACL for the current build. The same explicit action is the only path that reads the older `com.local.RemoteControlNetwork.secure-v2` item, verifies the new item, and deletes the weak legacy item.

Start at Login is written only for a stable installed app in `/Applications/Gatebeam.app` or `~/Applications/Gatebeam.app`. The app refuses temporary, build-output, legacy, or symbolic-link locations so a LaunchAgent cannot be redirected by an unstable path.

Do not grant Keychain access to a process you do not recognize. Gatebeam permits authorization UI only after the explicit Settings action described above or while the user saves a token. Startup, timers, diagnostics, screenshots, UI validation, and CI use noninteractive or injected Keychain backends and must never touch the production service or repeatedly prompt.

Use the macOS system proxy when it requires authentication. Avoid embedding a proxy username or password in a custom `http://` or `socks5://` URL, because configuration files are not a replacement for Keychain-backed secret storage.

## Network And VNC Safety

- Keep remote access disabled unless you are actively using it.
- Use a strong macOS account password and keep macOS patched.
- Prefer a random high IPv4 external port over public TCP `5900`.
- Set a temporary access window and close mappings afterward.
- Treat an IPv6 pinhole to TCP `5900` as public exposure of the native service.
- Test from a network outside your home LAN; many routers do not support hairpin NAT.
- Prefer a private overlay network, SSH tunnel, or managed remote-access solution for long-lived access.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request. Report security-sensitive bugs through [SECURITY.md](SECURITY.md), not a public issue.

## License

Released under the [MIT License](LICENSE).
