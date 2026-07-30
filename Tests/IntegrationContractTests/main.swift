import Foundation
import Darwin
import AppKit
import LocalAuthentication
import Security

struct IntegrationContractFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct SimulatedKeychainFailure: Error, LocalizedError {
    let operation: String

    var errorDescription: String? {
        "Simulated Keychain \(operation) failure"
    }
}

struct SimulatedLeakingCloudflareFailure: Error, LocalizedError {
    let secret: String

    var errorDescription: String? {
        "Authorization Bearer \(secret) through proxy-user:proxy-password"
    }
}

final class LockedCounter {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let result = value
        lock.unlock()
        return result
    }

    var current: Int {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }
}

struct KeychainQueryRecord {
    let operation: KeychainQueryOperation
    let interaction: KeychainInteraction
    let hasAuthenticationContext: Bool
    let authenticationContextInteractionNotAllowed: Bool?
    let authenticationUIValue: String?
}

final class LockedKeychainQueryAudit {
    private let lock = NSLock()
    private var records: [KeychainQueryRecord] = []

    func observe(
        operation: KeychainQueryOperation,
        interaction: KeychainInteraction,
        query: [String: Any]
    ) {
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        let authenticationUIValue = query[kSecUseAuthenticationUI as String] as? String
        lock.lock()
        records.append(
            KeychainQueryRecord(
                operation: operation,
                interaction: interaction,
                hasAuthenticationContext: context != nil,
                authenticationContextInteractionNotAllowed: context?.interactionNotAllowed,
                authenticationUIValue: authenticationUIValue
            )
        )
        lock.unlock()
    }

    var snapshot: [KeychainQueryRecord] {
        lock.lock()
        let result = records
        lock.unlock()
        return result
    }
}

final class AuditedLAContext: LAContext {
    private var storedInteractionNotAllowed = false

    override var interactionNotAllowed: Bool {
        get { storedInteractionNotAllowed }
        set { storedInteractionNotAllowed = newValue }
    }
}

final class LockedClock {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

final class LockedMonotonicClock {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }

    func now() -> TimeInterval {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

struct SimulatedRouterFailure: Error, LocalizedError {
    let operation: String

    var errorDescription: String? {
        "Simulated router \(operation) failure"
    }
}

final class MockLocalNetworkService: LocalNetworkServicing {
    private let calls = LockedCounter()
    var ipv4Address: String? = "192.0.2.20"
    var ipv4Gateway: String? = "192.0.2.1"
    var ipv6Address: String? = "2001:db8::20"
    var ipv6Gateway: String? = "2001:db8::1"
    var listening = true
    var beforeListeningCheck: (() -> Void)?

    var callCount: Int {
        calls.current
    }

    func localIPv4Address() -> String? {
        calls.increment()
        return ipv4Address
    }

    func globalIPv6Address() -> String? {
        calls.increment()
        return ipv6Address
    }

    func defaultGatewayIPv4() -> String? {
        calls.increment()
        return ipv4Gateway
    }

    func defaultGatewayIPv6() -> String? {
        calls.increment()
        return ipv6Gateway
    }

    func isTCPPortListening(port: UInt16, timeout: TimeInterval) -> Bool {
        calls.increment()
        beforeListeningCheck?()
        return listening
    }

    func isTCPPortOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        calls.increment()
        return false
    }
}

final class MockRouterMappingService: RouterMappingServicing {
    private let lock = NSLock()
    private let operations = LockedCounter()
    private var storedRemovalCalls: [ActiveRouterMapping] = []
    private var storedEnsureCalls: [RouterMappingAddressFamily] = []
    private var failedRemovalIDs: Set<String> = []
    private var failedEnsureFamilies: Set<RouterMappingAddressFamily> = []
    private var ensureError: Error?
    private var recoveryFailure: RouterMappingRecoveryRequiredError?
    private var legacyRemovalReport = RouterMappingRemovalReport(attempts: [])
    private var storedLegacyRemovalCallCount = 0
    private var storedExternalIPv4CallCount = 0
    private var epochInvalidatedIDs: Set<String> = []
    private var epochAddressChanges: [String: String] = [:]
    private var verificationFailureIDs: Set<String> = []
    var failAllRemovals = false
    var beforeRemoval: (() -> Void)?
    var afterRemoval: (() -> Void)?
    var beforeEnsure: (() -> Void)?
    var beforeEnsureFamily:
        ((RouterMappingAddressFamily) -> Void)?
    var cancellationHandler: (() -> Void)?
    var externalIPv4 = "192.0.2.53"
    var externalIPv4Failure: Error?
    var nowProvider: () -> Date = Date.init
    var monotonicUptimeProvider: () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }
    var bootIdentifierProvider: () -> String = {
        RouterMappingService.systemBootIdentifier
    }

    var removalCalls: [ActiveRouterMapping] {
        lock.lock()
        let result = storedRemovalCalls
        lock.unlock()
        return result
    }

    var ensureCalls: [RouterMappingAddressFamily] {
        lock.lock()
        let result = storedEnsureCalls
        lock.unlock()
        return result
    }

    var operationCount: Int {
        operations.current
    }

    var legacyRemovalCallCount: Int {
        lock.lock()
        let result = storedLegacyRemovalCallCount
        lock.unlock()
        return result
    }

    var externalIPv4CallCount: Int {
        lock.lock()
        let result = storedExternalIPv4CallCount
        lock.unlock()
        return result
    }

    func setRemovalFailures(_ mappings: [ActiveRouterMapping]) {
        lock.lock()
        failedRemovalIDs = Set(mappings.map(\.identifier))
        lock.unlock()
    }

    func setEnsureFailures(_ families: Set<RouterMappingAddressFamily>) {
        lock.lock()
        failedEnsureFamilies = families
        lock.unlock()
    }

    func setEnsureError(_ error: Error?) {
        lock.lock()
        ensureError = error
        lock.unlock()
    }

    func setRecoveryFailure(_ failure: RouterMappingRecoveryRequiredError?) {
        lock.lock()
        recoveryFailure = failure
        lock.unlock()
    }

    func setLegacyRemovalReport(_ report: RouterMappingRemovalReport) {
        lock.lock()
        legacyRemovalReport = report
        lock.unlock()
    }

    func setEpochInvalidations(_ mappings: [ActiveRouterMapping]) {
        lock.lock()
        epochInvalidatedIDs = Set(mappings.map(\.identifier))
        lock.unlock()
    }

    func setEpochAddressChange(
        _ mapping: ActiveRouterMapping,
        replacementAddress: String
    ) {
        lock.lock()
        epochAddressChanges[mapping.identifier] = replacementAddress
        lock.unlock()
    }

    func setVerificationFailures(
        _ mappings: [ActiveRouterMapping]
    ) {
        lock.lock()
        verificationFailureIDs = Set(
            mappings.map(\.identifier)
        )
        lock.unlock()
    }

    func externalIPv4Address(gatewayAddress: String) throws -> String {
        operations.increment()
        lock.lock()
        storedExternalIPv4CallCount += 1
        let address = externalIPv4
        let failure = externalIPv4Failure
        lock.unlock()
        if let failure { throw failure }
        return address
    }

    func cancelCurrentOperations() {
        cancellationHandler?()
    }

    func ensureMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        try ensure(
            family: .ipv4,
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        )
    }

    func ensureIPv6Pinhole(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        try ensure(
            family: .ipv6,
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        )
    }

    func removeMappings(_ mappings: [ActiveRouterMapping]) -> RouterMappingRemovalReport {
        operations.increment()
        beforeRemoval?()
        defer { afterRemoval?() }
        lock.lock()
        storedRemovalCalls.append(contentsOf: mappings)
        let failures = failedRemovalIDs
        let failEveryMapping = failAllRemovals
        lock.unlock()
        return RouterMappingRemovalReport(
            attempts: mappings.map {
                RouterMappingRemovalAttempt(
                    mapping: $0,
                    errorDescription: failEveryMapping || failures.contains($0.identifier)
                        ? SimulatedRouterFailure(operation: "delete").localizedDescription
                        : nil
                )
            }
        )
    }

    func removeLegacyMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> RouterMappingRemovalReport {
        operations.increment()
        lock.lock()
        storedLegacyRemovalCallCount += 1
        let report = legacyRemovalReport
        lock.unlock()
        return report
    }

    func verifyMappingsForCurrentCheck(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport {
        lock.lock()
        let invalidated = mappings.filter {
            epochInvalidatedIDs.contains($0.identifier)
        }
        let invalidatedIDs = Set(invalidated.map(\.identifier))
        let addressChanges = epochAddressChanges
        let verificationFailures = verificationFailureIDs
        lock.unlock()
        let addressInvalidations = mappings.compactMap { mapping in
            addressChanges[mapping.identifier].map {
                RouterMappingInvalidation(
                    mapping: mapping,
                    reason: .effectiveClientAddressChanged(
                        replacementAddress: $0
                    )
                )
            }
        }
        let allInvalidatedIDs = invalidatedIDs.union(
            addressInvalidations.map { $0.mapping.identifier }
        )
        let refreshed = mappings.filter {
                !allInvalidatedIDs.contains($0.identifier)
            }
        return RouterMappingEpochReport(
            refreshedMappings: refreshed,
            invalidations: invalidated.map {
                RouterMappingInvalidation(
                    mapping: $0,
                    reason: .routerStateLost
                )
            } + addressInvalidations,
            errors: refreshed.filter {
                verificationFailures.contains($0.identifier)
            }.map {
                "Injected \($0.transport.displayName) verification failure"
            },
            currentCheckProofs: refreshed.compactMap {
                verificationFailures.contains($0.identifier)
                    ? nil
                    : currentCheckProof(for: $0)
            }
        )
    }

    private func currentCheckProof(
        for mapping: ActiveRouterMapping
    ) -> RouterMappingCurrentCheckProof? {
        guard let address = mapping.routerExternalAddress else {
            return nil
        }
        let nowUptime = monotonicUptimeProvider()
        let leaseExpiresUptime =
            mapping.leaseExpiresUptime
            ?? nowUptime + max(
                0,
                mapping.leaseExpiresAt.timeIntervalSince(
                    nowProvider()
                )
            )
        return RouterMappingCurrentCheckProof(
            family: mapping.addressFamily,
            transport: mapping.transport,
            identity: RouterMappingProofIdentity(
                mappingIdentifier: mapping.identifier,
                effectiveSourceAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                protocolBinding: mapping.pcpNonce,
                internalPort: mapping.internalPort,
                externalPort: mapping.externalPort,
                pinholeID: mapping.pinholeID
            ),
            boundWANAddress: address,
            verifiedAtUptime: nowUptime,
            leaseExpiresUptime: leaseExpiresUptime,
            sideEffectSafetyMargin:
                RouterMappingCurrentCheckProof
                    .defaultSideEffectSafetyMargin,
            mappingIdentityVerified: true,
            boundWANEvidenceVerified: true,
            sameBootVerified: true,
            leaseVerified: true,
            epochOrIGDContinuityVerified: true,
            checkpointed: false
        )
    }

    private func ensure(
        family: RouterMappingAddressFamily,
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        operations.increment()
        beforeEnsure?()
        lock.lock()
        storedEnsureCalls.append(family)
        let shouldFail = failedEnsureFamilies.contains(family)
        let injectedEnsureError = ensureError
        let injectedRecovery = recoveryFailure
        lock.unlock()
        beforeEnsureFamily?(family)
        if let injectedEnsureError {
            throw injectedEnsureError
        }
        if let injectedRecovery {
            throw injectedRecovery
        }
        if shouldFail {
            throw SimulatedRouterFailure(operation: "\(family.displayName) ensure")
        }
        if family == .ipv6,
           config.mappingProtocolPreference == .natpmp {
            throw SimulatedRouterFailure(
                operation: "NAT-PMP IPv6 unsupported"
            )
        }

        let transport: RouterMappingTransport
        switch config.mappingProtocolPreference {
        case .pcp, .automatic:
            transport = .pcp
        case .natpmp:
            transport = .natpmp
        case .upnp:
            transport = .upnp
        case .disabled:
            throw SimulatedRouterFailure(operation: "disabled ensure")
        }
        let externalPort = family == .ipv4 ? config.externalPort : config.internalPort
        let pinholeID: UInt16? = family == .ipv6 && transport == .upnp ? 41 : nil
        let now = nowProvider()
        let nowUptime = monotonicUptimeProvider()
        let bootIdentifier = bootIdentifierProvider()
        let lifetime = max(1, config.mappingLeaseSeconds)
        let mapping = ActiveRouterMapping(
            transport: transport,
            addressFamily: family,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            internalPort: config.internalPort,
            externalPort: externalPort,
            routerExternalAddress: family == .ipv4
                ? externalIPv4
                : localAddress,
            pinholeID: pinholeID,
            pcpNonce: transport == .pcp
                ? config.pcpNonce
                : (transport == .upnp
                    ? "mock-bound-upnp-identity"
                    : nil),
            leaseExpiresAt: now.addingTimeInterval(
                TimeInterval(lifetime)
            ),
            renewAfter: now.addingTimeInterval(
                TimeInterval(lifetime) / 2
            ),
            routerEpoch: transport == .pcp || transport == .natpmp
                ? 1
                : nil,
            routerEpochObservedAt: transport == .pcp || transport == .natpmp
                ? now
                : nil,
            routerEpochObservedUptime: transport == .pcp || transport == .natpmp
                ? nowUptime
                : nil,
            routerEpochBootIdentifier: transport == .pcp || transport == .natpmp
                ? bootIdentifier
                : nil,
            routerEpochHealthCheckAfter:
                transport == .pcp || transport == .natpmp
                ? now.addingTimeInterval(60)
                : nil,
            routerEpochHealthCheckUptime:
                transport == .pcp || transport == .natpmp
                ? nowUptime + 60
                : nil,
            leaseExpiresUptime: nowUptime + TimeInterval(lifetime),
            renewAfterUptime: nowUptime + TimeInterval(lifetime) / 2,
            leaseBootIdentifier: bootIdentifier,
            leaseAnchorWallTime: now,
            leaseRemainingAtAnchor: TimeInterval(lifetime),
            renewRemainingAtAnchor: TimeInterval(lifetime) / 2
        )
        guard let proof = currentCheckProof(for: mapping) else {
            throw SimulatedRouterFailure(
                operation: "incomplete current-check proof"
            )
        }
        return PortMappingResult(
            protocolName: transport.displayName,
            externalPort: externalPort,
            routerExternalAddress: family == .ipv4
                ? externalIPv4
                : localAddress,
            message: "mock renewable lease",
            pinholeID: pinholeID,
            activeMapping: mapping,
            currentCheckProof: proof
        )
    }
}

final class MockPublicIPService: PublicIPServicing {
    private let ipv4Calls = LockedCounter()
    private let ipv6Calls = LockedCounter()
    var ipv4 = "8.8.4.4"
    var ipv6 = "2606:4700:4700::1111"

    var ipv4CallCount: Int { ipv4Calls.current }
    var ipv6CallCount: Int { ipv6Calls.current }

    func currentIPv4() throws -> String {
        ipv4Calls.increment()
        return ipv4
    }

    func currentIPv6() throws -> String {
        ipv6Calls.increment()
        return ipv6
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw IntegrationContractFailure(message)
    }
}

func stopAgent(
    _ agent: NetworkAgent,
    timeout: TimeInterval = 3
) throws {
    try expect(
        agent.stopAndWaitUntilIdle(timeout: timeout),
        "NetworkAgent must become explicitly idle before its temporary directory is removed"
    )
}

func stopAgentForCleanup(_ agent: NetworkAgent) {
    precondition(
        agent.stopAndWaitUntilIdle(),
        "NetworkAgent cleanup timed out before temporary directory removal"
    )
}

func waitUntil(
    timeout: TimeInterval = 3,
    condition: () -> Bool
) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition(),
          ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func activeMappingFixture(
    transport: RouterMappingTransport,
    family: RouterMappingAddressFamily,
    localAddress: String? = nil,
    gatewayAddress: String? = nil,
    externalPort: UInt16 = 45900,
    renewAfter: Date = Date().addingTimeInterval(1800),
    leaseExpiresAt: Date = Date().addingTimeInterval(3600)
) -> ActiveRouterMapping {
    ActiveRouterMapping(
        transport: transport,
        addressFamily: family,
        localAddress: localAddress ?? (family == .ipv4 ? "192.0.2.20" : "2001:db8::20"),
        gatewayAddress: gatewayAddress ?? (family == .ipv4 ? "192.0.2.1" : "2001:db8::1"),
        internalPort: 5900,
        externalPort: family == .ipv4 ? externalPort : 5900,
        pinholeID: family == .ipv6 && transport == .upnp ? 41 : nil,
        pcpNonce: transport == .pcp ? Data(repeating: 7, count: 12).base64EncodedString() : nil,
        leaseExpiresAt: leaseExpiresAt,
        renewAfter: renewAfter
    )
}

func inMemoryKeychain() -> KeychainStore {
    var token: String?
    return KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { value, _ in token = value },
            get: { _ in token },
            delete: { _ in token = nil }
        )
    )
}

func testKeychainQueryInteractionPolicy() throws {
    let audit = LockedKeychainQueryAudit()
    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.query-policy",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in },
            scopedGet: { _, _, _ in nil },
            scopedDelete: { _, _, _ in }
        ),
        authenticationContextFactory: AuditedLAContext.init,
        queryObserver: audit.observe
    )
    let account = "cloudflare-api-token"

    _ = try keychain.get(account: account, interaction: .background)
    try keychain.set(
        "background-fixture",
        account: account,
        interaction: .background,
        refreshAccess: false
    )
    try keychain.deleteChecked(account: account, interaction: .background)
    _ = try keychain.get(account: account, interaction: .userInitiated)
    try keychain.set("explicit-fixture", account: account, interaction: .userInitiated)
    try keychain.deleteChecked(account: account, interaction: .userInitiated)

    let records = audit.snapshot
    try expect(records.count == 6, "Every injected Keychain operation must expose its query policy")
    let backgroundPolicy = KeychainStore.queryPolicy(for: .background)
    let explicitPolicy = KeychainStore.queryPolicy(for: .userInitiated)
    try expect(
        backgroundPolicy.interactionNotAllowed && backgroundPolicy.failsAuthenticationUI,
        "The pure background policy must independently disable LAContext and SecurityAgent UI"
    )
    try expect(
        !explicitPolicy.interactionNotAllowed && !explicitPolicy.failsAuthenticationUI,
        "The pure user-initiated policy must preserve interactive authorization"
    )
    let background = Array(records.prefix(3))
    try expect(
        background.map(\.operation) == [.read, .write, .delete],
        "Background read, write, and delete must share the audited query builder"
    )
    try expect(
        background.allSatisfy {
            $0.interaction == .background
                && $0.hasAuthenticationContext
                && $0.authenticationContextInteractionNotAllowed == true
        },
        "Every background Keychain query must contain a non-interactive LAContext"
    )
    try expect(
        background.allSatisfy {
            $0.authenticationUIValue == kSecUseAuthenticationUIFail as String
        },
        "Every background Keychain query must independently fail SecurityAgent UI"
    )

    let explicit = Array(records.suffix(3))
    try expect(
        explicit.map(\.operation) == [.read, .write, .delete],
        "Explicit read, write, and delete must share the audited query builder"
    )
    try expect(
        explicit.allSatisfy {
            $0.interaction == .userInitiated
                && $0.hasAuthenticationContext
                && $0.authenticationContextInteractionNotAllowed == false
        },
        "User-initiated Keychain queries must contain an interactive LAContext"
    )
    try expect(
        explicit.allSatisfy { $0.authenticationUIValue == nil },
        "User-initiated Keychain queries must not carry the background UI-fail policy"
    )
}

func testScheduledChecksUseBackgroundKeychainPolicy() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "scheduled-keychain-policy")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let audit = LockedKeychainQueryAudit()
    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.scheduled-query-policy",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in },
            scopedGet: { _, _, interaction in
                try expect(
                    interaction == .background,
                    "Startup and scheduled checks must never initiate interactive Keychain access"
                )
                throw KeychainError.status(
                    operation: "read",
                    code: errSecInteractionNotAllowed
                )
            },
            scopedDelete: { _, _, _ in }
        ),
        authenticationContextFactory: AuditedLAContext.init,
        queryObserver: audit.observe
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.cloudflareZoneID = "zone-fixture"
    config.dnsRecordName = "host.example.test"
    config.checkIntervalSeconds = AppConfig.maximumCheckIntervalSeconds
    let startupChecks = LockedCounter()
    let startupAgent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: config,
        checkExecutionObserver: { startupChecks.increment() },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService()
    )
    defer { stopAgentForCleanup(startupAgent) }

    startupAgent.start()
    try expect(
        waitUntil { startupChecks.current == 1 && audit.snapshot.count == 1 },
        "Startup must complete one non-interactive Keychain-backed check"
    )
    try stopAgent(startupAgent)
    let scheduleLock = NSLock()
    var periodicHandler: (() -> Void)?
    let periodicChecks = LockedCounter()
    let periodicAgent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: config,
        checkExecutionObserver: { periodicChecks.increment() },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        performInitialCheckOnStart: false,
        periodicTimerScheduler: { _, handler in
            scheduleLock.lock()
            periodicHandler = handler
            scheduleLock.unlock()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(periodicAgent) }
    periodicAgent.start()
    scheduleLock.lock()
    let capturedPeriodicHandler = periodicHandler
    scheduleLock.unlock()
    guard let capturedPeriodicHandler else {
        throw IntegrationContractFailure("The periodic check handler was not scheduled")
    }
    capturedPeriodicHandler()
    try expect(
        waitUntil { periodicChecks.current == 1 && audit.snapshot.count == 2 },
        "The injected periodic timer must run one non-interactive Keychain-backed check"
    )
    try stopAgent(periodicAgent)
    _ = try? keychain.get(
        account: "cloudflare-api-token",
        interaction: .userInitiated
    )

    let records = audit.snapshot
    let backgroundPolicy = KeychainStore.queryPolicy(for: .background)
    let backgroundRecords = Array(records.prefix(2))
    try expect(
        backgroundRecords.count == 2 && backgroundRecords.allSatisfy {
            $0.operation == .read
                && $0.interaction == .background
                && $0.hasAuthenticationContext
                && $0.authenticationContextInteractionNotAllowed == true
                && $0.authenticationUIValue == kSecUseAuthenticationUIFail as String
        }
            && backgroundPolicy.interactionNotAllowed
            && backgroundPolicy.failsAuthenticationUI,
        "Startup and periodic checks must carry both independent background UI prohibitions"
    )
    guard let explicitRecord = records.last else {
        throw IntegrationContractFailure("The explicit Keychain authorization query was not observed")
    }
    try expect(
        explicitRecord.operation == .read
            && explicitRecord.interaction == .userInitiated
            && explicitRecord.hasAuthenticationContext
            && explicitRecord.authenticationContextInteractionNotAllowed == false
            && explicitRecord.authenticationUIValue == nil,
        "Explicit Keychain authorization must not inherit the background UI-fail policy"
    )
}

func makeTemporaryDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gatebeam-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func agentConfigPath(_ baseDirectory: URL) -> String {
    baseDirectory
        .appendingPathComponent("RemoteControlNetwork", isDirectory: true)
        .appendingPathComponent("config.json")
        .path
}

func emergencyJournal(in baseDirectory: URL) -> EmergencyMappingJournal {
    EmergencyMappingJournal(
        fileURL: baseDirectory.appendingPathComponent("emergency-router-mappings.json")
    )
}

func testUPnPRecoveryRequiresExplicitEnabledRule() throws {
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let deviceIdentity = "uuid:integration-enabled-contract-router"
    let service = UPnPService(
        serviceType: serviceType,
        controlURL: controlURL,
        gatewayIdentity: gateway,
        descriptionURL: descriptionURL,
        deviceIdentity: deviceIdentity
    )
    let description = Data("""
    <root>
      <device>
        <UDN>\(deviceIdentity)</UDN>
        <serviceList>
          <service>
            <serviceType>\(serviceType)</serviceType>
            <controlURL>\(controlURL.absoluteString)</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """.utf8)
    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv4
    config.internalPort = 5900
    config.externalPort = 45900

    let creator = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "AddPortMapping", "The fixture must fail after AddPortMapping")
            throw RouterMappingError.timeout("Injected AddPortMapping response loss")
        }
    )
    let recovery: RouterMappingRecoveryRequiredError
    do {
        _ = try creator.ensureMapping(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gateway
        )
        throw IntegrationContractFailure("Uncertain AddPortMapping must require recovery")
    } catch let captured as RouterMappingRecoveryRequiredError {
        recovery = captured
    }

    let variants: [(name: String, element: String, mayDelete: Bool)] = [
        ("missing", "", false),
        ("zero", "<NewEnabled>0</NewEnabled>", false),
        ("invalid", "<NewEnabled>true</NewEnabled>", false),
        ("one", "<NewEnabled> \n 1 \t</NewEnabled>", true)
    ]
    for variant in variants {
        var actions: [String] = []
        let remover = RouterMappingService(
            upnpDescriptionHandler: { _ in description },
            soapRequestHandler: { _, _, action, _ in
                actions.append(action)
                if action == "DeletePortMapping" {
                    return HTTPResponse(statusCode: 200, data: Data(), headers: [:])
                }
                try expect(
                    action == "GetSpecificPortMappingEntry",
                    "Recovery must query before considering deletion"
                )
                let xml = """
                <response>
                  <NewExternalPort>45900</NewExternalPort>
                  <NewProtocol>TCP</NewProtocol>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  \(variant.element)
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                </response>
                """
                return HTTPResponse(
                    statusCode: 200,
                    data: Data(xml.utf8),
                    headers: [:]
                )
            }
        )
        let report = remover.removeMappings([recovery.mapping])
        try expect(
            report.allSucceeded == variant.mayDelete,
            "\(variant.name) NewEnabled must \(variant.mayDelete ? "allow" : "refuse") recovery deletion"
        )
        let expectedActions = variant.mayDelete
            ? ["GetSpecificPortMappingEntry", "DeletePortMapping"]
            : ["GetSpecificPortMappingEntry"]
        try expect(
            actions == expectedActions,
            "\(variant.name) NewEnabled must retain fail-closed recovery state unless explicitly enabled"
        )
    }
}

func fileMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw IntegrationContractFailure("Missing POSIX permissions for \(url.path)")
    }
    return permissions.intValue & 0o777
}

func dependencyDescriptors(for config: AppConfig) throws -> [NetworkAgentDependencyDescriptor] {
    let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gatebeam-agent-\(UUID().uuidString)", isDirectory: true)
    let configStore = AppConfigStore(baseDirectory: baseDirectory)
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let agent = NetworkAgent(
        configStore: configStore,
        keychain: KeychainStore(service: "io.github.naifuliang.gatebeam.integration-contract"),
        initialConfig: config,
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }
    return try agent.networkDependencyDescriptors()
}

func descriptor(
    _ role: NetworkAgentDependencyRole,
    in descriptors: [NetworkAgentDependencyDescriptor]
) throws -> NetworkAgentDependencyDescriptor {
    guard let descriptor = descriptors.first(where: { $0.role == role }) else {
        throw IntegrationContractFailure("Missing dependency descriptor for \(role.rawValue)")
    }
    return descriptor
}

func verify(
    ddnsMode: NetworkProxyMode,
    publicIPMode: NetworkProxyMode,
    customProxyURL: String = ""
) throws {
    var config = AppConfig.default
    config.ddnsProxyMode = ddnsMode
    config.publicIPProxyMode = publicIPMode
    config.customProxyURL = customProxyURL

    let descriptors = try dependencyDescriptors(for: config)
    try expect(descriptors.count == 2, "NetworkAgent must construct exactly two configured HTTP dependencies")

    let cloudflare = try descriptor(.cloudflareDDNS, in: descriptors)
    let publicIP = try descriptor(.publicIPProbe, in: descriptors)
    try expect(cloudflare.proxyMode == ddnsMode, "Cloudflare must receive AppConfig.ddnsProxyMode")
    try expect(publicIP.proxyMode == publicIPMode, "Public-IP probe must receive AppConfig.publicIPProxyMode")
    try expect(cloudflare.httpClientType == "HTTPClient", "Cloudflare must be backed by HTTPClient")
    try expect(publicIP.httpClientType == "HTTPClient", "Public-IP probe must be backed by HTTPClient")

    let expectedCustomURL = customProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    try expect(
        cloudflare.customProxyURL == (ddnsMode == .custom ? expectedCustomURL : ""),
        "Only a custom Cloudflare policy may carry the custom proxy URL"
    )
    try expect(
        publicIP.customProxyURL == (publicIPMode == .custom ? expectedCustomURL : ""),
        "Only a custom public-IP policy may carry the custom proxy URL"
    )
}

func testDefaultDataChain() throws {
    let descriptors = try dependencyDescriptors(for: .default)
    let cloudflare = try descriptor(.cloudflareDDNS, in: descriptors)
    let publicIP = try descriptor(.publicIPProbe, in: descriptors)
    try expect(
        cloudflare.proxyMode == .system,
        "Default Cloudflare policy must use the system proxy"
    )
    try expect(
        publicIP.proxyMode == .direct,
        "Default public-IP policy must bypass CFNetwork proxies"
    )
}

func testSystemAndDirectMatrix() throws {
    try verify(ddnsMode: .system, publicIPMode: .direct)
    try verify(ddnsMode: .direct, publicIPMode: .system)
    try verify(ddnsMode: .system, publicIPMode: .system)
    try verify(ddnsMode: .direct, publicIPMode: .direct)
}

func testCustomPoliciesRemainIndependent() throws {
    let proxy = "http://proxy.example.test:8080"
    try verify(ddnsMode: .custom, publicIPMode: .direct, customProxyURL: proxy)
    try verify(ddnsMode: .system, publicIPMode: .custom, customProxyURL: proxy)
    try verify(ddnsMode: .custom, publicIPMode: .custom, customProxyURL: proxy)
}

func testInvalidProxyOnlyBlocksCustomConsumers() throws {
    try verify(ddnsMode: .system, publicIPMode: .direct, customProxyURL: "not-a-proxy")

    var ddnsConfig = AppConfig.default
    ddnsConfig.ddnsProxyMode = .custom
    ddnsConfig.publicIPProxyMode = .direct
    ddnsConfig.customProxyURL = "not-a-proxy"
    do {
        _ = try dependencyDescriptors(for: ddnsConfig)
        throw IntegrationContractFailure("Invalid custom Cloudflare proxy must fail dependency construction")
    } catch is NetworkError {
        // Expected: no request is sent because HTTPClient validation fails first.
    }

    var publicIPConfig = AppConfig.default
    publicIPConfig.ddnsProxyMode = .system
    publicIPConfig.publicIPProxyMode = .custom
    publicIPConfig.customProxyURL = "not-a-proxy"
    do {
        _ = try dependencyDescriptors(for: publicIPConfig)
        throw IntegrationContractFailure("Invalid custom public-IP proxy must fail dependency construction")
    } catch is NetworkError {
        // Expected: no request is sent because HTTPClient validation fails first.
    }
}

func testConfigStoreUsesInjectedDirectory() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "config-store")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    let expectedLocation = baseDirectory
        .appendingPathComponent("RemoteControlNetwork", isDirectory: true)
        .appendingPathComponent("config.json")
        .standardizedFileURL
    try expect(store.location.standardizedFileURL == expectedLocation, "Injected store must remain inside its temporary base directory")

    var config = AppConfig.default
    config.publicIPProxyMode = .custom
    config.customProxyURL = "http://proxy.example.test:8080"
    try store.save(config)
    try expect(FileManager.default.fileExists(atPath: expectedLocation.path), "Injected store must persist its config in the temporary directory")
    let loadedConfig = try store.load()
    try expect(loadedConfig.customProxyURL == config.customProxyURL, "Injected store must load the config it persisted")

    try FileManager.default.removeItem(at: baseDirectory)
    try expect(!FileManager.default.fileExists(atPath: baseDirectory.path), "Temporary config directory must be removable without production state")
}

