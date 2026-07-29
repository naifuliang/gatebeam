import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var configStore = isUIValidationMode
        ? AppConfigStore.isolatedTemporary()
        : AppConfigStore()
    private var isUIValidationMode: Bool {
        CommandLine.arguments.contains("--ui-validation")
    }
    private lazy var keychain = isUIValidationMode
        ? KeychainStore.isolatedValidationStore()
        : KeychainStore()
    private lazy var agent = NetworkAgent(
        configStore: configStore,
        keychain: keychain,
        sideEffectsEnabled: !isUIValidationMode
    )
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?
    private let statusPopover = NSPopover()
    private var statusPopoverController: StatusPopoverViewController?
    private var launchAgentMigrationError: LaunchAgentManagerError?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !isUIValidationMode {
            LaunchAgentManager().migrateLegacyUserState()
                .handleFailure { error in
                    self.launchAgentMigrationError = error
                }
        }
        setupStatusItem()
        setupAgent()
        if !isUIValidationMode {
            agent.start()
        }
        runLaunchValidationHooksIfNeeded()
        presentLaunchAgentMigrationErrorIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agent.stop()
        if isUIValidationMode {
            configStore.removeTemporaryStorage()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Gatebeam")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Gatebeam"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let controller = StatusPopoverViewController(
            agent: agent,
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) }
        )
        statusPopoverController = controller
        statusPopover.contentViewController = controller
        statusPopover.behavior = .transient
        statusPopover.animates = true
    }

    private func setupAgent() {
        agent.onStatusChanged = { [weak self] status in
            self?.render(status: status, config: self?.agent.config ?? .default)
        }
        agent.onConfigChanged = { [weak self] config in
            guard let self else { return }
            self.render(status: self.agent.status, config: config)
            self.settingsWindowController?.update(
                config: config,
                tokenState: self.agent.cloudflareTokenState
            )
            self.statusPopoverController?.update(config: config)
        }
    }

    private func render(status: AppStatus, config: AppConfig) {
        statusItem.button?.contentTintColor = menuBarColor(for: status, config: config)
        settingsWindowController?.update(status: status)
        statusPopoverController?.update(config: config)
        statusPopoverController?.update(status: status)
    }

    private func menuBarColor(for status: AppStatus, config: AppConfig) -> NSColor {
        if !config.remoteAccessEnabled {
            return .secondaryLabelColor
        }
        if status.routerStatus.state == .ok && status.ddnsStatus.state == .ok {
            return .systemGreen
        }
        if status.routerStatus.state == .failed || status.ddnsStatus.state == .failed || status.remoteDesktopStatus.state == .failed {
            return .systemRed
        }
        return .systemBlue
    }

    private func presentLaunchAgentMigrationErrorIfNeeded() {
        guard let error = launchAgentMigrationError else {
            return
        }
        launchAgentMigrationError = nil

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Start at Login needs attention"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Continue")
            if alert.runModal() == .alertFirstButtonReturn {
                self.openSettings()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown {
            statusPopover.performClose(nil)
        } else {
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func openSettings() {
        statusPopover.performClose(nil)
        if settingsWindowController == nil {
            var shouldLoadCloudflare = !isUIValidationMode
            if shouldLoadCloudflare {
                do {
                    try agent.loadCloudflareToken(
                        retryAfterFailure: false,
                        interaction: .background
                    )
                } catch {
                    // NetworkAgent publishes the Keychain failure into the settings status.
                    shouldLoadCloudflare = false
                }
            }
            settingsWindowController = SettingsWindowController(
                agent: agent,
                autoLoadCloudflare: !isUIValidationMode && shouldLoadCloudflare
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runLaunchValidationHooksIfNeeded() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard arguments.contains("--show-popover") || arguments.contains("--show-settings") else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if arguments.contains("--show-popover") {
                self.togglePopover()
            }
            if arguments.contains("--show-settings") {
                self.openSettings()
            }
        }
    }
}

private extension Result where Success == Void, Failure == LaunchAgentManagerError {
    func handleFailure(_ handler: (LaunchAgentManagerError) -> Void) {
        if case .failure(let error) = self {
            handler(error)
        }
    }
}
