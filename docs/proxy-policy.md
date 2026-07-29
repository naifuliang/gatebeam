# Proxy Policy

This document defines the network-path contract for Gatebeam. For a first-time setup and router guidance, see [Networking and remote access](networking.md).

## Principles

1. Do not send LAN router-control protocols through a proxy.
2. Make direct public-address discovery the default so a proxy exit address is not mistaken for the home connection.
3. Allow Cloudflare API requests to use the system proxy or a validated custom proxy when a managed network requires it.
4. Make the selected path visible in the status UI. The status popover may show complete connection addresses and URLs for copying. Gatebeam 0.5.0 has no diagnostic export and does not persist a diagnostic log; any future implementation must redact hostnames, public addresses, and credentials by default.
5. Treat packet-level VPNs and transparent interception as outside the control of URLSession proxy settings.
6. The current build has independent mode selections but one shared Custom URL. Every operation set to Custom uses that same URL.

Use a system-managed proxy for authenticated deployments. Do not embed proxy usernames or passwords in a custom proxy URL because regular configuration storage is not a Keychain substitute. Custom mode accepts only `http://host:port` and `socks5://host:port`; credentials, paths, queries, fragments, and other schemes are rejected.

## Operations

| Operation | Path | User choice | Failure guidance |
| --- | --- | --- | --- |
| Cloudflare API | System proxy by default | System proxy, Direct, or Custom `http://` / `socks5://` proxy | Switch to Direct if the proxy rewrites or blocks API traffic; use System or Custom on managed networks that require it. |
| IPv4/IPv6 public-address probe | Direct by default | Direct, System proxy, or Custom `http://` / `socks5://` proxy | Direct is recommended. A proxy result may be the proxy exit, not the router's WAN address. The probe is still not an external reachability test. |
| Router WAN address query | LAN direct | None | Confirm the selected gateway and check for CGNAT/private WAN addressing. |
| PCP/NAT-PMP/UPnP | LAN direct | None | Confirm that the Mac is on the expected LAN/VLAN and that the router allows the protocol. |
| Local-origin TCP check | LAN/loopback direct | None | Confirms only that the Mac's local service listener responds. It is not evidence that a public client can connect. |
| External reachability verification | Separate external test | N/A | Run a separately controlled test from an external network; LAN hairpin NAT can produce misleading local results. |

## Address Selection

- Prefer the router's WAN IPv4 report over an HTTP probe when both are available.
- Treat RFC 1918 and carrier-grade NAT ranges as a warning for public IPv4 reachability.
- Prefer a globally routable IPv6 address on a physical interface.
- Hard-exclude tunnel and virtual interfaces from IPv6 DDNS selection even when they own the default route. Also exclude loopback, link-local, ULA, temporary, deprecated, and detached IPv6 addresses.
- The `AAAA` record uses the selected stable global IPv6 address on this Mac. The public IPv6 probe is diagnostic only and does not supply the DNS value.
- Renew AAAA records and IPv6 pinholes when a selected IPv6 address changes.

## Privacy

The status popover should show the chosen family, source class, proxy mode, and complete connection address when one is available. Any future diagnostic export or persistent log should retain only the minimum useful family/source metadata while redacting raw Cloudflare tokens, full public addresses, hostnames, and router responses by default.