func testCheckIntervalNormalizationAndLegacyMigration() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "check-interval-migration")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    let encodedDefault = try JSONEncoder().encode(AppConfig.default)
    guard var object = try JSONSerialization.jsonObject(with: encodedDefault) as? [String: Any] else {
        throw IntegrationContractFailure("AppConfig must encode as a JSON object")
    }

    let cases: [(Double, TimeInterval)] = [
        (0, AppConfig.defaultCheckIntervalSeconds),
        (-10, AppConfig.defaultCheckIntervalSeconds),
        (1, AppConfig.minimumCheckIntervalSeconds),
        (9_999_999, AppConfig.maximumCheckIntervalSeconds)
    ]
    for (legacyValue, expected) in cases {
        object["checkIntervalSeconds"] = legacyValue
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: store.location, options: [.atomic])
        let migrated = try store.load()
        try expect(
            migrated.checkIntervalSeconds == expected,
            "Legacy interval \(legacyValue) must normalize to \(expected)"
        )
        let persisted = try store.load()
        try expect(
            persisted.checkIntervalSeconds == expected,
            "The normalized interval must be written back atomically"
        )
    }

    var invalidRuntimeConfig = AppConfig.default
    invalidRuntimeConfig.checkIntervalSeconds = 0
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: invalidRuntimeConfig,
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }
    try expect(
        agent.config.checkIntervalSeconds == AppConfig.defaultCheckIntervalSeconds,
        "Injected runtime configuration must be normalized before the timer can observe it"
    )
}

func testConfigStoreMigratesInactiveLegacyProxyCredentials() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "inactive-proxy-migration")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    var legacy = AppConfig.default
    legacy.ddnsProxyMode = .system
    legacy.publicIPProxyMode = .direct
    legacy.customProxyURL = "http://old-user:old-pass@proxy.example.test:8080"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(legacy).write(to: store.location, options: [.atomic])

    let migrated = try store.load()
    try expect(migrated.customProxyURL.isEmpty, "An inactive legacy proxy must not be returned to the UI")

    let persisted = try String(contentsOf: store.location, encoding: .utf8)
    try expect(!persisted.contains("old-user"), "Legacy proxy usernames must be removed from disk during load")
    try expect(!persisted.contains("old-pass"), "Legacy proxy passwords must be removed from disk during load")
    try expect(persisted.contains("\"customProxyURL\" : \"\""), "The migration must atomically persist the scrubbed proxy value")
}

func testConfigStoreMigratesInvalidActiveProxy() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "invalid-proxy-migration")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    var legacy = AppConfig.default
    legacy.ddnsProxyMode = .custom
    legacy.customProxyURL = "https://old-user:old-pass@proxy.example.test:443"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(legacy).write(to: store.location, options: [.atomic])

    let migrated = try store.load()
    try expect(migrated.ddnsProxyMode == .custom, "Migration must preserve the user's selected proxy policy")
    try expect(migrated.customProxyURL.isEmpty, "An invalid active proxy must fail closed instead of being displayed")

    let persisted = try String(contentsOf: store.location, encoding: .utf8)
    try expect(!persisted.contains("old-user"), "Invalid active proxy usernames must be removed from disk")
    try expect(!persisted.contains("old-pass"), "Invalid active proxy passwords must be removed from disk")
    try expect(!persisted.contains("https://"), "Unsupported legacy proxy schemes must not remain on disk")
}

func testConfigStoreNormalizesValidActiveProxy() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "valid-proxy-migration")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    var legacy = AppConfig.default
    legacy.publicIPProxyMode = .custom
    legacy.customProxyURL = "  socks5://[2001:db8::8]:1080  "

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(legacy).write(to: store.location, options: [.atomic])

    let migrated = try store.load()
    try expect(
        migrated.customProxyURL == "socks5://[2001:db8::8]:1080",
        "A valid active proxy must be normalized during migration"
    )
    let persisted = try String(contentsOf: store.location, encoding: .utf8)
    try expect(!persisted.contains("  socks5://"), "Normalized proxy storage must not retain surrounding whitespace")
}

func testCorruptConfigIsPreservedAndFailsMappingRecoveryClosed() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "malformed-config-migration")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let store = AppConfigStore(baseDirectory: baseDirectory)
    var damagedConfig = AppConfig.default
    damagedConfig.remoteAccessEnabled = true
    damagedConfig.mappingProtocolPreference = .pcp
    damagedConfig.pcpNonce = Data(repeating: 14, count: 12).base64EncodedString()
    damagedConfig.activeRouterMappings = [
        activeMappingFixture(transport: .pcp, family: .ipv4)
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var malformed = try encoder.encode(damagedConfig)
    malformed.removeLast()
    malformed.append(contentsOf: Data(#","broken":"# .utf8))
    try malformed.write(to: store.location, options: [.atomic])

    do {
        _ = try store.load()
        throw IntegrationContractFailure("Corrupt config must return a typed decode error")
    } catch AppConfigStoreError.decodingFailed(let url, _) {
        try expect(url == store.location, "Typed decode error must identify the preserved config")
    }
    let preservedAfterLoad = try Data(contentsOf: store.location)
    try expect(
        preservedAfterLoad == malformed,
        "Config decode failure must preserve the damaged bytes for backup and recovery"
    )
    let preserved = String(decoding: malformed, as: UTF8.self)
    try expect(
        preserved.contains("activeRouterMappings") && preserved.contains(damagedConfig.pcpNonce!),
        "The preserved corrupt fixture must retain its mapping recovery identity"
    )

    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        emergencyMappingJournal: emergencyJournal(in: baseDirectory),
        fallbackMappingJournal: EmergencyMappingJournal(
            fileURL: baseDirectory.appendingPathComponent("fallback/mappings.json")
        )
    )
    defer { stopAgentForCleanup(agent) }
    agent.runCheck()
    try expect(
        waitUntil {
            agent.status.routerStatus.message == "Router recovery state is unknown"
        },
        "Corrupt config containing mappings must set recovery state unknown"
    )
    try expect(router.ensureCalls.isEmpty, "Unknown config mapping state must block every new mapping")
    try expect(
        agent.status.settingsErrorMessage?.contains("Back up the damaged") == true,
        "The UI must tell the user to back up and restore the damaged config"
    )
    let preservedAfterCheck = try Data(contentsOf: store.location)
    try expect(
        preservedAfterCheck == malformed,
        "NetworkAgent must not replace the damaged config while fail-closed"
    )
    try stopAgent(agent)
}

func testInvalidProxyPreventsAllPersistence() throws {
    var config = AppConfig.default
    config.ddnsProxyMode = .custom
    config.customProxyURL = "https://unsupported.example.test:443"

    var calls: [String] = []
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { config, _ in
            calls.append("persist")
            return config
        }
    )

    do {
        try coordinator.persist(config: config, tokenMutation: .replace("never-persisted"))
        throw IntegrationContractFailure("Invalid custom proxy must fail before persistence")
    } catch NetworkError.invalidProxyURL {
        // Expected: production proxy validation rejects the value first.
    }
    try expect(calls.isEmpty, "Invalid custom proxy must not call Keychain or config persistence")
}

func testInactiveCredentialProxyIsScrubbedBeforePersistence() throws {
    var config = AppConfig.default
    config.ddnsProxyMode = .system
    config.publicIPProxyMode = .direct
    config.customProxyURL = "http://alice:top-secret@proxy.example.test:8080"

    var savedConfig: AppConfig?
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { config, _ in
            savedConfig = config
            return config
        }
    )

    let normalized = try coordinator.persist(config: config, tokenMutation: .replace("test-token"))
    try expect(normalized.customProxyURL.isEmpty, "Inactive proxy credentials must be cleared from the normalized config")
    try expect(savedConfig?.customProxyURL == "", "Inactive proxy credentials must never reach config persistence")

    let encoded = try JSONEncoder().encode(savedConfig)
    let persistedText = String(decoding: encoded, as: UTF8.self)
    try expect(!persistedText.contains("alice"), "Persisted config must not contain the proxy username")
    try expect(!persistedText.contains("top-secret"), "Persisted config must not contain the proxy password")
}

func testInactiveValidProxyIsClearedBeforePersistence() throws {
    var config = AppConfig.default
    config.ddnsProxyMode = .system
    config.publicIPProxyMode = .direct
    config.customProxyURL = " http://proxy.example.test:8080 "

    var savedConfig: AppConfig?
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { config, _ in
            savedConfig = config
            return config
        }
    )

    _ = try coordinator.persist(config: config, tokenMutation: .replace("test-token"))
    try expect(savedConfig?.customProxyURL == "", "Unused custom proxy values must be cleared before config persistence")
}

func testValidProxyPersistsInOrder() throws {
    var config = AppConfig.default
    config.publicIPProxyMode = .custom
    config.customProxyURL = "socks5://[2001:db8::1]:1080"

    var calls: [String] = []
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { config, mutation in
            try expect(
                mutation == .replace("test-token"),
                "The persistence boundary must receive the explicit replacement mutation"
            )
            calls.append("transaction:test-token:\(config.customProxyURL)")
            return config
        }
    )

    try coordinator.persist(config: config, tokenMutation: .replace("test-token"))
    try expect(
        calls == ["transaction:test-token:socks5://[2001:db8::1]:1080"],
        "Valid settings must cross one transactional persistence boundary"
    )
}

func testTokenFailurePreventsConfigPersistence() throws {
    struct TokenWriteFailure: Error {}

    var calls: [String] = []
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { _, _ in
            calls.append("transaction")
            throw TokenWriteFailure()
        }
    )

    do {
        try coordinator.persist(config: .default, tokenMutation: .replace("test-token"))
        throw IntegrationContractFailure("A token persistence failure must be propagated")
    } catch is TokenWriteFailure {
        // Expected: config persistence must not run after a failed token write.
    }
    try expect(calls == ["transaction"], "Transaction failure must propagate without reporting persistence success")
}

func testTokenMutationPolicyNeverInfersRemoval() throws {
    let states: [CloudflareTokenReadState] = [
        .unknown,
        .missing,
        .available("saved-token"),
        .unavailable
    ]
    for state in states {
        try expect(
            SettingsTokenMutationPolicy.saveMutation(
                enteredToken: "",
                fieldWasEdited: false,
                readState: state
            ) == .keepExisting,
            "An untouched token field must always keep the existing credential"
        )
        try expect(
            SettingsTokenMutationPolicy.saveMutation(
                enteredToken: "   \n",
                fieldWasEdited: true,
                readState: state
            ) == .keepExisting,
            "An edited but empty token field must never imply deletion"
        )
    }

    try expect(
        SettingsTokenMutationPolicy.saveMutation(
            enteredToken: " replacement-token ",
            fieldWasEdited: true,
            readState: .unavailable
        ) == .replace("replacement-token"),
        "A nonempty edited field must become an explicit normalized replacement"
    )
    try expect(
        SettingsTokenMutationPolicy.saveMutation(
            enteredToken: "saved-token",
            fieldWasEdited: true,
            readState: .available("saved-token")
        ) == .keepExisting,
        "Re-entering the loaded token must not rewrite Keychain"
    )
    try expect(
        SettingsTokenMutationPolicy.verificationToken(
            enteredToken: "",
            readState: .available("saved-token")
        ) == "saved-token",
        "Verify may use an already loaded token without changing it"
    )
    try expect(
        SettingsTokenMutationPolicy.verificationToken(
            enteredToken: "",
            readState: .unknown
        ) == nil,
        "An unknown empty field must stay unknown instead of becoming a removal"
    )
    try expect(
        SettingsTokenMutationPolicy.removalMutation(confirmed: false) == nil,
        "Cancelling the removal confirmation must produce no mutation"
    )
    try expect(
        SettingsTokenMutationPolicy.removalMutation(confirmed: true) == .explicitRemove,
        "Only the confirmed removal action may produce explicitRemove"
    )

    do {
        _ = try CloudflareTokenMutation.replace(" \n ").validated()
        throw IntegrationContractFailure("An empty replacement payload must be rejected")
    } catch CloudflareTokenMutationError.emptyReplacement {
        // Expected: deletion has its own explicit operation.
    }
}

func testKeepExistingSaveNeverTouchesUnknownOrFailedKeychain() throws {
    enum FailureFixture: Equatable {
        case none
        case readFailure
        case denied
        case cancelled

        var name: String {
            switch self {
            case .none: return "unknown"
            case .readFailure: return "read-failure"
            case .denied: return "denied"
            case .cancelled: return "cancelled"
            }
        }
    }

    for fixture in [
        FailureFixture.none,
        .readFailure,
        .denied,
        .cancelled
    ] {
        let baseDirectory = try makeTemporaryDirectory(named: "token-keep-\(fixture.name)")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let reads = LockedCounter()
        let writes = LockedCounter()
        let deletes = LockedCounter()
        let keychain = KeychainStore(
            service: "unused",
            operationHandlers: KeychainOperationHandlers(
                set: { _, _ in _ = writes.increment() },
                get: { _ in
                    reads.increment()
                    switch fixture {
                    case .none:
                        return "must-not-be-read"
                    case .readFailure:
                        throw SimulatedKeychainFailure(operation: "read")
                    case .denied:
                        throw KeychainError.status(operation: "read", code: errSecAuthFailed)
                    case .cancelled:
                        throw KeychainError.status(operation: "read", code: errSecUserCanceled)
                    }
                },
                delete: { _ in _ = deletes.increment() }
            )
        )
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: baseDirectory),
            keychain: keychain,
            initialConfig: .default
        )

        if fixture != .none {
            do {
                _ = try agent.loadCloudflareToken(
                    retryAfterFailure: false,
                    interaction: .background
                )
                throw IntegrationContractFailure("\(fixture.name) fixture must fail its initial read")
            } catch {
                // Establish the denied/cancelled/failed state before ordinary Save.
            }
            try expect(
                agent.cloudflareTokenState == .unavailable,
                "\(fixture.name) must be represented as unavailable, never as a missing token"
            )
        } else {
            try expect(agent.cloudflareTokenState == .unknown, "A fresh agent must begin with unknown token state")
        }

        var config = AppConfig.default
        config.dnsRecordName = "\(fixture.name).example.test"
        _ = try agent.persistSettings(
            config: config,
            tokenMutation: .keepExisting
        )
        let persisted = try AppConfigStore(baseDirectory: baseDirectory).load()
        try expect(
            persisted.dnsRecordName == config.dnsRecordName,
            "Ordinary Save must still persist non-secret settings for \(fixture.name)"
        )
        try expect(
            reads.current == (fixture == .none ? 0 : 1),
            "keepExisting must not perform an additional Keychain read for \(fixture.name)"
        )
        try expect(writes.current == 0, "keepExisting must not write Keychain for \(fixture.name)")
        try expect(deletes.current == 0, "keepExisting must not delete Keychain for \(fixture.name)")

        _ = try agent.persistSettings(
            config: config,
            tokenMutation: .keepExisting
        )
        try expect(
            reads.current == (fixture == .none ? 0 : 1),
            "Repeated ordinary Save must not create repeated authorization prompts for \(fixture.name)"
        )
    }
}

func testVerifyKeepsTokenAndLatchesDeniedOrCancelledReads() throws {
    let failures: [(String, OSStatus)] = [
        ("denied", errSecAuthFailed),
        ("cancelled", errSecUserCanceled)
    ]

    for (name, status) in failures {
        let baseDirectory = try makeTemporaryDirectory(named: "token-verify-\(name)")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let reads = LockedCounter()
        let writes = LockedCounter()
        let deletes = LockedCounter()
        let keychain = KeychainStore(
            service: "unused",
            operationHandlers: KeychainOperationHandlers(
                set: { _, _ in _ = writes.increment() },
                get: { _ in
                    reads.increment()
                    throw KeychainError.status(operation: "read", code: status)
                },
                delete: { _ in _ = deletes.increment() }
            )
        )
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: baseDirectory),
            keychain: keychain,
            initialConfig: .default
        )

        var firstResult: Result<[CloudflareZoneSummary], Error>?
        agent.loadCloudflareZones(token: nil) { firstResult = $0 }
        try expect(waitUntil { firstResult != nil }, "The first \(name) Verify callback must arrive")
        if case .success = firstResult {
            throw IntegrationContractFailure("A \(name) Keychain read must fail Verify")
        }

        var secondResult: Result<[CloudflareZoneSummary], Error>?
        agent.loadCloudflareZones(token: nil) { secondResult = $0 }
        try expect(waitUntil { secondResult != nil }, "The repeated \(name) Verify callback must arrive")
        if case .success = secondResult {
            throw IntegrationContractFailure("A repeated \(name) Verify must preserve the failure")
        }

        try expect(reads.current == 1, "Repeated \(name) Verify must consume the failure latch without another prompt")
        try expect(writes.current == 0, "Verify must never persist a token after \(name)")
        try expect(deletes.current == 0, "Verify must never delete a token after \(name)")
        try expect(
            !FileManager.default.fileExists(atPath: agentConfigPath(baseDirectory)),
            "Verify must not persist ordinary settings before credential validation"
        )
        try expect(agent.cloudflareTokenState == .unavailable, "Verify \(name) must retain unavailable state")
    }
}

func testSettingsVerifyDiscardsOutOfOrderAndEditedTokenResults() throws {
    var coordinator = SettingsCloudflareVerificationCoordinator()
    var config = AppConfig.default
    config.ddnsProxyMode = .system
    config.customProxyURL = "http://ignored.example.test:8080"

    let tokenA = try coordinator.begin(
        token: "token-a",
        pendingTokenMutation: .replace("token-a"),
        formConfig: config
    )
    config.ddnsProxyMode = .direct
    let tokenB = try coordinator.begin(
        token: "token-b",
        pendingTokenMutation: .replace("token-b"),
        formConfig: config
    )

    try expect(tokenA.token == "token-a", "The first Verify request must capture token A")
    try expect(tokenB.token == "token-b", "The second Verify request must capture token B")
    try expect(
        tokenA.pendingTokenMutation == .replace("token-a"),
        "Verify A feedback must remain bound to token A's captured mutation"
    )
    try expect(
        tokenB.pendingTokenMutation == .replace("token-b"),
        "Verify B feedback must remain bound to token B's captured mutation"
    )
    try expect(
        !coordinator.complete(tokenA),
        "A late Verify A callback must be discarded after Verify B starts"
    )
    try expect(
        coordinator.complete(tokenB),
        "The newest Verify B callback must be accepted"
    )

    let tokenBeforeEdit = try coordinator.begin(
        token: "token-before-edit",
        pendingTokenMutation: .replace("token-before-edit"),
        formConfig: config
    )
    try expect(
        coordinator.cancelActive(),
        "Editing the token while Verify is running must cancel the active generation"
    )
    try expect(
        !coordinator.complete(tokenBeforeEdit),
        "A callback for the pre-edit token must never update the edited field"
    )
}

func testSettingsVerifyUsesUnsavedCloudflareProxyWithoutPersistence() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "verify-unsaved-proxy")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    var config = AppConfig.default
    config.ddnsProxyMode = .custom
    config.customProxyURL = "  socks5://proxy.example.test:1080  "
    var coordinator = SettingsCloudflareVerificationCoordinator()
    let request = try coordinator.begin(
        token: "candidate-token",
        pendingTokenMutation: .replace("candidate-token"),
        formConfig: config
    )

    try expect(request.proxyMode == .custom, "Verify must capture the current unsaved DDNS proxy mode")
    try expect(
        request.customProxyURL == "socks5://proxy.example.test:1080",
        "Verify must normalize and capture the current unsaved custom proxy URL"
    )
    try expect(
        config.customProxyURL == "  socks5://proxy.example.test:1080  ",
        "Building a Verify request must not mutate the form configuration"
    )
    try expect(
        !FileManager.default.fileExists(atPath: agentConfigPath(baseDirectory)),
        "Building a Verify request must not persist settings"
    )

    config.ddnsProxyMode = .direct
    let directRequest = try coordinator.begin(
        token: "candidate-token",
        pendingTokenMutation: .keepExisting,
        formConfig: config
    )
    try expect(directRequest.proxyMode == .direct, "Verify must use the current unsaved Direct mode")
    try expect(
        directRequest.customProxyURL.isEmpty,
        "Direct Verify must not carry an inactive custom proxy URL"
    )

    config.ddnsProxyMode = .custom
    config.customProxyURL = "not-a-proxy"
    do {
        _ = try coordinator.begin(
            token: "candidate-token",
            pendingTokenMutation: .keepExisting,
            formConfig: config
        )
        throw IntegrationContractFailure("An invalid unsaved custom proxy must block Verify")
    } catch NetworkError.invalidProxyURL {
        // Expected: invalid visible form data cannot silently fall back to saved routing.
    }
    try expect(
        !coordinator.complete(directRequest),
        "A failed newer Verify attempt must still invalidate the previous request"
    )
}

func testCloudflareTokenRemovalPromptCancelAndConfirmContract() throws {
    let alert = SettingsCloudflareTokenRemovalPrompt.makeAlert()
    try expect(alert.buttons.count == 2, "Token removal must offer exactly Remove and Cancel")
    try expect(alert.buttons[0].title == "Remove Token", "The first action must explicitly remove the token")
    try expect(
        alert.buttons[0].hasDestructiveAction,
        "The Remove Token button must use macOS destructive-action styling"
    )
    try expect(alert.buttons[1].title == "Cancel", "The safe secondary action must be Cancel")
    try expect(
        SettingsCloudflareTokenRemovalPrompt.mutation(for: .alertSecondButtonReturn) == nil,
        "Cancelling the removal alert must not produce a Keychain mutation"
    )
    try expect(
        SettingsCloudflareTokenRemovalPrompt.mutation(for: .alertFirstButtonReturn) == .explicitRemove,
        "Confirming the removal alert must produce only an explicit token removal"
    )
}

func testCloudflareTokenRemovalControllerPath() throws {
    _ = NSApplication.shared
    let baseDirectory = try makeTemporaryDirectory(named: "token-removal-controller")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let lock = NSLock()
    var reads = 0
    var writes = 0
    var deletes = 0
    var storedToken: String?
    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { value, _ in
                lock.lock()
                storedToken = value
                writes += 1
                lock.unlock()
            },
            get: { _ in
                lock.lock()
                reads += 1
                let value = storedToken
                lock.unlock()
                return value
            },
            delete: { _ in
                lock.lock()
                storedToken = nil
                deletes += 1
                lock.unlock()
            }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    try agent.applyCloudflareTokenMutation(.replace("saved-token"))
    lock.lock()
    reads = 0
    writes = 0
    deletes = 0
    lock.unlock()

    var response = NSApplication.ModalResponse.alertSecondButtonReturn
    let controller = SettingsWindowController(
        agent: agent,
        autoLoadCloudflare: false,
        tokenRemovalResponseProvider: { _ in response }
    )

    controller.confirmRemoveCloudflareToken()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    lock.lock()
    let cancelledCounts = (reads, writes, deletes)
    lock.unlock()
    try expect(
        cancelledCounts == (0, 0, 0),
        "Cancel through the real remove-button controller action must perform zero Keychain operations"
    )

    response = .alertFirstButtonReturn
    controller.confirmRemoveCloudflareToken()
    try expect(
        waitUntil {
            lock.lock()
            let completed = deletes == 1
            lock.unlock()
            return completed
        },
        "Confirmed controller removal must complete one Keychain delete"
    )
    lock.lock()
    let confirmedCounts = (reads, writes, deletes)
    lock.unlock()
    try expect(
        confirmedCounts == (0, 0, 1),
        "Confirm through the real controller action must perform read=0, write=0, delete=1"
    )
    try expect(agent.cloudflareTokenState == .missing, "Confirmed controller removal must publish missing state")
    controller.close()
}

func settingsView<View: NSView>(
    identifier: String,
    in controller: SettingsWindowController,
    as type: View.Type = View.self
) throws -> View {
    func find(in view: NSView) -> View? {
        if let matched = view as? View,
           matched.identifier?.rawValue == identifier {
            return matched
        }
        for subview in view.subviews {
            if let matched = find(in: subview) {
                return matched
            }
        }
        return nil
    }

    guard let contentView = controller.window?.contentView,
          let matched = find(in: contentView) else {
        throw IntegrationContractFailure(
            "Settings view \(identifier) was not found in the real window hierarchy"
        )
    }
    return matched
}

func settingsButton(
    identifier: String,
    in controller: SettingsWindowController
) throws -> NSButton {
    try settingsView(identifier: identifier, in: controller)
}

func settingsConfigSnapshot(_ config: AppConfig) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(config)
}

func deliverSettingsAction(_ button: NSButton) throws {
    guard let action = button.action else {
        throw IntegrationContractFailure(
            "Settings button \(button.identifier?.rawValue ?? "unknown") has no action"
        )
    }
    _ = NSApplication.shared.sendAction(
        action,
        to: button.target,
        from: button
    )
}

func testSettingsUIAccessActionsPersistExplicitLifetimeModes() throws {
    _ = NSApplication.shared
    let baseline = Date(timeIntervalSince1970: 2_000_100_000)
    let staleDeadline = baseline.addingTimeInterval(600)

    func temporaryFixture(remoteAccessEnabled: Bool) -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = remoteAccessEnabled
        config.dnsProvider = .disabled
        config.mappingProtocolPreference = .disabled
        config.accessExpiresAt = staleDeadline
        config.accessExpiresUptime = 700
        config.accessBootIdentifier = "settings-ui-boot"
        config.accessAnchorWallTime = baseline.addingTimeInterval(-30)
        config.accessRemainingAtAnchor = 630
        return config
    }

    func hasNoTemporaryExpiration(_ config: AppConfig) -> Bool {
        config.accessExpiresAt == nil
            && config.accessExpiresUptime == nil
            && config.accessBootIdentifier == nil
            && config.accessAnchorWallTime == nil
            && config.accessRemainingAtAnchor == nil
    }

    func runSavePath(
        name: String,
        enabled: Bool
    ) throws {
        let directory = try makeTemporaryDirectory(named: "settings-ui-\(name)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppConfigStore(baseDirectory: directory)
        let agent = NetworkAgent(
            configStore: store,
            keychain: inMemoryKeychain(),
            initialConfig: temporaryFixture(remoteAccessEnabled: true),
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: MockRouterMappingService(),
            nowProvider: { baseline },
            monotonicUptimeProvider: { 100 },
            bootIdentifierProvider: { "settings-ui-boot" },
            performInitialCheckOnStart: false
        )
        let controller = SettingsWindowController(
            agent: agent,
            autoLoadCloudflare: false
        )
        defer {
            controller.close()
            stopAgentForCleanup(agent)
        }

        let remoteButton = try settingsButton(
            identifier: "settings-remote-access",
            in: controller
        )
        let saveButton = try settingsButton(
            identifier: "settings-save",
            in: controller
        )
        remoteButton.state = enabled ? .on : .off
        saveButton.performClick(nil)

        try expect(
            waitUntil {
                let current = agent.config
                guard current.remoteAccessEnabled == enabled,
                      hasNoTemporaryExpiration(current),
                      let persisted = try? store.load() else {
                    return false
                }
                return persisted.remoteAccessEnabled == enabled
                    && hasNoTemporaryExpiration(persisted)
            },
            "The real Settings \(name) save must persist its explicit lifetime mode "
                + "and clear every temporary-access field"
        )
    }

    try runSavePath(name: "disabled", enabled: false)
    try runSavePath(name: "permanent", enabled: true)

    let temporaryDirectory = try makeTemporaryDirectory(
        named: "settings-ui-temporary"
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    let temporaryStore = AppConfigStore(baseDirectory: temporaryDirectory)
    var disabledConfig = temporaryFixture(remoteAccessEnabled: false)
    disabledConfig.clearTemporaryAccessExpiration()
    let temporaryTokenReads = LockedCounter()
    let temporaryTokenWrites = LockedCounter()
    let temporaryTokenDeletes = LockedCounter()
    let temporaryKeychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.settings-ui-temporary",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in
                temporaryTokenWrites.increment()
            },
            scopedGet: { _, _, _ in
                temporaryTokenReads.increment()
                return nil
            },
            scopedDelete: { _, _, _ in
                temporaryTokenDeletes.increment()
            }
        )
    )
    let temporaryAgent = NetworkAgent(
        configStore: temporaryStore,
        keychain: temporaryKeychain,
        initialConfig: disabledConfig,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { baseline },
        monotonicUptimeProvider: { 100 },
        bootIdentifierProvider: { "settings-ui-boot" },
        performInitialCheckOnStart: false
    )
    let temporaryController = SettingsWindowController(
        agent: temporaryAgent,
        autoLoadCloudflare: false
    )
    defer {
        temporaryController.close()
        stopAgentForCleanup(temporaryAgent)
    }

    let temporaryButton = try settingsButton(
        identifier: "settings-open-30-minutes",
        in: temporaryController
    )
    let remoteButton = try settingsButton(
        identifier: "settings-remote-access",
        in: temporaryController
    )
    let checkButton = try settingsButton(
        identifier: "settings-check-now",
        in: temporaryController
    )
    try expect(
        temporaryButton.isEnabled && remoteButton.state == .off,
        "The idle Settings window must offer temporary access without "
            + "preemptively changing the access checkbox"
    )
    temporaryButton.performClick(nil)
    try expect(
        waitUntil {
            let current = temporaryAgent.config
            guard current.remoteAccessEnabled,
                  current.accessExpiresAt == baseline.addingTimeInterval(1_800),
                  current.accessExpiresUptime == 1_900,
                  current.accessBootIdentifier == "settings-ui-boot",
                  current.accessAnchorWallTime == baseline,
                  current.accessRemainingAtAnchor == 1_800,
                  let persisted = try? temporaryStore.load() else {
                return false
            }
            return persisted.remoteAccessEnabled
                && persisted.accessExpiresAt
                    == baseline.addingTimeInterval(1_800)
                && persisted.accessExpiresUptime == 1_900
                && persisted.accessBootIdentifier == "settings-ui-boot"
                && persisted.accessAnchorWallTime == baseline
                && persisted.accessRemainingAtAnchor == 1_800
                && temporaryButton.isEnabled
                && remoteButton.state == .on
                && temporaryTokenReads.current == 0
                && temporaryTokenWrites.current == 0
                && temporaryTokenDeletes.current == 0
        },
        "The real 30-minute button must use the agent entry point and durably "
            + "write the complete wall, monotonic, boot, and anchor deadline"
    )
    try expect(
        temporaryButton.isEnabled
            && remoteButton.state == .on
            && temporaryTokenReads.current == 0
            && temporaryTokenWrites.current == 0
            && temporaryTokenDeletes.current == 0,
        "A completed temporary-access click must restore the button, show the "
            + "persisted enabled state, and leave an untouched token alone"
    )
    let temporarySnapshot = temporaryAgent.config
    checkButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try expect(
        temporaryAgent.config.accessExpiresAt
                == temporarySnapshot.accessExpiresAt
            && temporaryAgent.config.accessExpiresUptime
                == temporarySnapshot.accessExpiresUptime
            && temporaryAgent.config.accessBootIdentifier
                == temporarySnapshot.accessBootIdentifier
            && temporaryAgent.config.accessAnchorWallTime
                == temporarySnapshot.accessAnchorWallTime
            && temporaryAgent.config.accessRemainingAtAnchor
                == temporarySnapshot.accessRemainingAtAnchor,
        "Check Now must inspect the saved configuration without converting "
            + "temporary access into permanent access"
    )
}

