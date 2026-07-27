# Product Direction

## Purpose

Gatebeam keeps a deliberately narrow remote-desktop path understandable and manageable:

```text
Hostname -> current address -> router policy -> macOS Screen Sharing service
```

It is a companion for users who understand the implications of publishing VNC. It is not a replacement for private overlay networking, endpoint hardening, or router administration.

## Current Capability

- Native macOS menu bar status and settings interface.
- Cloudflare DNS-only `A` and `AAAA` record management.
- IPv4, IPv6, and dual-stack operation.
- Direct LAN router control through PCP, NAT-PMP, UPnP IGD, and IPv6 firewall pinholes where supported.
- Per-family diagnostics for local address, public address, router path, and connection URL.
- Independent proxy controls for Cloudflare API traffic and public-address probes.
- Temporary access, mapping renewal, and removal on disable.

## Product Principles

1. **Be explicit about network paths.** Users should know whether an operation uses the system proxy, a custom proxy, or a direct route.
2. **Do not hide partial success.** IPv4 behind CGNAT and working IPv6 is a useful result, not a generic failure.
3. **Make public exposure intentional.** Access remains disabled until explicitly enabled and should be easy to turn off.
4. **Avoid false confidence.** A router accepting a mapping request does not prove that an outside client can connect.
5. **Keep secrets narrow.** Tokens stay in Keychain; documentation, diagnostics, tests, and screenshots use placeholders only.

## Near-Term Work

- Strengthen external verification with clearly labeled direct-path diagnostics.
- Add router/vendor interoperability fixtures without embedding personal network data.
- Improve accessibility and visual regression coverage for all status and settings states.
- Document a safer private-network alternative path for users who should not expose VNC publicly.
