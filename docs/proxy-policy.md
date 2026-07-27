# Proxy Policy

This document defines the intended network-path contract for Gatebeam. It is useful both for implementation and for diagnosing why a DDNS record may not reflect the address that outside clients can reach.

## Principles

1. Do not send LAN router-control protocols through a proxy.
2. Make direct public-address discovery the default so a proxy exit address is not mistaken for the home connection.
3. Allow Cloudflare API requests to use the system proxy or a validated custom proxy when a managed network requires it.
4. Make the selected path visible in diagnostics without revealing tokens, hostnames, or complete public addresses.
5. Treat packet-level VPNs and transparent interception as outside the control of URLSession proxy settings.

Use a system-managed proxy for authenticated deployments. Do not embed proxy usernames or passwords in a custom proxy URL because regular configuration storage is not a Keychain substitute.

## Operations

| Operation | Path | User choice | Failure guidance |
| --- | --- | --- | --- |
| Cloudflare API | System proxy by default | System proxy, direct, or custom HTTP/HTTPS/SOCKS proxy | Switch to direct if the proxy rewrites or blocks API traffic; use a system or validated custom proxy on managed networks that require it. |
| IPv4/IPv6 public-address probe | Direct by default | Direct, system proxy, or custom proxy | Direct is recommended. A proxy result may be the proxy exit, not the router's WAN address. |
| Router WAN address query | LAN direct | None | Confirm the selected gateway and check for CGNAT/private WAN addressing. |
| PCP/NAT-PMP/UPnP | LAN direct | None | Confirm that the Mac is on the expected LAN/VLAN and that the router allows the protocol. |
| External reachability check | Direct by default | Direct where supported | Run from an external network; LAN hairpin NAT can produce misleading local results. |

## Address Selection

- Prefer the router's WAN IPv4 report over an HTTP probe when both are available.
- Treat RFC 1918 and carrier-grade NAT ranges as a warning for public IPv4 reachability.
- Prefer a globally routable IPv6 address on a physical interface.
- Avoid loopback, link-local, ULA, and tunnel addresses unless there is no other explicit user-selected route.
- Renew AAAA records and IPv6 pinholes when a selected IPv6 address changes.

## Privacy

Diagnostics should show the chosen family, source class, and whether a proxy was used. They should not persist raw Cloudflare tokens, full public addresses, hostnames, or router responses in logs by default.