func testTemporaryAccessRejectsInvalidCustomProxyWithoutMutation() throws {
    _ = NSApplication.shared
    let directory = try makeTemporaryDirectory(
        named: "temporary-access-invalid-custom-proxy"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let configWrites = LockedCounter()
    let tokenReads = LockedCounter()
    let authorizationReads = LockedCounter()
    let tokenWrites = LockedCounter()
    let tokenDeletes = LockedCounter()
    let configURL = URL(fileURLWithPath: agentConfigPath(directory))
    let store = AppConfigStore(
        configURL: configURL,
        dataWriter: { data, url in
            configWrites.increment()
            try data.write(to: url, options: [.atomic])
        }
    )
    var initialConfig = AppConfig.default
    initialConfig.remoteAccessEnabled = false
    initialConfig.dnsProvider = .disabled
    initialConfig.mappingProtocolPreference = .disabled
    initialConfig.ddnsProxyMode = .custom
    initialConfig.publicIPProxyMode = .direct
    initialConfig.customProxyURL = "https://proxy.example.net:443/unsupported"
    try store.save(initialConfig)
    let initialDiskData = try Data(contentsOf: configURL)
    let initialDiskSnapshot = try settingsConfigSnapshot(store.load())

    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.settings-invalid-proxy",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in tokenWrites.increment() },
            scopedGet: { _, _, interaction in
                tokenReads.increment()
                if interaction == .userInitiated {
                    authorizationReads.increment()
                }
                return nil
            },
            scopedDelete: { _, _, _ in tokenDeletes.increment() }
        )
    )
    let localNetwork = MockLocalNetworkService()
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: store,
        keychain: keychain,
        initialConfig: initialConfig,
        localNetworkService: localNetwork,
        routerMappingService: router,
        performInitialCheckOnStart: false
    )
    let controller = SettingsWindowController(
        agent: agent,
        autoLoadCloudflare: false
    )
    defer {
        controller.close()
        stopAgentForCleanup(agent)
    }

    let temporaryButton = try settingsButton(
        identifier: "settings-open-30-minutes",
        in: controller
    )
    let remoteButton = try settingsButton(
        identifier: "settings-remote-access",
        in: controller
    )
    let ddnsProxyControl: NSSegmentedControl = try settingsView(
        identifier: "settings-ddns-proxy-mode",
        in: controller
    )
    let customProxyField: NSTextField = try settingsView(
        identifier: "settings-custom-proxy-url",
        in: controller
    )
    let validationLabel: NSTextField = try settingsView(
        identifier: "settings-proxy-validation",
        in: controller
    )
    let initialAgentSnapshot = try settingsConfigSnapshot(agent.config)
    try expect(
        temporaryButton.isEnabled
            && remoteButton.state == .off
            && ddnsProxyControl.selectedSegment == 2
            && customProxyField.stringValue == initialConfig.customProxyURL,
        "The real Settings window must begin off with the invalid Custom "
            + "proxy form intact before temporary access is attempted"
    )

    temporaryButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    let finalAgentSnapshot = try settingsConfigSnapshot(agent.config)
    let finalDiskData = try Data(contentsOf: configURL)
    let finalDiskSnapshot = try settingsConfigSnapshot(store.load())
    try expect(
        remoteButton.state == .off
            && temporaryButton.isEnabled
            && finalAgentSnapshot == initialAgentSnapshot
            && finalDiskData == initialDiskData
            && finalDiskSnapshot == initialDiskSnapshot
            && configWrites.current == 1,
        "Invalid Custom proxy validation must run before any checkbox, Agent, "
            + "or durable configuration mutation"
    )
    try expect(
        tokenReads.current == 0
            && authorizationReads.current == 0
            && tokenWrites.current == 0
            && tokenDeletes.current == 0
            && localNetwork.callCount == 0
            && router.operationCount == 0,
        "Rejected temporary access must perform zero Keychain authorization, "
            + "local-network discovery, or router operation"
    )
    try expect(
        !validationLabel.isHidden
            && validationLabel.stringValue.contains(
                SettingsProxyValidation.formatMessage
            )
            && validationLabel.toolTip == validationLabel.stringValue,
        "The rejected action must leave a visible, specific proxy format error"
    )
}

func testTemporaryAccessRejectsBusySettingsSaveWithoutMutation() throws {
    _ = NSApplication.shared
    let directory = try makeTemporaryDirectory(
        named: "temporary-access-save-busy"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceStarted = DispatchSemaphore(value: 0)
    let releasePersistence = DispatchSemaphore(value: 0)
    let configWrites = LockedCounter()
    let tokenReads = LockedCounter()
    let tokenWrites = LockedCounter()
    let tokenDeletes = LockedCounter()
    let configURL = URL(fileURLWithPath: agentConfigPath(directory))
    let store = AppConfigStore(
        configURL: configURL,
        dataWriter: { data, url in
            configWrites.increment()
            persistenceStarted.signal()
            releasePersistence.wait()
            try data.write(to: url, options: [.atomic])
        }
    )
    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.settings-save-busy",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in tokenWrites.increment() },
            scopedGet: { _, _, _ in
                tokenReads.increment()
                return nil
            },
            scopedDelete: { _, _, _ in tokenDeletes.increment() }
        )
    )
    var initialConfig = AppConfig.default
    initialConfig.dnsProvider = .disabled
    initialConfig.mappingProtocolPreference = .disabled
    let agent = NetworkAgent(
        configStore: store,
        keychain: keychain,
        initialConfig: initialConfig,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        performInitialCheckOnStart: false
    )
    let controller = SettingsWindowController(
        agent: agent,
        autoLoadCloudflare: false
    )
    defer {
        releasePersistence.signal()
        controller.close()
        stopAgentForCleanup(agent)
    }
    let temporaryButton = try settingsButton(
        identifier: "settings-open-30-minutes",
        in: controller
    )
    let remoteButton = try settingsButton(
        identifier: "settings-remote-access",
        in: controller
    )
    let saveButton = try settingsButton(
        identifier: "settings-save",
        in: controller
    )
    let verifyButton = try settingsButton(
        identifier: "settings-verify-token",
        in: controller
    )
    let checkButton = try settingsButton(
        identifier: "settings-check-now",
        in: controller
    )
    let initialSnapshot = try settingsConfigSnapshot(agent.config)

    saveButton.performClick(nil)
    try expect(
        persistenceStarted.wait(timeout: .now() + 3) == .success,
        "The real Save Changes action must enter the blocked persistence fixture"
    )
    try expect(
        !temporaryButton.isEnabled
            && !saveButton.isEnabled
            && !verifyButton.isEnabled
            && !checkButton.isEnabled,
        "Temporary access must be disabled with the existing Save, Verify, "
            + "and Check controls while settings persistence is active"
    )

    temporaryButton.performClick(nil)
    try deliverSettingsAction(temporaryButton)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let busySaveSnapshot = try settingsConfigSnapshot(agent.config)
    try expect(
        remoteButton.state == .off
            && busySaveSnapshot == initialSnapshot
            && configWrites.current == 1
            && tokenReads.current == 0
            && tokenWrites.current == 0
            && tokenDeletes.current == 0,
        "A click or queued temporary-access action during Save must leave the "
            + "checkbox, complete agent config, in-flight write count, and "
            + "Keychain side effects unchanged"
    )

    releasePersistence.signal()
    try expect(
        waitUntil {
            temporaryButton.isEnabled
                && saveButton.isEnabled
                && verifyButton.isEnabled
                && checkButton.isEnabled
        },
        "All Settings actions must become available together after Save completes"
    )
    let completedSaveSnapshot = try settingsConfigSnapshot(agent.config)
    try expect(
        remoteButton.state == .off
            && completedSaveSnapshot == initialSnapshot
            && configWrites.current == 1
            && tokenReads.current == 0
            && tokenWrites.current == 0
            && tokenDeletes.current == 0,
        "Completing the original Save must not replay the rejected temporary action"
    )
}

func testTemporaryAccessRejectsTokenAuthorizationBusyWithoutMutation() throws {
    _ = NSApplication.shared
    let directory = try makeTemporaryDirectory(
        named: "temporary-access-authorization-busy"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let authorizationStarted = DispatchSemaphore(value: 0)
    let releaseAuthorization = DispatchSemaphore(value: 0)
    let tokenReads = LockedCounter()
    let tokenWrites = LockedCounter()
    let tokenDeletes = LockedCounter()
    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.settings-authorization-busy",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in tokenWrites.increment() },
            scopedGet: { _, _, interaction in
                tokenReads.increment()
                if interaction == .userInitiated {
                    authorizationStarted.signal()
                    releaseAuthorization.wait()
                }
                return nil
            },
            scopedDelete: { _, _, _ in tokenDeletes.increment() }
        )
    )
    var initialConfig = AppConfig.default
    initialConfig.dnsProvider = .disabled
    initialConfig.mappingProtocolPreference = .disabled
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: directory),
        keychain: keychain,
        initialConfig: initialConfig,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        performInitialCheckOnStart: false
    )
    let controller = SettingsWindowController(
        agent: agent,
        autoLoadCloudflare: false
    )
    defer {
        releaseAuthorization.signal()
        controller.close()
        stopAgentForCleanup(agent)
    }
    let temporaryButton = try settingsButton(
        identifier: "settings-open-30-minutes",
        in: controller
    )
    let remoteButton = try settingsButton(
        identifier: "settings-remote-access",
        in: controller
    )
    let saveButton = try settingsButton(
        identifier: "settings-save",
        in: controller
    )
    let verifyButton = try settingsButton(
        identifier: "settings-verify-token",
        in: controller
    )
    let authorizeButton = try settingsButton(
        identifier: "settings-authorize-token",
        in: controller
    )
    let initialSnapshot = try settingsConfigSnapshot(agent.config)

    authorizeButton.performClick(nil)
    try expect(
        authorizationStarted.wait(timeout: .now() + 3) == .success,
        "The real Authorize Token action must enter the blocked Keychain fixture"
    )
    try expect(
        !temporaryButton.isEnabled
            && !saveButton.isEnabled
            && !verifyButton.isEnabled
            && !authorizeButton.isEnabled,
        "Temporary access must be disabled with Save, Verify, and Authorize "
            + "while Keychain authorization is active"
    )

    temporaryButton.performClick(nil)
    try deliverSettingsAction(temporaryButton)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let busyAuthorizationSnapshot = try settingsConfigSnapshot(agent.config)
    try expect(
        remoteButton.state == .off
            && busyAuthorizationSnapshot == initialSnapshot
            && !FileManager.default.fileExists(atPath: agentConfigPath(directory))
            && tokenReads.current == 1
            && tokenWrites.current == 0
            && tokenDeletes.current == 0,
        "A click or queued temporary-access action during authorization must "
            + "leave UI and config untouched and add no config or Keychain side effect"
    )

    releaseAuthorization.signal()
    try expect(
        waitUntil {
            temporaryButton.isEnabled
                && saveButton.isEnabled
                && verifyButton.isEnabled
                && authorizeButton.isEnabled
        },
        "All Settings actions must become available together after authorization"
    )
    let completedAuthorizationSnapshot = try settingsConfigSnapshot(
        agent.config
    )
    try expect(
        remoteButton.state == .off
            && completedAuthorizationSnapshot == initialSnapshot
            && !FileManager.default.fileExists(atPath: agentConfigPath(directory))
            && tokenReads.current == 1
            && tokenWrites.current == 0
            && tokenDeletes.current == 0,
        "Authorization completion must not replay the rejected temporary action"
    )
}

func testTemporaryAccessEntrySurvivesClockAndRestartBoundaries() throws {
    let directory = try makeTemporaryDirectory(
        named: "temporary-entry-boundaries"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppConfigStore(baseDirectory: directory)
    let wall = LockedClock(Date(timeIntervalSince1970: 2_000_110_000))
    let uptime = LockedMonotonicClock(100)
    var base = AppConfig.default
    base.dnsProvider = .disabled
    base.mappingProtocolPreference = .disabled

    let firstAgent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: base,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { wall.now() },
        monotonicUptimeProvider: { uptime.now() },
        bootIdentifierProvider: { "temporary-entry-boot-a" },
        performInitialCheckOnStart: false
    )
    defer { stopAgentForCleanup(firstAgent) }

    firstAgent.setTemporaryAccess(minutes: 30)
    try expect(
        waitUntil {
            firstAgent.config.accessExpiresUptime == 1_900
                && (try? store.load().accessExpiresUptime) == 1_900
        },
        "The first temporary-access request must persist its monotonic deadline"
    )

    let rolledBackWall = wall.now().addingTimeInterval(-3_600)
    wall.set(rolledBackWall)
    uptime.set(160)
    firstAgent.setTemporaryAccess(minutes: 30)
    try expect(
        waitUntil {
            let current = firstAgent.config
            return current.accessExpiresAt
                    == rolledBackWall.addingTimeInterval(1_800)
                && current.accessExpiresUptime == 1_960
                && current.accessBootIdentifier
                    == "temporary-entry-boot-a"
                && current.accessAnchorWallTime == rolledBackWall
                && current.accessRemainingAtAnchor == 1_800
                && (try? store.load().accessExpiresUptime) == 1_960
        },
        "A repeated request after wall-clock rollback must replace every anchor "
            + "and grant exactly 30 new monotonic minutes"
    )
    try stopAgent(firstAgent)

    let sameBootAgent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { rolledBackWall.addingTimeInterval(120) },
        monotonicUptimeProvider: { 280 },
        bootIdentifierProvider: { "temporary-entry-boot-a" },
        performInitialCheckOnStart: false
    )
    defer { stopAgentForCleanup(sameBootAgent) }
    try expect(
        sameBootAgent.config.remoteAccessEnabled
            && sameBootAgent.config.accessExpiresUptime == 1_960
            && sameBootAgent.config.accessBootIdentifier
                == "temporary-entry-boot-a"
            && sameBootAgent.config.accessAnchorWallTime == rolledBackWall
            && sameBootAgent.config.accessRemainingAtAnchor == 1_800,
        "A process restart in the same boot must preserve the monotonic deadline"
    )
    try stopAgent(sameBootAgent)

    let crossBootAgent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { rolledBackWall.addingTimeInterval(-7_200) },
        monotonicUptimeProvider: { 10 },
        bootIdentifierProvider: { "temporary-entry-boot-b" },
        performInitialCheckOnStart: false
    )
    defer { stopAgentForCleanup(crossBootAgent) }
    let crossBoot = crossBootAgent.config
    try expect(
        !crossBoot.remoteAccessEnabled
            && hasNoTemporaryAccessExpiration(crossBoot),
        "A temporary session restored in another boot must fail closed even "
            + "when the wall clock moved backward"
    )
    try stopAgent(crossBootAgent)
}

func hasNoTemporaryAccessExpiration(_ config: AppConfig) -> Bool {
    config.accessExpiresAt == nil
        && config.accessExpiresUptime == nil
        && config.accessBootIdentifier == nil
        && config.accessAnchorWallTime == nil
        && config.accessRemainingAtAnchor == nil
}

func testTemporaryAccessUsesMonotonicDeadlineAfterWallRollback() throws {
    let directory = try makeTemporaryDirectory(
        named: "temporary-monotonic-wall-rollback"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let wall = LockedClock(Date(timeIntervalSince1970: 2_000_120_000))
    let uptime = LockedMonotonicClock(100)
    let scheduleLock = NSLock()
    var scheduledHandlers: [() -> Void] = []
    var config = AppConfig.default
    config.dnsProvider = .disabled
    config.mappingProtocolPreference = .disabled
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: directory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { wall.now() },
        monotonicUptimeProvider: { uptime.now() },
        bootIdentifierProvider: { "temporary-wall-rollback-boot" },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { _, handler in
            scheduleLock.lock()
            scheduledHandlers.append(handler)
            scheduleLock.unlock()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }
    agent.start()
    agent.setTemporaryAccess(minutes: 30)
    try expect(
        waitUntil {
            scheduleLock.lock()
            let scheduled = !scheduledHandlers.isEmpty
            scheduleLock.unlock()
            return scheduled && agent.config.accessExpiresUptime == 1_900
        },
        "Temporary access must arm its monotonic expiration timer"
    )

    wall.set(wall.now().addingTimeInterval(-86_400))
    uptime.set(1_899)
    scheduleLock.lock()
    let earlyHandler = scheduledHandlers.last
    scheduleLock.unlock()
    guard let earlyHandler else {
        throw IntegrationContractFailure(
            "The temporary-access expiration handler was not captured"
        )
    }
    earlyHandler()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try expect(
        agent.config.remoteAccessEnabled,
        "Wall-clock rollback must not expire access before its monotonic deadline"
    )

    uptime.set(1_900)
    scheduleLock.lock()
    let deadlineHandler = scheduledHandlers.last
    scheduleLock.unlock()
    guard let deadlineHandler else {
        throw IntegrationContractFailure(
            "The monotonic deadline handler was not rescheduled"
        )
    }
    deadlineHandler()
    try expect(
        waitUntil {
            !agent.config.remoteAccessEnabled
                && hasNoTemporaryAccessExpiration(agent.config)
        },
        "Temporary access must close at 30 monotonic minutes despite a wall-clock rollback"
    )
    try stopAgent(agent)
}

func testCloudflareZoneReadPresentationDoesNotClaimDNSReady() throws {
    let singular = SettingsCloudflareZoneReadPresentation.message(
        zoneCount: 1,
        pendingStorage: false
    )
    try expect(
        singular == "Token is active and can read 1 zone. DNS Edit is confirmed when Gatebeam updates the selected record.",
        "Verify must accurately describe one readable zone without claiming DNS readiness"
    )
    let plural = SettingsCloudflareZoneReadPresentation.message(
        zoneCount: 2,
        pendingStorage: true
    )
    try expect(plural.contains("2 zones"), "Verify must use the plural zone form")
    try expect(plural.contains("Save Changes stores it"), "An unsaved verified token must be described as pending storage")
    for message in [singular, plural] {
        try expect(!message.contains("Connected"), "Zone Read verification must never claim Connected")
        try expect(!message.contains("ready"), "Zone Read verification must never claim DNS ready")
    }
}

func testSettingsCloudflareErrorPresentationFailsClosed() throws {
    let secret = "cfut_UI_SECRET_123"
    let unexpected = SettingsCloudflareErrorPresentation.message(
        for: SimulatedLeakingCloudflareFailure(secret: secret)
    )
    try expect(
        unexpected == SettingsCloudflareErrorPresentation.genericMessage,
        "An unexpected Cloudflare-path error must use fixed local UI copy"
    )
    try expect(
        !unexpected.contains(secret) && !unexpected.contains("proxy-password"),
        "Unexpected backend errors must not expose token or proxy fragments in Settings"
    )

    let invalidProxy = SettingsCloudflareErrorPresentation.message(
        for: NetworkError.invalidProxyURL(
            "http://proxy-user:proxy-password@example.test cfut_PROXY_SECRET"
        )
    )
    try expect(
        invalidProxy == "Invalid proxy URL: \(SettingsProxyValidation.formatMessage)",
        "Proxy validation UI must use the fixed local format message"
    )
    try expect(
        !invalidProxy.contains("proxy-password") && !invalidProxy.contains("cfut_"),
        "Proxy validation UI must not echo the rejected proxy value"
    )

    let controlled = CloudflareError.service(
        operation: .listZones,
        failure: .rejected(httpStatus: 500, safeCodes: [])
    )
    try expect(
        SettingsCloudflareErrorPresentation.message(for: controlled)
            == controlled.localizedDescription,
        "A controlled Cloudflare error must retain its fixed actionable UI copy"
    )
}

func testRemoteConnectionURLPolicyFailsClosedWhenAccessIsOff() throws {
    var status = AppStatus.initial
    status.connectionURL = "vnc://remote.example.test:45900"
    status.connectionURLIPv4 = "vnc://192.0.2.8:45900"
    status.connectionURLIPv6 = "vnc://[2001:db8::8]:5900"

    try expect(
        RemoteConnectionURLPolicy.displayURL(remoteAccessEnabled: false, status: status)
            == RemoteConnectionURLPolicy.unavailableText,
        "An off UI must display an unavailable placeholder instead of a stale VNC URL"
    )
    try expect(
        RemoteConnectionURLPolicy.primaryCopyURL(remoteAccessEnabled: false, status: status) == nil,
        "The primary copy action must fail closed while remote access is off"
    )
    try expect(
        RemoteConnectionURLPolicy.ipv6CopyURL(remoteAccessEnabled: false, status: status) == nil,
        "The IPv6 copy action must fail closed while remote access is off"
    )
    try expect(
        RemoteConnectionURLPolicy.primaryCopyURL(remoteAccessEnabled: true, status: status)
            == status.connectionURLIPv4,
        "The enabled primary copy action must prefer the explicit IPv4 URL"
    )
}

func testExplicitReplacementAndRemovalAreIdempotent() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "token-explicit-mutations")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let lock = NSLock()
    var storedToken: String? = "old-token"
    var writes: [String] = []
    var readCount = 0
    var deleteCount = 0
    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { value, _ in
                lock.lock()
                storedToken = value
                writes.append(value)
                lock.unlock()
            },
            get: { _ in
                lock.lock()
                defer { lock.unlock() }
                readCount += 1
                return storedToken
            },
            delete: { _ in
                lock.lock()
                storedToken = nil
                deleteCount += 1
                lock.unlock()
            }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )

    _ = try agent.persistSettings(
        config: .default,
        tokenMutation: .replace("new-token")
    )
    _ = try agent.persistSettings(
        config: .default,
        tokenMutation: .replace("new-token")
    )
    try expect(writes == ["new-token"], "Repeating the same replacement must not rewrite Keychain")
    try expect(readCount == 0, "Explicit replacement must not pre-read the old token")
    try expect(agent.cloudflareTokenState == .available("new-token"), "Replacement must update the visible token state")

    try agent.applyCloudflareTokenMutation(.explicitRemove)
    try agent.applyCloudflareTokenMutation(.explicitRemove)
    try expect(deleteCount == 1, "Repeating explicit removal must not trigger another Keychain prompt or delete")
    try expect(readCount == 0, "Explicit removal must not pre-read the old token")
    try expect(storedToken == nil, "Explicit removal must delete the saved token")
    try expect(agent.cloudflareTokenState == .missing, "Explicit removal must publish missing state")
}

func testDisabledSideEffectsRejectChecks() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "side-effects-disabled")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.checkIntervalSeconds = 0.01

    var checkExecutions = 0
    var statusChanges = 0
    let store = AppConfigStore(baseDirectory: baseDirectory)
    let agent = NetworkAgent(
        configStore: store,
        keychain: KeychainStore(service: "io.github.naifuliang.gatebeam.side-effects-disabled"),
        initialConfig: config,
        sideEffectsEnabled: false,
        checkExecutionObserver: { checkExecutions += 1 }
    )
    defer { stopAgentForCleanup(agent) }
    agent.onStatusChanged = { _ in statusChanges += 1 }

    agent.start()
    agent.runCheck()
    agent.saveConfig(config)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))

    try expect(checkExecutions == 0, "Disabled side effects must never enter the network/router check execution boundary")
    try expect(statusChanges == 0, "Rejected checks must not publish transient checking states")
    try expect(agent.status.ddnsStatus.state == .unknown, "Rejected checks must leave DDNS status unchanged")
    try expect(agent.status.routerStatus.state == .unknown, "Rejected checks must leave router status unchanged")
    try expect(agent.status.lastCheckedAt == nil, "Rejected checks must not report a completed check")
    try expect(!FileManager.default.fileExists(atPath: store.location.path), "Rejected checks must not persist config")
}

func testDisabledSideEffectsDoNotReadSuppliedConfigStore() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "side-effects-config-isolation")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let suppliedStore = AppConfigStore(baseDirectory: baseDirectory)
    let originalData = Data(
        #"{"activeRouterMappings":[{"pcpNonce":"must-not-be-read"}],"broken":"#.utf8
    )
    try originalData.write(to: suppliedStore.location, options: [.atomic])

    let agent = NetworkAgent(
        configStore: suppliedStore,
        keychain: KeychainStore(
            service: "unused",
            operationHandlers: KeychainOperationHandlers(
                set: { _, _ in throw IntegrationContractFailure("Isolated validation must not write Keychain") },
                get: { _ in throw IntegrationContractFailure("Isolated validation must not read Keychain") },
                delete: { _ in throw IntegrationContractFailure("Isolated validation must not delete Keychain") }
            )
        ),
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }

    try expect(agent.config.dnsRecordName.isEmpty, "Disabled side effects must start from isolated defaults")
    try expect(!agent.config.remoteAccessEnabled, "Disabled side effects must not inherit production enablement")
    let unchangedData = try Data(contentsOf: suppliedStore.location)
    try expect(
        unchangedData == originalData,
        "Disabled side effects must not rewrite the supplied production-like config"
    )
    try expect(agent.cloudflareToken().isEmpty, "Validation mode must expose no production Keychain value")
}

func testKeychainReadFailurePropagates() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-read-failure")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { _, _ in },
            get: { _ in throw SimulatedKeychainFailure(operation: "read") },
            delete: { _ in }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }

    do {
        _ = try agent.loadCloudflareToken()
        throw IntegrationContractFailure("A non-not-found Keychain read error must propagate")
    } catch is SimulatedKeychainFailure {
        // Expected.
    }
    try expect(agent.cloudflareToken().isEmpty, "A failed read must not populate the token cache")
    try expect(
        agent.status.settingsErrorMessage?.contains("Could not read") == true,
        "A Keychain read failure must be visible in settings"
    )
}

func testKeychainDeleteFailurePreservesTokenAndBlocksConfig() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-delete-failure")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let existingToken = "existing-test-token"
    var deleteShouldFail = true
    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { _, _ in },
            get: { _ in existingToken },
            delete: { _ in
                if deleteShouldFail {
                    throw SimulatedKeychainFailure(operation: "delete")
                }
            }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }
    let loadedToken = try agent.loadCloudflareToken()
    try expect(loadedToken == existingToken, "The fixture token must load before deletion")
    var changedConfig = AppConfig.default
    changedConfig.checkIntervalSeconds = 900

    do {
        try agent.persistSettings(config: changedConfig, tokenMutation: .explicitRemove)
        throw IntegrationContractFailure("A Keychain delete error must propagate through settings persistence")
    } catch is SimulatedKeychainFailure {
        // Expected.
    }

    let rolledBackConfig = try AppConfigStore(baseDirectory: baseDirectory).load()
    try expect(
        rolledBackConfig.checkIntervalSeconds == AppConfig.default.checkIntervalSeconds,
        "A failed token deletion must roll back the requested config change"
    )
    try expect(agent.cloudflareToken() == existingToken, "A failed deletion must preserve the cached token for UI rollback")
    try expect(
        agent.status.settingsErrorMessage?.contains("Could not delete") == true,
        "A Keychain delete failure must be visible in settings"
    )

    deleteShouldFail = false
    try agent.persistSettings(config: changedConfig, tokenMutation: .explicitRemove)
    try expect(FileManager.default.fileExists(atPath: agentConfigPath(baseDirectory)), "A successful retry may persist config after Keychain deletion")
    let persistedConfig = try AppConfigStore(baseDirectory: baseDirectory).load()
    try expect(
        persistedConfig.checkIntervalSeconds == 900,
        "A successful retry must persist the requested config"
    )
    try expect(agent.cloudflareToken().isEmpty, "A successful retry must update the cached token")
    try expect(agent.status.settingsErrorMessage == nil, "A successful Keychain retry must clear its visible error")
}

func testKeychainSingleFlightAndFailureLatch() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-single-flight")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let reads = LockedCounter()
    let readGate = DispatchSemaphore(value: 0)
    let phaseLock = NSLock()
    var shouldBlock = true
    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { _, _ in },
            get: { _ in
                reads.increment()
                phaseLock.lock()
                let block = shouldBlock
                phaseLock.unlock()
                if block {
                    readGate.wait()
                }
                throw SimulatedKeychainFailure(operation: "read")
            },
            delete: { _ in }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }

    let callers = 8
    let group = DispatchGroup()
    let startGate = DispatchSemaphore(value: 0)
    for _ in 0..<callers {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            startGate.wait()
            defer { group.leave() }
            do {
                _ = try agent.loadCloudflareToken(retryAfterFailure: true)
            } catch {
                // Every waiter must receive the same flight failure.
            }
        }
    }
    for _ in 0..<callers {
        startGate.signal()
    }
    Thread.sleep(forTimeInterval: 0.1)
    for _ in 0..<callers {
        readGate.signal()
    }
    try expect(group.wait(timeout: .now() + 3) == .success, "Concurrent Keychain callers must not deadlock")
    try expect(reads.current == 1, "Concurrent reads must share one Keychain authorization flight")

    for _ in 0..<4 {
        do {
            _ = try agent.loadCloudflareToken(retryAfterFailure: false)
        } catch {
            // Background readers consume the latched error.
        }
    }
    try expect(reads.current == 1, "Background reads must not retry a latched Keychain denial")

    phaseLock.lock()
    shouldBlock = false
    phaseLock.unlock()
    do {
        _ = try agent.loadCloudflareToken(retryAfterFailure: true)
    } catch {
        // An explicit retry may perform exactly one new Keychain read.
    }
    try expect(reads.current == 2, "An explicit retry must cross the failure latch exactly once")
}

func testKeychainLegacyMigrationRequiresExplicitAuthorization() throws {
    let currentService = "io.github.naifuliang.gatebeam.keychain-test.v3"
    let legacyService = "io.github.naifuliang.gatebeam.keychain-test.v2"
    let account = "cloudflare-api-token"
    let legacyToken = "legacy-fixture-token"
    let lock = NSLock()
    var values = ["\(legacyService):\(account)": legacyToken]
    var events: [String] = []

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [legacyService],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { value, scopedAccount, service, interaction, refreshAccess in
                lock.lock()
                events.append("set:\(service):\(interaction):\(refreshAccess)")
                values["\(service):\(scopedAccount)"] = value
                lock.unlock()
            },
            scopedGet: { scopedAccount, service, interaction in
                lock.lock()
                defer { lock.unlock() }
                events.append("get:\(service):\(interaction)")
                return values["\(service):\(scopedAccount)"]
            },
            scopedDelete: { scopedAccount, service, interaction in
                lock.lock()
                events.append("delete:\(service):\(interaction)")
                values.removeValue(forKey: "\(service):\(scopedAccount)")
                lock.unlock()
            }
        )
    )

    let backgroundValue = try keychain.get(account: account, interaction: .background)
    try expect(backgroundValue == nil, "Background reads must query only the versioned current service")
    try expect(
        events == ["get:\(currentService):background"],
        "Background reads must never enumerate or read a weak legacy service"
    )

    events.removeAll()
    let outcome = try keychain.authorizeCurrentOrMigrateLegacy(account: account)
    try expect(
        outcome == .migratedLegacyToken(token: legacyToken),
        "An explicit authorization action must migrate the legacy token"
    )
    try expect(
        values["\(currentService):\(account)"] == legacyToken,
        "Migration must create the versioned secure item"
    )
    try expect(
        values["\(legacyService):\(account)"] == nil,
        "Migration must delete the weak legacy item after verification"
    )
    try expect(
        events.contains("get:\(legacyService):userInitiated"),
        "Legacy reads must be user initiated"
    )
    try expect(
        events.contains("set:\(currentService):userInitiated:true"),
        "Migration must bind the new item to the current application ACL"
    )
    try expect(
        events.contains("delete:\(legacyService):userInitiated"),
        "Legacy cleanup must remain inside the explicit authorization action"
    )
}

func testKeychainRequirementClassificationRejectsWeakAlternatives() throws {
    let bundleIdentifier = "io.github.naifuliang.gatebeam"
    let teamIdentifier = "TEAMID1234"
    let preview = { (requirement: String) in
        KeychainStore.SigningIdentity(
            requirement: requirement,
            signedBundleIdentifier: bundleIdentifier,
            expectedBundleIdentifier: bundleIdentifier,
            signedTeamIdentifier: nil,
            expectedTeamIdentifier: nil,
            currentCDHashes: [
                "1111111111111111111111111111111111111111",
                "2222222222222222222222222222222222222222"
            ],
            hasHardenedRuntime: true,
            hasRuntimeVersion: true,
            hasSecureTimestamp: false
        )
    }
    func developerID(
        _ requirement: String,
        signedBundleIdentifier: String? = nil,
        expectedBundleIdentifier: String? = nil,
        signedTeamIdentifier: String? = nil,
        expectedTeamIdentifier: String? = nil,
        hasHardenedRuntime: Bool = true,
        hasRuntimeVersion: Bool = true,
        hasSecureTimestamp: Bool = true
    ) -> KeychainStore.SigningIdentity {
        KeychainStore.SigningIdentity(
            requirement: requirement,
            signedBundleIdentifier: signedBundleIdentifier ?? bundleIdentifier,
            expectedBundleIdentifier: expectedBundleIdentifier ?? bundleIdentifier,
            signedTeamIdentifier: signedTeamIdentifier ?? teamIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier ?? teamIdentifier,
            currentCDHashes: [],
            hasHardenedRuntime: hasHardenedRuntime,
            hasRuntimeVersion: hasRuntimeVersion,
            hasSecureTimestamp: hasSecureTimestamp
        )
    }
    let validDeveloperID =
        #"identifier "io.github.naifuliang.gatebeam" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TEAMID1234"#

    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(preview(
            #"cdhash H"1111111111111111111111111111111111111111" or cdhash H"2222222222222222222222222222222222222222""#
        )) != nil,
        "A pure exact-build cdhash set must be accepted for Developer Preview"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(preview(
            #"cdhash H"3333333333333333333333333333333333333333""#
        )) == nil,
        "A different build cdhash must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(preview(
            #"identifier "io.github.naifuliang.gatebeam""#
        )) == nil,
        "An identifier-only requirement must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(preview(
            #"identifier "io.github.naifuliang.gatebeam" or cdhash H"1111111111111111111111111111111111111111""#
        )) == nil,
        "A cdhash requirement with a weak identifier alternative must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(preview(
            #"true or cdhash H"1111111111111111111111111111111111111111""#
        )) == nil,
        "A cdhash requirement with a permissive alternative must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(
            developerID(validDeveloperID)
        ) != nil,
        "A canonical TN3127 Developer ID Application requirement must be accepted"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            #"identifier "io.github.naifuliang.gatebeam" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = "TEAMID1234""#
        )) == nil,
        "An Apple Development-like requirement must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            #"identifier "io.github.naifuliang.gatebeam" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.14] exists and certificate leaf[subject.OU] = "TEAMID1234""#
        )) == nil,
        "A Developer ID Installer-like requirement must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            #"identifier "io.github.naifuliang.gatebeam" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMID1234""#
        )) == nil,
        "Certificate OID fields without existence constraints must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            #"identifier "io.github.naifuliang.gatebeam" or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TEAMID1234")"#
        )) == nil,
        "A Developer ID requirement with a weak OR alternative must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID,
            signedBundleIdentifier: "io.github.naifuliang.gatebeam.spoof"
        )) == nil,
        "A signed Bundle ID mismatch must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID.replacingOccurrences(
                of: bundleIdentifier,
                with: "io.github.naifuliang.gatebeam.spoof"
            )
        )) == nil,
        "A requirement with the wrong Bundle ID must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID,
            signedTeamIdentifier: "OTHERTEAM1"
        )) == nil,
        "A signed Team ID mismatch must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID.replacingOccurrences(
                of: teamIdentifier,
                with: "OTHERTEAM1"
            )
        )) == nil,
        "A requirement with the wrong Team ID must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID,
            hasHardenedRuntime: false
        )) == nil,
        "A build without hardened runtime must be rejected"
    )
    try expect(
        KeychainStore.validatedTrustedApplicationRequirement(developerID(
            validDeveloperID,
            hasSecureTimestamp: false
        )) == nil,
        "A Developer ID build without a secure timestamp must be rejected"
    )
}

