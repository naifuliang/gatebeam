import Foundation
import Darwin

enum NetworkAgentError: Error, LocalizedError {
    case sideEffectsDisabled
    case superseded
    case transactionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sideEffectsDisabled:
            return "Network side effects are disabled"
        case .superseded:
            return "A newer settings revision replaced this operation"
        case .transactionFailed(let message):
            return message
        }
    }
}

private final class TokenLoadFlight {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<String, Error>?

    init() {
        group.enter()
    }

    func resolve(_ result: Result<String, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        group.leave()
    }

    func wait() throws -> String {
        group.wait()
        lock.lock()
        let resolved = result
        lock.unlock()
        guard let resolved else {
            throw NetworkAgentError.transactionFailed("Keychain token load ended without a result")
        }
        return try resolved.get()
    }
}

final class NetworkAgentScheduledTimer {
    private let lock = NSLock()
    private var cancelHandler: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        lock.lock()
        let handler = cancelHandler
        cancelHandler = nil
        lock.unlock()
        handler?()
    }

    deinit {
        cancel()
    }
}

final class EmergencyMappingJournal {
    typealias DataWriter = (Data, URL) throws -> Void
    typealias DataReader = (URL) throws -> Data

    private let fileURL: URL
    private let dataWriter: DataWriter
    private let dataReader: DataReader
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL,
        dataWriter: @escaping DataWriter = { data, url in
            try SecureAtomicFileWriter.write(data, to: url)
        },
        dataReader: @escaping DataReader = { url in
            try Data(contentsOf: url)
        }
    ) {
        self.fileURL = fileURL
        self.dataWriter = dataWriter
        self.dataReader = dataReader
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    static func systemDefault(namespace: String) -> EmergencyMappingJournal {
        systemJournal(namespace: namespace, directoryName: "Gatebeam")
    }

    static func systemFallback(namespace: String) -> EmergencyMappingJournal {
        systemJournal(namespace: namespace, directoryName: "GatebeamRecovery")
    }

    private static func systemJournal(
        namespace: String,
        directoryName: String
    ) -> EmergencyMappingJournal {
        let durableRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var namespaceHash: UInt64 = 14_695_981_039_346_656_037
        for byte in namespace.utf8 {
            namespaceHash ^= UInt64(byte)
            namespaceHash &*= 1_099_511_628_211
        }
        let fileURL = durableRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(
                "emergency-router-mappings-\(String(namespaceHash, radix: 16)).json"
            )
        return EmergencyMappingJournal(fileURL: fileURL)
    }

    func load() throws -> [ActiveRouterMapping] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> [ActiveRouterMapping] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try SecureAtomicFileWriter.validateReadableJournal(at: fileURL)
        return try decoder.decode([ActiveRouterMapping].self, from: dataReader(fileURL))
    }

    func save(_ mappings: [ActiveRouterMapping]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(mappings)
    }

    private func saveUnlocked(_ mappings: [ActiveRouterMapping]) throws {
        if mappings.isEmpty {
            try SecureAtomicFileWriter.removeIfPresent(fileURL)
            return
        }
        let data = try encoder.encode(mappings)
        try dataWriter(data, fileURL)
    }

    func merge(_ mappings: [ActiveRouterMapping]) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = try loadUnlocked()
        var merged = existing
        let known = Set(existing.map(\.identifier))
        merged.append(contentsOf: mappings.filter { !known.contains($0.identifier) })
        try saveUnlocked(merged)
    }

    var location: URL {
        fileURL
    }
}

enum NetworkAgentDependencyRole: String, Equatable {
    case cloudflareDDNS
    case publicIPProbe
}

struct NetworkAgentDependencyDescriptor: Equatable {
    let role: NetworkAgentDependencyRole
    let proxyMode: NetworkProxyMode
    let customProxyURL: String
    let httpClientType: String
}

private struct CloudflareDependency {
    let provider: CloudflareDNSProvider
    let descriptor: NetworkAgentDependencyDescriptor
}

private struct PublicIPDependency {
    let service: PublicIPService
    let descriptor: NetworkAgentDependencyDescriptor
}

private struct NetworkAgentDependencyFactory {
    func makeCloudflareProvider(
        proxyMode: NetworkProxyMode,
        customProxyURL: String
    ) throws -> CloudflareDependency {
        let http = try HTTPClient(proxyMode: proxyMode, customProxyURL: customProxyURL)
        return CloudflareDependency(
            provider: CloudflareDNSProvider(http: http),
            descriptor: descriptor(
                role: .cloudflareDDNS,
                proxyMode: proxyMode,
                customProxyURL: customProxyURL,
                http: http
            )
        )
    }

    func makePublicIPService(
        proxyMode: NetworkProxyMode,
        customProxyURL: String
    ) throws -> PublicIPDependency {
        let http = try HTTPClient(proxyMode: proxyMode, customProxyURL: customProxyURL)
        return PublicIPDependency(
            service: PublicIPService(http: http),
            descriptor: descriptor(
                role: .publicIPProbe,
                proxyMode: proxyMode,
                customProxyURL: customProxyURL,
                http: http
            )
        )
    }

    private func descriptor(
        role: NetworkAgentDependencyRole,
        proxyMode: NetworkProxyMode,
        customProxyURL: String,
        http: HTTPClient
    ) -> NetworkAgentDependencyDescriptor {
        let normalizedURL: String
        if proxyMode == .custom,
           let url = try? HTTPClient.validatedProxyURL(customProxyURL) {
            normalizedURL = url.absoluteString
        } else {
            normalizedURL = ""
        }
        return NetworkAgentDependencyDescriptor(
            role: role,
            proxyMode: proxyMode,
            customProxyURL: normalizedURL,
            httpClientType: String(describing: type(of: http))
        )
    }
}

