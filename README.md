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
./scripts/build_app.sh
./scripts/test_privacy.sh
```

The built application is written to `dist/Gatebeam.app`. This preview is ad-hoc signed unless a formal Developer ID build is configured; review [Releasing](docs/RELEASING.md) before distributing it.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request. Report security-sensitive bugs through [SECURITY.md](SECURITY.md), not a public issue.

## License

Released under the [MIT License](LICENSE).