func testCurrentKeychainItemAuthorizationRefreshesAccess() throws {
    let currentService = "io.github.naifuliang.gatebeam.keychain-rebind.v3"
    let legacyService = "io.github.naifuliang.gatebeam.keychain-rebind.v2"
    let account = "cloudflare-api-token"
    let token = "current-fixture-token"
    var values = ["\(currentService):\(account)": token]
    var events: [String] = []

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [legacyService],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { value, scopedAccount, service, interaction, refreshAccess in
                events.append("set:\(service):\(interaction):\(refreshAccess)")
                values["\(service):\(scopedAccount)"] = value
            },
            scopedGet: { scopedAccount, service, interaction in
                events.append("get:\(service):\(interaction)")
                return values["\(service):\(scopedAccount)"]
            },
            scopedDelete: { _, service, interaction in
                events.append("delete:\(service):\(interaction)")
            }
        )
    )

    let outcome = try keychain.authorizeCurrentOrMigrateLegacy(account: account)
    try expect(
        outcome == .authorized(token: token),
        "An existing current item must be authorized without legacy migration"
    )
    try expect(
        events.contains("set:\(currentService):userInitiated:true"),
        "Explicit authorization must refresh the current item's ACL for this build"
    )
    try expect(
        events.contains("get:\(legacyService):userInitiated"),
        "Explicit authorization must check for and clean any remaining weak legacy copy"
    )
}

func testLegacyCleanupFailureRetriesWithoutLosingSecureCopy() throws {
    let currentService = "io.github.naifuliang.gatebeam.keychain-cleanup.v3"
    let legacyService = "io.github.naifuliang.gatebeam.keychain-cleanup.v2"
    let account = "cloudflare-api-token"
    let token = "cleanup-fixture-token"
    var values = ["\(legacyService):\(account)": token]
    var legacyDeleteShouldFail = true

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [legacyService],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { value, scopedAccount, service, _, _ in
                values["\(service):\(scopedAccount)"] = value
            },
            scopedGet: { scopedAccount, service, _ in
                values["\(service):\(scopedAccount)"]
            },
            scopedDelete: { scopedAccount, service, _ in
                if service == legacyService, legacyDeleteShouldFail {
                    throw SimulatedKeychainFailure(operation: "legacy cleanup")
                }
                values.removeValue(forKey: "\(service):\(scopedAccount)")
            }
        )
    )

    do {
        _ = try keychain.authorizeCurrentOrMigrateLegacy(account: account)
        throw IntegrationContractFailure("A failed legacy cleanup must not report migration success")
    } catch is KeychainError {
        // The secure copy remains available while the weak copy is reported and retried.
    }
    try expect(
        values["\(currentService):\(account)"] == token,
        "A verified secure copy must survive a legacy cleanup failure"
    )
    try expect(
        values["\(legacyService):\(account)"] == token,
        "A failed cleanup must remain observable for a later explicit retry"
    )

    legacyDeleteShouldFail = false
    let retryOutcome = try keychain.authorizeCurrentOrMigrateLegacy(account: account)
    try expect(
        retryOutcome == .migratedLegacyToken(token: token),
        "The next explicit authorization must finish legacy cleanup"
    )
    try expect(
        values["\(legacyService):\(account)"] == nil,
        "A successful retry must remove the weak legacy copy"
    )
}

func testExplicitKeychainAuthorizationClearsFailureLatch() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-explicit-authorization")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let currentService = "io.github.naifuliang.gatebeam.keychain-latch.v3"
    let token = "authorized-fixture-token"
    let lock = NSLock()
    var explicitAuthorizationShouldFail = true
    var currentBuildAuthorized = false
    var backgroundReads = 0
    var userReads = 0

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, interaction, refreshAccess in
                try expect(interaction == .userInitiated, "ACL refresh must be user initiated")
                try expect(refreshAccess, "Explicit authorization must refresh the access requirement")
            },
            scopedGet: { _, _, interaction in
                lock.lock()
                defer { lock.unlock() }
                if interaction == .background {
                    backgroundReads += 1
                    guard currentBuildAuthorized else {
                        throw KeychainError.status(
                            operation: "read",
                            code: errSecInteractionNotAllowed
                        )
                    }
                    return token
                }

                userReads += 1
                if explicitAuthorizationShouldFail {
                    throw SimulatedKeychainFailure(operation: "authorization")
                }
                currentBuildAuthorized = true
                return token
            },
            scopedDelete: { _, _, _ in }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }

    do {
        _ = try agent.loadCloudflareToken(
            retryAfterFailure: false,
            interaction: .background
        )
        throw IntegrationContractFailure("An unauthorized background read must fail without prompting")
    } catch let error as KeychainError {
        try expect(error.requiresUserAuthorization, "The denial must identify an explicit authorization boundary")
    }
    do {
        _ = try agent.loadCloudflareToken(
            retryAfterFailure: false,
            interaction: .background
        )
    } catch {
        // The second background caller must consume the latch.
    }
    try expect(backgroundReads == 1, "A background authorization denial must be latched")

    var firstResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.authorizeSavedCloudflareToken { firstResult = $0 }
    try expect(
        waitUntil { firstResult != nil },
        "The explicit authorization failure callback must arrive"
    )
    if case .success = firstResult {
        throw IntegrationContractFailure("A denied explicit authorization must not report success")
    }
    try expect(userReads == 1, "One Settings action must create exactly one authorization attempt")

    do {
        _ = try agent.loadCloudflareToken(
            retryAfterFailure: false,
            interaction: .background
        )
    } catch {
        // The explicit failure remains latched for background work.
    }
    try expect(
        backgroundReads == 1,
        "A failed Settings authorization must remain latched for background work"
    )

    lock.lock()
    explicitAuthorizationShouldFail = false
    lock.unlock()
    var secondResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.authorizeSavedCloudflareToken { secondResult = $0 }
    try expect(
        waitUntil { secondResult != nil },
        "The successful explicit authorization callback must arrive"
    )
    let successfulOutcome = try secondResult?.get()
    try expect(
        successfulOutcome == .authorized(token: token),
        "A later explicit Settings action may cross the latch and rebind the item"
    )
    try expect(agent.cloudflareToken() == token, "Successful authorization must refresh the token cache")
    try expect(
        agent.status.settingsErrorMessage == nil,
        "Successful authorization must clear the visible Keychain failure"
    )
}

func testLegacyMigrationSerializesConcurrentKeepExistingSave() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-migration-empty-save")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let currentService = "io.github.naifuliang.gatebeam.keychain-race.v3"
    let legacyService = "io.github.naifuliang.gatebeam.keychain-race.v2"
    let account = "cloudflare-api-token"
    let lock = NSLock()
    let currentCopyWritten = DispatchSemaphore(value: 0)
    let finishMigration = DispatchSemaphore(value: 0)
    var values = ["\(legacyService):\(account)": "legacy-race-token"]
    var events: [String] = []

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [legacyService],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { value, scopedAccount, service, _, refreshAccess in
                lock.lock()
                values["\(service):\(scopedAccount)"] = value
                events.append("set:\(service):\(refreshAccess)")
                lock.unlock()
                if service == currentService, refreshAccess {
                    currentCopyWritten.signal()
                    finishMigration.wait()
                }
            },
            scopedGet: { scopedAccount, service, _ in
                lock.lock()
                defer { lock.unlock() }
                events.append("get:\(service)")
                return values["\(service):\(scopedAccount)"]
            },
            scopedDelete: { scopedAccount, service, _ in
                lock.lock()
                events.append("delete:\(service)")
                values.removeValue(forKey: "\(service):\(scopedAccount)")
                lock.unlock()
            }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }

    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.authorizeSavedCloudflareToken { authorizationResult = $0 }
    try expect(
        currentCopyWritten.wait(timeout: .now() + 3) == .success,
        "Migration must reach the verified current-service copy"
    )

    var saveResult: Result<AppConfig, Error>?
    agent.persistSettingsAsync(config: .default, tokenMutation: .keepExisting) { saveResult = $0 }
    Thread.sleep(forTimeInterval: 0.05)
    lock.lock()
    let eventsWhileMigrationIsBlocked = events
    lock.unlock()
    try expect(
        !eventsWhileMigrationIsBlocked.contains("delete:\(currentService)"),
        "A keep-existing save submitted during migration must not touch Keychain before authorization finishes"
    )
    finishMigration.signal()

    try expect(
        waitUntil { authorizationResult != nil && saveResult != nil },
        "Migration and the queued empty save must both complete"
    )
    _ = try authorizationResult?.get()
    _ = try saveResult?.get()

    lock.lock()
    let finalValues = values
    let finalEvents = events
    lock.unlock()
    let legacyDelete = finalEvents.firstIndex(of: "delete:\(legacyService)")
    let currentDelete = finalEvents.lastIndex(of: "delete:\(currentService)")
    try expect(
        legacyDelete != nil && currentDelete == nil,
        "Migration may remove only the legacy item; a keep-existing save must never delete the current item"
    )
    try expect(
        finalValues["\(currentService):\(account)"] == "legacy-race-token"
            && finalValues["\(legacyService):\(account)"] == nil,
        "A keep-existing save must preserve the migrated token"
    )
    try expect(
        agent.cloudflareToken() == "legacy-race-token",
        "The UI token cache must retain the authorized token after a keep-existing save"
    )
    try expect(agent.status.settingsErrorMessage == nil, "Successful migration and save must clear Keychain errors")
}

func testOldBackgroundReadCannotOverwriteAuthorizationSuccess() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-stale-read")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let currentService = "io.github.naifuliang.gatebeam.keychain-stale-read.v3"
    let token = "authorized-after-stale-read"
    let lock = NSLock()
    let backgroundReadStarted = DispatchSemaphore(value: 0)
    let releaseBackgroundRead = DispatchSemaphore(value: 0)
    var firstBackgroundRead = true
    var events: [String] = []

    let keychain = KeychainStore(
        service: currentService,
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, refreshAccess in
                lock.lock()
                events.append("authorize-set:\(refreshAccess)")
                lock.unlock()
            },
            scopedGet: { _, _, interaction in
                if interaction == .background {
                    lock.lock()
                    let shouldFail = firstBackgroundRead
                    firstBackgroundRead = false
                    events.append(shouldFail ? "old-read-start" : "verify-read")
                    lock.unlock()
                    if shouldFail {
                        backgroundReadStarted.signal()
                        releaseBackgroundRead.wait()
                        lock.lock()
                        events.append("old-read-failure")
                        lock.unlock()
                        throw KeychainError.status(
                            operation: "read",
                            code: errSecInteractionNotAllowed
                        )
                    }
                    return token
                }
                lock.lock()
                events.append("authorization-read")
                lock.unlock()
                return token
            },
            scopedDelete: { _, _, _ in }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }

    let readFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { readFinished.signal() }
        _ = try? agent.loadCloudflareToken(
            retryAfterFailure: false,
            interaction: .background
        )
    }
    try expect(
        backgroundReadStarted.wait(timeout: .now() + 3) == .success,
        "The stale background read must be in flight before authorization"
    )

    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.authorizeSavedCloudflareToken { authorizationResult = $0 }
    releaseBackgroundRead.signal()
    try expect(
        waitUntil { authorizationResult != nil },
        "Authorization queued behind the old read must complete"
    )
    try expect(
        readFinished.wait(timeout: .now() + 3) == .success,
        "The old background read caller must be released"
    )
    let successfulAuthorization = try authorizationResult?.get()
    try expect(
        successfulAuthorization == .authorized(token: token),
        "Explicit authorization must succeed after the old read failure"
    )

    lock.lock()
    let finalEvents = events
    lock.unlock()
    let oldFailure = finalEvents.firstIndex(of: "old-read-failure")
    let authorizationRead = finalEvents.firstIndex(of: "authorization-read")
    try expect(
        oldFailure != nil && authorizationRead != nil && oldFailure! < authorizationRead!,
        "Authorization must be ordered after the older background Keychain result"
    )
    try expect(agent.cloudflareToken() == token, "An older read failure must not clear the authorized token cache")
    try expect(!agent.savedTokenNeedsAuthorization, "Authorization success must clear the failure latch")
    try expect(agent.status.settingsErrorMessage == nil, "Authorization success must remain the visible final state")
}

func testDeleteWriteAuthorizeOrderingSurvivesBackendRestart() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "keychain-operation-order")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let service = "io.github.naifuliang.gatebeam.keychain-order.v3"
    let lock = NSLock()
    var storedToken: String? = "initial-token"
    var events: [String] = []
    let keychain = KeychainStore(
        service: service,
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { value, _, _, interaction, refreshAccess in
                lock.lock()
                events.append("set:\(value):\(interaction):\(refreshAccess)")
                storedToken = value
                lock.unlock()
            },
            scopedGet: { _, _, interaction in
                lock.lock()
                defer { lock.unlock() }
                events.append("get:\(interaction)")
                return storedToken
            },
            scopedDelete: { _, _, interaction in
                lock.lock()
                events.append("delete:\(interaction)")
                storedToken = nil
                lock.unlock()
            }
        )
    )
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(agent) }
    let initialLoad = try agent.loadCloudflareToken(interaction: .background)
    try expect(
        initialLoad == "initial-token",
        "The ordering fixture must begin with a cached token"
    )

    var deleteResult: Result<AppConfig, Error>?
    var writeResult: Result<AppConfig, Error>?
    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.persistSettingsAsync(config: .default, tokenMutation: .explicitRemove) { deleteResult = $0 }
    agent.persistSettingsAsync(config: .default, tokenMutation: .replace("replacement-token")) { writeResult = $0 }
    agent.authorizeSavedCloudflareToken { authorizationResult = $0 }

    try expect(
        waitUntil {
            deleteResult != nil && writeResult != nil && authorizationResult != nil
        },
        "Delete, write, and authorization transactions must all complete"
    )
    _ = try deleteResult?.get()
    _ = try writeResult?.get()
    let finalAuthorization = try authorizationResult?.get()
    try expect(
        finalAuthorization == .authorized(token: "replacement-token"),
        "Authorization must observe the replacement written by the preceding transaction"
    )

    lock.lock()
    let finalEvents = events
    let finalStoredToken = storedToken
    lock.unlock()
    let deleteIndex = finalEvents.firstIndex(of: "delete:userInitiated")
    let writeIndex = finalEvents.firstIndex {
        $0.hasPrefix("set:replacement-token:userInitiated")
    }
    let authorizationReadIndex = finalEvents.lastIndex(of: "get:userInitiated")
    try expect(
        deleteIndex != nil
            && writeIndex != nil
            && authorizationReadIndex != nil
            && deleteIndex! < writeIndex!
            && writeIndex! < authorizationReadIndex!,
        "Keychain transactions must preserve submitted delete, write, authorize order"
    )
    try expect(finalStoredToken == "replacement-token", "The physical Keychain state must match the final authorization")

    let restartedAgent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: .default
    )
    defer { stopAgentForCleanup(restartedAgent) }
    let restartedToken = try restartedAgent.loadCloudflareToken(
        retryAfterFailure: false,
        interaction: .background
    )
    try expect(
        restartedToken == "replacement-token",
        "A restarted backend must read the same token committed before restart"
    )
    try expect(
        restartedAgent.cloudflareToken() == "replacement-token",
        "The restarted UI-facing cache must match the Keychain"
    )
    try expect(!restartedAgent.savedTokenNeedsAuthorization, "A clean restart must not show a stale authorization latch")
    try expect(restartedAgent.status.settingsErrorMessage == nil, "A clean restart must not show a stale Keychain error")
}

func testConfigStoreReportsRealWriteFailure() throws {
    let unwritableURL = URL(fileURLWithPath: "/dev/null/config.json")
    let store = AppConfigStore(configURL: unwritableURL)

    do {
        try store.save(.default)
        throw IntegrationContractFailure("A real unwritable config path must fail")
    } catch is AppConfigStoreError {
        // Expected.
    }
}

func testSettingsTransactionRollsBackOnConfigWriteFailure() throws {
    struct InjectedWriteFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "settings-transaction-rollback")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    var failWrites = false
    let store = AppConfigStore(
        configURL: configURL,
        dataWriter: { data, url in
            if failWrites {
                throw InjectedWriteFailure()
            }
            try data.write(to: url, options: [.atomic])
        }
    )

    var previousConfig = AppConfig.default
    previousConfig.dnsRecordName = "before.example.test"
    previousConfig.startAtLogin = false
    try store.save(previousConfig)

    var keychainToken = "before-token"
    let keychain = KeychainStore(
        service: "unused",
        operationHandlers: KeychainOperationHandlers(
            set: { value, _ in keychainToken = value },
            get: { _ in keychainToken },
            delete: { _ in keychainToken = "" }
        )
    )

    var loginEnabled = false
    var loginCalls: [Bool] = []
    let agent = NetworkAgent(
        configStore: store,
        keychain: keychain,
        initialConfig: previousConfig,
        loginItemSetter: { enabled in
            loginCalls.append(enabled)
            loginEnabled = enabled
            return .success(())
        }
    )
    defer { stopAgentForCleanup(agent) }
    _ = try agent.loadCloudflareToken()
    var rollbackCallbackConfig: AppConfig?
    var rollbackCallbackWasOnMain = false
    agent.onConfigChanged = { config in
        rollbackCallbackConfig = config
        rollbackCallbackWasOnMain = Thread.isMainThread
    }

    var requestedConfig = previousConfig
    requestedConfig.dnsRecordName = "after.example.test"
    requestedConfig.startAtLogin = true
    failWrites = true

    do {
        try agent.persistSettings(config: requestedConfig, tokenMutation: .replace("after-token"))
        throw IntegrationContractFailure("Config write failure must fail the settings transaction")
    } catch is AppConfigStoreError {
        // Expected.
    }

    failWrites = false
    let diskConfig = try store.load()
    let callbackDeadline = Date().addingTimeInterval(1)
    while rollbackCallbackConfig == nil, Date() < callbackDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(keychainToken == "before-token", "Config failure must restore the previous Keychain token")
    try expect(agent.cloudflareToken() == "before-token", "Config failure must restore the token cache")
    try expect(!loginEnabled, "Config failure must restore the previous login-item state")
    try expect(loginCalls == [true, false], "Login item must be applied and then compensated")
    try expect(agent.config.dnsRecordName == previousConfig.dnsRecordName, "In-memory config must not advance after disk failure")
    try expect(diskConfig.dnsRecordName == previousConfig.dnsRecordName, "Atomic disk failure must preserve the old config")
    try expect(agent.status.settingsErrorMessage != nil, "Config failure must remain visible to the UI")
    try expect(
        rollbackCallbackConfig?.dnsRecordName == previousConfig.dnsRecordName,
        "Config failure must notify the UI with the previous config"
    )
    try expect(rollbackCallbackWasOnMain, "Transaction rollback UI callbacks must run on the main thread")
}

func testConcurrentStateAccessDoesNotDeadlock() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "state-serialization")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: KeychainStore(
            service: "unused",
            operationHandlers: KeychainOperationHandlers(
                set: { _, _ in },
                get: { _ in nil },
                delete: { _ in }
            )
        ),
        initialConfig: .default,
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }

    let group = DispatchGroup()
    for index in 0..<200 {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            if index.isMultiple(of: 4) {
                var next = agent.config
                next.externalPort = UInt16(41000 + (index % 1000))
                agent.saveConfig(next)
            } else {
                _ = agent.config
                _ = agent.status
                _ = agent.cloudflareToken()
            }
        }
    }
    try expect(group.wait(timeout: .now() + 5) == .success, "Concurrent state reads and writes must not deadlock")

    var callbackArrived = false
    var callbackWasOnMain = false
    agent.onConfigChanged = { _ in
        callbackArrived = true
        callbackWasOnMain = Thread.isMainThread
    }
    var finalConfig = agent.config
    finalConfig.externalPort = 49999
    agent.saveConfig(finalConfig)
    let deadline = Date().addingTimeInterval(2)
    while !callbackArrived, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(callbackArrived, "Serialized config updates must still invoke their callback")
    try expect(callbackWasOnMain, "NetworkAgent callbacks must return to the main thread")
}

func testCheckCoalescingPreventsQueuedStorms() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "check-coalescing")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let listeningCalls = LockedCounter()
    let checkExecutions = LockedCounter()
    let local = MockLocalNetworkService()
    local.beforeListeningCheck = {
        if listeningCalls.increment() == 1 {
            entered.signal()
            release.wait()
        }
    }

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .disabled
    config.checkIntervalSeconds = 0
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkExecutionObserver: { checkExecutions.increment() },
        localNetworkService: local,
        routerMappingService: MockRouterMappingService(),
        publicIPServiceFactory: { _ in MockPublicIPService() }
    )
    defer { stopAgentForCleanup(agent) }

    agent.start()
    try expect(entered.wait(timeout: .now() + 2) == .success, "The first check must enter the injected gate")
    for _ in 0..<500 {
        agent.runCheck()
    }
    release.signal()
    try expect(
        waitUntil { checkExecutions.current == 2 && agent.status.lastCheckedAt != nil },
        "A burst received during one check must coalesce into one latest rerun"
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    try expect(checkExecutions.current == 2, "A zero legacy interval must not create a timer event storm")
    try expect(
        agent.config.checkIntervalSeconds == AppConfig.defaultCheckIntervalSeconds,
        "The timer must observe the normalized default interval"
    )
    try stopAgent(agent)
}

func testConfigMutationInvalidatesAnOldCheckBeforeRouterSideEffects() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "stale-check-cancellation")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let gateCalls = LockedCounter()
    let local = MockLocalNetworkService()
    local.beforeListeningCheck = {
        if gateCalls.increment() == 1 {
            entered.signal()
            release.wait()
        }
    }
    let router = MockRouterMappingService()
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp

    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: local,
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }
    agent.runCheck()
    try expect(entered.wait(timeout: .now() + 2) == .success, "The old check must pause before mapping work")

    var disabled = config
    disabled.remoteAccessEnabled = false
    agent.saveConfig(disabled)
    try expect(
        waitUntil { !agent.config.remoteAccessEnabled },
        "Saving the disabled state must finish without waiting for the old check"
    )
    release.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))

    try expect(
        router.ensureCalls.isEmpty,
        "A superseded check must not create or renew a router mapping after settings changed"
    )
    try expect(
        agent.config.activeRouterMappings.isEmpty,
        "A superseded check must not publish stale mapping state"
    )
    try stopAgent(agent)
}

func testSideEffectGateLinearizesTheFinalCheckWindow() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "side-effect-gate-final-window")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let sideEffectEntered = DispatchSemaphore(value: 0)
    let sideEffectRelease = DispatchSemaphore(value: 0)
    let observerCalls = LockedCounter()
    let router = MockRouterMappingService()
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp

    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        sideEffectWillStartObserver: { label in
            guard label == "router.mapping.create",
                  observerCalls.increment() == 1 else { return }
            sideEffectEntered.signal()
            sideEffectRelease.wait()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        emergencyMappingJournal: emergencyJournal(in: baseDirectory)
    )
    defer { stopAgentForCleanup(agent) }
    agent.runCheck()
    try expect(
        sideEffectEntered.wait(timeout: .now() + 2) == .success,
        "The check must pause after its final generation validation while holding the side-effect gate"
    )

    var disabled = config
    disabled.remoteAccessEnabled = false
    var saveCompleted = false
    agent.persistSettingsAsync(config: disabled, tokenMutation: .keepExisting) { result in
        if case .success = result {
            saveCompleted = true
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try expect(!saveCompleted, "A save that arrives second must wait for the in-flight side effect")
    try expect(agent.config.remoteAccessEnabled, "Revision must not advance through the held side-effect gate")

    sideEffectRelease.signal()
    try expect(
        waitUntil { saveCompleted && !agent.config.remoteAccessEnabled },
        "The save must commit immediately after the earlier side effect leaves the gate"
    )
    try expect(router.ensureCalls == [.ipv4], "The already-linearized mapping creation must run exactly once")
    try expect(
        agent.config.activeRouterMappings.isEmpty,
        "The waiting save must clean up the completed old-generation mapping"
    )
    try stopAgent(agent)
}

func testStopAndDisableCooperativelyCancelRouterTransaction() throws {
    func makeConfig() -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .disabled
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = .pcp
        return config
    }

    do {
        let directory = try makeTemporaryDirectory(
            named: "stop-router-cancellation"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let router = MockRouterMappingService()
        router.beforeEnsure = {
            entered.signal()
            release.wait()
        }
        router.cancellationHandler = {
            release.signal()
        }
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: directory),
            keychain: inMemoryKeychain(),
            initialConfig: makeConfig(),
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router,
            publicIPServiceFactory: { _ in MockPublicIPService() }
        )
        defer { stopAgentForCleanup(agent) }
        agent.runCheck()
        try expect(
            entered.wait(timeout: .now() + 2) == .success,
            "Stop test must enter the router transaction"
        )
        let started = ProcessInfo.processInfo.systemUptime
        agent.stop()
        try expect(
            ProcessInfo.processInfo.systemUptime - started < 0.2,
            "stop() must not wait behind the side-effect gate"
        )
        try stopAgent(agent)
        try expect(
            agent.config.activeRouterMappings.isEmpty
                && router.ensureCalls == [.ipv4],
            "A cancelled old-generation MAP result must not be persisted"
        )
    }

    do {
        let directory = try makeTemporaryDirectory(
            named: "disable-router-cancellation"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let router = MockRouterMappingService()
        router.beforeEnsure = {
            entered.signal()
            release.wait()
        }
        router.cancellationHandler = {
            release.signal()
        }
        var config = makeConfig()
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "disable-generation-zone"
        config.dnsRecordName = "disable-generation.example.test"
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        let publicIP = MockPublicIPService()
        let eventLock = NSLock()
        var events: [String] = []
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: directory),
            keychain: keychain,
            initialConfig: config,
            checkCompletionObserver: {
                completed.signal()
            },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP }
        )
        defer { stopAgentForCleanup(agent) }
        agent.runCheck()
        try expect(
            entered.wait(timeout: .now() + 2) == .success,
            "Disable test must enter the router transaction"
        )
        let started = ProcessInfo.processInfo.systemUptime
        agent.setRemoteAccessEnabled(false)
        try expect(
            waitUntil(timeout: 0.75) {
                !agent.config.remoteAccessEnabled
            },
            "Disable must cooperatively cancel the transaction and commit promptly"
        )
        try expect(
            ProcessInfo.processInfo.systemUptime - started < 0.75
                && router.ensureCalls == [.ipv4]
                && agent.config.activeRouterMappings.isEmpty,
            "Disable must remain single-flight and reject the late MAP result"
        )
        try expect(
            completed.wait(timeout: .now() + 0.75) == .success,
            "The superseded check must complete promptly after disable"
        )
        try stopAgent(agent)
        eventLock.lock()
        let observedEvents = events
        eventLock.unlock()
        try expect(
            publicIP.ipv4CallCount == 0
                && publicIP.ipv6CallCount == 0
                && router.externalIPv4CallCount == 0,
            "A mid-check disable must prevent every later public-IP and router-WAN probe"
        )
        try expect(
            !observedEvents.contains(where: {
                $0.hasPrefix("public-ip.")
                    || $0.hasPrefix("cloudflare.")
            }),
            "A mid-check disable must prevent every later public-IP and Cloudflare side effect"
        )
    }
}

func testDisabledRecoveryCheckSkipsAllNonCleanupNetworkWork() throws {
    let directory = try makeTemporaryDirectory(
        named: "disabled-recovery-short-circuit"
    )
    let store = AppConfigStore(baseDirectory: directory)
    let emergency = emergencyJournal(in: directory)
    let fallback = EmergencyMappingJournal(
        fileURL: directory.appendingPathComponent(
            "fallback-router-mappings.json"
        )
    )
    let recoveredMapping = activeMappingFixture(
        transport: .pcp,
        family: .ipv4
    )
    try store.saveMappingRecoveryJournal([recoveredMapping])

    var config = AppConfig.default
    config.remoteAccessEnabled = false
    config.dnsProvider = .cloudflare
    config.cloudflareZoneID = "disabled-recovery-zone"
    config.dnsRecordName = "disabled-recovery.example.test"
    config.preferredAddressFamily = .dualStack
    config.mappingProtocolPreference = .automatic

    let localNetwork = MockLocalNetworkService()
    let router = MockRouterMappingService()
    let publicIP = MockPublicIPService()
    let eventLock = NSLock()
    var events: [String] = []
    let completed = DispatchSemaphore(value: 0)
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkCompletionObserver: {
            completed.signal()
        },
        sideEffectWillStartObserver: { label in
            eventLock.lock()
            events.append(label)
            eventLock.unlock()
        },
        localNetworkService: localNetwork,
        routerMappingService: router,
        publicIPServiceFactory: { _ in publicIP },
        emergencyMappingJournal: emergency,
        fallbackMappingJournal: fallback,
        performInitialCheckOnStart: false
    )
    defer {
        stopAgentForCleanup(agent)
        try? FileManager.default.removeItem(at: directory)
    }

    let checkStarted = ProcessInfo.processInfo.systemUptime
    agent.runCheck()
    try expect(
        completed.wait(timeout: .now() + 1) == .success,
        "A disabled recovery check must complete through its explicit observer"
    )
    let checkElapsed =
        ProcessInfo.processInfo.systemUptime - checkStarted
    let stopStarted = ProcessInfo.processInfo.systemUptime
    try expect(
        agent.stopAndWaitUntilIdle(timeout: 0.5),
        "A disabled recovery agent must stop promptly after cleanup"
    )
    let stopElapsed =
        ProcessInfo.processInfo.systemUptime - stopStarted

    eventLock.lock()
    let observedEvents = events
    eventLock.unlock()
    let status = agent.status
    let persistedConfig = try store.load()
    let primaryRecoveryEmpty =
        try store.loadMappingRecoveryJournal().isEmpty
    let emergencyRecoveryEmpty = try emergency.load().isEmpty
    let fallbackRecoveryEmpty = try fallback.load().isEmpty
    try expect(
        router.removalCalls.map(\.identifier)
            == [recoveredMapping.identifier]
            && router.ensureCalls.isEmpty
            && router.operationCount == 1,
        "The disabled check must perform only the necessary recovered mapping delete"
    )
    try expect(
        localNetwork.callCount == 0
            && router.externalIPv4CallCount == 0
            && publicIP.ipv4CallCount == 0
            && publicIP.ipv6CallCount == 0,
        "The disabled check must skip local discovery, router WAN, and public-IP probes"
    )
    try expect(
        observedEvents == ["router.recovery.delete"],
        "The disabled check must expose only the required recovery side effect: \(observedEvents)"
    )
    try expect(
        primaryRecoveryEmpty
            && emergencyRecoveryEmpty
            && fallbackRecoveryEmpty
            && persistedConfig.activeRouterMappings.isEmpty
            && !persistedConfig.remoteAccessEnabled,
        "Recovery cleanup and the closed configuration must be durable before the check returns"
    )
    try expect(
        status.ddnsStatus.state == .disabled
            && status.routerStatus.state == .disabled
            && status.remoteDesktopStatus.state == .disabled
            && status.externalReachabilityStatus.state == .disabled
            && status.ddnsStatus.message == "Remote access is off"
            && status.routerStatus.message == "Remote access is off",
        "Every component must clearly report the closed state"
    )
    try expect(
        checkElapsed < 1 && stopElapsed < 0.5,
        "Closed recovery must complete and stop promptly (check \(checkElapsed)s, stop \(stopElapsed)s)"
    )
}

