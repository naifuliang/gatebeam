import AppKit
import Foundation

private enum PopoverLayout {
    static let width: CGFloat = 430
    static let contentWidth: CGFloat = 394
    static let heroContentWidth: CGFloat = 362
    static let tileWidth: CGFloat = 192
    static let tileHeight: CGFloat = 72
    static let connectionRowHeight: CGFloat = 28
    static let singleConnectionHeight: CGFloat = 36
    static let dualConnectionHeight: CGFloat = 64
    static let singleURLHeight: CGFloat = 544
    static let dualURLHeight: CGFloat = 572
}

final class StatusPopoverViewController: NSViewController {
    private let agent: NetworkAgent
    private let openSettingsHandler: () -> Void
    private let quitHandler: () -> Void

    private let statusPill = PillLabel()
    private let headlineLabel = NSTextField(labelWithString: "Remote access is off")
    private let detailLabel = NSTextField(labelWithString: "Turn it on when you need this Mac reachable from outside your network.")
    private let connectionLabel = NSTextField(labelWithString: "No connection URL yet")
    private let connectionFamilyLabel = NSTextField(labelWithString: "URL")
    private let secondaryConnectionLabel = NSTextField(labelWithString: "")
    private let secondaryConnectionFamilyLabel = NSTextField(labelWithString: "IPv6")
    private let secondaryConnectionRow = NSStackView()
    private var connectionCardHeightConstraint: NSLayoutConstraint?
    private weak var primaryCopyButton: NSButton?
    private weak var secondaryCopyButton: NSButton?
    private let lastCheckedLabel = NSTextField(labelWithString: "Not checked yet")
    private let accessSwitch = NSSwitch()
    private let accessStateLabel = NSTextField(labelWithString: "Off")

    private let ddnsTile = StatusTile(title: "DDNS", symbol: "globe")
    private let routerTile = StatusTile(title: "Router", symbol: "point.3.connected.trianglepath.dotted")
    private let desktopTile = StatusTile(title: "Desktop", symbol: "display")
    private let reachabilityTile = StatusTile(title: "Local TCP", symbol: "antenna.radiowaves.left.and.right")

    private let publicIPLabel = ValueLabel(title: "Public IP")
    private let localIPLabel = ValueLabel(title: "Local IP")
    private let gatewayLabel = ValueLabel(title: "Gateway")
    private let portLabel = ValueLabel(title: "IPv4 Port")
    private let publicIPv6Label = ValueLabel(title: "Public IPv6")
    private let localIPv6Label = ValueLabel(title: "Local IPv6")
    private let gatewayIPv6Label = ValueLabel(title: "IPv6 Gateway")
    private let ipv6PortLabel = ValueLabel(title: "IPv6 Port")
    private let ddnsProxyRoute = ProxyRouteView(title: "DDNS path", symbol: "globe")
    private let publicIPProxyRoute = ProxyRouteView(title: "IP probe", symbol: "location.magnifyingglass")
    private var remoteAccessEnabled = false
    private var latestStatus = AppStatus.initial

