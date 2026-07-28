# Product Direction

## Purpose

Gatebeam keeps a deliberately narrow remote-desktop path understandable and manageable:

```text
Hostname -> current address -> router policy -> macOS Screen Sharing service
```

It is a companion for users who understand the implications of publishing VNC. It is not a replacement for private overlay networking, endpoint hardening, or router administration.

## Current Capability

The current release line is **0.5.0 Developer Preview**. The app is ad-hoc signed for development; the PKG is unsigned; and no app, PKG, or DMG artifact is notarized or stapled. A DMG is accepted only after real `hdiutil` creation and verification on a capable macOS host.

- Native macOS menu bar status and settings interface.
- Cloudflare DNS-only `A` and `AAAA` record management.
- IPv4, IPv6, and dual-stack operation.
- Direct LAN router control through PCP, NAT-PMP, UPnP IGD, and IPv6 firewall pinholes where supported.
- Per-family diagnostics for local address, public address, router path, and connection URL.
- Independent proxy controls for Cloudflare API traffic and public-address probes.
- Temporary access, mapping renewal, and removal on disable.
- Stable Start at Login integration limited to `/Applications/Gatebeam.app` or `~/Applications/Gatebeam.app`.

The status popover may display complete local/public addresses and family-specific connection URLs so the user can copy them. Gatebeam 0.5.0 has no diagnostic export and does not persist a diagnostic log. Any future export or persistent log must redact credentials and sensitive network identifiers by default.

## Product Principles

1. **Be explicit about network paths.** Users should know whether an operation uses the system proxy, a custom proxy, or a direct route.
2. **Do not hide partial success.** IPv4 behind CGNAT and working IPv6 is a useful result, not a generic failure.
3. **Make public exposure intentional.** Access remains disabled until explicitly enabled and should be easy to turn off.
4. **Avoid false confidence.** A router accepting a mapping request does not prove that an outside client can connect.
5. **Keep secrets narrow.** Tokens stay in Keychain; documentation, diagnostics, tests, and screenshots use placeholders only.

## Release Contract

- A local-origin TCP check confirms only the Mac's local listener. It does not validate the public address or prove that an outside client can connect.
- Mapping deletion must complete before access is marked disabled or a replacement rule is created. Failed rules remain tracked for retry, and uncheckpointed rules that cannot be closed are retained in the recovery journal.
- The recurring check interval defaults to 300 seconds, accepts 60 through 86400 seconds, and migrates invalid legacy values to the default or nearest supported limit.
- `Direct` only disables URLSession proxy selection; it cannot bypass a VPN/TUN or transparent interception.
- Custom proxy configuration is limited to `http://host:port` and `socks5://host:port`. When neither proxy setting is Custom, the persisted custom URL is empty.
- Login-item configuration is limited to stable installed locations and never follows temporary or symbolic-link app paths.
- Documentation and screenshots use placeholders. Tests may use RFC documentation, loopback, private, reserved protocol, and narrowly allowlisted non-personal public protocol/classification fixtures. Future diagnostic exports and persistent logs must redact user network identifiers and secrets.