func testDisabledPersistedActiveMappingRecoveryMatrix() throws {
    typealias SeededState = (
        directory: URL,
        store: AppConfigStore,
        emergency: EmergencyMappingJournal,
        fallback: EmergencyMappingJournal
    )

    let wallClock = LockedClock(
        Date(timeIntervalSince1970: 80_000)
    )
    let uptime = LockedMonotonicClock(500)
    let currentBoot = "boot-disabled-active-current"

    func makeMapping(
        transport: RouterMappingTransport = .pcp,
        bootIdentifier: String = currentBoot,
        remainingLease: TimeInterval = 60
    ) -> ActiveRouterMapping {
        var mapping = activeMappingFixture(
            transport: transport,
            family: .ipv4,
            renewAfter: wallClock.now().addingTimeInterval(
                remainingLease / 2
            ),
            leaseExpiresAt: wallClock.now().addingTimeInterval(
                remainingLease
            )
        )
        mapping.routerExternalAddress = "203.0.113.53"
        mapping.leaseBootIdentifier = bootIdentifier
        mapping.leaseExpiresUptime =
            uptime.now() + remainingLease
        mapping.renewAfterUptime =
            uptime.now() + remainingLease / 2
        mapping.leaseAnchorWallTime = wallClock.now()
        mapping.leaseRemainingAtAnchor = remainingLease
        mapping.renewRemainingAtAnchor = remainingLease / 2
        if transport == .pcp || transport == .natpmp {
            mapping.routerEpoch = 500
            mapping.routerEpochObservedAt = wallClock.now()
            mapping.routerEpochObservedUptime = uptime.now()
            mapping.routerEpochBootIdentifier = bootIdentifier
        }
        return mapping
    }

    func seed(
        name: String,
        mapping: ActiveRouterMapping
    ) throws -> SeededState {
        let directory = try makeTemporaryDirectory(named: name)
        let store = AppConfigStore(baseDirectory: directory)
        let emergency = emergencyJournal(in: directory)
        let fallback = EmergencyMappingJournal(
            fileURL: directory.appendingPathComponent(
                "fallback-router-mappings.json"
            )
        )
        var config = AppConfig.default
        config.remoteAccessEnabled = false
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "disabled-active-zone"
        config.dnsRecordName = "disabled-active.example.test"
        config.preferredAddressFamily = .dualStack
        config.mappingProtocolPreference = .automatic
        config.activeRouterMappings = [mapping]
        try store.save(config)
        try store.saveMappingRecoveryJournal([mapping])
        try emergency.save([mapping])
        try fallback.save([mapping])
        return (directory, store, emergency, fallback)
    }

    func persistedIdentifiers(
        _ state: SeededState
    ) throws -> [[String]] {
        [
            try state.store.load()
                .activeRouterMappings.map(\.identifier),
            try state.store.loadMappingRecoveryJournal()
                .map(\.identifier),
            try state.emergency.load().map(\.identifier),
            try state.fallback.load().map(\.identifier)
        ]
    }

    do {
        let mapping = makeMapping()
        let seeded = try seed(
            name: "disabled-active-delete-success",
            mapping: mapping
        )
        let router = MockRouterMappingService()
        let localNetwork = MockLocalNetworkService()
        let publicIP = MockPublicIPService()
        let completed = DispatchSemaphore(value: 0)
        let eventLock = NSLock()
        var events: [String] = []
        let agent = NetworkAgent(
            configStore: seeded.store,
            keychain: inMemoryKeychain(),
            checkCompletionObserver: { completed.signal() },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: localNetwork,
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: seeded.emergency,
            fallbackMappingJournal: seeded.fallback,
            nowProvider: wallClock.now,
            monotonicUptimeProvider: uptime.now,
            bootIdentifierProvider: { currentBoot },
            performInitialCheckOnStart: false
        )
        defer {
            stopAgentForCleanup(agent)
            try? FileManager.default.removeItem(
                at: seeded.directory
            )
        }
        let checkStarted = ProcessInfo.processInfo.systemUptime
        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 1) == .success,
            "Persisted active cleanup success must complete promptly"
        )
        let checkElapsed =
            ProcessInfo.processInfo.systemUptime - checkStarted
        let stopStarted = ProcessInfo.processInfo.systemUptime
        try expect(
            agent.stopAndWaitUntilIdle(timeout: 0.5),
            "Persisted active cleanup success must stop promptly"
        )
        let stopElapsed =
            ProcessInfo.processInfo.systemUptime - stopStarted
        eventLock.lock()
        let observed = events
        eventLock.unlock()
        let identities = try persistedIdentifiers(seeded)
        try expect(
            router.removalCalls.map(\.identifier)
                == [mapping.identifier],
            "The active and three journal copies must deduplicate to one complete identity"
        )
        try expect(
            identities.allSatisfy(\.isEmpty),
            "Successful cleanup must durably clear main config and all three journals"
        )
        try expect(
            agent.config.activeRouterMappings.isEmpty
                && agent.status.routerStatus.state == .disabled,
            "Off may be displayed only after active mappings are durably empty"
        )
        try expect(
            localNetwork.callCount == 0
                && publicIP.ipv4CallCount == 0
                && publicIP.ipv6CallCount == 0
                && router.externalIPv4CallCount == 0
                && observed == ["router.recovery.delete"],
            "Successful closed cleanup must perform no non-cleanup network work"
        )
        try expect(
            checkElapsed < 1 && stopElapsed < 0.5,
            "Successful closed cleanup must meet completion and stop latency bounds"
        )
    }

    do {
        let mapping = makeMapping()
        let seeded = try seed(
            name: "disabled-active-delete-failure",
            mapping: mapping
        )
        let router = MockRouterMappingService()
        router.setRemovalFailures([mapping])
        let localNetwork = MockLocalNetworkService()
        let publicIP = MockPublicIPService()
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: seeded.store,
            keychain: inMemoryKeychain(),
            checkCompletionObserver: { completed.signal() },
            localNetworkService: localNetwork,
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: seeded.emergency,
            fallbackMappingJournal: seeded.fallback,
            nowProvider: wallClock.now,
            monotonicUptimeProvider: uptime.now,
            bootIdentifierProvider: { currentBoot },
            performInitialCheckOnStart: false
        )
        defer {
            stopAgentForCleanup(agent)
            try? FileManager.default.removeItem(
                at: seeded.directory
            )
        }
        let checkStarted = ProcessInfo.processInfo.systemUptime
        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 1) == .success,
            "Persisted active cleanup failure must complete promptly"
        )
        let checkElapsed =
            ProcessInfo.processInfo.systemUptime - checkStarted
        let identities = try persistedIdentifiers(seeded)
        try expect(
            identities.allSatisfy {
                $0 == [mapping.identifier]
            },
            "A failed delete must retain the complete identity in main config and all journals"
        )
        try expect(
            agent.status.routerStatus.state == .failed
                && agent.status.routerStatus.message
                    == "Router cleanup failed"
                && agent.status.remoteDesktopStatus.state
                    == .warning
                && agent.status.remoteDesktopStatus.message
                    == "A router rule may still be open",
            "A failed cleanup must not claim that remote access is safely off"
        )
        try expect(
            localNetwork.callCount == 0
                && publicIP.ipv4CallCount == 0
                && publicIP.ipv6CallCount == 0
                && router.externalIPv4CallCount == 0,
            "A failed closed cleanup must still skip every non-cleanup probe"
        )
        let stopStarted = ProcessInfo.processInfo.systemUptime
        try expect(
            agent.stopAndWaitUntilIdle(timeout: 0.5)
                && checkElapsed < 1
                && ProcessInfo.processInfo.systemUptime
                    - stopStarted < 0.5,
            "Failed closed cleanup must meet completion and stop latency bounds"
        )
    }

    do {
        let mapping = makeMapping()
        let seeded = try seed(
            name: "disabled-active-delete-cancel",
            mapping: mapping
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let router = MockRouterMappingService()
        router.failAllRemovals = true
        router.beforeRemoval = {
            entered.signal()
            release.wait()
        }
        router.cancellationHandler = {
            release.signal()
        }
        let localNetwork = MockLocalNetworkService()
        let publicIP = MockPublicIPService()
        let agent = NetworkAgent(
            configStore: seeded.store,
            keychain: inMemoryKeychain(),
            checkCompletionObserver: { completed.signal() },
            localNetworkService: localNetwork,
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: seeded.emergency,
            fallbackMappingJournal: seeded.fallback,
            nowProvider: wallClock.now,
            monotonicUptimeProvider: uptime.now,
            bootIdentifierProvider: { currentBoot },
            performInitialCheckOnStart: false
        )
        defer {
            stopAgentForCleanup(agent)
            try? FileManager.default.removeItem(
                at: seeded.directory
            )
        }
        agent.runCheck()
        try expect(
            entered.wait(timeout: .now() + 1) == .success,
            "Cancellation fixture must enter recovery deletion"
        )
        let stopStarted = ProcessInfo.processInfo.systemUptime
        try expect(
            agent.stopAndWaitUntilIdle(timeout: 0.75),
            "Cancellation must promptly stop the recovery check"
        )
        let stopElapsed =
            ProcessInfo.processInfo.systemUptime - stopStarted
        try expect(
            completed.wait(timeout: .now()) == .success,
            "Cancelled recovery must signal explicit completion"
        )
        let identities = try persistedIdentifiers(seeded)
        try expect(
            identities.allSatisfy {
                $0 == [mapping.identifier]
            },
            "Cancellation must leave the identity in main config and every pre-staged journal"
        )
        try expect(
            stopElapsed < 0.75
                && localNetwork.callCount == 0
                && publicIP.ipv4CallCount == 0
                && publicIP.ipv6CallCount == 0
                && router.externalIPv4CallCount == 0,
            "Cancelled closed cleanup must stop quickly without later network work"
        )
    }

    do {
        let oldBoot = "boot-disabled-active-old"
        let mapping = makeMapping(
            transport: .natpmp,
            bootIdentifier: oldBoot,
            remainingLease: 2
        )
        let seeded = try seed(
            name: "disabled-active-cross-boot",
            mapping: mapping
        )
        let udpCalls = LockedCounter()
        let router = RouterMappingService(
            udpTransactionHandler: {
                _, _, _, _, _, _ in
                udpCalls.increment()
                throw SimulatedRouterFailure(
                    operation: "unexpected cross-boot UDP"
                )
            },
            nowProvider: wallClock.now,
            monotonicUptimeProvider: uptime.now,
            bootIdentifierProvider: { currentBoot }
        )
        let localNetwork = MockLocalNetworkService()
        let publicIP = MockPublicIPService()
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: seeded.store,
            keychain: inMemoryKeychain(),
            checkCompletionObserver: { completed.signal() },
            localNetworkService: localNetwork,
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: seeded.emergency,
            fallbackMappingJournal: seeded.fallback,
            nowProvider: wallClock.now,
            monotonicUptimeProvider: uptime.now,
            bootIdentifierProvider: { currentBoot },
            performInitialCheckOnStart: false
        )
        defer {
            stopAgentForCleanup(agent)
            try? FileManager.default.removeItem(
                at: seeded.directory
            )
        }

        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 1) == .success,
            "Cross-boot finite-lease wait must complete promptly"
        )
        let waitingIdentities =
            try persistedIdentifiers(seeded)
        try expect(
            waitingIdentities.allSatisfy {
                $0 == [mapping.identifier]
            }
                && agent.status.routerStatus.state == .failed
                && udpCalls.current == 0,
            "Cross-boot cleanup must retain identity and send no unsafe delete before lease expiry"
        )

        uptime.set(503)
        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 1) == .success,
            "Expired cross-boot recovery must complete promptly"
        )
        let expiredIdentities =
            try persistedIdentifiers(seeded)
        try expect(
            expiredIdentities.allSatisfy(\.isEmpty)
                && agent.status.routerStatus.state == .disabled
                && agent.config.activeRouterMappings.isEmpty
                && udpCalls.current == 0,
            "Finite lease expiry must safely clear every retained identity without UDP deletion"
        )
        let stopStarted = ProcessInfo.processInfo.systemUptime
        try expect(
            agent.stopAndWaitUntilIdle(timeout: 0.5)
                && ProcessInfo.processInfo.systemUptime
                    - stopStarted < 0.5
                && localNetwork.callCount == 0
                && publicIP.ipv4CallCount == 0
                && publicIP.ipv6CallCount == 0,
            "Cross-boot recovery must stop quickly and perform no non-cleanup probes"
        )
    }
}

func testRouterWANIPv4RequiresPublicRoutability() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "router-wan-public-selection")

    let router = MockRouterMappingService()
    let publicIP = MockPublicIPService()
    var config = AppConfig.default
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .automatic
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        publicIPServiceFactory: { _ in publicIP },
        emergencyMappingJournal: emergencyJournal(in: baseDirectory)
    )
    defer { stopAgentForCleanup(agent) }

    router.externalIPv4 = "8.8.4.4"
    let verifiedPublic = try agent.currentPublicIPv4(
        config: config,
        gatewayAddress: "192.0.2.1",
        revision: 0
    )
    try expect(
        verifiedPublic.routerWANAddress == "8.8.4.4"
            && verifiedPublic.routerWANVerified
            && !verifiedPublic.blocksDDNS,
        "Only a router-protocol-verified public WAN address may allow DDNS"
    )

    let nonPublicAddresses = [
        ("10.0.0.1", "RFC1918"),
        ("100.64.1.20", "CGNAT"),
        ("169.254.1.2", "link-local"),
        ("192.0.2.1", "documentation"),
        ("198.18.0.1", "benchmark"),
        ("224.0.0.1", "multicast"),
        ("240.0.0.1", "reserved"),
        ("127.0.0.1", "loopback"),
        ("0.0.0.0", "unspecified")
    ]
    for (address, category) in nonPublicAddresses {
        router.externalIPv4 = address
        let discovery = try agent.currentPublicIPv4(
            config: config,
            gatewayAddress: "192.0.2.1",
            revision: 0
        )
        try expect(
            discovery.publicAddress == publicIP.ipv4,
            "\(category) address \(address) must fall back to the independent public-IP probe"
        )
        try expect(
            discovery.routerWANAddress == address,
            "\(category) address \(address) must remain available for diagnostics"
        )
        try expect(
            discovery.routerWANVerified
                && discovery.blocksDDNS,
            "\(category) address \(address) must block A-record updates"
        )
    }
    try stopAgent(agent)
    let natOnlyDirectory = try makeTemporaryDirectory(
        named: "router-wan-natpmp-only"
    )
    var natPMPTimeouts: [TimeInterval] = []
    var upnpDiscoveryCalls = 0
    let realRouter = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpDiscoveryCalls += 1
            return []
        },
        udpRequestHandler: { request, _, _, timeout in
            try expect(
                request == Data([0, 0]),
                "NetworkAgent Auto WAN must use the harmless NAT-PMP External Address request"
            )
            natPMPTimeouts.append(timeout)
            return Data([
                0, 128, 0, 0,
                0, 0, 0, 1,
                100, 64, 1, 20
            ])
        }
    )
    var automaticConfig = config
    automaticConfig.mappingProtocolPreference = .automatic
    let natOnlyPublicIP = MockPublicIPService()
    let natOnlyAgent = NetworkAgent(
        configStore: AppConfigStore(
            baseDirectory: natOnlyDirectory
        ),
        keychain: inMemoryKeychain(),
        initialConfig: automaticConfig,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: realRouter,
        publicIPServiceFactory: { _ in natOnlyPublicIP },
        emergencyMappingJournal: emergencyJournal(
            in: natOnlyDirectory
        )
    )
    defer { stopAgentForCleanup(natOnlyAgent) }
    let natOnlyDiscovery = try natOnlyAgent.currentPublicIPv4(
        config: automaticConfig,
        gatewayAddress: "192.0.2.1",
        revision: 0
    )
    try expect(
        natOnlyDiscovery.routerWANAddress == "100.64.1.20"
            && natOnlyDiscovery.publicAddress == natOnlyPublicIP.ipv4
            && natOnlyDiscovery.routerWANVerified
            && natOnlyDiscovery.blocksDDNS,
        "The real Auto path must retain NAT-PMP-only CGNAT evidence and block DDNS"
    )
    try expect(
        natPMPTimeouts == [0.25]
            && upnpDiscoveryCalls == 0,
        "NAT-PMP-only Auto WAN must finish in the first short probe without UPnP"
    )
    try stopAgent(natOnlyAgent)
    let unavailableDirectory = try makeTemporaryDirectory(
        named: "router-wan-auto-unverified"
    )
    var unavailableTimeouts: [TimeInterval] = []
    var unavailableUPnPCalls = 0
    let unavailableRouter = RouterMappingService(
        upnpDiscoveryHandler: {
            unavailableUPnPCalls += 1
            return []
        },
        udpRequestHandler: { _, _, _, timeout in
            unavailableTimeouts.append(timeout)
            throw RouterMappingError.timeout(
                "Injected short Auto WAN timeout"
            )
        }
    )
    let unavailableAgent = NetworkAgent(
        configStore: AppConfigStore(
            baseDirectory: unavailableDirectory
        ),
        keychain: inMemoryKeychain(),
        initialConfig: automaticConfig,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: unavailableRouter,
        publicIPServiceFactory: { _ in MockPublicIPService() },
        emergencyMappingJournal: emergencyJournal(
            in: unavailableDirectory
        )
    )
    defer { stopAgentForCleanup(unavailableAgent) }
    let unavailableDiscovery = try unavailableAgent.currentPublicIPv4(
        config: automaticConfig,
        gatewayAddress: "192.0.2.1",
        revision: 0
    )
    try expect(
        unavailableDiscovery.routerWANAddress == nil
            && !unavailableDiscovery.routerWANVerified
            && unavailableDiscovery.blocksDDNS,
        "Auto mode must fail closed when neither short NAT-PMP nor UPnP can verify router WAN state"
    )
    try expect(
        unavailableTimeouts == [0.25, 0.5, 1]
            && unavailableUPnPCalls == 1,
        "Unavailable Auto WAN must use only the 1.75-second NAT-PMP budget before one UPnP fallback"
    )
    let missingGatewayDiscovery = try unavailableAgent
        .currentPublicIPv4(
            config: automaticConfig,
            gatewayAddress: nil,
            revision: 0
        )
    try expect(
        missingGatewayDiscovery.publicAddress == "8.8.4.4"
            && missingGatewayDiscovery.routerWANAddress == nil
            && !missingGatewayDiscovery.routerWANVerified
            && missingGatewayDiscovery.blocksDDNS,
        "Auto mode must fail closed when default-route parsing or a network transition yields no gateway"
    )
    try stopAgent(unavailableAgent)
    try? FileManager.default.removeItem(
        at: unavailableDirectory
    )
    try? FileManager.default.removeItem(at: natOnlyDirectory)
    try? FileManager.default.removeItem(at: baseDirectory)
}

