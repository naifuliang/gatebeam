import AppKit
import Foundation

private struct SnapshotTheme {
    let name: String
    let appearance: NSAppearance.Name
}

private struct SnapshotScenario {
    let name: String
    let config: AppConfig
    let status: AppStatus
}

@main
struct UISnapshotRenderer {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let outputDir = root.appendingPathComponent("build/ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try removeOldSnapshots(in: outputDir)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let themes = [
            SnapshotTheme(name: "aqua", appearance: .aqua),
            SnapshotTheme(name: "dark-aqua", appearance: .darkAqua)
        ]
        let scenarios = makeScenarios()
        var rendered: [(URL, NSSize)] = []

        for theme in themes {
            guard let appearance = NSAppearance(named: theme.appearance) else {
                fatalError("Could not create \(theme.name) appearance")
            }
            NSApp.appearance = appearance

            for scenario in scenarios {
                appearance.performAsCurrentDrawingAppearance {
                    let agent = NetworkAgent(
                        configStore: AppConfigStore(),
                        keychain: KeychainStore(),
                        initialConfig: scenario.config
                    )

                    let popover = StatusPopoverViewController(agent: agent, openSettings: {}, quit: {})
                    popover.loadViewIfNeeded()
                    popover.view.appearance = appearance
                    popover.update(config: scenario.config)
                    popover.update(status: scenario.status)
                    let popoverSize = popover.preferredContentSize
                    let popoverURL = outputDir.appendingPathComponent("\(theme.name)-popover-\(scenario.name).png")
                    render(view: popover.view, size: popoverSize, to: popoverURL)
                    rendered.append((popoverURL, popoverSize))

                    let settings = SettingsWindowController(agent: agent, autoLoadCloudflare: false)
                    settings.update(
                        config: scenario.config,
                        token: scenario.config.dnsProvider == .cloudflare ? "****************" : ""
                    )
                    settings.setCloudflareZonesForPreview([
                        CloudflareZoneSummary(
                            id: "0123456789abcdef0123456789abcdef",
                            name: "example.com",
                            status: "active"
                        )
                    ])
                    settings.update(status: scenario.status)
                    if let contentView = settings.window?.contentView {
                        contentView.appearance = appearance
                        let settingsSize = NSSize(width: 880, height: 880)
                        let settingsURL = outputDir.appendingPathComponent("\(theme.name)-settings-\(scenario.name).png")
                        render(view: contentView, size: settingsSize, to: settingsURL)
                        validateSettingsLayout(
                            contentView,
                            scenarioName: scenario.name,
                            themeName: theme.name
                        )
                        rendered.append((settingsURL, settingsSize))
                    }
                }
            }
        }

        try createCompatibilityCopies(in: outputDir)

