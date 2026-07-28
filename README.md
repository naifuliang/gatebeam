# Gatebeam

Gatebeam is a native macOS menu bar app for keeping a remote-desktop entry point current without handing DNS and router mapping work to a collection of unrelated tools. It manages Cloudflare DDNS and local-network port exposure for macOS Screen Sharing / Remote Management (TCP `5900`).

> **0.5.0 Developer Preview:** this is an open-source preview of Gatebeam, released under the [MIT License](LICENSE). The application is ad-hoc signed for development, the PKG is unsigned, and no artifact is notarized or stapled. Review and build it locally before exposing a remote-desktop service.

> **Known preview limitations:** a successful local mapping or DNS update does not prove that an outside client can reach the Mac. Router behavior, CGNAT, upstream firewalls, and ISP policy can still block inbound traffic. `Direct` bypasses URLSession proxy selection, but cannot bypass a VPN/TUN or transparent network interception. Custom proxy URLs support `http://` and `socks5://` only. External reachability verification must be performed from a separately controlled external network.

> **Security first:** publishing VNC to the public internet is inherently risky. This app helps manage the network path; it does not make an internet-facing VNC service safe by itself. Read [Network and VNC safety](#network-and-vnc-safety) before enabling remote access.

![Menu bar status panel](docs/screenshots/popover.png)

![Settings window](docs/screenshots/settings.png)

## What It Does

- Updates Cloudflare DNS-only `A` and `AAAA` records, creating a missing record when necessary.
- Supports IPv4-only, IPv6-only, and dual-stack DDNS operation.
- For IPv4, uses the usable address on the macOS IPv4 default-route interface first, then falls back to a usable `en`, `bridge`, or `ppp` interface if that route address is unavailable.
- For IPv6, accepts only stable global addresses on eligible physical interfaces. Tunnel and virtual interface families are hard-excluded even when one owns the IPv6 default route; temporary, deprecated, detached, ULA, link-local, and loopback addresses are also excluded.
- Uses PCP where available, NAT-PMP for IPv4, and UPnP IGD for IPv4 port mappings.
- Supports UPnP `WANIPv6FirewallControl` pinholes for IPv6-capable routers.
- Checks whether macOS Screen Sharing / Remote Management is listening on TCP `5900`.
- Renews tracked mappings and attempts to remove them before disabling access or changing mapping identity.
- Stores Cloudflare credentials in the macOS Keychain, not in the app configuration file.

## Quick Start

1. Enable **Screen Sharing** or **Remote Management** in macOS System Settings.
2. Open Gatebeam from the menu bar and open **Settings**.
3. Select **Cloudflare**, enter an API token, then choose a zone and hostname.
4. Choose `IPv4`, `Dual`, or `IPv6` address mode.
5. Confirm the inside port (`5900`) and choose a high external IPv4 port.
6. Review the network-path status and explicitly enable remote access.

The app creates DNS records as **DNS only**. Cloudflare's standard orange-cloud proxy is for HTTP(S) and will not proxy a VNC TCP connection.

## Proxy And Network Path Policy

Different operations should not all inherit the same proxy behavior. In particular, a public-IP lookup routed through a local VPN or HTTP proxy can publish the proxy exit address instead of the address reachable through the home router.

The app presents a network-path setting for Cloudflare/DDNS traffic and keeps local-router protocols direct. The intended defaults are deliberately conservative:

| Operation | Default behavior | Configurable | Why |
| --- | --- | --- | --- |
| Cloudflare token verification and DNS updates | Follow macOS proxy settings | Yes: system proxy, direct, or custom `http://` / `socks5://` proxy | Some managed networks require a proxy to reach Cloudflare. |
| Public IPv4/IPv6 address probes | Direct, bypass HTTP/HTTPS/SOCKS/PAC and auto-discovery | Yes: direct, system proxy, or custom `http://` / `socks5://` proxy | Direct is recommended; a proxy can return its own exit address. |
| Router WAN IPv4 query | Direct local-network protocol | No | NAT-PMP, PCP, and UPnP target the local gateway, not the internet. |
| PCP, NAT-PMP, UPnP, and IPv6 pinholes | Direct local-network protocol | No | These are LAN control protocols and must never traverse an HTTP proxy. |
| Local-origin TCP check | Loopback/LAN only | No | It verifies the Mac's own TCP listener. It is not a public-IP check and does not prove that an outside client can connect. |
| External reachability verification | Separate external test | N/A | Run it from a separately controlled network. A local-origin TCP check, local mapping, or DNS update cannot prove public reachability. |

The router-reported WAN IPv4 address is preferred over a web probe when the router provides one. The app detects private/CGNAT-like router WAN addresses and reports that an IPv4 mapping may not be reachable from the wider internet. IPv4 local-address selection follows the default-route interface first. IPv6 selection hard-excludes tunnel and virtual interfaces before ranking stable global candidates.

The menu bar status popover displays the complete addresses and connection URLs needed for the user to connect or copy them. Those values exist only in local UI state.

Gatebeam 0.5.0 does not provide a diagnostic-export command and does not persist a diagnostic log. If either capability is added later, it must redact credentials, hostnames, public addresses, and router responses by default.

## Mapping Cleanup Contract

Gatebeam does not claim that remote access is off until every tracked router rule has been removed. If deletion fails, it keeps remote access marked enabled, persists the exact remaining mappings for retry, and blocks mapping-identity changes from creating replacement rules. If a newly created rule cannot be checkpointed and compensation cleanup also fails, Gatebeam records that rule in its recovery journal. On a later check or launch, journal cleanup runs before any new mapping is opened.

## Check Interval

The recurring check interval defaults to `300` seconds and accepts `60` through `86400` seconds. Missing, non-finite, zero, or negative numeric values normalize to `300`; positive values below or above the supported range normalize to the nearest limit. A non-numeric settings-field entry uses `300`. Normalized legacy values are written back; a configuration file that cannot be decoded falls back to the complete default configuration.

Even direct URLSession traffic cannot bypass a route-level VPN/TUN, firewall, or transparent network interception. During diagnosis, temporarily disable those tools or compare the displayed route and address with your router's own status page.

## Cloudflare Permissions

Create a scoped API token under **Cloudflare Dashboard > My Profile > API Tokens > Create Token**. The **Edit zone DNS** template is a good starting point. Grant:

- `Zone > DNS > Edit`
- `Zone > Zone > Read`

Restrict **Zone Resources** to the one zone used by this Mac. Use access to all zones only when you want the app to list every eligible zone. Do not use the Global API Key. Avoid Client IP filtering for a DDNS token because the connection's source address can change.

Useful Cloudflare references:

- [Create API tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
- [DNS Records API](https://developers.cloudflare.com/api/resources/dns/subresources/records/)

## IPv6 Notes

IPv6 normally uses firewall pinholes rather than address translation. PCP may grant the requested external port; `WANIPv6FirewallControl` exposes the Mac's local service port directly. As a result, IPv4 and IPv6 can legitimately have different connection ports. The app should show separate family-specific VNC URLs in that case.

Some networks do not offer usable global IPv6, do not expose PCP, or prohibit inbound IPv6 in the ISP router. Dual-stack status is therefore reported per address family rather than as a single all-or-nothing result.

Protocol references: [PCP RFC 6887](https://datatracker.ietf.org/doc/html/rfc6887) and [UPnP WANIPv6FirewallControl](https://upnp.org/specs/gw/UPnP-gw-WANIPv6FirewallControl-v1-Service.pdf).

## Build And Test

Requirements: macOS with Xcode Command Line Tools or Xcode installed.

```sh
./scripts/test_backend.sh
./scripts/test_proxy_policy.sh
./scripts/test_integration_contract.sh
./scripts/test_upgrade.sh
./scripts/test_ui_validation.sh
./scripts/test_build_assets.sh
./scripts/test_privacy.sh
./scripts/build_app.sh
```

The validation suite is split by contract:

- `test_backend.sh`: Cloudflare, address-family, router mapping, IPv6, and status behavior.
- `test_proxy_policy.sh`: system/direct/custom routing, direct-proxy disabling, supported `http://` / `socks5://` forms, invalid proxy rejection, and direct-only LAN control.
- `test_integration_contract.sh`: configuration normalization, non-Custom proxy URL clearing, injected-store isolation, local-origin status semantics, and stable login-path behavior.
- `test_upgrade.sh`: migration, rollback, symlink/path safety, and stable LaunchAgent installation behavior.
- `test_ui_validation.sh`: isolated AppKit validation mode, no network side effects, no Keychain prompts, and UI contract coverage.
- `test_build_assets.sh`: icon, app bundle, PKG, and DMG staging/build-asset checks.
- `test_privacy.sh`: credentials, email addresses, bare domains, IPv4/IPv6 literals, user-specific paths, and built-binary private material against explicit fixture allowlists.

The built app is written to `dist/Gatebeam.app`. `test_ui_validation.sh` is a UI contract check; the final preview should also be visually inspected from rendered screenshots for both Aqua and Dark Aqua states.

For a distributable artifact:

```sh
./scripts/package_pkg.sh
./scripts/package_dmg.sh
```

The PKG supports installation and upgrade, but the preview PKG is unsigned. A DMG is release-valid only after a real `hdiutil create`, `hdiutil convert`, and `hdiutil verify` run on a macOS environment that can create disk images; staging or `--validate-only` checks do not replace that verification.

## Installation And Trust

The 0.5.0 Developer Preview app uses an ad-hoc signature. The PKG is unsigned, and the app, PKG, and DMG are not notarized or stapled. macOS may therefore show a security warning on first launch. Build from source when you need a fully auditable local artifact.

Start at Login is written only for a stable installed app in `/Applications/Gatebeam.app` or `~/Applications/Gatebeam.app`. The app refuses temporary, build-output, legacy, or symbolic-link locations so a LaunchAgent cannot be redirected by an unstable path.

Do not grant Keychain access to a process you do not recognize. A legitimate app should request access only when saving or retrieving its own Cloudflare token, never repeatedly while merely displaying diagnostics or screenshots.

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

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request. Security-sensitive bugs should follow [SECURITY.md](SECURITY.md), not public issue reporting.

## License

Released under the [MIT License](LICENSE).