func testAutomaticPCPMappingSuppliesVerifiedRouterWAN() throws {
    struct CheckResult {
        let events: [String]
        let config: AppConfig
        let status: AppStatus
        let ensureCalls: [RouterMappingAddressFamily]
        let externalIPv4Calls: Int
        let publicIPv4Calls: Int
    }

    func automaticConfig() -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "invalid-zone-id"
        config.dnsRecordName = "mac.example.test"
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = .automatic
        return config
    }

    func runFresh(
        name: String,
        routerAddress: String,
        ensureError: Error? = nil,
        routerWANQueryError: Error? = nil
    ) throws -> CheckResult {
        let baseDirectory = try makeTemporaryDirectory(named: name)
        let router = MockRouterMappingService()
        router.externalIPv4 = routerAddress
        router.externalIPv4Failure = routerWANQueryError
        router.setEnsureError(ensureError)
        let publicIP = MockPublicIPService()
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        let eventLock = NSLock()
        var events: [String] = []
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: baseDirectory),
            keychain: keychain,
            initialConfig: automaticConfig(),
            checkCompletionObserver: {
                completed.signal()
            },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: emergencyJournal(
                in: baseDirectory
            )
        )
        defer {
            stopAgentForCleanup(agent)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 3) == .success,
            "\(name) must complete through an explicit observer"
        )
        eventLock.lock()
        let observedEvents = events
        eventLock.unlock()
        let result = CheckResult(
            events: observedEvents,
            config: agent.config,
            status: agent.status,
            ensureCalls: router.ensureCalls,
            externalIPv4Calls: router.externalIPv4CallCount,
            publicIPv4Calls: publicIP.ipv4CallCount
        )
        try stopAgent(agent)
        return result
    }

    let publicResult = try runFresh(
        name: "auto-pcp-public-wan",
        routerAddress: "8.8.4.4"
    )
    guard let mapIndex = publicResult.events.firstIndex(
        of: "router.mapping.create"
    ),
    let ddnsIndex = publicResult.events.firstIndex(
        of: "cloudflare.upsert-a"
    ) else {
        throw IntegrationContractFailure(
            "A public PCP MAP must reach both mapping and DDNS side effects"
        )
    }
    try expect(
        mapIndex < ddnsIndex,
        "Cloudflare A-record work must start only after PCP MAP verification"
    )
    try expect(
        publicResult.ensureCalls == [.ipv4]
            && publicResult.externalIPv4Calls == 0,
        "PCP MAP must run once and its response must avoid a second WAN query or MAP"
    )
    try expect(
        publicResult.status.publicAddress == "8.8.4.4"
            && publicResult.publicIPv4Calls == 0,
        "A public PCP MAP address must be the verified DDNS input without an independent public-IP probe"
    )
    try expect(
        publicResult.config.activeRouterMappings.count == 1
            && publicResult.config.activeRouterMappings[0]
                .routerExternalAddress == "8.8.4.4",
        "The verified PCP router WAN address must be persisted with the lease"
    )

    for address in ["100.64.1.20", "10.0.0.20", "192.0.2.20"] {
        let result = try runFresh(
            name: "auto-pcp-non-public-\(address)",
            routerAddress: address
        )
        try expect(
            result.ensureCalls == [.ipv4]
                && result.externalIPv4Calls == 0,
            "A non-public PCP response must still use exactly one verified MAP"
        )
        try expect(
            !result.events.contains("cloudflare.upsert-a")
                && result.publicIPv4Calls == 1,
            "CGNAT, RFC1918, and other non-global PCP addresses must block A-record writes"
        )
        try expect(
            result.status.publicAddress == "8.8.4.4",
            "The independent public address remains diagnostic when PCP reports \(address)"
        )
    }

    let failed = try runFresh(
        name: "auto-pcp-map-failed",
        routerAddress: "8.8.4.4",
        ensureError: RouterMappingError.timeout(
            "Injected PCP MAP timeout"
        ),
        routerWANQueryError: RouterMappingError.timeout(
            "Injected PCP-only WAN query timeout"
        )
    )
    try expect(
        failed.ensureCalls == [.ipv4]
            && failed.externalIPv4Calls == 0
            && !failed.events.contains("cloudflare.upsert-a"),
        "A failed PCP MAP must fail closed without accepting a separate WAN query"
    )

    func persistedPCPConfig(
        externalAddress: String
    ) -> AppConfig {
        let now = Date()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let bootIdentifier = RouterMappingService.systemBootIdentifier
        var mapping = activeMappingFixture(
            transport: .pcp,
            family: .ipv4,
            renewAfter: now.addingTimeInterval(1_800),
            leaseExpiresAt: now.addingTimeInterval(3_600)
        )
        mapping.routerExternalAddress = externalAddress
        mapping.routerEpoch = 500
        mapping.routerEpochObservedAt = now
        mapping.routerEpochObservedUptime = nowUptime
        mapping.routerEpochBootIdentifier = bootIdentifier
        mapping.routerEpochHealthCheckAfter =
            now.addingTimeInterval(60)
        mapping.routerEpochHealthCheckUptime = nowUptime + 60
        mapping.leaseExpiresUptime = nowUptime + 3_600
        mapping.renewAfterUptime = nowUptime + 1_800
        mapping.leaseBootIdentifier = bootIdentifier
        mapping.leaseAnchorWallTime = now
        mapping.leaseRemainingAtAnchor = 3_600
        mapping.renewRemainingAtAnchor = 1_800
        var config = automaticConfig()
        config.externalPort = mapping.externalPort
        config.pcpNonce = mapping.pcpNonce
        config.activeRouterMappings = [mapping]
        return config
    }

    let restoreDirectory = try makeTemporaryDirectory(
        named: "auto-pcp-persisted-wan"
    )
    defer {
        try? FileManager.default.removeItem(at: restoreDirectory)
    }
    let restoreStore = AppConfigStore(
        baseDirectory: restoreDirectory
    )
    try restoreStore.save(
        persistedPCPConfig(externalAddress: "8.8.4.4")
    )
    let restoreKeychain = inMemoryKeychain()
    try restoreKeychain.set(
        "integration-token",
        account: "cloudflare-api-token"
    )
    let restoreRouter = MockRouterMappingService()
    restoreRouter.externalIPv4Failure = RouterMappingError.timeout(
        "Persisted PCP evidence must avoid WAN rediscovery"
    )
    let restoreEventsLock = NSLock()
    var restoreEvents: [String] = []
    let restoreCompleted = DispatchSemaphore(value: 0)
    let restoredAgent = NetworkAgent(
        configStore: restoreStore,
        keychain: restoreKeychain,
        checkCompletionObserver: {
            restoreCompleted.signal()
        },
        sideEffectWillStartObserver: { label in
            restoreEventsLock.lock()
            restoreEvents.append(label)
            restoreEventsLock.unlock()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: restoreRouter,
        publicIPServiceFactory: { _ in MockPublicIPService() },
        emergencyMappingJournal: emergencyJournal(
            in: restoreDirectory
        )
    )
    defer { stopAgentForCleanup(restoredAgent) }
    restoredAgent.runCheck()
    try expect(
        restoreCompleted.wait(timeout: .now() + 3) == .success,
        "The persisted PCP lease check must complete"
    )
    restoreEventsLock.lock()
    let observedRestoreEvents = restoreEvents
    restoreEventsLock.unlock()
    guard let epochIndex = observedRestoreEvents.firstIndex(
        of: "router.mapping.epoch-health"
    ),
    let restoredDDNSIndex = observedRestoreEvents.firstIndex(
        of: "cloudflare.upsert-a"
    ) else {
        throw IntegrationContractFailure(
            "A restored PCP lease must be Epoch-verified before DDNS"
        )
    }
    try expect(
        restoreRouter.ensureCalls.isEmpty
            && restoreRouter.externalIPv4CallCount == 0
            && epochIndex < restoredDDNSIndex,
        "A same-boot, unexpired, Epoch-verified PCP lease may reuse its persisted WAN address without renewal or rediscovery"
    )
    try stopAgent(restoredAgent)

    let orphanDirectory = try makeTemporaryDirectory(
        named: "auto-pcp-orphan-wan"
    )
    defer {
        try? FileManager.default.removeItem(at: orphanDirectory)
    }
    let orphanStore = AppConfigStore(
        baseDirectory: orphanDirectory
    )
    let orphanConfig = persistedPCPConfig(
        externalAddress: "8.8.4.4"
    )
    try orphanStore.save(orphanConfig)
    let oldMapping = orphanConfig.activeRouterMappings[0]
    let orphanRouter = MockRouterMappingService()
    orphanRouter.setEpochAddressChange(
        oldMapping,
        replacementAddress: "192.0.2.21"
    )
    orphanRouter.setRemovalFailures([oldMapping])
    orphanRouter.externalIPv4Failure = RouterMappingError.timeout(
        "Orphaned PCP evidence must not be reused"
    )
    let orphanKeychain = inMemoryKeychain()
    try orphanKeychain.set(
        "integration-token",
        account: "cloudflare-api-token"
    )
    let orphanEventsLock = NSLock()
    var orphanEvents: [String] = []
    let orphanCompleted = DispatchSemaphore(value: 0)
    let orphanAgent = NetworkAgent(
        configStore: orphanStore,
        keychain: orphanKeychain,
        checkCompletionObserver: {
            orphanCompleted.signal()
        },
        sideEffectWillStartObserver: { label in
            orphanEventsLock.lock()
            orphanEvents.append(label)
            orphanEventsLock.unlock()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: orphanRouter,
        publicIPServiceFactory: { _ in MockPublicIPService() },
        emergencyMappingJournal: emergencyJournal(
            in: orphanDirectory
        )
    )
    defer { stopAgentForCleanup(orphanAgent) }
    orphanAgent.runCheck()
    try expect(
        orphanCompleted.wait(timeout: .now() + 3) == .success,
        "The PCP address-change recovery check must complete"
    )
    orphanEventsLock.lock()
    let observedOrphanEvents = orphanEvents
    orphanEventsLock.unlock()
    try expect(
        orphanRouter.ensureCalls.isEmpty
            && !observedOrphanEvents.contains("cloudflare.upsert-a"),
        "An effective-address orphan must block both replacement MAP and DDNS until cleanup or monotonic expiry"
    )
    try expect(
        orphanAgent.config.activeRouterMappings.first?
            .recoveryState == .effectiveClientAddressChanged,
        "The old PCP identity and lease deadline must remain persisted for recovery"
    )
    try stopAgent(orphanAgent)
}

func testCurrentCheckMappingProofFamilyMatrix() throws {
    struct InjectedRecoveryCheckpointFailure: Error {}

    struct MatrixResult {
        let events: [String]
        let ensureCalls: [RouterMappingAddressFamily]
        let mappings: [ActiveRouterMapping]
        let removalCalls: [ActiveRouterMapping]
        let externalIPv4Calls: Int
    }

    func run(
        name: String,
        preference: MappingProtocolPreference,
        failedFamilies: Set<RouterMappingAddressFamily> = [],
        initialMappings: [ActiveRouterMapping] = [],
        verificationFailures: [ActiveRouterMapping] = [],
        failRecoveryCheckpoint: Bool = false
    ) throws -> MatrixResult {
        let directory = try makeTemporaryDirectory(named: name)
        let configURL = directory.appendingPathComponent("config.json")
        let store = AppConfigStore(
            configURL: configURL,
            recoveryDataWriter: { data, url in
                if failRecoveryCheckpoint {
                    throw InjectedRecoveryCheckpointFailure()
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let router = MockRouterMappingService()
        router.externalIPv4 = "8.8.4.4"
        router.setEnsureFailures(failedFamilies)
        router.setVerificationFailures(verificationFailures)
        let local = MockLocalNetworkService()
        local.ipv6Address = "2606:4700:4700::1111"
        let publicIP = MockPublicIPService()
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "matrix-zone"
        config.dnsRecordName = "matrix.example.test"
        config.preferredAddressFamily = .dualStack
        config.mappingProtocolPreference = preference
        config.activeRouterMappings = initialMappings
        if let ipv4 = initialMappings.first(where: {
            $0.addressFamily == .ipv4
        }) {
            config.externalPort = ipv4.externalPort
            config.pcpNonce = ipv4.pcpNonce
        }

        let eventLock = NSLock()
        var events: [String] = []
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: store,
            keychain: keychain,
            initialConfig: config,
            checkCompletionObserver: { completed.signal() },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: local,
            routerMappingService: router,
            publicIPServiceFactory: { _ in publicIP },
            emergencyMappingJournal: emergencyJournal(in: directory)
        )
        agent.runCheck()
        try expect(
            completed.wait(timeout: .now() + 3) == .success,
            "\(name) must complete through its explicit observer"
        )
        eventLock.lock()
        let observedEvents = events
        eventLock.unlock()
        let result = MatrixResult(
            events: observedEvents,
            ensureCalls: router.ensureCalls,
            mappings: agent.config.activeRouterMappings,
            removalCalls: router.removalCalls,
            externalIPv4Calls: router.externalIPv4CallCount
        )
        try stopAgent(agent)
        try? FileManager.default.removeItem(at: directory)
        return result
    }

    func expectDNSFamilies(
        _ result: MatrixResult,
        a: Bool,
        aaaa: Bool,
        context: String
    ) throws {
        try expect(
            result.events.contains("cloudflare.upsert-a") == a,
            "\(context) A-record proof result was incorrect"
        )
        try expect(
            result.events.contains("cloudflare.upsert-aaaa") == aaaa,
            "\(context) AAAA-record proof result was incorrect"
        )
    }

    for preference in [
        MappingProtocolPreference.automatic,
        .pcp,
        .upnp
    ] {
        let both = try run(
            name: "proof-matrix-\(preference.rawValue)-both",
            preference: preference
        )
        try expectDNSFamilies(
            both,
            a: true,
            aaaa: true,
            context: "\(preference.rawValue) verified dual stack"
        )
        try expect(
            Set(both.mappings.map(\.addressFamily))
                == Set([.ipv4, .ipv6]),
            "\(preference.rawValue) must checkpoint one mapping identity per family"
        )

        let noIPv4 = try run(
            name: "proof-matrix-\(preference.rawValue)-no-v4",
            preference: preference,
            failedFamilies: [.ipv4]
        )
        try expectDNSFamilies(
            noIPv4,
            a: false,
            aaaa: true,
            context: "\(preference.rawValue) IPv4 failure isolation"
        )

        let noIPv6 = try run(
            name: "proof-matrix-\(preference.rawValue)-no-v6",
            preference: preference,
            failedFamilies: [.ipv6]
        )
        try expectDNSFamilies(
            noIPv6,
            a: true,
            aaaa: false,
            context: "\(preference.rawValue) IPv6 failure isolation"
        )
    }

    let proofNow = Date()
    let proofUptime = ProcessInfo.processInfo.systemUptime
    let proofBoot = RouterMappingService.systemBootIdentifier
    var failedPCP = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: proofNow.addingTimeInterval(1_800),
        leaseExpiresAt: proofNow.addingTimeInterval(3_600)
    )
    failedPCP.routerExternalAddress = "8.8.4.4"
    failedPCP.routerEpoch = 500
    failedPCP.routerEpochObservedAt = proofNow
    failedPCP.routerEpochObservedUptime = proofUptime
    failedPCP.routerEpochBootIdentifier = proofBoot
    failedPCP.routerEpochHealthCheckAfter =
        proofNow.addingTimeInterval(60)
    failedPCP.routerEpochHealthCheckUptime = proofUptime + 60
    failedPCP.leaseExpiresUptime = proofUptime + 3_600
    failedPCP.renewAfterUptime = proofUptime + 1_800
    failedPCP.leaseBootIdentifier = proofBoot
    failedPCP.leaseAnchorWallTime = proofNow
    failedPCP.leaseRemainingAtAnchor = 3_600
    failedPCP.renewRemainingAtAnchor = 1_800

    var validUPnPIPv6 = activeMappingFixture(
        transport: .upnp,
        family: .ipv6,
        localAddress: "2606:4700:4700::1111",
        renewAfter: proofNow.addingTimeInterval(1_800),
        leaseExpiresAt: proofNow.addingTimeInterval(3_600)
    )
    validUPnPIPv6.routerExternalAddress =
        "2606:4700:4700::1111"
    validUPnPIPv6.pcpNonce = "mock-bound-upnp-identity"
    validUPnPIPv6.leaseExpiresUptime = proofUptime + 3_600
    validUPnPIPv6.renewAfterUptime = proofUptime + 1_800
    validUPnPIPv6.leaseBootIdentifier = proofBoot
    validUPnPIPv6.leaseAnchorWallTime = proofNow
    validUPnPIPv6.leaseRemainingAtAnchor = 3_600
    validUPnPIPv6.renewRemainingAtAnchor = 1_800

    let mixedRecovery = try run(
        name: "proof-matrix-pcp-epoch-failure",
        preference: .automatic,
        initialMappings: [failedPCP, validUPnPIPv6],
        verificationFailures: [failedPCP]
    )
    try expectDNSFamilies(
        mixedRecovery,
        a: false,
        aaaa: true,
        context: "failed PCP Epoch with independent UPnP IPv6 proof"
    )
    try expect(
        mixedRecovery.ensureCalls.isEmpty
            && mixedRecovery.externalIPv4Calls == 0,
        "A persisted PCP port or another protocol's WAN proof must not replace failed PCP Epoch verification"
    )

    let natPMP = try run(
        name: "proof-matrix-natpmp",
        preference: .natpmp
    )
    try expectDNSFamilies(
        natPMP,
        a: true,
        aaaa: false,
        context: "NAT-PMP IPv4-only mapping"
    )
    try expect(
        natPMP.mappings.count == 1
            && natPMP.mappings[0].transport == .natpmp
            && natPMP.mappings[0].addressFamily == .ipv4,
        "Explicit NAT-PMP must not manufacture an IPv6 mapping proof"
    )

    let pureDDNS = try run(
        name: "proof-matrix-ddns-only",
        preference: .disabled
    )
    try expectDNSFamilies(
        pureDDNS,
        a: true,
        aaaa: true,
        context: "mapping-off pure DDNS exception"
    )
    try expect(
        pureDDNS.ensureCalls.isEmpty,
        "Pure DDNS must not create a router mapping"
    )

    let failedCheckpoint = try run(
        name: "proof-matrix-checkpoint-failure",
        preference: .automatic,
        failRecoveryCheckpoint: true
    )
    try expectDNSFamilies(
        failedCheckpoint,
        a: false,
        aaaa: false,
        context: "uncheckpointed mapping"
    )
    try expect(
        Set(failedCheckpoint.removalCalls.map(\.addressFamily))
            == Set([.ipv4, .ipv6]),
        "A failed proof checkpoint must compensate both newly created mappings"
    )
}

func testDDNSWaitsForDurableUnexpiredMappingProof() throws {
    struct InjectedMainConfigFailure: Error {}

    func cloudflareConfig(
        family: AddressFamilyPreference
    ) -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .cloudflare
        config.cloudflareZoneID = "durability-zone"
        config.dnsRecordName = "durability.example.test"
        config.preferredAddressFamily = family
        config.mappingProtocolPreference = .automatic
        return config
    }

    do {
        let directory = try makeTemporaryDirectory(
            named: "ddns-after-durable-router-state"
        )
        let eventLock = NSLock()
        var events: [String] = []
        func record(_ event: String) {
            eventLock.lock()
            events.append(event)
            eventLock.unlock()
        }
        let configURL = directory.appendingPathComponent(
            "config.json"
        )
        let store = AppConfigStore(
            configURL: configURL,
            dataWriter: { data, url in
                record("commit.main-config")
                try SecureAtomicFileWriter.write(data, to: url)
            },
            recoveryDataWriter: { data, url in
                record("commit.primary-recovery")
                try SecureAtomicFileWriter.write(data, to: url)
            }
        )
        let emergency = EmergencyMappingJournal(
            fileURL: directory.appendingPathComponent(
                "emergency.json"
            ),
            dataWriter: { data, url in
                record("commit.emergency-recovery")
                try SecureAtomicFileWriter.write(data, to: url)
            }
        )
        let fallback = EmergencyMappingJournal(
            fileURL: directory.appendingPathComponent(
                "fallback.json"
            ),
            dataWriter: { data, url in
                record("commit.fallback-recovery")
                try SecureAtomicFileWriter.write(data, to: url)
            }
        )
        let router = MockRouterMappingService()
        router.externalIPv4 = "8.8.4.4"
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: store,
            keychain: keychain,
            initialConfig: cloudflareConfig(family: .ipv4),
            checkCompletionObserver: {
                completed.signal()
            },
            sideEffectWillStartObserver: { record($0) },
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router,
            publicIPServiceFactory: { _ in MockPublicIPService() },
            emergencyMappingJournal: emergency,
            fallbackMappingJournal: fallback
        )
        agent.runCheck()
        try expect(
            completed.wait(
                timeout: .now() + .seconds(3)
            ) == .success,
            "The durable-order check must explicitly complete"
        )
        eventLock.lock()
        let observed = events
        eventLock.unlock()
        guard let cloudflareIndex = observed.firstIndex(
            of: "cloudflare.upsert-a"
        ),
        let mainIndex = observed.firstIndex(
            of: "commit.main-config"
        ),
        let primaryIndex = observed.lastIndex(
            of: "commit.primary-recovery"
        ) else {
            throw IntegrationContractFailure(
                "The durable-order fixture did not observe every commit boundary: "
                    + "\(observed)"
            )
        }
        try expect(
            primaryIndex < mainIndex
                && mainIndex < cloudflareIndex,
            "The recovery ownership checkpoint and main config must "
                + "commit before Cloudflare: \(observed)"
        )
        try expect(
            agent.config.activeRouterMappings.count == 1
                && (try? store.loadMappingRecoveryJournal().isEmpty)
                    == true
                && (try? emergency.load().isEmpty) == true
                && (try? fallback.load().isEmpty) == true,
            "A Cloudflare attempt requires a durable main mapping and "
                + "cleared ownership journals"
        )
        try stopAgent(agent)
        try? FileManager.default.removeItem(at: directory)
    }

    do {
        let directory = try makeTemporaryDirectory(
            named: "ddns-main-config-commit-failure"
        )
        let configURL = directory.appendingPathComponent(
            "config.json"
        )
        let store = AppConfigStore(
            configURL: configURL,
            dataWriter: { _, _ in
                throw InjectedMainConfigFailure()
            }
        )
        let emergency = EmergencyMappingJournal(
            fileURL: directory.appendingPathComponent(
                "emergency.json"
            )
        )
        let fallback = EmergencyMappingJournal(
            fileURL: directory.appendingPathComponent(
                "fallback.json"
            )
        )
        let router = MockRouterMappingService()
        router.externalIPv4 = "8.8.4.4"
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        let eventLock = NSLock()
        var events: [String] = []
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: store,
            keychain: keychain,
            initialConfig: cloudflareConfig(family: .ipv4),
            checkCompletionObserver: {
                completed.signal()
            },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router,
            publicIPServiceFactory: { _ in MockPublicIPService() },
            emergencyMappingJournal: emergency,
            fallbackMappingJournal: fallback
        )
        agent.runCheck()
        try expect(
            completed.wait(
                timeout: .now() + .seconds(3)
            ) == .success,
            "The failed-main-config check must explicitly complete"
        )
        eventLock.lock()
        let observed = events
        eventLock.unlock()
        try expect(
            !observed.contains("cloudflare.upsert-a")
                && !observed.contains("cloudflare.upsert-aaaa"),
            "A failed durable commit must send no Cloudflare request"
        )
        try expect(
            router.ensureCalls == [.ipv4]
                && router.removalCalls.count == 1
                && agent.config.activeRouterMappings.isEmpty
                && (try? store.loadMappingRecoveryJournal().isEmpty)
                    == true
                && (try? emergency.load().isEmpty) == true
                && (try? fallback.load().isEmpty) == true,
            "Commit failure must compensate the mapping and leave no "
                + "dangling ownership state"
        )
        try expect(
            agent.status.ddnsStatus.message.contains("not committed"),
            "Commit failure must record why DDNS was skipped"
        )
        try stopAgent(agent)
        try? FileManager.default.removeItem(at: directory)
    }

    do {
        let directory = try makeTemporaryDirectory(
            named: "ddns-proof-expires-during-ipv6"
        )
        let wallClock = LockedClock(
            Date(timeIntervalSince1970: 2_200_000_000)
        )
        let uptime = LockedMonotonicClock(100)
        let router = MockRouterMappingService()
        router.externalIPv4 = "8.8.4.4"
        router.nowProvider = { wallClock.now() }
        router.monotonicUptimeProvider = { uptime.now() }
        router.bootIdentifierProvider = { "short-proof-boot" }
        router.beforeEnsureFamily = { family in
            if family == .ipv6 {
                uptime.set(100.8)
                wallClock.set(
                    Date(timeIntervalSince1970: 2_200_000_000.8)
                )
            }
        }
        let local = MockLocalNetworkService()
        local.ipv6Address = "2606:4700:4700::1111"
        var config = cloudflareConfig(family: .dualStack)
        config.mappingLeaseSeconds = 1
        let keychain = inMemoryKeychain()
        try keychain.set(
            "integration-token",
            account: "cloudflare-api-token"
        )
        let eventLock = NSLock()
        var events: [String] = []
        let completed = DispatchSemaphore(value: 0)
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: directory),
            keychain: keychain,
            initialConfig: config,
            checkCompletionObserver: {
                completed.signal()
            },
            sideEffectWillStartObserver: { label in
                eventLock.lock()
                events.append(label)
                eventLock.unlock()
            },
            localNetworkService: local,
            routerMappingService: router,
            publicIPServiceFactory: { _ in MockPublicIPService() },
            emergencyMappingJournal: emergencyJournal(in: directory),
            nowProvider: { wallClock.now() },
            monotonicUptimeProvider: { uptime.now() },
            bootIdentifierProvider: { "short-proof-boot" }
        )
        agent.runCheck()
        try expect(
            completed.wait(
                timeout: .now() + .seconds(3)
            ) == .success,
            "The short-proof check must explicitly complete"
        )
        eventLock.lock()
        let firstEvents = events
        eventLock.unlock()
        try expect(
            !firstEvents.contains("cloudflare.upsert-a")
                && firstEvents.contains("cloudflare.upsert-aaaa"),
            "IPv4 proof crossing its monotonic safety deadline during "
                + "IPv6 work must block only A: \(firstEvents)"
        )
        try expect(
            agent.status.ddnsStatus.detail.contains(
                "monotonic lease safety deadline"
            ),
            "The family-specific status must record the expired proof"
        )

        router.beforeEnsureFamily = nil
        agent.runCheck()
        try expect(
            completed.wait(
                timeout: .now() + .seconds(3)
            ) == .success,
            "The proof-expiration recovery check must explicitly complete"
        )
        try expect(
            router.ensureCalls == [.ipv4, .ipv6, .ipv4],
            "The next check must renew the expired IPv4 proof without "
                + "unnecessarily renewing IPv6"
        )
        try stopAgent(agent)
        try? FileManager.default.removeItem(at: directory)
    }
}

func testPersistSettingsAsyncNeverBlocksTheMainThread() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "async-settings-save")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .pcp
    previous.activeRouterMappings = [mapping]

    let removalEntered = DispatchSemaphore(value: 0)
    let removalRelease = DispatchSemaphore(value: 0)
    let removalGateCalls = LockedCounter()
    let router = MockRouterMappingService()
    router.beforeRemoval = {
        if removalGateCalls.increment() == 1 {
            removalEntered.signal()
            removalRelease.wait()
        }
    }
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: previous,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    var requested = previous
    requested.remoteAccessEnabled = false
    var completionArrived = false
    var completionWasOnMain = false
    var completionError: Error?
    let startedAt = Date()
    agent.persistSettingsAsync(config: requested, tokenMutation: .keepExisting) { result in
        completionArrived = true
        completionWasOnMain = Thread.isMainThread
        if case .failure(let error) = result {
            completionError = error
        }
    }
    let returnLatency = Date().timeIntervalSince(startedAt)
    try expect(returnLatency < 0.05, "Settings persistence must return immediately to the main thread")
    try expect(
        removalEntered.wait(timeout: .now() + 2) == .success,
        "The background transaction must reach the injected router timeout"
    )
    try expect(!completionArrived, "Completion must wait for the background router transaction")
    removalRelease.signal()
    try expect(waitUntil { completionArrived }, "The asynchronous save completion must arrive")
    try expect(completionWasOnMain, "The asynchronous save result must return on the main thread")
    try expect(completionError == nil, "The injected asynchronous save must succeed after release")
    try expect(!agent.config.remoteAccessEnabled, "The successful asynchronous save must commit the requested state")
    try stopAgent(agent)
}

func testSupersededSavePreservesCompletedMappingCleanup() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "superseded-save-mapping-checkpoint")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .pcp
    previous.externalPort = mapping.externalPort
    previous.pcpNonce = mapping.pcpNonce
    previous.activeRouterMappings = [mapping]
    let store = AppConfigStore(baseDirectory: baseDirectory)
    try store.save(previous)

    let removalEntered = DispatchSemaphore(value: 0)
    let removalRelease = DispatchSemaphore(value: 0)
    let removalGateCalls = LockedCounter()
    let router = MockRouterMappingService()
    router.beforeRemoval = {
        if removalGateCalls.increment() == 1 {
            removalEntered.signal()
            removalRelease.wait()
        }
    }
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: previous,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    var firstRequest = previous
    firstRequest.remoteAccessEnabled = false
    agent.saveConfig(firstRequest)
    try expect(
        removalEntered.wait(timeout: .now() + 2) == .success,
        "The first save must reach router cleanup"
    )

    var latestRequest = previous
    latestRequest.externalPort &+= 1
    agent.saveConfig(latestRequest)
    removalRelease.signal()
    try expect(
        waitUntil {
            agent.config.externalPort == latestRequest.externalPort
                && !agent.config.activeRouterMappings.contains {
                    $0.identifier == mapping.identifier
                }
        },
        "The latest save must not resurrect the mapping already removed by the superseded save"
    )
    let diskConfig = try store.load()
    try expect(
        !diskConfig.activeRouterMappings.contains { $0.identifier == mapping.identifier },
        "The durable checkpoint must not resurrect the exact mapping removed by a superseded save"
    )
    try stopAgent(agent)
}

func testLocalOriginTCPStatusSemantics() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "local-origin-status")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.preferredAddressFamily = .ipv4
    config.dnsRecordName = ""
    config.externalProbeHost = "target.example.test"

    var status = AppStatus.initial
    status.externalPort = 45900
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: KeychainStore(service: "io.github.naifuliang.gatebeam.local-origin-status"),
        initialConfig: config,
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }

    var resolvedHost = ""
    var resolvedFamily: Int32 = 0
    var connectedHost = ""
    var connectedPort: UInt16 = 0
    let result = agent.verifyLocalOriginTCPConnection(
        config: config,
        status: status,
        resolve: { host, family in
            resolvedHost = host
            resolvedFamily = family
            return "192.0.2.44"
        },
        connect: { host, port, _ in
            connectedHost = host
            connectedPort = port
            return true
        }
    )

    try expect(resolvedHost == "target.example.test", "The configured compatibility host must be used as the local TCP target")
    try expect(resolvedFamily == AF_INET, "IPv4 preference must request an IPv4 target")
    try expect(connectedHost == "192.0.2.44", "The locally resolved address must be passed to the TCP connector")
    try expect(connectedPort == 45900, "The mapped IPv4 port must be checked")
    try expect(result.state == .ok, "A successful local TCP connection may report the local check as OK")
    try expect(result.message == "Local-origin TCP connection succeeded", "Success must be labeled as a local-origin TCP result")
    try expect(result.detail.contains("from this Mac"), "Success detail must identify this Mac as the connection origin")
    try expect(result.detail.contains("does not verify internet reachability"), "Success must explicitly disclaim internet reachability")
    try expect(!result.message.lowercased().contains("external"), "The local check message must not claim external reachability")
    try expect(!result.message.lowercased().contains("public"), "The local check message must not claim public reachability")
}

func testStartAtLoginFailureIsVisibleAndRevertsConfig() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "start-at-login-result")
    defer {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    var previousConfig = AppConfig.default
    previousConfig.startAtLogin = false
    var requestedConfig = previousConfig
    requestedConfig.startAtLogin = true

    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: KeychainStore(service: "io.github.naifuliang.gatebeam.start-at-login-result"),
        initialConfig: previousConfig,
        sideEffectsEnabled: false
    )
    defer { stopAgentForCleanup(agent) }

    let appliedConfig = agent.applyStartAtLoginResult(
        .failure(.unstableApplicationLocation),
        requestedConfig: requestedConfig,
        previousConfig: previousConfig
    )
    try expect(!appliedConfig.startAtLogin, "A failed login-item update must revert the requested config value")
    let errorMessage = agent.status.settingsErrorMessage ?? ""
    try expect(!errorMessage.isEmpty, "A failed login-item update must publish a visible settings error")
    try expect(errorMessage.contains("/Applications"), "The visible error must retain the stable installation path guidance")

    let recoveryConfig = agent.applyStartAtLoginResult(
        .failure(.unableToRestoreLoginItem),
        requestedConfig: requestedConfig,
        previousConfig: previousConfig
    )
    try expect(
        !recoveryConfig.startAtLogin,
        "A failed login-item rollback must preserve the previous config value"
    )
    let recoveryMessage = agent.status.settingsErrorMessage ?? ""
    try expect(
        recoveryMessage.contains("duplicate launches"),
        "A rollback failure must publish the duplicate-launch recovery guidance"
    )
    try expect(
        recoveryMessage.contains("off and on again"),
        "A rollback failure must publish an actionable retry path"
    )

    let successfulConfig = agent.applyStartAtLoginResult(
        .success(()),
        requestedConfig: requestedConfig,
        previousConfig: previousConfig
    )
    try expect(successfulConfig.startAtLogin, "A successful login-item update must retain the requested config value")
    try expect(agent.status.settingsErrorMessage == nil, "A successful retry must clear the visible settings error")
}

func testRemoteAccessDisableRetainsFailedMappingForRetry() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "mapping-disable-rollback")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let ipv4 = activeMappingFixture(transport: .pcp, family: .ipv4)
    let ipv6 = activeMappingFixture(transport: .upnp, family: .ipv6)
    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.externalPort = ipv4.externalPort
    previous.pcpNonce = ipv4.pcpNonce
    previous.ipv6PinholeID = ipv6.pinholeID
    previous.activeRouterMappings = [ipv4, ipv6]

    let store = AppConfigStore(baseDirectory: baseDirectory)
    try store.save(previous)
    let router = MockRouterMappingService()
    router.setRemovalFailures([ipv6])
    let local = MockLocalNetworkService()
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: previous,
        localNetworkService: local,
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil {
            router.removalCalls.count == 2
                && agent.status.settingsErrorMessage?.contains("retained the failed rules") == true
        },
        "A partial router deletion must return an actionable failure to the UI"
    )
    try expect(agent.config.remoteAccessEnabled, "A failed close must keep remote access enabled")
    try expect(
        agent.config.activeRouterMappings == [ipv6],
        "A partial close must retain only the failed mapping for retry"
    )
    let failedDiskState = try store.load()
    try expect(failedDiskState.remoteAccessEnabled, "A failed close must not persist the disabled state")
    try expect(
        failedDiskState.activeRouterMappings.map(\.identifier) == [ipv6.identifier],
        "The retry checkpoint must persist the exact failed protocol and address family"
    )

    router.setRemovalFailures([])
    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil { !agent.config.remoteAccessEnabled && agent.config.activeRouterMappings.isEmpty },
        "Retrying close after router recovery must disable access and clear tracked mappings"
    )
    let closedDiskState = try store.load()
    try expect(!closedDiskState.remoteAccessEnabled, "A fully successful close may persist the disabled state")
    try expect(closedDiskState.activeRouterMappings.isEmpty, "A fully successful close must clear retry state")
}

func testLegacyAutomaticCleanupPersistsEveryUnknownProtocol() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "legacy-automatic-cleanup")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .automatic
    previous.pcpNonce = Data(repeating: 27, count: 12).base64EncodedString()
    previous.activeRouterMappings = []

    let confirmed = ActiveRouterMapping(
        transport: .natpmp,
        addressFamily: .ipv4,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1",
        internalPort: previous.internalPort,
        externalPort: previous.externalPort,
        pinholeID: nil,
        pcpNonce: nil,
        leaseExpiresAt: .distantFuture,
        renewAfter: .distantFuture
    )
    let unknownPCP = ActiveRouterMapping(
        transport: .pcp,
        addressFamily: .ipv4,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1",
        internalPort: previous.internalPort,
        externalPort: previous.externalPort,
        pinholeID: nil,
        pcpNonce: previous.pcpNonce,
        leaseExpiresAt: .distantFuture,
        renewAfter: .distantFuture
    )
    let unknownUPnP = ActiveRouterMapping(
        transport: .upnp,
        addressFamily: .ipv4,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1",
        internalPort: previous.internalPort,
        externalPort: previous.externalPort,
        pinholeID: nil,
        pcpNonce: "gatebeam-upnp-v1:fixture",
        leaseExpiresAt: .distantFuture,
        renewAfter: .distantFuture
    )
    let unknownMappings = [unknownPCP, unknownUPnP]
    let store = AppConfigStore(baseDirectory: baseDirectory)
    try store.save(previous)
    let router = MockRouterMappingService()
    router.setLegacyRemovalReport(
        RouterMappingRemovalReport(
            attempts: [
                RouterMappingRemovalAttempt(
                    mapping: confirmed,
                    errorDescription: nil
                ),
                RouterMappingRemovalAttempt(
                    mapping: unknownPCP,
                    errorDescription: "PCP deletion response was uncertain"
                ),
                RouterMappingRemovalAttempt(
                    mapping: unknownUPnP,
                    errorDescription: "UPnP rule identity could not be confirmed"
                )
            ]
        )
    )
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: previous,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil {
            router.legacyRemovalCallCount == 1
                && agent.status.settingsErrorMessage?.contains("retained the failed rules") == true
        },
        "Uncertain legacy protocols must block the close transaction"
    )
    try expect(agent.config.remoteAccessEnabled, "Legacy uncertainty must keep remote access enabled")
    try expect(
        agent.config.activeRouterMappings == unknownMappings,
        "Every exact uncertain legacy protocol must be retained for retry"
    )
    let failedDiskState = try store.load()
    try expect(
        failedDiskState.activeRouterMappings == unknownMappings,
        "Every exact uncertain legacy protocol must be checkpointed on disk without collapsing state"
    )

    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil {
            !agent.config.remoteAccessEnabled
                && agent.config.activeRouterMappings.isEmpty
                && router.removalCalls == unknownMappings
        },
        "A retry must use every persisted exact protocol instead of rerunning Automatic discovery"
    )
    try expect(
        router.legacyRemovalCallCount == 1,
        "Once uncertain protocols are known, retries must not run the legacy Automatic batch again"
    )
}

func testMappingIdentityChangeMustDeleteOldRuleFirst() throws {
    let oldMapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .pcp
    previous.externalPort = oldMapping.externalPort
    previous.pcpNonce = oldMapping.pcpNonce
    previous.activeRouterMappings = [oldMapping]

    let changes: [(String, (inout AppConfig) -> Void)] = [
        ("external port", { $0.externalPort += 1 }),
        ("internal port", { $0.internalPort += 1 }),
        ("mapping protocol", { $0.mappingProtocolPreference = .upnp }),
        ("address family", { $0.preferredAddressFamily = .dualStack }),
        ("lease policy", { $0.mappingLeaseSeconds += 60 })
    ]

    for (name, applyChange) in changes {
        let baseDirectory = try makeTemporaryDirectory(named: "mapping-identity-\(name.replacingOccurrences(of: " ", with: "-"))")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = AppConfigStore(baseDirectory: baseDirectory)
        try store.save(previous)
        let router = MockRouterMappingService()
        router.setRemovalFailures([oldMapping])
        let agent = NetworkAgent(
            configStore: store,
            keychain: inMemoryKeychain(),
            initialConfig: previous,
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router
        )
        defer { stopAgentForCleanup(agent) }

        var requested = previous
        applyChange(&requested)
        do {
            _ = try agent.persistSettings(config: requested, tokenMutation: .keepExisting)
            throw IntegrationContractFailure("A failed old-rule deletion must block the new \(name)")
        } catch {
            try expect(
                error.localizedDescription.contains("Could not close every router mapping"),
                "The blocked \(name) change must explain how to retry cleanup"
            )
        }

        try expect(
            agent.config.activeRouterMappings == [oldMapping],
            "The failed \(name) change must retain the old mapping in the UI state"
        )
        try expect(
            agent.config.internalPort == previous.internalPort
                && agent.config.externalPort == previous.externalPort
                && agent.config.mappingProtocolPreference == previous.mappingProtocolPreference
                && agent.config.preferredAddressFamily == previous.preferredAddressFamily
                && agent.config.mappingLeaseSeconds == previous.mappingLeaseSeconds,
            "The failed \(name) change must not expose any requested mapping identity"
        )
        let diskConfig = try store.load()
        try expect(
            diskConfig.activeRouterMappings.map(\.identifier) == [oldMapping.identifier],
            "The failed \(name) change must retain the old mapping checkpoint on disk"
        )
        try expect(router.ensureCalls.isEmpty, "A new router rule must never be created before the old \(name) rule is removed")
    }
}

func testPostCleanupPersistenceFailureKeepsTruthfulMappingState() throws {
    struct InjectedConfigFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "mapping-post-cleanup-persistence")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .pcp
    previous.externalPort = mapping.externalPort
    previous.pcpNonce = mapping.pcpNonce
    previous.activeRouterMappings = [mapping]

    var writeCount = 0
    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    let store = AppConfigStore(
        configURL: configURL,
        dataWriter: { data, url in
            writeCount += 1
            if writeCount == 3 {
                throw InjectedConfigFailure()
            }
            try data.write(to: url, options: [.atomic])
        }
    )
    try store.save(previous)
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: previous,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    var requested = previous
    requested.externalPort += 1
    do {
        _ = try agent.persistSettings(config: requested, tokenMutation: .keepExisting)
        throw IntegrationContractFailure("The injected post-cleanup config failure must propagate")
    } catch is AppConfigStoreError {
        // Expected.
    }

    try expect(router.removalCalls == [mapping], "The old mapping must have been removed before the injected disk failure")
    try expect(agent.config.remoteAccessEnabled, "A post-cleanup disk failure must retain the previous enabled configuration")
    try expect(agent.config.externalPort == previous.externalPort, "A post-cleanup disk failure must not expose the requested port")
    try expect(agent.config.activeRouterMappings.isEmpty, "In-memory state must record that the old mapping was already removed")
    let diskConfig = try store.load()
    try expect(diskConfig.remoteAccessEnabled, "The persisted checkpoint must retain the previous enabled state")
    try expect(diskConfig.externalPort == previous.externalPort, "The persisted checkpoint must retain the previous port")
    try expect(diskConfig.activeRouterMappings.isEmpty, "The persisted checkpoint must not resurrect the deleted mapping")
}

func testTemporaryAccessExpiryDoesNotHideCleanupFailure() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "mapping-expiration")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.externalPort = mapping.externalPort
    config.pcpNonce = mapping.pcpNonce
    config.activeRouterMappings = [mapping]
    config.accessExpiresAt = Date().addingTimeInterval(-10)

    let store = AppConfigStore(baseDirectory: baseDirectory)
    try store.save(config)
    let router = MockRouterMappingService()
    router.setRemovalFailures([mapping])
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    agent.runCheck()
    try expect(
        waitUntil {
            agent.status.routerStatus.message == "Router cleanup needs attention"
        },
        "An expired temporary session must surface router deletion failure"
    )
    try expect(agent.config.remoteAccessEnabled, "Expiration must not claim access is off while a router rule remains")
    try expect(agent.config.activeRouterMappings == [mapping], "Expiration failure must preserve exact retry state")
    try expect(router.ensureCalls.isEmpty, "Expiration cleanup failure must not renew or recreate the mapping")

    router.setRemovalFailures([])
    agent.runCheck()
    try expect(
        waitUntil { !agent.config.remoteAccessEnabled && agent.config.activeRouterMappings.isEmpty },
        "A later expiration cleanup retry must close the mapping before disabling access"
    )
    try stopAgent(agent)
}

