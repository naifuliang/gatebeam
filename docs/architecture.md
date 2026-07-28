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
│   └── AppStatus aggregation
├── AppConfigStore
└── KeychainStore
```

## Runtime Flow

1. Load non-secret configuration from local storage and the Cloudflare token from Keychain only when an API operation needs it.
2. Determine the active physical route, LAN IPv4 address, global IPv6 candidate, and local-origin TCP `5900` listener state. This local-origin check is not an external reachability test.
3. Discover router capabilities and router-reported WAN addressing through direct LAN protocols.
4. Resolve the selected public-address path. IPv4 and IPv6 are tracked independently.
5. Update Cloudflare `A` and/or `AAAA` records according to the selected address-family mode.
6. When remote access is explicitly enabled, create or renew the applicable IPv4 mapping and IPv6 pinhole.
7. Publish a compact per-family status model to the menu bar and settings UI.
8. Re-run on schedule and after relevant local network changes. The default interval is 300 seconds, normalized to the inclusive 60-to-86400-second range; invalid numeric legacy values are normalized and written back.

## Network Boundaries

The app has two distinct traffic classes:

- **Internet-facing HTTP traffic:** Cloudflare API and public-address probes use URLSession and honor their independently selected proxy mode: system, direct, or a validated custom `http://` / `socks5://` proxy. Any custom proxy URL is cleared before persistence when neither operation is in Custom mode.
- **LAN control traffic:** PCP, NAT-PMP, UPnP, gateway discovery, and local TCP checks are always direct. They never use the HTTP proxy setting.

`Direct` disables URLSession HTTP, HTTPS, SOCKS, PAC, and auto-discovery proxies. It cannot bypass a route-level VPN, packet tunnel, firewall, or transparent network interception. Custom mode accepts only `http://host:port` and `socks5://host:port` without credentials, paths, queries, or fragments.

## State Model

`AppStatus` is the UI contract. It provides explicit component states, readable messages, technical detail, timestamps, selected IPv4/IPv6 addresses, per-family ports, and one or two connection URLs. The menu bar status popover is allowed to display those complete addresses and URLs because they are the user's connection details. Gatebeam 0.5.0 has no diagnostic export and does not persist a diagnostic log; any future implementation must redact credentials and sensitive network identifiers by default. UI views must not infer health from raw log text.

`AppConfig` contains behavior such as DNS zone and record name, address-family mode, mapping preference, lease duration, check interval, proxy modes, and a custom proxy URL. The check interval defaults to 300 seconds. Non-finite and non-positive numeric values normalize to 300; positive out-of-range values clamp to 60 or 86400; normalized legacy values are written back. If the configuration cannot be read or decoded, the store preserves the damaged file and returns a typed load error. `NetworkAgent` then marks configuration and mapping recovery state as unknown, blocks new mapping creation and settings overwrite, and asks the user to back up the damaged file before restoring a known-good configuration. Cloudflare tokens remain in Keychain and must not be copied into configuration, future logs or exports, or screenshots. A custom proxy URL should not embed credentials; use a system-managed authenticated proxy instead.

## Protocol Strategy

- IPv4 local-address selection follows the macOS IPv4 default-route interface when it has a usable address, with a fallback to usable `en`, `bridge`, or `ppp` interfaces.
- IPv6 selection first hard-excludes tunnel and virtual interface families, even if one owns the default route. It then selects a stable global address from eligible physical interfaces and excludes temporary, deprecated, detached, ULA, link-local, and loopback candidates.
- IPv4 automatic mode prefers PCP, then NAT-PMP, then UPnP IGD where applicable.
- IPv6 automatic mode prefers PCP and can fall back to UPnP `WANIPv6FirewallControl` pinholes.
- A router may offer only a subset of these mechanisms. The app reports partial IPv4/IPv6 success rather than treating a dual-stack network as binary.
- IPv6 pinholes do not generally translate ports. When the IPv4 external port and IPv6 service port differ, the UI exposes separate connection URLs.

## Safety Invariants

- Remote access is disabled by default and mapping creation requires explicit enablement.
- Disabling access or changing mapping identity removes tracked rules first. A failed deletion keeps access marked enabled, persists the exact failed mappings for retry, and prevents creation of a replacement rule.
- If a newly created rule cannot be checkpointed and compensation deletion fails, the recovery journal records it. Recovery cleanup runs before any subsequent mapping creation.
- An unreadable or undecodable configuration is preserved for recovery. Unknown configuration or recovery state fails closed and blocks new router mappings until a known-good configuration is restored.
- DNS records are Cloudflare DNS-only records; HTTP proxying is not used for VNC.
- A local-origin TCP success, router mapping response, or DNS update must never be presented as proof of public reachability.
- Non-Custom proxy modes persist an empty custom proxy URL.
- Start at Login may write only the stable LaunchAgent for `/Applications/Gatebeam.app` or `~/Applications/Gatebeam.app`; temporary and symbolic-link locations are rejected.
- Any future diagnostic export or persistent diagnostic log must avoid stored credentials and redact sensitive network identifiers by default.
