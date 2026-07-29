# Networking And Remote Access

Gatebeam coordinates several independent checks. A green DNS or router status is useful evidence, but it is not a substitute for an external connection test.

## Before Enabling Access

1. Enable **Screen Sharing** or **Remote Management** in macOS System Settings.
2. Confirm the intended macOS account is permitted to sign in and has a strong password.
3. Confirm the configured inside port is listening locally. Gatebeam checks this, but it cannot configure macOS account access for you.
4. Keep remote access off while configuring DNS and the router path.

Screen Sharing commonly listens on TCP `5900`. Gatebeam's **Inside** port is the service on this Mac; its **Outside** port is the IPv4 port requested from the router. As a safety recommendation, use ports from `1` through `65535`, avoid `0`, and choose a high, random outside port rather than publishing the default port when your router supports it. The current preview has limited input validation: choose **Off** to disable router mapping instead of using port `0`.

## DNS Address Modes

- **IPv4** updates an `A` record using the selected public IPv4 path.
- **Dual** independently updates `A` and `AAAA` when usable addresses are available.
- **IPv6** updates an `AAAA` record only.

The IPv6 `AAAA` value comes from this Mac's stable, global IPv6 address on an eligible physical interface. Tunnel and virtual interfaces are excluded. The IPv6 public-IP probe is diagnostic only; it does not supply the value written to the `AAAA` record.

See [Cloudflare setup](cloudflare-setup.md#address-modes-and-records) before changing modes, because the current preview does not automatically delete the other family's prior record.

## Proxy Choices

Gatebeam offers two independent choices:

| Operation | Default | Choices |
| --- | --- | --- |
| Cloudflare token verification and DNS updates | System | System, Direct, Custom |
| Public IPv4 and IPv6 probe | Direct | System, Direct, Custom |

The current build stores one Custom proxy URL, shared by every operation set to Custom. A Custom URL supports `http://` or `socks5://`; it is not a credential store, so do not include a username or password.

Direct disables URLSession's HTTP, HTTPS, SOCKS, PAC, and automatic proxy discovery. It cannot force traffic around a route-level VPN/TUN, a firewall, or transparent interception. Router discovery and mapping never use an HTTP proxy.

Use a Direct public-IP probe when you want to avoid a normal system proxy returning its own exit address. If your network requires a proxy to reach Cloudflare, use System or Custom for DDNS independently. More detail is in [Proxy policy](proxy-policy.md).

## Router Mapping

Gatebeam can use these local-router mechanisms:

| Mode | Use |
| --- | --- |
| Auto | Tries supported local protocols in the app's chosen order. It is the normal first choice. |
| PCP | Requests a mapping or IPv6 firewall permission from a PCP-capable router. |
| NAT-PMP | Requests an IPv4 mapping from a NAT-PMP router. |
| UPnP | Uses compatible UPnP IGD services for IPv4 mappings and, where available, IPv6 firewall pinholes. |

Not every router supports every protocol, and a router can reject a request even when discovery works. IPv6 usually uses a firewall pinhole rather than address translation, so its reachable port can differ from the IPv4 outside port.

**Lease** is the requested lifetime for a finite router rule. As a safety recommendation, use `60` through `86400` seconds; `3600` seconds is the default. The current preview has limited field validation, so review the saved value rather than assuming the UI enforced that range. Leave automatic renewal on only while continued remote access is intended. Gatebeam records the router-reported lifetime and attempts renewal during a subsequent check. In current preview builds, a lease shorter than the check interval can expire first; use a lease comfortably longer than the interval. Check status after sleep, network changes, or router restarts.

## Reachability Boundaries

Port mapping cannot create a public IPv4 route when the router's WAN address is private or carrier-grade NAT. Common causes of failure are:

- **CGNAT:** the ISP, not your router, owns the public IPv4 address. Ask the ISP for a public IPv4 service, use IPv6 if appropriate, or choose a private overlay solution.
- **Double NAT:** another router or gateway is in front of the router Gatebeam controls. Bridge the upstream device, forward through both devices, or put the downstream router in the appropriate passthrough mode.
- **Firewall or ISP filtering:** inbound ports may be blocked even with a correct rule.
- **VPN/TUN routing:** Direct mode cannot override where the operating system routes packets.
- **Hairpin NAT:** a LAN-to-public-name test can fail even though an outside client works, or pass in a way that does not represent an external path.

Test with a separately controlled external network. Do not test by sharing the Mac's own internet connection.

## Closing, Uninstalling, And Rolling Back

1. Turn off remote access in Gatebeam.
2. Wait for the router status to confirm mapping removal. If removal fails, leave the app installed and retry from the same network; Gatebeam retains tracked mappings for recovery instead of claiming access is closed.
3. In Cloudflare, remove DNS records that should no longer point to this connection, especially stale `A` or `AAAA` records from a mode change.
4. Remove the saved token through the explicit token removal control when present, then revoke it in Cloudflare.
5. Only then uninstall or replace the app.

For a rollback, first close mappings with the currently installed version. A previous preview build can have different Keychain signing identity or token controls; it may need an explicit authorization action before it can read a token saved by another build. Do not assume a rollback removes a mapping it did not create or cannot authenticate to remove.

## Troubleshooting

| Status or symptom | What it means | Next step |
| --- | --- | --- |
| Token verified, but DNS update is denied | The token can read zones but cannot edit the selected record. | Add `Zone / DNS / Edit` for the chosen zone, then run an update again. |
| No domains load | The token is inactive, not scoped to a readable zone, or the selected network path cannot reach Cloudflare. | Check token status and zone resources; try the DDNS System, Direct, or Custom path appropriate for the network. |
| `A` works but `AAAA` is absent | No eligible stable global IPv6 was found, or IPv6 update failed. | Check physical-interface IPv6, router/ISP IPv6 policy, and Cloudflare's `AAAA` record. |
| Old `A` or `AAAA` remains after mode change | Current preview does not delete the other family automatically. | Inspect the DNS record set in Cloudflare and deliberately remove the inactive family. |
| Router protocol unavailable | The gateway may not support the selected protocol or may be on another network path. | Start with Auto; otherwise enable PCP, NAT-PMP, or UPnP in the router if you understand the security impact. |
| Mapping succeeds but outside connection fails | Mapping does not prove an end-to-end public route. | Check CGNAT, double NAT, ISP filtering, firewall rules, and test from an actual external network. |
| Remote desktop port is closed | macOS is not listening on the configured inside port. | Enable Screen Sharing or Remote Management, verify account access, and recheck the port. |
| Keychain authorization appears | An explicit token authorization, replacement, or removal needs macOS approval. | Review the prompt, allow only Gatebeam when expected, and avoid repeatedly retrying a denied prompt. |
| Saved token seems unavailable after an update | A preview build's Keychain access can be tied to its signing identity. | Open Settings and use the explicit authorization action in the current build. |