func testTemporaryAccessUsesIndependentExpirationTimer() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "independent-expiration")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let clock = LockedClock(Date(timeIntervalSince1970: 2_000_200_000))
    let expiresAt = clock.now().addingTimeInterval(30 * 60)
    let mapping = activeMappingFixture(
        transport: .upnp,
        family: .ipv4,
        renewAfter: clock.now().addingTimeInterval(15 * 60),
        leaseExpiresAt: expiresAt
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .upnp
    config.autoRenewMapping = false
    config.externalPort = mapping.externalPort
    config.activeRouterMappings = [mapping]
    config.accessExpiresAt = expiresAt
    config.checkIntervalSeconds = 86_400

    let scheduleLock = NSLock()
    var scheduledDeadlines: [Date] = []
    var scheduledHandlers: [() -> Void] = []
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        nowProvider: { clock.now() },
        expirationTimerScheduler: { deadline, handler in
            scheduleLock.lock()
            scheduledDeadlines.append(deadline)
            scheduledHandlers.append(handler)
            scheduleLock.unlock()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }

    agent.start()
    try expect(
        waitUntil { agent.status.lastCheckedAt != nil },
        "The initial check must complete before the independent expiration fires"
    )
    scheduleLock.lock()
    let initialDeadline = scheduledDeadlines.last
    let expirationHandler = scheduledHandlers.last
    scheduleLock.unlock()
    try expect(
        initialDeadline == expiresAt,
        "A 24-hour check interval must still arm the exact 30-minute access deadline"
    )
    guard let expirationHandler else {
        throw IntegrationContractFailure("The independent expiration handler was not scheduled")
    }

    clock.set(expiresAt)
    expirationHandler()
    try expect(
        waitUntil {
            !agent.config.remoteAccessEnabled
                && agent.config.accessExpiresAt == nil
                && agent.config.activeRouterMappings.isEmpty
        },
        "The independent timer must revoke the mapping and disable access at 30 minutes"
    )
    try expect(
        router.removalCalls == [mapping],
        "The expiration timer must remove the tracked router mapping exactly once"
    )
    try expect(
        agent.config.checkIntervalSeconds == 86_400,
        "Expiration must not depend on or rewrite the periodic check interval"
    )
    try stopAgent(agent)
}

func testMappingDeadlinesDriveUnifiedWakeAndPersistedRecovery() throws {
    let baseDirectory = try makeTemporaryDirectory(
        named: "mapping-deadline-wake"
    )
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let clock = LockedClock(Date(timeIntervalSince1970: 2_000_250_000))
    let initialNow = clock.now()
    var mapping = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: initialNow.addingTimeInterval(30),
        leaseExpiresAt: initialNow.addingTimeInterval(60)
    )
    mapping.routerEpoch = 100
    mapping.routerEpochObservedAt = initialNow
    mapping.routerEpochObservedUptime = 1_000
    mapping.routerEpochBootIdentifier = "integration-boot"
    mapping.routerEpochHealthCheckAfter =
        initialNow.addingTimeInterval(45)

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.externalPort = mapping.externalPort
    config.pcpNonce = mapping.pcpNonce
    config.mappingLeaseSeconds = 60
    config.checkIntervalSeconds = 300
    config.activeRouterMappings = [mapping]

    let scheduleLock = NSLock()
    var deadlines: [Date] = []
    var handlers: [() -> Void] = []
    let checks = LockedCounter()
    let checkCompleted = DispatchSemaphore(value: 0)
    let router = MockRouterMappingService()
    router.nowProvider = { clock.now() }
    router.monotonicUptimeProvider = {
        1_000 + clock.now().timeIntervalSince(initialNow)
    }
    router.bootIdentifierProvider = { "integration-boot" }
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkExecutionObserver: { checks.increment() },
        checkCompletionObserver: { checkCompleted.signal() },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        publicIPServiceFactory: { _ in MockPublicIPService() },
        nowProvider: { clock.now() },
        monotonicUptimeProvider: {
            1_000 + clock.now().timeIntervalSince(initialNow)
        },
        bootIdentifierProvider: { "integration-boot" },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, handler in
            scheduleLock.lock()
            deadlines.append(deadline)
            handlers.append(handler)
            scheduleLock.unlock()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }
    agent.start()

    scheduleLock.lock()
    let firstDeadline = deadlines.last
    let renewalHandler = handlers.last
    scheduleLock.unlock()
    try expect(
        firstDeadline == mapping.renewAfter,
        "A 60-second lease must wake at its 30-second renewAfter before the 300-second check"
    )
    guard let renewalHandler else {
        throw IntegrationContractFailure(
            "The mapping renewal deadline handler was not scheduled"
        )
    }

    clock.set(mapping.renewAfter)
    renewalHandler()
    try expect(
        checkCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "The renewAfter check must explicitly complete"
    )
    try expect(
        router.ensureCalls == [.ipv4]
            && checks.current == 1
            && agent.config.activeRouterMappings.first?.renewAfter
                == clock.now().addingTimeInterval(30),
        "The completed renewAfter wake must issue and persist exactly one renewal"
    )

    renewalHandler()
    try expect(
        checkCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success
            && checks.current >= 2,
        "A duplicate stale timer callback must complete as one coalesced check"
    )
    try expect(
        router.ensureCalls == [.ipv4],
        "A duplicate callback before the new renewAfter must not issue another renewal"
    )
    scheduleLock.lock()
    let deadlinesAfterRenewal = deadlines
    scheduleLock.unlock()
    try expect(
        deadlinesAfterRenewal.suffix(from: 1).allSatisfy {
            $0.timeIntervalSince(
                clock.now().addingTimeInterval(30)
            ) >= -0.1
        },
        "Renewal scheduling must not enter an immediate busy loop: "
            + "\(deadlinesAfterRenewal)"
    )
    try stopAgent(agent)
    let persistedDirectory = try makeTemporaryDirectory(
        named: "persisted-mapping-deadline"
    )
    defer {
        try? FileManager.default.removeItem(at: persistedDirectory)
    }
    let persistedStore = AppConfigStore(
        baseDirectory: persistedDirectory
    )
    try persistedStore.save(config)
    var persistedDeadlines: [Date] = []
    let persistedAgent = NetworkAgent(
        configStore: persistedStore,
        keychain: inMemoryKeychain(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { initialNow },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, _ in
            persistedDeadlines.append(deadline)
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(persistedAgent) }
    persistedAgent.start()
    try expect(
        persistedDeadlines.last.map {
            $0.timeIntervalSince(initialNow) <= 0.051
        } == true,
        "A legacy persisted mapping without boot identity must fail closed "
            + "into an immediate renewal wake"
    )
    try stopAgent(persistedAgent)
    var epochFirst = mapping
    epochFirst.renewAfter = initialNow.addingTimeInterval(90)
    epochFirst.routerEpochHealthCheckAfter =
        initialNow.addingTimeInterval(20)
    config.activeRouterMappings = [epochFirst]
    var epochDeadlines: [Date] = []
    let epochDirectory = try makeTemporaryDirectory(
        named: "epoch-deadline-wake"
    )
    defer { try? FileManager.default.removeItem(at: epochDirectory) }
    let epochAgent = NetworkAgent(
        configStore: AppConfigStore(
            baseDirectory: epochDirectory
        ),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { initialNow },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, _ in
            epochDeadlines.append(deadline)
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(epochAgent) }
    epochAgent.start()
    try expect(
        epochDeadlines.last == epochFirst.routerEpochHealthCheckAfter,
        "The earliest Epoch health deadline must precede renewAfter and checkInterval"
    )
    try stopAgent(epochAgent)
}

func testMonotonicLeaseDeadlinesIgnoreWallClockAndRestoreConservatively() throws {
    let directory = try makeTemporaryDirectory(
        named: "monotonic-lease-deadlines"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let baseline = Date(timeIntervalSince1970: 2_000_280_000)
    let wall = LockedClock(baseline)
    let uptime = LockedMonotonicClock(100)
    let bootA = "lease-boot-a"

    var mapping = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: baseline.addingTimeInterval(30),
        leaseExpiresAt: baseline.addingTimeInterval(60)
    )
    mapping.leaseBootIdentifier = bootA
    mapping.renewAfterUptime = 130
    mapping.leaseExpiresUptime = 160
    mapping.leaseAnchorWallTime = baseline
    mapping.renewRemainingAtAnchor = 30
    mapping.leaseRemainingAtAnchor = 60
    mapping.routerEpoch = 100
    mapping.routerEpochObservedAt = baseline
    mapping.routerEpochObservedUptime = 100
    mapping.routerEpochBootIdentifier = bootA
    mapping.routerEpochHealthCheckAfter =
        baseline.addingTimeInterval(45)
    mapping.routerEpochHealthCheckUptime = 145

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.externalPort = mapping.externalPort
    config.pcpNonce = mapping.pcpNonce
    config.activeRouterMappings = [mapping]

    var deadlines: [Date] = []
    let checkCompleted = DispatchSemaphore(value: 0)
    let router = MockRouterMappingService()
    router.nowProvider = { wall.now() }
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: directory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkCompletionObserver: { checkCompleted.signal() },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        publicIPServiceFactory: { _ in MockPublicIPService() },
        nowProvider: { wall.now() },
        monotonicUptimeProvider: { uptime.now() },
        bootIdentifierProvider: { bootA },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, _ in
            deadlines.append(deadline)
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }
    agent.start()
    try expect(
        deadlines.last == baseline.addingTimeInterval(30),
        "Same-boot renewal scheduling must project uptime 130 to 30 seconds"
    )

    wall.set(baseline.addingTimeInterval(3_600))
    uptime.set(120)
    agent.runCheck()
    try expect(
        checkCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "The NTP-forward check must explicitly complete"
    )
    try expect(
        router.ensureCalls.isEmpty,
        "An in-process NTP forward jump must not trigger early renewal"
    )

    wall.set(baseline.addingTimeInterval(-3_600))
    uptime.set(130)
    agent.runCheck()
    try expect(
        checkCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success
            && router.ensureCalls == [.ipv4],
        "The completed monotonic renewAfter check must trigger despite an NTP backward jump"
    )
    try stopAgent(agent)
    let store = AppConfigStore(baseDirectory: directory)
    try store.save(config)
    var rebootDeadlines: [Date] = []
    let rebootWall = baseline.addingTimeInterval(10)
    let rebooted = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { rebootWall },
        monotonicUptimeProvider: { 10 },
        bootIdentifierProvider: { "lease-boot-b" },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, _ in
            rebootDeadlines.append(deadline)
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(rebooted) }
    rebooted.start()
    try expect(
        rebootDeadlines.last.map {
            $0.timeIntervalSince(rebootWall) <= 0.051
        } == true,
        "Cross-boot recovery must fail closed into an immediate renewal"
    )
    try expect(
        rebooted.config.activeRouterMappings.first?.leaseExpiresUptime
            == 10
            && rebooted.config.activeRouterMappings.first?.recoveryState
                == .clockContinuityUnverified
            && rebooted.config.activeRouterMappings.first?
                .recoverySafeAfterUptime == 70,
        "Cross-boot recovery must expire active use immediately while "
            + "retaining only a separate conservative cleanup deadline"
    )
    let secondBootDirectory = try makeTemporaryDirectory(
        named: "second-cross-boot-recovery"
    )
    defer {
        try? FileManager.default.removeItem(
            at: secondBootDirectory
        )
    }
    let secondBootStore = AppConfigStore(
        baseDirectory: secondBootDirectory
    )
    try secondBootStore.save(rebooted.config)
    let secondBoot = NetworkAgent(
        configStore: secondBootStore,
        keychain: inMemoryKeychain(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { rebootWall.addingTimeInterval(5) },
        monotonicUptimeProvider: { 5 },
        bootIdentifierProvider: { "lease-boot-d" },
        performInitialCheckOnStart: false
    )
    defer { stopAgentForCleanup(secondBoot) }
    try expect(
        secondBoot.config.activeRouterMappings.first?
            .leaseExpiresUptime == 5
            && secondBoot.config.activeRouterMappings.first?
                .recoverySafeAfterUptime == 65,
        "A second reboot before cleanup must restart the conservative "
            + "recovery wait rather than treating the old lease as expired"
    )
    try stopAgent(secondBoot)
    try stopAgent(rebooted)
    let backwardWall = baseline.addingTimeInterval(-3_600)
    let backward = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        routerMappingService: MockRouterMappingService(),
        nowProvider: { backwardWall },
        monotonicUptimeProvider: { 10 },
        bootIdentifierProvider: { "lease-boot-c" },
        performInitialCheckOnStart: false
    )
    defer { stopAgentForCleanup(backward) }
    try expect(
        backward.config.activeRouterMappings.first?.leaseExpiresUptime
            == 10
            && backward.config.activeRouterMappings.first?.recoveryState
                == .clockContinuityUnverified
            && backward.config.activeRouterMappings.first?
                .recoverySafeAfterUptime == 70,
        "A wall-clock rollback across boot must expire the mapping "
            + "immediately and retain it only as cleanup recovery state"
    )
    try stopAgent(backward)
}

func testCrossBootWallRollbackAfterRuntimeFailsClosed() throws {
    let directory = try makeTemporaryDirectory(
        named: "cross-boot-wall-rollback"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let baseline = Date(timeIntervalSince1970: 2_000_290_000)
    let rebootWall = baseline.addingTimeInterval(20)
    let rebootUptime: TimeInterval = 10

    var mapping = activeMappingFixture(
        transport: .natpmp,
        family: .ipv4,
        localAddress: "10.0.0.20",
        renewAfter: baseline.addingTimeInterval(45),
        leaseExpiresAt: baseline.addingTimeInterval(60)
    )
    mapping.leaseBootIdentifier = "rollback-old-boot"
    mapping.renewAfterUptime = 145
    mapping.leaseExpiresUptime = 160
    mapping.leaseAnchorWallTime = baseline
    mapping.renewRemainingAtAnchor = 45
    mapping.leaseRemainingAtAnchor = 60

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .natpmp
    config.externalPort = mapping.externalPort
    config.activeRouterMappings = [mapping]
    config.accessExpiresAt = baseline.addingTimeInterval(60)
    config.accessExpiresUptime = 160
    config.accessBootIdentifier = "rollback-old-boot"
    config.accessAnchorWallTime = baseline
    config.accessRemainingAtAnchor = 60

    let store = AppConfigStore(baseDirectory: directory)
    try store.save(config)
    let emergency = emergencyJournal(in: directory)
    let fallback = EmergencyMappingJournal(
        fileURL: directory.appendingPathComponent(
            "cross-boot-fallback-mappings.json"
        )
    )
    let router = MockRouterMappingService()
    router.setRemovalFailures([mapping])
    let cleanupCompleted = DispatchSemaphore(value: 0)
    let checkCompleted = DispatchSemaphore(value: 0)
    router.afterRemoval = {
        cleanupCompleted.signal()
    }
    let scheduleLock = NSLock()
    let scheduleReady = DispatchSemaphore(value: 0)
    var scheduledDeadline: Date?
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        checkCompletionObserver: { checkCompleted.signal() },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        emergencyMappingJournal: emergency,
        fallbackMappingJournal: fallback,
        nowProvider: { rebootWall },
        monotonicUptimeProvider: { rebootUptime },
        bootIdentifierProvider: { "rollback-new-boot" },
        performInitialCheckOnStart: false,
        expirationTimerScheduler: { deadline, _ in
            scheduleLock.lock()
            scheduledDeadline = deadline
            scheduleLock.unlock()
            scheduleReady.signal()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }

    try expect(
        !agent.config.remoteAccessEnabled
            && agent.config.activeRouterMappings.isEmpty
            && agent.config.accessExpiresAt == nil
            && agent.config.accessExpiresUptime == nil,
        "A temporary session from another boot must close immediately "
            + "and move its mapping out of active state"
    )

    agent.start()
    try expect(
        scheduleReady.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "Cross-boot recovery must arm its conservative cleanup deadline"
    )
    scheduleLock.lock()
    let firstDeadline = scheduledDeadline
    scheduleLock.unlock()
    try expect(
        firstDeadline == rebootWall.addingTimeInterval(60),
        "The recovery-only deadline must wait the full original finite "
            + "lease instead of restoring it as active"
    )
    agent.runCheck()
    try expect(
        cleanupCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success
            && checkCompleted.wait(
                timeout: .now() + .seconds(3)
            ) == .success
            && router.removalCalls.map(\.localAddress)
                == ["10.0.0.20"]
            && router.ensureCalls.isEmpty
            && !agent.config.remoteAccessEnabled
            && agent.config.activeRouterMappings.map(\.identifier)
                == [mapping.identifier]
            && agent.status.routerStatus.state == .failed,
        "Failed recovery before natural expiry must remain blocked and "
            + "retain its recovery identity without recreating access"
    )
    try stopAgent(agent)
}

func testTemporaryAccessExpirationDoesNotWaitForKeychainAuthorization() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "expiration-keychain-isolation")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let clock = LockedClock(Date(timeIntervalSince1970: 2_000_300_000))
    let expiresAt = clock.now().addingTimeInterval(60)
    let mapping = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: clock.now().addingTimeInterval(30),
        leaseExpiresAt: expiresAt
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.externalPort = mapping.externalPort
    config.pcpNonce = mapping.pcpNonce
    config.activeRouterMappings = [mapping]
    config.accessExpiresAt = expiresAt

    let authorizationStarted = DispatchSemaphore(value: 0)
    let releaseAuthorization = DispatchSemaphore(value: 0)
    let keychain = KeychainStore(
        service: "io.github.naifuliang.gatebeam.expiration-keychain-isolation",
        legacyServices: [],
        operationHandlers: KeychainOperationHandlers(
            scopedSet: { _, _, _, _, _ in },
            scopedGet: { _, _, interaction in
                if interaction == .userInitiated {
                    authorizationStarted.signal()
                    releaseAuthorization.wait()
                }
                return "blocked-authorization-token"
            },
            scopedDelete: { _, _, _ in }
        )
    )
    let scheduleLock = NSLock()
    var expirationHandler: (() -> Void)?
    let resultLock = NSLock()
    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    var staleSaveResult: Result<AppConfig, Error>?
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: keychain,
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        nowProvider: { clock.now() },
        expirationTimerScheduler: { _, handler in
            scheduleLock.lock()
            expirationHandler = handler
            scheduleLock.unlock()
            return NetworkAgentScheduledTimer {}
        }
    )
    defer { stopAgentForCleanup(agent) }

    agent.start()
    try expect(
        waitUntil {
            scheduleLock.lock()
            let isScheduled = expirationHandler != nil
            scheduleLock.unlock()
            return isScheduled
        },
        "The access deadline must be scheduled before authorization starts"
    )
    agent.authorizeSavedCloudflareToken { result in
        resultLock.lock()
        authorizationResult = result
        resultLock.unlock()
    }
    try expect(
        authorizationStarted.wait(timeout: .now() + 3) == .success,
        "The injected authorization must block on the isolated Keychain queue"
    )
    agent.persistSettingsAsync(
        config: config,
        tokenMutation: .replace("stale-settings-token")
    ) { result in
        resultLock.lock()
        staleSaveResult = result
        resultLock.unlock()
    }

    clock.set(expiresAt)
    scheduleLock.lock()
    let handler = expirationHandler
    scheduleLock.unlock()
    guard let handler else {
        throw IntegrationContractFailure("The access expiration handler was not captured")
    }
    handler()

    try expect(
        waitUntil {
            !agent.config.remoteAccessEnabled
                && agent.config.accessExpiresAt == nil
                && agent.config.activeRouterMappings.isEmpty
        },
        "Temporary access must expire while Keychain authorization is still blocked"
    )
    try expect(
        router.removalCalls == [mapping],
        "Expiration must schedule and complete exact mapping cleanup without "
            + "waiting for Keychain UI: \(router.removalCalls)"
    )
    resultLock.lock()
    let completedWhileBlocked = authorizationResult != nil
    let staleSaveCompletedWhileBlocked = staleSaveResult != nil
    resultLock.unlock()
    try expect(!completedWhileBlocked, "The fixture must still have authorization blocked at the deadline")
    try expect(
        !staleSaveCompletedWhileBlocked,
        "A settings save queued behind authorization must not occupy the access state queue"
    )

    releaseAuthorization.signal()
    try expect(
        waitUntil {
            resultLock.lock()
            let completed = authorizationResult != nil && staleSaveResult != nil
            resultLock.unlock()
            return completed
        },
        "Authorization and the stale queued save must finish after the fixture releases it"
    )
    resultLock.lock()
    let finalAuthorization = authorizationResult
    let finalStaleSave = staleSaveResult
    resultLock.unlock()
    _ = try finalAuthorization?.get()
    if case .success = finalStaleSave {
        throw IntegrationContractFailure(
            "A settings save based on the pre-expiration revision must be superseded"
        )
    }
    try expect(!agent.config.remoteAccessEnabled, "Late authorization must not reopen remote access")
    try expect(agent.config.accessExpiresAt == nil, "Late authorization must not restore the expired deadline")
    try expect(agent.config.activeRouterMappings.isEmpty, "Late authorization must not restore router mappings")
    try expect(router.removalCalls == [mapping], "Late authorization must not repeat or undo mapping cleanup")
    try stopAgent(agent)
}

func testTemporaryAccessRevokesAnExistingOverlongLease() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "temporary-lease-shortening")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let now = Date()
    let overlong = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: now.addingTimeInterval(3600),
        leaseExpiresAt: now.addingTimeInterval(7200)
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.externalPort = overlong.externalPort
    config.pcpNonce = overlong.pcpNonce
    config.activeRouterMappings = [overlong]

    let router = MockRouterMappingService()
    let eventLock = NSLock()
    var events: [String] = []
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        sideEffectWillStartObserver: { label in
            eventLock.lock()
            events.append(label)
            eventLock.unlock()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }
    agent.start()
    try expect(
        waitUntil { agent.status.lastCheckedAt != nil },
        "The baseline mapping check must finish before temporary access is requested"
    )
    eventLock.lock()
    events.removeAll()
    eventLock.unlock()

    agent.setTemporaryAccess(minutes: 30)
    try expect(
        waitUntil {
            router.removalCalls.contains(overlong)
                && agent.config.accessExpiresAt != nil
                && router.ensureCalls.contains(.ipv4)
        },
        "Switching to temporary access must delete the overlong lease before creating its bounded replacement"
    )
    eventLock.lock()
    let observedEvents = events
    eventLock.unlock()
    guard let deleteIndex = observedEvents.firstIndex(of: "router.mapping.config-delete"),
          let createIndex = observedEvents.firstIndex(of: "router.mapping.create") else {
        throw IntegrationContractFailure(
            "Expected config-delete and bounded replacement creation events"
        )
    }
    try expect(
        deleteIndex < createIndex,
        "The old overlong lease must be revoked before a temporary replacement is created"
    )
    try stopAgent(agent)
}

func testMappingRenewalWindowAndAddressChangeReconciliation() throws {
    func runCheck(with mapping: ActiveRouterMapping, router: MockRouterMappingService) throws -> NetworkAgent {
        let baseDirectory = try makeTemporaryDirectory(named: "mapping-renewal-\(UUID().uuidString)")
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .disabled
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = mapping.transport.preference
        config.externalPort = mapping.externalPort
        config.pcpNonce = mapping.pcpNonce
        config.activeRouterMappings = [mapping]
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: baseDirectory),
            keychain: inMemoryKeychain(),
            initialConfig: config,
            localNetworkService: MockLocalNetworkService(),
            routerMappingService: router
        )
        defer { stopAgentForCleanup(agent) }
        agent.runCheck()
        try expect(
            waitUntil { agent.status.lastCheckedAt != nil },
            "The injected mapping check must complete"
        )
        try? FileManager.default.removeItem(at: baseDirectory)
        return agent
    }

    let fresh = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: Date().addingTimeInterval(1200),
        leaseExpiresAt: Date().addingTimeInterval(2400)
    )
    let freshRouter = MockRouterMappingService()
    let freshAgent = try runCheck(with: fresh, router: freshRouter)
    try expect(freshRouter.ensureCalls.isEmpty, "A fresh lease must not emit an early renewal packet")
    try expect(freshAgent.config.activeRouterMappings == [fresh], "A fresh lease must retain its tracked state")
    try stopAgent(freshAgent)
    var rebooted = fresh
    rebooted.routerEpoch = 600
    rebooted.routerEpochObservedAt = Date().addingTimeInterval(-30)
    let rebootRouter = MockRouterMappingService()
    rebootRouter.setEpochInvalidations([rebooted])
    let rebootAgent = try runCheck(with: rebooted, router: rebootRouter)
    try expect(
        rebootRouter.ensureCalls == [.ipv4],
        "An Epoch reset must rebuild immediately even before renewAfter"
    )
    try expect(
        rebootRouter.removalCalls.isEmpty,
        "A mapping invalidated by router state loss must not issue a stale delete"
    )
    try expect(
        rebootAgent.config.activeRouterMappings.count == 1
            && rebootAgent.config.activeRouterMappings[0].renewAfter > Date(),
        "The immediate rebuild must replace the invalidated tracked mapping"
    )
    try stopAgent(rebootAgent)
    let due = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: Date().addingTimeInterval(-10),
        leaseExpiresAt: Date().addingTimeInterval(1200)
    )
    let renewalRouter = MockRouterMappingService()
    let renewalAgent = try runCheck(with: due, router: renewalRouter)
    try expect(renewalRouter.ensureCalls == [.ipv4], "A lease in its renewal window must emit exactly one renewal")
    try expect(
        renewalAgent.config.activeRouterMappings.first?.renewAfter ?? .distantPast > Date(),
        "A successful renewal must persist the next renewal window"
    )
    try stopAgent(renewalAgent)
    let oldAddress = activeMappingFixture(
        transport: .upnp,
        family: .ipv4,
        localAddress: "192.0.2.99"
    )
    let changedRouter = MockRouterMappingService()
    changedRouter.setRemovalFailures([oldAddress])
    let changedAgent = try runCheck(with: oldAddress, router: changedRouter)
    try expect(changedRouter.removalCalls == [oldAddress], "An address change must revoke the old mapping first")
    try expect(changedRouter.ensureCalls.isEmpty, "A failed old-address cleanup must block a replacement mapping")
    try expect(
        changedAgent.config.activeRouterMappings == [oldAddress],
        "A failed address-change cleanup must preserve the old mapping for retry"
    )
    try stopAgent(changedAgent)
}

func testEffectiveAddressChangeBlocksReplacementUntilSafe() throws {
    let wall = Date(timeIntervalSince1970: 2_000_360_000)
    let boot = "integration-address-change-boot"

    func run(
        name: String,
        transport: RouterMappingTransport,
        oldAddress: String,
        replacementAddress: String,
        expired: Bool,
        cleanupFails: Bool
    ) throws -> (MockRouterMappingService, NetworkAgent, URL) {
        let directory = try makeTemporaryDirectory(named: name)
        var old = activeMappingFixture(
            transport: transport,
            family: .ipv4,
            localAddress: oldAddress,
            renewAfter: wall.addingTimeInterval(30),
            leaseExpiresAt: wall.addingTimeInterval(60)
        )
        old.leaseBootIdentifier = boot
        old.renewAfterUptime = 130
        old.leaseExpiresUptime = expired ? 99 : 160
        old.leaseAnchorWallTime = wall
        old.leaseRemainingAtAnchor = 60
        old.renewRemainingAtAnchor = 30

        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .disabled
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = transport.preference
        config.externalPort = old.externalPort
        config.pcpNonce = old.pcpNonce
        config.activeRouterMappings = [old]

        let local = MockLocalNetworkService()
        local.ipv4Address = replacementAddress
        let router = MockRouterMappingService()
        router.nowProvider = { wall }
        router.setEpochAddressChange(
            old,
            replacementAddress: replacementAddress
        )
        if cleanupFails {
            router.setRemovalFailures([old])
        }
        let agent = NetworkAgent(
            configStore: AppConfigStore(baseDirectory: directory),
            keychain: inMemoryKeychain(),
            initialConfig: config,
            localNetworkService: local,
            routerMappingService: router,
            publicIPServiceFactory: { _ in MockPublicIPService() },
            nowProvider: { wall },
            monotonicUptimeProvider: { 100 },
            bootIdentifierProvider: { boot }
        )
        defer { stopAgentForCleanup(agent) }
        agent.runCheck()
        try expect(
            waitUntil { agent.status.lastCheckedAt != nil },
            "Address-change check \(name) must finish"
        )
        return (router, agent, directory)
    }

    let failed = try run(
        name: "pcp-address-change-failed-cleanup",
        transport: .pcp,
        oldAddress: "192.0.2.20",
        replacementAddress: "192.0.2.21",
        expired: false,
        cleanupFails: true
    )
    defer { try? FileManager.default.removeItem(at: failed.2) }
    try expect(
        failed.0.ensureCalls.isEmpty,
        "B cleanup failure must block every replacement MAP for C"
    )
    try expect(
        failed.1.config.activeRouterMappings.first?.localAddress
            == "192.0.2.20"
            && failed.1.config.activeRouterMappings.first?.recoveryState
                == .effectiveClientAddressChanged,
        "Failed cleanup must persist B as the orphan recovery identity"
    )
    try stopAgent(failed.1)
    let succeeded = try run(
        name: "pcp-address-change-successful-cleanup",
        transport: .pcp,
        oldAddress: "192.0.2.20",
        replacementAddress: "192.0.2.21",
        expired: false,
        cleanupFails: false
    )
    defer { try? FileManager.default.removeItem(at: succeeded.2) }
    try expect(
        succeeded.0.removalCalls.first?.localAddress == "192.0.2.20"
            && succeeded.0.ensureCalls == [.ipv4],
        "Confirmed B deletion must happen before exactly one replacement MAP"
    )
    try expect(
        succeeded.1.config.activeRouterMappings.first?.localAddress
            == "192.0.2.21",
        "Successful cleanup must replace the tracked identity with C"
    )
    try stopAgent(succeeded.1)
    let expired = try run(
        name: "pcp-address-change-expired-lease",
        transport: .pcp,
        oldAddress: "192.0.2.20",
        replacementAddress: "192.0.2.21",
        expired: true,
        cleanupFails: true
    )
    defer { try? FileManager.default.removeItem(at: expired.2) }
    try expect(
        expired.0.removalCalls.isEmpty
            && expired.0.ensureCalls == [.ipv4],
        "A monotonic-expired B lease may be replaced without an unsafe delete"
    )
    try stopAgent(expired.1)
    let natFailed = try run(
        name: "natpmp-address-change-failed-cleanup",
        transport: .natpmp,
        oldAddress: "10.0.0.20",
        replacementAddress: "10.0.0.21",
        expired: false,
        cleanupFails: true
    )
    defer { try? FileManager.default.removeItem(at: natFailed.2) }
    try expect(
        natFailed.0.ensureCalls.isEmpty
            && natFailed.1.config.activeRouterMappings.first?.localAddress
                == "10.0.0.20"
            && natFailed.1.config.activeRouterMappings.first?.recoveryState
                == .effectiveClientAddressChanged,
        "NAT-PMP effective B cleanup failure must preserve B and block C"
    )
    try stopAgent(natFailed.1)
    let natSucceeded = try run(
        name: "natpmp-address-change-successful-cleanup",
        transport: .natpmp,
        oldAddress: "10.0.0.20",
        replacementAddress: "10.0.0.21",
        expired: false,
        cleanupFails: false
    )
    defer { try? FileManager.default.removeItem(at: natSucceeded.2) }
    try expect(
        natSucceeded.0.removalCalls.first?.localAddress == "10.0.0.20"
            && natSucceeded.0.ensureCalls == [.ipv4]
            && natSucceeded.1.config.activeRouterMappings.first?.localAddress
                == "10.0.0.21",
        "NAT-PMP must confirm B deletion before creating and persisting C"
    )
    try stopAgent(natSucceeded.1)
    let natExpired = try run(
        name: "natpmp-address-change-expired-lease",
        transport: .natpmp,
        oldAddress: "10.0.0.20",
        replacementAddress: "10.0.0.21",
        expired: true,
        cleanupFails: true
    )
    defer { try? FileManager.default.removeItem(at: natExpired.2) }
    try expect(
        natExpired.0.removalCalls.isEmpty
            && natExpired.0.ensureCalls == [.ipv4],
        "A monotonic-expired NAT-PMP B lease may be replaced without delete"
    )
    try stopAgent(natExpired.1)
}

func testNATPMPGatewayResetRebuildsOneMappingAtATime() throws {
    let baseDirectory = try makeTemporaryDirectory(
        named: "natpmp-serialized-rebuild"
    )
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let first = activeMappingFixture(
        transport: .natpmp,
        family: .ipv4,
        localAddress: "192.0.2.20",
        externalPort: 45900
    )
    let second = activeMappingFixture(
        transport: .natpmp,
        family: .ipv4,
        localAddress: "192.0.2.21",
        externalPort: 45901
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .natpmp
    config.externalPort = first.externalPort
    config.activeRouterMappings = [first, second]

    let router = MockRouterMappingService()
    router.setEpochInvalidations([first, second])
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        publicIPServiceFactory: { _ in MockPublicIPService() }
    )
    defer { stopAgentForCleanup(agent) }
    agent.runCheck()
    try expect(
        waitUntil { agent.status.lastCheckedAt != nil },
        "The NAT-PMP reset rebuild check must complete"
    )
    try expect(
        router.ensureCalls == [.ipv4],
        "All invalidated mappings on one NAT-PMP gateway must collapse to one serial rebuild"
    )
    try expect(
        router.removalCalls.isEmpty,
        "State lost by a restarted gateway must not receive stale deletes"
    )
    try expect(
        agent.config.activeRouterMappings.count == 1
            && agent.config.activeRouterMappings[0].transport == .natpmp,
        "The serialized rebuild must persist one authoritative replacement"
    )
    try stopAgent(agent)
}

