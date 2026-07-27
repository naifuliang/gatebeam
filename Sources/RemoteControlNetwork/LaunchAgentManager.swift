import Foundation

final class LaunchAgentManager {
    private let label = "io.github.naifuliang.gatebeam.login"
    private let legacyLabel = "com.local.RemoteControlNetwork.login"

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard let agentsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("LaunchAgents", isDirectory: true) else {
            return
        }
        try? FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: agentsURL.appendingPathComponent("\(legacyLabel).plist"))
        let plistURL = agentsURL.appendingPathComponent("\(label).plist")
        let appPath = Bundle.main.bundlePath
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "RunAtLoad": true
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: [.atomic])
        }
    }

    private func uninstall() {
        guard let agentsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("LaunchAgents", isDirectory: true) else {
            return
        }
        let plistURL = agentsURL.appendingPathComponent("\(label).plist")
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: agentsURL.appendingPathComponent("\(legacyLabel).plist"))
    }
}
