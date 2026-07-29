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

private struct DDNSMappingProofValidationError: Error, LocalizedError {
    let family: RouterMappingAddressFamily
    let reason: String
    let expired: Bool

    var errorDescription: String? {
        "\(family.displayName) mapping proof is no longer valid: \(reason)"
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
    private let keychainQueue = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.keychain", qos: .userInitiated)
    private let keychainQueueKey = DispatchSpecificKey<UInt8>()
    private let sideEffectGate = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent.side-effect-gate")
    private let keychainReadQueue = DispatchQueue(
        label: "RemoteControlNetwork.NetworkAgent.keychain-read",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let sideEffectsEnabled: Bool
    private let checkExecutionObserver: (() -> Void)?
    private let checkCompletionObserver: (() -> Void)?
    private let sideEffectWillStartObserver: ((String) -> Void)?
    private let nowProvider: () -> Date
    private let monotonicUptimeProvider: () -> TimeInterval
    private let bootIdentifierProvider: () -> String
    private let performInitialCheckOnStart: Bool
    private let periodicTimerScheduler:
        ((TimeInterval, @escaping () -> Void) -> NetworkAgentScheduledTimer)?
    private let expirationTimerScheduler:
        (Date, @escaping () -> Void) -> NetworkAgentScheduledTimer
    private var timer: NetworkAgentScheduledTimer?
    private var expirationTimer: NetworkAgentScheduledTimer?
    private var expirationRetryNotBeforeUptime: TimeInterval?
    private var nextPeriodicCheckUptime: TimeInterval?
    private var isRunning = false
    private var cachedCloudflareToken: String?
    private var keychainReadFailure: Error?
    private var keychainStateGeneration: UInt64 = 0
    private var launchAgentErrorMessage: String?
    private var keychainErrorMessage: String?
    private var configPersistenceErrorMessage: String?
    private var routerMappingErrorMessage: String?
    private var configRevision: UInt64 = 0
    private var settingsRequestGeneration: UInt64 = 0
    private var lastCommittedSettingsGeneration: UInt64 = 0
    private var lastSettingsCommitRevision: UInt64 = 0
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
        checkCompletionObserver: (() -> Void)? = nil,
        sideEffectWillStartObserver: ((String) -> Void)? = nil,
        loginItemSetter: ((Bool) -> Result<Void, LaunchAgentManagerError>)? = nil,
        localNetworkService: LocalNetworkServicing = LocalNetworkService(),
        routerMappingService: RouterMappingServicing = RouterMappingService(),
        publicIPServiceFactory: ((AppConfig) throws -> PublicIPServicing)? = nil,
        emergencyMappingJournal: EmergencyMappingJournal? = nil,
        fallbackMappingJournal: EmergencyMappingJournal? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        monotonicUptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        bootIdentifierProvider: @escaping () -> String = {
            RouterMappingService.systemBootIdentifier
        },
        performInitialCheckOnStart: Bool = true,
        periodicTimerScheduler:
            ((TimeInterval, @escaping () -> Void) -> NetworkAgentScheduledTimer)? = nil,
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
        self.checkCompletionObserver = checkCompletionObserver
        self.sideEffectWillStartObserver = sideEffectWillStartObserver
        self.nowProvider = nowProvider
        self.monotonicUptimeProvider = monotonicUptimeProvider
        self.bootIdentifierProvider = bootIdentifierProvider
        self.performInitialCheckOnStart = performInitialCheckOnStart
        self.periodicTimerScheduler = periodicTimerScheduler
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
        if initialConfig == nil {
            Self.restoreRuntimeDeadlines(
                config: &loadedConfig,
                recoveryMappings: &recoveryMappings,
                now: nowProvider(),
                uptime: monotonicUptimeProvider(),
                bootIdentifier: bootIdentifierProvider()
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
        keychainQueue.setSpecific(key: keychainQueueKey, value: 1)
    }

    deinit {
        if !sideEffectsEnabled {
            configStore.removeTemporaryStorage()
        }
    }

    func start() {
        guard sideEffectsEnabled else { return }
        if performInitialCheckOnStart {
            scheduleCheck(retryKeychainAfterFailure: false)
        }
        withState {
            isRunning = true
            restartTimerOnStateQueue()
            if periodicTimerScheduler != nil {
                restartExpirationTimerOnStateQueue()
            }
        }
    }

    func stop() {
        routerMappingService.cancelCurrentOperations()
        withState {
            timer?.cancel()
            timer = nil
            expirationTimer?.cancel()
            expirationTimer = nil
            expirationRetryNotBeforeUptime = nil
            nextPeriodicCheckUptime = nil
            isRunning = false
            configRevision &+= 1
            activeConfigMutationRevision = nil
            checkPending = false
            pendingCheckRetriesKeychain = false
        }
    }

    func stopAndWaitUntilIdle(
        timeout: TimeInterval = 3
    ) -> Bool {
        stop()
        let deadline = ProcessInfo.processInfo.systemUptime
            + max(0.01, timeout)

        // Two fence rounds catch work that was already running when the
        // first round enqueued follow-up work on another agent queue.
        for _ in 0..<2 {
            let group = DispatchGroup()
            let enqueueFence: (DispatchQueue) -> Void = { queue in
                group.enter()
                queue.async {
                    group.leave()
                }
            }
            enqueueFence(workQueue)
            enqueueFence(transactionQueue)
            enqueueFence(keychainQueue)
            enqueueFence(sideEffectGate)
            enqueueFence(stateQueue)
            group.enter()
            keychainReadQueue.async(flags: .barrier) {
                group.leave()
            }

            let remaining = deadline
                - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  group.wait(
                    timeout: .now() + remaining
                  ) == .success else {
                return false
            }
        }

        return withState {
            !checkInFlight
                && activeConfigMutationRevision == nil
                && !checkPending
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
    func persistSettings(
        config newConfig: AppConfig,
        tokenMutation: CloudflareTokenMutation = .keepExisting
    ) throws -> AppConfig {
        let request = reserveSettingsRequest()
        return try withKeychainTransaction {
            try persistSettingsOnKeychainQueue(
                config: newConfig.normalizedForPersistence(),
                tokenMutation: tokenMutation,
                requestGeneration: request.generation,
                baseConfigRevision: request.configRevision
            )
        }
    }

    func persistSettingsAsync(
        config newConfig: AppConfig,
        tokenMutation: CloudflareTokenMutation = .keepExisting,
        completion: @escaping (Result<AppConfig, Error>) -> Void
    ) {
        let request = reserveSettingsRequest()
        keychainQueue.async {
            let result = Result {
                try self.persistSettingsOnKeychainQueue(
                    config: newConfig.normalizedForPersistence(),
                    tokenMutation: tokenMutation,
                    requestGeneration: request.generation,
                    baseConfigRevision: request.configRevision
                )
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func persistSettingsOnKeychainQueue(
        config newConfig: AppConfig,
        tokenMutation: CloudflareTokenMutation,
        requestGeneration: UInt64,
        baseConfigRevision: UInt64
    ) throws -> AppConfig {
        let validatedMutation = try tokenMutation.validated()
        guard sideEffectsEnabled else {
            return withState {
                switch validatedMutation {
                case .keepExisting:
                    break
                case .replace(let token):
                    cachedCloudflareToken = token
                    keychainReadFailure = nil
                case .explicitRemove:
                    cachedCloudflareToken = ""
                    keychainReadFailure = nil
                }
                commitConfigOnStateQueue(newConfig, advanceRevision: false)
                return newConfig
            }
        }

        let effectiveBaseConfigRevision = try resolveSettingsRequestConfigRevision(
            generation: requestGeneration,
            requestedConfigRevision: baseConfigRevision
        )
        let requestedToken: String?
        switch validatedMutation {
        case .keepExisting:
            requestedToken = nil
        case .replace(let token):
            requestedToken = token
        case .explicitRemove:
            requestedToken = ""
        }
        try requireCurrentSettingsRequest(
            generation: requestGeneration,
            configRevision: effectiveBaseConfigRevision
        )
        let tokenChanged = requestedToken.map { requested in
            withState { cachedCloudflareToken != requested }
        } ?? false

        return try withTransaction {
            try requireCurrentSettingsRequest(
                generation: requestGeneration,
                configRevision: effectiveBaseConfigRevision
            )
            let mutationRevision = beginConfigMutation()
            defer { endConfigMutation(mutationRevision) }
            try requireKnownConfigState()
            try requireCurrentRevision(mutationRevision)

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
            try persistNonKeychainSettings(
                appliedConfig,
                previousConfig: previousConfig,
                expectedRevision: mutationRevision
            ) {
                try sideEffectGate.sync {
                    try requireCurrentSettingsRequest(
                        generation: requestGeneration,
                        configRevision: mutationRevision
                    )
                    if tokenChanged, let requestedToken {
                        do {
                            sideEffectWillStartObserver?("keychain.write")
                            try writeTokenToKeychain(requestedToken)
                        } catch {
                            withState {
                                let action = requestedToken.isEmpty ? "delete" : "save"
                                keychainErrorMessage = "Could not \(action) the Cloudflare token: \(error.localizedDescription)"
                                publishCurrentSettingsErrorOnStateQueue()
                            }
                            throw error
                        }
                    }
                    withState {
                        if tokenChanged {
                            keychainStateGeneration &+= 1
                        }
                        if let requestedToken {
                            cachedCloudflareToken = requestedToken
                            keychainReadFailure = nil
                            keychainErrorMessage = nil
                        }
                        configPersistenceErrorMessage = nil
                        launchAgentErrorMessage = nil
                        if !recoveryStateUnknown {
                            routerMappingErrorMessage = nil
                        }
                        lastCommittedSettingsGeneration = requestGeneration
                        lastSettingsCommitRevision = mutationRevision
                        commitConfigOnStateQueue(appliedConfig, advanceRevision: false)
                        publishCurrentSettingsErrorOnStateQueue()
                    }
                }
            }
            finishPostCommit(previousConfig: previousConfig, appliedConfig: appliedConfig)
            return appliedConfig
        }
    }

    private func persistNonKeychainSettings(
        _ appliedConfig: AppConfig,
        previousConfig: AppConfig,
        expectedRevision: UInt64,
        finalize: () throws -> Void
    ) throws {
        var loginItemChanged = false
        var configWritten = false
        var failureArea = "Start at Login"
        do {
            if previousConfig.startAtLogin != appliedConfig.startAtLogin {
                try withMutationSideEffect(
                    revision: expectedRevision,
                    label: "login-item.write"
                ) {
                    try setLoginItemEnabled(appliedConfig.startAtLogin).get()
                }
                loginItemChanged = true
            }
            failureArea = "configuration"
            try withMutationSideEffect(
                revision: expectedRevision,
                label: "config.write"
            ) {
                try configStore.save(appliedConfig)
            }
            configWritten = true
            try requireCurrentRevision(expectedRevision)
            failureArea = "Cloudflare token"
            try finalize()
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
            withState {
                guard configRevision == expectedRevision else { return }
                if failureArea == "Start at Login" {
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
            next.accessExpiresUptime = nil
            next.accessBootIdentifier = nil
            next.accessAnchorWallTime = nil
            next.accessRemainingAtAnchor = nil
        }
        saveConfig(next)
    }

    func setTemporaryAccess(minutes: Int) {
        var next = config
        let duration = TimeInterval(minutes * 60)
        let now = nowProvider()
        next.remoteAccessEnabled = true
        next.accessExpiresAt = now.addingTimeInterval(duration)
        next.accessExpiresUptime = monotonicUptimeProvider() + duration
        next.accessBootIdentifier = bootIdentifierProvider()
        next.accessAnchorWallTime = now
        next.accessRemainingAtAnchor = duration
        saveConfig(next)
    }

    func cloudflareToken() -> String {
        withState { cachedCloudflareToken ?? "" }
    }

    var cloudflareTokenState: CloudflareTokenReadState {
        withState {
            if let cachedCloudflareToken {
                return cachedCloudflareToken.isEmpty
                    ? .missing
                    : .available(cachedCloudflareToken)
            }
            return keychainReadFailure == nil ? .unknown : .unavailable
        }
    }

    @discardableResult
    func loadCloudflareToken(
        retryAfterFailure: Bool = true,
        interaction: KeychainInteraction = .background
    ) throws -> String {
        guard sideEffectsEnabled else { return "" }

        let requestGeneration = withState { keychainStateGeneration }
        return try withKeychainTransaction {
            try loadCloudflareTokenOnKeychainQueue(
                retryAfterFailure: retryAfterFailure,
                interaction: interaction,
                requestGeneration: requestGeneration
            )
        }
    }

    private func loadCloudflareTokenOnKeychainQueue(
        retryAfterFailure: Bool,
        interaction: KeychainInteraction,
        requestGeneration: UInt64
    ) throws -> String {
        let existing: Result<String, Error>? = withState {
            if let cachedCloudflareToken {
                return .success(cachedCloudflareToken)
            }
            if let keychainReadFailure,
               !retryAfterFailure || requestGeneration != keychainStateGeneration {
                return .failure(keychainReadFailure)
            }
            return nil
        }
        if let existing {
            return try existing.get()
        }

        let result = Result {
            try keychain.get(
                account: "cloudflare-api-token",
                interaction: interaction
            ) ?? ""
        }
        withState {
            keychainStateGeneration &+= 1
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
        return try result.get()
    }

    func applyCloudflareTokenMutation(_ mutation: CloudflareTokenMutation) throws {
        try withKeychainTransaction {
            try applyCloudflareTokenMutationOnKeychainQueue(mutation)
        }
    }

    func applyCloudflareTokenMutationAsync(
        _ mutation: CloudflareTokenMutation,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        keychainQueue.async {
            let result = Result {
                try self.applyCloudflareTokenMutationOnKeychainQueue(mutation)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func applyCloudflareTokenMutationOnKeychainQueue(
        _ mutation: CloudflareTokenMutation
    ) throws {
        dispatchPrecondition(condition: .onQueue(keychainQueue))
        let validatedMutation = try mutation.validated()
        guard validatedMutation != .keepExisting else { return }
        guard sideEffectsEnabled else {
            withState {
                switch validatedMutation {
                case .keepExisting:
                    break
                case .replace(let token):
                    cachedCloudflareToken = token
                case .explicitRemove:
                    cachedCloudflareToken = ""
                }
                keychainReadFailure = nil
            }
            return
        }

        let requestedToken: String
        switch validatedMutation {
        case .keepExisting:
            return
        case .replace(let token):
            requestedToken = token
        case .explicitRemove:
            requestedToken = ""
        }
        guard withState({ cachedCloudflareToken != requestedToken }) else { return }
        do {
            try writeTokenToKeychain(requestedToken)
            withState {
                keychainStateGeneration &+= 1
                cachedCloudflareToken = requestedToken
                keychainReadFailure = nil
                keychainErrorMessage = nil
                publishCurrentSettingsErrorOnStateQueue()
            }
            scheduleCheck(retryKeychainAfterFailure: false)
        } catch {
            withState {
                let action = requestedToken.isEmpty ? "delete" : "save"
                keychainErrorMessage = "Could not \(action) the Cloudflare token: \(error.localizedDescription)"
                publishCurrentSettingsErrorOnStateQueue()
            }
            throw error
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

        keychainQueue.async {
            let result = Result {
                try self.keychain.authorizeCurrentOrMigrateLegacy(
                    account: "cloudflare-api-token"
                )
            }
            self.withState {
                self.keychainStateGeneration &+= 1
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
                        retryAfterFailure: false,
                        interaction: .userInitiated
                    )
                    : suppliedToken
                guard !candidate.isEmpty else {
                    throw CloudflareError.configuration(.missingToken)
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
                    throw CloudflareError.configuration(.missingToken)
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

    private func persistCheckState(
        _ config: AppConfig,
        checkpointedMappingIDs: Set<String>,
        revision: UInt64
    ) throws -> UInt64 {
        let retainedRecoveryMappings = withState {
            mappingRecoveryMappings.filter {
                !checkpointedMappingIDs.contains($0.identifier)
            }
        }
        return try persistCheckState(
            config,
            recoveryMappings: retainedRecoveryMappings,
            revision: revision
        )
    }

    private func persistCheckState(
        _ config: AppConfig,
        recoveryMappings: [ActiveRouterMapping],
        revision: UInt64
    ) throws -> UInt64 {
        try requireCurrentRevision(revision)
        let retainedRecoveryMappings =
            deduplicatedRouterMappings(recoveryMappings)
        var committedRevision: UInt64?
        try withTransaction {
            try self.requireCurrentRevision(revision)
            try self.configStore.save(config)
            try self.requireCurrentRevision(revision)
            var journalErrors: [String] = []
            do {
                try self.configStore.saveMappingRecoveryJournal(
                    retainedRecoveryMappings
                )
            } catch {
                journalErrors.append(
                    "Primary journal: \(error.localizedDescription)"
                )
            }
            do {
                try self.emergencyMappingJournal.save(
                    retainedRecoveryMappings
                )
            } catch {
                journalErrors.append(
                    "Emergency journal: \(error.localizedDescription)"
                )
            }
            do {
                try self.fallbackMappingJournal.save(
                    retainedRecoveryMappings
                )
            } catch {
                journalErrors.append(
                    "Fallback journal: \(error.localizedDescription)"
                )
            }
            guard journalErrors.isEmpty else {
                throw NetworkAgentError.transactionFailed(
                    journalErrors.joined(separator: "\n")
                )
            }
            try self.requireCurrentRevision(revision)
            let committed = self.withState {
                guard self.configRevision == revision else {
                    return false
                }
                self.mappingRecoveryMappings =
                    retainedRecoveryMappings
                self.configPersistenceErrorMessage = nil
                self.commitConfigOnStateQueue(config)
                committedRevision = self.configRevision
                return true
            }
            guard committed else {
                throw NetworkAgentError.superseded
            }
        }
        guard let committedRevision else {
            throw NetworkAgentError.superseded
        }
        return committedRevision
    }

    private func deduplicatedRouterMappings(
        _ mappings: [ActiveRouterMapping]
    ) -> [ActiveRouterMapping] {
        var identifiers = Set<String>()
        return mappings.filter {
            identifiers.insert($0.identifier).inserted
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
        defer { checkCompletionObserver?() }

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

        if !workingConfig.remoteAccessEnabled {
            let cleanupMappings = deduplicatedRouterMappings(
                recoveredMappings
                    + workingConfig.activeRouterMappings
            )
            if !cleanupMappings.isEmpty {
                do {
                    try requireCurrentRevision(revision)
                    try saveAllRecoveryJournals(cleanupMappings)
                    withState {
                        guard configRevision == revision else { return }
                        mappingRecoveryMappings = cleanupMappings
                        restartExpirationTimerOnStateQueue()
                    }
                    try requireCurrentRevision(revision)
                    let report = try withCurrentCheckSideEffect(
                        revision: revision,
                        label: "router.recovery.delete"
                    ) {
                        routerMappingService.removeMappings(
                            cleanupMappings
                        )
                    }
                    let remainingMappings =
                        deduplicatedRouterMappings(
                            report.remainingMappings
                        )
                    workingConfig.activeRouterMappings =
                        remainingMappings
                    workingConfig.ipv6PinholeID =
                        remainingMappings.first {
                            $0.addressFamily == .ipv6
                                && $0.transport == .upnp
                        }?.pinholeID
                    let expectedRevision = try persistCheckState(
                        workingConfig,
                        recoveryMappings: remainingMappings,
                        revision: revision
                    )

                    guard report.allSucceeded,
                          remainingMappings.isEmpty,
                          workingConfig.activeRouterMappings.isEmpty else {
                        let detail = [
                            "Recovered router mappings still need cleanup.",
                            report.failureDescription,
                            "Gatebeam retained every unresolved identity in the main configuration and all recovery journals."
                        ]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                        next.ddnsStatus = .disabled(
                            "Waiting for router cleanup"
                        )
                        next.routerStatus = .failed(
                            "Router cleanup failed",
                            detail: detail
                        )
                        next.remoteDesktopStatus = .warning(
                            "A router rule may still be open",
                            detail: "Gatebeam will retry safe deletion or wait for its finite lease to expire."
                        )
                        next.externalReachabilityStatus = .disabled(
                            "Waiting for router cleanup"
                        )
                        next.lastCheckedAt = nowProvider()
                        withState {
                            guard configRevision == expectedRevision else {
                                return
                            }
                            routerMappingErrorMessage = detail
                            next.settingsErrorMessage = settingsErrorMessage
                            publishOnStateQueue(next)
                        }
                        return
                    }

                    next.ddnsStatus = .disabled(
                        "Remote access is off"
                    )
                    next.routerStatus = .disabled(
                        "Remote access is off"
                    )
                    next.remoteDesktopStatus = .disabled(
                        "Remote access is off"
                    )
                    next.externalReachabilityStatus = .disabled(
                        "Remote access is off"
                    )
                    next.lastCheckedAt = nowProvider()
                    withState {
                        guard configRevision == expectedRevision else {
                            return
                        }
                        routerMappingErrorMessage = nil
                        next.settingsErrorMessage = settingsErrorMessage
                        publishOnStateQueue(next)
                    }
                    return
                } catch {
                    guard !isSuperseded(error) else { return }
                    var retainedConfig = workingConfig
                    retainedConfig.activeRouterMappings =
                        cleanupMappings
                    retainedConfig.ipv6PinholeID =
                        cleanupMappings.first {
                            $0.addressFamily == .ipv6
                                && $0.transport == .upnp
                        }?.pinholeID
                    var retentionErrors: [String] = []
                    do {
                        try configStore.save(retainedConfig)
                    } catch {
                        retentionErrors.append(
                            "Main configuration: "
                                + error.localizedDescription
                        )
                    }
                    do {
                        try saveAllRecoveryJournals(
                            cleanupMappings
                        )
                    } catch {
                        retentionErrors.append(
                            "Recovery journals: "
                                + error.localizedDescription
                        )
                    }
                    let detail = (
                        [error.localizedDescription]
                            + retentionErrors
                            + [
                                "Gatebeam retained the unresolved mapping identity and will retry cleanup."
                            ]
                    ).joined(separator: "\n")
                    withState {
                        guard configRevision == revision else { return }
                        mappingRecoveryMappings = cleanupMappings
                        configPersistenceErrorMessage =
                            retentionErrors.isEmpty
                                ? nil
                                : retentionErrors.joined(
                                    separator: "\n"
                                )
                        routerMappingErrorMessage = detail
                        commitConfigOnStateQueue(retainedConfig)
                        let expectedRevision = configRevision
                        next.ddnsStatus = .disabled(
                            "Waiting for router cleanup"
                        )
                        next.routerStatus = .failed(
                            "Router cleanup could not be committed",
                            detail: detail
                        )
                        next.remoteDesktopStatus = .warning(
                            "A router rule may still be open",
                            detail: "Gatebeam will retry safe deletion or wait for its finite lease to expire."
                        )
                        next.externalReachabilityStatus = .disabled(
                            "Waiting for router cleanup"
                        )
                        next.lastCheckedAt = nowProvider()
                        guard configRevision == expectedRevision else {
                            return
                        }
                        next.settingsErrorMessage = settingsErrorMessage
                        publishOnStateQueue(next)
                    }
                    return
                }
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

        if workingConfig.accessExpiresAt != nil,
           let expiresUptime = accessExpiryUptime(workingConfig),
           expiresUptime <= monotonicUptimeProvider() {
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
                workingConfig.accessExpiresUptime = nil
                workingConfig.accessBootIdentifier = nil
                workingConfig.accessAnchorWallTime = nil
                workingConfig.accessRemainingAtAnchor = nil
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

        if !workingConfig.remoteAccessEnabled {
            var expectedRevision = revision
            if configChanged {
                do {
                    expectedRevision = try persistCheckState(
                        workingConfig,
                        checkpointedMappingIDs: [],
                        revision: revision
                    )
                } catch {
                    guard !isSuperseded(error) else { return }
                    let remainingRecoveryMappings = withState {
                        mappingRecoveryMappings
                    }
                    var persistenceErrors = [error.localizedDescription]
                    do {
                        try configStore.save(initialConfig)
                    } catch {
                        persistenceErrors.append(
                            "Fallback config: \(error.localizedDescription)"
                        )
                    }
                    do {
                        try saveAllRecoveryJournals(
                            remainingRecoveryMappings
                        )
                    } catch {
                        persistenceErrors.append(
                            "Fallback recovery journals: "
                                + error.localizedDescription
                        )
                    }
                    let detail = persistenceErrors.joined(separator: "\n")
                    withState {
                        guard configRevision == revision else { return }
                        configPersistenceErrorMessage = detail
                        commitConfigOnStateQueue(initialConfig)
                        expectedRevision = configRevision
                    }
                    next.ddnsStatus = .disabled(
                        "DDNS skipped because closed state was not committed"
                    )
                    next.routerStatus = .failed(
                        "Closed router state was not committed",
                        detail: detail
                    )
                    next.remoteDesktopStatus = .disabled(
                        "Remote access check stopped"
                    )
                    next.externalReachabilityStatus = .disabled(
                        "Remote access check stopped"
                    )
                    next.lastCheckedAt = nowProvider()
                    withState {
                        guard configRevision == expectedRevision else {
                            return
                        }
                        next.settingsErrorMessage = settingsErrorMessage
                        publishOnStateQueue(next)
                    }
                    return
                }
            }

            next.ddnsStatus = .disabled("Remote access is off")
            next.routerStatus = .disabled("Remote access is off")
            next.remoteDesktopStatus = .disabled("Remote access is off")
            next.externalReachabilityStatus = .disabled("Remote access is off")
            next.lastCheckedAt = nowProvider()
            withState {
                guard configRevision == expectedRevision else { return }
                next.settingsErrorMessage = settingsErrorMessage
                publishOnStateQueue(next)
            }
            return
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

        var mappingOutcome: RouterMappingOutcome?
        if workingConfig.remoteAccessEnabled {
            do {
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
                next.routerStatus = mapping.status
                if let port = mapping.ipv4Port { next.externalPort = port }
                next.ipv6ExternalPort = mapping.ipv6Port
                if !uncheckpointedMappings.isEmpty {
                    try configStore.saveMappingRecoveryJournal(uncheckpointedMappings)
                    withState {
                        mappingRecoveryMappings = uncheckpointedMappings
                        restartExpirationTimerOnStateQueue()
                    }
                }
                mappingOutcome = mapping
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
                let retainedDetail = withState {
                    routerMappingErrorMessage
                }
                next.routerStatus = .failed(
                    "Router access failed",
                    detail: [
                        Optional(next.routerStatus.detail),
                        retainedDetail,
                        Optional(error.localizedDescription)
                    ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { values, value in
                        if !values.contains(value) {
                            values.append(value)
                        }
                    }
                    .joined(separator: "\n")
                )
            }
        } else {
            next.routerStatus = .disabled("Remote access is off")
        }

        var expectedRevision = revision
        if configChanged {
            do {
                let checkpointedMappingIDs = Set(
                    mappingOutcome?.currentCheckProofs.compactMap {
                        $0.hasVerifiedMappingEvidence
                            ? $0.identity.mappingIdentifier
                            : nil
                    } ?? []
                )
                expectedRevision = try persistCheckState(
                    workingConfig,
                    checkpointedMappingIDs: checkpointedMappingIDs,
                    revision: revision
                )
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
                var fallbackPersistenceErrors: [String] = []
                do {
                    try configStore.save(fallback)
                } catch {
                    fallbackPersistenceErrors.append(
                        "Compensated config: \(error.localizedDescription)"
                    )
                }
                let remainingRecoveryMappings = withState {
                    mappingRecoveryMappings
                }
                do {
                    try saveAllRecoveryJournals(
                        remainingRecoveryMappings
                    )
                } catch {
                    fallbackPersistenceErrors.append(
                        "Compensated recovery journals: "
                            + error.localizedDescription
                    )
                }
                let persistenceDetail = (
                    [error.localizedDescription]
                        + fallbackPersistenceErrors
                ).joined(separator: "\n")
                let recoveryDetail = withState {
                    routerMappingErrorMessage
                }
                let routerFailureDetail = [
                    Optional(next.routerStatus.detail),
                    recoveryDetail,
                    Optional(persistenceDetail)
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { values, value in
                    if !values.contains(value) {
                        values.append(value)
                    }
                }
                .joined(separator: "\n")
                withState {
                    guard configRevision == revision else { return }
                    configPersistenceErrorMessage = persistenceDetail
                    commitConfigOnStateQueue(fallback)
                    expectedRevision = configRevision
                    next.settingsErrorMessage = settingsErrorMessage
                    publishCurrentSettingsErrorOnStateQueue()
                }
                next.routerStatus = .failed(
                    "Router state was not committed",
                    detail: routerFailureDetail
                )
                next.ddnsStatus = .failed(
                    "DDNS skipped because router state was not committed",
                    detail: "No Cloudflare request was sent."
                )
                buildConnectionURLs(
                    config: fallback,
                    status: &next
                )
                next.externalReachabilityStatus =
                    verifyLocalOriginTCPConnection(
                        config: fallback,
                        status: next
                    )
                next.lastCheckedAt = Date()
                withState {
                    guard configRevision == expectedRevision else {
                        return
                    }
                    next.settingsErrorMessage = settingsErrorMessage
                    publishOnStateQueue(next)
                }
                return
            }
        }
        mappingOutcome = mappingOutcome?.checkpointed(
            generation: expectedRevision
        )

        var ddnsIPv4: String?
        var ddnsIPv4Proof: RouterMappingCurrentCheckProof?
        var ipv4Issue: String?
        if workingConfig.preferredAddressFamily.usesIPv4 {
            let mappingRequired =
                workingConfig.mappingProtocolPreference != .disabled
            if mappingRequired,
               let proof = mappingOutcome?.verifiedProof(for: .ipv4) {
                ddnsIPv4Proof = proof
                next.publicAddress = proof.boundWANAddress
                if PublicIPService.isPublicIPv4(
                    proof.boundWANAddress
                ) {
                    ddnsIPv4 = proof.boundWANAddress
                } else {
                    let internetAddress = try? withCurrentCheckSideEffect(
                        revision: expectedRevision,
                        label: "public-ip.ipv4"
                    ) {
                        try makePublicIPService(
                            config: workingConfig
                        ).currentIPv4()
                    }
                    next.publicAddress =
                        internetAddress ?? proof.boundWANAddress
                    ipv4Issue =
                        "\(proof.transport.displayName) mapping is bound to "
                        + "non-public router WAN address "
                        + "\(proof.boundWANAddress)."
                }
            } else if mappingRequired {
                next.publicAddress = try? withCurrentCheckSideEffect(
                    revision: expectedRevision,
                    label: "public-ip.ipv4"
                ) {
                    try makePublicIPService(
                        config: workingConfig
                    ).currentIPv4()
                }
                ipv4Issue =
                    "No checkpointed IPv4 mapping proof was verified "
                    + "during this check; the A record was not updated."
            } else {
                do {
                    let address = try withCurrentCheckSideEffect(
                        revision: expectedRevision,
                        label: "public-ip.ipv4"
                    ) {
                        try makePublicIPService(
                            config: workingConfig
                        ).currentIPv4()
                    }
                    next.publicAddress = address
                    ddnsIPv4 = address
                } catch {
                    if isSuperseded(error) { return }
                    ipv4Issue = error.localizedDescription
                }
            }
        }

        var ddnsIPv6: String?
        var ddnsIPv6Proof: RouterMappingCurrentCheckProof?
        var ipv6Issue: String?
        if workingConfig.preferredAddressFamily.usesIPv6 {
            let mappingRequired =
                workingConfig.mappingProtocolPreference != .disabled
            if mappingRequired,
               let proof = mappingOutcome?.verifiedProof(for: .ipv6),
               PublicIPService.isGlobalIPv6(
                   proof.boundWANAddress
               ) {
                ddnsIPv6Proof = proof
                ddnsIPv6 = proof.boundWANAddress
                next.publicIPv6Address = proof.boundWANAddress
            } else if mappingRequired {
                next.publicIPv6Address = try? withCurrentCheckSideEffect(
                    revision: expectedRevision,
                    label: "public-ip.ipv6"
                ) {
                    try makePublicIPService(
                        config: workingConfig
                    ).currentIPv6()
                }
                ipv6Issue =
                    "No checkpointed IPv6 mapping proof was verified "
                    + "during this check; the AAAA record was not updated."
            } else if let localIPv6 {
                ddnsIPv6 = localIPv6
                let probedIPv6 = try? withCurrentCheckSideEffect(
                    revision: expectedRevision,
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
        } else {
            do {
                next.ddnsStatus = try updateDDNS(
                    config: workingConfig,
                    tokenResult: tokenResult,
                    ipv4Address: ddnsIPv4,
                    ipv6Address: ddnsIPv6,
                    ipv4Proof: ddnsIPv4Proof,
                    ipv6Proof: ddnsIPv6Proof,
                    ipv4Issue: ipv4Issue,
                    ipv6Issue: ipv6Issue,
                    revision: expectedRevision
                )
            } catch {
                guard !isSuperseded(error) else { return }
                next.ddnsStatus = .failed(
                    "DDNS update failed",
                    detail: error.localizedDescription
                )
            }
        }

        buildConnectionURLs(config: workingConfig, status: &next)
        next.externalReachabilityStatus = verifyLocalOriginTCPConnection(config: workingConfig, status: next)
        next.lastCheckedAt = Date()

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
        ipv4Proof: RouterMappingCurrentCheckProof?,
        ipv6Proof: RouterMappingCurrentCheckProof?,
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
                        label: "cloudflare.upsert-a",
                        preflight: {
                            try self.validateDDNSMappingProof(
                                ipv4Proof,
                                family: .ipv4,
                                address: ipv4Address,
                                config: config,
                                generation: revision
                            )
                        }
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
                    if (error as? DDNSMappingProofValidationError)?
                        .expired == true {
                        withState {
                            restartExpirationTimerOnStateQueue()
                        }
                    }
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
                        label: "cloudflare.upsert-aaaa",
                        preflight: {
                            try self.validateDDNSMappingProof(
                                ipv6Proof,
                                family: .ipv6,
                                address: ipv6Address,
                                config: config,
                                generation: revision
                            )
                        }
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
                    if (error as? DDNSMappingProofValidationError)?
                        .expired == true {
                        withState {
                            restartExpirationTimerOnStateQueue()
                        }
                    }
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

    private func validateDDNSMappingProof(
        _ proof: RouterMappingCurrentCheckProof?,
        family: RouterMappingAddressFamily,
        address: String,
        config: AppConfig,
        generation: UInt64
    ) throws {
        guard config.mappingProtocolPreference != .disabled else {
            return
        }
        guard let proof else {
            throw DDNSMappingProofValidationError(
                family: family,
                reason: "this check has no protocol-bound proof",
                expired: false
            )
        }
        guard proof.family == family,
              proof.boundWANAddress == address,
              proof.hasVerifiedMappingEvidence,
              proof.checkpointed,
              proof.checkpointGeneration == generation,
              config.activeRouterMappings.contains(where: {
                  $0.identifier == proof.identity.mappingIdentifier
              }) else {
            throw DDNSMappingProofValidationError(
                family: family,
                reason:
                    "the mapping identity, WAN evidence, or durable "
                    + "checkpoint generation changed",
                expired: false
            )
        }
        let currentUptime = monotonicUptimeProvider()
        guard currentUptime < proof.sideEffectDeadlineUptime else {
            throw DDNSMappingProofValidationError(
                family: family,
                reason:
                    "its monotonic lease safety deadline "
                    + "\(proof.sideEffectDeadlineUptime) has passed "
                    + "at \(currentUptime); renewal or recovery is required",
                expired: true
            )
        }
    }

    func currentPublicIPv4(
        config: AppConfig,
        gatewayAddress: String?,
        revision: UInt64,
        verifiedRouterWANAddress: String? = nil
    ) throws -> PublicIPv4Discovery {
        var routerWANAddress = verifiedRouterWANAddress.flatMap {
            PublicIPService.looksLikeIPv4($0) ? $0 : nil
        }
        var routerWANVerified = routerWANAddress != nil
        if let routerWANAddress,
           PublicIPService.isPublicIPv4(routerWANAddress) {
            return PublicIPv4Discovery(
                publicAddress: routerWANAddress,
                routerWANAddress: routerWANAddress,
                routerWANVerified: true,
                blocksDDNS: false
            )
        }
        if !routerWANVerified, let gatewayAddress {
            do {
                let routerAddress = try withCurrentCheckSideEffect(
                    revision: revision,
                    label: "router.wan-ipv4"
                ) {
                    if config.mappingProtocolPreference == .automatic {
                        return try routerMappingService
                            .externalIPv4AddressForAutomaticMapping(
                                gatewayAddress: gatewayAddress
                            )
                    }
                    return try routerMappingService.externalIPv4Address(
                        gatewayAddress: gatewayAddress
                    )
                }
                if PublicIPService.looksLikeIPv4(routerAddress) {
                    routerWANAddress = routerAddress
                    routerWANVerified = true
                    if PublicIPService.isPublicIPv4(routerAddress) {
                        return PublicIPv4Discovery(
                            publicAddress: routerAddress,
                            routerWANAddress: routerAddress,
                            routerWANVerified: true,
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
            routerWANVerified: routerWANVerified,
            blocksDDNS:
                config.mappingProtocolPreference == .automatic
                    ? (
                        !routerWANVerified
                            || routerWANAddress.map {
                                !PublicIPService.isPublicIPv4($0)
                            } ?? true
                    )
                    : routerWANAddress.map {
                        !PublicIPService.isPublicIPv4($0)
                    } ?? false
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
        var currentCheckProofs: [RouterMappingCurrentCheckProof] = []
        var activeMappings = config.activeRouterMappings
        let now = nowProvider()
        let nowUptime = monotonicUptimeProvider()
        let clockContinuityMappings = activeMappings.filter {
            $0.recoveryState == .wallClockRollback
                || $0.recoveryState == .clockContinuityUnverified
        }
        let epochCandidates = activeMappings.filter {
            $0.recoveryState != .wallClockRollback
                && $0.recoveryState != .clockContinuityUnverified
        }

        let epochReport = try withCurrentCheckSideEffect(
            revision: revision,
            label: "router.mapping.epoch-health"
        ) {
            try routerMappingService.verifyMappingsForCurrentCheck(
                epochCandidates
            )
        }
        activeMappings = epochReport.refreshedMappings
            + clockContinuityMappings
        let addressInvalidations = epochReport.invalidations.compactMap {
            invalidation -> ActiveRouterMapping? in
            guard case .effectiveClientAddressChanged(let replacement) =
                    invalidation.reason else {
                return nil
            }
            var orphan = invalidation.mapping
            orphan.recoveryState = .effectiveClientAddressChanged
            orphan.replacementLocalAddress = replacement
            return orphan
        }
        activeMappings.append(contentsOf: addressInvalidations)
        let stateLossInvalidations = epochReport.invalidations.filter {
            if case .routerStateLost = $0.reason { return true }
            return false
        }
        if !stateLossInvalidations.isEmpty {
            let protocols = Set(
                stateLossInvalidations.map {
                    $0.mapping.transport.displayName
                }
            ).sorted().joined(separator: ", ")
            successes.append(
                "\(protocols) router restart or state loss detected; rebuilding mappings now"
            )
        }
        if !epochReport.errors.isEmpty {
            failures.append(
                "Router Epoch health check: "
                    + epochReport.errors.joined(separator: "\n")
            )
        }

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

        var replacementBlockedFamilies: Set<RouterMappingAddressFamily> = []
        for rollbackMapping in clockContinuityMappings {
            let report = try withCurrentCheckSideEffect(
                revision: revision,
                label: "router.mapping.clock-rollback-cleanup"
            ) {
                routerMappingService.removeMappings([rollbackMapping])
            }
            if report.allSucceeded {
                activeMappings.removeAll {
                    $0.identifier == rollbackMapping.identifier
                }
                successes.append(
                    "\(rollbackMapping.addressFamily.displayName): "
                        + "removed the pre-rollback "
                        + "\(rollbackMapping.transport.displayName) mapping"
                )
            } else {
                replacementBlockedFamilies.insert(
                    rollbackMapping.addressFamily
                )
                failures.append(
                    "\(rollbackMapping.addressFamily.displayName): wall clock "
                        + "rollback made the persisted lease unsafe; replacement "
                        + "is blocked until cleanup is confirmed. "
                        + report.failureDescription
                )
            }
        }
        for orphan in addressInvalidations {
            if mappingHasExpired(orphan, atUptime: nowUptime) {
                activeMappings.removeAll {
                    $0.identifier == orphan.identifier
                }
                successes.append(
                    "\(orphan.addressFamily.displayName): old "
                        + "\(orphan.transport.displayName) lease for "
                        + "\(orphan.localAddress) expired; replacement may proceed"
                )
                continue
            }
            let report = try withCurrentCheckSideEffect(
                revision: revision,
                label: "router.mapping.address-change-cleanup"
            ) {
                routerMappingService.removeMappings([orphan])
            }
            if report.allSucceeded {
                activeMappings.removeAll {
                    $0.identifier == orphan.identifier
                }
                successes.append(
                    "\(orphan.addressFamily.displayName): confirmed deletion of "
                        + "the old \(orphan.transport.displayName) identity "
                        + "\(orphan.localAddress)"
                )
            } else {
                replacementBlockedFamilies.insert(orphan.addressFamily)
                failures.append(
                    "\(orphan.addressFamily.displayName): effective address changed "
                        + "from \(orphan.localAddress) to "
                        + "\(orphan.replacementLocalAddress ?? "unknown"); "
                        + "replacement is blocked until the old lease is deleted "
                        + "or expires. \(report.failureDescription)"
                )
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
            if replacementBlockedFamilies.contains(family) {
                return
            }
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
                let remaining = max(
                    0,
                    Int(
                        mappingExpiryUptime(
                            compatible,
                            now: now,
                            uptime: nowUptime
                        ) - nowUptime
                    )
                )
                if mappingHasExpired(compatible, atUptime: nowUptime),
                   !config.autoRenewMapping {
                    activeMappings.removeAll {
                        $0.identifier == compatible.identifier
                    }
                    failures.append(
                        "\(familyName): the \(compatible.transport.displayName) lease expired while Auto Renew was off"
                    )
                    return
                }
                if nowUptime < mappingRenewUptime(
                    compatible,
                    now: now,
                    uptime: nowUptime
                )
                    || !config.autoRenewMapping {
                    if mappingHasExpired(compatible, atUptime: nowUptime) {
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
                        if let proof = epochReport
                            .currentCheckProofs.first(where: {
                                $0.identity.mappingIdentifier
                                    == compatible.identifier
                            }) {
                            currentCheckProofs.append(proof)
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
                        try routerMappingService.renewMapping(
                            config: renewalConfig,
                            mapping: compatible
                        )
                    }
                    let renewedMapping = result.activeMapping
                    activeMappings.removeAll { $0.identifier == compatible.identifier }
                    activeMappings.append(renewedMapping)
                    successes.append("\(familyName): renewed \(result.message) via \(result.protocolName)")
                    if family == .ipv4 {
                        ipv4Port = result.externalPort
                    } else {
                        ipv6Port = result.externalPort
                    }
                    currentCheckProofs.append(
                        result.currentCheckProof
                    )
                } catch {
                    if isSuperseded(error) { throw error }
                    if let recovery = error as? RouterMappingRecoveryRequiredError {
                        retainRecoveryMapping(recovery)
                        failures.append(
                            "\(familyName) renewal requires recovery: "
                                + recovery.localizedDescription
                        )
                        return
                    }
                    if !mappingHasExpired(
                        compatible,
                        atUptime: monotonicUptimeProvider()
                    ) {
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
                let createdMapping = result.activeMapping
                activeMappings.append(createdMapping)
                successes.append("\(familyName): \(result.message) via \(result.protocolName)")
                if family == .ipv4 {
                    ipv4Port = result.externalPort
                } else {
                    ipv6Port = result.externalPort
                }
                currentCheckProofs.append(
                    result.currentCheckProof
                )
            } catch {
                if isSuperseded(error) { throw error }
                if let recovery = error as? RouterMappingRecoveryRequiredError {
                    retainRecoveryMapping(recovery)
                    failures.append(
                        "\(familyName) mapping requires recovery: "
                            + recovery.localizedDescription
                    )
                    return
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
            activeMappings: activeMappings,
            currentCheckProofs: currentCheckProofs
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
        status.connectionURL = nil
        status.connectionURLIPv4 = nil
        status.connectionURLIPv6 = nil
        guard config.remoteAccessEnabled else { return }

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
        let now = nowProvider()
        let uptime = monotonicUptimeProvider()
        let temporaryDeadlineRequiresShorterLease = accessExpiryUptime(
            requested,
            now: now,
            uptime: uptime
        ).map { deadline in
            previous.activeRouterMappings.contains {
                mappingExpiryUptime(
                    $0,
                    now: now,
                    uptime: uptime
                ) > deadline
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
        if trackedMappings.isEmpty,
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

        let report: RouterMappingRemovalReport
        if trackedMappings.isEmpty {
            report = try withRevisionBoundSideEffect(
                revision: expectedRevision,
                label: "router.mapping.legacy-delete"
            ) {
                routerMappingService.removeLegacyMappings(
                    config: previous,
                    localIPv4: localIPv4,
                    gatewayIPv4: gatewayIPv4,
                    localIPv6: localIPv6,
                    gatewayIPv6: gatewayIPv6
                )
            }
        } else {
            report = try withRevisionBoundSideEffect(
                revision: expectedRevision,
                label: "router.mapping.config-delete"
            ) {
                routerMappingService.removeMappings(trackedMappings)
            }
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

    private func withKeychainTransaction<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: keychainQueueKey) != nil {
            return try body()
        }
        return try keychainQueue.sync(execute: body)
    }

    private func reserveSettingsRequest() -> (generation: UInt64, configRevision: UInt64) {
        withState {
            settingsRequestGeneration &+= 1
            return (settingsRequestGeneration, configRevision)
        }
    }

    private func resolveSettingsRequestConfigRevision(
        generation: UInt64,
        requestedConfigRevision: UInt64
    ) throws -> UInt64 {
        let resolvedRevision = withState { () -> UInt64? in
            guard lastCommittedSettingsGeneration < generation else { return nil }
            if configRevision == requestedConfigRevision {
                return configRevision
            }
            if lastCommittedSettingsGeneration &+ 1 == generation,
               configRevision == lastSettingsCommitRevision {
                return configRevision
            }
            return nil
        }
        guard let resolvedRevision else {
            throw NetworkAgentError.superseded
        }
        return resolvedRevision
    }

    private func requireCurrentSettingsRequest(
        generation: UInt64,
        configRevision expectedConfigRevision: UInt64
    ) throws {
        let isCurrent = withState {
            settingsRequestGeneration >= generation
                && lastCommittedSettingsGeneration < generation
                && configRevision == expectedConfigRevision
        }
        guard isCurrent else {
            throw NetworkAgentError.superseded
        }
    }

    private func beginConfigMutation() -> UInt64 {
        routerMappingService.cancelCurrentOperations()
        return sideEffectGate.sync {
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
        preflight: () throws -> Void = {},
        _ body: () throws -> T
    ) throws -> T {
        try sideEffectGate.sync {
            try withState {
                guard configRevision == revision, activeConfigMutationRevision == nil else {
                    throw NetworkAgentError.superseded
                }
            }
            try preflight()
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
            if periodicTimerScheduler == nil, isRunning {
                nextPeriodicCheckUptime = monotonicUptimeProvider() + (
                    AppConfig.normalizedCheckInterval(
                        storedConfig.checkIntervalSeconds
                    )
                )
                restartExpirationTimerOnStateQueue()
            }
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
        timer = nil
        let interval = AppConfig.normalizedCheckInterval(storedConfig.checkIntervalSeconds)
        let handler: () -> Void = { [weak self] in
            guard let self else { return }
            self.scheduleCheck(retryKeychainAfterFailure: false)
        }
        if let periodicTimerScheduler {
            nextPeriodicCheckUptime = nil
            timer = periodicTimerScheduler(interval, handler)
            return
        }
        nextPeriodicCheckUptime = monotonicUptimeProvider() + interval
        restartExpirationTimerOnStateQueue()
    }

    private func mappingExpiryUptime(
        _ mapping: ActiveRouterMapping,
        now: Date? = nil,
        uptime: TimeInterval? = nil
    ) -> TimeInterval {
        if mapping.leaseBootIdentifier == bootIdentifierProvider(),
           let deadline = mapping.leaseExpiresUptime {
            return deadline
        }
        let currentNow = now ?? nowProvider()
        let currentUptime = uptime ?? monotonicUptimeProvider()
        return currentUptime
            + max(0, mapping.leaseExpiresAt.timeIntervalSince(currentNow))
    }

    private func mappingRenewUptime(
        _ mapping: ActiveRouterMapping,
        now: Date? = nil,
        uptime: TimeInterval? = nil
    ) -> TimeInterval {
        if mapping.leaseBootIdentifier == bootIdentifierProvider(),
           let deadline = mapping.renewAfterUptime {
            return deadline
        }
        let currentNow = now ?? nowProvider()
        let currentUptime = uptime ?? monotonicUptimeProvider()
        return currentUptime
            + max(0, mapping.renewAfter.timeIntervalSince(currentNow))
    }

    private func accessExpiryUptime(
        _ config: AppConfig,
        now: Date? = nil,
        uptime: TimeInterval? = nil
    ) -> TimeInterval? {
        guard let wallDeadline = config.accessExpiresAt else { return nil }
        if config.accessBootIdentifier == bootIdentifierProvider(),
           let deadline = config.accessExpiresUptime {
            return deadline
        }
        let currentNow = now ?? nowProvider()
        let currentUptime = uptime ?? monotonicUptimeProvider()
        return currentUptime
            + max(0, wallDeadline.timeIntervalSince(currentNow))
    }

    private func mappingHasExpired(
        _ mapping: ActiveRouterMapping,
        atUptime uptime: TimeInterval
    ) -> Bool {
        uptime >= mappingExpiryUptime(mapping)
    }

    private static func restoreRuntimeDeadlines(
        config: inout AppConfig,
        recoveryMappings: inout [ActiveRouterMapping],
        now: Date,
        uptime: TimeInterval,
        bootIdentifier: String
    ) {
        func restore(_ mapping: ActiveRouterMapping) -> ActiveRouterMapping {
            if mapping.leaseBootIdentifier == bootIdentifier,
               mapping.leaseExpiresUptime != nil,
               mapping.renewAfterUptime != nil {
                return mapping
            }
            var restored = mapping
            let recoveryWait = min(
                86_400,
                max(
                    0,
                    mapping.leaseRemainingAtAnchor ?? 86_400
                )
            )
            restored.leaseExpiresUptime = uptime
            restored.renewAfterUptime = uptime
            restored.leaseBootIdentifier = bootIdentifier
            restored.leaseAnchorWallTime = now
            restored.leaseRemainingAtAnchor = recoveryWait
            restored.renewRemainingAtAnchor = 0
            restored.recoveryState = .clockContinuityUnverified
            restored.replacementLocalAddress = nil
            restored.recoverySafeAfterUptime = uptime + recoveryWait
            restored.recoveryBootIdentifier = bootIdentifier
            restored.leaseExpiresAt = now
            restored.renewAfter = now
            if restored.transport == .pcp
                || restored.transport == .natpmp {
                restored.routerEpochHealthCheckAfter = now
                restored.routerEpochHealthCheckUptime = uptime
            }
            return restored
        }

        config.activeRouterMappings = config.activeRouterMappings.map(restore)
        recoveryMappings = recoveryMappings.map(restore)

        guard config.remoteAccessEnabled,
              config.accessExpiresAt != nil else {
            config.accessExpiresUptime = nil
            config.accessBootIdentifier = nil
            config.accessAnchorWallTime = nil
            config.accessRemainingAtAnchor = nil
            return
        }
        if config.accessBootIdentifier == bootIdentifier,
           config.accessExpiresUptime != nil {
            return
        }
        var knownRecoveryIDs = Set(
            recoveryMappings.map(\.identifier)
        )
        recoveryMappings.append(
            contentsOf: config.activeRouterMappings.filter {
                knownRecoveryIDs.insert($0.identifier).inserted
            }
        )
        config.activeRouterMappings = []
        config.remoteAccessEnabled = false
        config.accessExpiresAt = nil
        config.accessExpiresUptime = nil
        config.accessBootIdentifier = nil
        config.accessAnchorWallTime = nil
        config.accessRemainingAtAnchor = nil
    }

    private func restartExpirationTimerOnStateQueue() {
        expirationTimer?.cancel()
        expirationTimer = nil
        guard sideEffectsEnabled, isRunning else { return }

        let now = nowProvider()
        let nowUptime = monotonicUptimeProvider()
        var deadlines: [TimeInterval] = []
        if periodicTimerScheduler == nil {
            if nextPeriodicCheckUptime == nil {
                nextPeriodicCheckUptime = nowUptime + (
                    AppConfig.normalizedCheckInterval(
                        storedConfig.checkIntervalSeconds
                    )
                )
            }
            if let nextPeriodicCheckUptime {
                deadlines.append(nextPeriodicCheckUptime)
            }
        }
        if storedConfig.remoteAccessEnabled,
           let accessExpiresUptime = accessExpiryUptime(
               storedConfig,
               now: now,
               uptime: nowUptime
           ) {
            deadlines.append(accessExpiresUptime)
        }
        let recoveryCandidates = storedConfig.activeRouterMappings + mappingRecoveryMappings
        if storedConfig.remoteAccessEnabled {
            if storedConfig.autoRenewMapping {
                deadlines.append(
                    contentsOf: recoveryCandidates.map {
                        mappingRenewUptime(
                            $0,
                            now: now,
                            uptime: nowUptime
                        )
                    }
                )
            }
            deadlines.append(
                contentsOf: recoveryCandidates.compactMap { mapping in
                    guard mapping.transport == .pcp
                            || mapping.transport == .natpmp else {
                        return nil
                    }
                    if mapping.routerEpochBootIdentifier
                            == bootIdentifierProvider(),
                       let deadline =
                            mapping.routerEpochHealthCheckUptime {
                        return deadline
                    }
                    if let wallDeadline =
                            mapping.routerEpochHealthCheckAfter {
                        return nowUptime + max(
                            0,
                            wallDeadline.timeIntervalSince(now)
                        )
                    }
                    return nowUptime
                }
            )
        }
        deadlines.append(
            contentsOf: recoveryCandidates.compactMap { mapping in
                guard mapping.addressFamily == .ipv6,
                      mapping.transport == .upnp else {
                    return nil
                }
                return mappingExpiryUptime(
                    mapping,
                    now: now,
                    uptime: nowUptime
                )
            }
        )
        deadlines.append(
            contentsOf: recoveryCandidates.compactMap { mapping in
                guard mapping.recoveryBootIdentifier
                        == bootIdentifierProvider() else {
                    return nil
                }
                return mapping.recoverySafeAfterUptime
            }
        )
        guard let safetyDeadline = deadlines.min() else {
            expirationRetryNotBeforeUptime = nil
            return
        }

        let scheduledUptime: TimeInterval
        if safetyDeadline > nowUptime {
            expirationRetryNotBeforeUptime = nil
            scheduledUptime = safetyDeadline
        } else if let retry = expirationRetryNotBeforeUptime,
                  retry > nowUptime {
            scheduledUptime = retry
        } else {
            scheduledUptime = nowUptime + 0.05
        }
        let scheduledDeadline = now.addingTimeInterval(
            max(0, scheduledUptime - nowUptime)
        )
        expirationTimer = expirationTimerScheduler(scheduledDeadline) { [weak self] in
            self?.handleExpirationTimerFired()
        }
    }

    private func handleExpirationTimerFired() {
        transactionQueue.async {
            guard self.sideEffectsEnabled else { return }
            let nowUptime = self.monotonicUptimeProvider()
            self.withState {
                self.expirationRetryNotBeforeUptime = nowUptime + 30
            }
            let snapshot = self.config
            if snapshot.remoteAccessEnabled,
               let expiresAt = snapshot.accessExpiresAt,
               let expiresUptime = self.accessExpiryUptime(
                   snapshot,
                   now: self.nowProvider(),
                   uptime: nowUptime
               ),
               expiresUptime <= nowUptime {
                self.expireTemporaryAccessOnTransactionQueue(
                    expectedExpiration: expiresAt,
                    nowUptime: nowUptime
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
        nowUptime: TimeInterval
    ) {
        let mutationRevision = beginConfigMutation()
        defer { endConfigMutation(mutationRevision) }
        var previousConfig = config
        guard previousConfig.remoteAccessEnabled,
              let currentExpiration = previousConfig.accessExpiresAt,
              let currentExpirationUptime =
                accessExpiryUptime(
                    previousConfig,
                    now: nowProvider(),
                    uptime: nowUptime
                ),
              currentExpiration == expectedExpiration,
              currentExpirationUptime <= nowUptime else {
            return
        }

        var expiredConfig = previousConfig
        do {
            if mappingLifecycleChanged(from: previousConfig, to: {
                var disabled = previousConfig
                disabled.remoteAccessEnabled = false
                disabled.accessExpiresAt = nil
                disabled.accessExpiresUptime = nil
                disabled.accessBootIdentifier = nil
                disabled.accessAnchorWallTime = nil
                disabled.accessRemainingAtAnchor = nil
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
            expiredConfig.accessExpiresUptime = nil
            expiredConfig.accessBootIdentifier = nil
            expiredConfig.accessAnchorWallTime = nil
            expiredConfig.accessRemainingAtAnchor = nil
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
    var currentCheckProofs: [RouterMappingCurrentCheckProof] = []

    func checkpointed(
        generation: UInt64
    ) -> RouterMappingOutcome {
        var result = self
        result.currentCheckProofs = currentCheckProofs.map {
            var proof = $0
            proof.checkpointed = true
            proof.checkpointGeneration = generation
            return proof
        }
        return result
    }

    func verifiedProof(
        for family: RouterMappingAddressFamily
    ) -> RouterMappingCurrentCheckProof? {
        currentCheckProofs.first {
            $0.family == family && $0.isVerified
        }
    }
}

struct PublicIPv4Discovery {
    let publicAddress: String
    let routerWANAddress: String?
    let routerWANVerified: Bool
    let blocksDDNS: Bool
}
