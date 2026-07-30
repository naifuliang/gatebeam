import AppKit
import Foundation

private enum SettingsLayout {
    static let gridWidth: CGFloat = 820
    static let cardContentWidth: CGFloat = 369
    static let metricWidth: CGFloat = 178.5
    static let horizontalInset: CGFloat = 30
    static let minimumContentHeight: CGFloat = 620
}

enum SettingsProxyValidation {
    static let formatMessage = "Use http://host:port or socks5://host:port."

    static func normalizedForPersistence(_ config: AppConfig) throws -> AppConfig {
        var normalized = config
        let candidate = config.customProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesCustomProxy = config.ddnsProxyMode == .custom || config.publicIPProxyMode == .custom

        guard !candidate.isEmpty else {
            normalized.customProxyURL = ""
            if usesCustomProxy {
                _ = try HTTPClient.validatedProxyURL(candidate)
            }
            return normalized
        }

        do {
            normalized.customProxyURL = try HTTPClient.validatedProxyURL(candidate).absoluteString
        } catch {
            normalized.customProxyURL = ""
            if usesCustomProxy {
                throw error
            }
        }

        if !usesCustomProxy {
            normalized.customProxyURL = ""
        }
        return normalized
    }

    static func message(for config: AppConfig) -> String? {
        do {
            _ = try normalizedForPersistence(config)
            return nil
        } catch {
            return formatMessage
        }
    }
}

struct SettingsPersistenceCoordinator {
    let persistSettings: (AppConfig, CloudflareTokenMutation) throws -> AppConfig

    @discardableResult
    func persist(
        config: AppConfig,
        tokenMutation: CloudflareTokenMutation = .keepExisting
    ) throws -> AppConfig {
        let normalized = try SettingsProxyValidation.normalizedForPersistence(config)
        return try persistSettings(normalized, tokenMutation.validated())
    }
}

enum SettingsTokenMutationPolicy {
    static func saveMutation(
        enteredToken: String,
        fieldWasEdited: Bool,
        readState: CloudflareTokenReadState
    ) -> CloudflareTokenMutation {
        guard fieldWasEdited else { return .keepExisting }
        let normalized = enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .keepExisting }
        if case .available(let savedToken) = readState,
           savedToken == normalized {
            return .keepExisting
        }
        return .replace(normalized)
    }

    static func verificationToken(
        enteredToken: String,
        readState: CloudflareTokenReadState
    ) -> String? {
        let normalized = enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return normalized
        }
        if case .available(let savedToken) = readState {
            return savedToken
        }
        return nil
    }

    static func removalMutation(confirmed: Bool) -> CloudflareTokenMutation? {
        confirmed ? .explicitRemove : nil
    }
}

struct CloudflareVerificationRequest: Equatable {
    let generation: UInt64
    let token: String?
    let pendingTokenMutation: CloudflareTokenMutation
    let proxyMode: NetworkProxyMode
    let customProxyURL: String
}

struct SettingsCloudflareVerificationCoordinator {
    private var nextGeneration: UInt64 = 0
    private(set) var activeGeneration: UInt64?

    mutating func begin(
        token: String?,
        pendingTokenMutation: CloudflareTokenMutation,
        formConfig: AppConfig
    ) throws -> CloudflareVerificationRequest {
        nextGeneration &+= 1
        activeGeneration = nil
        let route = try Self.cloudflareRoute(from: formConfig)
        activeGeneration = nextGeneration
        return CloudflareVerificationRequest(
            generation: nextGeneration,
            token: token,
            pendingTokenMutation: pendingTokenMutation,
            proxyMode: route.mode,
            customProxyURL: route.customProxyURL
        )
    }

    mutating func complete(_ request: CloudflareVerificationRequest) -> Bool {
        guard activeGeneration == request.generation else { return false }
        activeGeneration = nil
        return true
    }

    @discardableResult
    mutating func cancelActive() -> Bool {
        guard activeGeneration != nil else { return false }
        activeGeneration = nil
        return true
    }

    private static func cloudflareRoute(
        from config: AppConfig
    ) throws -> (mode: NetworkProxyMode, customProxyURL: String) {
        guard config.ddnsProxyMode == .custom else {
            return (config.ddnsProxyMode, "")
        }
        return (
            .custom,
            try HTTPClient.validatedProxyURL(config.customProxyURL).absoluteString
        )
    }
}

enum SettingsCloudflareTokenRemovalPrompt {
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Cloudflare Token?"
        alert.informativeText = "Gatebeam will delete only the saved Cloudflare API token. Your other settings will not be changed."
        let removeButton = alert.addButton(withTitle: "Remove Token")
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func mutation(
        for response: NSApplication.ModalResponse
    ) -> CloudflareTokenMutation? {
        SettingsTokenMutationPolicy.removalMutation(
            confirmed: response == .alertFirstButtonReturn
        )
    }
}

enum SettingsCloudflareZoneReadPresentation {
    static func message(zoneCount: Int, pendingStorage: Bool) -> String {
        guard zoneCount > 0 else {
            return "Token is active, but no readable zones were returned. Grant Zone/Zone/Read for the target zone."
        }
        let noun = zoneCount == 1 ? "zone" : "zones"
        if pendingStorage {
            return "Token is active and can read \(zoneCount) \(noun). Save Changes stores it; DNS Edit is confirmed on the first record update."
        }
        return "Token is active and can read \(zoneCount) \(noun). DNS Edit is confirmed when Gatebeam updates the selected record."
    }
}

enum SettingsCloudflareErrorPresentation {
    static let genericMessage = "Cloudflare request failed. Check the connection route and try again."

    static func message(for error: Error) -> String {
        if let cloudflareError = error as? CloudflareError {
            return cloudflareError.localizedDescription
        }
        if let keychainError = error as? KeychainError {
            return keychainError.localizedDescription
        }
        if case NetworkError.invalidProxyURL = error {
            return "Invalid proxy URL: \(SettingsProxyValidation.formatMessage)"
        }
        return genericMessage
    }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private struct PreparedPersistence {
        let config: AppConfig
        let tokenMutation: CloudflareTokenMutation
    }

    private let agent: NetworkAgent
    private let tokenRemovalResponseProvider: (NSAlert) -> NSApplication.ModalResponse

