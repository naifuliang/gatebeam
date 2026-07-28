# Changelog

All notable changes to Gatebeam are documented in this file.

The format follows Keep a Changelog 1.1.0, and Gatebeam intends to follow
Semantic Versioning 2.0.0 once formal releases begin.

## [Unreleased]

These entries describe an unreleased developer-preview candidate. They do not
claim a published version, tag, or release date, and none of the checks below
prove that a particular Mac is reachable from the public internet.

### Added

- Cloudflare Dynamic DNS support that discovers accessible zones and creates or
  updates A and AAAA records for the selected hostname.
- Separate proxy policies for Cloudflare requests and public-address discovery:
  System, Direct, or a custom HTTP/SOCKS5 proxy.
- Independent IPv4 and IPv6 discovery, interface-aware IPv6 selection, and
  fail-closed public-address classification.
- Router mapping through PCP, NAT-PMP, and UPnP, including protocol-specific
  recovery state and IPv6-aware discovery.
- Time-limited remote access with bounded router leases, an independent
  expiration path, and cleanup after expiry or disablement.
- Keychain-backed Cloudflare token storage with explicit authorization,
  background no-UI access, exact-build preview identity, and legacy migration.
- Upgrade and rollback handling for current and legacy Gatebeam application
  identities.
- A native AppKit menu-bar interface with light and dark appearances, aligned
  settings layouts, status reporting, and network diagnostics.
- Backend, proxy-policy, integration-contract, Keychain/signing,
  upgrade/rollback, build-asset, UI-isolation, and privacy gates.
- A dedicated Thread Sanitizer (`TSan`) release gate.
- Canonical Aqua and Dark Aqua snapshots for every supported settings and
  menu-bar state, including bottom-scroll states.
- Packaging checks for DMG integrity, PKG contents, permissions, metadata, and
  atomic replacement.

### Changed

- Repository release and contribution guidance now distinguishes developer
  previews from formal, signed, notarized releases.
- A saved token is intentionally authorized for one exact preview build and may
  require explicit reauthorization after an update.

### Security

- DDNS publication is blocked when a router reports a non-public WAN address.
- Router recovery verifies the discovered device and mapping identity before
  cleanup where the protocol permits.
- Developer-preview builds use hardened runtime and strict code-signature
  validation.
- Privacy checks reject committed credentials, private hostnames, public
  addresses, and other environment-specific material.
- The app is ad-hoc signed. The installer package is unsigned.
- The app, installer package, and disk image are not notarized or stapled.
- Router interoperability varies by vendor, firmware, topology, firewall,
  carrier network, and ISP policy.
- Local TCP checks, DNS updates, router responses, and automated fixtures do not
  establish end-to-end public reachability.
- Formal distribution requires Apple Developer credentials, Developer ID
  Application and Developer ID Installer certificates, secure timestamps,
  notarization, stapling, and release-host verification.
