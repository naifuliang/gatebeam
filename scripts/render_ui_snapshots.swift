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

        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
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
                        keychain: KeychainStore.isolatedValidationStore(
                            service: "io.github.naifuliang.gatebeam.snapshot-validation"
                        ),
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
                    validatePopoverLayout(
                        popover.view,
                        scenarioName: scenario.name,
                        themeName: theme.name
                    )
                    rendered.append((popoverURL, popoverSize))

                    let settings = SettingsWindowController(agent: agent, autoLoadCloudflare: false)
                    settings.update(
                        config: scenario.config,
                        tokenState: scenario.config.dnsProvider == .cloudflare
                            ? .available("****************")
                            : .missing
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

                        if scenario.name == "ready" {
                            let compactSize = NSSize(width: 880, height: 620)
                            let bottomURL = outputDir.appendingPathComponent("\(theme.name)-settings-ready-bottom.png")
                            prepareBottomScrolledSettings(
                                contentView,
                                size: compactSize,
                                themeName: theme.name
                            )
                            render(view: contentView, size: compactSize, to: bottomURL)
                            rendered.append((bottomURL, compactSize))
                        }
                    }
                }
            }
        }

        validateRuntimeAppearanceSwitch(
            root: root,
            scenario: scenarios[0]
        )
        try createCompatibilityCopies(in: outputDir)
        try createDocumentationCopies(
            from: outputDir,
            to: root.appendingPathComponent("docs/screenshots", isDirectory: true)
        )

        print("Rendered UI snapshots:")
        for (url, size) in rendered {
            print("\(url.path) \(Int(size.width))x\(Int(size.height))")
        }
    }

    private static func makeScenarios() -> [SnapshotScenario] {
        let snapshotDate = Date(timeIntervalSince1970: 1_719_849_600)
        let readyConfig = makeBaseConfig()
        let readyStatus = AppStatus(
            ddnsStatus: .ok("remote.example.com -> 203.0.113.42"),
            routerStatus: .ok("Mapped TCP 45900 -> 5900", detail: "Protocol: NAT-PMP"),
            remoteDesktopStatus: .ok("Screen Sharing is listening", detail: "127.0.0.1:5900"),
            externalReachabilityStatus: .warning(
                "Local-origin TCP check not configured",
                detail: "Add a target host to test from this Mac. Internet reachability is not verified."
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
            lastCheckedAt: snapshotDate
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
            lastCheckedAt: snapshotDate
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
                "Local-origin TCP connection failed",
                detail: "This Mac could not connect to the target. Internet reachability was not tested."
            ),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            externalPort: 45900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            lastCheckedAt: snapshotDate
        )

        var longIPv6Config = makeBaseConfig()
        longIPv6Config.preferredAddressFamily = .dualStack
        let longIPv6 = "2001:db8:1234:5678:90ab:cdef:1234:5678"
        let longIPv6Status = AppStatus(
            ddnsStatus: .ok("a-very-long-remote-hostname.example.com is current"),
            routerStatus: .ok("IPv4 mapping and IPv6 pinhole are active"),
            remoteDesktopStatus: .ok("Screen Sharing is listening"),
            externalReachabilityStatus: .ok(
                "Local-origin TCP connection succeeded",
                detail: "Connected from this Mac. This does not verify internet reachability."
            ),
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
            lastCheckedAt: snapshotDate
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
                "Local-origin TCP connection was partially successful",
                detail: "At least one local path failed. Internet reachability was not tested."
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
            lastCheckedAt: snapshotDate
        )

        var invalidCustomProxyConfig = makeBaseConfig()
        invalidCustomProxyConfig.ddnsProxyMode = .custom
        invalidCustomProxyConfig.publicIPProxyMode = .direct
        invalidCustomProxyConfig.customProxyURL = "https://proxy.example.net:443/unsupported"
        let invalidCustomProxyStatus = AppStatus(
            ddnsStatus: .warning("Custom proxy needs attention"),
            routerStatus: .ok("Local router traffic stays direct"),
            remoteDesktopStatus: .ok("Screen Sharing is listening"),
            externalReachabilityStatus: .disabled("Local-origin TCP check not configured"),
            publicAddress: "203.0.113.42",
            localAddress: "192.168.1.24",
            gatewayAddress: "192.168.1.1",
            externalPort: 45900,
            connectionURL: "vnc://203.0.113.42:45900",
            connectionURLIPv4: "vnc://203.0.113.42:45900",
            lastCheckedAt: snapshotDate
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

    private static func createDocumentationCopies(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let copies = [
            ("aqua-popover-ready.png", "popover.png"),
            ("aqua-settings-ready.png", "settings.png")
        ]

        for (sourceName, destinationName) in copies {
            let source = sourceDirectory.appendingPathComponent(sourceName)
            let destination = destinationDirectory.appendingPathComponent(destinationName)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        }
    }

    private static func render(view: NSView, size: NSSize, to url: URL) {
        let data = renderedPNGData(view: view, size: size)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            fatalError("Could not write \(url.path): \(error)")
        }
    }

    private static func renderedPNGData(view: NSView, size: NSSize) -> Data {
        view.frame = NSRect(origin: .zero, size: size)
        view.bounds = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Could not create bitmap representation")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode PNG")
        }
        return data
    }

    private static func validateRuntimeAppearanceSwitch(
        root: URL,
        scenario: SnapshotScenario
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let aqua = NSAppearance(named: .aqua),
              let dark = NSAppearance(named: .darkAqua) else {
            fatalError("Could not create runtime appearance fixtures")
        }
        let outputDirectory = root.appendingPathComponent(
            "build/ui-appearance-switch",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: outputDirectory)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("Could not create appearance-switch output: \(error)")
        }

        let agent = NetworkAgent(
            configStore: AppConfigStore(),
            keychain: KeychainStore.isolatedValidationStore(
                service: "io.github.naifuliang.gatebeam.appearance-validation"
            ),
            initialConfig: scenario.config
        )
        let popover = StatusPopoverViewController(
            agent: agent,
            openSettings: {},
            quit: {}
        )
        popover.loadViewIfNeeded()
        popover.update(config: scenario.config)
        popover.update(status: scenario.status)

        let settings = SettingsWindowController(agent: agent, autoLoadCloudflare: false)
        settings.update(
            config: scenario.config,
            tokenState: .available("****************")
        )
        settings.setCloudflareZonesForPreview([
            CloudflareZoneSummary(
                id: "0123456789abcdef0123456789abcdef",
                name: "example.com",
                status: "active"
            )
        ])
        settings.update(status: scenario.status)
        guard let settingsView = settings.window?.contentView else {
            fatalError("Runtime appearance settings view is missing")
        }

        let popoverSize = popover.preferredContentSize
        let settingsSize = NSSize(width: 880, height: 880)
        let popoverAquaBefore = appearanceSnapshot(
            view: popover.view,
            size: popoverSize,
            appearance: aqua,
            name: "popover-aqua-before",
            outputDirectory: outputDirectory,
            validateColors: {
                validatePopoverAppearanceColors(
                    popover.view,
                    appearance: aqua,
                    context: "popover Aqua before"
                )
            }
        )
        let popoverDark = appearanceSnapshot(
            view: popover.view,
            size: popoverSize,
            appearance: dark,
            name: "popover-dark",
            outputDirectory: outputDirectory,
            validateColors: {
                validatePopoverAppearanceColors(
                    popover.view,
                    appearance: dark,
                    context: "popover Dark"
                )
            }
        )
        let popoverAquaAfter = appearanceSnapshot(
            view: popover.view,
            size: popoverSize,
            appearance: aqua,
            name: "popover-aqua-after",
            outputDirectory: outputDirectory,
            validateColors: {
                validatePopoverAppearanceColors(
                    popover.view,
                    appearance: aqua,
                    context: "popover Aqua after"
                )
            }
        )

        let settingsAquaBefore = appearanceSnapshot(
            view: settingsView,
            size: settingsSize,
            appearance: aqua,
            name: "settings-aqua-before",
            outputDirectory: outputDirectory,
            validateColors: {
                validateSettingsAppearanceColors(
                    settingsView,
                    appearance: aqua,
                    context: "settings Aqua before"
                )
            }
        )
        let settingsDark = appearanceSnapshot(
            view: settingsView,
            size: settingsSize,
            appearance: dark,
            name: "settings-dark",
            outputDirectory: outputDirectory,
            validateColors: {
                validateSettingsAppearanceColors(
                    settingsView,
                    appearance: dark,
                    context: "settings Dark"
                )
            }
        )
        let settingsAquaAfter = appearanceSnapshot(
            view: settingsView,
            size: settingsSize,
            appearance: aqua,
            name: "settings-aqua-after",
            outputDirectory: outputDirectory,
            validateColors: {
                validateSettingsAppearanceColors(
                    settingsView,
                    appearance: aqua,
                    context: "settings Aqua after"
                )
            }
        )

        assertAppearancePixels(
            aquaBefore: popoverAquaBefore,
            dark: popoverDark,
            aquaAfter: popoverAquaAfter,
            context: "popover"
        )
        assertAppearancePixels(
            aquaBefore: settingsAquaBefore,
            dark: settingsDark,
            aquaAfter: settingsAquaAfter,
            context: "settings"
        )
        settings.close()
    }

    private static func appearanceSnapshot(
        view: NSView,
        size: NSSize,
        appearance: NSAppearance,
        name: String,
        outputDirectory: URL,
        validateColors: () -> Void
    ) -> Data {
        NSApp.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            view.appearance = appearance
            // Offscreen validation has no window to deliver AppKit's normal callback.
            // Invoke the same root-view hook that a live appearance change dispatches.
            view.viewDidChangeEffectiveAppearance()
            view.layoutSubtreeIfNeeded()
            validateColors()
        }
        let data = renderedPNGData(view: view, size: size)
        do {
            try data.write(
                to: outputDirectory.appendingPathComponent("\(name).png"),
                options: [.atomic]
            )
        } catch {
            fatalError("Could not write \(name) appearance screenshot: \(error)")
        }
        return decodedPixelData(from: data, context: name)
    }

    private static func decodedPixelData(from png: Data, context: String) -> Data {
        guard let rep = NSBitmapImageRep(data: png),
              let bitmap = rep.bitmapData else {
            fatalError("\(context): could not decode screenshot pixels")
        }
        return Data(
            bytes: bitmap,
            count: rep.bytesPerRow * rep.pixelsHigh
        )
    }

    private static func assertAppearancePixels(
        aquaBefore: Data,
        dark: Data,
        aquaAfter: Data,
        context: String
    ) {
        guard aquaBefore != dark else {
            fatalError("\(context): Aqua and Dark screenshots have identical pixels")
        }
        guard aquaBefore == aquaAfter else {
            fatalError("\(context): Aqua pixels were not restored after Dark → Aqua")
        }
    }

    private static func validatePopoverAppearanceColors(
        _ root: NSView,
        appearance: NSAppearance,
        context: String
    ) {
        let views = descendants(of: root)
        guard let hero = view(identifiedBy: "hero-card", in: views),
              let address = view(
                  identifiedBy: "connection-address-container",
                  in: views
              ),
              let pill = view(identifiedBy: "status-pill", in: views),
              let statusDot = view(identifiedBy: "status-dot-ddns", in: views) else {
            fatalError("\(context): required popover appearance views are missing")
        }
        for target in [hero, address, pill, statusDot] {
            assertEffectiveAppearance(target, equals: appearance, context: context)
        }
        assertLayerColor(
            hero.layer?.backgroundColor,
            equals: resolvedColor(.controlBackgroundColor, for: hero),
            context: "\(context) hero background"
        )
        assertLayerColor(
            hero.layer?.borderColor,
            equals: resolvedColor(
                .separatorColor.withAlphaComponent(0.45),
                for: hero
            ),
            context: "\(context) hero border"
        )
        assertLayerColor(
            address.layer?.backgroundColor,
            equals: resolvedColor(.textBackgroundColor, for: address),
            context: "\(context) address background"
        )
        assertLayerColor(
            pill.layer?.backgroundColor,
            equals: resolvedColor(
                .systemGreen.withAlphaComponent(0.14),
                for: pill
            ),
            context: "\(context) status pill"
        )
        assertLayerColor(
            statusDot.layer?.backgroundColor,
            equals: resolvedColor(.systemGreen, for: statusDot),
            context: "\(context) DDNS status dot"
        )
    }

    private static func validateSettingsAppearanceColors(
        _ root: NSView,
        appearance: NSAppearance,
        context: String
    ) {
        let views = descendants(of: root)
        guard let panel = view(
                  identifiedBy: "settings-panel-access-&-health",
                  in: views
              ),
              let footer = view(identifiedBy: "settings-footer", in: views),
              let statusDot = view(
                  identifiedBy: "settings-status-dot-ddns",
                  in: views
              ) else {
            fatalError("\(context): required settings appearance views are missing")
        }
        for target in [root, panel, footer, statusDot] {
            assertEffectiveAppearance(target, equals: appearance, context: context)
        }
        assertLayerColor(
            root.layer?.backgroundColor,
            equals: resolvedColor(.windowBackgroundColor, for: root),
            context: "\(context) root background"
        )
        assertLayerColor(
            footer.layer?.backgroundColor,
            equals: resolvedColor(.windowBackgroundColor, for: footer),
            context: "\(context) footer background"
        )
        assertLayerColor(
            panel.layer?.backgroundColor,
            equals: resolvedColor(.controlBackgroundColor, for: panel),
            context: "\(context) panel background"
        )
        assertLayerColor(
            panel.layer?.borderColor,
            equals: resolvedColor(
                .separatorColor.withAlphaComponent(0.25),
                for: panel
            ),
            context: "\(context) panel border"
        )
        assertLayerColor(
            statusDot.layer?.backgroundColor,
            equals: resolvedColor(.systemGreen, for: statusDot),
            context: "\(context) DDNS status dot"
        )
    }

    private static func resolvedColor(_ color: NSColor, for view: NSView) -> CGColor {
        var result = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }

    private static func assertEffectiveAppearance(
        _ view: NSView,
        equals expected: NSAppearance,
        context: String
    ) {
        let candidates: [NSAppearance.Name] = [.aqua, .darkAqua]
        guard view.effectiveAppearance.bestMatch(from: candidates)
            == expected.bestMatch(from: candidates) else {
            fatalError("\(context): effective appearance did not propagate to \(view)")
        }
    }

    private static func assertLayerColor(
        _ actual: CGColor?,
        equals expected: CGColor,
        context: String
    ) {
        guard let actual,
              let actualColor = NSColor(cgColor: actual)?.usingColorSpace(.deviceRGB),
              let expectedColor = NSColor(cgColor: expected)?.usingColorSpace(.deviceRGB) else {
            fatalError("\(context): layer color is unavailable")
        }
        let delta = max(
            abs(actualColor.redComponent - expectedColor.redComponent),
            abs(actualColor.greenComponent - expectedColor.greenComponent),
            abs(actualColor.blueComponent - expectedColor.blueComponent),
            abs(actualColor.alphaComponent - expectedColor.alphaComponent)
        )
        guard delta < 0.003 else {
            fatalError(
                "\(context): layer color \(actualColor) does not match \(expectedColor)"
            )
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

        if scenarioName == "off" {
            guard let connection = view(
                      identifiedBy: "settings-connection-url",
                      in: views
                  ) as? NSTextField,
                  let copyButton = view(
                      identifiedBy: "settings-copy-url",
                      in: views
                  ) as? NSButton else {
                fatalError("\(context): settings off-state connection controls are missing")
            }
            guard connection.stringValue == RemoteConnectionURLPolicy.unavailableText,
                  !connection.stringValue.contains("vnc://"),
                  !copyButton.isEnabled else {
                fatalError("\(context): settings must hide stale VNC data and disable copy while access is off")
            }
        }

        if scenarioName == "invalid-custom-proxy" {
            guard let errorLabel = textField(containing: [
                "Use http://host:port or socks5://host:port."
            ], in: views), !errorLabel.isHidden else {
                fatalError("\(context): invalid proxy error is not visible")
            }
            assertFullyVisible(
                errorLabel,
                inside: scrollView.contentView,
                context: "\(context) proxy error"
            )
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

    private static func validatePopoverLayout(
        _ contentView: NSView,
        scenarioName: String,
        themeName: String
    ) {
        let context = "\(themeName) popover \(scenarioName)"
        let views = descendants(of: contentView)
        guard let heroCard = view(identifiedBy: "hero-card", in: views),
              let heroHeadline = view(identifiedBy: "hero-headline", in: views) as? NSTextField,
              let heroDetail = view(identifiedBy: "hero-detail", in: views) as? NSTextField,
              let addressContainer = view(
                  identifiedBy: "connection-address-container",
                  in: views
              ),
              let primaryRow = view(identifiedBy: "primary-connection-row", in: views),
              let primaryURL = view(identifiedBy: "primary-connection-url", in: views),
              let primaryCopy = view(
                  identifiedBy: "copy-primary-connection-url",
                  in: views
              ),
              let secondaryRow = view(
                  identifiedBy: "secondary-connection-row",
                  in: views
              ),
              let secondaryURL = view(
                  identifiedBy: "secondary-connection-url",
                  in: views
              ),
              let secondaryCopy = view(
                  identifiedBy: "copy-secondary-connection-url",
                  in: views
              ),
              let healthGrid = view(
                  identifiedBy: "connection-health-grid",
                  in: views
              ) else {
            fatalError("\(context): required connection layout views are missing")
        }

        let heroRect = heroCard.convert(heroCard.bounds, to: contentView)
        guard abs(heroRect.minX - 18) < 0.75,
              abs(contentView.bounds.maxX - heroRect.maxX - 18) < 0.75 else {
            fatalError("\(context): hero card does not preserve the 18-point outer inset")
        }
        assertTextDrawingContained(
            heroHeadline,
            inside: heroCard,
            minimumHorizontalInset: 13,
            context: "\(context) hero headline"
        )
        assertTextDrawingContained(
            heroDetail,
            inside: heroCard,
            minimumHorizontalInset: 13,
            context: "\(context) hero subtitle"
        )
        let heroDetailRect = textDrawingRect(for: heroDetail, in: contentView)
        guard heroDetailRect.minX >= 31 else {
            fatalError(
                "\(context): hero subtitle begins at x=\(heroDetailRect.minX), "
                + "below the required card-relative content inset"
            )
        }

        assertFullyVisible(
            addressContainer,
            inside: contentView,
            context: "\(context) address container"
        )
        assertFullyVisible(primaryRow, inside: addressContainer, context: "\(context) primary row")
        assertFullyVisible(primaryURL, inside: addressContainer, context: "\(context) primary URL")
        assertFullyVisible(primaryCopy, inside: addressContainer, context: "\(context) primary copy")
        assertNoOverlap(primaryURL, primaryCopy, in: addressContainer, context: "\(context) primary URL")

        let expectedHeight: CGFloat = secondaryRow.isHidden ? 36 : 64
        guard abs(addressContainer.frame.height - expectedHeight) < 0.5 else {
            fatalError(
                "\(context): address container height \(addressContainer.frame.height) "
                + "does not match stable \(expectedHeight)-point layout"
            )
        }

        if !secondaryRow.isHidden {
            assertFullyVisible(
                secondaryRow,
                inside: addressContainer,
                context: "\(context) secondary row"
            )
            assertFullyVisible(
                secondaryURL,
                inside: addressContainer,
                context: "\(context) secondary URL"
            )
            assertFullyVisible(
                secondaryCopy,
                inside: addressContainer,
                context: "\(context) secondary copy"
            )
            assertNoOverlap(
                secondaryURL,
                secondaryCopy,
                in: addressContainer,
                context: "\(context) secondary URL"
            )
        }

        let addressRect = addressContainer.convert(addressContainer.bounds, to: contentView)
        let healthRect = healthGrid.convert(healthGrid.bounds, to: contentView)
        guard !addressRect.intersects(healthRect) else {
            fatalError("\(context): address container overlaps the following health card")
        }

        let tileMessages = views.compactMap { $0 as? NSTextField }.filter {
            $0.identifier?.rawValue.hasPrefix("status-message-") == true
        }
        guard tileMessages.count == 4 else {
            fatalError("\(context): expected four identified status messages")
        }
        for message in tileMessages {
            guard let tile = ancestor(
                of: message,
                identifiedByPrefix: "status-tile-"
            ) else {
                fatalError("\(context): status message has no identified tile")
            }
            assertTextDrawingContained(
                message,
                inside: tile,
                minimumHorizontalInset: 8,
                context: "\(context) \(message.identifier?.rawValue ?? "status message")"
            )
        }

        if scenarioName == "off" {
            guard let primaryLabel = primaryURL as? NSTextField,
                  let primaryButton = primaryCopy as? NSButton,
                  primaryLabel.stringValue == RemoteConnectionURLPolicy.unavailableText,
                  !primaryLabel.stringValue.contains("vnc://"),
                  !primaryButton.isEnabled,
                  secondaryRow.isHidden else {
                fatalError("\(context): popover must hide stale VNC data and disable copy while access is off")
            }
        }

        if scenarioName == "long-ipv6" {
            guard let label = secondaryURL as? NSTextField,
                  label.lineBreakMode == .byTruncatingMiddle,
                  label.intrinsicContentSize.width > label.frame.width else {
                fatalError("\(context): long IPv6 URL is not constrained to middle truncation")
            }
        }
    }

    private static func prepareBottomScrolledSettings(
        _ contentView: NSView,
        size: NSSize,
        themeName: String
    ) {
        contentView.frame = NSRect(origin: .zero, size: size)
        contentView.bounds = NSRect(origin: .zero, size: size)
        contentView.layoutSubtreeIfNeeded()

        let views = descendants(of: contentView)
        guard let scrollView = views.compactMap({ $0 as? NSScrollView }).first,
              let documentView = scrollView.documentView,
              let bottomLabel = textField(containing: [
                  "Direct bypasses macOS HTTP, SOCKS, PAC, and automatic proxy discovery"
              ], in: views),
              let saveButton = views.compactMap({ $0 as? NSButton }).first(where: {
                  $0.title == "Save Changes"
              }) else {
            fatalError("\(themeName) bottom scroll: required settings controls are missing")
        }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let bottomOriginY = documentView.isFlipped
            ? max(documentView.bounds.minY, documentView.bounds.maxY - clipView.bounds.height)
            : documentView.bounds.minY
        documentView.scroll(NSPoint(x: documentView.bounds.minX, y: bottomOriginY))
        scrollView.reflectScrolledClipView(clipView)

        let visibleDocumentRect = documentView.visibleRect
        let reachedBottom = documentView.isFlipped
            ? visibleDocumentRect.maxY >= documentView.bounds.maxY - 1
            : visibleDocumentRect.minY <= documentView.bounds.minY + 1
        guard reachedBottom else {
            fatalError(
                "\(themeName) bottom scroll: document did not reach its bottom edge "
                + "(flipped=\(documentView.isFlipped), frame=\(documentView.frame), "
                + "bounds=\(documentView.bounds), clip=\(clipView.bounds), visible=\(visibleDocumentRect))"
            )
        }

        assertFullyVisible(
            bottomLabel,
            inside: clipView,
            context: "\(themeName) bottom scroll final routing guidance"
        )
        assertFullyVisible(
            saveButton,
            inside: contentView,
            context: "\(themeName) bottom scroll fixed footer"
        )

        let bottomLabelRect = bottomLabel.convert(bottomLabel.bounds, to: contentView)
        let saveButtonRect = saveButton.convert(saveButton.bounds, to: contentView)
        guard !bottomLabelRect.intersects(saveButtonRect) else {
            fatalError("\(themeName) bottom scroll: content is obscured by the fixed footer")
        }
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func textField(containing candidates: [String], in views: [NSView]) -> NSTextField? {
        views.compactMap { $0 as? NSTextField }.first { field in
            candidates.contains { field.stringValue.contains($0) }
        }
    }

    private static func view(identifiedBy identifier: String, in views: [NSView]) -> NSView? {
        let target = NSUserInterfaceItemIdentifier(identifier)
        return views.first { $0.identifier == target }
    }

    private static func ancestor(
        of view: NSView,
        identifiedByPrefix prefix: String
    ) -> NSView? {
        var candidate = view.superview
        while let current = candidate {
            if current.identifier?.rawValue.hasPrefix(prefix) == true {
                return current
            }
            candidate = current.superview
        }
        return nil
    }

    private static func textDrawingRect(
        for field: NSTextField,
        in container: NSView
    ) -> NSRect {
        let drawingBounds = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        let storage = NSTextStorage(attributedString: field.attributedStringValue)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: drawingBounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = max(1, field.maximumNumberOfLines)
        textContainer.lineBreakMode = field.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer).offsetBy(
            dx: drawingBounds.minX,
            dy: drawingBounds.minY
        )
        return field.convert(usedRect, to: container)
    }

    private static func assertTextDrawingContained(
        _ field: NSTextField,
        inside container: NSView,
        minimumHorizontalInset: CGFloat,
        context: String
    ) {
        let rect = textDrawingRect(for: field, in: container)
        let outerBounds = container.bounds.insetBy(dx: -0.75, dy: -0.75)
        guard rect.width > 0,
              rect.height > 0,
              outerBounds.contains(rect) else {
            fatalError("\(context) actual text bounds \(rect) leave container \(container.bounds)")
        }
        guard rect.minX >= minimumHorizontalInset - 0.75,
              rect.maxX <= container.bounds.maxX - minimumHorizontalInset + 0.75 else {
            fatalError(
                "\(context) actual text bounds \(rect) do not preserve "
                + "the \(minimumHorizontalInset)-point horizontal content inset"
            )
        }
    }

    private static func assertNoOverlap(
        _ leadingView: NSView,
        _ trailingView: NSView,
        in container: NSView,
        context: String
    ) {
        let leadingRect = leadingView.convert(leadingView.bounds, to: container)
        let trailingRect = trailingView.convert(trailingView.bounds, to: container)
        guard !leadingRect.intersects(trailingRect) else {
            fatalError("\(context) overlaps its fixed copy button")
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

    private static func assertFullyVisible(_ view: NSView, inside container: NSView, context: String) {
        let rect = view.convert(view.bounds, to: container)
        guard !view.isHidden,
              rect.width > 0,
              rect.height > 0,
              container.bounds.insetBy(dx: -1, dy: -1).contains(rect) else {
            fatalError("\(context) is not fully visible")
        }
    }
}
