import Foundation
import Darwin

enum SecureAtomicFileWriter {
    static func validateReadableJournal(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard fileAttributes[.type] as? FileAttributeType == .typeRegular,
              fileMode & 0o777 == 0o600,
              directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              directoryMode & 0o777 == 0o700 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Recovery journal permissions are unsafe at \(fileURL.path); expected file 0600 and directory 0700"
                ]
            )
        }
    }

    static func prepareParentDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            let ancestorURL = directoryURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: ancestorURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST {
                throw posixError("mkdir", path: directoryURL.path)
            }
        }
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw posixError("chmod", path: directoryURL.path)
        }
    }

    static func write(
        _ data: Data,
        to fileURL: URL,
        beforeRename: ((URL) throws -> Void)? = nil
    ) throws {
        try prepareParentDirectory(for: fileURL)
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError("open", path: temporaryURL.path)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("fchmod", path: temporaryURL.path)
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write", path: temporaryURL.path)
                }
                offset += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", path: temporaryURL.path)
        }
        try beforeRename?(temporaryURL)
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw posixError("rename", path: fileURL.path)
        }
        shouldRemoveTemporaryFile = false

        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw posixError("open", path: directoryURL.path)
        }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw posixError("fsync", path: directoryURL.path)
        }
    }

    static func removeIfPresent(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard unlink(fileURL.path) == 0 else {
            throw posixError("unlink", path: fileURL.path)
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("open", path: directoryURL.path)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync", path: directoryURL.path)
        }
    }

    private static func posixError(_ operation: String, path: String) -> Error {
        let code = Int(errno)
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(Int32(code))))"
            ]
        )
    }
}

enum AppConfigStoreError: Error, LocalizedError {
    case persistenceFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .persistenceFailed(let url, let error):
            return "Could not save configuration at \(url.path): \(error.localizedDescription)"
        }
    }
}

final class AppConfigStore {
    typealias DataWriter = (Data, URL) throws -> Void
    typealias DataReader = (URL) throws -> Data

    private let fileURL: URL
    private let mappingRecoveryURL: URL
    private let cleanupURL: URL?
    private let dataWriter: DataWriter
    private let recoveryDataWriter: DataWriter
    private let recoveryDataReader: DataReader
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    convenience init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(baseDirectory: baseURL)
    }

    convenience init(baseDirectory: URL) {
        // Keep the existing location so the Gatebeam rebrand does not discard
        // a working local configuration during upgrade.
        let appURL = baseDirectory.appendingPathComponent("RemoteControlNetwork", isDirectory: true)
        self.init(configURL: appURL.appendingPathComponent("config.json"))
    }

    init(
        configURL: URL,
        cleanupURL: URL? = nil,
        dataWriter: @escaping DataWriter = { data, url in
            try SecureAtomicFileWriter.write(data, to: url)
        },
        recoveryDataWriter: @escaping DataWriter = { data, url in
            try SecureAtomicFileWriter.write(data, to: url)
        },
        recoveryDataReader: @escaping DataReader = { url in
            try Data(contentsOf: url)
        }
    ) {
        self.fileURL = configURL
        self.mappingRecoveryURL = configURL
            .deletingPathExtension()
            .appendingPathExtension("mapping-recovery.json")
        self.cleanupURL = cleanupURL
        self.dataWriter = dataWriter
        self.recoveryDataWriter = recoveryDataWriter
        self.recoveryDataReader = recoveryDataReader
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try? SecureAtomicFileWriter.prepareParentDirectory(for: configURL)
    }

    static func isolatedTemporary() -> AppConfigStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gatebeam-ui-validation-\(UUID().uuidString)", isDirectory: true)
        let configURL = root
            .appendingPathComponent("RemoteControlNetwork", isDirectory: true)
            .appendingPathComponent("config.json")
        return AppConfigStore(configURL: configURL, cleanupURL: root)
    }

    func load() throws -> AppConfig {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch where !FileManager.default.fileExists(atPath: fileURL.path) {
            let config = AppConfig.default
            try save(config)
            return config
        } catch {
            throw AppConfigStoreError.persistenceFailed(fileURL, error)
        }

        let decoded: AppConfig
        do {
            decoded = try decoder.decode(AppConfig.self, from: data)
        } catch {
            let config = AppConfig.default
            try save(config)
            return config
        }

        let sanitized = sanitizedForStorage(decoded)
        if sanitized.customProxyURL != decoded.customProxyURL
            || sanitized.checkIntervalSeconds != decoded.checkIntervalSeconds {
            try save(sanitized)
        }
        return sanitized
    }

    func save(_ config: AppConfig) throws {
        let sanitized = sanitizedForStorage(config)
        do {
            let data = try encoder.encode(sanitized)
            try dataWriter(data, fileURL)
        } catch {
            throw AppConfigStoreError.persistenceFailed(fileURL, error)
        }
    }

    func removeTemporaryStorage() {
        guard let cleanupURL else { return }
        try? FileManager.default.removeItem(at: cleanupURL)
    }

    func loadMappingRecoveryJournal() throws -> [ActiveRouterMapping] {
        guard FileManager.default.fileExists(atPath: mappingRecoveryURL.path) else {
            return []
        }
        do {
            try SecureAtomicFileWriter.validateReadableJournal(at: mappingRecoveryURL)
            let data = try recoveryDataReader(mappingRecoveryURL)
            return try decoder.decode([ActiveRouterMapping].self, from: data)
        } catch {
            throw AppConfigStoreError.persistenceFailed(mappingRecoveryURL, error)
        }
    }

    func saveMappingRecoveryJournal(_ mappings: [ActiveRouterMapping]) throws {
        do {
            if mappings.isEmpty {
                try SecureAtomicFileWriter.removeIfPresent(mappingRecoveryURL)
                return
            }
            let data = try encoder.encode(mappings)
            try recoveryDataWriter(data, mappingRecoveryURL)
        } catch {
            throw AppConfigStoreError.persistenceFailed(mappingRecoveryURL, error)
        }
    }

    var location: URL {
        fileURL
    }

    var mappingRecoveryLocation: URL {
        mappingRecoveryURL
    }

    private func sanitizedForStorage(_ config: AppConfig) -> AppConfig {
        var sanitized = config.normalizedForPersistence()
        let usesCustomProxy = config.ddnsProxyMode == .custom || config.publicIPProxyMode == .custom
        guard usesCustomProxy else {
            sanitized.customProxyURL = ""
            return sanitized
        }

        do {
            sanitized.customProxyURL = try HTTPClient.validatedProxyURL(
                config.customProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            ).absoluteString
        } catch {
            sanitized.customProxyURL = ""
        }
        return sanitized
    }

}