func testMappingCreationIsCompensatedWhenCheckpointWriteFails() throws {
    struct InjectedConfigFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "mapping-checkpoint-write-failure")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.pcpNonce = Data(repeating: 8, count: 12).base64EncodedString()

    let store = AppConfigStore(
        configURL: URL(fileURLWithPath: agentConfigPath(baseDirectory)),
        dataWriter: { _, _ in throw InjectedConfigFailure() }
    )
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    agent.runCheck()
    try expect(
        waitUntil {
            router.ensureCalls == [.ipv4]
                && router.removalCalls.count == 1
        },
        "A mapping checkpoint write failure must immediately remove the newly created mapping"
    )
    try expect(
        agent.config.activeRouterMappings.isEmpty,
        "A successfully compensated mapping must not remain active in memory"
    )
    let recoveryJournalCleared = try store.loadMappingRecoveryJournal().isEmpty
    try expect(
        recoveryJournalCleared,
        "A successful compensation must clear the write-ahead recovery journal"
    )
    try expect(
        agent.status.settingsErrorMessage?.contains("was closed") == true,
        "The UI must explain that the uncheckpointed mapping was closed"
    )
    try stopAgent(agent)
}

func testFailedMappingCompensationPersistsAndRecoversJournal() throws {
    struct InjectedConfigFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "mapping-recovery-journal")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    let failingStore = AppConfigStore(
        configURL: configURL,
        dataWriter: { _, _ in throw InjectedConfigFailure() }
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.pcpNonce = Data(repeating: 9, count: 12).base64EncodedString()

    let failingRouter = MockRouterMappingService()
    failingRouter.failAllRemovals = true
    let durableEmergencyJournal = emergencyJournal(in: baseDirectory)
    let durableFallbackJournal = EmergencyMappingJournal(
        fileURL: baseDirectory.appendingPathComponent(
            "fallback-router-mappings.json"
        )
    )
    let firstAgent = NetworkAgent(
        configStore: failingStore,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: failingRouter,
        emergencyMappingJournal: durableEmergencyJournal,
        fallbackMappingJournal: durableFallbackJournal
    )
    defer { stopAgentForCleanup(firstAgent) }
    firstAgent.runCheck()
    try expect(
        waitUntil {
            failingRouter.ensureCalls == [.ipv4]
                && !failingRouter.removalCalls.isEmpty
                && (try? failingStore.loadMappingRecoveryJournal().count) == 1
                && firstAgent.config.activeRouterMappings.count == 1
        },
        "A failed compensation must persist the exact remaining mapping in a recovery journal"
    )
    let journaled = try failingStore.loadMappingRecoveryJournal()
    try expect(
        firstAgent.config.activeRouterMappings.map(\.identifier) == journaled.map(\.identifier),
        "In-memory retry state must match the durable recovery journal"
    )
    try stopAgent(firstAgent)
    let recoveredStore = AppConfigStore(configURL: configURL)
    let recoveredRouter = MockRouterMappingService()
    var disabled = AppConfig.default
    disabled.dnsProvider = .disabled
    disabled.preferredAddressFamily = .ipv4
    let recoveredAgent = NetworkAgent(
        configStore: recoveredStore,
        keychain: inMemoryKeychain(),
        initialConfig: disabled,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: recoveredRouter,
        emergencyMappingJournal: durableEmergencyJournal,
        fallbackMappingJournal: durableFallbackJournal
    )
    defer { stopAgentForCleanup(recoveredAgent) }
    recoveredAgent.runCheck()
    let recoveredCleanupCompleted = waitUntil {
        recoveredRouter.removalCalls.map(\.identifier)
            == journaled.map(\.identifier)
            && (try? recoveredStore.loadMappingRecoveryJournal()
                .isEmpty) == true
    }
    try expect(
        recoveredCleanupCompleted,
        "The next launch must clean the journal before any new router "
            + "mapping work; removals="
            + "\(recoveredRouter.removalCalls.map(\.identifier)), "
            + "active=\(recoveredAgent.config.activeRouterMappings.map(\.identifier)), "
            + "status=\(recoveredAgent.status.routerStatus.message)"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Recovery cleanup must not create a replacement mapping")
    try stopAgent(recoveredAgent)
}

func testEmergencyJournalSurvivesPrimaryStoreAndDeleteFailure() throws {
    struct InjectedStoreFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "emergency-mapping-journal")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    let failingStore = AppConfigStore(
        configURL: configURL,
        dataWriter: { _, _ in throw InjectedStoreFailure() },
        recoveryDataWriter: { _, _ in throw InjectedStoreFailure() }
    )
    let durableEmergencyJournal = emergencyJournal(in: baseDirectory)
    let durableFallbackJournal = EmergencyMappingJournal(
        fileURL: baseDirectory.appendingPathComponent(
            "fallback-router-mappings.json"
        )
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.pcpNonce = Data(repeating: 10, count: 12).base64EncodedString()

    let failingRouter = MockRouterMappingService()
    failingRouter.failAllRemovals = true
    let firstAgent = NetworkAgent(
        configStore: failingStore,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: failingRouter,
        emergencyMappingJournal: durableEmergencyJournal,
        fallbackMappingJournal: durableFallbackJournal
    )
    defer { stopAgentForCleanup(firstAgent) }
    firstAgent.runCheck()
    try expect(
        waitUntil {
            failingRouter.ensureCalls == [.ipv4]
                && !failingRouter.removalCalls.isEmpty
                && (try? durableEmergencyJournal.load().count) == 1
        },
        "Primary journal failure followed by delete failure must durably record the exact mapping elsewhere"
    )
    let emergencyMappings = try durableEmergencyJournal.load()
    try expect(
        emergencyMappings.first?.pcpNonce == config.pcpNonce,
        "The emergency journal must retain the complete PCP removal identity"
    )
    try stopAgent(firstAgent)
    let recoveredRouter = MockRouterMappingService()
    let recoveredAgent = NetworkAgent(
        configStore: AppConfigStore(configURL: configURL),
        keychain: inMemoryKeychain(),
        initialConfig: .default,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: recoveredRouter,
        emergencyMappingJournal: durableEmergencyJournal,
        fallbackMappingJournal: durableFallbackJournal
    )
    defer { stopAgentForCleanup(recoveredAgent) }
    recoveredAgent.runCheck()
    let emergencyCleanupCompleted = waitUntil {
        recoveredRouter.removalCalls.map(\.identifier)
            == emergencyMappings.map(\.identifier)
            && (try? durableEmergencyJournal.load().isEmpty)
                == true
    }
    try expect(
        emergencyCleanupCompleted,
        "A restart must load and remove emergency mappings before any "
            + "replacement work; removals="
            + "\(recoveredRouter.removalCalls.map(\.identifier)), "
            + "active=\(recoveredAgent.config.activeRouterMappings.map(\.identifier)), "
            + "status=\(recoveredAgent.status.routerStatus.message)"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Emergency recovery must not create a new router mapping")
    try stopAgent(recoveredAgent)
}

func testRecoveryIdentitySurvivesEveryJournalAndDeleteFailure() throws {
    struct InjectedPrimaryJournalFailure: Error {}
    struct InjectedEmergencyJournalFailure: Error {}

    let baseDirectory = try makeTemporaryDirectory(named: "journal-total-failure")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    let store = AppConfigStore(
        configURL: configURL,
        recoveryDataWriter: { _, _ in throw InjectedPrimaryJournalFailure() }
    )
    let failingEmergency = EmergencyMappingJournal(
        fileURL: baseDirectory
            .appendingPathComponent("emergency", isDirectory: true)
            .appendingPathComponent("mappings.json"),
        dataWriter: { _, _ in throw InjectedEmergencyJournalFailure() }
    )
    let durableFallback = EmergencyMappingJournal(
        fileURL: baseDirectory
            .appendingPathComponent("fallback", isDirectory: true)
            .appendingPathComponent("mappings.json")
    )

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .pcp
    config.pcpNonce = Data(repeating: 11, count: 12).base64EncodedString()
    var uncleanMapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    uncleanMapping.pcpNonce = config.pcpNonce
    let recovery = RouterMappingRecoveryRequiredError(
        mapping: uncleanMapping,
        operationDescription: "Injected mapping verification failure",
        cleanupDescription: "Injected initial delete failure"
    )

    let failingRouter = MockRouterMappingService()
    failingRouter.setRecoveryFailure(recovery)
    failingRouter.failAllRemovals = true
    let firstCheckCompleted = DispatchSemaphore(value: 0)
    let firstAgent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkCompletionObserver: {
            firstCheckCompleted.signal()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: failingRouter,
        emergencyMappingJournal: failingEmergency,
        fallbackMappingJournal: durableFallback
    )
    defer { stopAgentForCleanup(firstAgent) }
    firstAgent.runCheck()
    try expect(
        firstCheckCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "The first total-journal-failure check must explicitly complete"
    )
    try expect(
        failingRouter.ensureCalls == [.ipv4]
            && failingRouter.removalCalls.map(\.identifier)
                .contains(uncleanMapping.identifier)
            && (try? durableFallback.load().map(\.identifier))
                == [uncleanMapping.identifier],
        "Emergency and primary journal failures plus delete failure "
            + "must reach the durable fallback before assertions"
    )
    let failureDetail = firstAgent.status.routerStatus.detail
    try expect(failureDetail.contains(uncleanMapping.identifier), "The surfaced error must retain the full mapping identity")
    try expect(failureDetail.contains("Emergency journal failed"), "The surfaced error must include the emergency journal failure")
    try expect(failureDetail.contains("Primary journal failed"), "The surfaced error must include the primary journal failure")
    try expect(failureDetail.contains("Immediate cleanup retry failed"), "The surfaced error must include the second delete failure")

    firstAgent.runCheck()
    try expect(
        firstCheckCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "The in-memory recovery retry must explicitly complete"
    )
    try expect(
        failingRouter.removalCalls.count >= 2,
        "A later completed check must retry the in-memory recovery identity"
    )
    try expect(
        failingRouter.ensureCalls == [.ipv4],
        "An in-memory recovery identity must block every new mapping attempt"
    )
    try stopAgent(firstAgent)
    let recoveredRouter = MockRouterMappingService()
    let recoveredCheckCompleted = DispatchSemaphore(value: 0)
    let recoveredAgent = NetworkAgent(
        configStore: AppConfigStore(configURL: configURL),
        keychain: inMemoryKeychain(),
        initialConfig: .default,
        checkCompletionObserver: {
            recoveredCheckCompleted.signal()
        },
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: recoveredRouter,
        emergencyMappingJournal: emergencyJournal(in: baseDirectory),
        fallbackMappingJournal: durableFallback
    )
    defer { stopAgentForCleanup(recoveredAgent) }
    recoveredAgent.runCheck()
    try expect(
        recoveredCheckCompleted.wait(
            timeout: .now() + .seconds(3)
        ) == .success,
        "The restarted fallback recovery check must explicitly complete"
    )
    try expect(
        recoveredRouter.removalCalls.map(\.identifier)
            == [uncleanMapping.identifier]
            && (try? durableFallback.load().isEmpty) == true,
        "A completed restart must recover the third-journal identity "
            + "and clear it after idempotent cleanup"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Fallback recovery must finish before any new mapping")
    try stopAgent(recoveredAgent)
}

func testRecoveryJournalsUseSecureAtomicPermissions() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "journal-permissions")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)

    let configURL = baseDirectory
        .appendingPathComponent("primary", isDirectory: true)
        .appendingPathComponent("config.json")
    let store = AppConfigStore(configURL: configURL)
    try store.saveMappingRecoveryJournal([mapping])

    let emergencyURL = baseDirectory
        .appendingPathComponent("emergency", isDirectory: true)
        .appendingPathComponent("mappings.json")
    let emergency = EmergencyMappingJournal(fileURL: emergencyURL)
    try emergency.save([mapping])

    let primaryFileMode = try fileMode(at: store.mappingRecoveryLocation)
    let primaryDirectoryMode = try fileMode(
        at: store.mappingRecoveryLocation.deletingLastPathComponent()
    )
    let emergencyFileMode = try fileMode(at: emergencyURL)
    let emergencyDirectoryMode = try fileMode(at: emergencyURL.deletingLastPathComponent())
    try expect(primaryFileMode == 0o600, "Primary journal must be mode 0600")
    try expect(
        primaryDirectoryMode == 0o700,
        "Primary journal directory must be mode 0700"
    )
    try expect(emergencyFileMode == 0o600, "Emergency journal must be mode 0600")
    try expect(
        emergencyDirectoryMode == 0o700,
        "Emergency journal directory must be mode 0700"
    )

    let observedURL = baseDirectory
        .appendingPathComponent("observed", isDirectory: true)
        .appendingPathComponent("journal.json")
    var observedTemporaryMode: Int?
    var observedDirectoryMode: Int?
    try SecureAtomicFileWriter.write(Data("identity".utf8), to: observedURL) { temporaryURL in
        observedTemporaryMode = try fileMode(at: temporaryURL)
        observedDirectoryMode = try fileMode(at: temporaryURL.deletingLastPathComponent())
    }
    try expect(observedTemporaryMode == 0o600, "Temporary journal must be 0600 before rename")
    try expect(observedDirectoryMode == 0o700, "Journal directory must be 0700 before rename")
    let leftovers = try FileManager.default.contentsOfDirectory(
        at: observedURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    try expect(
        leftovers.contains { $0.lastPathComponent == observedURL.lastPathComponent },
        "Secure atomic replacement must leave the completed journal"
    )
    try expect(
        !leftovers.contains { $0.pathExtension == "tmp" },
        "Secure atomic replacement must not leave temporary journal files"
    )
}

func testUnknownRecoverySourcesFailClosed() throws {
    struct InjectedJournalReadFailure: Error, LocalizedError {
        var errorDescription: String? { "Injected journal read failure" }
    }

    func enabledConfig() -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .disabled
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = .pcp
        config.pcpNonce = Data(repeating: 12, count: 12).base64EncodedString()
        return config
    }

    func expectFailClosed(
        _ agent: NetworkAgent,
        router: MockRouterMappingService,
        sourceName: String
    ) throws {
        agent.runCheck()
        try expect(
            waitUntil {
                agent.status.routerStatus.message == "Router recovery state is unknown"
            },
            "\(sourceName) failure must surface an unknown recovery state"
        )
        try expect(router.ensureCalls.isEmpty, "\(sourceName) failure must block every new mapping")
        let visibleError = agent.status.settingsErrorMessage ?? ""
        try expect(
            visibleError.contains("Back up the damaged file"),
            "\(sourceName) failure must present an actionable settings error"
        )
        try expect(
            visibleError.contains(sourceName),
            "\(sourceName) failure must identify the unreadable recovery source"
        )
    }

    let primaryRoot = try makeTemporaryDirectory(named: "primary-journal-corrupt")
    defer { try? FileManager.default.removeItem(at: primaryRoot) }
    let primaryStore = AppConfigStore(
        configURL: URL(fileURLWithPath: agentConfigPath(primaryRoot))
    )
    try SecureAtomicFileWriter.write(
        Data("not-json".utf8),
        to: primaryStore.mappingRecoveryLocation
    )
    let primaryRouter = MockRouterMappingService()
    let primaryEmergency = emergencyJournal(in: primaryRoot)
    let primaryFallback = EmergencyMappingJournal(
        fileURL: primaryRoot.appendingPathComponent("fallback/mappings.json")
    )
    let primaryAgent = NetworkAgent(
        configStore: primaryStore,
        keychain: inMemoryKeychain(),
        initialConfig: enabledConfig(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: primaryRouter,
        emergencyMappingJournal: primaryEmergency,
        fallbackMappingJournal: primaryFallback
    )
    defer { stopAgentForCleanup(primaryAgent) }
    try expectFailClosed(primaryAgent, router: primaryRouter, sourceName: "Primary recovery journal")
    try primaryStore.saveMappingRecoveryJournal([])
    primaryAgent.runCheck()
    try expect(
        waitUntil {
            primaryRouter.ensureCalls == [.ipv4]
        },
        "Recovery state must unlock only after all three sources read and clean successfully"
    )
    try stopAgent(primaryAgent)
    let emergencyRoot = try makeTemporaryDirectory(named: "emergency-journal-unreadable")
    defer { try? FileManager.default.removeItem(at: emergencyRoot) }
    let emergencyURL = emergencyRoot.appendingPathComponent("emergency/mappings.json")
    let seededEmergency = EmergencyMappingJournal(fileURL: emergencyURL)
    try seededEmergency.save([activeMappingFixture(transport: .pcp, family: .ipv4)])
    let unreadableEmergency = EmergencyMappingJournal(
        fileURL: emergencyURL,
        dataReader: { _ in throw InjectedJournalReadFailure() }
    )
    let emergencyRouter = MockRouterMappingService()
    let emergencyAgent = NetworkAgent(
        configStore: AppConfigStore(
            configURL: URL(fileURLWithPath: agentConfigPath(emergencyRoot))
        ),
        keychain: inMemoryKeychain(),
        initialConfig: enabledConfig(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: emergencyRouter,
        emergencyMappingJournal: unreadableEmergency,
        fallbackMappingJournal: EmergencyMappingJournal(
            fileURL: emergencyRoot.appendingPathComponent("fallback/mappings.json")
        )
    )
    defer { stopAgentForCleanup(emergencyAgent) }
    try expectFailClosed(
        emergencyAgent,
        router: emergencyRouter,
        sourceName: "Emergency recovery journal"
    )
    try stopAgent(emergencyAgent)
    let fallbackRoot = try makeTemporaryDirectory(named: "fallback-journal-permissions")
    defer { try? FileManager.default.removeItem(at: fallbackRoot) }
    let fallbackURL = fallbackRoot.appendingPathComponent("fallback/mappings.json")
    let insecureFallback = EmergencyMappingJournal(fileURL: fallbackURL)
    try insecureFallback.save([activeMappingFixture(transport: .pcp, family: .ipv4)])
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fallbackURL.path
    )
    let fallbackRouter = MockRouterMappingService()
    let fallbackAgent = NetworkAgent(
        configStore: AppConfigStore(
            configURL: URL(fileURLWithPath: agentConfigPath(fallbackRoot))
        ),
        keychain: inMemoryKeychain(),
        initialConfig: enabledConfig(),
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: fallbackRouter,
        emergencyMappingJournal: emergencyJournal(in: fallbackRoot),
        fallbackMappingJournal: insecureFallback
    )
    defer { stopAgentForCleanup(fallbackAgent) }
    try expectFailClosed(
        fallbackAgent,
        router: fallbackRouter,
        sourceName: "Fallback recovery journal"
    )
    try stopAgent(fallbackAgent)
}

func testDisabledSideEffectsNeverReadProductionRecoverySources() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "disabled-recovery-read-isolation")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }
    let configURL = URL(fileURLWithPath: agentConfigPath(baseDirectory))
    let seededStore = AppConfigStore(configURL: configURL)
    let mapping = activeMappingFixture(transport: .pcp, family: .ipv4)
    try seededStore.saveMappingRecoveryJournal([mapping])
    let primaryReads = LockedCounter()
    let store = AppConfigStore(
        configURL: configURL,
        recoveryDataReader: { url in
            primaryReads.increment()
            return try Data(contentsOf: url)
        }
    )

    let emergencyURL = baseDirectory.appendingPathComponent("emergency/mappings.json")
    try EmergencyMappingJournal(fileURL: emergencyURL).save([mapping])
    let emergencyReads = LockedCounter()
    let emergency = EmergencyMappingJournal(
        fileURL: emergencyURL,
        dataReader: { url in
            emergencyReads.increment()
            return try Data(contentsOf: url)
        }
    )

    let fallbackURL = baseDirectory.appendingPathComponent("fallback/mappings.json")
    try EmergencyMappingJournal(fileURL: fallbackURL).save([mapping])
    let fallbackReads = LockedCounter()
    let fallback = EmergencyMappingJournal(
        fileURL: fallbackURL,
        dataReader: { url in
            fallbackReads.increment()
            return try Data(contentsOf: url)
        }
    )

    let agent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: .default,
        sideEffectsEnabled: false,
        emergencyMappingJournal: emergency,
        fallbackMappingJournal: fallback
    )
    defer { stopAgentForCleanup(agent) }
    agent.runCheck()
    try expect(primaryReads.current == 0, "Disabled side effects must not read the primary production journal")
    try expect(emergencyReads.current == 0, "Disabled side effects must not read the emergency production journal")
    try expect(fallbackReads.current == 0, "Disabled side effects must not read the fallback production journal")
    try stopAgent(agent)
}

func testManagedMappingIdentifierIncludesProtocolRemovalIdentity() throws {
    let pcpA = activeMappingFixture(transport: .pcp, family: .ipv4)
    var pcpB = pcpA
    pcpB.pcpNonce = Data(repeating: 8, count: 12).base64EncodedString()
    try expect(
        pcpA.identifier != pcpB.identifier,
        "PCP mappings with different nonces must have distinct removal identifiers"
    )

    let upnpA = activeMappingFixture(transport: .upnp, family: .ipv6)
    var upnpB = upnpA
    upnpB.gatewayAddress = "2001:db8::2"
    upnpB.pinholeID = 42
    try expect(
        upnpA.identifier != upnpB.identifier,
        "UPnP pinholes on different gateways or IDs must remain independently trackable"
    )

    let router = MockRouterMappingService()
    router.setRemovalFailures([pcpB])
    let report = router.removeMappings([pcpA, pcpB])
    try expect(
        report.succeededMappings.map(\.identifier) == [pcpA.identifier],
        "A partial removal must report only the exact successful mapping"
    )
    try expect(
        report.remainingMappings.map(\.identifier) == [pcpB.identifier],
        "A partial removal must retain only the exact failed mapping"
    )
}

func testDisabledSideEffectsNeverTouchInjectedLANServices() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "mapping-side-effects-disabled")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.activeRouterMappings = [
        activeMappingFixture(transport: .pcp, family: .ipv4)
    ]
    let local = MockLocalNetworkService()
    let router = MockRouterMappingService()
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        sideEffectsEnabled: false,
        localNetworkService: local,
        routerMappingService: router
    )
    defer { stopAgentForCleanup(agent) }

    agent.start()
    agent.runCheck()
    agent.setRemoteAccessEnabled(false)
    _ = try agent.persistSettings(config: .default, tokenMutation: .keepExisting)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    try expect(local.callCount == 0, "Disabled side effects must not inspect LAN addresses, gateways, or ports")
    try expect(router.operationCount == 0, "Disabled side effects must not discover, renew, or delete router mappings")
}

let tests: [(String, () throws -> Void)] = [
    ("default data chain", testDefaultDataChain),
    ("system/direct matrix", testSystemAndDirectMatrix),
    ("custom policy independence", testCustomPoliciesRemainIndependent),
    ("invalid custom proxy isolation", testInvalidProxyOnlyBlocksCustomConsumers),
    ("injected config-store directory", testConfigStoreUsesInjectedDirectory),
    ("check interval normalization and migration", testCheckIntervalNormalizationAndLegacyMigration),
    ("inactive legacy proxy migration", testConfigStoreMigratesInactiveLegacyProxyCredentials),
    ("invalid active proxy migration", testConfigStoreMigratesInvalidActiveProxy),
    ("valid active proxy normalization", testConfigStoreNormalizesValidActiveProxy),
    ("corrupt config preservation and fail-closed recovery", testCorruptConfigIsPreservedAndFailsMappingRecoveryClosed),
    ("invalid proxy persistence ordering", testInvalidProxyPreventsAllPersistence),
    ("inactive credential proxy scrubbing", testInactiveCredentialProxyIsScrubbedBeforePersistence),
    ("inactive valid proxy scrubbing", testInactiveValidProxyIsClearedBeforePersistence),
    ("valid proxy persistence ordering", testValidProxyPersistsInOrder),
    ("token failure persistence ordering", testTokenFailurePreventsConfigPersistence),
    ("token mutation policy never infers removal", testTokenMutationPolicyNeverInfersRemoval),
    ("keep-existing save isolates unknown and failed Keychain", testKeepExistingSaveNeverTouchesUnknownOrFailedKeychain),
    ("Verify latches denied and cancelled Keychain reads", testVerifyKeepsTokenAndLatchesDeniedOrCancelledReads),
    ("Settings Verify rejects stale token callbacks", testSettingsVerifyDiscardsOutOfOrderAndEditedTokenResults),
    ("Settings Verify uses unsaved Cloudflare proxy", testSettingsVerifyUsesUnsavedCloudflareProxyWithoutPersistence),
    ("Cloudflare token removal prompt contract", testCloudflareTokenRemovalPromptCancelAndConfirmContract),
    ("Cloudflare token removal controller path", testCloudflareTokenRemovalControllerPath),
    ("Settings UI access lifetime actions", testSettingsUIAccessActionsPersistExplicitLifetimeModes),
    ("temporary access rejects invalid Custom proxy", testTemporaryAccessRejectsInvalidCustomProxyWithoutMutation),
    ("temporary access rejects busy Settings save", testTemporaryAccessRejectsBusySettingsSaveWithoutMutation),
    ("temporary access rejects busy token authorization", testTemporaryAccessRejectsTokenAuthorizationBusyWithoutMutation),
    ("temporary access clock and restart boundaries", testTemporaryAccessEntrySurvivesClockAndRestartBoundaries),
    ("temporary access monotonic wall rollback", testTemporaryAccessUsesMonotonicDeadlineAfterWallRollback),
    ("Cloudflare Zone Read presentation", testCloudflareZoneReadPresentationDoesNotClaimDNSReady),
    ("Settings Cloudflare error presentation", testSettingsCloudflareErrorPresentationFailsClosed),
    ("remote connection URL off-state policy", testRemoteConnectionURLPolicyFailsClosedWhenAccessIsOff),
    ("explicit token replacement and removal idempotence", testExplicitReplacementAndRemovalAreIdempotent),
    ("disabled side-effects check isolation", testDisabledSideEffectsRejectChecks),
    ("disabled side-effects config isolation", testDisabledSideEffectsDoNotReadSuppliedConfigStore),
    ("Keychain read error propagation", testKeychainReadFailurePropagates),
    ("Keychain delete rollback", testKeychainDeleteFailurePreservesTokenAndBlocksConfig),
    ("Keychain single-flight and failure latch", testKeychainSingleFlightAndFailureLatch),
    ("Keychain background query policy", testKeychainQueryInteractionPolicy),
    ("scheduled checks use background Keychain policy", testScheduledChecksUseBackgroundKeychainPolicy),
    ("Keychain explicit legacy migration", testKeychainLegacyMigrationRequiresExplicitAuthorization),
    ("Keychain signing requirement classification", testKeychainRequirementClassificationRejectsWeakAlternatives),
    ("Keychain current item ACL refresh", testCurrentKeychainItemAuthorizationRefreshesAccess),
    ("Keychain legacy cleanup retry", testLegacyCleanupFailureRetriesWithoutLosingSecureCopy),
    ("Keychain explicit authorization latch", testExplicitKeychainAuthorizationClearsFailureLatch),
    ("Keychain migration and concurrent keep-existing save", testLegacyMigrationSerializesConcurrentKeepExistingSave),
    ("Keychain stale read and authorization ordering", testOldBackgroundReadCannotOverwriteAuthorizationSuccess),
    ("Keychain delete write authorize restart ordering", testDeleteWriteAuthorizeOrderingSurvivesBackendRestart),
    ("real config write failure", testConfigStoreReportsRealWriteFailure),
    ("settings transaction rollback", testSettingsTransactionRollsBackOnConfigWriteFailure),
    ("serialized concurrent state", testConcurrentStateAccessDoesNotDeadlock),
    ("check coalescing and interval storm resistance", testCheckCoalescingPreventsQueuedStorms),
    ("stale check cancellation before router side effects", testConfigMutationInvalidatesAnOldCheckBeforeRouterSideEffects),
    ("linearized final side-effect window", testSideEffectGateLinearizesTheFinalCheckWindow),
    ("stop and disable cancel router transactions", testStopAndDisableCooperativelyCancelRouterTransaction),
    ("disabled recovery skips non-cleanup network work", testDisabledRecoveryCheckSkipsAllNonCleanupNetworkWork),
    ("disabled persisted active mapping recovery matrix", testDisabledPersistedActiveMappingRecoveryMatrix),
    ("router WAN public IPv4 selection", testRouterWANIPv4RequiresPublicRoutability),
    ("automatic PCP mapping supplies verified router WAN", testAutomaticPCPMappingSuppliesVerifiedRouterWAN),
    ("current-check mapping proof family matrix", testCurrentCheckMappingProofFamilyMatrix),
    ("DDNS waits for durable unexpired mapping proof", testDDNSWaitsForDurableUnexpiredMappingProof),
    ("asynchronous settings persistence", testPersistSettingsAsyncNeverBlocksTheMainThread),
    ("superseded save mapping checkpoint merge", testSupersededSavePreservesCompletedMappingCleanup),
    ("local-origin TCP status semantics", testLocalOriginTCPStatusSemantics),
    ("start-at-login result visibility", testStartAtLoginFailureIsVisibleAndRevertsConfig),
    ("mapping disable retry state", testRemoteAccessDisableRetainsFailedMappingForRetry),
    ("legacy Automatic exact retry state", testLegacyAutomaticCleanupPersistsEveryUnknownProtocol),
    ("UPnP recovery explicit enabled contract", testUPnPRecoveryRequiresExplicitEnabledRule),
    ("mapping identity transaction", testMappingIdentityChangeMustDeleteOldRuleFirst),
    ("post-cleanup persistence truth", testPostCleanupPersistenceFailureKeepsTruthfulMappingState),
    ("temporary access cleanup retry", testTemporaryAccessExpiryDoesNotHideCleanupFailure),
    ("independent temporary access expiration", testTemporaryAccessUsesIndependentExpirationTimer),
    ("mapping deadlines drive unified wake", testMappingDeadlinesDriveUnifiedWakeAndPersistedRecovery),
    ("monotonic lease deadlines and conservative restore", testMonotonicLeaseDeadlinesIgnoreWallClockAndRestoreConservatively),
    ("cross-boot wall rollback after runtime fails closed", testCrossBootWallRollbackAfterRuntimeFailsClosed),
    ("temporary access expiration ignores Keychain prompts", testTemporaryAccessExpirationDoesNotWaitForKeychainAuthorization),
    ("temporary access shortens existing router lease", testTemporaryAccessRevokesAnExistingOverlongLease),
    ("mapping renewal and address reconciliation", testMappingRenewalWindowAndAddressChangeReconciliation),
    ("effective address change safety gate", testEffectiveAddressChangeBlocksReplacementUntilSafe),
    ("NAT-PMP reset rebuilds serially", testNATPMPGatewayResetRebuildsOneMappingAtATime),
    ("mapping checkpoint compensation", testMappingCreationIsCompensatedWhenCheckpointWriteFails),
    ("mapping recovery journal", testFailedMappingCompensationPersistsAndRecoversJournal),
    ("emergency mapping journal", testEmergencyJournalSurvivesPrimaryStoreAndDeleteFailure),
    ("total journal failure identity retention", testRecoveryIdentitySurvivesEveryJournalAndDeleteFailure),
    ("secure journal atomic permissions", testRecoveryJournalsUseSecureAtomicPermissions),
    ("unknown recovery sources fail closed", testUnknownRecoverySourcesFailClosed),
    ("disabled recovery-source read isolation", testDisabledSideEffectsNeverReadProductionRecoverySources),
    ("managed mapping unique identity", testManagedMappingIdentifierIncludesProtocolRemovalIdentity),
    ("disabled side-effects LAN isolation", testDisabledSideEffectsNeverTouchInjectedLANServices)
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS: \(name)")
    } catch {
        failures += 1
        print("FAIL: \(name): \(error)")
    }
}

if failures > 0 {
    exit(1)
}

print("\(tests.count) integration contract tests passed")
