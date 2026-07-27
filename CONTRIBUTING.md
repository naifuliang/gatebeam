# Contributing

Thanks for improving Gatebeam.

## Before You Start

- Keep changes narrowly scoped and explain the network or security behavior they affect.
- Never commit API tokens, hostnames, public IP addresses, router exports, Keychain data, or screenshots containing private details.
- Do not add a mapping, pinhole, or DNS update that runs without the user's explicit enablement.
- Preserve the distinction between local-router protocols and internet-facing requests. PCP, NAT-PMP, and UPnP must remain direct LAN traffic.

## Development Workflow

1. Create a branch from the current default branch.
2. Make focused changes with tests appropriate to the risk.
3. Run `./scripts/test_backend.sh` and `./scripts/build_app.sh`.
4. For UI changes, capture and inspect the affected menu bar and settings states at the supported window sizes.
5. Open a pull request that describes behavior, test coverage, and any network hardware required for validation.

## Pull Request Expectations

- Add regression tests for protocol parsing, address selection, and DNS behavior where practical.
- State whether the change was tested with IPv4, IPv6, dual-stack, a VPN/tunnel, a system proxy, or a real router.
- Do not claim that a router protocol works on all hardware. Vendor implementations vary.
- Keep accessibility labels, fixed control dimensions, and alignment intact for AppKit UI changes.

## Reporting Bugs

Use GitHub Issues for reproducible non-sensitive bugs. Include the app version, macOS version, redacted diagnostics, and the affected protocol. For vulnerabilities or anything that could expose a remote desktop service, follow [SECURITY.md](SECURITY.md).