    private let remoteEnabledButton = NSButton(checkboxWithTitle: "Remote access", target: nil, action: nil)
    private let startAtLoginButton = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let providerControl = NSSegmentedControl(labels: ["Off", "Cloudflare"], trackingMode: .selectOne, target: nil, action: nil)
    private let addressControl = NSSegmentedControl(labels: ["IPv4", "Dual", "IPv6"], trackingMode: .selectOne, target: nil, action: nil)
    private let protocolControl = NSSegmentedControl(labels: ["Auto", "PCP", "UPnP", "NAT-PMP", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let ddnsProxyControl = NSSegmentedControl(labels: ["System", "Direct", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let publicIPProxyControl = NSSegmentedControl(labels: ["System", "Direct", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let zonePopup = NSPopUpButton()
    private let recordNameField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let customProxyField = NSTextField()
    private let proxyExplanationLabel = NSTextField(labelWithString: "")
    private let proxyValidationLabel = NSTextField(labelWithString: "")
    private let cloudflareFeedbackLabel = NSTextField(
        labelWithString: "Paste a token, or authorize one saved by an earlier Gatebeam build."
    )
    private let recordPreviewLabel = NSTextField(labelWithString: "Full address will appear after a domain is selected.")
    private let internalPortField = NSTextField()
    private let externalPortField = NSTextField()
    private let leaseField = NSTextField()
    private let intervalField = NSTextField()
    private let externalProbeField = NSTextField()

    private let headlineLabel = NSTextField(labelWithString: "Remote access is off")
    private let subheadlineLabel = NSTextField(labelWithString: "Turn it on when you want this Mac reachable from outside your network.")
    private let connectionLabel = NSTextField(labelWithString: "No connection URL yet")
    private let lastCheckedLabel = NSTextField(labelWithString: "Not checked yet")

    private let ddnsStatusView = StatusMetricView(title: "DDNS", width: SettingsLayout.metricWidth)
    private let routerStatusView = StatusMetricView(title: "Router", width: SettingsLayout.metricWidth)
    private let desktopStatusView = StatusMetricView(title: "Desktop", width: SettingsLayout.metricWidth)
    private let reachabilityStatusView = StatusMetricView(title: "Local TCP", width: SettingsLayout.metricWidth)
    private var cloudflareZones: [CloudflareZoneSummary] = []
    private var configuredRecordName = ""
    private var tokenReadState: CloudflareTokenReadState = .unknown
    private var tokenFieldWasEdited = false
    private var isSynchronizingTokenField = false
    private var cloudflareVerification = SettingsCloudflareVerificationCoordinator()
    private var isPersisting = false
    private var isAuthorizingToken = false
    private weak var saveButton: NSButton?
    private weak var checkButton: NSButton?
    private weak var connectButton: NSButton?
    private weak var authorizeTokenButton: NSButton?
    private weak var removeTokenButton: NSButton?
    private weak var temporaryAccessButton: NSButton?
    private weak var copyURLButton: NSButton?
    private weak var footerView: NSView?

    init(
        agent: NetworkAgent,
        autoLoadCloudflare: Bool = true,
        tokenRemovalResponseProvider: ((NSAlert) -> NSApplication.ModalResponse)? = nil
    ) {
        self.agent = agent
        self.tokenRemovalResponseProvider = tokenRemovalResponseProvider ?? { alert in
            alert.runModal()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let appearanceView = SettingsAppearanceTrackingView(
            frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 880, height: 880)
        )
        appearanceView.autoresizingMask = [.width, .height]
        appearanceView.identifier = NSUserInterfaceItemIdentifier("settings-root")
        window.contentView = appearanceView
        window.title = "Gatebeam"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(
            width: SettingsLayout.gridWidth + (SettingsLayout.horizontalInset * 2),
            height: SettingsLayout.minimumContentHeight
        )
        window.center()
        super.init(window: window)
        appearanceView.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshAppearance()
        }
        setupContent()
        let tokenState = agent.cloudflareTokenState
        update(config: agent.config, tokenState: tokenState)
        update(status: agent.status)
        if agent.savedTokenNeedsAuthorization {
            cloudflareFeedbackLabel.stringValue = "A saved token needs approval. Click Authorize Token."
            cloudflareFeedbackLabel.textColor = .systemOrange
        }
        if autoLoadCloudflare, case .available = tokenState {
            loadCloudflareZones(showErrors: false)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(config: AppConfig, tokenState: CloudflareTokenReadState) {
        remoteEnabledButton.state = config.remoteAccessEnabled ? .on : .off
        startAtLoginButton.state = config.startAtLogin ? .on : .off
        configuredRecordName = config.dnsRecordName
        if let index = cloudflareZones.firstIndex(where: { $0.id == config.cloudflareZoneID }) {
            zonePopup.selectItem(at: index)
            recordNameField.stringValue = relativeRecordName(config.dnsRecordName, zoneName: cloudflareZones[index].name)
        } else {
            recordNameField.stringValue = config.dnsRecordName
        }
        updateRecordPreview()
        tokenReadState = tokenState
        if !tokenFieldWasEdited {
            synchronizeTokenField(with: tokenState)
        }
        internalPortField.stringValue = String(config.internalPort)
        externalPortField.stringValue = String(config.externalPort)
        leaseField.stringValue = String(config.mappingLeaseSeconds)
        intervalField.stringValue = String(Int(config.checkIntervalSeconds))
        externalProbeField.stringValue = config.externalProbeHost
        providerControl.selectedSegment = config.dnsProvider == .disabled ? 0 : 1
        addressControl.selectedSegment = addressSegment(for: config.preferredAddressFamily)
        protocolControl.selectedSegment = segment(for: config.mappingProtocolPreference)
        ddnsProxyControl.selectedSegment = proxySegment(for: config.ddnsProxyMode)
        publicIPProxyControl.selectedSegment = proxySegment(for: config.publicIPProxyMode)
        customProxyField.stringValue = config.customProxyURL
        updateProxyControls(validationMessage: proxyValidationMessage(for: config))
        refreshConnectionPresentation(status: agent.status)
    }

    func update(status: AppStatus) {
        renderSummary(status)
        refreshConnectionPresentation(status: status)
        if let checked = status.lastCheckedAt {
            lastCheckedLabel.stringValue = "Last checked \(DateFormatter.settingsShortTime.string(from: checked))"
        } else {
            lastCheckedLabel.stringValue = "Not checked yet"
        }
        ddnsStatusView.update(status.ddnsStatus)
        routerStatusView.update(status.routerStatus)
        desktopStatusView.update(status.remoteDesktopStatus)
        reachabilityStatusView.update(status.externalReachabilityStatus)
    }

    func setCloudflareZonesForPreview(_ zones: [CloudflareZoneSummary]) {
        applyCloudflareZones(zones)
        cloudflareFeedbackLabel.stringValue = SettingsCloudflareZoneReadPresentation.message(
            zoneCount: zones.count,
            pendingStorage: false
        )
        cloudflareFeedbackLabel.textColor = zones.isEmpty ? .systemOrange : .systemBlue
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(header)

        let accessPanel = makeAccessPanel()
        let ddnsPanel = makeDDNSPanel()
        let routerPanel = makeRouterPanel()
        let routingPanel = makeNetworkRoutingPanel()
        let grid = NSGridView(views: [
            [accessPanel, ddnsPanel],
            [routerPanel, routingPanel]
        ])
        grid.columnSpacing = 18
        grid.rowSpacing = 16
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth),
            accessPanel.widthAnchor.constraint(equalTo: ddnsPanel.widthAnchor),
            accessPanel.widthAnchor.constraint(equalTo: routerPanel.widthAnchor),
            accessPanel.widthAnchor.constraint(equalTo: routingPanel.widthAnchor),
            accessPanel.heightAnchor.constraint(equalTo: ddnsPanel.heightAnchor),
            routerPanel.heightAnchor.constraint(equalTo: routingPanel.heightAnchor)
        ])

        let document = NSStackView()
        document.orientation = .vertical
        document.alignment = .centerX
        document.spacing = 0
        document.edgeInsets = NSEdgeInsets(top: 0, left: SettingsLayout.horizontalInset, bottom: 16, right: SettingsLayout.horizontalInset)
        document.addArrangedSubview(grid)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.setContentHuggingPriority(.required, for: .vertical)
        document.setContentCompressionResistancePriority(.required, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        contentView.addSubview(scrollView)

        let actionBar = makeActionBar()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.setContentHuggingPriority(.required, for: .vertical)
        actionBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let footer = NSView()
        footer.identifier = NSUserInterfaceItemIdentifier("settings-footer")
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footerView = footer
        contentView.addSubview(footer)
        footer.addSubview(actionBar)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: SettingsLayout.horizontalInset),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -SettingsLayout.horizontalInset),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 56),

            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),

            actionBar.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            actionBar.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 1)
        ])
        refreshAppearance()
    }

    private func makeHeader() -> NSView {
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth).isActive = true

        headlineLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        headlineLabel.alignment = .left
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth).isActive = true

        subheadlineLabel.font = NSFont.systemFont(ofSize: 13)
        subheadlineLabel.alignment = .left
        subheadlineLabel.textColor = .secondaryLabelColor
        subheadlineLabel.lineBreakMode = .byTruncatingTail
        subheadlineLabel.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth).isActive = true

        connectionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        connectionLabel.identifier = NSUserInterfaceItemIdentifier("settings-connection-url")
        connectionLabel.alignment = .left
        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.lineBreakMode = .byTruncatingMiddle
        connectionLabel.maximumNumberOfLines = 1
        connectionLabel.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth).isActive = true

        textStack.addArrangedSubview(headlineLabel)
        textStack.addArrangedSubview(subheadlineLabel)
        textStack.addArrangedSubview(connectionLabel)
        return textStack
    }

    private func makeAccessPanel() -> NSView {
        let panel = makePanel(title: "Access & Health", subtitle: "Control public access and review connection health.")

        remoteEnabledButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        remoteEnabledButton.identifier = NSUserInterfaceItemIdentifier("settings-remote-access")
        remoteEnabledButton.target = self
        remoteEnabledButton.action = #selector(remoteAccessFormChanged)
        startAtLoginButton.font = NSFont.systemFont(ofSize: 13)

        let hint = caption("When off, DNS updates and router mappings pause.")

        let openButton = iconButton(title: "30 min", symbol: "timer", action: #selector(openForThirtyMinutes))
        openButton.identifier = NSUserInterfaceItemIdentifier("settings-open-30-minutes")
        openButton.bezelStyle = .rounded
        openButton.toolTip = "Open remote access for 30 minutes"
        temporaryAccessButton = openButton

        let accessControls = NSStackView()
        accessControls.orientation = .horizontal
        accessControls.alignment = .centerY
        accessControls.spacing = 14
        accessControls.addArrangedSubview(remoteEnabledButton)
        accessControls.addArrangedSubview(startAtLoginButton)
        let accessSpacer = NSView()
        accessSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accessControls.addArrangedSubview(accessSpacer)
        accessControls.addArrangedSubview(openButton)
        accessControls.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        panel.addArrangedSubview(accessControls)
        panel.addArrangedSubview(hint)
        panel.addArrangedSubview(separator())

        let healthGrid = NSGridView(views: [
            [ddnsStatusView, routerStatusView],
            [desktopStatusView, reachabilityStatusView]
        ])
        healthGrid.columnSpacing = 12
        healthGrid.rowSpacing = 8
        healthGrid.xPlacement = .fill
        healthGrid.yPlacement = .fill
        healthGrid.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        panel.addArrangedSubview(healthGrid)

        lastCheckedLabel.font = NSFont.systemFont(ofSize: 11)
        lastCheckedLabel.textColor = .secondaryLabelColor
        panel.addArrangedSubview(lastCheckedLabel)
        panel.addArrangedSubview(verticalSpacer())
        return panel
    }

    private func makeDDNSPanel() -> NSView {
        let panel = makePanel(title: "Dynamic DNS", subtitle: "Creates DNS-only A and AAAA records for the selected address mode.")
        configureSegment(providerControl)
        configureSegment(addressControl)
        panel.addArrangedSubview(twoColumnRow(
            labeledControl("Provider", providerControl, minWidth: 170),
            labeledControl("Address mode", addressControl, minWidth: 170)
        ))
        panel.addArrangedSubview(labeledField("API token", tokenField))

        let connectButton = iconButton(title: "Verify", symbol: "arrow.triangle.2.circlepath", action: #selector(connectCloudflare))
        connectButton.identifier = NSUserInterfaceItemIdentifier("settings-verify-token")
        connectButton.toolTip = "Verify the entered token and load its available Cloudflare domains"
        self.connectButton = connectButton
        let authorizeButton = iconButton(
            title: "Authorize Token",
            symbol: "key",
            action: #selector(authorizeSavedToken)
        )
        authorizeButton.identifier = NSUserInterfaceItemIdentifier("settings-authorize-token")
        authorizeButton.toolTip = "Allow this Gatebeam build to use and securely migrate a previously saved token"
        self.authorizeTokenButton = authorizeButton
        let removeButton = symbolButton(
            symbol: "trash",
            toolTip: "Remove the saved Cloudflare token",
            action: #selector(confirmRemoveCloudflareToken)
        )
        self.removeTokenButton = removeButton
        let helpButton = symbolButton(symbol: "questionmark.circle", toolTip: "Cloudflare token permissions", action: #selector(showCloudflareHelp))
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.addArrangedSubview(connectButton)
        buttonStack.addArrangedSubview(authorizeButton)
        buttonStack.addArrangedSubview(removeButton)
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonStack.addArrangedSubview(buttonSpacer)
        buttonStack.addArrangedSubview(helpButton)
        buttonStack.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        panel.addArrangedSubview(buttonStack)

        cloudflareFeedbackLabel.font = NSFont.systemFont(ofSize: 11)
        cloudflareFeedbackLabel.textColor = .secondaryLabelColor
        cloudflareFeedbackLabel.maximumNumberOfLines = 3
        cloudflareFeedbackLabel.lineBreakMode = .byWordWrapping
        cloudflareFeedbackLabel.preferredMaxLayoutWidth = SettingsLayout.cardContentWidth
        cloudflareFeedbackLabel.widthAnchor.constraint(
            equalToConstant: SettingsLayout.cardContentWidth
        ).isActive = true
        panel.addArrangedSubview(cloudflareFeedbackLabel)

        zonePopup.removeAllItems()
        zonePopup.addItem(withTitle: "No domains loaded")
        zonePopup.isEnabled = false
        zonePopup.target = self
        zonePopup.action = #selector(zoneChanged)
        zonePopup.controlSize = .regular
        zonePopup.heightAnchor.constraint(equalToConstant: 28).isActive = true
        recordNameField.delegate = self
        tokenField.delegate = self
        panel.addArrangedSubview(twoColumnRow(
            labeledControl("Domain", zonePopup, minWidth: 160),
            labeledField("Subdomain", recordNameField, placeholder: "remote or @", minWidth: 160)
        ))
        recordPreviewLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        recordPreviewLabel.textColor = .secondaryLabelColor
        recordPreviewLabel.lineBreakMode = .byTruncatingMiddle
        recordPreviewLabel.toolTip = "The complete DNS address that Cloudflare will create or update"
        panel.addArrangedSubview(recordPreviewLabel)
        panel.addArrangedSubview(verticalSpacer())
        return panel
    }

    private func makeRouterPanel() -> NSView {
        let panel = makePanel(
            title: "Router & Local Check",
            subtitle: "Open the route, then test a TCP connection originating from this Mac."
        )
        configureSegment(protocolControl)
        panel.addArrangedSubview(labeledControl("Protocol", protocolControl))
        panel.addArrangedSubview(threeColumnRow(
            labeledField("Inside", internalPortField, placeholder: "5900", minWidth: 100),
            labeledField("Outside", externalPortField, placeholder: "45900", minWidth: 100),
            labeledField("Lease", leaseField, placeholder: "3600", minWidth: 100)
        ))
        panel.addArrangedSubview(caption("IPv6 UPnP opens the inside port directly. PCP can request the outside port."))
        panel.addArrangedSubview(separator())
        panel.addArrangedSubview(sectionLabel("Local-origin TCP Check"))
        intervalField.toolTip = "Default: 300 seconds. Allowed range: 60 to 86400. Invalid saved values migrate to 300 or the nearest limit."
        panel.addArrangedSubview(twoColumnRow(
            labeledField("Check interval (seconds)", intervalField, placeholder: "300", minWidth: 120),
            labeledField("Target host", externalProbeField, placeholder: "Optional", minWidth: 120)
        ))
        panel.addArrangedSubview(caption("Interval defaults to 300 seconds; allowed range is 60 to 86400. Invalid saved values are migrated."))
        panel.addArrangedSubview(caption("Optional. This checks a TCP path from this Mac only; it does not verify internet reachability."))
        panel.addArrangedSubview(verticalSpacer())
        return panel
    }

    private func makeNetworkRoutingPanel() -> NSView {
        let panel = makePanel(
            title: "Connection Routing",
            subtitle: "Choose how each internet request leaves this Mac."
        )

        configureSegment(ddnsProxyControl)
        configureSegment(publicIPProxyControl)
        ddnsProxyControl.identifier = NSUserInterfaceItemIdentifier(
            "settings-ddns-proxy-mode"
        )
        publicIPProxyControl.identifier = NSUserInterfaceItemIdentifier(
            "settings-public-ip-proxy-mode"
        )
        ddnsProxyControl.target = self
        ddnsProxyControl.action = #selector(proxyModeChanged)
        publicIPProxyControl.target = self
        publicIPProxyControl.action = #selector(proxyModeChanged)

        panel.addArrangedSubview(labeledControl("Cloudflare DDNS", ddnsProxyControl))
        panel.addArrangedSubview(caption("Controls token verification, domain loading, and DNS record updates."))
        panel.addArrangedSubview(labeledControl("Public IP probe", publicIPProxyControl))
        panel.addArrangedSubview(caption("Direct is recommended when the probe must report the ISP-facing address."))

        customProxyField.delegate = self
        customProxyField.identifier = NSUserInterfaceItemIdentifier(
            "settings-custom-proxy-url"
        )
        customProxyField.toolTip = "Use http://host:port or socks5://host:port. Credentials are not stored here."
        panel.addArrangedSubview(labeledField(
            "Custom proxy URL",
            customProxyField,
            placeholder: "http://host:port or socks5://host:port"
        ))

        proxyExplanationLabel.font = NSFont.systemFont(ofSize: 11)
        proxyExplanationLabel.textColor = .secondaryLabelColor
        proxyExplanationLabel.maximumNumberOfLines = 2
        proxyExplanationLabel.lineBreakMode = .byWordWrapping
        proxyExplanationLabel.preferredMaxLayoutWidth = SettingsLayout.cardContentWidth
        proxyExplanationLabel.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        panel.addArrangedSubview(proxyExplanationLabel)

        proxyValidationLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        proxyValidationLabel.textColor = .systemRed
        proxyValidationLabel.maximumNumberOfLines = 1
        proxyValidationLabel.lineBreakMode = .byTruncatingTail
        proxyValidationLabel.preferredMaxLayoutWidth = SettingsLayout.cardContentWidth
        proxyValidationLabel.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        proxyValidationLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings-proxy-validation"
        )
        panel.addArrangedSubview(proxyValidationLabel)
        panel.addArrangedSubview(verticalSpacer())
        return panel
    }

    private func makeActionBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copyButton = iconButton(title: "Copy URL", symbol: "doc.on.doc", action: #selector(copyURL))
        copyButton.identifier = NSUserInterfaceItemIdentifier("settings-copy-url")
        let checkButton = iconButton(title: "Check Now", symbol: "arrow.clockwise", action: #selector(checkNow))
        checkButton.identifier = NSUserInterfaceItemIdentifier("settings-check-now")
        let saveButton = iconButton(title: "Save Changes", symbol: "checkmark", action: #selector(save))
        saveButton.identifier = NSUserInterfaceItemIdentifier("settings-save")
        self.copyURLButton = copyButton
        self.checkButton = checkButton
        self.saveButton = saveButton
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(copyButton)
        bar.addArrangedSubview(checkButton)
        bar.addArrangedSubview(saveButton)
        bar.widthAnchor.constraint(equalToConstant: SettingsLayout.gridWidth).isActive = true
        return bar
    }

    private func makePanel(
        title: String? = nil,
        subtitle: String? = nil,
        alignment: NSLayoutConstraint.Attribute = .leading
    ) -> NSStackView {
        let stack = SettingsPanelView()
        let identifierTitle = title ?? "untitled"
        stack.identifier = NSUserInterfaceItemIdentifier(
            "settings-panel-\(identifierTitle.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.cornerCurve = .continuous
        stack.layer?.borderWidth = 1
        stack.refreshAppearanceLayers()

        if let title {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            titleLabel.alignment = alignment == .centerX ? .center : .left
            stack.addArrangedSubview(titleLabel)
        }

        if let subtitle {
            stack.addArrangedSubview(caption(subtitle))
        }

        return stack
    }

    private func labeledField(_ title: String, _ field: NSTextField, placeholder: String = "", minWidth: CGFloat = SettingsLayout.cardContentWidth) -> NSView {
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: 13)
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        return labeledControl(title, field, minWidth: minWidth)
    }

    private func labeledControl(_ title: String, _ control: NSView, minWidth: CGFloat = SettingsLayout.cardContentWidth) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(control)
        return stack
    }

    private func twoColumnRow(_ left: NSView, _ right: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(right)
        stack.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        return stack
    }

    private func threeColumnRow(_ first: NSView, _ second: NSView, _ third: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.distribution = .fillEqually
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        stack.addArrangedSubview(third)
        stack.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        return stack
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = SettingsLayout.cardContentWidth
        label.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsLayout.cardContentWidth).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        return label
    }

    private func buttonRow(_ button: NSButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(button)
        row.addArrangedSubview(spacer)
        row.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: SettingsLayout.cardContentWidth).isActive = true
        return box
    }

    private func verticalSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return spacer
    }

    private func configureSegment(_ control: NSSegmentedControl) {
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func iconButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func symbolButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = toolTip
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func renderSummary(_ status: AppStatus) {
        let config = agent.config
        if let settingsError = status.settingsErrorMessage {
            headlineLabel.stringValue = "Settings need attention"
            subheadlineLabel.stringValue = settingsError
            subheadlineLabel.toolTip = settingsError
            return
        }
        subheadlineLabel.toolTip = nil

        if !config.remoteAccessEnabled {
            headlineLabel.stringValue = "Remote access is off"
            subheadlineLabel.stringValue = "DDNS and router mappings stay idle until you turn access on."
            return
        }

        if status.routerStatus.state == .ok && status.ddnsStatus.state == .ok && status.remoteDesktopStatus.state == .ok {
            headlineLabel.stringValue = "Ready for remote connection"
            subheadlineLabel.stringValue = "DNS, router mapping, and this Mac's desktop service are aligned."
            return
        }

        if status.routerStatus.state == .failed || status.ddnsStatus.state == .failed || status.remoteDesktopStatus.state == .failed {
            headlineLabel.stringValue = "Needs attention"
            subheadlineLabel.stringValue = "One or more checks failed. Review the health panel before connecting."
            return
        }

        headlineLabel.stringValue = "Checking connection"
        subheadlineLabel.stringValue = "The app is refreshing DNS, router mapping, and local desktop status."
    }

    @objc private func save() {
        persist(formConfig())
    }

    private func formConfig() -> AppConfig {
        var config = agent.config
        config.remoteAccessEnabled = remoteEnabledButton.state == .on
        config.clearTemporaryAccessExpiration()
        config.startAtLogin = startAtLoginButton.state == .on
        config.dnsProvider = providerControl.selectedSegment == 0 ? .disabled : .cloudflare
        config.preferredAddressFamily = addressPreference(for: addressControl.selectedSegment)
        if let zone = selectedCloudflareZone() {
            config.cloudflareZoneID = zone.id
            config.dnsRecordName = fullyQualifiedRecordName(recordNameField.stringValue, zoneName: zone.name)
        } else {
            config.dnsRecordName = recordNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        config.mappingProtocolPreference = mappingPreference(for: protocolControl.selectedSegment)
        config.internalPort = UInt16(internalPortField.stringValue) ?? 5900
        config.externalPort = UInt16(externalPortField.stringValue) ?? AppConfig.default.externalPort
        config.mappingLeaseSeconds = UInt32(leaseField.stringValue) ?? 3600
        let requestedInterval = TimeInterval(intervalField.stringValue)
            ?? AppConfig.defaultCheckIntervalSeconds
        config.checkIntervalSeconds = AppConfig.normalizedCheckInterval(requestedInterval)
        config.externalProbeHost = externalProbeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.ddnsProxyMode = proxyMode(for: ddnsProxyControl.selectedSegment)
        config.publicIPProxyMode = proxyMode(for: publicIPProxyControl.selectedSegment)
        config.customProxyURL = customProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    private func persist(
        _ config: AppConfig,
        tokenMutation: CloudflareTokenMutation? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isBusy else { return }
        let prepared: PreparedPersistence
        do {
            prepared = try preparePersistence(
                config,
                tokenMutation: tokenMutation
            )
        } catch {
            presentPersistenceError(error)
            completion?(false)
            return
        }
        performPersistence(prepared, completion: completion)
    }

    private func preparePersistence(
        _ config: AppConfig,
        tokenMutation: CloudflareTokenMutation? = nil
    ) throws -> PreparedPersistence {
        let normalized = try SettingsProxyValidation.normalizedForPersistence(
            config
        )
        let mutation = try (
            tokenMutation ?? SettingsTokenMutationPolicy.saveMutation(
                enteredToken: tokenField.stringValue,
                fieldWasEdited: tokenFieldWasEdited,
                readState: tokenReadState
            )
        ).validated()
        return PreparedPersistence(
            config: normalized,
            tokenMutation: mutation
        )
    }

    private func performPersistence(
        _ prepared: PreparedPersistence,
        temporaryAccessMinutes: Int? = nil,
        uiMutation: (() -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !isBusy else { return }
        uiMutation?()
        cancelCloudflareVerification()
        setPersistenceBusy(true)
        let handleResult: (Result<AppConfig, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.setPersistenceBusy(false)
            switch result {
            case .success(let persistedConfig):
                self.applyPersistedTokenMutation(prepared.tokenMutation)
                self.synchronizePersistedProxyField(from: persistedConfig)
                self.intervalField.stringValue = String(Int(persistedConfig.checkIntervalSeconds))
                completion?(true)
            case .failure(let error):
                self.tokenFieldWasEdited = false
                self.update(config: self.agent.config, tokenState: self.agent.cloudflareTokenState)
                self.update(status: self.agent.status)
                self.presentPersistenceError(error)
                completion?(false)
            }
        }
        if let temporaryAccessMinutes {
            agent.setTemporaryAccess(
                minutes: temporaryAccessMinutes,
                applying: prepared.config,
                tokenMutation: prepared.tokenMutation,
                completion: handleResult
            )
        } else {
            agent.persistSettingsAsync(
                config: prepared.config,
                tokenMutation: prepared.tokenMutation,
                completion: handleResult
            )
        }
    }

    @objc private func connectCloudflare() {
        guard !isBusy else { return }
        let token = SettingsTokenMutationPolicy.verificationToken(
            enteredToken: tokenField.stringValue,
            readState: tokenReadState
        )
        if token == nil, tokenReadState == .missing {
            cloudflareFeedbackLabel.stringValue = "No saved token exists. Paste a scoped token to verify."
            cloudflareFeedbackLabel.textColor = .systemRed
            return
        }
        loadCloudflareZones(showErrors: true, token: token)
    }

    @objc private func authorizeSavedToken() {
        guard !isBusy else { return }
        cancelCloudflareVerification()
        setAuthorizationBusy(true)
        cloudflareFeedbackLabel.stringValue = "Waiting for macOS Keychain authorization..."
        cloudflareFeedbackLabel.textColor = .secondaryLabelColor

        agent.authorizeSavedCloudflareToken { [weak self] result in
            guard let self else { return }
            self.setAuthorizationBusy(false)
            switch result {
            case .success(.noSavedToken):
                self.tokenReadState = .missing
                self.tokenFieldWasEdited = false
                self.synchronizeTokenField(with: .missing)
                self.cloudflareFeedbackLabel.stringValue = "No saved token was found. Paste a new scoped token."
                self.cloudflareFeedbackLabel.textColor = .secondaryLabelColor
            case .success(.authorized(let token)):
                self.tokenReadState = .available(token)
                self.tokenFieldWasEdited = false
                self.synchronizeTokenField(with: .available(token))
                self.cloudflareFeedbackLabel.stringValue = "Saved token authorized for this Gatebeam build."
                self.cloudflareFeedbackLabel.textColor = .systemGreen
                self.loadCloudflareZones(showErrors: false)
            case .success(.migratedLegacyToken(let token)):
                self.tokenReadState = .available(token)
                self.tokenFieldWasEdited = false
                self.synchronizeTokenField(with: .available(token))
                self.cloudflareFeedbackLabel.stringValue = "Legacy token secured and removed from the old Keychain item."
                self.cloudflareFeedbackLabel.textColor = .systemGreen
                self.loadCloudflareZones(showErrors: false)
            case .failure(let error):
                self.tokenReadState = .unavailable
                self.cloudflareFeedbackLabel.stringValue = error.localizedDescription
                self.cloudflareFeedbackLabel.textColor = .systemRed
                self.showAlert(
                    title: "Saved token authorization failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    @objc func confirmRemoveCloudflareToken() {
        guard !isBusy else { return }
        let alert = SettingsCloudflareTokenRemovalPrompt.makeAlert()
        guard let mutation = SettingsCloudflareTokenRemovalPrompt.mutation(
            for: tokenRemovalResponseProvider(alert)
        ) else {
            return
        }

        cancelCloudflareVerification()
        setPersistenceBusy(true)
        agent.applyCloudflareTokenMutationAsync(mutation) { [weak self] result in
            guard let self else { return }
            self.setPersistenceBusy(false)
            switch result {
            case .success:
                self.tokenReadState = .missing
                self.tokenFieldWasEdited = false
                self.synchronizeTokenField(with: .missing)
                self.cloudflareZones = []
                self.zonePopup.removeAllItems()
                self.zonePopup.addItem(withTitle: "No domains loaded")
                self.zonePopup.isEnabled = false
                self.cloudflareFeedbackLabel.stringValue = "Saved Cloudflare token removed."
                self.cloudflareFeedbackLabel.textColor = .secondaryLabelColor
            case .failure(let error):
                self.tokenReadState = self.agent.cloudflareTokenState
                self.showAlert(
                    title: "Could not remove Cloudflare token",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func synchronizeTokenField(with state: CloudflareTokenReadState) {
        isSynchronizingTokenField = true
        switch state {
        case .available(let token):
            tokenField.stringValue = token
        case .unknown, .missing, .unavailable:
            tokenField.stringValue = ""
        }
        isSynchronizingTokenField = false
    }

    private func applyPersistedTokenMutation(_ mutation: CloudflareTokenMutation) {
        switch mutation {
        case .keepExisting:
            tokenFieldWasEdited = false
            synchronizeTokenField(with: tokenReadState)
        case .replace(let token):
            tokenReadState = .available(token)
            tokenFieldWasEdited = false
            synchronizeTokenField(with: tokenReadState)
        case .explicitRemove:
            tokenReadState = .missing
            tokenFieldWasEdited = false
            synchronizeTokenField(with: tokenReadState)
        }
    }

    private func synchronizePersistedProxyField(from config: AppConfig) {
        guard customProxyField.stringValue != config.customProxyURL else { return }
        customProxyField.stringValue = config.customProxyURL
        updateProxyControls(validationMessage: proxyValidationMessage(for: config))
    }

    private func setPersistenceBusy(_ busy: Bool) {
        isPersisting = busy
        updateBusyControls()
        saveButton?.title = busy ? "Saving..." : "Save Changes"
    }

    private func setAuthorizationBusy(_ busy: Bool) {
        isAuthorizingToken = busy
        updateBusyControls()
    }

    private func updateBusyControls() {
        saveButton?.isEnabled = !isBusy
        checkButton?.isEnabled = !isBusy
        connectButton?.isEnabled = !isBusy
        authorizeTokenButton?.isEnabled = !isBusy
        removeTokenButton?.isEnabled = !isBusy
        temporaryAccessButton?.isEnabled = !isBusy
    }

    private var isBusy: Bool {
        isPersisting || isAuthorizingToken
    }

    private func presentPersistenceError(_ error: Error) {
        if case NetworkError.invalidProxyURL = error {
            presentProxyValidationError(NetworkError.invalidProxyURL(SettingsProxyValidation.formatMessage))
        } else {
            showAlert(title: "Could not save settings", message: error.localizedDescription)
        }
    }

    private func proxyValidationMessage(for config: AppConfig) -> String? {
        SettingsProxyValidation.message(for: config)
    }

    private func presentProxyValidationError(_ error: Error) {
        let message = error.localizedDescription
        proxyValidationLabel.stringValue = message
        proxyValidationLabel.toolTip = message
        proxyValidationLabel.isHidden = false
        customProxyField.window?.makeFirstResponder(customProxyField)
    }

    @objc private func proxyModeChanged() {
        cancelCloudflareVerification(
            feedback: "Cloudflare connection settings changed. Verify again."
        )
        updateProxyControls(validationMessage: proxyValidationMessage(for: formConfig()))
    }

    private func updateProxyControls(validationMessage: String? = nil) {
        let usesCustomProxy = ddnsProxyControl.selectedSegment == 2 || publicIPProxyControl.selectedSegment == 2
        customProxyField.isEnabled = usesCustomProxy
        customProxyField.alphaValue = usesCustomProxy ? 1 : 0.65

        if usesCustomProxy {
            proxyExplanationLabel.stringValue = "Custom applies only to services set to Custom. Direct bypasses macOS HTTP, SOCKS, PAC, and automatic proxy discovery, not VPN or TUN routing."
        } else {
            proxyExplanationLabel.stringValue = "Direct bypasses macOS HTTP, SOCKS, PAC, and automatic proxy discovery, not VPN or TUN routing."
        }

        proxyValidationLabel.stringValue = validationMessage ?? ""
        proxyValidationLabel.toolTip = validationMessage
        proxyValidationLabel.isHidden = validationMessage == nil
    }

    private func loadCloudflareZones(showErrors: Bool, token: String? = nil) {
        let candidate = token ?? SettingsTokenMutationPolicy.verificationToken(
            enteredToken: tokenField.stringValue,
            readState: tokenReadState
        )
        let pendingMutation = SettingsTokenMutationPolicy.saveMutation(
            enteredToken: tokenField.stringValue,
            fieldWasEdited: tokenFieldWasEdited,
            readState: tokenReadState
        )
        let request: CloudflareVerificationRequest
        do {
            request = try cloudflareVerification.begin(
                token: candidate,
                pendingTokenMutation: pendingMutation,
                formConfig: formConfig()
            )
        } catch {
            presentProxyValidationError(error)
            cloudflareFeedbackLabel.stringValue = error.localizedDescription
            cloudflareFeedbackLabel.textColor = .systemRed
            return
        }

        cloudflareFeedbackLabel.stringValue = "Verifying token and loading domains..."
        cloudflareFeedbackLabel.textColor = .secondaryLabelColor
        zonePopup.isEnabled = false

        agent.loadCloudflareZones(
            token: request.token,
            proxyMode: request.proxyMode,
            customProxyURL: request.customProxyURL
        ) { [weak self] result in
            guard let self else { return }
            guard self.cloudflareVerification.complete(request) else { return }
            switch result {
            case .success(let zones):
                self.applyCloudflareZones(zones)
                let pendingStorage: Bool
                if case .replace = request.pendingTokenMutation {
                    pendingStorage = true
                } else {
                    pendingStorage = false
                }
                self.cloudflareFeedbackLabel.stringValue = SettingsCloudflareZoneReadPresentation.message(
                    zoneCount: zones.count,
                    pendingStorage: pendingStorage
                )
                self.cloudflareFeedbackLabel.textColor = zones.isEmpty ? .systemOrange : .systemBlue
            case .failure(let error):
                self.cloudflareZones = []
                self.zonePopup.removeAllItems()
                self.zonePopup.addItem(withTitle: "No domains loaded")
                let message = SettingsCloudflareErrorPresentation.message(for: error)
                self.cloudflareFeedbackLabel.stringValue = message
                self.cloudflareFeedbackLabel.textColor = .systemRed
                if showErrors {
                    self.showAlert(title: "Cloudflare connection failed", message: message)
                }
            }
        }
    }

    private func cancelCloudflareVerification(feedback: String? = nil) {
        guard cloudflareVerification.cancelActive() else { return }
        if let feedback {
            cloudflareFeedbackLabel.stringValue = feedback
            cloudflareFeedbackLabel.textColor = .secondaryLabelColor
        }
    }

    private func applyCloudflareZones(_ zones: [CloudflareZoneSummary]) {
        cloudflareZones = zones
        zonePopup.removeAllItems()
        if zones.isEmpty {
            zonePopup.addItem(withTitle: "No domains loaded")
            zonePopup.isEnabled = false
            return
        }
        zonePopup.addItems(withTitles: zones.map(\.name))
        zonePopup.isEnabled = true
        if let index = zones.firstIndex(where: { $0.id == agent.config.cloudflareZoneID }) {
            zonePopup.selectItem(at: index)
        } else {
            zonePopup.selectItem(at: 0)
        }
        if let zone = selectedCloudflareZone() {
            recordNameField.stringValue = relativeRecordName(configuredRecordName, zoneName: zone.name)
        }
        updateRecordPreview()
    }

    @objc private func zoneChanged() {
        guard let zone = selectedCloudflareZone() else { return }
        let current = recordNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current.contains(".") {
            recordNameField.stringValue = relativeRecordName(configuredRecordName, zoneName: zone.name)
        }
        updateRecordPreview()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === recordNameField {
            updateRecordPreview()
        } else if field === tokenField, !isSynchronizingTokenField {
            cancelCloudflareVerification(
                feedback: "The token changed. Verify it again before trusting the result."
            )
            tokenFieldWasEdited = true
            let normalized = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                cloudflareFeedbackLabel.stringValue = "The saved token will be kept. Use the trash button to remove it."
                cloudflareFeedbackLabel.textColor = .secondaryLabelColor
            }
        } else if field === customProxyField {
            cancelCloudflareVerification(
                feedback: "Cloudflare connection settings changed. Verify again."
            )
            updateProxyControls(validationMessage: proxyValidationMessage(for: formConfig()))
        }
    }

    @objc private func showCloudflareHelp() {
        let alert = NSAlert()
        alert.messageText = "Cloudflare API Token"
        alert.informativeText = """
        1. Open Cloudflare > My Profile > API Tokens > Create Token.
        2. Start with Edit zone DNS, then make sure both permissions are present:
           - Zone/DNS/Edit
           - Zone/Zone/Read
        3. Under Zone Resources, choose Specific Zone for least privilege, or All Zones to list every domain.
        4. Leave Client IP filtering empty because a DDNS connection can change IP.
        5. Create the token, paste it here once, then click Verify.

        Domain means the Cloudflare zone, such as example.com. Subdomain is the relative part, such as remote; use @ for the root domain.

        The token is stored in a versioned macOS Keychain item restricted to Gatebeam's code-signing identity. Developer ID releases remain authorized across normal upgrades. Developer Preview builds are bound to the exact build; after replacing one, click Authorize Token to let macOS approve and rebind it. Legacy items are read only by that explicit action, then migrated and deleted.

        Do not use the Global API Key.
        """
        alert.addButton(withTitle: "Open Cloudflare")
        alert.addButton(withTitle: "Documentation")
        alert.addButton(withTitle: "Close")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/fundamentals/api/get-started/create-token/")!)
        }
    }

    private func selectedCloudflareZone() -> CloudflareZoneSummary? {
        let index = zonePopup.indexOfSelectedItem
        guard cloudflareZones.indices.contains(index) else { return nil }
        return cloudflareZones[index]
    }

    private func fullyQualifiedRecordName(_ value: String, zoneName: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if normalized.isEmpty || normalized == "@" || normalized == zoneName.lowercased() {
            return zoneName.lowercased()
        }
        if normalized.hasSuffix(".\(zoneName.lowercased())") {
            return normalized
        }
        return "\(normalized).\(zoneName.lowercased())"
    }

    private func relativeRecordName(_ recordName: String, zoneName: String) -> String {
        let normalizedRecord = recordName.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let normalizedZone = zoneName.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if normalizedRecord == normalizedZone { return "@" }
        let suffix = ".\(normalizedZone)"
        if normalizedRecord.hasSuffix(suffix) {
            return String(normalizedRecord.dropLast(suffix.count))
        }
        return normalizedRecord
    }

    private func updateRecordPreview() {
        guard let zone = selectedCloudflareZone() else {
            recordPreviewLabel.stringValue = "Full address will appear after a domain is selected."
            return
        }
        let fullName = fullyQualifiedRecordName(recordNameField.stringValue, zoneName: zone.name)
        recordPreviewLabel.stringValue = "Full address: \(fullName)"
    }

    @objc private func checkNow() {
        agent.runCheck()
    }

    @objc private func openForThirtyMinutes() {
        guard !isBusy else { return }
        var config = formConfig()
        config.remoteAccessEnabled = true
        let prepared: PreparedPersistence
        do {
            prepared = try preparePersistence(config)
        } catch {
            presentPersistenceError(error)
            return
        }
        performPersistence(
            prepared,
            temporaryAccessMinutes: 30,
            uiMutation: { [weak self] in
                self?.remoteEnabledButton.state = .on
            }
        )
    }

    @objc private func remoteAccessFormChanged() {
        refreshConnectionPresentation(status: agent.status)
    }

    @objc private func copyURL() {
        guard let url = RemoteConnectionURLPolicy.primaryCopyURL(
            remoteAccessEnabled: effectiveRemoteAccessEnabled,
            status: agent.status
        ) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func refreshConnectionPresentation(status: AppStatus) {
        let remoteAccessEnabled = effectiveRemoteAccessEnabled
        connectionLabel.stringValue = RemoteConnectionURLPolicy.displayURL(
            remoteAccessEnabled: remoteAccessEnabled,
            status: status
        )
        connectionLabel.toolTip = remoteAccessEnabled ? status.connectionURL : nil
        copyURLButton?.isEnabled = RemoteConnectionURLPolicy.primaryCopyURL(
            remoteAccessEnabled: remoteAccessEnabled,
            status: status
        ) != nil
    }

    private var effectiveRemoteAccessEnabled: Bool {
        remoteEnabledButton.state == .on && agent.config.remoteAccessEnabled
    }

    func refreshAppearance() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let contentView = window?.contentView else { return }
        contentView.layer?.backgroundColor = NSColor.resolvedCGColor(
            .windowBackgroundColor,
            for: contentView
        )
        if let footerView {
            footerView.layer?.backgroundColor = NSColor.resolvedCGColor(
                .windowBackgroundColor,
                for: footerView
            )
        }
        for view in settingsDescendants(of: contentView) {
            (view as? SettingsAppearanceRefreshing)?.refreshAppearanceLayers()
        }
        ddnsStatusView.refreshAppearanceLayers()
        routerStatusView.refreshAppearanceLayers()
        desktopStatusView.refreshAppearanceLayers()
        reachabilityStatusView.refreshAppearanceLayers()
        contentView.needsDisplay = true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func segment(for preference: MappingProtocolPreference) -> Int {
        switch preference {
        case .automatic: return 0
        case .pcp: return 1
        case .upnp: return 2
        case .natpmp: return 3
        case .disabled: return 4
        }
    }

    private func mappingPreference(for segment: Int) -> MappingProtocolPreference {
        switch segment {
        case 1: return .pcp
        case 2: return .upnp
        case 3: return .natpmp
        case 4: return .disabled
        default: return .automatic
        }
    }

    private func addressSegment(for preference: AddressFamilyPreference) -> Int {
        switch preference {
        case .ipv4: return 0
        case .dualStack: return 1
        case .ipv6: return 2
        }
    }

    private func addressPreference(for segment: Int) -> AddressFamilyPreference {
        switch segment {
        case 0: return .ipv4
        case 2: return .ipv6
        default: return .dualStack
        }
    }

    private func proxySegment(for mode: NetworkProxyMode) -> Int {
        switch mode {
        case .system: return 0
        case .direct: return 1
        case .custom: return 2
        }
    }

    private func proxyMode(for segment: Int) -> NetworkProxyMode {
        switch segment {
        case 1: return .direct
        case 2: return .custom
        default: return .system
        }
    }
}

private extension DateFormatter {
    static let settingsShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private final class StatusMetricView: NSView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var currentState: CheckState = .unknown

    init(title: String, width: CGFloat = SettingsLayout.cardContentWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        dot.wantsLayer = true
        dot.identifier = NSUserInterfaceItemIdentifier(
            "settings-status-dot-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.toolTip = title

        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(messageLabel)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(text)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        refreshAppearanceLayers()
    }

    func refreshAppearanceLayers() {
        dot.layer?.backgroundColor = NSColor.resolvedCGColor(
            color(for: currentState),
            for: dot
        )
    }

    private func color(for state: CheckState) -> NSColor {
        switch state {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .failed: return .systemRed
        case .checking: return .systemBlue
        case .disabled: return .tertiaryLabelColor
        case .unknown: return .separatorColor
        }
    }
}

private protocol SettingsAppearanceRefreshing: AnyObject {
    func refreshAppearanceLayers()
}

private final class SettingsAppearanceTrackingView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dispatchPrecondition(condition: .onQueue(.main))
        onEffectiveAppearanceChanged?()
    }
}

private final class SettingsPanelView: NSStackView, SettingsAppearanceRefreshing {
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
            .separatorColor.withAlphaComponent(0.25),
            for: self
        )
    }
}

private func settingsDescendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + settingsDescendants(of: $0) }
}

private extension NSColor {
    static func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
