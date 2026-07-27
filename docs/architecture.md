# Architecture

Gatebeam is a native AppKit macOS menu bar application. Its UI is intentionally separate from the networking layer so the protocol and address-selection logic can be tested without opening a window or touching a live router.

```text
AppDelegate
├── StatusPopoverViewController
├── SettingsWindowController
├── NetworkAgent
│   ├── LocalNetworkService
│   ├── PublicIPService
│   ├── CloudflareDNSProvider
│   ├── RouterMappingService
│   └── ConnectivityVerifier
├── AppConfigStore
└── KeychainStore
```

## Runtime Flow

1. Load non-secret configuration from local storage and the Cloudflare token from Keychain only when an API operation needs it.
2. Determine the active physical route, LAN IPv4 address, global IPv6 candidate, and local TCP `5900` listener state.
3. Discover router capabilities and router-reported WAN addressing through direct LAN protocols.
4. Resolve the selected public-address path. IPv4 and IPv6 are tracked independently.
5. Update Cloudflare `A` and/or `AAAA` records according to the selected address-family mode.
6. When remote access is explicitly enabled, create or renew the applicable IPv4 mapping and IPv6 pinhole.
7. Publish a compact per-family status model to the menu bar and settings UI.
8. Re-run on schedule and after relevant local network changes.

## Network Boundaries

The app has two distinct traffic classes:

- **Internet-facing HTTP traffic:** Cloudflare API and public-address probes use URLSession and honor their independently selected proxy mode: system, direct, or a validated custom HTTP/HTTPS/SOCKS proxy.
- **LAN control traffic:** PCP, NAT-PMP, UPnP, gateway discovery, and local TCP checks are always direct. They never use the HTTP proxy setting.

`Direct` disables URLSession HTTP, HTTPS, SOCKS, PAC, and auto-discovery proxies. It cannot bypass a route-level VPN, packet tunnel, firewall, or transparent network interception.

## State Model

`AppStatus` is the UI contract. It provides explicit component states, readable messages, technical detail, timestamps, selected IPv4/IPv6 addresses, per-family ports, and one or two connection URLs. UI views must not infer health from raw log text.

`AppConfig` contains behavior such as DNS zone and record name, address-family mode, mapping preference, lease duration, proxy modes, and a custom proxy URL. Cloudflare tokens remain in Keychain and must not be copied into configuration, logs, diagnostics, or screenshots. A custom proxy URL should not embed credentials; use a system-managed authenticated proxy instead.

## Protocol Strategy

- IPv4 automatic mode prefers PCP, then NAT-PMP, then UPnP IGD where applicable.
- IPv6 automatic mode prefers PCP and can fall back to UPnP `WANIPv6FirewallControl` pinholes.
- A router may offer only a subset of these mechanisms. The app reports partial IPv4/IPv6 success rather than treating a dual-stack network as binary.
- IPv6 pinholes do not generally translate ports. When the IPv4 external port and IPv6 service port differ, the UI exposes separate connection URLs.

## Safety Invariants

- Remote access is disabled by default and mapping creation requires explicit enablement.
- Disabling access removes app-managed mappings/pinholes where the router protocol allows it.
- DNS records are Cloudflare DNS-only records; HTTP proxying is not used for VNC.
- Diagnostics avoid stored credentials and sensitive network identifiers by default.