final class NetworkAgent {
    private let configStore: AppConfigStore
    private let keychain: KeychainStore
    private let dependencyFactory = NetworkAgentDependencyFactory()
    private let localNetworkService: LocalNetworkServicing
    private let routerMappingService: RouterMappingServicing
    private let injectedPublicIPServiceFactory: ((AppConfig) throws -> PublicIPServicing)?
    private let emergencyMappingJournal: EmergencyMappingJournal
    private let fallbackMappingJournal: EmergencyMappingJournal
    private let setLoginItemEnabled: (Bool) -> Result<Void, LaunchAgentManagerError>
    private let stateQueue = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.state")
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let workQueue = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.work", qos: .utility)
    private let transactionQueue = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.transaction", qos: .userInitiated)
    private let transactionQueueKey = DispatchSpecificKey<UInt8>()
    private let sideEffectGate = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.side-effect-gate")
    private let keychainReadQueue = DispatchQueue(
        label: "RemoteControlNetwork.NetworkAgent.keychain-read",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let sideEffectsEnabled: Bool
    private let checkExecutionObserver: (() -> Void)?
    private let sideEffectWillStartObserver: ((String) -> Void)?
    private let nowProvider: () -> Date
    private let expirationTimerScheduler:
        (Date, @escaping () -> Void) -> NetworkAgentScheduledTimer
    private var timer: DispatchSourceTimer?
    private var expirationTimer: NetworkAgentScheduledTimer?
    private var expirationRetryNotBefore: Date?
    private var isRunning = false
    private var cachedCloudflareToken: String?
    private var keychainReadFailure: Error?
    private var tokenLoadFlight: TokenLoadFlight?
    private var launchAgentErrorMessage: String?
    private var keychainErrorMessage: String?
    private var configPersistenceErrorMessage: String?
    private var routerMappingErrorMessage: String?
    private var configRevision: UInt64 = 0
    private var activeConfigMutationRevision: UInt64?
    private var checkInFlight = false
    private var checkPending = false
    private var pendingCheckRetriesKeychain = false
    private var mappingRecoveryMappings: [ActiveRouterMapping]
    private var recoveryStateUnknown = false
    private var configStateUnknown = false
    private var storedStatus = AppStatus.initial
    private var storedConfig: AppConfig
    private var storedStatusCallback: ((AppStatus) -> Void)?
    private var storedConfigCallback: ((AppConfig) -> Void)?

    var status: AppStatus {
        withState { storedStatus }
    }

    var config: AppConfig {
        withState { storedConfig }
    }

    var onStatusChanged: ((AppStatus) -> Void)? {
        get { withState { storedStatusCallback } }
        set { withState { storedStatusCallback = newValue } }
    }

    var onConfigChanged: ((AppConfig) -> Void)? {
        get { withState { storedConfigCallback } }
        set { withState { storedConfigCallback = newValue } }
    }

    init(
        configStore: AppConfigStore,
        keychain: KeychainStore,
        initialConfig: AppConfig? = nil,
        sideEffectsEnabled: Bool = true,
        checkExecutionObserver: (() -> Void)? = nil,
        sideEffectWillStartObserver: ((String) -> Void)? = nil,
        loginItemSetter: ((Bool) -> Result<Void, LaunchAgentManagerError>)? = nil,
        localNetworkService: LocalNetworkServicing = LocalNetworkService(),
        routerMappingService: RouterMappingServicing = RouterMappingService(),
        publicIPServiceFactory: ((AppConfig) throws -> PublicIPServicing)? = nil,
        emergencyMappingJournal: EmergencyMappingJournal? = nil,
        fallbackMappingJournal: EmergencyMappingJournal? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        expirationTimerScheduler:
            ((Date, @escaping () -> Void) -> NetworkAgentScheduledTimer)? = nil
    ) {
        let effectiveConfigStore = sideEffectsEnabled ? configStore : AppConfigStore.isolatedTemporary()
        let effectiveEmergencyJournal = emergencyMappingJournal
            ?? .systemDefault(namespace: effectiveConfigStore.location.path)
        let effectiveFallbackJournal = fallbackMappingJournal
            ?? .systemFallback(namespace: effectiveConfigStore.location.path)
        self.configStore = effectiveConfigStore
        self.keychain = keychain
        self.sideEffectsEnabled = sideEffectsEnabled
        self.checkExecutionObserver = checkExecutionObserver
        self.sideEffectWillStartObserver = sideEffectWillStartObserver
        self.nowProvider = nowProvider
        self.expirationTimerScheduler = expirationTimerScheduler
            ?? Self.scheduleSystemExpirationTimer
        self.localNetworkService = localNetworkService
        self.routerMappingService = routerMappingService
        self.injectedPublicIPServiceFactory = publicIPServiceFactory
        self.emergencyMappingJournal = effectiveEmergencyJournal
        self.fallbackMappingJournal = effectiveFallbackJournal
        self.setLoginItemEnabled = loginItemSetter ?? { enabled in
            LaunchAgentManager().setEnabled(enabled)
        }

        var loadedConfig = (initialConfig ?? .default).normalizedForPersistence()
        var recoveryMappings: [ActiveRouterMapping] = []
        var loadErrorMessage: String?
        var loadedRecoveryStateUnknown = false
        var loadedConfigStateUnknown = false
        if initialConfig == nil, sideEffectsEnabled {
            do {
                loadedConfig = try effectiveConfigStore.load()
            } catch {
                loadedConfigStateUnknown = true
                loadedRecoveryStateUnknown = true
                loadErrorMessage = [
                    "Configuration could not be decoded or read.",
                    "Back up the damaged config before restoring a known-good copy.",
                    error.localizedDescription
                ].joined(separator: "\n")
            }
        }
        if sideEffectsEnabled {
            do {
                recoveryMappings = try effectiveConfigStore.loadMappingRecoveryJournal()
                let trackedIDs = Set(loadedConfig.activeRouterMappings.map(\.identifier))
                recoveryMappings.removeAll { trackedIDs.contains($0.identifier) }
                try effectiveConfigStore.saveMappingRecoveryJournal(recoveryMappings)
            } catch {
                loadedRecoveryStateUnknown = true
                loadErrorMessage = [loadErrorMessage, "Primary recovery journal: \(error.localizedDescription)"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            do {
                var emergencyMappings = try effectiveEmergencyJournal.load()
                let trackedIDs = Set(loadedConfig.activeRouterMappings.map(\.identifier))
                emergencyMappings.removeAll { trackedIDs.contains($0.identifier) }
                try effectiveEmergencyJournal.save(emergencyMappings)
                let known = Set(recoveryMappings.map(\.identifier))
                recoveryMappings.append(
                    contentsOf: emergencyMappings.filter { !known.contains($0.identifier) }
                )
            } catch {
                loadedRecoveryStateUnknown = true
                loadErrorMessage = [loadErrorMessage, "Emergency recovery journal: \(error.localizedDescription)"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            do {
                var fallbackMappings = try effectiveFallbackJournal.load()
                let trackedIDs = Set(loadedConfig.activeRouterMappings.map(\.identifier))
                fallbackMappings.removeAll { trackedIDs.contains($0.identifier) }
                try effectiveFallbackJournal.save(fallbackMappings)
                let known = Set(recoveryMappings.map(\.identifier))
                recoveryMappings.append(
                    contentsOf: fallbackMappings.filter { !known.contains($0.identifier) }
                )
            } catch {
                loadedRecoveryStateUnknown = true
                loadErrorMessage = [loadErrorMessage, "Fallback recovery journal: \(error.localizedDescription)"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
        }
        if !recoveryMappings.isEmpty {
            let trackedIDs = Set(loadedConfig.activeRouterMappings.map(\.identifier))
            loadedConfig.activeRouterMappings.append(
                contentsOf: recoveryMappings.filter { !trackedIDs.contains($0.identifier) }
            )
        }
        self.storedConfig = loadedConfig
        self.mappingRecoveryMappings = recoveryMappings
        self.recoveryStateUnknown = loadedRecoveryStateUnknown
        self.configStateUnknown = loadedConfigStateUnknown
        self.configPersistenceErrorMessage = loadErrorMessage
        if loadedRecoveryStateUnknown {
            self.routerMappingErrorMessage = Self.unknownRecoveryStateMessage(
                detail: loadErrorMessage ?? "A recovery journal could not be verified."
            )
        } else if !recoveryMappings.isEmpty {
            self.routerMappingErrorMessage = "Gatebeam recovered router mappings that still require cleanup."
        }
        self.storedStatus.settingsErrorMessage = self.routerMappingErrorMessage ?? loadErrorMessage
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
        transactionQueue.setSpecific(key: transactionQueueKey, value: 1)
    }

    deinit {
        if !sideEffectsEnabled {
            configStore.removeTemporaryStorage()
        }
    }

    func start() {
        guard sideEffectsEnabled else { return }
        scheduleCheck(retryKeychainAfterFailure: false)
        withState {
            isRunning = true
            restartTimerOnStateQueue()
            restartExpirationTimerOnStateQueue()
        }
    }

    func stop() {
        sideEffectGate.sync {
            withState {
                timer?.cancel()
                timer = nil
                expirationTimer?.cancel()
                expirationTimer = nil
                expirationRetryNotBefore = nil
                isRunning = false
                configRevision &+= 1
                activeConfigMutationRevision = nil
                checkPending = false
                pendingCheckRetriesKeychain = false
            }
        }
    }

    func runCheck() {
        guard sideEffectsEnabled else { return }
        scheduleCheck(retryKeychainAfterFailure: true)
    }

    func saveConfig(_ newConfig: AppConfig) {
        let appliedRequest = newConfig.normalizedForPersistence()
        transactionQueue.async {
            let mutationRevision = self.beginConfigMutation()
            defer { self.endConfigMutation(mutationRevision) }
            var rollbackConfig = self.config
            var appliedConfig = appliedRequest
            guard self.sideEffectsEnabled else {
                self.withState {
                    self.commitConfigOnStateQueue(appliedRequest, advanceRevision: false)
                }
                return
            }

            do {
                try self.requireKnownConfigState()
                try self.requireCurrentRevision(mutationRevision)
                if self.mappingLifecycleChanged(from: rollbackConfig, to: appliedConfig) {
                    rollbackConfig = try self.revokeMappingsBeforeConfigChange(
                        rollbackConfig,
                        expectedRevision: mutationRevision
                    )
                    appliedConfig.activeRouterMappings = []
                    appliedConfig.ipv6PinholeID = nil
                }
                try self.requireCurrentRevision(mutationRevision)
                try self.persistConfigOnly(
                    appliedConfig,
                    previousConfig: rollbackConfig,
                    expectedRevision: mutationRevision
                )
                try self.finishConfigCommit(
                    appliedConfig,
                    previousConfig: rollbackConfig,
                    expectedRevision: mutationRevision
                )
            } catch {
                guard !self.isSuperseded(error) else { return }
                self.publishPersistenceFailure(error, rollbackConfig: self.config)
            }
        }
    }

    @discardableResult
    func persistSettings(config newConfig: AppConfig, token: String) throws -> AppConfig {
        return try withTransaction {
            let mutationRevision = beginConfigMutation()
            defer { endConfigMutation(mutationRevision) }
            return try persistSettingsOnTransactionQueue(
                config: newConfig.normalizedForPersistence(),
                token: token,
                mutationRevision: mutationRevision
            )
        }
    }

    func persistSettingsAsync(
        config newConfig: AppConfig,
        token: String,
        completion: @escaping (Result<AppConfig, Error>) -> Void
    ) {
        transactionQueue.async {
            let mutationRevision = self.beginConfigMutation()
            defer { self.endConfigMutation(mutationRevision) }
            let result = Result {
                try self.persistSettingsOnTransactionQueue(
                    config: newConfig.normalizedForPersistence(),
                    token: token,
                    mutationRevision: mutationRevision
                )
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func persistSettingsOnTransactionQueue(
        config newConfig: AppConfig,
        token: String,
        mutationRevision: UInt64
    ) throws -> AppConfig {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sideEffectsEnabled else {
            return withState {
                cachedCloudflareToken = normalizedToken
                commitConfigOnStateQueue(newConfig, advanceRevision: false)
                return newConfig
            }
        }

        return try withTransaction {
            try requireKnownConfigState()
            try requireCurrentRevision(mutationRevision)
            let previousToken = try withMutationSideEffect(
                revision: mutationRevision,
                label: "keychain.read"
            ) {
                try loadCloudflareToken(
                    retryAfterFailure: true,
                    interaction: .userInitiated
                )
            }
            var previousConfig = config
            var appliedConfig = newConfig
            if mappingLifecycleChanged(from: previousConfig, to: appliedConfig) {
                previousConfig = try revokeMappingsBeforeConfigChange(
                    previousConfig,
                    expectedRevision: mutationRevision
                )
                appliedConfig.activeRouterMappings = []
                appliedConfig.ipv6PinholeID = nil
            }
            let tokenChanged = previousToken != normalizedToken
            var tokenWritten = false
            var loginItemChanged = false
            var configWritten = false
            var failureArea = "Keychain"

            do {
                if tokenChanged {
                    try withMutationSideEffect(
                        revision: mutationRevision,
                        label: "keychain.write"
                    ) {
                        try writeTokenToKeychain(normalizedToken)
                    }
                    tokenWritten = true
                }
                failureArea = "Start at Login"
                if previousConfig.startAtLogin != appliedConfig.startAtLogin {
                    try withMutationSideEffect(
                        revision: mutationRevision,
                        label: "login-item.write"
                    ) {
                        try setLoginItemEnabled(appliedConfig.startAtLogin).get()
                    }
                    loginItemChanged = true
                }
                failureArea = "configuration"
                try withMutationSideEffect(
                    revision: mutationRevision,
                    label: "config.write"
                ) {
                    try configStore.save(appliedConfig)
                }
                configWritten = true
                try requireCurrentRevision(mutationRevision)
            } catch {
                var rollbackFailures: [String] = []
                if configWritten {
                    do {
                        try withRecoverySideEffect(label: "config.rollback") {
                            try configStore.save(previousConfig)
                        }
                    } catch {
                        rollbackFailures.append("configuration: \(error.localizedDescription)")
                    }
                }
                if loginItemChanged {
                    let rollbackResult = withRecoverySideEffect(label: "login-item.rollback") {
                        setLoginItemEnabled(previousConfig.startAtLogin)
                    }
                    if case .failure(let rollbackError) = rollbackResult {
                        rollbackFailures.append("login item: \(rollbackError.localizedDescription)")
                    }
                }
                if tokenWritten {
                    do {
                        try withRecoverySideEffect(label: "keychain.rollback") {
                            try writeTokenToKeychain(previousToken)
                        }
                    } catch {
                        rollbackFailures.append("Keychain token: \(error.localizedDescription)")
                    }
                }

                withState {
                    guard configRevision == mutationRevision else { return }
                    if rollbackFailures.isEmpty {
                        cachedCloudflareToken = previousToken
                    } else {
                        cachedCloudflareToken = nil
                    }
                    if failureArea == "Keychain" {
                        let action = normalizedToken.isEmpty ? "delete" : "save"
                        keychainErrorMessage = "Could not \(action) the Cloudflare token: \(error.localizedDescription)"
                    } else if failureArea == "Start at Login" {
                        launchAgentErrorMessage = error.localizedDescription
                    } else {
                        configPersistenceErrorMessage = error.localizedDescription
                    }
                    publishCurrentSettingsErrorOnStateQueue()
                    commitConfigOnStateQueue(previousConfig, advanceRevision: false)
                }
                if rollbackFailures.isEmpty {
                    throw error
                }
                throw NetworkAgentError.transactionFailed(
                    "\(error.localizedDescription) Rollback also failed: \(rollbackFailures.joined(separator: "; "))."
                )
            }

            let committed = withState {
                guard configRevision == mutationRevision else { return false }
                cachedCloudflareToken = normalizedToken
                keychainReadFailure = nil
                keychainErrorMessage = nil
                configPersistenceErrorMessage = nil
                launchAgentErrorMessage = nil
                if !recoveryStateUnknown {
                    routerMappingErrorMessage = nil
                }
                commitConfigOnStateQueue(appliedConfig, advanceRevision: false)
                publishCurrentSettingsErrorOnStateQueue()
                return true
            }
            guard committed else { throw NetworkAgentError.superseded }
            finishPostCommit(previousConfig: previousConfig, appliedConfig: appliedConfig)
            return appliedConfig
        }
    }

    @discardableResult
    func applyStartAtLoginResult(
        _ result: Result<Void, LaunchAgentManagerError>,
        requestedConfig: AppConfig,
        previousConfig: AppConfig
    ) -> AppConfig {
        withState {
            var appliedConfig = requestedConfig
            switch result {
            case .success:
                launchAgentErrorMessage = nil
            case .failure(let error):
                appliedConfig.startAtLogin = previousConfig.startAtLogin
                launchAgentErrorMessage = error.localizedDescription
            }
            publishCurrentSettingsErrorOnStateQueue()
            return appliedConfig
        }
    }

    func setRemoteAccessEnabled(_ enabled: Bool) {
        var next = config
        next.remoteAccessEnabled = enabled
        if !enabled {
            next.accessExpiresAt = nil
        }
        saveConfig(next)
    }

    func setTemporaryAccess(minutes: Int) {
        var next = config
        next.remoteAccessEnabled = true
        next.accessExpiresAt = nowProvider().addingTimeInterval(TimeInterval(minutes * 60))
        saveConfig(next)
    }

    func cloudflareToken() -> String {
        withState { cachedCloudflareToken ?? "" }
    }

    @discardableResult
    func loadCloudflareToken(
        retryAfterFailure: Bool = true,
        interaction: KeychainInteraction = .background
    ) throws -> String {
        guard sideEffectsEnabled else { return "" }

        enum Decision {
            case cached(String)
            case latched(Error)
            case wait(TokenLoadFlight)
            case perform(TokenLoadFlight)
        }

        let decision: Decision = withState {
            if let cachedCloudflareToken {
                return .cached(cachedCloudflareToken)
            }
            if let tokenLoadFlight {
                return .wait(tokenLoadFlight)
            }
            if let keychainReadFailure, !retryAfterFailure {
                return .latched(keychainReadFailure)
            }
            let flight = TokenLoadFlight()
            tokenLoadFlight = flight
            return .perform(flight)
        }

        switch decision {
        case .cached(let token):
            return token
        case .latched(let error):
            throw error
        case .wait(let flight):
            return try flight.wait()
        case .perform(let flight):
            let result = Result {
                try keychain.get(
                    account: "cloudflare-api-token",
                    interaction: interaction
                ) ?? ""
            }
            withState {
                tokenLoadFlight = nil
                switch result {
                case .success(let token):
                    cachedCloudflareToken = token
                    keychainReadFailure = nil
                    keychainErrorMessage = nil
                case .failure(let error):
                    cachedCloudflareToken = nil
                    keychainReadFailure = error
                    keychainErrorMessage = "Could not read the Cloudflare token: \(error.localizedDescription)"
                }
                publishCurrentSettingsErrorOnStateQueue()
            }
            flight.resolve(result)
            return try result.get()
        }
    }

    func saveCloudflareToken(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sideEffectsEnabled else {
            withState {
                cachedCloudflareToken = normalized
                keychainReadFailure = nil
            }
            return
        }

        try withTransaction {
            let current = try loadCloudflareToken(
                retryAfterFailure: true,
                interaction: .userInitiated
            )
            guard current != normalized else { return }
            do {
                try writeTokenToKeychain(normalized)
                withState {
                    cachedCloudflareToken = normalized
                    keychainReadFailure = nil
                    keychainErrorMessage = nil
                    publishCurrentSettingsErrorOnStateQueue()
                }
            } catch {
                withState {
                    let action = normalized.isEmpty ? "delete" : "save"
                    keychainErrorMessage = "Could not \(action) the Cloudflare token: \(error.localizedDescription)"
                    publishCurrentSettingsErrorOnStateQueue()
                }
                throw error
            }
        }
    }

    func authorizeSavedCloudflareToken(
        completion: @escaping (Result<KeychainAuthorizationOutcome, Error>) -> Void
    ) {
        guard sideEffectsEnabled else {
            DispatchQueue.main.async {
                completion(.success(.noSavedToken))
            }
            return
        }

        keychainReadQueue.async {
            let result = Result {
                try self.keychain.authorizeCurrentOrMigrateLegacy(
                    account: "cloudflare-api-token"
                )
            }
            self.withState {
                switch result {
                case .success(let outcome):
                    self.cachedCloudflareToken = outcome.token
                    self.keychainReadFailure = nil
                    self.keychainErrorMessage = nil
                case .failure(let error):
                    self.cachedCloudflareToken = nil
                    self.keychainReadFailure = error
                    self.keychainErrorMessage = "Could not authorize the saved Cloudflare token: \(error.localizedDescription)"
                }
                self.publishCurrentSettingsErrorOnStateQueue()
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    var savedTokenNeedsAuthorization: Bool {
        withState {
            (keychainReadFailure as? KeychainError)?.requiresUserAuthorization == true
        }
    }

    func networkDependencyDescriptors() throws -> [NetworkAgentDependencyDescriptor] {
        let cloudflare = try dependencyFactory.makeCloudflareProvider(
            proxyMode: config.ddnsProxyMode,
            customProxyURL: config.customProxyURL
        )
        let publicIP = try dependencyFactory.makePublicIPService(
            proxyMode: config.publicIPProxyMode,
            customProxyURL: config.customProxyURL
        )
        return [cloudflare.descriptor, publicIP.descriptor]
    }

    func loadCloudflareZones(
        token: String? = nil,
        proxyMode: NetworkProxyMode? = nil,
        customProxyURL: String? = nil,
        completion: @escaping (Result<[CloudflareZoneSummary], Error>) -> Void
    ) {
        guard sideEffectsEnabled else {
            DispatchQueue.main.async {
                completion(.failure(NetworkAgentError.sideEffectsDisabled))
            }
            return
        }
        keychainReadQueue.async {
            do {
                let suppliedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let candidate = suppliedToken.isEmpty
                    ? try self.loadCloudflareToken(
                        retryAfterFailure: true,
                        interaction: .userInitiated
                    )
                    : suppliedToken
                guard !candidate.isEmpty else {
                    throw CloudflareError.configuration("Cloudflare API token is missing")
                }
                let config = self.config
                self.workQueue.async {
                    do {
                        let provider = try self.makeDNSProvider(
                            mode: proxyMode ?? config.ddnsProxyMode,
                            customProxyURL: customProxyURL ?? config.customProxyURL
                        )
                        let zones = try provider.listZones(token: candidate)
                        DispatchQueue.main.async {
                            completion(.success(zones))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func validateCloudflareConfiguration(
        zoneID: String,
        recordName: String,
        token: String? = nil,
        proxyMode: NetworkProxyMode? = nil,
        customProxyURL: String? = nil,
        completion: @escaping (Result<CloudflareValidationResult, Error>) -> Void
    ) {
        guard sideEffectsEnabled else {
            DispatchQueue.main.async {
                completion(.failure(NetworkAgentError.sideEffectsDisabled))
            }
            return
        }
        keychainReadQueue.async {
            do {
                let suppliedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let candidate = suppliedToken.isEmpty
                    ? try self.loadCloudflareToken(
                        retryAfterFailure: true,
                        interaction: .userInitiated
                    )
                    : suppliedToken
                guard !candidate.isEmpty else {
                    throw CloudflareError.configuration("Cloudflare API token is missing")
                }
                let config = self.config
                self.workQueue.async {
                    do {
                        let provider = try self.makeDNSProvider(
                            mode: proxyMode ?? config.ddnsProxyMode,
                            customProxyURL: customProxyURL ?? config.customProxyURL
                        )
                        let result = try provider.validateConfiguration(
                            zoneID: zoneID,
                            recordName: recordName,
                            token: candidate
                        )
                        DispatchQueue.main.async {
                            completion(.success(result))
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func reloadAllRecoverySources(
        config: AppConfig
    ) throws -> [ActiveRouterMapping] {
        let primary: [ActiveRouterMapping]
        let emergency: [ActiveRouterMapping]
        let fallback: [ActiveRouterMapping]
        do {
            primary = try configStore.loadMappingRecoveryJournal()
        } catch {
            throw NetworkAgentError.transactionFailed(
                "Primary recovery journal: \(error.localizedDescription)"
            )
        }
        do {
            emergency = try emergencyMappingJournal.load()
        } catch {
            throw NetworkAgentError.transactionFailed(
                "Emergency recovery journal: \(error.localizedDescription)"
            )
        }
        do {
            fallback = try fallbackMappingJournal.load()
        } catch {
            throw NetworkAgentError.transactionFailed(
                "Fallback recovery journal: \(error.localizedDescription)"
            )
        }
        let sources = [primary, emergency, fallback]
        let trackedIDs = Set(config.activeRouterMappings.map(\.identifier))
        var recovered = withState { mappingRecoveryMappings }
        var knownIDs = Set(recovered.map(\.identifier))
        for source in sources {
            for mapping in source
            where !trackedIDs.contains(mapping.identifier)
                && !knownIDs.contains(mapping.identifier) {
                recovered.append(mapping)
                knownIDs.insert(mapping.identifier)
            }
        }
        withState {
            mappingRecoveryMappings = recovered
            restartExpirationTimerOnStateQueue()
        }
        return recovered
    }

    private func saveAllRecoveryJournals(
        _ mappings: [ActiveRouterMapping]
    ) throws {
        var errors: [String] = []
        do {
            try configStore.saveMappingRecoveryJournal(mappings)
        } catch {
            errors.append("Primary recovery journal: \(error.localizedDescription)")
        }
        do {
            try emergencyMappingJournal.save(mappings)
        } catch {
            errors.append("Emergency recovery journal: \(error.localizedDescription)")
        }
        do {
            try fallbackMappingJournal.save(mappings)
        } catch {
            errors.append("Fallback recovery journal: \(error.localizedDescription)")
        }
        guard errors.isEmpty else {
            throw NetworkAgentError.transactionFailed(errors.joined(separator: "\n"))
        }
    }

    private static func unknownRecoveryStateMessage(detail: String) -> String {
        [
            "Router recovery state could not be verified. Gatebeam will not create a new mapping.",
            "Back up the damaged file, then restore a known-good config or repair the journal. Remove recovery data only after confirming that the router rule is closed, then run Check Now.",
            detail
        ].joined(separator: "\n")
    }

    private func publishUnknownRecoveryState(
        detail: String,
        status: inout AppStatus
    ) {
        let message = Self.unknownRecoveryStateMessage(detail: detail)
        status.ddnsStatus = .disabled("Waiting for recovery journal repair")
        status.routerStatus = .failed(
            "Router recovery state is unknown",
            detail: message
        )
        status.remoteDesktopStatus = .warning(
            "No new mapping was created",
            detail: "Repair the recovery journal, then run Check Now."
        )
        status.externalReachabilityStatus = .disabled("Waiting for recovery journal repair")
        status.lastCheckedAt = Date()
        withState {
            recoveryStateUnknown = true
            routerMappingErrorMessage = message
            status.settingsErrorMessage = settingsErrorMessage
            publishOnStateQueue(status)
        }
    }

    private func performCheck(
        config initialConfig: AppConfig,
        revision: UInt64,
        tokenResult: Result<String, Error>
    ) {
        guard sideEffectsEnabled, isCurrentRevision(revision) else { return }
        checkExecutionObserver?()

        var next = AppStatus.initial
        next.settingsErrorMessage = withState { settingsErrorMessage }
        var workingConfig = initialConfig
        var configChanged = false
        var uncheckpointedMappings: [ActiveRouterMapping] = []

        var recoveredMappings = withState { mappingRecoveryMappings }
        if withState({ recoveryStateUnknown }) {
            do {
                if withState({ configStateUnknown }) {
                    workingConfig = try configStore.load()
                    withState {
                        configStateUnknown = false
                        storedConfig = workingConfig
                        notifyConfigChangedOnStateQueue(workingConfig)
                    }
                }
                recoveredMappings = try reloadAllRecoverySources(config: workingConfig)
                if recoveredMappings.isEmpty {
                    try saveAllRecoveryJournals([])
                    withState {
                        recoveryStateUnknown = false
                        routerMappingErrorMessage = nil
                        configPersistenceErrorMessage = nil
                    }
                }
            } catch {
                publishUnknownRecoveryState(
                    detail: error.localizedDescription,
                    status: &next
                )
                return
            }
        }
        if !recoveredMappings.isEmpty {
            do {
                let report = try withCurrentCheckSideEffect(
                    revision: revision,
                    label: "router.recovery.delete"
                ) {
                    routerMappingService.removeMappings(recoveredMappings)
                }
                do {
                    try saveAllRecoveryJournals(report.remainingMappings)
                } catch {
                    withState {
                        recoveryStateUnknown = true
                    }
                    throw error
                }
                withState {
                    mappingRecoveryMappings = report.remainingMappings
                    configPersistenceErrorMessage = nil
                    restartExpirationTimerOnStateQueue()
                }
                let removedIDs = Set(report.succeededMappings.map(\.identifier))
                workingConfig.activeRouterMappings.removeAll {
                    removedIDs.contains($0.identifier)
                }
                configChanged = !report.succeededMappings.isEmpty
                guard report.allSucceeded else {
                    throw NetworkAgentError.transactionFailed(
                        [
                            "Recovered router mappings still need cleanup:",
                            report.failureDescription
                        ].filter { !$0.isEmpty }.joined(separator: "\n")
                    )
                }
                withState {
                    recoveryStateUnknown = false
                    routerMappingErrorMessage = nil
                }
            } catch {
                guard !isSuperseded(error) else { return }
                if withState({ recoveryStateUnknown }) {
                    publishUnknownRecoveryState(
                        detail: error.localizedDescription,
                        status: &next
                    )
                    return
                }
                next.ddnsStatus = .disabled("Waiting for router cleanup")
                next.routerStatus = .failed(
                    "Recovered router mappings still need cleanup",
                    detail: error.localizedDescription
                )
                next.remoteDesktopStatus = .warning(
                    "No new mapping was created",
                    detail: "Gatebeam will retry the recorded cleanup before opening another rule."
                )
                next.externalReachabilityStatus = .disabled("Waiting for router cleanup")
                next.lastCheckedAt = Date()
                withState {
                    routerMappingErrorMessage = error.localizedDescription
                    next.settingsErrorMessage = settingsErrorMessage
                    publishOnStateQueue(next)
                }
                return
            }
        }

        if let expiresAt = workingConfig.accessExpiresAt, expiresAt <= nowProvider() {
            do {
                workingConfig = try withTransaction {
                    try self.requireCurrentRevision(revision)
                    return try self.revokeMappingsBeforeConfigChange(
                        workingConfig,
                        expectedRevision: revision
                    )
                }
                workingConfig.remoteAccessEnabled = false
                workingConfig.accessExpiresAt = nil
                configChanged = true
            } catch {
                next.ddnsStatus = .disabled("Temporary access expired")
                next.routerStatus = .failed(
                    "Router cleanup needs attention",
                    detail: error.localizedDescription
                )
                next.remoteDesktopStatus = .warning(
                    "Remote access remains enabled until router cleanup succeeds",
                    detail: "Reconnect to the original router and run Check Now to retry."
                )
                next.externalReachabilityStatus = .disabled("Temporary access expired")
                next.lastCheckedAt = Date()
                withState {
                    next.settingsErrorMessage = settingsErrorMessage
                    publishOnStateQueue(next)
                }
                return
            }
        }

        if workingConfig.remoteAccessEnabled,
           workingConfig.mappingProtocolPreference == .automatic || workingConfig.mappingProtocolPreference == .pcp,
           workingConfig.pcpNonce == nil {
            var generator = SystemRandomNumberGenerator()
            let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            workingConfig.pcpNonce = nonce.base64EncodedString()
            configChanged = true
        }

        let localIPv4 = localNetworkService.localIPv4Address()
        let gatewayIPv4 = localNetworkService.defaultGatewayIPv4()
        let localIPv6 = localNetworkService.globalIPv6Address()
        let gatewayIPv6 = localNetworkService.defaultGatewayIPv6()
        next.localAddress = localIPv4
        next.gatewayAddress = gatewayIPv4
        next.localIPv6Address = localIPv6
        next.gatewayIPv6Address = gatewayIPv6
        next.externalPort = workingConfig.externalPort

        if localNetworkService.isTCPPortListening(port: workingConfig.internalPort, timeout: 2) {
            next.remoteDesktopStatus = .ok(
                "Remote desktop port \(workingConfig.internalPort) is listening",
                detail: "Screen Sharing accepts a local IPv4 or IPv6 connection."
            )
        } else {
            next.remoteDesktopStatus = .failed(
                "Remote desktop port \(workingConfig.internalPort) is closed",
                detail: "Enable macOS Screen Sharing or Remote Management in System Settings."
            )
        }

        var ddnsIPv4: String?
        var ipv4Issue: String?
        if workingConfig.preferredAddressFamily.usesIPv4 {
            do {
                let discovery = try currentPublicIPv4(
                    config: workingConfig,
                    gatewayAddress: gatewayIPv4,
                    revision: revision
                )
                next.publicAddress = discovery.publicAddress
                if let routerAddress = discovery.routerWANAddress,
                   discovery.blocksDDNS {
                    ipv4Issue = "Router WAN address \(routerAddress) is private or CGNAT. Internet-facing address: \(discovery.publicAddress)."
                } else {
                    ddnsIPv4 = discovery.publicAddress
                }
            } catch {
                if isSuperseded(error) { return }
                ipv4Issue = error.localizedDescription
            }
        }

        var ddnsIPv6: String?
        var ipv6Issue: String?
        if workingConfig.preferredAddressFamily.usesIPv6 {
            if let localIPv6 {
                ddnsIPv6 = localIPv6
                let probedIPv6 = try? withCurrentCheckSideEffect(
                    revision: revision,
                    label: "public-ip.ipv6"
                ) {
                    try makePublicIPService(config: workingConfig).currentIPv6()
                }
                if let internetIPv6 = probedIPv6 {
                    next.publicIPv6Address = internetIPv6
                    if PublicIPService.normalizedIPv6(internetIPv6) != PublicIPService.normalizedIPv6(localIPv6) {
                        ipv6Issue = "The internet IPv6 path differs from this Mac's physical global IPv6; using \(localIPv6) for direct access."
                    }
                } else {
                    next.publicIPv6Address = localIPv6
                }
            } else {
                ipv6Issue = "No global IPv6 address was found on a physical network interface."
            }
        }

        if !workingConfig.remoteAccessEnabled {
            next.ddnsStatus = .disabled("Remote access is off")
            next.routerStatus = .disabled("Remote access is off")
        } else {
            do {
                next.ddnsStatus = try updateDDNS(
                    config: workingConfig,
                    tokenResult: tokenResult,
                    ipv4Address: ddnsIPv4,
                    ipv6Address: ddnsIPv6,
                    ipv4Issue: ipv4Issue,
                    ipv6Issue: ipv6Issue,
                    revision: revision
                )
                let mapping = try ensureRouterMappings(
                    config: workingConfig,
                    localIPv4: localIPv4,
                    gatewayIPv4: gatewayIPv4,
                    localIPv6: localIPv6,
                    gatewayIPv6: gatewayIPv6,
                    remoteDesktopStatus: next.remoteDesktopStatus,
                    revision: revision
                )
                uncheckpointedMappings = mapping.activeMappings.filter {
                    !initialConfig.activeRouterMappings.contains($0)
                }
                if !uncheckpointedMappings.isEmpty {
                    try configStore.saveMappingRecoveryJournal(uncheckpointedMappings)
                    withState {
                        mappingRecoveryMappings = uncheckpointedMappings
                        restartExpirationTimerOnStateQueue()
                    }
                }
            next.routerStatus = mapping.status
            if let port = mapping.ipv4Port { next.externalPort = port }
            next.ipv6ExternalPort = mapping.ipv6Port
            if mapping.pinholeID != workingConfig.ipv6PinholeID {
                workingConfig.ipv6PinholeID = mapping.pinholeID
                configChanged = true
            }
            if mapping.activeMappings != workingConfig.activeRouterMappings {
                workingConfig.activeRouterMappings = mapping.activeMappings
                configChanged = true
            }
            } catch {
                guard !isSuperseded(error) else {
                    compensateUncheckpointedMappings(
                        uncheckpointedMappings,
                        workingConfig: workingConfig,
                        initialConfig: initialConfig,
                        underlyingError: error
                    )
                    return
                }
                if !uncheckpointedMappings.isEmpty {
                    let fallback = compensateUncheckpointedMappings(
                        uncheckpointedMappings,
                        workingConfig: workingConfig,
                        initialConfig: initialConfig,
                        underlyingError: error
                    )
                    workingConfig.pcpNonce = fallback.pcpNonce
                    workingConfig.ipv6PinholeID = fallback.ipv6PinholeID
                    workingConfig.activeRouterMappings = fallback.activeRouterMappings
                    configChanged = true
                }
                next.routerStatus = .failed("Router access failed", detail: error.localizedDescription)
            }
        }

        buildConnectionURLs(config: workingConfig, status: &next)
        next.externalReachabilityStatus = verifyLocalOriginTCPConnection(config: workingConfig, status: next)
        next.lastCheckedAt = Date()

        var expectedRevision = revision
        if configChanged {
            do {
                try requireCurrentRevision(revision)
                try withTransaction {
                    try self.requireCurrentRevision(revision)
                    try self.configStore.save(workingConfig)
                    try self.requireCurrentRevision(revision)
                    var journalErrors: [String] = []
                    do {
                        try self.configStore.saveMappingRecoveryJournal([])
                    } catch {
                        journalErrors.append("Primary journal: \(error.localizedDescription)")
                    }
                    do {
                        try self.emergencyMappingJournal.save([])
                    } catch {
                        journalErrors.append("Emergency journal: \(error.localizedDescription)")
                    }
                    do {
                        try self.fallbackMappingJournal.save([])
                    } catch {
                        journalErrors.append("Fallback journal: \(error.localizedDescription)")
                    }
                    guard journalErrors.isEmpty else {
                        throw NetworkAgentError.transactionFailed(
                            journalErrors.joined(separator: "\n")
                        )
                    }
                    self.withState {
                        guard self.configRevision == revision else { return }
                        self.mappingRecoveryMappings = []
                        self.configPersistenceErrorMessage = nil
                        self.commitConfigOnStateQueue(workingConfig)
                        expectedRevision = self.configRevision
                    }
                }
            } catch {
                if isSuperseded(error) {
                    compensateUncheckpointedMappings(
                        uncheckpointedMappings,
                        workingConfig: workingConfig,
                        initialConfig: initialConfig,
                        underlyingError: error
                    )
                    return
                }
                let fallback = compensateUncheckpointedMappings(
                    uncheckpointedMappings,
                    workingConfig: workingConfig,
                    initialConfig: initialConfig,
                    underlyingError: error
                )
                withState {
                    guard configRevision == revision else { return }
                    configPersistenceErrorMessage = error.localizedDescription
                    commitConfigOnStateQueue(fallback)
                    expectedRevision = configRevision
                    next.settingsErrorMessage = settingsErrorMessage
                    publishCurrentSettingsErrorOnStateQueue()
                }
            }
        }
        withState {
            guard configRevision == expectedRevision else { return }
            next.settingsErrorMessage = settingsErrorMessage
            publishOnStateQueue(next)
        }
    }

    private func updateDDNS(
        config: AppConfig,
        tokenResult: Result<String, Error>,
        ipv4Address: String?,
        ipv6Address: String?,
        ipv4Issue: String?,
        ipv6Issue: String?,
        revision: UInt64
    ) throws -> ComponentStatus {
        guard config.dnsProvider != .disabled else {
            return .disabled("DDNS is disabled")
        }
        guard !config.cloudflareZoneID.isEmpty, !config.dnsRecordName.isEmpty else {
            return .warning("Cloudflare is not configured", detail: "Select a domain and enter the subdomain and API token.")
        }
        let token: String
        do {
            token = try tokenResult.get()
        } catch {
            return .failed("Cloudflare token is unavailable", detail: error.localizedDescription)
        }
        guard !token.isEmpty else {
            return .warning("Cloudflare token is missing", detail: "Save a Cloudflare API token in settings.")
        }
        let dnsProvider: CloudflareDNSProvider
        do {
            dnsProvider = try makeDNSProvider(
                mode: config.ddnsProxyMode,
                customProxyURL: config.customProxyURL
            )
        } catch {
            return .failed("DDNS proxy configuration is invalid", detail: error.localizedDescription)
        }

        var successes: [String] = []
        var notes: [String] = []
        var failures: [String] = []
        if config.preferredAddressFamily.usesIPv4 {
            if let ipv4Address {
                do {
                    let result = try withCurrentCheckSideEffect(
                        revision: revision,
                        label: "cloudflare.upsert-a"
                    ) {
                        try dnsProvider.upsertARecord(
                            zoneID: config.cloudflareZoneID,
                            recordName: config.dnsRecordName,
                            ipAddress: ipv4Address,
                            token: token
                        )
                    }
                    successes.append(result.message)
                } catch {
                    if isSuperseded(error) { throw error }
                    failures.append("A: \(error.localizedDescription)")
                }
            } else {
                failures.append("A: \(ipv4Issue ?? "No public IPv4 address")")
            }
        }
        if config.preferredAddressFamily.usesIPv6 {
            if let ipv6Address {
                do {
                    let result = try withCurrentCheckSideEffect(
                        revision: revision,
                        label: "cloudflare.upsert-aaaa"
                    ) {
                        try dnsProvider.upsertAAAARecord(
                            zoneID: config.cloudflareZoneID,
                            recordName: config.dnsRecordName,
                            ipAddress: ipv6Address,
                            token: token
                        )
                    }
                    successes.append(result.message)
                    if let ipv6Issue { notes.append("IPv6 note: \(ipv6Issue)") }
                } catch {
                    if isSuperseded(error) { throw error }
                    failures.append("AAAA: \(error.localizedDescription)")
                }
            } else {
                failures.append("AAAA: \(ipv6Issue ?? "No global IPv6 address")")
            }
        }

        let detail = (successes + notes + failures).joined(separator: "\n")
        if successes.isEmpty {
            return .failed("DDNS update failed", detail: detail)
        }
        if !failures.isEmpty {
            return .warning("DDNS is partially available", detail: detail)
        }
        let family = config.preferredAddressFamily == .dualStack ? "A and AAAA" : (config.preferredAddressFamily == .ipv6 ? "AAAA" : "A")
        return .ok("Cloudflare \(family) record is current", detail: detail)
    }

    func currentPublicIPv4(
        config: AppConfig,
        gatewayAddress: String?,
        revision: UInt64
    ) throws -> PublicIPv4Discovery {
        var routerWANAddress: String?
        if let gatewayAddress {
            do {
                let routerAddress = try withCurrentCheckSideEffect(
                    revision: revision,
                    label: "router.wan-ipv4"
                ) {
                    try routerMappingService.externalIPv4Address(gatewayAddress: gatewayAddress)
                }
                if PublicIPService.looksLikeIPv4(routerAddress) {
                    routerWANAddress = routerAddress
                    if PublicIPService.isPublicIPv4(routerAddress) {
                        return PublicIPv4Discovery(
                            publicAddress: routerAddress,
                            routerWANAddress: routerAddress,
                            blocksDDNS: false
                        )
                    }
                }
            } catch {
                if isSuperseded(error) { throw error }
            }
        }
        let probedAddress = try withCurrentCheckSideEffect(
            revision: revision,
            label: "public-ip.ipv4"
        ) {
            try makePublicIPService(config: config).currentIPv4()
        }
        return PublicIPv4Discovery(
            publicAddress: probedAddress,
            routerWANAddress: routerWANAddress,
            blocksDDNS: routerWANAddress.map(PublicIPService.isPrivateOrCGNAT) ?? false
        )
    }

    private func makeDNSProvider(mode: NetworkProxyMode, customProxyURL: String) throws -> CloudflareDNSProvider {
        try dependencyFactory.makeCloudflareProvider(
            proxyMode: mode,
            customProxyURL: customProxyURL
        ).provider
    }

    private func makePublicIPService(config: AppConfig) throws -> PublicIPServicing {
        if let injectedPublicIPServiceFactory {
            return try injectedPublicIPServiceFactory(config)
        }
        return try dependencyFactory.makePublicIPService(
            proxyMode: config.publicIPProxyMode,
            customProxyURL: config.customProxyURL
        ).service
    }

    private func ensureRouterMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?,
        remoteDesktopStatus: ComponentStatus,
        revision: UInt64
    ) throws -> RouterMappingOutcome {
        guard config.mappingProtocolPreference != .disabled else {
            let report = try withCurrentCheckSideEffect(
                revision: revision,
                label: "router.mapping.delete-disabled"
            ) {
                routerMappingService.removeMappings(config.activeRouterMappings)
            }
            if report.allSucceeded {
                return RouterMappingOutcome(status: .disabled("Router mapping is disabled"))
            }
            return RouterMappingOutcome(
                status: .failed(
                    "Old router mappings still need cleanup",
                    detail: report.failureDescription
                ),
                activeMappings: report.remainingMappings
            )
        }
        guard remoteDesktopStatus.state == .ok else {
            return RouterMappingOutcome(
                status: .failed("Remote desktop is not ready", detail: remoteDesktopStatus.detail),
                ipv4Port: config.activeRouterMappings.first { $0.addressFamily == .ipv4 }?.externalPort,
                ipv6Port: config.activeRouterMappings.first { $0.addressFamily == .ipv6 }?.externalPort,
                pinholeID: config.activeRouterMappings.first {
                    $0.addressFamily == .ipv6 && $0.transport == .upnp
                }?.pinholeID,
                activeMappings: config.activeRouterMappings
            )
        }

        var successes: [String] = []
        var failures: [String] = []
        var ipv4Port: UInt16?
        var ipv6Port: UInt16?
        var activeMappings = config.activeRouterMappings
        let now = nowProvider()

        func removeTrackedMappings(
            _ mappings: [ActiveRouterMapping],
            reason: String
        ) throws -> Bool {
            guard !mappings.isEmpty else { return true }
            let report = try withCurrentCheckSideEffect(
                revision: revision,
                label: "router.mapping.delete"
            ) {
                routerMappingService.removeMappings(mappings)
            }
            let removedIDs = Set(report.succeededMappings.map(\.identifier))
            activeMappings.removeAll { removedIDs.contains($0.identifier) }
            guard report.allSucceeded else {
                failures.append("\(reason): \(report.failureDescription)")
                return false
            }
            return true
        }

        func executeEnsure(
            label: String,
            _ body: () throws -> PortMappingResult
        ) throws -> PortMappingResult {
            try withCurrentCheckSideEffect(revision: revision, label: label) {
                do {
                    return try body()
                } catch let recovery as RouterMappingRecoveryRequiredError {
                    throw preserveRecoveryIdentityAfterJournalFailure(recovery)
                }
            }
        }

        func retainRecoveryMapping(_ recovery: RouterMappingRecoveryRequiredError) {
            activeMappings.removeAll { $0.identifier == recovery.mapping.identifier }
            activeMappings.append(recovery.mapping)
            withState {
                if !mappingRecoveryMappings.contains(where: {
                    $0.identifier == recovery.mapping.identifier
                }) {
                    mappingRecoveryMappings.append(recovery.mapping)
                }
                restartExpirationTimerOnStateQueue()
            }
        }

        let undesiredMappings = activeMappings.filter {
            ($0.addressFamily == .ipv4 && !config.preferredAddressFamily.usesIPv4)
                || ($0.addressFamily == .ipv6 && !config.preferredAddressFamily.usesIPv6)
        }
        _ = try removeTrackedMappings(undesiredMappings, reason: "Old address-family cleanup")

        func reconcile(
            family: RouterMappingAddressFamily,
            localAddress: String?,
            gatewayAddress: String?,
            ensure: (AppConfig, String, String) throws -> PortMappingResult
        ) throws {
            let familyName = family.displayName
            let tracked = activeMappings.filter { $0.addressFamily == family }
            guard let localAddress, let gatewayAddress else {
                _ = try removeTrackedMappings(
                    tracked,
                    reason: "\(familyName) old mapping cleanup"
                )
                failures.append("\(familyName): local address or default gateway is unavailable")
                return
            }

            let compatible = tracked.first {
                $0.isCompatible(
                    with: config,
                    family: family,
                    localAddress: localAddress,
                    gatewayAddress: gatewayAddress
                )
            }
            var keptCompatible = false
            let obsolete = tracked.filter { mapping in
                if !keptCompatible, mapping == compatible {
                    keptCompatible = true
                    return false
                }
                return true
            }
            guard try removeTrackedMappings(
                obsolete,
                reason: "\(familyName) old mapping cleanup"
            ) else {
                return
            }

            if let compatible {
                let remaining = max(0, Int(compatible.leaseExpiresAt.timeIntervalSince(now)))
                if now < compatible.renewAfter || !config.autoRenewMapping {
                    if now >= compatible.leaseExpiresAt {
                        failures.append(
                            "\(familyName): the \(compatible.transport.displayName) lease expired; turn on Auto Renew or save settings to create a new lease"
                        )
                    } else {
                        let renewal = config.autoRenewMapping ? "renewal is scheduled" : "Auto Renew is off"
                        successes.append(
                            "\(familyName): \(compatible.transport.displayName) mapping is active for about \(remaining)s; \(renewal)"
                        )
                        if family == .ipv4 {
                            ipv4Port = compatible.externalPort
                        } else {
                            ipv6Port = compatible.externalPort
                        }
                    }
                    return
                }

                var renewalConfig = config
                renewalConfig.mappingProtocolPreference = compatible.transport.preference
                renewalConfig.pcpNonce = compatible.pcpNonce ?? config.pcpNonce
                renewalConfig.ipv6PinholeID = compatible.pinholeID
                do {
                    let result = try executeEnsure(label: "router.mapping.renew") {
                        try ensure(renewalConfig, localAddress, gatewayAddress)
                    }
                    activeMappings.removeAll { $0.identifier == compatible.identifier }
                    activeMappings.append(result.activeMapping)
                    successes.append("\(familyName): renewed \(result.message) via \(result.protocolName)")
                    if family == .ipv4 {
                        ipv4Port = result.externalPort
                    } else {
                        ipv6Port = result.externalPort
                    }
                } catch {
                    if isSuperseded(error) { throw error }
                    if let recovery = error as? RouterMappingRecoveryRequiredError {
                        retainRecoveryMapping(recovery)
                        throw recovery
                    }
                    if now < compatible.leaseExpiresAt {
                        successes.append(
                            "\(familyName): the existing \(compatible.transport.displayName) lease remains active for about \(remaining)s"
                        )
                        if family == .ipv4 {
                            ipv4Port = compatible.externalPort
                        } else {
                            ipv6Port = compatible.externalPort
                        }
                    }
                    failures.append("\(familyName) renewal: \(error.localizedDescription)")
                }
                return
            }

            do {
                let result = try executeEnsure(label: "router.mapping.create") {
                    try ensure(config, localAddress, gatewayAddress)
                }
                activeMappings.append(result.activeMapping)
                successes.append("\(familyName): \(result.message) via \(result.protocolName)")
                if family == .ipv4 {
                    ipv4Port = result.externalPort
                } else {
                    ipv6Port = result.externalPort
                }
            } catch {
                if isSuperseded(error) { throw error }
                if let recovery = error as? RouterMappingRecoveryRequiredError {
                    retainRecoveryMapping(recovery)
                    throw recovery
                }
                failures.append("\(familyName): \(error.localizedDescription)")
            }
        }

        if config.preferredAddressFamily.usesIPv4 {
            try reconcile(
                family: .ipv4,
                localAddress: localIPv4,
                gatewayAddress: gatewayIPv4
            ) { candidate, local, gateway in
                try routerMappingService.ensureMapping(
                    config: candidate,
                    localAddress: local,
                    gatewayAddress: gateway
                )
            }
        }
        if config.preferredAddressFamily.usesIPv6 {
            try reconcile(
                family: .ipv6,
                localAddress: localIPv6,
                gatewayAddress: gatewayIPv6
            ) { candidate, local, gateway in
                try routerMappingService.ensureIPv6Pinhole(
                    config: candidate,
                    localAddress: local,
                    gatewayAddress: gateway
                )
            }
        }

        activeMappings.sort {
            if $0.addressFamily != $1.addressFamily {
                return $0.addressFamily.rawValue < $1.addressFamily.rawValue
            }
            return $0.transport.rawValue < $1.transport.rawValue
        }
        let pinholeID = activeMappings.first {
            $0.addressFamily == .ipv6 && $0.transport == .upnp
        }?.pinholeID

        let detail = (successes + failures).joined(separator: "\n")
        let status: ComponentStatus
        if successes.isEmpty {
            status = .failed("Router access failed", detail: detail)
        } else if !failures.isEmpty {
            status = .warning("Router access is partially available", detail: detail)
        } else if config.preferredAddressFamily == .dualStack {
            status = .ok("IPv4 mapping and IPv6 pinhole are open", detail: detail)
        } else {
            status = .ok("Router access is open", detail: detail)
        }
        return RouterMappingOutcome(
            status: status,
            ipv4Port: ipv4Port,
            ipv6Port: ipv6Port,
            pinholeID: pinholeID,
            activeMappings: activeMappings
        )
    }

    private func preserveRecoveryIdentityAfterJournalFailure(
        _ recovery: RouterMappingRecoveryRequiredError
    ) -> Error {
        let recoveryMappings = withState { () -> [ActiveRouterMapping] in
            if !mappingRecoveryMappings.contains(where: {
                $0.identifier == recovery.mapping.identifier
            }) {
                mappingRecoveryMappings.append(recovery.mapping)
            }
            restartExpirationTimerOnStateQueue()
            return mappingRecoveryMappings
        }

        do {
            try emergencyMappingJournal.merge([recovery.mapping])
            return recovery
        } catch {
            let emergencyError = error
            var primaryError: Error?
            do {
                try configStore.saveMappingRecoveryJournal(recoveryMappings)
            } catch {
                primaryError = error
            }

            let retryReport = routerMappingService.removeMappings([recovery.mapping])
            if retryReport.allSucceeded {
                let remaining = withState { () -> [ActiveRouterMapping] in
                    mappingRecoveryMappings.removeAll {
                        $0.identifier == recovery.mapping.identifier
                    }
                    restartExpirationTimerOnStateQueue()
                    return mappingRecoveryMappings
                }
                try? configStore.saveMappingRecoveryJournal(remaining)
                try? emergencyMappingJournal.save(remaining)
                try? fallbackMappingJournal.save(remaining)
                return NetworkAgentError.transactionFailed(
                    [
                        recovery.operationDescription,
                        "Initial cleanup failed: \(recovery.cleanupDescription)",
                        "Emergency journal failed: \(emergencyError.localizedDescription)",
                        "The immediate cleanup retry succeeded for \(recovery.mapping.identifier)."
                    ].joined(separator: "\n")
                )
            }

            var fallbackError: Error?
            if primaryError != nil {
                do {
                    try fallbackMappingJournal.merge([recovery.mapping])
                } catch {
                    fallbackError = error
                }
            }
            let details = [
                recovery.cleanupDescription,
                "Emergency journal failed: \(emergencyError.localizedDescription)",
                primaryError.map { "Primary journal failed: \($0.localizedDescription)" },
                "Immediate cleanup retry failed: \(retryReport.failureDescription)",
                fallbackError.map { "Fallback journal failed: \($0.localizedDescription)" }
            ].compactMap { $0 }.joined(separator: "\n")
            return RouterMappingRecoveryRequiredError(
                mapping: recovery.mapping,
                operationDescription: recovery.operationDescription,
                cleanupDescription: details
            )
        }
    }

    private func buildConnectionURLs(config: AppConfig, status: inout AppStatus) {
        let dnsHost = config.dnsRecordName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipv4Port = status.externalPort ?? config.externalPort
        let ipv6Port = status.ipv6ExternalPort ?? config.externalPort

        if config.preferredAddressFamily.usesIPv4, status.publicAddress != nil {
            let host = dnsHost.isEmpty ? status.publicAddress! : dnsHost
            status.connectionURLIPv4 = vncURL(host: host, port: ipv4Port)
        }
        if config.preferredAddressFamily.usesIPv6, let ipv6Address = status.localIPv6Address {
            let host = dnsHost.isEmpty ? ipv6Address : dnsHost
            status.connectionURLIPv6 = vncURL(host: host, port: ipv6Port)
        }

        switch config.preferredAddressFamily {
        case .ipv4:
            status.connectionURL = status.connectionURLIPv4
        case .ipv6:
            status.connectionURL = status.connectionURLIPv6
        case .dualStack:
            if ipv4Port == ipv6Port, !dnsHost.isEmpty {
                status.connectionURL = vncURL(host: dnsHost, port: ipv4Port)
            } else {
                if let ipv4Address = status.publicAddress {
                    status.connectionURLIPv4 = vncURL(host: ipv4Address, port: ipv4Port)
                }
                status.connectionURL = status.connectionURLIPv4 ?? status.connectionURLIPv6
            }
        }
    }

    private func vncURL(host: String, port: UInt16) -> String {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "vnc://\(formattedHost):\(port)"
    }

    func verifyLocalOriginTCPConnection(
        config: AppConfig,
        status: AppStatus,
        resolve: ((String, Int32) -> String?)? = nil,
        connect: ((String, UInt16, TimeInterval) -> Bool)? = nil
    ) -> ComponentStatus {
        let resolveAddress = resolve ?? { [self] host, family in
            self.resolveAddress(host, family: family)
        }
        let connectToPort = connect ?? { [localNetworkService] host, port, timeout in
            localNetworkService.isTCPPortOpen(host: host, port: port, timeout: timeout)
        }

        guard config.remoteAccessEnabled else {
            return .disabled("Remote access is off")
        }

        if !config.dnsRecordName.isEmpty {
            var missing: [String] = []
            if config.preferredAddressFamily.usesIPv4, resolveAddress(config.dnsRecordName, AF_INET) == nil {
                missing.append("A")
            }
            if config.preferredAddressFamily.usesIPv6, resolveAddress(config.dnsRecordName, AF_INET6) == nil {
                missing.append("AAAA")
            }
            if !missing.isEmpty {
                return .warning(
                    "DNS has not fully resolved on this Mac",
                    detail: "Missing \(missing.joined(separator: " and ")) for \(config.dnsRecordName). Internet reachability was not tested."
                )
            }
        }

        let probeHost = config.externalProbeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if probeHost.isEmpty {
            return .warning(
                "Local-origin TCP check not configured",
                detail: "Optional. A connection from this Mac cannot verify internet reachability."
            )
        }

        var checks: [Bool] = []
        if config.preferredAddressFamily.usesIPv4,
           let address = resolveAddress(probeHost, AF_INET) {
            checks.append(connectToPort(address, status.externalPort ?? config.externalPort, 4))
        }
        if config.preferredAddressFamily.usesIPv6,
           let address = resolveAddress(probeHost, AF_INET6) {
            checks.append(connectToPort(address, status.ipv6ExternalPort ?? config.externalPort, 4))
        }
        if checks.contains(true) {
            return checks.allSatisfy { $0 }
                ? .ok(
                    "Local-origin TCP connection succeeded",
                    detail: "Connected from this Mac to \(probeHost). This does not verify internet reachability."
                )
                : .warning(
                    "Local-origin TCP connection was partially successful",
                    detail: "At least one local address-family path to \(probeHost) failed. Internet reachability was not tested."
                )
        }
        return .failed(
            "Local-origin TCP connection failed",
            detail: "This Mac could not connect to \(probeHost). Internet reachability was not tested."
        )
    }

    private func resolveAddress(_ host: String, family: Int32) -> String? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            first.pointee.ai_addr,
            first.pointee.ai_addrlen,
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else {
            return nil
        }
        return String(cString: hostname)
    }

    private var settingsErrorMessage: String? {
        routerMappingErrorMessage ?? keychainErrorMessage ?? configPersistenceErrorMessage ?? launchAgentErrorMessage
    }

    @discardableResult
    private func compensateUncheckpointedMappings(
        _ mappings: [ActiveRouterMapping],
        workingConfig: AppConfig,
        initialConfig: AppConfig,
        underlyingError: Error
    ) -> AppConfig {
        withTransaction {
            compensateUncheckpointedMappingsOnTransactionQueue(
                mappings,
                workingConfig: workingConfig,
                initialConfig: initialConfig,
                underlyingError: underlyingError
            )
        }
    }

    private func compensateUncheckpointedMappingsOnTransactionQueue(
        _ mappings: [ActiveRouterMapping],
        workingConfig: AppConfig,
        initialConfig: AppConfig,
        underlyingError: Error
    ) -> AppConfig {
        var fallback = initialConfig
        fallback.pcpNonce = workingConfig.pcpNonce
        fallback.ipv6PinholeID = workingConfig.ipv6PinholeID
        fallback.activeRouterMappings = workingConfig.activeRouterMappings
        let trackedIDs = Set(fallback.activeRouterMappings.map(\.identifier))
        fallback.activeRouterMappings.append(
            contentsOf: mappings.filter { !trackedIDs.contains($0.identifier) }
        )
        guard !mappings.isEmpty else { return fallback }

        var primaryJournalError: Error?
        var emergencyJournalError: Error?
        var fallbackJournalError: Error?
        do {
            try configStore.saveMappingRecoveryJournal(mappings)
        } catch {
            primaryJournalError = error
            do {
                try emergencyMappingJournal.save(mappings)
            } catch {
                emergencyJournalError = error
                do {
                    try fallbackMappingJournal.save(mappings)
                } catch {
                    fallbackJournalError = error
                }
            }
        }

        let report = withRecoverySideEffect(label: "router.mapping.compensate-delete") {
            routerMappingService.removeMappings(mappings)
        }
        let removedIDs = Set(report.succeededMappings.map(\.identifier))
        fallback.activeRouterMappings.removeAll {
            removedIDs.contains($0.identifier)
        }
        fallback.ipv6PinholeID = fallback.activeRouterMappings.first {
            $0.addressFamily == .ipv6 && $0.transport == .upnp
        }?.pinholeID

        do {
            try configStore.saveMappingRecoveryJournal(report.remainingMappings)
        } catch {
            primaryJournalError = error
        }
        do {
            try emergencyMappingJournal.save(report.remainingMappings)
            emergencyJournalError = nil
        } catch {
            emergencyJournalError = error
        }
        do {
            try fallbackMappingJournal.save(report.remainingMappings)
            fallbackJournalError = nil
        } catch {
            fallbackJournalError = error
        }
        if !report.remainingMappings.isEmpty,
           primaryJournalError != nil,
           emergencyJournalError != nil,
           fallbackJournalError != nil {
            try? configStore.save(fallback)
        }

        let recoveryMessage: String
        if report.allSucceeded {
            recoveryMessage = "The new router mapping was closed after its checkpoint could not be saved."
        } else {
            recoveryMessage = [
                "A new router mapping could not be checkpointed or fully closed.",
                report.failureDescription,
                "Gatebeam recorded the remaining rule and will retry cleanup before creating another mapping."
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        let journalDetail = [primaryJournalError, emergencyJournalError, fallbackJournalError]
            .compactMap { $0?.localizedDescription }
            .map { "Recovery journal error: \($0)" }
            .joined(separator: "\n")
        withState {
            mappingRecoveryMappings = report.remainingMappings
            restartExpirationTimerOnStateQueue()
            routerMappingErrorMessage = [recoveryMessage, journalDetail]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            configPersistenceErrorMessage = underlyingError.localizedDescription
            publishCurrentSettingsErrorOnStateQueue()
        }
        return fallback
    }

    private func mappingLifecycleChanged(from previous: AppConfig, to requested: AppConfig) -> Bool {
        guard previous.remoteAccessEnabled || !previous.activeRouterMappings.isEmpty else {
            return false
        }
        let temporaryDeadlineRequiresShorterLease = requested.accessExpiresAt.map { deadline in
            previous.activeRouterMappings.contains {
                $0.leaseExpiresAt > deadline
            }
        } ?? false
        return !requested.remoteAccessEnabled
            || previous.mappingProtocolPreference != requested.mappingProtocolPreference
            || previous.preferredAddressFamily != requested.preferredAddressFamily
            || previous.internalPort != requested.internalPort
            || previous.externalPort != requested.externalPort
            || previous.mappingLeaseSeconds != requested.mappingLeaseSeconds
            || temporaryDeadlineRequiresShorterLease
    }

    private func revokeMappingsBeforeConfigChange(
        _ previous: AppConfig,
        expectedRevision: UInt64
    ) throws -> AppConfig {
        try requireCurrentRevision(expectedRevision)
        let localIPv4 = localNetworkService.localIPv4Address()
        let gatewayIPv4 = localNetworkService.defaultGatewayIPv4()
        let localIPv6 = localNetworkService.globalIPv6Address()
        let gatewayIPv6 = localNetworkService.defaultGatewayIPv6()
        let trackedMappings = previous.activeRouterMappings
        let candidates: [ActiveRouterMapping]
        if trackedMappings.isEmpty {
            candidates = try withRevisionBoundSideEffect(
                revision: expectedRevision,
                label: "router.mapping.legacy-discovery"
            ) {
                try routerMappingService.legacyRemovalCandidates(
                    config: previous,
                    localIPv4: localIPv4,
                    gatewayIPv4: gatewayIPv4,
                    localIPv6: localIPv6,
                    gatewayIPv6: gatewayIPv6
                )
            }
        } else {
            candidates = trackedMappings
        }

        if candidates.isEmpty,
           let missingContext = missingLegacyRemovalContext(
            config: previous,
            localIPv4: localIPv4,
            gatewayIPv4: gatewayIPv4,
            localIPv6: localIPv6,
            gatewayIPv6: gatewayIPv6
           ) {
            let message = "Could not identify the old router mapping because \(missingContext). Reconnect to the original router, then try again."
            withState {
                routerMappingErrorMessage = message
                publishCurrentSettingsErrorOnStateQueue()
            }
            throw NetworkAgentError.transactionFailed(message)
        }

        let report = try withRevisionBoundSideEffect(
            revision: expectedRevision,
            label: "router.mapping.config-delete"
        ) {
            routerMappingService.removeMappings(candidates)
        }
        var checkpoint = previous
        checkpoint.activeRouterMappings = report.remainingMappings
        checkpoint.ipv6PinholeID = report.remainingMappings.first {
            $0.addressFamily == .ipv6 && $0.transport == .upnp
        }?.pinholeID

        if checkpoint.activeRouterMappings != previous.activeRouterMappings || !report.attempts.isEmpty {
            do {
                try withRevisionBoundSideEffect(
                    revision: expectedRevision,
                    label: "config.mapping-checkpoint"
                ) {
                    try configStore.save(checkpoint)
                }
                withState {
                    applyMappingCheckpointOnStateQueue(checkpoint)
                }
            } catch {
                let message = "Router cleanup changed state, but Gatebeam could not save the retry checkpoint: \(error.localizedDescription)"
                withState {
                    routerMappingErrorMessage = message
                    applyMappingCheckpointOnStateQueue(checkpoint)
                    publishCurrentSettingsErrorOnStateQueue()
                }
                throw NetworkAgentError.transactionFailed(message)
            }
        }

        guard report.allSucceeded else {
            let message = [
                "Could not close every router mapping. Gatebeam kept remote access enabled and retained the failed rules for retry.",
                report.failureDescription,
                "Check that this Mac is connected to the same router, then try again."
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            withState {
                routerMappingErrorMessage = message
                publishCurrentSettingsErrorOnStateQueue()
            }
            throw NetworkAgentError.transactionFailed(message)
        }

        withState {
            if !recoveryStateUnknown {
                routerMappingErrorMessage = nil
            }
            publishCurrentSettingsErrorOnStateQueue()
        }
        return checkpoint
    }

    private func missingLegacyRemovalContext(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> String? {
        guard config.mappingProtocolPreference != .disabled else { return nil }
        var missing: [String] = []
        if config.preferredAddressFamily.usesIPv4,
           localIPv4 == nil || gatewayIPv4 == nil {
            missing.append("the IPv4 address or gateway is unavailable")
        }
        if config.preferredAddressFamily.usesIPv6,
           config.mappingProtocolPreference != .natpmp,
           localIPv6 == nil || gatewayIPv6 == nil {
            missing.append("the IPv6 address or gateway is unavailable")
        }
        return missing.isEmpty ? nil : missing.joined(separator: " and ")
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return try body()
        }
        return try stateQueue.sync(execute: body)
    }

    private func withTransaction<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: transactionQueueKey) != nil {
            return try body()
        }
        return try transactionQueue.sync(execute: body)
    }

    private func beginConfigMutation() -> UInt64 {
        sideEffectGate.sync {
            withState {
                configRevision &+= 1
                activeConfigMutationRevision = configRevision
                return configRevision
            }
        }
    }

    private func endConfigMutation(_ revision: UInt64) {
        let pendingRetry: Bool? = sideEffectGate.sync {
            withState {
                guard activeConfigMutationRevision == revision else { return nil }
                activeConfigMutationRevision = nil
                guard checkPending, !checkInFlight else { return nil }
                let retry = pendingCheckRetriesKeychain
                checkPending = false
                pendingCheckRetriesKeychain = false
                return retry
            }
        }
        if let pendingRetry {
            scheduleCheck(retryKeychainAfterFailure: pendingRetry)
        }
    }

    private func isCurrentRevision(_ revision: UInt64) -> Bool {
        withState { configRevision == revision }
    }

    private func requireCurrentRevision(_ revision: UInt64) throws {
        guard isCurrentRevision(revision) else {
            throw NetworkAgentError.superseded
        }
    }

    private func requireKnownConfigState() throws {
        guard !withState({ configStateUnknown }) else {
            throw NetworkAgentError.transactionFailed(
                "The damaged configuration must be backed up and restored before settings can be saved."
            )
        }
    }

    private func withCurrentCheckSideEffect<T>(
        revision: UInt64,
        label: String,
        _ body: () throws -> T
    ) throws -> T {
        try sideEffectGate.sync {
            try withState {
                guard configRevision == revision, activeConfigMutationRevision == nil else {
                    throw NetworkAgentError.superseded
                }
            }
            sideEffectWillStartObserver?(label)
            return try body()
        }
    }

    private func withMutationSideEffect<T>(
        revision: UInt64,
        label: String,
        _ body: () throws -> T
    ) throws -> T {
        try sideEffectGate.sync {
            try withState {
                guard configRevision == revision,
                      activeConfigMutationRevision == revision else {
                    throw NetworkAgentError.superseded
                }
            }
            sideEffectWillStartObserver?(label)
            return try body()
        }
    }

    private func withRevisionBoundSideEffect<T>(
        revision: UInt64,
        label: String,
        _ body: () throws -> T
    ) throws -> T {
        try sideEffectGate.sync {
            try withState {
                guard configRevision == revision,
                      activeConfigMutationRevision == nil
                        || activeConfigMutationRevision == revision else {
                    throw NetworkAgentError.superseded
                }
            }
            sideEffectWillStartObserver?(label)
            return try body()
        }
    }

    private func withRecoverySideEffect<T>(
        label: String,
        _ body: () throws -> T
    ) rethrows -> T {
        try sideEffectGate.sync {
            sideEffectWillStartObserver?(label)
            return try body()
        }
    }

    private func isSuperseded(_ error: Error) -> Bool {
        guard let agentError = error as? NetworkAgentError else { return false }
        if case .superseded = agentError {
            return true
        }
        return false
    }

    private func scheduleCheck(retryKeychainAfterFailure: Bool) {
        let snapshot: (AppConfig, UInt64, Bool, Result<String, Error>?)? = withState {
            if activeConfigMutationRevision != nil {
                checkPending = true
                pendingCheckRetriesKeychain = pendingCheckRetriesKeychain || retryKeychainAfterFailure
                return nil
            }
            if checkInFlight {
                checkPending = true
                pendingCheckRetriesKeychain = pendingCheckRetriesKeychain || retryKeychainAfterFailure
                return nil
            }
            checkInFlight = true
            var checking = storedStatus
            checking.ddnsStatus = ComponentStatus(state: .checking, message: "Checking DDNS", detail: "", updatedAt: Date())
            checking.routerStatus = ComponentStatus(state: .checking, message: "Checking router access", detail: "", updatedAt: Date())
            checking.remoteDesktopStatus = ComponentStatus(state: .checking, message: "Checking remote desktop", detail: "", updatedAt: Date())
            checking.externalReachabilityStatus = ComponentStatus(
                state: .checking,
                message: "Checking local-origin TCP path",
                detail: "This does not verify internet reachability.",
                updatedAt: Date()
            )
            publishOnStateQueue(checking)

            let needsToken = requiresCloudflareToken(storedConfig)
            let tokenResult: Result<String, Error>?
            if let cachedCloudflareToken {
                tokenResult = .success(cachedCloudflareToken)
            } else if let keychainReadFailure, !retryKeychainAfterFailure {
                tokenResult = .failure(keychainReadFailure)
            } else {
                tokenResult = nil
            }
            return (storedConfig, configRevision, needsToken, tokenResult)
        }
        guard let snapshot else { return }

        let execute: (Result<String, Error>) -> Void = { tokenResult in
            self.workQueue.async {
                defer { self.finishScheduledCheck() }
                self.performCheck(
                    config: snapshot.0,
                    revision: snapshot.1,
                    tokenResult: tokenResult
                )
            }
        }

        guard snapshot.2, snapshot.3 == nil else {
            execute(snapshot.3 ?? .success(""))
            return
        }

        keychainReadQueue.async {
            let result = Result {
                try self.loadCloudflareToken(
                    retryAfterFailure: retryKeychainAfterFailure,
                    interaction: .background
                )
            }
            execute(result)
        }
    }

    private func finishScheduledCheck() {
        let pendingRetry: Bool? = withState {
            checkInFlight = false
            guard checkPending else { return nil }
            let retry = pendingCheckRetriesKeychain
            checkPending = false
            pendingCheckRetriesKeychain = false
            return retry
        }
        if let pendingRetry {
            scheduleCheck(retryKeychainAfterFailure: pendingRetry)
        }
    }

    private func requiresCloudflareToken(_ config: AppConfig) -> Bool {
        config.remoteAccessEnabled
            && config.dnsProvider == .cloudflare
            && !config.cloudflareZoneID.isEmpty
            && !config.dnsRecordName.isEmpty
    }

    private func restartTimerOnStateQueue() {
        guard sideEffectsEnabled else { return }
        timer?.cancel()
        let interval = AppConfig.normalizedCheckInterval(storedConfig.checkIntervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleCheck(retryKeychainAfterFailure: false)
        }
        self.timer = timer
        timer.resume()
    }

    private func restartExpirationTimerOnStateQueue() {
        expirationTimer?.cancel()
        expirationTimer = nil
        guard sideEffectsEnabled, isRunning else { return }

        var deadlines: [Date] = []
        if storedConfig.remoteAccessEnabled, let accessExpiresAt = storedConfig.accessExpiresAt {
            deadlines.append(accessExpiresAt)
        }
        let recoveryCandidates = storedConfig.activeRouterMappings + mappingRecoveryMappings
        deadlines.append(
            contentsOf: recoveryCandidates.compactMap { mapping in
                guard mapping.addressFamily == .ipv6,
                      mapping.transport == .upnp,
                      mapping.pinholeID == nil else {
                    return nil
                }
                return mapping.leaseExpiresAt
            }
        )
        guard let safetyDeadline = deadlines.min() else {
            expirationRetryNotBefore = nil
            return
        }

        let now = nowProvider()
        let scheduledDeadline: Date
        if safetyDeadline > now {
            expirationRetryNotBefore = nil
            scheduledDeadline = safetyDeadline
        } else if let expirationRetryNotBefore, expirationRetryNotBefore > now {
            scheduledDeadline = expirationRetryNotBefore
        } else {
            scheduledDeadline = now.addingTimeInterval(0.05)
        }
        expirationTimer = expirationTimerScheduler(scheduledDeadline) { [weak self] in
            self?.handleExpirationTimerFired()
        }
    }

    private func handleExpirationTimerFired() {
        transactionQueue.async {
            guard self.sideEffectsEnabled else { return }
            let now = self.nowProvider()
            self.withState {
                self.expirationRetryNotBefore = now.addingTimeInterval(30)
            }
            let snapshot = self.config
            if snapshot.remoteAccessEnabled,
               let expiresAt = snapshot.accessExpiresAt,
               expiresAt <= now {
                self.expireTemporaryAccessOnTransactionQueue(
                    expectedExpiration: expiresAt,
                    now: now
                )
            } else {
                self.scheduleCheck(retryKeychainAfterFailure: false)
            }
            self.withState {
                self.restartExpirationTimerOnStateQueue()
            }
        }
    }

    private func expireTemporaryAccessOnTransactionQueue(
        expectedExpiration: Date,
        now: Date
    ) {
        let mutationRevision = beginConfigMutation()
        defer { endConfigMutation(mutationRevision) }
        var previousConfig = config
        guard previousConfig.remoteAccessEnabled,
              let currentExpiration = previousConfig.accessExpiresAt,
              currentExpiration == expectedExpiration,
              currentExpiration <= now else {
            return
        }

        var expiredConfig = previousConfig
        do {
            if mappingLifecycleChanged(from: previousConfig, to: {
                var disabled = previousConfig
                disabled.remoteAccessEnabled = false
                disabled.accessExpiresAt = nil
                return disabled
            }()) {
                previousConfig = try revokeMappingsBeforeConfigChange(
                    previousConfig,
                    expectedRevision: mutationRevision
                )
            }
            expiredConfig = previousConfig
            expiredConfig.remoteAccessEnabled = false
            expiredConfig.accessExpiresAt = nil
            expiredConfig.activeRouterMappings = []
            expiredConfig.ipv6PinholeID = nil
            try persistConfigOnly(
                expiredConfig,
                previousConfig: previousConfig,
                expectedRevision: mutationRevision
            )
            try finishConfigCommit(
                expiredConfig,
                previousConfig: previousConfig,
                expectedRevision: mutationRevision
            )
        } catch {
            guard !isSuperseded(error) else { return }
            publishPersistenceFailure(error, rollbackConfig: previousConfig)
        }
    }

    private static func scheduleSystemExpirationTimer(
        deadline: Date,
        handler: @escaping () -> Void
    ) -> NetworkAgentScheduledTimer {
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.schedule(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            leeway: .milliseconds(100)
        )
        source.setEventHandler(handler: handler)
        source.resume()
        return NetworkAgentScheduledTimer {
            source.setEventHandler {}
            source.cancel()
        }
    }

    private func persistConfigOnly(
        _ newConfig: AppConfig,
        previousConfig: AppConfig,
        expectedRevision: UInt64
    ) throws {
        var loginItemChanged = false
        var configWritten = false
        if previousConfig.startAtLogin != newConfig.startAtLogin {
            let loginResult = try withMutationSideEffect(
                revision: expectedRevision,
                label: "login-item.write"
            ) {
                setLoginItemEnabled(newConfig.startAtLogin)
            }
            switch loginResult {
            case .success:
                loginItemChanged = true
            case .failure(let error):
                withState {
                    launchAgentErrorMessage = error.localizedDescription
                    publishCurrentSettingsErrorOnStateQueue()
                }
                throw error
            }
        }

        do {
            try withMutationSideEffect(
                revision: expectedRevision,
                label: "config.write"
            ) {
                try configStore.save(newConfig)
            }
            configWritten = true
            try requireCurrentRevision(expectedRevision)
        } catch {
            if configWritten {
                try? withRecoverySideEffect(label: "config.rollback") {
                    try configStore.save(previousConfig)
                }
            }
            if loginItemChanged {
                let rollbackResult = withRecoverySideEffect(label: "login-item.rollback") {
                    setLoginItemEnabled(previousConfig.startAtLogin)
                }
                if case .failure(let rollbackError) = rollbackResult {
                    throw NetworkAgentError.transactionFailed(
                        "\(error.localizedDescription) Login-item rollback also failed: \(rollbackError.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    private func finishConfigCommit(
        _ appliedConfig: AppConfig,
        previousConfig: AppConfig,
        expectedRevision: UInt64
    ) throws {
        let committed = withState {
            guard configRevision == expectedRevision else { return false }
            configPersistenceErrorMessage = nil
            launchAgentErrorMessage = nil
            commitConfigOnStateQueue(appliedConfig, advanceRevision: false)
            publishCurrentSettingsErrorOnStateQueue()
            return true
        }
        guard committed else { throw NetworkAgentError.superseded }
        finishPostCommit(previousConfig: previousConfig, appliedConfig: appliedConfig)
    }

    private func finishPostCommit(previousConfig: AppConfig, appliedConfig: AppConfig) {
        if previousConfig.checkIntervalSeconds != appliedConfig.checkIntervalSeconds {
            withState {
                restartTimerOnStateQueue()
            }
        }
        scheduleCheck(retryKeychainAfterFailure: false)
    }

    private func publishPersistenceFailure(_ error: Error, rollbackConfig: AppConfig) {
        withState {
            configPersistenceErrorMessage = error.localizedDescription
            publishCurrentSettingsErrorOnStateQueue()
            commitConfigOnStateQueue(rollbackConfig)
        }
    }

    private func writeTokenToKeychain(_ token: String) throws {
        if token.isEmpty {
            try keychain.deleteChecked(account: "cloudflare-api-token")
        } else {
            try keychain.set(token, account: "cloudflare-api-token")
        }
    }

    private func commitConfigOnStateQueue(_ config: AppConfig, advanceRevision: Bool = true) {
        let normalized = config.normalizedForPersistence()
        storedConfig = normalized
        if advanceRevision {
            configRevision &+= 1
        }
        notifyConfigChangedOnStateQueue(normalized)
        restartExpirationTimerOnStateQueue()
    }

    private func applyMappingCheckpointOnStateQueue(_ checkpoint: AppConfig) {
        storedConfig.activeRouterMappings = checkpoint.activeRouterMappings
        storedConfig.ipv6PinholeID = checkpoint.ipv6PinholeID
        storedConfig.pcpNonce = checkpoint.pcpNonce
        notifyConfigChangedOnStateQueue(storedConfig)
        restartExpirationTimerOnStateQueue()
    }

    private func notifyConfigChangedOnStateQueue(_ config: AppConfig) {
        let callback = storedConfigCallback
        DispatchQueue.main.async {
            callback?(config)
        }
    }

    private func publishCurrentSettingsErrorOnStateQueue() {
        storedStatus.settingsErrorMessage = settingsErrorMessage
        publishOnStateQueue(storedStatus)
    }

    private func publishOnStateQueue(_ status: AppStatus) {
        storedStatus = status
        let callback = storedStatusCallback
        DispatchQueue.main.async {
            callback?(status)
        }
    }
}

private struct RouterMappingOutcome {
    let status: ComponentStatus
    var ipv4Port: UInt16? = nil
    var ipv6Port: UInt16? = nil
    var pinholeID: UInt16? = nil
    var activeMappings: [ActiveRouterMapping] = []
}

struct PublicIPv4Discovery {
    let publicAddress: String
    let routerWANAddress: String?
    let blocksDDNS: Bool
}
