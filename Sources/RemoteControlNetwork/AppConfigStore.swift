import Foundation

final class AppConfigStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Keep the existing location so the Gatebeam rebrand does not discard
        // a working local configuration during upgrade.
        let appURL = baseURL.appendingPathComponent("RemoteControlNetwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        self.fileURL = appURL.appendingPathComponent("config.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            let config = AppConfig.default
            save(config)
            return config
        }

        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            return AppConfig.default
        }
    }

    func save(_ config: AppConfig) {
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    var location: URL {
        fileURL
    }
}
