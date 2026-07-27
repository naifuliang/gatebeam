import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = AppConfigStore()
    private let keychain = KeychainStore()
    private var isUIValidationMode: Bool {
        CommandLine.arguments.contains("--ui-validation")
    }
    private lazy var agent = NetworkAgent(
        configStore: configStore,
        keychain: keychain,
        sideEffectsEnabled: !isUIValidationMode
    )
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?
    private let statusPopover = NSPopover()
    private var statusPopoverController: StatusPopoverViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupAgent()
        if !isUIValidationMode {
            agent.start()
        }
        runLaunchValidationHooksIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agent.stop()
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
            self.settingsWindowController?.update(config: config, token: self.agent.cloudflareToken())
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
            settingsWindowController = SettingsWindowController(agent: agent)
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