        print("Rendered UI snapshots:")
        for (url, size) in rendered {
            print("\(url.path) \(Int(size.width))x\(Int(size.height))")
        }
    }

    private static func makeScenarios() -> [SnapshotScenario] {
        let readyConfig = makeBaseConfig()
        let readyStatus = AppStatus(
            ddnsStatus: .ok("remote.example.com -> 203.0.113.42"),
            routerStatus: .ok("Mapped TCP 45900 -> 5900", detail: "Protocol: NAT-PMP"),
            remoteDesktopStatus: .ok("Screen Sharing is listening", detail: "127.0.0.1:5900"),
            externalReachabilityStatus: .warning(
                "External probe is not configured",
                detail: "Add a probe host for internet-side verification."
            ),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            publicIPv6Address: "2001:db8:1234::24",
            localIPv6Address: "2001:db8:1234::24",
            gatewayIPv6Address: "fe80::1%en0",
            externalPort: 45900,
            ipv6ExternalPort: 5900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            connectionURLIPv6: "vnc://remote.example.com:5900",
            lastCheckedAt: Date()
        )

        var offConfig = makeBaseConfig()
        offConfig.remoteAccessEnabled = false
        let offStatus = AppStatus(
            ddnsStatus: .warning(
                "Cloudflare is not configured",
                detail: "Set a zone, record name, and API token."
            ),
            routerStatus: .disabled("Remote access is off"),
            remoteDesktopStatus: .failed(
                "Remote desktop port 5900 is closed",
                detail: "Enable Screen Sharing in System Settings."
            ),
            externalReachabilityStatus: .disabled("Remote access is off"),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            externalPort: 58940,
            connectionURL: "vnc://203.0.113.42:58940",
            connectionURLIPv4: "vnc://203.0.113.42:58940",
            lastCheckedAt: Date()
        )

        var errorConfig = makeBaseConfig()
        errorConfig.preferredAddressFamily = .ipv4
        let errorStatus = AppStatus(
            ddnsStatus: .failed(
                "Cloudflare rejected the DNS update because this token cannot edit the selected zone",
                detail: "Grant Zone DNS Edit and Zone Read."
            ),
            routerStatus: .failed(
                "No compatible PCP, NAT-PMP, or UPnP gateway responded before the request timed out",
                detail: "Check router discovery and firewall settings."
            ),
            remoteDesktopStatus: .failed(
                "Screen Sharing is not listening on the configured internal TCP port",
                detail: "Enable Screen Sharing in System Settings."
            ),
            externalReachabilityStatus: .failed(
                "The public endpoint did not accept a connection from the verification service",
                detail: "Review the router mapping and upstream NAT."
            ),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            externalPort: 45900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            lastCheckedAt: Date()
        )

        var longIPv6Config = makeBaseConfig()
        longIPv6Config.preferredAddressFamily = .dualStack
        let longIPv6 = "2001:db8:1234:5678:90ab:cdef:1234:5678"
        let longIPv6Status = AppStatus(
            ddnsStatus: .ok("a-very-long-remote-hostname.example.com is current"),
            routerStatus: .ok("IPv4 mapping and IPv6 pinhole are active"),
            remoteDesktopStatus: .ok("Screen Sharing is listening"),
            externalReachabilityStatus: .ok("Both address families are reachable"),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.100.248",
            gatewayAddress: "192.168.100.1",
            publicIPv6Address: longIPv6,
            localIPv6Address: longIPv6,
            gatewayIPv6Address: "fe80::a8bb:ccff:fedd:eeff%en12",
            externalPort: 45900,
            ipv6ExternalPort: 5900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            connectionURLIPv6: "vnc://[\(longIPv6)]:5900",
            lastCheckedAt: Date()
        )

        var customProxyConfig = makeBaseConfig()
        customProxyConfig.ddnsProxyMode = .custom
        customProxyConfig.publicIPProxyMode = .custom
        customProxyConfig.customProxyURL = "socks5://proxy-gateway-with-a-long-hostname.example.net:1080"
        let customProxyStatus = AppStatus(
            ddnsStatus: .ok("Cloudflare updated through the custom proxy"),
            routerStatus: .ok("UPnP used the direct local network path"),
            remoteDesktopStatus: .ok("Screen Sharing is listening"),
            externalReachabilityStatus: .warning(
                "A direct app connection can still follow a VPN or TUN route",
                detail: "Proxy policy does not override the system route table."
            ),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            publicIPv6Address: "2001:db8:1234::24",
            localIPv6Address: "2001:db8:1234::24",
            gatewayIPv6Address: "fe80::1%en0",
            externalPort: 45900,
            ipv6ExternalPort: 5900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            connectionURLIPv6: "vnc://remote.example.com:5900",
            lastCheckedAt: Date()
        )

        var invalidCustomProxyConfig = makeBaseConfig()
        invalidCustomProxyConfig.ddnsProxyMode = .custom
        invalidCustomProxyConfig.publicIPProxyMode = .direct
        invalidCustomProxyConfig.customProxyURL = "https://proxy.example.net:443/unsupported"
        let invalidCustomProxyStatus = AppStatus(
            ddnsStatus: .warning("Custom proxy needs attention"),
            routerStatus: .ok("Local router traffic stays direct"),
            remoteDesktopStatus: .ok("Screen Sharing is listening"),
            externalReachabilityStatus: .disabled("Waiting for a valid proxy configuration"),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            externalPort: 45900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            lastCheckedAt: Date()
        )

        return [
            SnapshotScenario(name: "ready", config: readyConfig, status: readyStatus),
            SnapshotScenario(name: "off", config: offConfig, status: offStatus),
            SnapshotScenario(name: "error", config: errorConfig, status: errorStatus),
            SnapshotScenario(name: "long-ipv6", config: longIPv6Config, status: longIPv6Status),
            SnapshotScenario(name: "custom-proxy", config: customProxyConfig, status: customProxyStatus),
            SnapshotScenario(name: "invalid-custom-proxy", config: invalidCustomProxyConfig, status: invalidCustomProxyStatus)
        ]
    }

    private static func makeBaseConfig() -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "0123456789abcdef0123456789abcdef"
        config.dnsRecordName = "remote.example.com"
        config.mappingProtocolPreference = .automatic
        config.preferredAddressFamily = .dualStack
        config.internalPort = 5900
        config.externalPort = 45900
        config.mappingLeaseSeconds = 3600
        config.checkIntervalSeconds = 300
        config.startAtLogin = true
        return config
    }

    private static func removeOldSnapshots(in directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension.lowercased() == "png" else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func createCompatibilityCopies(in directory: URL) throws {
        let aliases = [
            ("aqua-popover-ready.png", "popover.png"),
            ("aqua-popover-ready.png", "popover-ready.png"),
            ("aqua-settings-ready.png", "settings.png"),
            ("aqua-settings-ready.png", "settings-ready.png"),
            ("aqua-popover-off.png", "popover-off.png"),
            ("aqua-settings-off.png", "settings-off.png")
        ]

        for (sourceName, destinationName) in aliases {
            let source = directory.appendingPathComponent(sourceName)
            let destination = directory.appendingPathComponent(destinationName)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func render(view: NSView, size: NSSize, to url: URL) {
        view.frame = NSRect(origin: .zero, size: size)
        view.bounds = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Could not create bitmap representation for \(url.lastPathComponent)")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode PNG for \(url.lastPathComponent)")
        }

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            fatalError("Could not write \(url.path): \(error)")
        }
    }

    private static func validateSettingsLayout(
        _ contentView: NSView,
        scenarioName: String,
        themeName: String
    ) {
        let context = "\(themeName) \(scenarioName)"
        let views = descendants(of: contentView)
        guard let scrollView = views.compactMap({ $0 as? NSScrollView }).first,
              let documentView = scrollView.documentView else {
            fatalError("\(context): settings content is not inside a scroll view")
        }

        let cards = views.filter {
            $0.frame.width > 350 &&
            abs(($0.layer?.cornerRadius ?? 0) - 8) < 0.1 &&
            ($0.layer?.borderWidth ?? 0) > 0
        }
        guard cards.count == 4 else {
            fatalError("\(context): expected four settings cards, found \(cards.count)")
        }
        let cardWidths = cards.map(\.frame.width)
        guard let narrowest = cardWidths.min(),
              let widest = cardWidths.max(),
              widest - narrowest < 1 else {
            fatalError("\(context): settings cards are not equal width")
        }

        guard let headline = textField(containing: [
            "Remote access is off",
            "Ready for remote connection",
            "Needs attention",
            "Checking connection",
            "Settings need attention"
        ], in: views),
        let intervalHelp = textField(containing: [
            "Interval defaults to 300 seconds"
        ], in: views),
        let saveButton = views.compactMap({ $0 as? NSButton }).first(where: {
            $0.title == "Save Changes"
        }) else {
            fatalError("\(context): required settings controls are missing")
        }

        assertVisible(headline, inside: contentView, context: "\(context) headline")
        assertVisible(intervalHelp, inside: scrollView.contentView, context: "\(context) interval help")
        assertVisible(saveButton, inside: contentView, context: "\(context) save button")

        if scenarioName == "invalid-custom-proxy" {
            guard let errorLabel = textField(containing: [
                "Use http://host:port or socks5://host:port."
            ], in: views), !errorLabel.isHidden else {
                fatalError("\(context): invalid proxy error is not visible")
            }
            assertVisible(errorLabel, inside: scrollView.contentView, context: "\(context) proxy error")
        }

        let originalFrame = contentView.frame
        contentView.frame = NSRect(origin: .zero, size: NSSize(width: 880, height: 620))
        contentView.bounds = NSRect(origin: .zero, size: NSSize(width: 880, height: 620))
        contentView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        assertVisible(headline, inside: contentView, context: "\(context) compact headline")
        assertVisible(saveButton, inside: contentView, context: "\(context) compact save button")
        guard documentView.frame.height > scrollView.contentView.bounds.height else {
            fatalError("\(context): compact settings content does not expose a vertical scroll range")
        }

        contentView.frame = originalFrame
        contentView.bounds = NSRect(origin: .zero, size: originalFrame.size)
        contentView.layoutSubtreeIfNeeded()
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func textField(containing candidates: [String], in views: [NSView]) -> NSTextField? {
        views.compactMap { $0 as? NSTextField }.first { field in
            candidates.contains { field.stringValue.contains($0) }
        }
    }

    private static func assertVisible(_ view: NSView, inside container: NSView, context: String) {
        let rect = view.convert(view.bounds, to: container)
        guard !view.isHidden,
              rect.width > 0,
              rect.height > 0,
              container.bounds.intersects(rect) else {
            fatalError("\(context) is clipped or hidden")
        }
    }
}