    init(agent: NetworkAgent, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.agent = agent
        self.openSettingsHandler = openSettings
        self.quitHandler = quit
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: PopoverLayout.width, height: PopoverLayout.singleURLHeight)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let effect = PopoverAppearanceTrackingView()
        effect.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshAppearance()
        }
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        view = effect

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 13, left: 18, bottom: 11, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        root.addArrangedSubview(makeHeader())
        root.addArrangedSubview(makeHeroCard())
        root.addArrangedSubview(makeHealthGrid())
        root.addArrangedSubview(makeNetworkCard())
        root.addArrangedSubview(makeFooter())

        update(config: agent.config)
        update(status: agent.status)
        refreshAppearance()
    }

    func update(config: AppConfig) {
        remoteAccessEnabled = config.remoteAccessEnabled
        accessSwitch.state = config.remoteAccessEnabled ? .on : .off
        accessStateLabel.stringValue = config.remoteAccessEnabled ? "On" : "Off"
        ddnsProxyRoute.update(proxyPresentation(for: config.ddnsProxyMode, customURL: config.customProxyURL))
        publicIPProxyRoute.update(proxyPresentation(for: config.publicIPProxyMode, customURL: config.customProxyURL))
        renderHero(latestStatus)
        refreshConnectionPresentation(latestStatus)
    }

    func update(status: AppStatus) {
        latestStatus = status
        renderHero(status)
        refreshConnectionPresentation(status)
        lastCheckedLabel.stringValue = status.lastCheckedAt.map { "Checked \(DateFormatter.popoverTime.string(from: $0))" } ?? "Not checked yet"

        ddnsTile.update(status.ddnsStatus)
        routerTile.update(status.routerStatus)
        desktopTile.update(status.remoteDesktopStatus)
        reachabilityTile.update(status.externalReachabilityStatus)

        publicIPLabel.value = status.publicAddress ?? "-"
        localIPLabel.value = status.localAddress ?? "-"
        gatewayLabel.value = status.gatewayAddress ?? "-"
        publicIPv6Label.value = status.publicIPv6Address ?? "-"
        localIPv6Label.value = status.localIPv6Address ?? "-"
        gatewayIPv6Label.value = status.gatewayIPv6Address ?? "-"
        if let port = status.externalPort {
            portLabel.value = String(port)
        } else {
            portLabel.value = "-"
        }
        ipv6PortLabel.value = status.ipv6ExternalPort.map(String.init) ?? "-"
    }

    private func makeHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let icon = SymbolBadgeView(symbol: "cursorarrow")
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 1
        let title = NSTextField(labelWithString: "Gatebeam")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Network access")
        subtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(title)
        titleStack.addArrangedSubview(subtitle)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let settingsButton = iconOnlyButton(
            symbol: "gearshape",
            toolTip: "Open settings",
            action: #selector(openSettings)
        )
        let quitButton = iconOnlyButton(
            symbol: "power",
            toolTip: "Quit Gatebeam",
            action: #selector(quit)
        )

        row.addArrangedSubview(icon)
        row.addArrangedSubview(titleStack)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(statusPill)
        row.addArrangedSubview(settingsButton)
        row.addArrangedSubview(quitButton)
        row.widthAnchor.constraint(equalToConstant: PopoverLayout.contentWidth).isActive = true
        return row
    }

    private func makeHeroCard() -> NSView {
        let card = CardView()
        card.identifier = NSUserInterfaceItemIdentifier("hero-card")
        card.widthAnchor.constraint(equalToConstant: PopoverLayout.contentWidth).isActive = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 12

        let text = NSStackView()
        text.orientation = .vertical
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headlineLabel.identifier = NSUserInterfaceItemIdentifier("hero-headline")
        headlineLabel.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        headlineLabel.maximumNumberOfLines = 1
        headlineLabel.usesSingleLineMode = true
        headlineLabel.lineBreakMode = .byTruncatingTail
        detailLabel.identifier = NSUserInterfaceItemIdentifier("hero-detail")
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1
        detailLabel.usesSingleLineMode = true
        detailLabel.lineBreakMode = .byTruncatingTail
        text.addArrangedSubview(headlineLabel)
        text.addArrangedSubview(detailLabel)

        accessSwitch.target = self
        accessSwitch.action = #selector(toggleAccess)
        accessStateLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        accessStateLabel.textColor = .secondaryLabelColor

        let switchStack = NSStackView()
        switchStack.orientation = .vertical
        switchStack.alignment = .centerX
        switchStack.spacing = 4
        switchStack.setContentHuggingPriority(.required, for: .horizontal)
        switchStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        switchStack.addArrangedSubview(accessSwitch)
        switchStack.addArrangedSubview(accessStateLabel)

        top.addArrangedSubview(text)
        top.addArrangedSubview(switchStack)
        top.widthAnchor.constraint(equalToConstant: PopoverLayout.heroContentWidth).isActive = true
        stack.addArrangedSubview(top)

        let urlCard = RoundedFieldView()
        urlCard.identifier = NSUserInterfaceItemIdentifier("connection-address-container")
        urlCard.widthAnchor.constraint(equalToConstant: PopoverLayout.heroContentWidth).isActive = true
        let connectionCardHeightConstraint = urlCard.heightAnchor.constraint(
            equalToConstant: PopoverLayout.singleConnectionHeight
        )
        connectionCardHeightConstraint.isActive = true
        self.connectionCardHeightConstraint = connectionCardHeightConstraint
        let urlStack = NSStackView()
        urlStack.orientation = .vertical
        urlStack.spacing = 0
        urlStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
        urlStack.translatesAutoresizingMaskIntoConstraints = false
        urlCard.addSubview(urlStack)

        let urlRow = NSStackView()
        urlRow.identifier = NSUserInterfaceItemIdentifier("primary-connection-row")
        urlRow.orientation = .horizontal
        urlRow.alignment = .centerY
        urlRow.spacing = 8
        urlRow.heightAnchor.constraint(equalToConstant: PopoverLayout.connectionRowHeight).isActive = true

        NSLayoutConstraint.activate([
            urlStack.leadingAnchor.constraint(equalTo: urlCard.leadingAnchor),
            urlStack.trailingAnchor.constraint(equalTo: urlCard.trailingAnchor),
            urlStack.topAnchor.constraint(equalTo: urlCard.topAnchor),
            urlStack.bottomAnchor.constraint(equalTo: urlCard.bottomAnchor)
        ])

        let linkIcon = NSImageView(image: NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage())
        linkIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        linkIcon.contentTintColor = .secondaryLabelColor
        linkIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        linkIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        linkIcon.setContentHuggingPriority(.required, for: .horizontal)
        linkIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        connectionLabel.identifier = NSUserInterfaceItemIdentifier("primary-connection-url")
        connectionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        connectionLabel.maximumNumberOfLines = 1
        connectionLabel.usesSingleLineMode = true
        connectionLabel.lineBreakMode = .byTruncatingMiddle
        connectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        connectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionFamilyLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        connectionFamilyLabel.textColor = .secondaryLabelColor
        connectionFamilyLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        connectionFamilyLabel.setContentHuggingPriority(.required, for: .horizontal)
        connectionFamilyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let copy = iconOnlyButton(
            symbol: "doc.on.doc",
            toolTip: "Copy connection URL",
            action: #selector(copyURL)
        )
        copy.identifier = NSUserInterfaceItemIdentifier("copy-primary-connection-url")
        copy.setContentHuggingPriority(.required, for: .horizontal)
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryCopyButton = copy
        urlRow.addArrangedSubview(linkIcon)
        urlRow.addArrangedSubview(connectionFamilyLabel)
        urlRow.addArrangedSubview(connectionLabel)
        urlRow.addArrangedSubview(copy)
        urlStack.addArrangedSubview(urlRow)

        secondaryConnectionRow.orientation = .horizontal
        secondaryConnectionRow.identifier = NSUserInterfaceItemIdentifier("secondary-connection-row")
        secondaryConnectionRow.alignment = .centerY
        secondaryConnectionRow.spacing = 8
        secondaryConnectionRow.heightAnchor.constraint(equalToConstant: PopoverLayout.connectionRowHeight).isActive = true
        let secondaryIndent = NSView()
        secondaryIndent.widthAnchor.constraint(equalToConstant: 16).isActive = true
        secondaryIndent.setContentHuggingPriority(.required, for: .horizontal)
        secondaryIndent.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryConnectionFamilyLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        secondaryConnectionFamilyLabel.textColor = .secondaryLabelColor
        secondaryConnectionFamilyLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        secondaryConnectionFamilyLabel.setContentHuggingPriority(.required, for: .horizontal)
        secondaryConnectionFamilyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryConnectionLabel.identifier = NSUserInterfaceItemIdentifier("secondary-connection-url")
        secondaryConnectionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        secondaryConnectionLabel.maximumNumberOfLines = 1
        secondaryConnectionLabel.usesSingleLineMode = true
        secondaryConnectionLabel.lineBreakMode = .byTruncatingMiddle
        secondaryConnectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryConnectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copyIPv6 = iconOnlyButton(
            symbol: "doc.on.doc",
            toolTip: "Copy IPv6 connection URL",
            action: #selector(copyIPv6URL)
        )
        copyIPv6.identifier = NSUserInterfaceItemIdentifier("copy-secondary-connection-url")
        copyIPv6.setContentHuggingPriority(.required, for: .horizontal)
        copyIPv6.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryCopyButton = copyIPv6
        secondaryConnectionRow.addArrangedSubview(secondaryIndent)
        secondaryConnectionRow.addArrangedSubview(secondaryConnectionFamilyLabel)
        secondaryConnectionRow.addArrangedSubview(secondaryConnectionLabel)
        secondaryConnectionRow.addArrangedSubview(copyIPv6)
        secondaryConnectionRow.isHidden = true
        urlStack.addArrangedSubview(secondaryConnectionRow)
        stack.addArrangedSubview(urlCard)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        actions.widthAnchor.constraint(equalToConstant: PopoverLayout.heroContentWidth).isActive = true
        actions.addArrangedSubview(actionButton(title: "Check", symbol: "arrow.clockwise", action: #selector(checkNow)))
        actions.addArrangedSubview(actionButton(title: "30 min", symbol: "timer", action: #selector(openForThirtyMinutes)))
        stack.addArrangedSubview(actions)
        return card
    }

    private func makeHealthGrid() -> NSView {
        let grid = NSGridView(views: [
            [ddnsTile, routerTile],
            [desktopTile, reachabilityTile]
        ])
        grid.identifier = NSUserInterfaceItemIdentifier("connection-health-grid")
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        for index in 0..<grid.numberOfColumns {
            grid.column(at: index).xPlacement = .fill
        }
        [ddnsTile, routerTile, desktopTile, reachabilityTile].forEach { tile in
            tile.widthAnchor.constraint(equalToConstant: PopoverLayout.tileWidth).isActive = true
            tile.heightAnchor.constraint(equalToConstant: PopoverLayout.tileHeight).isActive = true
        }
        grid.widthAnchor.constraint(equalToConstant: PopoverLayout.contentWidth).isActive = true
        return grid
    }

    private func makeNetworkCard() -> NSView {
        let card = CardView()
        card.identifier = NSUserInterfaceItemIdentifier("network-card")
        card.widthAnchor.constraint(equalToConstant: PopoverLayout.contentWidth).isActive = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        let title = NSTextField(labelWithString: "Network")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lastCheckedLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        lastCheckedLabel.textColor = .secondaryLabelColor
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(spacer)
        titleRow.addArrangedSubview(lastCheckedLabel)
        stack.addArrangedSubview(titleRow)

        let routes = NSGridView(views: [[ddnsProxyRoute, publicIPProxyRoute]])
        routes.columnSpacing = 10
        routes.xPlacement = .fill
        routes.yPlacement = .fill
        for index in 0..<routes.numberOfColumns {
            routes.column(at: index).xPlacement = .fill
        }
        [ddnsProxyRoute, publicIPProxyRoute].forEach { route in
            route.widthAnchor.constraint(equalToConstant: 178).isActive = true
            route.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        stack.addArrangedSubview(routes)

        let values = NSGridView(views: [
            [publicIPLabel, localIPLabel, gatewayLabel, portLabel],
            [publicIPv6Label, localIPv6Label, gatewayIPv6Label, ipv6PortLabel]
        ])
        values.rowSpacing = 6
        values.columnSpacing = 8
        let valueGridWidth = PopoverLayout.contentWidth - 28
        let valueColumnWidth = (valueGridWidth - (values.columnSpacing * 3)) / 4
        for index in 0..<values.numberOfColumns {
            values.column(at: index).xPlacement = .fill
            values.column(at: index).width = valueColumnWidth
        }
        values.widthAnchor.constraint(equalToConstant: valueGridWidth).isActive = true
        stack.addArrangedSubview(values)
        return card
    }

    private func proxyPresentation(for mode: NetworkProxyMode, customURL: String) -> ProxyPresentation {
        switch mode {
        case .custom:
            let customAddress = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URL(string: customAddress)?.host
            let detail = host ?? (customAddress.isEmpty || customAddress == "nil" ? "Custom proxy" : customAddress)
            return ProxyPresentation(name: "Custom", detail: detail, tint: .controlAccentColor)
        case .direct:
            return ProxyPresentation(name: "Direct", detail: "Skips HTTP/HTTPS/SOCKS/PAC", tint: .systemGreen)
        case .system:
            return ProxyPresentation(name: "System", detail: "Uses macOS proxy settings", tint: .secondaryLabelColor)
        }
    }

    private func makeFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let hint = NSTextField(labelWithString: "Screen Sharing: TCP 5900")
        hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settings = actionButton(title: "Settings", symbol: "slider.horizontal.3", action: #selector(openSettings))
        row.addArrangedSubview(hint)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(settings)
        row.widthAnchor.constraint(equalToConstant: PopoverLayout.contentWidth).isActive = true
        return row
    }

    private func renderHero(_ status: AppStatus) {
        if !remoteAccessEnabled {
            headlineLabel.stringValue = "Remote access is off"
            detailLabel.stringValue = "DDNS and router mappings are paused."
            statusPill.update(text: "Off", state: .disabled)
            return
        }

        if status.routerStatus.state == .ok && status.ddnsStatus.state == .ok && status.remoteDesktopStatus.state == .ok {
            headlineLabel.stringValue = "Ready to connect"
            detailLabel.stringValue = "DNS, router mapping, and this Mac are aligned."
            statusPill.update(text: "Ready", state: .ok)
            return
        }

        if status.routerStatus.state == .failed || status.ddnsStatus.state == .failed || status.remoteDesktopStatus.state == .failed {
            headlineLabel.stringValue = "Needs attention"
            detailLabel.stringValue = "A check failed. Review the tiles below before connecting."
            statusPill.update(text: "Issue", state: .failed)
            return
        }

        headlineLabel.stringValue = "Checking"
        detailLabel.stringValue = "Refreshing DNS, router mapping, and desktop status."
        statusPill.update(text: "Check", state: .checking)
    }

    private func actionButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private func iconOnlyButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func toggleAccess() {
        agent.setRemoteAccessEnabled(accessSwitch.state == .on)
    }

    @objc private func openForThirtyMinutes() {
        agent.setTemporaryAccess(minutes: 30)
    }

    @objc private func checkNow() {
        agent.runCheck()
    }

    @objc private func copyURL() {
        guard let url = RemoteConnectionURLPolicy.primaryCopyURL(
            remoteAccessEnabled: agent.config.remoteAccessEnabled,
            status: agent.status
        ) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func copyIPv6URL() {
        guard let url = RemoteConnectionURLPolicy.ipv6CopyURL(
            remoteAccessEnabled: agent.config.remoteAccessEnabled,
            status: agent.status
        ) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func refreshConnectionPresentation(_ status: AppStatus) {
        let hasDistinctURLs = remoteAccessEnabled
            && status.connectionURLIPv4 != nil
            && status.connectionURLIPv6 != nil
            && status.connectionURLIPv4 != status.connectionURLIPv6
        preferredContentSize = NSSize(
            width: PopoverLayout.width,
            height: hasDistinctURLs ? PopoverLayout.dualURLHeight : PopoverLayout.singleURLHeight
        )
        connectionCardHeightConstraint?.constant = hasDistinctURLs
            ? PopoverLayout.dualConnectionHeight
            : PopoverLayout.singleConnectionHeight

        if hasDistinctURLs {
            connectionFamilyLabel.stringValue = "IPv4"
            connectionLabel.stringValue = status.connectionURLIPv4 ?? "-"
            connectionLabel.toolTip = status.connectionURLIPv4
            secondaryConnectionFamilyLabel.stringValue = "IPv6 URL"
            secondaryConnectionLabel.stringValue = status.connectionURLIPv6 ?? "-"
            secondaryConnectionLabel.toolTip = status.connectionURLIPv6
            secondaryConnectionRow.isHidden = false
        } else {
            connectionFamilyLabel.stringValue = remoteAccessEnabled
                && status.connectionURLIPv6 != nil
                && status.connectionURLIPv4 == nil ? "IPv6 URL" : "URL"
            connectionLabel.stringValue = RemoteConnectionURLPolicy.displayURL(
                remoteAccessEnabled: remoteAccessEnabled,
                status: status
            )
            connectionLabel.toolTip = remoteAccessEnabled ? status.connectionURL : nil
            secondaryConnectionLabel.stringValue = ""
            secondaryConnectionLabel.toolTip = nil
            secondaryConnectionRow.isHidden = true
        }

        primaryCopyButton?.isEnabled = RemoteConnectionURLPolicy.primaryCopyURL(
            remoteAccessEnabled: remoteAccessEnabled,
            status: status
        ) != nil
        secondaryCopyButton?.isEnabled = RemoteConnectionURLPolicy.ipv6CopyURL(
            remoteAccessEnabled: remoteAccessEnabled,
            status: status
        ) != nil
    }

    func refreshAppearance() {
        dispatchPrecondition(condition: .onQueue(.main))
        for candidate in popoverDescendants(of: view) {
            (candidate as? PopoverAppearanceRefreshing)?.refreshAppearanceLayers()
        }
        view.needsDisplay = true
    }

    @objc private func openSettings() {
        openSettingsHandler()
    }

    @objc private func quit() {
        quitHandler()
    }
}

private class CardView: NSView, PopoverAppearanceRefreshing {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        applyCardAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        refreshAppearanceLayers()
    }

    func refreshAppearanceLayers() {
        applyCardAppearance()
    }

    private func applyCardAppearance() {
        layer?.backgroundColor = NSColor.resolvedCGColor(
            .controlBackgroundColor,
            for: self
        )
        layer?.borderColor = NSColor.resolvedCGColor(
            .separatorColor.withAlphaComponent(0.45),
            for: self
        )
    }
}

private final class RoundedFieldView: NSView, PopoverAppearanceRefreshing {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        refreshAppearanceLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        refreshAppearanceLayers()
    }

    func refreshAppearanceLayers() {
        layer?.backgroundColor = NSColor.resolvedCGColor(
            .textBackgroundColor,
            for: self
        )
        layer?.borderColor = NSColor.resolvedCGColor(
            .separatorColor.withAlphaComponent(0.5),
            for: self
        )
    }
}

private final class StatusTile: CardView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var currentState: CheckState = .unknown

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier(
            "status-tile-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        dot.wantsLayer = true
        dot.identifier = NSUserInterfaceItemIdentifier(
            "status-dot-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        titleLabel.stringValue = title
        titleLabel.identifier = NSUserInterfaceItemIdentifier(
            "status-title-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(dot)

        messageLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        messageLabel.identifier = NSUserInterfaceItemIdentifier(
            "status-message-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.preferredMaxLayoutWidth = PopoverLayout.tileWidth - 20
        messageLabel.heightAnchor.constraint(equalToConstant: 27).isActive = true

        stack.addArrangedSubview(row)
        stack.addArrangedSubview(messageLabel)
        update(.unknown())
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ status: ComponentStatus) {
        messageLabel.stringValue = status.message
        messageLabel.toolTip = status.message
        currentState = status.state
        refreshAppearanceLayers()
    }

    override func refreshAppearanceLayers() {
        super.refreshAppearanceLayers()
        dot.layer?.backgroundColor = NSColor.resolvedCGColor(
            .statusColor(for: currentState),
            for: dot
        )
    }
}

private struct ProxyPresentation {
    let name: String
    let detail: String
    let tint: NSColor
}

private final class ProxyRouteView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "System")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 5

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modeLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        modeLabel.lineBreakMode = .byTruncatingTail
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        top.addArrangedSubview(icon)
        top.addArrangedSubview(titleLabel)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(detailLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ presentation: ProxyPresentation) {
        modeLabel.stringValue = presentation.name
        modeLabel.textColor = presentation.tint
        detailLabel.stringValue = presentation.detail
        detailLabel.toolTip = presentation.detail
    }
}

private final class ValueLabel: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "-")

    var value: String {
        get { valueLabel.stringValue }
        set {
            valueLabel.stringValue = newValue
            valueLabel.toolTip = newValue
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        valueLabel.maximumNumberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.usesSingleLineMode = true
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class PillLabel: NSTextField, PopoverAppearanceRefreshing {
    private var currentState: CheckState = .disabled

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("status-pill")
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        update(text: "Off", state: .disabled)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(text: String, state: CheckState) {
        stringValue = text
        currentState = state
        refreshAppearanceLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        refreshAppearanceLayers()
    }

    func refreshAppearanceLayers() {
        if currentState == .disabled {
            textColor = .labelColor
            layer?.backgroundColor = NSColor.resolvedCGColor(
                .separatorColor.withAlphaComponent(0.24),
                for: self
            )
            return
        }

        let base = NSColor.statusColor(for: currentState)
        textColor = base
        layer?.backgroundColor = NSColor.resolvedCGColor(
            base.withAlphaComponent(0.14),
            for: self
        )
    }
}

private final class SymbolBadgeView: NSView, PopoverAppearanceRefreshing {
    private let imageView = NSImageView()

    init(symbol: String) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("gatebeam-symbol-badge")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        refreshAppearanceLayers()

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        refreshAppearanceLayers()
    }

    func refreshAppearanceLayers() {
        layer?.backgroundColor = NSColor.resolvedCGColor(
            .controlBackgroundColor,
            for: self
        )
        layer?.borderColor = NSColor.resolvedCGColor(
            .separatorColor.withAlphaComponent(0.35),
            for: self
        )
    }
}

private protocol PopoverAppearanceRefreshing: AnyObject {
    func refreshAppearanceLayers()
}

private final class PopoverAppearanceTrackingView: NSVisualEffectView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        onEffectiveAppearanceChanged?()
    }
}

private func popoverDescendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + popoverDescendants(of: $0) }
}

private extension NSColor {
    static func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    static func statusColor(for state: CheckState) -> NSColor {
        switch state {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .failed: return .systemRed
        case .checking: return .systemBlue
        case .disabled: return .secondaryLabelColor
        case .unknown: return .separatorColor
        }
    }
}

private extension DateFormatter {
    static let popoverTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
