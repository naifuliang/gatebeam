import Foundation
import Darwin

struct PortMappingResult {
    let protocolName: String
    let externalPort: UInt16
    let routerExternalAddress: String?
    let message: String
    var pinholeID: UInt16? = nil
    let activeMapping: ActiveRouterMapping
    let currentCheckProof: RouterMappingCurrentCheckProof
}

struct RouterMappingProofIdentity: Equatable {
    let mappingIdentifier: String
    let effectiveSourceAddress: String
    let gatewayAddress: String
    let protocolBinding: String?
    let internalPort: UInt16
    let externalPort: UInt16
    let pinholeID: UInt16?
}

struct RouterMappingCurrentCheckProof: Equatable {
    static let defaultSideEffectSafetyMargin: TimeInterval = 0.25

    let family: RouterMappingAddressFamily
    let transport: RouterMappingTransport
    let identity: RouterMappingProofIdentity
    let boundWANAddress: String
    let verifiedAtUptime: TimeInterval
    let leaseExpiresUptime: TimeInterval
    let sideEffectSafetyMargin: TimeInterval
    let mappingIdentityVerified: Bool
    let boundWANEvidenceVerified: Bool
    let sameBootVerified: Bool
    let leaseVerified: Bool
    let epochOrIGDContinuityVerified: Bool
    var checkpointed: Bool
    var checkpointGeneration: UInt64? = nil

    var sideEffectDeadlineUptime: TimeInterval {
        leaseExpiresUptime - max(0, sideEffectSafetyMargin)
    }

    var hasVerifiedMappingEvidence: Bool {
        mappingIdentityVerified
            && boundWANEvidenceVerified
            && sameBootVerified
            && leaseVerified
            && epochOrIGDContinuityVerified
    }

    var isVerified: Bool {
        hasVerifiedMappingEvidence
            && checkpointed
    }
}

struct RouterCapabilityResult {
    let natPMPAvailable: Bool
    let upnpAvailable: Bool
    let routerExternalAddress: String?
    var pcpAvailable: Bool = false
    var ipv6FirewallAvailable: Bool = false
}

enum UPnPDiscoveryAddressFamily: Equatable {
    case ipv4
    case ipv6
}

struct UPnPDiscoveryRequest {
    let addressFamily: UPnPDiscoveryAddressFamily
    let host: String
    let port: UInt16
    let interfaceName: String?
    let payloads: [Data]
    let timeoutSeconds: Int
}

struct RouterMappingRetryPolicy {
    var pcpMaximumAttempts = 9
    var natPMPMaximumAttempts = 9
    var pcpInitialRetryInterval: TimeInterval = 3
    var automaticCapabilityProbeIntervals: [TimeInterval] = [0.25, 0.5, 1]
    var epochHealthProbeIntervals: [TimeInterval] = [0.25, 0.5]

    static let protocolDefault = RouterMappingRetryPolicy()

    var normalizedPCPMaximumAttempts: Int {
        min(max(pcpMaximumAttempts, 1), 64)
    }

    var normalizedNATPMPMaximumAttempts: Int {
        min(max(natPMPMaximumAttempts, 1), 9)
    }

    var normalizedAutomaticCapabilityProbeIntervals: [TimeInterval] {
        Self.normalizedShortIntervals(
            automaticCapabilityProbeIntervals,
            fallback: [0.25, 0.5, 1]
        )
    }

    var normalizedEpochHealthProbeIntervals: [TimeInterval] {
        Self.normalizedShortIntervals(
            epochHealthProbeIntervals,
            fallback: [0.25, 0.5]
        )
    }

    private static func normalizedShortIntervals(
        _ intervals: [TimeInterval],
        fallback: [TimeInterval]
    ) -> [TimeInterval] {
        let normalized = intervals.prefix(4).map {
            min(max($0, 0.001), 2)
        }
        return normalized.isEmpty ? fallback : normalized
    }
}

struct RouterMappingUDPError: Error, LocalizedError {
    let underlying: RouterMappingError
    let requestMayHaveReachedRouter: Bool
    var effectiveSourceAddress: String? = nil

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private struct RouterMappingUDPTransactionResult<Response> {
    let response: Response
    let effectiveSourceAddress: String
}

private final class RouterMappingOperationContext: NSObject {
    let cancellationGeneration: UInt64
    let absoluteDeadlineUptime: TimeInterval?

    init(
        cancellationGeneration: UInt64,
        absoluteDeadlineUptime: TimeInterval?
    ) {
        self.cancellationGeneration = cancellationGeneration
        self.absoluteDeadlineUptime = absoluteDeadlineUptime
    }
}

typealias RouterMappingUDPTransactionHandler = (
    _ host: String,
    _ port: UInt16,
    _ retryIntervals: [TimeInterval],
    _ sourceAddressHint: String?,
    _ payloadBuilder: (String) throws -> Data,
    _ acceptsResponse: (Data) throws -> Bool
) throws -> Data

struct RouterMappingUDPSocketOperations {
    var makeSocket: (Int32, Int32, Int32) -> Int32 = {
        Darwin.socket($0, $1, $2)
    }
    var connectSocket: (
        Int32,
        UnsafePointer<sockaddr>,
        socklen_t
    ) -> Int32 = {
        Darwin.connect($0, $1, $2)
    }
    var sendDatagram: (
        Int32,
        UnsafeRawPointer,
        Int
    ) -> ssize_t = {
        Darwin.send($0, $1, $2, 0)
    }
    var closeSocket: (Int32) -> Void = {
        _ = Darwin.close($0)
    }

    static let system = RouterMappingUDPSocketOperations()
}

enum RouterMappingInvalidationReason: Equatable {
    case routerStateLost
    case effectiveClientAddressChanged(replacementAddress: String)
}

struct RouterMappingInvalidation {
    let mapping: ActiveRouterMapping
    let reason: RouterMappingInvalidationReason
}

struct RouterMappingEpochReport {
    let refreshedMappings: [ActiveRouterMapping]
    let invalidations: [RouterMappingInvalidation]
    let errors: [String]
    let currentCheckProofs: [RouterMappingCurrentCheckProof]

    var invalidatedMappings: [ActiveRouterMapping] {
        invalidations.map(\.mapping)
    }

    init(
        refreshedMappings: [ActiveRouterMapping],
        invalidations: [RouterMappingInvalidation],
        errors: [String],
        currentCheckProofs: [RouterMappingCurrentCheckProof] = []
    ) {
        self.refreshedMappings = refreshedMappings
        self.invalidations = invalidations
        self.errors = errors
        self.currentCheckProofs = currentCheckProofs
    }

    init(
        refreshedMappings: [ActiveRouterMapping],
        invalidatedMappings: [ActiveRouterMapping],
        errors: [String],
        currentCheckProofs: [RouterMappingCurrentCheckProof] = []
    ) {
        self.init(
            refreshedMappings: refreshedMappings,
            invalidations: invalidatedMappings.map {
                RouterMappingInvalidation(
                    mapping: $0,
                    reason: .routerStateLost
                )
            },
            errors: errors,
            currentCheckProofs: currentCheckProofs
        )
    }
}

private enum RouterEpochProtocol: String, Hashable {
    case pcp
    case natPMP
}

private struct RouterEpochKey: Hashable {
    let gatewayAddress: String
    let clientAddress: String
    let protocolName: RouterEpochProtocol
}

private struct RouterEpochObservation {
    let epoch: UInt32
    let wallTime: Date
    let monotonicUptime: TimeInterval
    let bootIdentifier: String
}

private struct RouterEpochProbeResult {
    let epoch: UInt32
    let wallTime: Date
    let monotonicUptime: TimeInterval
    let bootIdentifier: String
    let resetDetected: Bool
    var effectiveClientAddress: String? = nil
}

private final class RouterEpochTracker {
    private static let persistedWallClockTolerance: TimeInterval = 5
    private let lock = NSLock()
    private var observations: [RouterEpochKey: RouterEpochObservation] = [:]
    private var pendingResets: Set<RouterEpochKey> = []
    private var seededKeys: Set<RouterEpochKey> = []

    func seed(
        key: RouterEpochKey,
        epoch: UInt32,
        wallTime: Date,
        monotonicUptime: TimeInterval?,
        bootIdentifier: String?,
        currentWallTime: Date,
        currentMonotonicUptime: TimeInterval,
        currentBootIdentifier: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard seededKeys.insert(key).inserted else { return }
        guard let monotonicUptime,
              let bootIdentifier,
              bootIdentifier == currentBootIdentifier,
              monotonicUptime >= 0,
              monotonicUptime <= currentMonotonicUptime else {
            pendingResets.insert(key)
            return
        }
        let persisted = RouterEpochObservation(
            epoch: epoch,
            wallTime: wallTime,
            monotonicUptime: monotonicUptime,
            bootIdentifier: bootIdentifier
        )
        let monotonicElapsed = currentMonotonicUptime - monotonicUptime
        let wallElapsed = currentWallTime.timeIntervalSince(wallTime)
        guard wallElapsed >= 0,
              abs(wallElapsed - monotonicElapsed)
                <= Self.persistedWallClockTolerance else {
            pendingResets.insert(key)
            return
        }
        if let current = observations[key] {
            if indicatesReset(
                protocolName: key.protocolName,
                previous: persisted,
                current: current
            ) {
                pendingResets.insert(key)
            }
        } else {
            observations[key] = persisted
        }
    }

    func observe(
        key: RouterEpochKey,
        epoch: UInt32,
        wallTime: Date,
        monotonicUptime: TimeInterval,
        bootIdentifier: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = observations[key]
        let current = RouterEpochObservation(
            epoch: epoch,
            wallTime: wallTime,
            monotonicUptime: monotonicUptime,
            bootIdentifier: bootIdentifier
        )
        observations[key] = current
        guard let previous else { return false }
        let resetDetected = indicatesReset(
            protocolName: key.protocolName,
            previous: previous,
            current: current
        )
        if resetDetected {
            pendingResets.insert(key)
        }
        return resetDetected
    }

    private func indicatesReset(
        protocolName: RouterEpochProtocol,
        previous: RouterEpochObservation,
        current: RouterEpochObservation
    ) -> Bool {
        guard previous.bootIdentifier == current.bootIdentifier else {
            return true
        }
        let clientDelta = Int64(
            floor(
                current.monotonicUptime - previous.monotonicUptime
            )
        )
        guard clientDelta >= 0 else {
            return true
        }

        switch protocolName {
        case .pcp:
            let serverDelta = Int64(current.epoch) - Int64(previous.epoch)
            if serverDelta < -1 {
                return true
            } else if serverDelta < 0 {
                return false
            } else {
                return
                    clientDelta + 2 < serverDelta - serverDelta / 16
                    || serverDelta + 2 < clientDelta - clientDelta / 16
            }
        case .natPMP:
            let expected = Int64(previous.epoch) + clientDelta * 7 / 8
            return Int64(current.epoch) + 2 < expected
        }
    }

    func consumeReset(key: RouterEpochKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingResets.remove(key) != nil
    }

    func markResetPending(key: RouterEpochKey) {
        lock.lock()
        pendingResets.insert(key)
        lock.unlock()
    }

    func clearReset(key: RouterEpochKey) {
        lock.lock()
        pendingResets.remove(key)
        lock.unlock()
    }
}

struct RouterMappingRemovalAttempt {
    let mapping: ActiveRouterMapping
    let errorDescription: String?

    var succeeded: Bool {
        errorDescription == nil
    }
}

struct RouterMappingRemovalReport {
    let attempts: [RouterMappingRemovalAttempt]

    var remainingMappings: [ActiveRouterMapping] {
        attempts.filter { !$0.succeeded }.map(\.mapping)
    }

    var succeededMappings: [ActiveRouterMapping] {
        attempts.filter(\.succeeded).map(\.mapping)
    }

    var allSucceeded: Bool {
        attempts.allSatisfy(\.succeeded)
    }

    var failureDescription: String {
        attempts.compactMap { attempt in
            attempt.errorDescription.map {
                "\(attempt.mapping.addressFamily.displayName) \(attempt.mapping.transport.displayName): \($0)"
            }
        }.joined(separator: "\n")
    }
}

protocol RouterMappingServicing {
    func externalIPv4Address(gatewayAddress: String) throws -> String
    func externalIPv4AddressForAutomaticMapping(
        gatewayAddress: String
    ) throws -> String
    func ensureMapping(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult
    func ensureIPv6Pinhole(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult
    func renewMapping(
        config: AppConfig,
        mapping: ActiveRouterMapping
    ) throws -> PortMappingResult
    func removeMappings(_ mappings: [ActiveRouterMapping]) -> RouterMappingRemovalReport
    func removeLegacyMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> RouterMappingRemovalReport
    func verifyMappingsForCurrentCheck(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport
    func cancelCurrentOperations()
}

extension RouterMappingServicing {
    func externalIPv4AddressForAutomaticMapping(
        gatewayAddress: String
    ) throws -> String {
        try externalIPv4Address(gatewayAddress: gatewayAddress)
    }

    func cancelCurrentOperations() {}

    func renewMapping(
        config: AppConfig,
        mapping: ActiveRouterMapping
    ) throws -> PortMappingResult {
        if mapping.addressFamily == .ipv6 {
            return try ensureIPv6Pinhole(
                config: config,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress
            )
        }
        return try ensureMapping(
            config: config,
            localAddress: mapping.localAddress,
            gatewayAddress: mapping.gatewayAddress
        )
    }

    func verifyMappingsForCurrentCheck(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport {
        return RouterMappingEpochReport(
            refreshedMappings: mappings,
            invalidatedMappings: [],
            errors: []
        )
    }
}

final class RouterMappingService: RouterMappingServicing {
    private static let pcpInitialRetryInterval: TimeInterval = 3
    private static let pcpMaximumRetryInterval: TimeInterval = 1_024
    private static let upnpBootIDHeader = [
        "BOOTID", "UPNP", "ORG"
    ].joined(separator: ".")
    private static let upnpConfigIDHeader = [
        "CONFIGID", "UPNP", "ORG"
    ].joined(separator: ".")
    private static let natPMPProtocolRetryIntervals: [TimeInterval] = [
        0.25, 0.5, 1, 2, 4, 8, 16, 32, 64
    ]

    // Router control is always local. It must never follow a system or custom
    // proxy, which could leak private IGD requests or make discovery unusable.
    private let http = HTTPClient(useSystemProxy: false)
    private let upnpDiscoveryHandler: (() throws -> [UPnPService])?
    private let upnpDescriptionHandler: ((URL) throws -> Data)?
    private let soapRequestHandler: ((URL, String, String, String) throws -> HTTPResponse)?
    private let udpRequestHandler: ((Data, String, UInt16, TimeInterval) throws -> Data)?
    private let udpTransactionHandler: RouterMappingUDPTransactionHandler?
    private let ssdpSearchHandler: ((UPnPDiscoveryRequest) throws -> [Data])?
    private let removalHandler: ((ActiveRouterMapping) throws -> Void)?
    private let nowProvider: () -> Date
    private let monotonicUptimeProvider: () -> TimeInterval
    private let bootIdentifierProvider: () -> String
    private let cancellationHandler: () -> Bool
    private let retryRandomizationProvider: () -> Double
    private let natPMPRebuildRandomizationProvider: () -> Double
    private let rebuildDelayScheduler:
        (TimeInterval, () -> Bool) throws -> Void
    private let retryPolicy: RouterMappingRetryPolicy
    private let epochHealthInterval: TimeInterval
    private let routerControlPort: UInt16
    private let socketOperations: RouterMappingUDPSocketOperations
    private let epochTracker = RouterEpochTracker()
    private let operationCancellationLock = NSLock()
    private var operationCancellationGeneration: UInt64 = 0
    private var operationContextKey: String {
        "Gatebeam.RouterMappingOperation.\(ObjectIdentifier(self))"
    }

    func cancelCurrentOperations() {
        operationCancellationLock.lock()
        operationCancellationGeneration &+= 1
        operationCancellationLock.unlock()
    }

    private func cancellationGeneration() -> UInt64 {
        operationCancellationLock.lock()
        defer { operationCancellationLock.unlock() }
        return operationCancellationGeneration
    }

    private func operationWasCancelled(since generation: UInt64) -> Bool {
        operationCancellationLock.lock()
        defer { operationCancellationLock.unlock() }
        return operationCancellationGeneration != generation
            || cancellationHandler()
    }

    private func withOperation<T>(
        absoluteDeadlineUptime: TimeInterval? = nil,
        _ body: () throws -> T
    ) throws -> T {
        if currentOperationContext != nil {
            try checkOperation()
            let result = try body()
            try checkOperation()
            return result
        }
        let context = RouterMappingOperationContext(
            cancellationGeneration: cancellationGeneration(),
            absoluteDeadlineUptime: absoluteDeadlineUptime
        )
        Thread.current.threadDictionary[operationContextKey] = context
        defer {
            Thread.current.threadDictionary.removeObject(
                forKey: operationContextKey
            )
        }
        try checkOperation(context)
        let result = try body()
        try checkOperation(context)
        return result
    }

    private var currentOperationContext: RouterMappingOperationContext? {
        Thread.current.threadDictionary[operationContextKey]
            as? RouterMappingOperationContext
    }

    private func operationShouldStop(
        _ context: RouterMappingOperationContext? = nil
    ) -> Bool {
        guard let context = context ?? currentOperationContext else {
            return cancellationHandler()
        }
        if operationWasCancelled(
            since: context.cancellationGeneration
        ) {
            return true
        }
        if let deadline = context.absoluteDeadlineUptime,
           monotonicUptimeProvider() >= deadline {
            return true
        }
        return false
    }

    private func checkOperation(
        _ context: RouterMappingOperationContext? = nil
    ) throws {
        guard let context = context ?? currentOperationContext else {
            if cancellationHandler() {
                throw RouterMappingError.cancelled
            }
            return
        }
        if operationWasCancelled(
            since: context.cancellationGeneration
        ) {
            throw RouterMappingError.cancelled
        }
        if let deadline = context.absoluteDeadlineUptime,
           monotonicUptimeProvider() >= deadline {
            throw RouterMappingError.protocolFailure(
                "Router renewal reached its monotonic safety deadline"
            )
        }
    }

    init(
        upnpDiscoveryHandler: (() throws -> [UPnPService])? = nil,
        upnpDescriptionHandler: ((URL) throws -> Data)? = nil,
        soapRequestHandler: ((URL, String, String, String) throws -> HTTPResponse)? = nil,
        udpRequestHandler: ((Data, String, UInt16, TimeInterval) throws -> Data)? = nil,
        udpTransactionHandler: RouterMappingUDPTransactionHandler? = nil,
        ssdpSearchHandler: ((UPnPDiscoveryRequest) throws -> [Data])? = nil,
        removalHandler: ((ActiveRouterMapping) throws -> Void)? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        monotonicUptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        bootIdentifierProvider: @escaping () -> String = {
            RouterMappingService.systemBootIdentifier
        },
        cancellationHandler: @escaping () -> Bool = {
            Thread.current.isCancelled
                || withUnsafeCurrentTask { task in task?.isCancelled ?? false }
        },
        retryRandomizationProvider: @escaping () -> Double = {
            Double.random(in: -0.1 ... 0.1)
        },
        natPMPRebuildRandomizationProvider: @escaping () -> Double = {
            Double.random(in: 0 ... 1)
        },
        rebuildDelayScheduler:
            @escaping (TimeInterval, () -> Bool) throws -> Void =
                RouterMappingService.waitForRebuildDelay,
        retryPolicy: RouterMappingRetryPolicy = .protocolDefault,
        epochHealthInterval: TimeInterval = 60,
        routerControlPort: UInt16 = 5351,
        socketOperations: RouterMappingUDPSocketOperations = .system
    ) {
        self.upnpDiscoveryHandler = upnpDiscoveryHandler
        self.upnpDescriptionHandler = upnpDescriptionHandler
        self.soapRequestHandler = soapRequestHandler
        self.udpRequestHandler = udpRequestHandler
        self.udpTransactionHandler = udpTransactionHandler
        self.ssdpSearchHandler = ssdpSearchHandler
        self.removalHandler = removalHandler
        self.nowProvider = nowProvider
        self.monotonicUptimeProvider = monotonicUptimeProvider
        self.bootIdentifierProvider = bootIdentifierProvider
        self.cancellationHandler = cancellationHandler
        self.retryRandomizationProvider = retryRandomizationProvider
        self.natPMPRebuildRandomizationProvider =
            natPMPRebuildRandomizationProvider
        self.rebuildDelayScheduler = rebuildDelayScheduler
        self.retryPolicy = retryPolicy
        self.epochHealthInterval = max(1, epochHealthInterval)
        self.routerControlPort = routerControlPort
        self.socketOperations = socketOperations
    }

    static let systemBootIdentifier: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else {
            return "unavailable-\(ProcessInfo.processInfo.globallyUniqueString)"
        }
        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(
                "kern.bootsessionuuid",
                bytes.baseAddress,
                &size,
                nil,
                0
            )
        }
        guard status == 0 else {
            return "unavailable-\(ProcessInfo.processInfo.globallyUniqueString)"
        }
        return String(cString: buffer)
    }()

    private static func waitForRebuildDelay(
        _ duration: TimeInterval,
        cancellationHandler: () -> Bool
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
        repeat {
            if cancellationHandler() {
                throw RouterMappingError.cancelled
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                return
            }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        } while true
    }

    static func renewableUPnPLeaseSeconds(requested: UInt32, minimum: UInt32 = 60) -> UInt32 {
        min(max(requested, minimum), 86_400)
    }

    func externalIPv4Address(gatewayAddress: String) throws -> String {
        try withOperation {
            do {
                return try queryNATPMPExternalAddress(
                    gatewayAddress: gatewayAddress
                ).address
            } catch RouterMappingError.cancelled {
                throw RouterMappingError.cancelled
            } catch {
                let service = try discoverUPnPService(
                    gatewayAddress: gatewayAddress
                )
                return try queryUPnPExternalAddress(service: service)
            }
        }
    }

    func externalIPv4AddressForAutomaticMapping(
        gatewayAddress: String
    ) throws -> String {
        try withOperation {
            do {
                return try queryNATPMPExternalAddress(
                    gatewayAddress: gatewayAddress,
                    retryIntervals: retryPolicy
                        .normalizedAutomaticCapabilityProbeIntervals
                ).address
            } catch RouterMappingError.cancelled {
                throw RouterMappingError.cancelled
            } catch {
                let service = try discoverUPnPService(
                    gatewayAddress: gatewayAddress
                )
                return try queryUPnPExternalAddress(service: service)
            }
        }
    }

    func inspectCapabilities(gatewayAddress: String) throws -> RouterCapabilityResult {
        try withOperation {
            try inspectCapabilitiesInOperation(
                gatewayAddress: gatewayAddress
            )
        }
    }

    private func inspectCapabilitiesInOperation(
        gatewayAddress: String
    ) throws -> RouterCapabilityResult {
        var natPMPAvailable = false
        var upnpAvailable = false
        var externalAddress: String?
        var errors: [String] = []

        do {
            externalAddress = try queryNATPMPExternalAddress(
                gatewayAddress: gatewayAddress
            ).address
            natPMPAvailable = true
        } catch {
            errors.append("NAT-PMP: \(error.localizedDescription)")
        }

        do {
            let service = try discoverUPnPService(gatewayAddress: gatewayAddress)
            upnpAvailable = true
            if externalAddress == nil {
                externalAddress = try? queryUPnPExternalAddress(service: service)
            }
        } catch {
            errors.append("UPnP: \(error.localizedDescription)")
        }

        guard natPMPAvailable || upnpAvailable else {
            throw RouterMappingError.allProtocolsFailed(errors.joined(separator: "\n"))
        }
        return RouterCapabilityResult(
            natPMPAvailable: natPMPAvailable,
            upnpAvailable: upnpAvailable,
            routerExternalAddress: externalAddress
        )
    }

    func verifyMappingsForCurrentCheck(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport {
        try withOperation {
            try verifyMappingsForCurrentCheckInOperation(mappings)
        }
    }

    func refreshMappingEpochs(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport {
        try verifyMappingsForCurrentCheck(mappings)
    }

    private func verifyMappingsForCurrentCheckInOperation(
        _ mappings: [ActiveRouterMapping]
    ) throws -> RouterMappingEpochReport {
        guard let operationContext = currentOperationContext else {
            throw RouterMappingError.cancelled
        }
        var refreshed: [ActiveRouterMapping] = []
        var invalidations: [RouterMappingInvalidation] = []
        var errors: [String] = []
        var currentCheckProofs: [RouterMappingCurrentCheckProof] = []
        var natPMPGatewaysRequiringDelay: Set<String> = []

        for mapping in mappings {
            if mapping.transport == .upnp {
                do {
                    let verification = try verifyUPnPMappingForCurrentCheck(
                        mapping
                    )
                    refreshed.append(verification.mapping)
                    currentCheckProofs.append(verification.proof)
                } catch RouterMappingError.cancelled {
                    throw RouterMappingError.cancelled
                } catch {
                    refreshed.append(mapping)
                    errors.append(
                        "UPnP \(mapping.gatewayAddress): "
                            + error.localizedDescription
                    )
                }
                continue
            }
            let key = epochKey(
                protocolName: mapping.transport == .pcp ? .pcp : .natPMP,
                gatewayAddress: mapping.gatewayAddress,
                clientAddress: mapping.localAddress
            )
            if let epoch = mapping.routerEpoch,
               let observedAt = mapping.routerEpochObservedAt {
                let currentWallTime = nowProvider()
                let currentUptime = monotonicUptimeProvider()
                let currentBootIdentifier = bootIdentifierProvider()
                epochTracker.seed(
                    key: key,
                    epoch: epoch,
                    wallTime: observedAt,
                    monotonicUptime: mapping.routerEpochObservedUptime,
                    bootIdentifier: mapping.routerEpochBootIdentifier,
                    currentWallTime: currentWallTime,
                    currentMonotonicUptime: currentUptime,
                    currentBootIdentifier: currentBootIdentifier
                )
            } else {
                epochTracker.markResetPending(key: key)
            }

            do {
                let observation: RouterEpochProbeResult
                var observedWANAddress: String?
                switch mapping.transport {
                case .pcp:
                    observation = try probePCP(
                        localAddress: mapping.localAddress,
                        gatewayAddress: mapping.gatewayAddress,
                        retryIntervals:
                            retryPolicy.normalizedEpochHealthProbeIntervals,
                        consumeEpochReset: true
                    )
                case .natpmp:
                    let response = try queryNATPMPExternalAddress(
                        gatewayAddress: mapping.gatewayAddress,
                        retryIntervals:
                            retryPolicy.normalizedEpochHealthProbeIntervals,
                        sourceAddressHint: mapping.localAddress,
                        consumeEpochReset: true
                    )
                    observation = response.epochObservation
                    observedWANAddress = response.address
                case .upnp:
                    continue
                }
                let effectiveIdentityChanged =
                    observation.effectiveClientAddress
                        != mapping.localAddress
                if effectiveIdentityChanged {
                    invalidations.append(
                        RouterMappingInvalidation(
                            mapping: mapping,
                            reason: .effectiveClientAddressChanged(
                                replacementAddress:
                                    observation.effectiveClientAddress ?? ""
                            )
                        )
                    )
                } else if observation.resetDetected {
                    invalidations.append(
                        RouterMappingInvalidation(
                            mapping: mapping,
                            reason: .routerStateLost
                        )
                    )
                    if mapping.transport == .natpmp {
                        natPMPGatewaysRequiringDelay.insert(
                            epochKey(
                                protocolName: .natPMP,
                                gatewayAddress: mapping.gatewayAddress,
                                clientAddress: mapping.localAddress
                            ).gatewayAddress
                        )
                    }
                } else {
                    var updated = mapping
                    if updated.recoveryState
                        == .effectiveClientAddressChanged {
                        updated.recoveryState = nil
                        updated.replacementLocalAddress = nil
                    }
                    updated.routerEpoch = observation.epoch
                    updated.routerEpochObservedAt = observation.wallTime
                    updated.routerEpochObservedUptime =
                        observation.monotonicUptime
                    updated.routerEpochBootIdentifier =
                        observation.bootIdentifier
                    updated.routerEpochHealthCheckAfter =
                        observation.wallTime.addingTimeInterval(
                            epochHealthInterval
                        )
                    updated.routerEpochHealthCheckUptime =
                        observation.monotonicUptime + epochHealthInterval
                    if let observedWANAddress {
                        updated.routerExternalAddress =
                            observedWANAddress
                    }
                    refreshed.append(updated)
                    if let proof = makeCurrentCheckProof(
                        mapping: updated
                    ) {
                        currentCheckProofs.append(proof)
                    }
                }
            } catch RouterMappingError.cancelled {
                throw RouterMappingError.cancelled
            } catch let error as RouterMappingUDPError {
                if case .cancelled = error.underlying {
                    throw RouterMappingError.cancelled
                }
                refreshed.append(mapping)
                errors.append(
                    "\(mapping.transport.displayName) \(mapping.gatewayAddress): "
                        + error.localizedDescription
                )
            } catch {
                refreshed.append(mapping)
                errors.append(
                    "\(mapping.transport.displayName) \(mapping.gatewayAddress): "
                        + error.localizedDescription
                )
            }
        }
        for _ in natPMPGatewaysRequiringDelay.sorted() {
            let sample = min(
                1,
                max(0, natPMPRebuildRandomizationProvider())
            )
            try throwIfCancelled()
            try rebuildDelayScheduler(5 * sample) { [self] in
                operationShouldStop(operationContext)
            }
            try throwIfCancelled()
        }
        return RouterMappingEpochReport(
            refreshedMappings: refreshed,
            invalidations: invalidations,
            errors: errors,
            currentCheckProofs: currentCheckProofs
        )
    }

    func ensureMapping(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult {
        try withOperation {
            try ensureMappingInOperation(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress
            )
        }
    }

    private func ensureMappingInOperation(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        switch config.mappingProtocolPreference {
        case .disabled:
            throw RouterMappingError.disabled
        case .pcp:
            return try addPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, familyName: "IPv4")
        case .natpmp:
            return try addNATPMPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress)
        case .upnp:
            return try addUPnPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress)
        case .automatic:
            return try Self.firstSuccessfulAutomaticMapping([
                ("PCP", {
                    _ = try self.probePCP(
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        retryIntervals: self.retryPolicy
                            .normalizedAutomaticCapabilityProbeIntervals
                    )
                    return try self.addPCPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        familyName: "IPv4",
                        retryIntervals: self.pcpRetryIntervals()
                    )
                }),
                ("NAT-PMP", {
                    let externalAddress = try self.queryNATPMPExternalAddress(
                        gatewayAddress: gatewayAddress,
                        retryIntervals: self.retryPolicy
                            .normalizedAutomaticCapabilityProbeIntervals
                    )
                    return try self.addNATPMPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        retryIntervals: self.natPMPRetryIntervals(),
                        knownExternalAddress: externalAddress,
                        expectedClientAddress:
                            externalAddress.effectiveClientAddress
                    )
                }),
                ("UPnP", {
                    try self.addUPnPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
                    )
                })
            ])
        }
    }

    func ensureIPv6Pinhole(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult {
        try withOperation {
            try ensureIPv6PinholeInOperation(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress
            )
        }
    }

    private func ensureIPv6PinholeInOperation(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        switch config.mappingProtocolPreference {
        case .disabled:
            throw RouterMappingError.disabled
        case .natpmp:
            throw RouterMappingError.protocolFailure("NAT-PMP does not support IPv6; choose Auto, PCP, or UPnP")
        case .pcp:
            return try addPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, familyName: "IPv6")
        case .upnp:
            return try addUPnPIPv6Pinhole(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress)
        case .automatic:
            return try Self.firstSuccessfulAutomaticMapping([
                ("PCP", {
                    _ = try self.probePCP(
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        retryIntervals: self.retryPolicy
                            .normalizedAutomaticCapabilityProbeIntervals
                    )
                    return try self.addPCPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        familyName: "IPv6",
                        retryIntervals: self.pcpRetryIntervals()
                    )
                }),
                ("UPnP IPv6", {
                    try self.addUPnPIPv6Pinhole(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
                    )
                })
            ])
        }
    }

    func renewMapping(
        config: AppConfig,
        mapping: ActiveRouterMapping
    ) throws -> PortMappingResult {
        let deadline = try renewalAbsoluteDeadline(for: mapping)
        return try withOperation(
            absoluteDeadlineUptime: deadline
        ) {
            try renewMappingInOperation(
                config: config,
                mapping: mapping
            )
        }
    }

    private func renewMappingInOperation(
        config: AppConfig,
        mapping: ActiveRouterMapping
    ) throws -> PortMappingResult {
        var renewalConfig = config
        renewalConfig.mappingProtocolPreference = mapping.transport.preference
        renewalConfig.externalPort = mapping.externalPort
        renewalConfig.pcpNonce = mapping.pcpNonce ?? config.pcpNonce
        renewalConfig.ipv6PinholeID = mapping.pinholeID
        if mapping.transport == .pcp {
            let boundedRetryIntervals = try renewalRetryIntervals(
                for: mapping
            )
            return try addPCPMapping(
                config: renewalConfig,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                familyName: mapping.addressFamily.displayName,
                retryIntervals: boundedRetryIntervals,
                expectedClientAddress: mapping.localAddress
            )
        }
        if mapping.transport == .natpmp {
            let boundedRetryIntervals = try renewalRetryIntervals(
                for: mapping
            )
            return try addNATPMPMapping(
                config: renewalConfig,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                retryIntervals: boundedRetryIntervals,
                expectedClientAddress: mapping.localAddress
            )
        }
        let expectedService: UPnPServiceRole =
            mapping.addressFamily == .ipv6
                ? .ipv6Firewall
                : .ipv4PortMapping
        let service: UPnPService
        do {
            service = try boundUPnPService(
                for: mapping,
                expectedService: expectedService
            )
        } catch RouterMappingError.cancelled {
            throw RouterMappingError.cancelled
        } catch {
            var recovery = mapping
            recovery.recoveryState = .upnpIdentityChanged
            throw RouterMappingRecoveryRequiredError(
                mapping: recovery,
                operationDescription:
                    "The original UPnP IGD identity could not be verified, "
                        + "so no renewal or replacement request was sent.",
                cleanupDescription:
                    "\(error.localizedDescription) Gatebeam will retain the "
                        + "original mapping identity until exact cleanup is "
                        + "confirmed or its monotonic lease expires."
            )
        }
        if mapping.addressFamily == .ipv6 {
            return try addUPnPIPv6Pinhole(
                config: renewalConfig,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                boundService: service,
                protocolState: mapping.pcpNonce
            )
        }
        return try addUPnPMapping(
            config: renewalConfig,
            localAddress: mapping.localAddress,
            gatewayAddress: mapping.gatewayAddress,
            boundService: service,
            protocolState: mapping.pcpNonce
        )
    }

    private func renewalAbsoluteDeadline(
        for mapping: ActiveRouterMapping
    ) throws -> TimeInterval {
        let nowUptime = monotonicUptimeProvider()
        let expiryUptime: TimeInterval
        if mapping.leaseBootIdentifier == bootIdentifierProvider(),
           let persisted = mapping.leaseExpiresUptime {
            expiryUptime = persisted
        } else {
            expiryUptime = nowUptime
                + max(
                    0,
                    mapping.leaseExpiresAt.timeIntervalSince(
                        nowProvider()
                    )
                )
        }
        let deadline = expiryUptime - 0.25
        guard nowUptime < deadline else {
            throw RouterMappingError.protocolFailure(
                "\(mapping.transport.displayName) lease expired before renewal could start"
            )
        }
        return deadline
    }

    private func renewalRetryIntervals(
        for mapping: ActiveRouterMapping
    ) throws -> [TimeInterval] {
        let protocolIntervals = mapping.transport == .pcp
            ? pcpRetryIntervals()
            : natPMPRetryIntervals()
        let nowUptime = monotonicUptimeProvider()
        guard let deadline =
                currentOperationContext?.absoluteDeadlineUptime else {
            throw RouterMappingError.protocolFailure(
                "Router renewal has no absolute monotonic deadline"
            )
        }
        var budget = max(0, deadline - nowUptime)
        guard budget >= 0.001 else {
            throw RouterMappingError.protocolFailure(
                "\(mapping.transport.displayName) lease expired before renewal could start"
            )
        }
        var bounded: [TimeInterval] = []
        for interval in protocolIntervals where budget > 0 {
            let next = min(interval, budget)
            guard next >= 0.001 else { break }
            bounded.append(next)
            budget -= next
        }
        return bounded
    }

    static func firstSuccessfulAutomaticMapping(
        _ attempts: [(String, () throws -> PortMappingResult)]
    ) throws -> PortMappingResult {
        var errors: [String] = []
        for (name, attempt) in attempts {
            do {
                return try attempt()
            } catch let recovery as RouterMappingRecoveryRequiredError {
                throw recovery
            } catch RouterMappingError.cancelled {
                throw RouterMappingError.cancelled
            } catch let transportError as RouterMappingUDPError {
                if case .cancelled = transportError.underlying {
                    throw RouterMappingError.cancelled
                }
                errors.append("\(name): \(transportError.localizedDescription)")
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        throw RouterMappingError.allProtocolsFailed(errors.joined(separator: "\n"))
    }

    func removeMappings(_ mappings: [ActiveRouterMapping]) -> RouterMappingRemovalReport {
        do {
            return try withOperation {
                RouterMappingRemovalReport(
                    attempts: mappings.map { mapping in
                        do {
                            try checkOperation()
                            try removeMapping(mapping)
                            try checkOperation()
                            return RouterMappingRemovalAttempt(
                                mapping: mapping,
                                errorDescription: nil
                            )
                        } catch {
                            return RouterMappingRemovalAttempt(
                                mapping: mapping,
                                errorDescription:
                                    error.localizedDescription
                            )
                        }
                    }
                )
            }
        } catch {
            return RouterMappingRemovalReport(
                attempts: mappings.map {
                    RouterMappingRemovalAttempt(
                        mapping: $0,
                        errorDescription: error.localizedDescription
                    )
                }
            )
        }
    }

    func removeLegacyMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> RouterMappingRemovalReport {
        var completedReport: RouterMappingRemovalReport?
        do {
            return try withOperation {
                let report = removeLegacyMappingsInOperation(
                    config: config,
                    localIPv4: localIPv4,
                    gatewayIPv4: gatewayIPv4,
                    localIPv6: localIPv6,
                    gatewayIPv6: gatewayIPv6
                )
                completedReport = report
                return report
            }
        } catch {
            return completedReport
                ?? RouterMappingRemovalReport(attempts: [])
        }
    }

    private func removeLegacyMappingsInOperation(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> RouterMappingRemovalReport {
        var attempts: [RouterMappingRemovalAttempt] = []

        func append(_ next: [RouterMappingRemovalAttempt]) {
            attempts.append(contentsOf: next)
        }

        if config.preferredAddressFamily.usesIPv4,
           let localIPv4,
           let gatewayIPv4 {
            let next: [RouterMappingRemovalAttempt]
            switch config.mappingProtocolPreference {
            case .automatic:
                next = removeLegacyAutomaticIPv4Mappings(
                    config: config,
                    localAddress: localIPv4,
                    gatewayAddress: gatewayIPv4
                )
            case .pcp, .natpmp:
                let transport: RouterMappingTransport =
                    config.mappingProtocolPreference == .pcp ? .pcp : .natpmp
                next = [
                    removeLegacyMapping(
                        legacyMapping(
                            config: config,
                            transport: transport,
                            family: .ipv4,
                            localAddress: localIPv4,
                            gatewayAddress: gatewayIPv4
                        )
                    )
                ]
            case .upnp:
                next = removeLegacyUPnPIPv4Mapping(
                    config: config,
                    localAddress: localIPv4,
                    gatewayAddress: gatewayIPv4
                ).map { [$0] } ?? []
            case .disabled:
                next = []
            }
            append(next)
        }

        if config.preferredAddressFamily.usesIPv6,
           let localIPv6,
           let gatewayIPv6 {
            append(
                removeLegacyIPv6Mappings(
                    config: config,
                    localAddress: localIPv6,
                    gatewayAddress: gatewayIPv6
                )
            )
        }

        return RouterMappingRemovalReport(attempts: attempts)
    }

    private func removeLegacyAutomaticIPv4Mappings(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) -> [RouterMappingRemovalAttempt] {
        var attempts: [RouterMappingRemovalAttempt] = []
        for transport in [RouterMappingTransport.pcp, .natpmp] {
            let mapping = legacyMapping(
                config: config,
                transport: transport,
                family: .ipv4,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress
            )
            do {
                try removeMapping(mapping)
                attempts.append(
                    RouterMappingRemovalAttempt(mapping: mapping, errorDescription: nil)
                )
            } catch {
                if Self.isConclusiveLegacyUnsupported(error, transport: transport) {
                    continue
                }
                attempts.append(
                    RouterMappingRemovalAttempt(
                        mapping: mapping,
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }

        if let upnpAttempt = removeLegacyUPnPIPv4Mapping(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        ) {
            attempts.append(upnpAttempt)
        }
        return attempts
    }

    private func removeLegacyIPv6Mappings(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) -> [RouterMappingRemovalAttempt] {
        switch config.mappingProtocolPreference {
        case .automatic:
            var attempts: [RouterMappingRemovalAttempt] = []
            let pcp = legacyMapping(
                config: config,
                transport: .pcp,
                family: .ipv6,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress
            )
            do {
                try removeMapping(pcp)
                attempts.append(
                    RouterMappingRemovalAttempt(mapping: pcp, errorDescription: nil)
                )
            } catch {
                if !Self.isConclusiveLegacyUnsupported(error, transport: .pcp) {
                    attempts.append(
                        RouterMappingRemovalAttempt(
                            mapping: pcp,
                            errorDescription: error.localizedDescription
                        )
                    )
                }
            }
            guard config.ipv6PinholeID != nil else {
                return attempts
            }
            attempts.append(
                RouterMappingRemovalAttempt(
                    mapping: legacyMapping(
                        config: config,
                        transport: .upnp,
                        family: .ipv6,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
                    ),
                    errorDescription:
                        "The legacy UPnP IPv6 pinhole has no verifiable IGD identity. "
                            + "Wait for its router lease to expire or remove it in the original router before continuing."
                )
            )
            return attempts
        case .pcp:
            return [
                removeLegacyMapping(
                    legacyMapping(
                        config: config,
                        transport: .pcp,
                        family: .ipv6,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
                    )
                )
            ]
        case .natpmp, .disabled:
            return []
        case .upnp:
            guard config.ipv6PinholeID != nil else {
                return []
            }
            return [
                RouterMappingRemovalAttempt(
                    mapping: legacyMapping(
                        config: config,
                        transport: .upnp,
                        family: .ipv6,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
                    ),
                    errorDescription:
                        "The legacy UPnP IPv6 pinhole has no verifiable IGD identity. "
                            + "Wait for its router lease to expire or remove it in the original router before continuing."
                )
            ]
        }
    }

    private func removeLegacyUPnPIPv4Mapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) -> RouterMappingRemovalAttempt? {
        let unbound = legacyMapping(
            config: config,
            transport: .upnp,
            family: .ipv4,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        )
        let service: UPnPService
        do {
            service = try discoverUPnPService(gatewayAddress: gatewayAddress)
        } catch {
            return RouterMappingRemovalAttempt(
                mapping: unbound,
                errorDescription:
                    "The original UPnP IGD could not be discovered, so its legacy rule could not be verified: "
                        + error.localizedDescription
            )
        }

        let binding: String
        do {
            binding = try UPnPControlBinding(
                service: service,
                gatewayAddress: gatewayAddress
            ).encoded()
        } catch {
            return RouterMappingRemovalAttempt(
                mapping: unbound,
                errorDescription: error.localizedDescription
            )
        }
        let candidate = activeMapping(
            config: config,
            transport: .upnp,
            family: .ipv4,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            externalPort: config.externalPort,
            lifetime: 1,
            protocolState: binding
        )
        let values: [String: String]
        do {
            values = try querySpecificUPnPMapping(
                externalPort: config.externalPort,
                service: service
            )
        } catch let error as RouterMappingError where error.isMissingIPv4UPnPMapping {
            return nil
        } catch {
            return RouterMappingRemovalAttempt(
                mapping: candidate,
                errorDescription:
                    "The legacy UPnP rule could not be verified on the original IGD: "
                        + error.localizedDescription
            )
        }

        do {
            try validateUPnPIPv4Mapping(values, matches: candidate)
        } catch {
            return RouterMappingRemovalAttempt(
                mapping: candidate,
                errorDescription: error.localizedDescription
            )
        }
        return removeLegacyMapping(candidate)
    }

    private func removeLegacyMapping(
        _ mapping: ActiveRouterMapping
    ) -> RouterMappingRemovalAttempt {
        do {
            try removeMapping(mapping)
            return RouterMappingRemovalAttempt(mapping: mapping, errorDescription: nil)
        } catch {
            return RouterMappingRemovalAttempt(
                mapping: mapping,
                errorDescription: error.localizedDescription
            )
        }
    }

    private static func isConclusiveLegacyUnsupported(
        _ error: Error,
        transport: RouterMappingTransport
    ) -> Bool {
        guard let mappingError = error as? RouterMappingError else {
            return false
        }
        switch (transport, mappingError) {
        case (.pcp, .pcpResultCode(let code)):
            return [1, 4, 9].contains(code)
        case (.natpmp, .natPMPResultCode(let code)):
            return [1, 5].contains(code)
        default:
            return false
        }
    }

    private func validateUPnPIPv4Mapping(
        _ values: [String: String],
        matches mapping: ActiveRouterMapping
    ) throws {
        let acceptedDescriptions = ["Gatebeam", "Remote Control Network"]
        let echoedExternalPortMatches = values["NewExternalPort"].map {
            $0 == String(mapping.externalPort)
        } ?? true
        let echoedProtocolMatches = values["NewProtocol"].map {
            $0.caseInsensitiveCompare("TCP") == .orderedSame
        } ?? true
        guard echoedExternalPortMatches,
              echoedProtocolMatches,
              values["NewInternalClient"] == mapping.localAddress,
              values["NewInternalPort"] == String(mapping.internalPort),
              values["NewEnabled"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              values["NewPortMappingDescription"].map(acceptedDescriptions.contains) == true else {
            throw RouterMappingError.protocolFailure(
                "A UPnP rule exists on the original gateway, but its external port, protocol, "
                    + "client, internal port, enabled state, or Gatebeam description does not "
                    + "exactly match. Refusing to delete it automatically."
            )
        }
    }

    private func removeMapping(_ mapping: ActiveRouterMapping) throws {
        if let removalHandler {
            try checkOperation()
            try removalHandler(mapping)
            try checkOperation()
            return
        }
        if mappingLeaseDefinitelyExpiredForCleanup(mapping) {
            return
        }
        var config = AppConfig.default
        config.internalPort = mapping.internalPort
        config.externalPort = mapping.externalPort
        config.pcpNonce = mapping.pcpNonce
        config.ipv6PinholeID = mapping.pinholeID

        switch (mapping.addressFamily, mapping.transport) {
        case (_, .pcp):
            _ = try sendPCPMapping(
                config: config,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                lifetime: 0,
                retryIntervals: [Self.pcpInitialRetryInterval],
                expectedClientAddress: mapping.localAddress
            )
        case (.ipv4, .natpmp):
            try validateNATPMPDeletionContinuity(mapping)
            _ = try sendNATPMPMapping(
                config: config,
                localAddress: mapping.localAddress,
                gatewayAddress: mapping.gatewayAddress,
                lifetime: 0,
                retryIntervals: [
                    Self.natPMPProtocolRetryIntervals[0]
                ],
                expectedClientAddress: mapping.localAddress
            )
        case (.ipv4, .upnp):
            let service = try boundUPnPService(for: mapping, expectedService: .ipv4PortMapping)
            let values: [String: String]
            do {
                values = try querySpecificUPnPMapping(
                    externalPort: mapping.externalPort,
                    service: service
                )
            } catch let error as RouterMappingError where error.isMissingIPv4UPnPMapping {
                return
            }
            try validateUPnPIPv4Mapping(values, matches: mapping)
            // UPnP IGD exposes no conditional delete operation. Another controller
            // can replace this port between the identity query and this delete.
            try deleteUPnPMapping(externalPort: mapping.externalPort, service: service)
        case (.ipv6, .upnp):
            guard let pinholeID = mapping.pinholeID else {
                let expired: Bool
                if mapping.leaseBootIdentifier
                        == bootIdentifierProvider(),
                   let deadline = mapping.leaseExpiresUptime {
                    expired = monotonicUptimeProvider() >= deadline
                } else {
                    expired = nowProvider() >= mapping.leaseExpiresAt
                }
                if expired {
                    return
                }
                throw RouterMappingError.protocolFailure("The tracked UPnP IPv6 pinhole has no ID")
            }
            let service = try boundUPnPService(for: mapping, expectedService: .ipv6Firewall)
            try deleteUPnPIPv6Pinhole(pinholeID: pinholeID, service: service)
        case (.ipv6, .natpmp):
            throw RouterMappingError.protocolFailure("NAT-PMP does not support IPv6")
        }
    }

    private func mappingLeaseDefinitelyExpiredForCleanup(
        _ mapping: ActiveRouterMapping
    ) -> Bool {
        let currentBoot = bootIdentifierProvider()
        let nowUptime = monotonicUptimeProvider()
        if let recoveryDeadline = mapping.recoverySafeAfterUptime {
            guard mapping.recoveryBootIdentifier == currentBoot else {
                return false
            }
            return nowUptime >= recoveryDeadline
        }
        guard mapping.leaseBootIdentifier == currentBoot,
              let leaseDeadline = mapping.leaseExpiresUptime else {
            return false
        }
        return nowUptime >= leaseDeadline
    }

    private func validateNATPMPDeletionContinuity(
        _ mapping: ActiveRouterMapping
    ) throws {
        let currentBoot = bootIdentifierProvider()
        let currentWall = nowProvider()
        let currentUptime = monotonicUptimeProvider()
        guard mapping.recoverySafeAfterUptime == nil,
              mapping.recoveryBootIdentifier == nil,
              let persistedEpoch = mapping.routerEpoch,
              let persistedWall = mapping.routerEpochObservedAt,
              let persistedUptime = mapping.routerEpochObservedUptime,
              let persistedBoot = mapping.routerEpochBootIdentifier,
              persistedBoot == currentBoot,
              persistedUptime >= 0,
              persistedUptime <= currentUptime else {
            throw RouterMappingError.protocolFailure(
                "NAT-PMP delete is waiting for the finite lease to expire "
                    + "because router Epoch continuity cannot be proven"
            )
        }
        let key = epochKey(
            protocolName: .natPMP,
            gatewayAddress: mapping.gatewayAddress,
            clientAddress: mapping.localAddress
        )
        epochTracker.seed(
            key: key,
            epoch: persistedEpoch,
            wallTime: persistedWall,
            monotonicUptime: persistedUptime,
            bootIdentifier: persistedBoot,
            currentWallTime: currentWall,
            currentMonotonicUptime: currentUptime,
            currentBootIdentifier: currentBoot
        )
        let probe = try queryNATPMPExternalAddress(
            gatewayAddress: mapping.gatewayAddress,
            retryIntervals:
                retryPolicy.normalizedEpochHealthProbeIntervals,
            sourceAddressHint: mapping.localAddress,
            consumeEpochReset: true
        )
        guard probe.effectiveClientAddress == mapping.localAddress else {
            throw RouterMappingError.protocolFailure(
                "NAT-PMP delete effective source changed from "
                    + "\(mapping.localAddress) to "
                    + "\(probe.effectiveClientAddress)"
            )
        }
        let elapsed = Int64(
            floor(
                probe.epochObservation.monotonicUptime
                    - persistedUptime
            )
        )
        let expectedLower =
            Int64(persistedEpoch) + elapsed * 7 / 8 - 2
        let expectedUpper =
            Int64(persistedEpoch) + elapsed * 9 / 8 + 2
        let currentEpoch = Int64(probe.epochTime)
        guard !probe.epochObservation.resetDetected,
              currentEpoch >= expectedLower,
              currentEpoch <= expectedUpper else {
            throw RouterMappingError.protocolFailure(
                "NAT-PMP delete was not sent because the router Epoch "
                    + "does not prove continuity with the tracked mapping"
            )
        }
    }

    private func legacyMapping(
        config: AppConfig,
        transport: RouterMappingTransport,
        family: RouterMappingAddressFamily,
        localAddress: String,
        gatewayAddress: String
    ) -> ActiveRouterMapping {
        ActiveRouterMapping(
            transport: transport,
            addressFamily: family,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            internalPort: config.internalPort,
            externalPort: family == .ipv6 && transport == .upnp
                ? config.internalPort
                : config.externalPort,
            pinholeID: family == .ipv6 ? config.ipv6PinholeID : nil,
            pcpNonce: transport == .pcp ? config.pcpNonce : nil,
            leaseExpiresAt: .distantFuture,
            renewAfter: .distantFuture
        )
    }

    private func activeMapping(
        config: AppConfig,
        transport: RouterMappingTransport,
        family: RouterMappingAddressFamily,
        localAddress: String,
        gatewayAddress: String,
        externalPort: UInt16,
        lifetime: UInt32,
        routerExternalAddress: String? = nil,
        pinholeID: UInt16? = nil,
        protocolState: String? = nil,
        routerEpoch: UInt32? = nil,
        routerEpochObservedAt: Date? = nil,
        routerEpochObservedUptime: TimeInterval? = nil,
        routerEpochBootIdentifier: String? = nil
    ) -> ActiveRouterMapping {
        let now = nowProvider()
        let effectiveLifetime = max(1, lifetime)
        let expiresAt = now.addingTimeInterval(TimeInterval(effectiveLifetime))
        let nowUptime = monotonicUptimeProvider()
        let bootIdentifier = bootIdentifierProvider()
        let renewalLead = min(
            TimeInterval(effectiveLifetime) / 2,
            max(60, TimeInterval(effectiveLifetime) / 4)
        )
        return ActiveRouterMapping(
            transport: transport,
            addressFamily: family,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            internalPort: config.internalPort,
            externalPort: externalPort,
            routerExternalAddress: routerExternalAddress,
            pinholeID: pinholeID,
            pcpNonce: protocolState ?? (transport == .pcp ? config.pcpNonce : nil),
            leaseExpiresAt: expiresAt,
            renewAfter: expiresAt.addingTimeInterval(-renewalLead),
            routerEpoch: routerEpoch,
            routerEpochObservedAt: routerEpochObservedAt,
            routerEpochObservedUptime: routerEpochObservedUptime,
            routerEpochBootIdentifier: routerEpochBootIdentifier,
            routerEpochHealthCheckAfter: routerEpoch.map { _ in
                (routerEpochObservedAt ?? now).addingTimeInterval(
                    epochHealthInterval
                )
            },
            routerEpochHealthCheckUptime: routerEpoch.map { _ in
                (routerEpochObservedUptime ?? nowUptime)
                    + epochHealthInterval
            },
            leaseExpiresUptime:
                nowUptime + TimeInterval(effectiveLifetime),
            renewAfterUptime:
                nowUptime + TimeInterval(effectiveLifetime) - renewalLead,
            leaseBootIdentifier: bootIdentifier,
            leaseAnchorWallTime: now,
            leaseRemainingAtAnchor: TimeInterval(effectiveLifetime),
            renewRemainingAtAnchor:
                TimeInterval(effectiveLifetime) - renewalLead
        )
    }

    private func makeCurrentCheckProof(
        mapping: ActiveRouterMapping
    ) -> RouterMappingCurrentCheckProof? {
        guard mapping.recoveryState == nil,
              let boundWANAddress = mapping.routerExternalAddress,
              let leaseExpiresUptime =
                mapping.leaseExpiresUptime else {
            return nil
        }
        let bootIdentifier = bootIdentifierProvider()
        let nowUptime = monotonicUptimeProvider()
        let protocolIdentityPresent: Bool
        switch mapping.transport {
        case .pcp:
            protocolIdentityPresent =
                mapping.pcpNonce?.isEmpty == false
        case .natpmp:
            protocolIdentityPresent = true
        case .upnp:
            protocolIdentityPresent =
                mapping.pcpNonce?.isEmpty == false
                    && (mapping.addressFamily == .ipv4
                        || mapping.pinholeID != nil)
        }
        let boundAddressValid =
            mapping.addressFamily == .ipv4
                ? PublicIPService.looksLikeIPv4(boundWANAddress)
                : PublicIPService.isGlobalIPv6(boundWANAddress)
        let epochOrIGDBootMatches =
            mapping.transport == .pcp
                || mapping.transport == .natpmp
                ? mapping.routerEpochBootIdentifier == bootIdentifier
                : true
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
            boundWANAddress: boundWANAddress,
            verifiedAtUptime: nowUptime,
            leaseExpiresUptime: leaseExpiresUptime,
            sideEffectSafetyMargin:
                RouterMappingCurrentCheckProof
                    .defaultSideEffectSafetyMargin,
            mappingIdentityVerified: protocolIdentityPresent,
            boundWANEvidenceVerified: boundAddressValid,
            sameBootVerified:
                mapping.leaseBootIdentifier == bootIdentifier
                    && epochOrIGDBootMatches,
            leaseVerified:
                nowUptime < leaseExpiresUptime,
            epochOrIGDContinuityVerified: true,
            checkpointed: false
        )
    }

    private func verifyUPnPMappingForCurrentCheck(
        _ mapping: ActiveRouterMapping
    ) throws -> (
        mapping: ActiveRouterMapping,
        proof: RouterMappingCurrentCheckProof
    ) {
        let role: UPnPServiceRole =
            mapping.addressFamily == .ipv4
                ? .ipv4PortMapping
                : .ipv6Firewall
        let service = try boundUPnPService(
            for: mapping,
            expectedService: role
        )
        var updated = mapping
        if mapping.addressFamily == .ipv4 {
            let values = try querySpecificUPnPMapping(
                externalPort: mapping.externalPort,
                service: service
            )
            try validateUPnPIPv4Mapping(values, matches: mapping)
            updated.routerExternalAddress =
                try queryUPnPExternalAddress(service: service)
        } else {
            guard let pinholeID = mapping.pinholeID else {
                throw RouterMappingError.protocolFailure(
                    "The tracked UPnP IPv6 pinhole has no ID"
                )
            }
            let firewall = try queryUPnPIPv6FirewallStatus(
                service: service
            )
            guard firewall.firewallEnabled,
                  firewall.inboundPinholeAllowed,
                  try checkUPnPIPv6PinholeWorking(
                      service: service,
                      pinholeID: pinholeID
                  ) else {
                throw RouterMappingError.protocolFailure(
                    "The original UPnP IPv6 pinhole is not active"
                )
            }
            updated.routerExternalAddress = mapping.localAddress
        }
        guard let proof = makeCurrentCheckProof(mapping: updated) else {
            throw RouterMappingError.protocolFailure(
                "The UPnP mapping did not produce a complete current-check proof"
            )
        }
        return (updated, proof)
    }

    private func effectiveLeaseSeconds(
        config: AppConfig,
        protocolName: String,
        minimum: UInt32 = 1
    ) throws -> UInt32 {
        let requested = min(max(config.mappingLeaseSeconds, minimum), 86_400)
        guard let expiresAt = config.accessExpiresAt else {
            return requested
        }

        let remaining: TimeInterval
        if config.accessBootIdentifier == bootIdentifierProvider(),
           let expiresUptime = config.accessExpiresUptime {
            remaining = floor(
                expiresUptime - monotonicUptimeProvider()
            )
        } else {
            remaining = floor(expiresAt.timeIntervalSince(nowProvider()))
        }
        guard remaining >= TimeInterval(minimum) else {
            throw RouterMappingError.protocolFailure(
                "\(protocolName) cannot create a lease because temporary access has less than "
                    + "\(minimum) second(s) remaining"
            )
        }
        return min(requested, UInt32(min(remaining, TimeInterval(UInt32.max))))
    }

    private func enforceAbsoluteAccessDeadline(
        config: AppConfig,
        protocolName: String,
        mapping: ActiveRouterMapping
    ) throws -> ActiveRouterMapping {
        guard let deadline = config.accessExpiresAt else {
            return mapping
        }
        let now = nowProvider()
        let withinDeadline: Bool
        if config.accessBootIdentifier == bootIdentifierProvider(),
           mapping.leaseBootIdentifier == config.accessBootIdentifier,
           let accessUptime = config.accessExpiresUptime,
           let mappingUptime = mapping.leaseExpiresUptime {
            withinDeadline =
                monotonicUptimeProvider() < accessUptime
                && mappingUptime <= accessUptime
        } else {
            withinDeadline =
                now < deadline && mapping.leaseExpiresAt <= deadline
        }
        guard withinDeadline else {
            do {
                try removeMapping(mapping)
            } catch {
                throw RouterMappingRecoveryRequiredError(
                    mapping: mapping,
                    operationDescription:
                        "\(protocolName) completed too late to remain within the temporary-access deadline.",
                    cleanupDescription:
                        "Immediate cleanup could not be confirmed: \(error.localizedDescription)"
                )
            }
            throw RouterMappingError.protocolFailure(
                "\(protocolName) completed too late for temporary access and was closed immediately"
            )
        }
        return mapping
    }

    static func pcpRetryIntervals(
        maximumAttempts: Int,
        initialRetryInterval: TimeInterval = 3,
        randomizationProvider: () -> Double
    ) -> [TimeInterval] {
        let attemptCount = min(max(maximumAttempts, 1), 64)
        var interval = max(0.001, initialRetryInterval)
            * (1 + min(0.1, max(-0.1, randomizationProvider())))
        var result: [TimeInterval] = []
        for attempt in 0..<attemptCount {
            result.append(interval)
            if attempt + 1 < attemptCount {
                interval = min(
                    Self.pcpMaximumRetryInterval,
                    min(interval * 2, Self.pcpMaximumRetryInterval)
                        * (1 + min(0.1, max(-0.1, randomizationProvider())))
                )
            }
        }
        return result
    }

    private func pcpRetryIntervals() -> [TimeInterval] {
        Self.pcpRetryIntervals(
            maximumAttempts: retryPolicy.normalizedPCPMaximumAttempts,
            initialRetryInterval: retryPolicy.pcpInitialRetryInterval,
            randomizationProvider: retryRandomizationProvider
        )
    }

    private func natPMPRetryIntervals() -> [TimeInterval] {
        Array(
            Self.natPMPProtocolRetryIntervals.prefix(
                retryPolicy.normalizedNATPMPMaximumAttempts
            )
        )
    }

    private func epochKey(
        protocolName: RouterEpochProtocol,
        gatewayAddress: String,
        clientAddress: String
    ) -> RouterEpochKey {
        var normalizedGateway = gatewayAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "%25", with: "%")
        if normalizedGateway.hasPrefix("["),
           normalizedGateway.hasSuffix("]") {
            normalizedGateway.removeFirst()
            normalizedGateway.removeLast()
        }
        return RouterEpochKey(
            gatewayAddress: normalizedGateway,
            clientAddress: clientAddress.lowercased(),
            protocolName: protocolName
        )
    }

    private func recordEpoch(
        _ epoch: UInt32,
        protocolName: RouterEpochProtocol,
        gatewayAddress: String,
        clientAddress: String,
        consumePendingReset: Bool = false
    ) -> RouterEpochProbeResult {
        let wallTime = nowProvider()
        let monotonicUptime = monotonicUptimeProvider()
        let bootIdentifier = bootIdentifierProvider()
        let key = epochKey(
            protocolName: protocolName,
            gatewayAddress: gatewayAddress,
            clientAddress: clientAddress
        )
        let resetDetected = epochTracker.observe(
            key: key,
            epoch: epoch,
            wallTime: wallTime,
            monotonicUptime: monotonicUptime,
            bootIdentifier: bootIdentifier
        )
        return RouterEpochProbeResult(
            epoch: epoch,
            wallTime: wallTime,
            monotonicUptime: monotonicUptime,
            bootIdentifier: bootIdentifier,
            resetDetected: resetDetected
                || (consumePendingReset && epochTracker.consumeReset(key: key))
        )
    }

    private func clearEpochReset(
        protocolName: RouterEpochProtocol,
        gatewayAddress: String,
        clientAddress: String
    ) {
        epochTracker.clearReset(
            key: epochKey(
                protocolName: protocolName,
                gatewayAddress: gatewayAddress,
                clientAddress: clientAddress
            )
        )
    }

    private func probePCP(
        localAddress: String,
        gatewayAddress: String,
        retryIntervals: [TimeInterval],
        consumeEpochReset: Bool = false
    ) throws -> RouterEpochProbeResult {
        let transaction = try performUDPTransactionWithSource(
            host: gatewayAddress,
            port: routerControlPort,
            retryIntervals: retryIntervals,
            sourceAddressHint: localAddress,
            operation: "PCP ANNOUNCE probe",
            stateChangingRequest: false,
            payloadBuilder: { selectedSourceAddress in
                try PCPMessageCodec.makeAnnounceRequest(
                    clientAddress: selectedSourceAddress
                )
            },
            parseResponse: PCPMessageCodec.parseAnnounceResponse
        )
        var observation = recordEpoch(
            transaction.response,
            protocolName: .pcp,
            gatewayAddress: gatewayAddress,
            clientAddress: transaction.effectiveSourceAddress,
            consumePendingReset: consumeEpochReset
        )
        observation.effectiveClientAddress =
            transaction.effectiveSourceAddress
        return observation
    }

    private func addPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        familyName: String,
        retryIntervals: [TimeInterval]? = nil,
        expectedClientAddress: String? = nil
    ) throws -> PortMappingResult {
        let nonce = pcpNonce(config: config)
        let family: RouterMappingAddressFamily = familyName == "IPv6" ? .ipv6 : .ipv4
        let requestedLease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "PCP"
        )
        let transaction: PCPMappingTransactionResult
        do {
            transaction = try sendPCPMapping(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                lifetime: requestedLease,
                nonce: nonce,
                retryIntervals: retryIntervals,
                expectedClientAddress: expectedClientAddress
            )
        } catch {
            guard Self.isUncertainCreationError(error) else { throw error }
            let effectiveClientAddress =
                (error as? RouterMappingUDPError)?.effectiveSourceAddress
                ?? localAddress
            var candidate = activeMapping(
                config: config,
                transport: .pcp,
                family: family,
                localAddress: effectiveClientAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.externalPort,
                lifetime: requestedLease
            )
            candidate.pcpNonce = nonce.base64EncodedString()
            throw RouterMappingRecoveryRequiredError(
                mapping: candidate,
                operationDescription: "PCP mapping request was sent, but its result is uncertain.",
                cleanupDescription: error.localizedDescription
            )
        }
        let response = transaction.response
        let effectiveClientAddress = transaction.effectiveClientAddress
        let epochObservation = recordEpoch(
            response.epochTime,
            protocolName: .pcp,
            gatewayAddress: gatewayAddress,
            clientAddress: effectiveClientAddress
        )
        var mapping = activeMapping(
            config: config,
            transport: .pcp,
            family: family,
            localAddress: effectiveClientAddress,
            gatewayAddress: gatewayAddress,
            externalPort: response.externalPort,
            lifetime: response.lifetimeSeconds,
            routerExternalAddress: response.externalAddress,
            routerEpoch: response.epochTime,
            routerEpochObservedAt: epochObservation.wallTime,
            routerEpochObservedUptime:
                epochObservation.monotonicUptime,
            routerEpochBootIdentifier:
                epochObservation.bootIdentifier
        )
        clearEpochReset(
            protocolName: .pcp,
            gatewayAddress: gatewayAddress,
            clientAddress: effectiveClientAddress
        )
        mapping.pcpNonce = nonce.base64EncodedString()
        mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "PCP \(familyName)",
            mapping: mapping
        )
        guard response.lifetimeSeconds <= requestedLease else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "PCP returned a \(response.lifetimeSeconds)s lease after Gatebeam requested at most \(requestedLease)s.",
                cleanupDescription: "The overlong lease must be removed before temporary access can be trusted."
            )
        }
        guard let proof = makeCurrentCheckProof(mapping: mapping) else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "PCP MAP succeeded without a complete current-check proof.",
                cleanupDescription:
                    "The confirmed mapping must be removed before DDNS can continue."
            )
        }
        return PortMappingResult(
            protocolName: "PCP \(familyName)",
            externalPort: response.externalPort,
            routerExternalAddress: response.externalAddress,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s",
            activeMapping: mapping,
            currentCheckProof: proof
        )
    }

    private func sendPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        lifetime: UInt32,
        nonce suppliedNonce: Data? = nil,
        retryIntervals: [TimeInterval]? = nil,
        expectedClientAddress: String? = nil
    ) throws -> PCPMappingTransactionResult {
        let nonce = suppliedNonce ?? pcpNonce(config: config)
        let parseResponse: (Data) throws -> PCPMappingResponse = { response in
            try PCPMessageCodec.parseMapResponse(
                response,
                nonce: nonce,
                internalPort: config.internalPort,
                requestedLifetime: lifetime
            )
        }
        let transaction = try performUDPTransactionWithSource(
            host: gatewayAddress,
            port: routerControlPort,
            retryIntervals: retryIntervals ?? pcpRetryIntervals(),
            sourceAddressHint:
                expectedClientAddress ?? localAddress,
            operation: lifetime == 0 ? "PCP MAP delete" : "PCP MAP",
            stateChangingRequest: true,
            payloadBuilder: { selectedSourceAddress in
                if let expectedClientAddress,
                   selectedSourceAddress != expectedClientAddress {
                    throw RouterMappingError.protocolFailure(
                        "PCP effective client address changed from "
                            + "\(expectedClientAddress) to "
                            + "\(selectedSourceAddress)"
                    )
                }
                return try PCPMessageCodec.makeMapRequest(
                    lifetime: lifetime,
                    clientAddress: selectedSourceAddress,
                    nonce: nonce,
                    internalPort: config.internalPort,
                    suggestedExternalPort: config.externalPort
                )
            },
            parseResponse: parseResponse
        )
        return PCPMappingTransactionResult(
            response: transaction.response,
            effectiveClientAddress: transaction.effectiveSourceAddress
        )
    }

    private func addNATPMPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        retryIntervals: [TimeInterval]? = nil,
        knownExternalAddress: NATPMPExternalAddressResponse? = nil,
        expectedClientAddress: String? = nil
    ) throws -> PortMappingResult {
        let requestedLease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "NAT-PMP"
        )
        let externalAddress = try knownExternalAddress
            ?? queryNATPMPExternalAddress(
                gatewayAddress: gatewayAddress,
                retryIntervals: retryIntervals,
                sourceAddressHint:
                    expectedClientAddress ?? localAddress
            )
        if let expectedClientAddress,
           externalAddress.effectiveClientAddress
                != expectedClientAddress {
            throw RouterMappingError.protocolFailure(
                "NAT-PMP WAN evidence effective source changed from "
                    + "\(expectedClientAddress) to "
                    + "\(externalAddress.effectiveClientAddress)"
            )
        }
        let transaction: NATPMPMappingTransactionResult
        do {
            transaction = try sendNATPMPMapping(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                lifetime: requestedLease,
                retryIntervals: retryIntervals,
                expectedClientAddress:
                    externalAddress.effectiveClientAddress
            )
        } catch {
            guard Self.isUncertainCreationError(error) else { throw error }
            let effectiveClientAddress =
                (error as? RouterMappingUDPError)?
                    .effectiveSourceAddress
                ?? externalAddress.effectiveClientAddress
            let candidate = activeMapping(
                config: config,
                transport: .natpmp,
                family: .ipv4,
                localAddress: effectiveClientAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.externalPort,
                lifetime: requestedLease
            )
            throw RouterMappingRecoveryRequiredError(
                mapping: candidate,
                operationDescription: "NAT-PMP mapping request was sent, but its result is uncertain.",
                cleanupDescription: error.localizedDescription
            )
        }
        let response = transaction.response
        let effectiveClientAddress =
            transaction.effectiveClientAddress
        guard effectiveClientAddress
                == externalAddress.effectiveClientAddress else {
            throw RouterMappingError.protocolFailure(
                "NAT-PMP MAP effective source no longer matches its bound WAN evidence"
            )
        }
        let epochObservation = recordEpoch(
            response.epochTime,
            protocolName: .natPMP,
            gatewayAddress: gatewayAddress,
            clientAddress: effectiveClientAddress
        )
        var mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "NAT-PMP",
            mapping: activeMapping(
                config: config,
                transport: .natpmp,
                family: .ipv4,
                localAddress: effectiveClientAddress,
                gatewayAddress: gatewayAddress,
                externalPort: response.externalPort,
                lifetime: response.lifetimeSeconds,
                routerExternalAddress: externalAddress.address,
                routerEpoch: response.epochTime,
                routerEpochObservedAt: epochObservation.wallTime,
                routerEpochObservedUptime:
                    epochObservation.monotonicUptime,
                routerEpochBootIdentifier:
                    epochObservation.bootIdentifier
            )
        )
        clearEpochReset(
            protocolName: .natPMP,
            gatewayAddress: gatewayAddress,
            clientAddress: effectiveClientAddress
        )
        guard response.lifetimeSeconds <= requestedLease else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "NAT-PMP returned a \(response.lifetimeSeconds)s lease after Gatebeam requested at most \(requestedLease)s.",
                cleanupDescription: "The overlong lease must be removed before temporary access can be trusted."
            )
        }
        guard !epochObservation.resetDetected else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "NAT-PMP router state changed between WAN verification and MAP.",
                cleanupDescription:
                    "The confirmed mapping cannot be bound to the earlier WAN evidence."
            )
        }
        mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "NAT-PMP",
            mapping: mapping
        )
        guard let proof = makeCurrentCheckProof(mapping: mapping) else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "NAT-PMP MAP succeeded without a complete current-check proof.",
                cleanupDescription:
                    "The confirmed mapping must be removed before DDNS can continue."
            )
        }
        return PortMappingResult(
            protocolName: "NAT-PMP",
            externalPort: response.externalPort,
            routerExternalAddress: externalAddress.address,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s",
            activeMapping: mapping,
            currentCheckProof: proof
        )
    }

    private func sendNATPMPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        lifetime: UInt32,
        retryIntervals: [TimeInterval]? = nil,
        expectedClientAddress: String? = nil
    ) throws -> NATPMPMappingTransactionResult {
        let parseResponse: (Data) throws -> NATPMPMappingResponse = { response in
            guard response.count >= 16 else {
                throw RouterMappingError.invalidResponse("NAT-PMP response too short")
            }
            guard response[0] == 0, response[1] == 130 else {
                throw RouterMappingError.invalidResponse("Unexpected NAT-PMP opcode")
            }
            let resultCode = response.readUInt16(at: 2)
            guard resultCode == 0 else {
                throw RouterMappingError.natPMPResultCode(resultCode)
            }
            let internalPort = response.readUInt16(at: 8)
            let externalPort = response.readUInt16(at: 10)
            let lifetimeSeconds = response.readUInt32(at: 12)
            guard internalPort == config.internalPort else {
                throw RouterMappingError.invalidResponse(
                    "NAT-PMP confirmed unexpected internal port \(internalPort)"
                )
            }
            if lifetime > 0, lifetimeSeconds == 0 {
                throw RouterMappingError.protocolFailure(
                    "NAT-PMP router returned a zero-second lease"
                )
            }
            if lifetime == 0,
               lifetimeSeconds != 0 || externalPort != 0 {
                throw RouterMappingError.protocolFailure(
                    "NAT-PMP delete response retained a nonzero external port or lifetime"
                )
            }
            return NATPMPMappingResponse(
                externalPort: externalPort,
                lifetimeSeconds: lifetimeSeconds,
                epochTime: response.readUInt32(at: 4)
            )
        }
        let transaction = try performUDPTransactionWithSource(
            host: gatewayAddress,
            port: routerControlPort,
            retryIntervals: retryIntervals ?? natPMPRetryIntervals(),
            sourceAddressHint:
                expectedClientAddress ?? localAddress,
            operation: lifetime == 0 ? "NAT-PMP delete" : "NAT-PMP MAP",
            stateChangingRequest: true,
            payloadBuilder: { selectedSourceAddress in
                if let expectedClientAddress,
                   selectedSourceAddress != expectedClientAddress {
                    throw RouterMappingError.protocolFailure(
                        "NAT-PMP effective client address changed from "
                            + "\(expectedClientAddress) to "
                            + "\(selectedSourceAddress)"
                    )
                }
                var request = Data([0, 2, 0, 0])
                request.appendUInt16(config.internalPort)
                request.appendUInt16(lifetime == 0 ? 0 : config.externalPort)
                request.appendUInt32(lifetime)
                return request
            },
            parseResponse: parseResponse
        )
        return NATPMPMappingTransactionResult(
            response: transaction.response,
            effectiveClientAddress:
                transaction.effectiveSourceAddress
        )
    }

    private func queryNATPMPExternalAddress(
        gatewayAddress: String,
        retryIntervals: [TimeInterval]? = nil,
        sourceAddressHint: String? = nil,
        consumeEpochReset: Bool = false
    ) throws -> NATPMPExternalAddressResponse {
        let parseResponse: (Data) throws -> (
            address: String,
            epochTime: UInt32
        ) = {
            response in
            guard response.count >= 12, response[0] == 0, response[1] == 128 else {
                throw RouterMappingError.invalidResponse(
                    "Invalid NAT-PMP public address response"
                )
            }
            let resultCode = response.readUInt16(at: 2)
            guard resultCode == 0 else {
                throw RouterMappingError.natPMPResultCode(resultCode)
            }
            return (
                "\(response[8]).\(response[9]).\(response[10]).\(response[11])",
                response.readUInt32(at: 4)
            )
        }
        let transaction = try performUDPTransactionWithSource(
            host: gatewayAddress,
            port: routerControlPort,
            retryIntervals: retryIntervals ?? natPMPRetryIntervals(),
            sourceAddressHint: sourceAddressHint,
            operation: "NAT-PMP External Address probe",
            stateChangingRequest: false,
            payloadBuilder: { _ in Data([0, 0]) },
            parseResponse: parseResponse
        )
        let response = transaction.response
        let observation = recordEpoch(
            response.epochTime,
            protocolName: .natPMP,
            gatewayAddress: gatewayAddress,
            clientAddress: transaction.effectiveSourceAddress,
            consumePendingReset: consumeEpochReset
        )
        var effectiveObservation = observation
        effectiveObservation.effectiveClientAddress =
            transaction.effectiveSourceAddress
        return NATPMPExternalAddressResponse(
            address: response.address,
            epochTime: response.epochTime,
            epochObservation: effectiveObservation,
            effectiveClientAddress:
                transaction.effectiveSourceAddress
        )
    }

    private func addUPnPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        boundService: UPnPService? = nil,
        protocolState: String? = nil
    ) throws -> PortMappingResult {
        let service = try boundService
            ?? discoverUPnPService(gatewayAddress: gatewayAddress)
        let binding = try protocolState
            ?? UPnPControlBinding(
                service: service,
                gatewayAddress: gatewayAddress
            ).encoded()
        let lease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "UPnP IPv4"
        )
        do {
            try addUPnPMapping(
                config: config,
                localAddress: localAddress,
                service: service,
                lease: lease
            )
        } catch {
            if let mappingError = error as? RouterMappingError,
               mappingError.isConclusiveUPnPAddRejection {
                throw error
            }
            let mapping = activeMapping(
                config: config,
                transport: .upnp,
                family: .ipv4,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.externalPort,
                lifetime: lease,
                protocolState: binding
            )
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "The UPnP AddPortMapping request may have reached the original IGD, but no conclusive response was received.",
                cleanupDescription: error.localizedDescription
            )
        }
        let confirmedLease: UInt32
        do {
            confirmedLease = try verifyUPnPMapping(
                config: config,
                localAddress: localAddress,
                maximumLease: lease,
                service: service
            )
        } catch {
            let mapping = activeMapping(
                config: config,
                transport: .upnp,
                family: .ipv4,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.externalPort,
                lifetime: lease,
                protocolState: binding
            )
            do {
                try removeMapping(mapping)
            } catch let cleanupError {
                throw RouterMappingRecoveryRequiredError(
                    mapping: mapping,
                    operationDescription: "UPnP mapping verification failed: \(error.localizedDescription)",
                    cleanupDescription: cleanupError.localizedDescription
                )
            }
            throw error
        }
        var mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "UPnP IPv4",
            mapping: activeMapping(
                config: config,
                transport: .upnp,
                family: .ipv4,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.externalPort,
                lifetime: confirmedLease,
                protocolState: binding
            )
        )
        let routerExternalAddress: String
        do {
            routerExternalAddress =
                try queryUPnPExternalAddress(service: service)
            mapping.routerExternalAddress = routerExternalAddress
        } catch {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "UPnP mapping was confirmed, but its bound IGD WAN address could not be verified.",
                cleanupDescription: error.localizedDescription
            )
        }
        mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "UPnP IPv4",
            mapping: mapping
        )
        guard let proof = makeCurrentCheckProof(mapping: mapping) else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "UPnP mapping succeeded without a complete current-check proof.",
                cleanupDescription:
                    "The confirmed mapping must be removed before DDNS can continue."
            )
        }
        return PortMappingResult(
            protocolName: "UPnP IGD",
            externalPort: config.externalPort,
            routerExternalAddress: routerExternalAddress,
            message: "Verified TCP \(config.externalPort) -> \(localAddress):\(config.internalPort), \(confirmedLease)s lease",
            activeMapping: mapping,
            currentCheckProof: proof
        )
    }

    private func addUPnPMapping(
        config: AppConfig,
        localAddress: String,
        service: UPnPService,
        lease: UInt32
    ) throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:AddPortMapping xmlns:u="\(service.serviceType)">
              <NewRemoteHost></NewRemoteHost>
              <NewExternalPort>\(config.externalPort)</NewExternalPort>
              <NewProtocol>TCP</NewProtocol>
              <NewInternalPort>\(config.internalPort)</NewInternalPort>
              <NewInternalClient>\(localAddress)</NewInternalClient>
              <NewEnabled>1</NewEnabled>
              <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
              <NewLeaseDuration>\(lease)</NewLeaseDuration>
            </u:AddPortMapping>
          </s:Body>
        </s:Envelope>
        """
        _ = try soapRequest(controlURL: service.controlURL, serviceType: service.serviceType, action: "AddPortMapping", body: body)
    }

    private func verifyUPnPMapping(
        config: AppConfig,
        localAddress: String,
        maximumLease: UInt32,
        service: UPnPService
    ) throws -> UInt32 {
        let values = try querySpecificUPnPMapping(
            externalPort: config.externalPort,
            service: service
        )
        guard values["NewInternalClient"] == localAddress,
              values["NewInternalPort"] == String(config.internalPort),
              values["NewEnabled"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              values["NewPortMappingDescription"] == "Gatebeam",
              let confirmedLease = values["NewLeaseDuration"].flatMap(UInt32.init),
              confirmedLease > 0,
              confirmedLease <= maximumLease else {
            throw RouterMappingError.invalidResponse(
                "UPnP mapping could not be confirmed with the requested client, port, description, and finite lease"
            )
        }
        return confirmedLease
    }

    private func querySpecificUPnPMapping(
        externalPort: UInt16,
        service: UPnPService
    ) throws -> [String: String] {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetSpecificPortMappingEntry xmlns:u="\(service.serviceType)">
              <NewRemoteHost></NewRemoteHost>
              <NewExternalPort>\(externalPort)</NewExternalPort>
              <NewProtocol>TCP</NewProtocol>
            </u:GetSpecificPortMappingEntry>
          </s:Body>
        </s:Envelope>
        """
        let response = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "GetSpecificPortMappingEntry",
            body: body
        )
        return Self.xmlValues(in: response.data)
    }

    private func queryUPnPExternalAddress(service: UPnPService) throws -> String {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetExternalIPAddress xmlns:u="\(service.serviceType)"></u:GetExternalIPAddress>
          </s:Body>
        </s:Envelope>
        """
        let response = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "GetExternalIPAddress",
            body: body
        )
        guard let address = Self.xmlValues(in: response.data)["NewExternalIPAddress"],
              PublicIPService.looksLikeIPv4(address) else {
            throw RouterMappingError.invalidResponse("UPnP returned an invalid public address")
        }
        return address
    }

    private func deleteUPnPMapping(externalPort: UInt16, service: UPnPService) throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:DeletePortMapping xmlns:u="\(service.serviceType)">
              <NewRemoteHost></NewRemoteHost>
              <NewExternalPort>\(externalPort)</NewExternalPort>
              <NewProtocol>TCP</NewProtocol>
            </u:DeletePortMapping>
          </s:Body>
        </s:Envelope>
        """
        do {
            _ = try soapRequest(
                controlURL: service.controlURL,
                serviceType: service.serviceType,
                action: "DeletePortMapping",
                body: body
            )
        } catch let error as RouterMappingError where error.isIdempotentIPv4UPnPDeletionMiss {
            return
        }
    }

    private func addUPnPIPv6Pinhole(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        boundService: UPnPService? = nil,
        protocolState: String? = nil
    ) throws -> PortMappingResult {
        guard PublicIPService.isGlobalIPv6(localAddress) else {
            throw RouterMappingError.protocolFailure("UPnP IPv6 pinholes require a global IPv6 address on this Mac")
        }
        let service = try boundService
            ?? discoverUPnPIPv6FirewallService(
                gatewayAddress: gatewayAddress
            )
        let binding = try protocolState
            ?? UPnPControlBinding(
                service: service,
                gatewayAddress: gatewayAddress
            ).encoded()
        let firewallStatus = try queryUPnPIPv6FirewallStatus(service: service)
        guard firewallStatus.firewallEnabled, firewallStatus.inboundPinholeAllowed else {
            throw RouterMappingError.protocolFailure("The router reports that inbound IPv6 pinholes are disabled")
        }

        let lease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "UPnP IPv6"
        )
        var pinholeID = config.ipv6PinholeID
        if let existingID = pinholeID {
            do {
                try updateUPnPIPv6Pinhole(service: service, pinholeID: existingID, lease: lease)
            } catch let error as RouterMappingError
            where error.isMissingIPv6UPnPPinholeForUpdate {
                pinholeID = nil
            } catch {
                let candidate = activeMapping(
                    config: config,
                    transport: .upnp,
                    family: .ipv6,
                    localAddress: localAddress,
                    gatewayAddress: gatewayAddress,
                    externalPort: config.internalPort,
                    lifetime: lease,
                    pinholeID: existingID,
                    protocolState: binding
                )
                throw RouterMappingRecoveryRequiredError(
                    mapping: candidate,
                    operationDescription:
                        "UPnP IPv6 pinhole \(existingID) renewal result is uncertain.",
                    cleanupDescription: error.localizedDescription
                )
            }
        }
        if pinholeID == nil {
            do {
                pinholeID = try createUPnPIPv6Pinhole(
                    service: service,
                    localAddress: localAddress,
                    internalPort: config.internalPort,
                    lease: lease
                )
            } catch {
                if let mappingError = error as? RouterMappingError,
                   mappingError.isConclusiveUPnPAddRejection {
                    throw error
                }
                let unknownExposure = activeMapping(
                    config: config,
                    transport: .upnp,
                    family: .ipv6,
                    localAddress: localAddress,
                    gatewayAddress: gatewayAddress,
                    externalPort: config.internalPort,
                    lifetime: lease,
                    pinholeID: nil,
                    protocolState: binding
                )
                throw RouterMappingRecoveryRequiredError(
                    mapping: unknownExposure,
                    operationDescription:
                        "The UPnP AddPinhole request may have created an IPv6 exposure, "
                            + "but Gatebeam did not receive a usable UniqueID.",
                    cleanupDescription:
                        "\(error.localizedDescription) New mappings are blocked until the finite "
                            + "lease expires at \(unknownExposure.leaseExpiresAt)."
                )
            }
        }

        var mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "UPnP IPv6",
            mapping: activeMapping(
                config: config,
                transport: .upnp,
                family: .ipv6,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                externalPort: config.internalPort,
                lifetime: lease,
                pinholeID: pinholeID,
                protocolState: binding
            )
        )
        mapping.routerExternalAddress = localAddress
        guard let proof = makeCurrentCheckProof(mapping: mapping) else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "UPnP IPv6 pinhole succeeded without a complete current-check proof.",
                cleanupDescription:
                    "The confirmed pinhole must be removed before DDNS can continue."
            )
        }
        return PortMappingResult(
            protocolName: "UPnP IPv6 Firewall",
            externalPort: config.internalPort,
            routerExternalAddress: localAddress,
            message: "Opened IPv6 TCP \(config.internalPort) to \(localAddress) for \(lease)s",
            pinholeID: pinholeID,
            activeMapping: mapping,
            currentCheckProof: proof
        )
    }

    private func queryUPnPIPv6FirewallStatus(service: UPnPService) throws -> (firewallEnabled: Bool, inboundPinholeAllowed: Bool) {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetFirewallStatus xmlns:u="\(service.serviceType)"></u:GetFirewallStatus>
          </s:Body>
        </s:Envelope>
        """
        let response = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "GetFirewallStatus",
            body: body
        )
        let values = Self.xmlValues(in: response.data)
        return (
            Self.xmlBoolean(values["FirewallEnabled"]),
            Self.xmlBoolean(values["InboundPinholeAllowed"])
        )
    }

    private func createUPnPIPv6Pinhole(
        service: UPnPService,
        localAddress: String,
        internalPort: UInt16,
        lease: UInt32
    ) throws -> UInt16 {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:AddPinhole xmlns:u="\(service.serviceType)">
              <RemoteHost></RemoteHost>
              <RemotePort>0</RemotePort>
              <InternalClient>\(localAddress)</InternalClient>
              <InternalPort>\(internalPort)</InternalPort>
              <Protocol>6</Protocol>
              <LeaseTime>\(lease)</LeaseTime>
            </u:AddPinhole>
          </s:Body>
        </s:Envelope>
        """
        let response = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "AddPinhole",
            body: body
        )
        let values = Self.xmlValues(in: response.data)
        guard let rawID = values["UniqueID"], let pinholeID = UInt16(rawID) else {
            throw RouterMappingError.invalidResponse("UPnP AddPinhole did not return a UniqueID")
        }
        return pinholeID
    }

    private func updateUPnPIPv6Pinhole(service: UPnPService, pinholeID: UInt16, lease: UInt32) throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:UpdatePinhole xmlns:u="\(service.serviceType)">
              <UniqueID>\(pinholeID)</UniqueID>
              <NewLeaseTime>\(lease)</NewLeaseTime>
            </u:UpdatePinhole>
          </s:Body>
        </s:Envelope>
        """
        _ = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "UpdatePinhole",
            body: body
        )
    }

    private func checkUPnPIPv6PinholeWorking(
        service: UPnPService,
        pinholeID: UInt16
    ) throws -> Bool {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:CheckPinholeWorking xmlns:u="\(service.serviceType)">
              <UniqueID>\(pinholeID)</UniqueID>
            </u:CheckPinholeWorking>
          </s:Body>
        </s:Envelope>
        """
        let response = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "CheckPinholeWorking",
            body: body
        )
        let values = Self.xmlValues(in: response.data)
        guard let raw = values["IsWorking"] else {
            throw RouterMappingError.invalidResponse(
                "UPnP CheckPinholeWorking omitted IsWorking"
            )
        }
        return Self.xmlBoolean(raw)
    }

    private func deleteUPnPIPv6Pinhole(pinholeID: UInt16, service: UPnPService) throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:DeletePinhole xmlns:u="\(service.serviceType)">
              <UniqueID>\(pinholeID)</UniqueID>
            </u:DeletePinhole>
          </s:Body>
        </s:Envelope>
        """
        do {
            _ = try soapRequest(
                controlURL: service.controlURL,
                serviceType: service.serviceType,
                action: "DeletePinhole",
                body: body
            )
        } catch let error as RouterMappingError where error.isIdempotentIPv6UPnPDeletionMiss {
            return
        }
    }

    private func boundUPnPService(
        for mapping: ActiveRouterMapping,
        expectedService: UPnPServiceRole
    ) throws -> UPnPService {
        guard let protocolState = mapping.pcpNonce else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP mapping predates bound IGD metadata; refusing to rediscover another router"
            )
        }
        let binding = try UPnPControlBinding.decode(protocolState)
        guard normalizedGatewayIdentity(binding.gatewayIdentity)
                == normalizedGatewayIdentity(mapping.gatewayAddress) else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP gateway identity no longer matches the mapping"
            )
        }
        guard let controlURL = URL(string: binding.controlURL),
              let descriptionURL = URL(string: binding.descriptionURL),
              let scheme = controlURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let descriptionScheme = descriptionURL.scheme?.lowercased(),
              ["http", "https"].contains(descriptionScheme),
              controlURL.user == nil,
              controlURL.password == nil,
              descriptionURL.user == nil,
              descriptionURL.password == nil,
              controlURL.host != nil,
              descriptionURL.host != nil else {
            throw RouterMappingError.protocolFailure("The tracked UPnP control or description URL is invalid")
        }

        let service = UPnPService(
            serviceType: binding.serviceType,
            controlURL: controlURL,
            gatewayIdentity: binding.gatewayIdentity,
            descriptionURL: descriptionURL,
            deviceIdentity: binding.deviceIdentity,
            allowsCrossFamilyControl: binding.allowsCrossFamilyControl,
            ssdpBootID: binding.ssdpBootID,
            ssdpConfigID: binding.ssdpConfigID
        )
        guard service.isBound(to: mapping.gatewayAddress) else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP control URL is not bound to the original gateway"
            )
        }
        guard expectedService.matches(service.serviceType) else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP service type does not match the mapping address family"
            )
        }
        try verifyBoundUPnPIdentity(
            service,
            expectedService: expectedService
        )
        return service
    }

    private func verifyBoundUPnPIdentity(
        _ service: UPnPService,
        expectedService: UPnPServiceRole
    ) throws {
        guard let descriptionURL = service.descriptionURL,
              let expectedIdentity = service.deviceIdentity,
              !expectedIdentity.isEmpty else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP mapping predates IGD device identity metadata"
            )
        }
        if case .ipv6Firewall = expectedService {
            guard let expectedBootID = normalizedUPnPVersionIdentifier(
                service.ssdpBootID
            ),
            let expectedConfigID = normalizedUPnPVersionIdentifier(
                service.ssdpConfigID
            ) else {
                throw RouterMappingError.protocolFailure(
                    "The tracked IPv6 UPnP pinhole predates SSDP BOOTID/CONFIGID metadata; "
                        + "refusing an ID-only operation until its finite lease expires"
                )
            }
            let currentServices = try discoverUPnPServices(
                gatewayAddress: service.gatewayIdentity,
                addressFamily: .ipv6
            )
            guard currentServices.contains(where: {
                normalizedUPnPDeviceIdentity($0.deviceIdentity ?? "")
                    == normalizedUPnPDeviceIdentity(expectedIdentity)
                    && $0.serviceType == service.serviceType
                    && $0.controlURL == service.controlURL
                    && $0.descriptionURL == service.descriptionURL
                    && $0.isBound(to: service.gatewayIdentity)
                    && normalizedUPnPVersionIdentifier($0.ssdpBootID)
                        == expectedBootID
                    && normalizedUPnPVersionIdentifier($0.ssdpConfigID)
                        == expectedConfigID
            }) else {
                throw RouterMappingError.protocolFailure(
                    "The original IPv6 UPnP SSDP BOOTID, CONFIGID, or static endpoint identity changed"
                )
            }
        }
        let currentServices = try parseUPnPDescription(
            location: descriptionURL,
            gatewayIdentityOverride: service.gatewayIdentity,
            allowsCrossFamilyControl: service.allowsCrossFamilyControl
        )
        guard currentServices.contains(where: {
            normalizedUPnPDeviceIdentity($0.deviceIdentity ?? "") == normalizedUPnPDeviceIdentity(expectedIdentity)
                && $0.serviceType == service.serviceType
                && $0.controlURL == service.controlURL
                && $0.isBound(to: service.gatewayIdentity)
        }) else {
            throw RouterMappingError.protocolFailure(
                "The original UPnP IGD identity or control endpoint has changed"
            )
        }
    }

    private func discoverUPnPService(gatewayAddress: String) throws -> UPnPService {
        let services = try discoverUPnPServices(
            gatewayAddress: gatewayAddress,
            addressFamily: .ipv4
        )
        let candidates = services.filter {
            ($0.serviceType.contains("WANIPConnection") || $0.serviceType.contains("WANPPPConnection"))
                && $0.isBound(to: gatewayAddress)
        }.sorted {
            if $0.serviceType.contains("WANIPConnection") != $1.serviceType.contains("WANIPConnection") {
                return $0.serviceType.contains("WANIPConnection")
            }
            return $0.serviceType > $1.serviceType
        }
        guard let service = candidates.first else {
            throw RouterMappingError.protocolFailure(
                "No UPnP WAN connection service was bound to the original gateway \(gatewayAddress)"
            )
        }
        return service
    }

    private func discoverUPnPIPv6FirewallService(gatewayAddress: String) throws -> UPnPService {
        guard let service = try discoverUPnPServices(
            gatewayAddress: gatewayAddress,
            addressFamily: .ipv6
        ).first(where: {
            $0.serviceType.contains("WANIPv6FirewallControl") && $0.isBound(to: gatewayAddress)
        }) else {
            throw RouterMappingError.protocolFailure(
                "No UPnP WANIPv6FirewallControl service was bound to the original gateway \(gatewayAddress)"
            )
        }
        return service
    }

    private func discoverUPnPServices(
        gatewayAddress: String,
        addressFamily: UPnPDiscoveryAddressFamily
    ) throws -> [UPnPService] {
        if let upnpDiscoveryHandler {
            try checkOperation()
            let services = try upnpDiscoveryHandler()
            try checkOperation()
            return services
        }
        let targets = [
            "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
            "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1"
        ]
        let host: String
        let hostHeader: String
        let interfaceName: String?
        switch addressFamily {
        case .ipv4:
            host = "239.255.255.250"
            hostHeader = "239.255.255.250:1900"
            interfaceName = nil
        case .ipv6:
            guard let scopedInterface = Self.ipv6ScopeInterface(in: gatewayAddress) else {
                throw RouterMappingError.protocolFailure(
                    "The IPv6 default gateway has no interface scope for link-local SSDP discovery"
                )
            }
            host = "ff02::c"
            hostHeader = "[FF02::C]:1900"
            interfaceName = scopedInterface
        }
        let payloads = targets.map { target in
            Data("""
            M-SEARCH * HTTP/1.1\r
            HOST: \(hostHeader)\r
            MAN: "ssdp:discover"\r
            MX: 2\r
            ST: \(target)\r
            \r
            """.utf8)
        }
        let request = UPnPDiscoveryRequest(
            addressFamily: addressFamily,
            host: host,
            port: 1900,
            interfaceName: interfaceName,
            payloads: payloads,
            timeoutSeconds: 4
        )
        let responses: [Data]
        if let ssdpSearchHandler {
            try checkOperation()
            responses = try ssdpSearchHandler(request)
            try checkOperation()
        } else {
            switch addressFamily {
            case .ipv4:
                responses = try udpMulticastSearchIPv4(request)
            case .ipv6:
                responses = try udpMulticastSearchIPv6(request)
            }
        }
        var endpoints: [(
            location: URL,
            deviceIdentity: String?,
            bootID: String?,
            configID: String?
        )] = []
        var conflictingHeaderDetected = false
        for response in responses {
            let text = String(data: response, encoding: .utf8) ?? ""
            let location = Self.uniqueHeaderValue(
                "location",
                in: text
            ) {
                URL(string: $0)?.absoluteString
            }
            let deviceIdentity = Self.uniqueHeaderValue(
                "usn",
                in: text
            ) {
                let normalized = normalizedUPnPDeviceIdentity($0)
                return normalized.isEmpty ? nil : normalized
            }
            let bootID = Self.uniqueHeaderValue(
                Self.upnpBootIDHeader,
                in: text,
                normalizer: normalizedUPnPVersionIdentifier
            )
            let configID = Self.uniqueHeaderValue(
                Self.upnpConfigIDHeader,
                in: text,
                normalizer: normalizedUPnPVersionIdentifier
            )
            if location.conflicting
                || deviceIdentity.conflicting
                || bootID.conflicting
                || configID.conflicting {
                conflictingHeaderDetected = true
                continue
            }
            guard let locationValue = location.value,
                  let locationURL = URL(string: locationValue) else {
                continue
            }
            endpoints.append(
                (
                    locationURL,
                    deviceIdentity.value,
                    bootID.value,
                    configID.value
                )
            )
        }
        guard !conflictingHeaderDetected else {
            throw RouterMappingError.protocolFailure(
                "SSDP returned conflicting duplicate identity headers"
            )
        }

        var services: [UPnPService] = []
        var endpointSignaturesByIdentity: [String: Set<String>] = [:]
        for endpoint in endpoints {
            guard let identity = endpoint.deviceIdentity else { continue }
            endpointSignaturesByIdentity[identity, default: []].insert(
                [
                    endpoint.location.absoluteString,
                    endpoint.bootID ?? "<missing>",
                    endpoint.configID ?? "<missing>"
                ].joined(separator: "|")
            )
        }
        guard !endpointSignaturesByIdentity.values.contains(where: {
            $0.count > 1
        }) else {
            throw RouterMappingError.protocolFailure(
                "One UPnP UDN advertised conflicting SSDP locations or BOOTID/CONFIGID values"
            )
        }

        var seenEndpoints = Set<String>()
        for endpoint in endpoints {
            let endpointKey = [
                endpoint.deviceIdentity ?? "<missing>",
                endpoint.location.absoluteString,
                endpoint.bootID ?? "<missing>",
                endpoint.configID ?? "<missing>"
            ].joined(separator: "|")
            guard seenEndpoints.insert(endpointKey).inserted else {
                continue
            }
            do {
                services.append(
                    contentsOf: try parseUPnPDescription(
                        location: endpoint.location,
                        fallbackDeviceIdentity: endpoint.deviceIdentity,
                        gatewayIdentityOverride: addressFamily == .ipv6 ? gatewayAddress : nil,
                        allowsCrossFamilyControl: addressFamily == .ipv6,
                        ssdpBootID: endpoint.bootID,
                        ssdpConfigID: endpoint.configID
                    )
                )
            } catch RouterMappingError.cancelled {
                throw RouterMappingError.cancelled
            } catch {
                continue
            }
        }

        guard !services.isEmpty else {
            throw RouterMappingError.protocolFailure("No UPnP IGD service discovered")
        }
        var discoverySignaturesByIdentity:
            [String: Set<String>] = [:]
        var controlEndpointsByIdentityAndService:
            [String: Set<String>] = [:]
        for service in services {
            let identity = normalizedUPnPDeviceIdentity(
                service.deviceIdentity ?? ""
            )
            guard !identity.isEmpty else { continue }
            discoverySignaturesByIdentity[
                identity,
                default: []
            ].insert(
                [
                    service.descriptionURL?.absoluteString
                        ?? "<missing>",
                    normalizedUPnPVersionIdentifier(
                        service.ssdpBootID
                    ) ?? "<missing>",
                    normalizedUPnPVersionIdentifier(
                        service.ssdpConfigID
                    ) ?? "<missing>"
                ].joined(separator: "|")
            )
            controlEndpointsByIdentityAndService[
                "\(identity)|\(service.serviceType)",
                default: []
            ].insert(
                [
                    service.controlURL.absoluteString,
                    normalizedGatewayIdentity(
                        service.gatewayIdentity
                    )
                ].joined(separator: "|")
            )
        }
        guard !discoverySignaturesByIdentity.values.contains(where: {
            $0.count > 1
        }),
        !controlEndpointsByIdentityAndService.values.contains(where: {
            $0.count > 1
        }) else {
            throw RouterMappingError.protocolFailure(
                "One UPnP UDN resolved to conflicting static service endpoints"
            )
        }
        var seen = Set<String>()
        return services.filter {
            seen.insert("\($0.serviceType)|\($0.controlURL.absoluteString)").inserted
        }
    }

    private func parseUPnPDescription(
        location: URL,
        fallbackDeviceIdentity: String? = nil,
        gatewayIdentityOverride: String? = nil,
        allowsCrossFamilyControl: Bool = false,
        ssdpBootID: String? = nil,
        ssdpConfigID: String? = nil
    ) throws -> [UPnPService] {
        let data: Data
        if let upnpDescriptionHandler {
            try checkOperation()
            data = try upnpDescriptionHandler(location)
            try checkOperation()
        } else {
            let response = try routerHTTPRequest(
                HTTPRequest(
                    url: location,
                    method: "GET",
                    headers: [:],
                    body: nil,
                    timeout: 6
                )
            )
            guard (200...299).contains(response.statusCode) else {
                throw RouterMappingError.protocolFailure("UPnP description HTTP \(response.statusCode)")
            }
            data = response.data
        }
        let description = UPnPDescriptionParser.parse(data)
        let baseURL = description.urlBase.flatMap(URL.init(string:)) ?? location
        if let parsedIdentity = description.deviceIdentity,
           let fallbackDeviceIdentity,
           normalizedUPnPDeviceIdentity(parsedIdentity)
                != normalizedUPnPDeviceIdentity(fallbackDeviceIdentity) {
            throw RouterMappingError.protocolFailure(
                "The UPnP description UDN did not match the SSDP responder identity"
            )
        }
        let deviceIdentity = description.deviceIdentity ?? fallbackDeviceIdentity
        let services = description.services.compactMap { candidate -> UPnPService? in
            guard candidate.serviceType.contains("WANIPConnection")
                    || candidate.serviceType.contains("WANPPPConnection")
                    || candidate.serviceType.contains("WANIPv6FirewallControl"),
                  let controlURL = URL(string: candidate.controlURL, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return UPnPService(
                serviceType: candidate.serviceType,
                controlURL: controlURL,
                gatewayIdentity: normalizedGatewayIdentity(
                    gatewayIdentityOverride ?? controlURL.host ?? location.host ?? ""
                ),
                descriptionURL: location,
                deviceIdentity: deviceIdentity,
                allowsCrossFamilyControl: allowsCrossFamilyControl,
                ssdpBootID: normalizedUPnPVersionIdentifier(ssdpBootID),
                ssdpConfigID: normalizedUPnPVersionIdentifier(ssdpConfigID)
            )
        }
        guard !services.isEmpty else {
            throw RouterMappingError.protocolFailure("UPnP description did not contain a supported WAN service")
        }
        return services
    }

    private func soapRequest(controlURL: URL, serviceType: String, action: String, body: String) throws -> HTTPResponse {
        let response: HTTPResponse
        if let soapRequestHandler {
            try checkOperation()
            response = try soapRequestHandler(controlURL, serviceType, action, body)
            try checkOperation()
        } else {
            response = try routerHTTPRequest(
                HTTPRequest(
                    url: controlURL,
                    method: "POST",
                    headers: [
                        "Content-Type": "text/xml; charset=\"utf-8\"",
                        "SOAPAction": "\"\(serviceType)#\(action)\""
                    ],
                    body: Data(body.utf8),
                    timeout: 8
                )
            )
        }
        guard (200...299).contains(response.statusCode) else {
            let values = Self.xmlValues(in: response.data)
            throw RouterMappingError.upnpFault(
                action: action,
                serviceType: serviceType,
                statusCode: response.statusCode,
                errorCode: values["errorCode"].flatMap(Int.init),
                description: values["errorDescription"]
            )
        }
        return response
    }

    private func routerHTTPRequest(
        _ request: HTTPRequest
    ) throws -> HTTPResponse {
        try checkOperation()
        do {
            let response = try http.request(
                request,
                cancellationHandler: { [weak self] in
                    self?.operationShouldStop() ?? true
                }
            )
            try checkOperation()
            return response
        } catch NetworkError.cancelled {
            throw RouterMappingError.cancelled
        }
    }

    private func udpMulticastSearchIPv4(_ request: UPnPDiscoveryRequest) throws -> [Data] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw RouterMappingError.socket("socket() failed") }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: request.timeoutSeconds, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = request.port.bigEndian
        inet_pton(AF_INET, request.host, &destination.sin_addr)

        try sendSSDPPayloads(
            request.payloads,
            socketFD: socketFD,
            destination: &destination
        )
        return try receiveSSDPResponses(
            socketFD: socketFD,
            timeoutSeconds: request.timeoutSeconds
        )
    }

    private func udpMulticastSearchIPv6(_ request: UPnPDiscoveryRequest) throws -> [Data] {
        guard let interfaceName = request.interfaceName else {
            throw RouterMappingError.protocolFailure(
                "IPv6 SSDP discovery requires the default route interface"
            )
        }
        let interfaceIndex = if_nametoindex(interfaceName)
        guard interfaceIndex != 0 else {
            throw RouterMappingError.socket(
                "Could not resolve IPv6 SSDP interface \(interfaceName)"
            )
        }

        let socketFD = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw RouterMappingError.socket("IPv6 SSDP socket() failed")
        }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_REUSEADDR,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var multicastInterface = interfaceIndex
        guard setsockopt(
            socketFD,
            IPPROTO_IPV6,
            IPV6_MULTICAST_IF,
            &multicastInterface,
            socklen_t(MemoryLayout<UInt32>.size)
        ) == 0 else {
            throw RouterMappingError.socket(
                "Could not bind IPv6 SSDP to interface \(interfaceName)"
            )
        }

        var timeout = timeval(tv_sec: request.timeoutSeconds, tv_usec: 0)
        setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = request.port.bigEndian
        destination.sin6_scope_id = interfaceIndex
        guard inet_pton(AF_INET6, request.host, &destination.sin6_addr) == 1 else {
            throw RouterMappingError.socket(
                "Invalid IPv6 SSDP multicast destination \(request.host)"
            )
        }

        try sendSSDPPayloads(
            request.payloads,
            socketFD: socketFD,
            destination: &destination
        )
        return try receiveSSDPResponses(
            socketFD: socketFD,
            timeoutSeconds: request.timeoutSeconds
        )
    }

    private func sendSSDPPayloads<Address>(
        _ payloads: [Data],
        socketFD: Int32,
        destination: inout Address
    ) throws {
        for payload in payloads {
            try checkOperation()
            let sent = payload.withUnsafeBytes { bytes -> ssize_t in
                guard let base = bytes.baseAddress else { return -1 }
                return withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(
                            socketFD,
                            base,
                            payload.count,
                            0,
                            $0,
                            socklen_t(MemoryLayout<Address>.size)
                        )
                    }
                }
            }
            guard sent > 0 else { throw RouterMappingError.socket("sendto() failed") }
            try checkOperation()
        }
    }

    private func receiveSSDPResponses(
        socketFD: Int32,
        timeoutSeconds: Int
    ) throws -> [Data] {
        var responses: [Data] = []
        let deadline = monotonicUptimeProvider()
            + Double(timeoutSeconds)
        while monotonicUptimeProvider() < deadline {
            try checkOperation()
            let remaining = deadline - monotonicUptimeProvider()
            var descriptor = pollfd(
                fd: socketFD,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = Darwin.poll(
                &descriptor,
                1,
                Int32(
                    max(
                        1,
                        min(100, Int(ceil(remaining * 1_000)))
                    )
                )
            )
            if ready == 0 {
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw RouterMappingError.socket("SSDP poll() failed")
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else {
                if descriptor.revents
                    & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw RouterMappingError.socket(
                        "SSDP socket became unavailable"
                    )
                }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count > 0 {
                responses.append(Data(buffer.prefix(count)))
                try checkOperation()
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0,
                      errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw RouterMappingError.socket("SSDP recv() failed")
            }
        }
        return responses
    }

    private static func ipv6ScopeInterface(in address: String) -> String? {
        guard let separator = address.firstIndex(of: "%") else { return nil }
        let interfaceName = address[address.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceName.isEmpty ? nil : interfaceName
    }

    private func performUDPTransaction<Response>(
        host: String,
        port: UInt16,
        retryIntervals: [TimeInterval],
        sourceAddressHint: String?,
        operation: String,
        stateChangingRequest: Bool,
        payloadBuilder: (String) throws -> Data,
        parseResponse: (Data) throws -> Response
    ) throws -> Response {
        try performUDPTransactionWithSource(
            host: host,
            port: port,
            retryIntervals: retryIntervals,
            sourceAddressHint: sourceAddressHint,
            operation: operation,
            stateChangingRequest: stateChangingRequest,
            payloadBuilder: payloadBuilder,
            parseResponse: parseResponse
        ).response
    }

    private func performUDPTransactionWithSource<Response>(
        host: String,
        port: UInt16,
        retryIntervals: [TimeInterval],
        sourceAddressHint: String?,
        operation: String,
        stateChangingRequest: Bool,
        payloadBuilder: (String) throws -> Data,
        parseResponse: (Data) throws -> Response
    ) throws -> RouterMappingUDPTransactionResult<Response> {
        precondition(!retryIntervals.isEmpty)
        let acceptsResponse: (Data) throws -> Bool = { response in
            do {
                _ = try parseResponse(response)
                return true
            } catch let error as RouterMappingError {
                if case .invalidResponse = error {
                    return false
                }
                throw error
            }
        }
        var effectiveSourceAddress: String?
        do {
            let response = try udpTransaction(
                host: host,
                port: port,
                retryIntervals: retryIntervals,
                sourceAddressHint: sourceAddressHint,
                operation: operation,
                stateChangingRequest: stateChangingRequest,
                payloadBuilder: { selectedSourceAddress in
                    effectiveSourceAddress = selectedSourceAddress
                    return try payloadBuilder(selectedSourceAddress)
                },
                acceptsResponse: acceptsResponse
            )
            guard let effectiveSourceAddress else {
                throw RouterMappingError.protocolFailure(
                    "\(operation) did not select an effective source address"
                )
            }
            return RouterMappingUDPTransactionResult(
                response: try parseResponse(response),
                effectiveSourceAddress: effectiveSourceAddress
            )
        } catch let error as RouterMappingUDPError {
            throw RouterMappingUDPError(
                underlying: error.underlying,
                requestMayHaveReachedRouter:
                    error.requestMayHaveReachedRouter,
                effectiveSourceAddress:
                    error.effectiveSourceAddress
                    ?? effectiveSourceAddress
            )
        }
    }

    private func udpTransaction(
        host: String,
        port: UInt16,
        retryIntervals: [TimeInterval],
        sourceAddressHint: String?,
        operation: String,
        stateChangingRequest: Bool,
        payloadBuilder: (String) throws -> Data,
        acceptsResponse: (Data) throws -> Bool
    ) throws -> Data {
        guard let operationContext = currentOperationContext else {
            throw RouterMappingUDPError(
                underlying: .cancelled,
                requestMayHaveReachedRouter: false
            )
        }
        try checkUDPOperation(
            operationContext,
            requestMayHaveReachedRouter: false
        )
        if let udpTransactionHandler {
            let response = try udpTransactionHandler(
                host,
                port,
                retryIntervals,
                sourceAddressHint,
                payloadBuilder,
                acceptsResponse
            )
            try checkUDPOperation(
                operationContext,
                requestMayHaveReachedRouter: stateChangingRequest
            )
            return response
        }
        if let udpRequestHandler {
            let selectedSourceAddress = sourceAddressHint ?? "0.0.0.0"
            try checkUDPOperation(
                operationContext,
                requestMayHaveReachedRouter: false
            )
            let payload = try payloadBuilder(selectedSourceAddress)
            var requestMayHaveReachedRouter = false
            var lastError: RouterMappingError = .timeout(
                "\(operation) received no matching response"
            )

            for timeout in retryIntervals {
                try checkUDPOperation(
                    operationContext,
                    requestMayHaveReachedRouter:
                        requestMayHaveReachedRouter
                )
                do {
                    let response = try udpRequestHandler(
                        payload,
                        host,
                        port,
                        timeout
                    )
                    requestMayHaveReachedRouter = true
                    try checkUDPOperation(
                        operationContext,
                        requestMayHaveReachedRouter:
                            stateChangingRequest
                    )
                    if try acceptsResponse(response) {
                        return response
                    }
                    lastError = .invalidResponse(
                        "\(operation) ignored an unrelated or malformed response"
                    )
                } catch let error as RouterMappingUDPError {
                    requestMayHaveReachedRouter =
                        requestMayHaveReachedRouter
                        || error.requestMayHaveReachedRouter
                    lastError = error.underlying
                } catch let error as RouterMappingError {
                    switch error {
                    case .uncertainAfterSend:
                        requestMayHaveReachedRouter = true
                    case .cancelledAfterSend:
                        throw RouterMappingUDPError(
                            underlying: .cancelled,
                            requestMayHaveReachedRouter: true
                        )
                    case .cancelled:
                        throw RouterMappingUDPError(
                            underlying: error,
                            requestMayHaveReachedRouter: requestMayHaveReachedRouter
                        )
                    case .pcpResultCode,
                         .natPMPVersionNegotiation,
                         .natPMPResultCode,
                         .protocolFailure:
                        throw error
                    default:
                        break
                    }
                    lastError = error
                } catch {
                    throw error
                }
            }
            throw RouterMappingUDPError(
                underlying: lastError,
                requestMayHaveReachedRouter: requestMayHaveReachedRouter
            )
        }

        try checkUDPOperation(
            operationContext,
            requestMayHaveReachedRouter: false
        )
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var results: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &results)
        guard lookup == 0, let first = results else {
            let detail = lookup == 0
                ? "no address"
                : String(cString: gai_strerror(lookup))
            throw RouterMappingUDPError(
                underlying: .socket(
                    "Could not resolve UDP destination \(host): \(detail)"
                ),
                requestMayHaveReachedRouter: false
            )
        }
        defer { freeaddrinfo(results) }

        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var lastFailure = RouterMappingUDPError(
            underlying: .socket("No usable UDP address for \(host)"),
            requestMayHaveReachedRouter: false
        )
        while let current = pointer {
            try checkUDPOperation(
                operationContext,
                requestMayHaveReachedRouter: false
            )
            pointer = current.pointee.ai_next
            let socketFD = socketOperations.makeSocket(
                current.pointee.ai_family,
                current.pointee.ai_socktype,
                current.pointee.ai_protocol
            )
            guard socketFD >= 0 else {
                lastFailure = RouterMappingUDPError(
                    underlying: .socket("socket() failed for \(host)"),
                    requestMayHaveReachedRouter: false
                )
                continue
            }

            let connected = socketOperations.connectSocket(
                socketFD,
                current.pointee.ai_addr,
                current.pointee.ai_addrlen
            )
            guard connected == 0 else {
                lastFailure = RouterMappingUDPError(
                    underlying: .socket("connect() failed for \(host):\(port)"),
                    requestMayHaveReachedRouter: false
                )
                socketOperations.closeSocket(socketFD)
                continue
            }

            do {
                let selectedSourceAddress = try connectedSourceAddress(
                    socketFD: socketFD
                )
                try checkUDPOperation(
                    operationContext,
                    requestMayHaveReachedRouter: false
                )
                let payload = try payloadBuilder(selectedSourceAddress)
                let response = try runConnectedUDPTransaction(
                    socketFD: socketFD,
                    payload: payload,
                    host: host,
                    port: port,
                    retryIntervals: retryIntervals,
                    operation: operation,
                    operationContext: operationContext,
                    acceptsResponse: acceptsResponse
                )
                socketOperations.closeSocket(socketFD)
                return response
            } catch let failure as RouterMappingUDPError {
                socketOperations.closeSocket(socketFD)
                lastFailure = failure
                if stateChangingRequest,
                   failure.requestMayHaveReachedRouter {
                    throw failure
                }
            } catch {
                socketOperations.closeSocket(socketFD)
                throw error
            }
        }
        throw lastFailure
    }

    private func runConnectedUDPTransaction(
        socketFD: Int32,
        payload: Data,
        host: String,
        port: UInt16,
        retryIntervals: [TimeInterval],
        operation: String,
        operationContext: RouterMappingOperationContext,
        acceptsResponse: (Data) throws -> Bool
    ) throws -> Data {
        var requestMayHaveReachedRouter = false
        var lastError: RouterMappingError = .timeout(
            "\(operation) received no matching response"
        )

        for timeout in retryIntervals {
            try checkUDPOperation(
                operationContext,
                requestMayHaveReachedRouter:
                    requestMayHaveReachedRouter
            )

            try checkUDPOperation(
                operationContext,
                requestMayHaveReachedRouter:
                    requestMayHaveReachedRouter
            )
            let sent = payload.withUnsafeBytes { bytes -> ssize_t in
                guard let base = bytes.baseAddress else { return -1 }
                return socketOperations.sendDatagram(
                    socketFD,
                    base,
                    payload.count
                )
            }
            if sent == payload.count {
                requestMayHaveReachedRouter = true
                try checkUDPOperation(
                    operationContext,
                    requestMayHaveReachedRouter: true
                )
            } else {
                lastError = .socket("send() failed for \(host):\(port)")
                if !requestMayHaveReachedRouter {
                    continue
                }
            }

            let retryDeadline =
                monotonicUptimeProvider() + timeout
            let deadline = min(
                retryDeadline,
                operationContext.absoluteDeadlineUptime
                    ?? retryDeadline
            )
            while monotonicUptimeProvider() < deadline {
                try checkUDPOperation(
                    operationContext,
                    requestMayHaveReachedRouter:
                        requestMayHaveReachedRouter
                )

                let remaining =
                    deadline - monotonicUptimeProvider()
                let pollMilliseconds = Int32(
                    max(1, min(100, Int(ceil(remaining * 1_000))))
                )
                var descriptor = pollfd(
                    fd: socketFD,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let ready = Darwin.poll(&descriptor, 1, pollMilliseconds)
                if ready == 0 {
                    continue
                }
                if ready < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw RouterMappingUDPError(
                        underlying: .socket(
                            "poll() failed for \(host):\(port)"
                        ),
                        requestMayHaveReachedRouter: requestMayHaveReachedRouter
                    )
                }
                if descriptor.revents & Int16(POLLIN) != 0 {
                    var buffer = [UInt8](repeating: 0, count: 2_048)
                    let count = recv(socketFD, &buffer, buffer.count, 0)
                    if count > 0 {
                        let response = Data(buffer.prefix(count))
                        if try acceptsResponse(response) {
                            try checkUDPOperation(
                                operationContext,
                                requestMayHaveReachedRouter:
                                    requestMayHaveReachedRouter
                            )
                            return response
                        }
                        lastError = .invalidResponse(
                            "\(operation) ignored an unrelated or malformed datagram"
                        )
                        continue
                    }
                    if count < 0, errno == EINTR {
                        continue
                    }
                    throw RouterMappingUDPError(
                        underlying: .socket(
                            "recv() failed for \(host):\(port)"
                        ),
                        requestMayHaveReachedRouter: requestMayHaveReachedRouter
                    )
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(
                        socketFD,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &length
                    )
                    throw RouterMappingUDPError(
                        underlying: .socket(
                            "UDP socket error \(socketError) for \(host):\(port)"
                        ),
                        requestMayHaveReachedRouter: requestMayHaveReachedRouter
                    )
                }
            }
            lastError = .timeout(
                "\(operation) received no matching response within \(timeout)s"
            )
        }

        throw RouterMappingUDPError(
            underlying: lastError,
            requestMayHaveReachedRouter: requestMayHaveReachedRouter
        )
    }

    private func checkUDPOperation(
        _ context: RouterMappingOperationContext,
        requestMayHaveReachedRouter: Bool
    ) throws {
        do {
            try checkOperation(context)
        } catch let error as RouterMappingError {
            throw RouterMappingUDPError(
                underlying: error,
                requestMayHaveReachedRouter:
                    requestMayHaveReachedRouter
            )
        }
    }

    private func connectedSourceAddress(socketFD: Int32) throws -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard status == 0 else {
            throw RouterMappingUDPError(
                underlying: .socket("getsockname() failed"),
                requestMayHaveReachedRouter: false
            )
        }

        switch Int32(storage.ss_family) {
        case AF_INET:
            var address = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET,
                &address,
                &buffer,
                socklen_t(INET_ADDRSTRLEN)
            ) != nil else {
                throw RouterMappingUDPError(
                    underlying: .socket("Could not format connected IPv4 source"),
                    requestMayHaveReachedRouter: false
                )
            }
            return String(cString: buffer)
        case AF_INET6:
            let socketAddress = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee
                }
            }
            var address = socketAddress.sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET6,
                &address,
                &buffer,
                socklen_t(INET6_ADDRSTRLEN)
            ) != nil else {
                throw RouterMappingUDPError(
                    underlying: .socket("Could not format connected IPv6 source"),
                    requestMayHaveReachedRouter: false
                )
            }
            let formatted = String(cString: buffer)
            guard socketAddress.sin6_scope_id != 0 else {
                return formatted
            }
            var interfaceBuffer = [CChar](
                repeating: 0,
                count: Int(IF_NAMESIZE)
            )
            guard if_indextoname(
                socketAddress.sin6_scope_id,
                &interfaceBuffer
            ) != nil else {
                return "\(formatted)%\(socketAddress.sin6_scope_id)"
            }
            return "\(formatted)%\(String(cString: interfaceBuffer))"
        default:
            throw RouterMappingUDPError(
                underlying: .socket("Connected UDP socket has an unsupported address family"),
                requestMayHaveReachedRouter: false
            )
        }
    }

    private func throwIfCancelled() throws {
        try checkOperation()
    }

    private func udpRequest(
        payload: Data,
        host: String,
        port: UInt16,
        timeoutSeconds: TimeInterval
    ) throws -> Data {
        try throwIfCancelled()
        if let udpRequestHandler {
            return try udpRequestHandler(payload, host, port, timeoutSeconds)
        }
        return try performUDPTransaction(
            host: host,
            port: port,
            retryIntervals: [timeoutSeconds],
            sourceAddressHint: nil,
            operation: "UDP request",
            stateChangingRequest: false,
            payloadBuilder: { _ in payload },
            parseResponse: { $0 }
        )
    }

    private static func isUncertainCreationError(_ error: Error) -> Bool {
        (error as? RouterMappingUDPError)?.requestMayHaveReachedRouter == true
    }

    private func pcpNonce(config: AppConfig) -> Data {
        if let encoded = config.pcpNonce,
           let stored = Data(base64Encoded: encoded),
           stored.count == 12 {
            return stored
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func uniqueHeaderValue(
        _ name: String,
        in text: String,
        normalizer: (String?) -> String?
    ) -> (value: String?, conflicting: Bool) {
        let normalizedName = name.lowercased()
        var values = Set<String>()
        var matchingHeaderCount = 0
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2
                && parts[0].trimmingCharacters(
                    in: .whitespaces
                ).lowercased() == normalizedName {
                matchingHeaderCount += 1
                let rawValue = parts[1].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard let normalized = normalizer(rawValue) else {
                    return (nil, true)
                }
                values.insert(normalized)
            }
        }
        if values.count > 1 {
            return (nil, true)
        }
        if matchingHeaderCount == 0 {
            return (nil, false)
        }
        return (values.first, false)
    }

    private static func uniqueHeaderValue(
        _ name: String,
        in text: String,
        normalizer: (String) -> String?
    ) -> (value: String?, conflicting: Bool) {
        uniqueHeaderValue(name, in: text) { value in
            value.flatMap(normalizer)
        }
    }

    private static func xmlValues(in data: Data) -> [String: String] {
        XMLValueParser.parse(data)
    }

    private static func xmlBoolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
    }
}

struct PCPMappingResponse {
    let externalPort: UInt16
    let lifetimeSeconds: UInt32
    let externalAddress: String?
    let epochTime: UInt32
}

private struct PCPMappingTransactionResult {
    let response: PCPMappingResponse
    let effectiveClientAddress: String
}

struct PCPMessageCodec {
    static func makeAnnounceRequest(clientAddress: String) throws -> Data {
        var request = Data([2, 0, 0, 0])
        request.appendUInt32(0)
        request.append(try addressBytes(clientAddress))
        return request
    }

    static func parseAnnounceResponse(_ response: Data) throws -> UInt32 {
        if response.count >= 8,
           response[0] == 0,
           response[1] == 0,
           response.readUInt16(at: 2) == 1 {
            throw RouterMappingError.natPMPVersionNegotiation(
                response.readUInt32(at: 4)
            )
        }
        guard response.count >= 24,
              response.count <= 1_100,
              response.count.isMultiple(of: 4) else {
            throw RouterMappingError.invalidResponse(
                "PCP ANNOUNCE response length is invalid"
            )
        }
        guard response[0] == 2, response[1] == 0x80, response[2] == 0 else {
            throw RouterMappingError.invalidResponse(
                "Unexpected PCP ANNOUNCE response"
            )
        }
        guard response.readUInt32(at: 4) == 0 else {
            throw RouterMappingError.invalidResponse(
                "PCP ANNOUNCE response lifetime must be zero"
            )
        }
        let resultCode = response[3]
        guard resultCode == 0 else {
            throw RouterMappingError.pcpResultCode(resultCode)
        }
        return response.readUInt32(at: 8)
    }

    static func makeMapRequest(
        lifetime: UInt32,
        clientAddress: String,
        nonce: Data,
        internalPort: UInt16,
        suggestedExternalPort: UInt16
    ) throws -> Data {
        guard nonce.count == 12 else {
            throw RouterMappingError.protocolFailure("PCP nonce must be 12 bytes")
        }
        var request = Data([2, 1, 0, 0])
        request.appendUInt32(lifetime)
        request.append(try addressBytes(clientAddress))
        request.append(nonce)
        request.append(6)
        request.append(contentsOf: [0, 0, 0])
        request.appendUInt16(internalPort)
        request.appendUInt16(lifetime == 0 ? 0 : suggestedExternalPort)
        request.append(Data(repeating: 0, count: 16))
        return request
    }

    static func parseMapResponse(
        _ response: Data,
        nonce: Data,
        internalPort: UInt16,
        requestedLifetime: UInt32
    ) throws -> PCPMappingResponse {
        guard response.count >= 24,
              response.count <= 1_100,
              response.count.isMultiple(of: 4) else {
            throw RouterMappingError.invalidResponse(
                "PCP MAP response length is invalid"
            )
        }
        guard response[0] == 2, response[1] == 0x81, response[2] == 0 else {
            throw RouterMappingError.invalidResponse("Unexpected PCP MAP opcode")
        }
        let resultCode = response[3]
        guard resultCode == 0 else {
            throw RouterMappingError.pcpResultCode(resultCode)
        }
        guard response.count >= 60 else {
            throw RouterMappingError.invalidResponse("PCP MAP response too short")
        }
        guard Data(response[24..<36]) == nonce, response[36] == 6 else {
            throw RouterMappingError.invalidResponse("PCP MAP response did not match the request")
        }
        let confirmedInternalPort = response.readUInt16(at: 40)
        let externalPort = response.readUInt16(at: 42)
        let responseLifetime = response.readUInt32(at: 4)
        let externalAddressData = Data(response[44..<60])
        guard confirmedInternalPort == internalPort else {
            throw RouterMappingError.invalidResponse("PCP confirmed unexpected internal port \(confirmedInternalPort)")
        }
        if requestedLifetime > 0, responseLifetime == 0 {
            throw RouterMappingError.protocolFailure("PCP router returned a zero-second lease")
        }
        if requestedLifetime == 0,
           responseLifetime != 0
            || externalPort != 0
            || externalAddressData.contains(where: { $0 != 0 }) {
            throw RouterMappingError.protocolFailure(
                "PCP delete response retained a nonzero lifetime or external endpoint"
            )
        }
        return PCPMappingResponse(
            externalPort: externalPort,
            lifetimeSeconds: responseLifetime,
            externalAddress: addressString(externalAddressData),
            epochTime: response.readUInt32(at: 8)
        )
    }

    static func addressBytes(_ value: String) throws -> Data {
        let address = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var result = Data(repeating: 0, count: 10)
            result.append(contentsOf: [0xff, 0xff])
            withUnsafeBytes(of: &ipv4) { result.append(contentsOf: $0) }
            return result
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: &ipv6) { Data($0) }
        }
        throw RouterMappingError.protocolFailure("Invalid PCP client address: \(value)")
    }

    static func addressString(_ data: Data) -> String? {
        guard data.count == 16, data.contains(where: { $0 != 0 }) else { return nil }
        let bytes = Array(data)
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            var address = in_addr()
            _ = withUnsafeMutableBytes(of: &address) { destination in
                data[12..<16].copyBytes(to: destination)
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }

        var address = in6_addr()
        _ = withUnsafeMutableBytes(of: &address) { destination in
            data.copyBytes(to: destination)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}

private struct NATPMPMappingResponse {
    let externalPort: UInt16
    let lifetimeSeconds: UInt32
    let epochTime: UInt32
}

private struct NATPMPMappingTransactionResult {
    let response: NATPMPMappingResponse
    let effectiveClientAddress: String
}

private struct NATPMPExternalAddressResponse {
    let address: String
    let epochTime: UInt32
    let epochObservation: RouterEpochProbeResult
    let effectiveClientAddress: String
}

struct UPnPService {
    let serviceType: String
    let controlURL: URL
    let gatewayIdentity: String
    var descriptionURL: URL? = nil
    var deviceIdentity: String? = nil
    var allowsCrossFamilyControl: Bool = false
    var ssdpBootID: String? = nil
    var ssdpConfigID: String? = nil

    func isBound(to gatewayAddress: String) -> Bool {
        let expected = normalizedGatewayIdentity(gatewayAddress)
        guard !expected.isEmpty,
              normalizedGatewayIdentity(gatewayIdentity) == expected else {
            return false
        }
        if allowsCrossFamilyControl {
            return deviceIdentity.map {
                !normalizedUPnPDeviceIdentity($0).isEmpty
            } ?? false
        }
        guard let controlHost = controlURL.host else { return false }
        guard normalizedGatewayIdentity(controlHost) == expected else {
            return false
        }
        if let descriptionURL {
            guard let descriptionHost = descriptionURL.host,
                  normalizedGatewayIdentity(descriptionHost) == expected else {
                return false
            }
        }
        return true
    }
}

private enum UPnPServiceRole {
    case ipv4PortMapping
    case ipv6Firewall

    func matches(_ serviceType: String) -> Bool {
        switch self {
        case .ipv4PortMapping:
            return serviceType.contains("WANIPConnection")
                || serviceType.contains("WANPPPConnection")
        case .ipv6Firewall:
            return serviceType.contains("WANIPv6FirewallControl")
        }
    }
}

private struct UPnPControlBinding: Codable {
    private static let prefix = "gatebeam-upnp-v1:"

    let serviceType: String
    let controlURL: String
    let gatewayIdentity: String
    let descriptionURL: String
    let deviceIdentity: String
    let allowsCrossFamilyControl: Bool
    let ssdpBootID: String?
    let ssdpConfigID: String?

    private enum CodingKeys: String, CodingKey {
        case serviceType
        case controlURL
        case gatewayIdentity
        case descriptionURL
        case deviceIdentity
        case allowsCrossFamilyControl
        case ssdpBootID
        case ssdpConfigID
    }

    init(service: UPnPService, gatewayAddress: String) throws {
        guard service.isBound(to: gatewayAddress),
              let descriptionURL = service.descriptionURL,
              let deviceIdentity = service.deviceIdentity,
              !deviceIdentity.isEmpty else {
            throw RouterMappingError.protocolFailure(
                "Discovered UPnP service lacks a bound IGD identity for gateway \(gatewayAddress)"
            )
        }
        serviceType = service.serviceType
        controlURL = service.controlURL.absoluteString
        gatewayIdentity = gatewayAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.descriptionURL = descriptionURL.absoluteString
        self.deviceIdentity = normalizedUPnPDeviceIdentity(deviceIdentity)
        self.allowsCrossFamilyControl = service.allowsCrossFamilyControl
        self.ssdpBootID = normalizedUPnPVersionIdentifier(
            service.ssdpBootID
        )
        self.ssdpConfigID = normalizedUPnPVersionIdentifier(
            service.ssdpConfigID
        )
        if service.serviceType.contains("WANIPv6FirewallControl"),
           self.ssdpBootID == nil || self.ssdpConfigID == nil {
            throw RouterMappingError.protocolFailure(
                "Discovered IPv6 UPnP service lacks valid SSDP BOOTID/CONFIGID metadata"
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceType = try container.decode(String.self, forKey: .serviceType)
        controlURL = try container.decode(String.self, forKey: .controlURL)
        gatewayIdentity = try container.decode(String.self, forKey: .gatewayIdentity)
        descriptionURL = try container.decode(String.self, forKey: .descriptionURL)
        deviceIdentity = try container.decode(String.self, forKey: .deviceIdentity)
        allowsCrossFamilyControl = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsCrossFamilyControl
        ) ?? false
        ssdpBootID = try container.decodeIfPresent(
            String.self,
            forKey: .ssdpBootID
        )
        ssdpConfigID = try container.decodeIfPresent(
            String.self,
            forKey: .ssdpConfigID
        )
    }

    func encoded() throws -> String {
        Self.prefix + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    static func decode(_ value: String) throws -> UPnPControlBinding {
        guard value.hasPrefix(prefix),
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP mapping has no valid bound IGD metadata"
            )
        }
        do {
            return try JSONDecoder().decode(UPnPControlBinding.self, from: data)
        } catch {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP IGD metadata is unreadable"
            )
        }
    }
}

private func normalizedGatewayIdentity(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("["), normalized.hasSuffix("]") {
        normalized.removeFirst()
        normalized.removeLast()
    }
    normalized = normalized.replacingOccurrences(of: "%25", with: "%")
    if let scope = normalized.firstIndex(of: "%") {
        normalized = String(normalized[..<scope])
    }
    if let ipv6 = PublicIPService.normalizedIPv6(normalized) {
        return ipv6
    }
    return normalized
}

private func normalizedUPnPDeviceIdentity(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.components(separatedBy: "::").first ?? normalized
}

private func normalizedUPnPVersionIdentifier(
    _ value: String?
) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.allSatisfy(\.isNumber),
          let numeric = UInt64(trimmed) else {
        return nil
    }
    return String(numeric)
}

private struct UPnPServiceDescription {
    let urlBase: String?
    let deviceIdentity: String?
    let services: [(serviceType: String, controlURL: String)]
}

private final class UPnPDescriptionParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var text = ""
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var urlBase: String?
    private var deviceIdentity: String?
    private var services: [(serviceType: String, controlURL: String)] = []

    static func parse(_ data: Data) -> UPnPServiceDescription {
        let delegate = UPnPDescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return UPnPServiceDescription(
            urlBase: delegate.urlBase,
            deviceIdentity: delegate.deviceIdentity,
            services: delegate.services
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = Self.localName(qName ?? elementName)
        text = ""
        if currentElement == "service" {
            currentServiceType = nil
            currentControlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = Self.localName(qName ?? elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "URLBase":
            if !value.isEmpty { urlBase = value }
        case "UDN":
            if deviceIdentity == nil, !value.isEmpty { deviceIdentity = value }
        case "serviceType":
            if !value.isEmpty { currentServiceType = value }
        case "controlURL":
            if !value.isEmpty { currentControlURL = value }
        case "service":
            if let serviceType = currentServiceType, let controlURL = currentControlURL {
                services.append((serviceType, controlURL))
            }
        default:
            break
        }
        currentElement = ""
        text = ""
    }

    private static func localName(_ value: String) -> String {
        String(value.split(separator: ":").last ?? Substring(value))
    }
}

private final class XMLValueParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var values: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = XMLValueParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.values
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let key = String((qName ?? elementName).split(separator: ":").last ?? Substring(elementName))
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            values[key] = value
        }
        text = ""
    }
}

enum RouterMappingError: Error, LocalizedError {
    case disabled
    case cancelled
    case cancelledAfterSend
    case socket(String)
    case timeout(String)
    case uncertainAfterSend(String)
    case invalidResponse(String)
    case protocolFailure(String)
    case pcpResultCode(UInt8)
    case natPMPVersionNegotiation(UInt32)
    case natPMPResultCode(UInt16)
    case upnpFault(action: String, serviceType: String, statusCode: Int, errorCode: Int?, description: String?)
    case allProtocolsFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Router mapping is disabled"
        case .cancelled:
            return "Router mapping was cancelled"
        case .cancelledAfterSend:
            return "Router mapping was cancelled after the UDP request was sent"
        case .socket(let message), .timeout(let message), .uncertainAfterSend(let message), .invalidResponse(let message), .protocolFailure(let message), .allProtocolsFailed(let message):
            return message
        case .pcpResultCode(let code):
            return "PCP result code \(code)"
        case .natPMPVersionNegotiation:
            return "Gateway answered PCP with NAT-PMP version 0; switching protocols"
        case .natPMPResultCode(let code):
            return "NAT-PMP result code \(code)"
        case .upnpFault(let action, _, let statusCode, let errorCode, let description):
            let code = errorCode.map { " code \($0)" } ?? ""
            let detail = description.map { ": \($0)" } ?? ""
            return "UPnP \(action) failed: HTTP \(statusCode)\(code)\(detail)"
        }
    }

    var isRetriableUDPExchangeFailure: Bool {
        switch self {
        case .timeout, .uncertainAfterSend, .invalidResponse:
            return true
        default:
            return false
        }
    }

    var isIdempotentIPv4UPnPDeletionMiss: Bool {
        guard isMissingIPv4UPnPMapping else { return false }
        guard case .upnpFault(let action, _, _, _, _) = self else { return false }
        return action == "DeletePortMapping"
    }

    var isMissingIPv4UPnPMapping: Bool {
        guard case .upnpFault(
            let action,
            let serviceType,
            _,
            let errorCode,
            let description
        ) = self,
              action == "DeletePortMapping" || action == "GetSpecificPortMappingEntry",
              serviceType.contains("WANIPConnection")
                || serviceType.contains("WANPPPConnection") else {
            return false
        }
        if let errorCode {
            return errorCode == 714
        }
        return Self.isNoSuchEntryDescription(description)
    }

    var isConclusiveUPnPAddRejection: Bool {
        guard case .upnpFault(let action, _, _, _, _) = self else { return false }
        return action == "AddPortMapping" || action == "AddPinhole"
    }

    var isIdempotentIPv6UPnPDeletionMiss: Bool {
        guard case .upnpFault(
            let action,
            let serviceType,
            _,
            let errorCode,
            let description
        ) = self,
              action == "DeletePinhole",
              serviceType.contains("WANIPv6FirewallControl") else {
            return false
        }
        if let errorCode {
            return errorCode == 704
        }
        return Self.isNoSuchEntryDescription(description)
    }

    var isMissingIPv6UPnPPinholeForUpdate: Bool {
        guard case .upnpFault(
            let action,
            let serviceType,
            _,
            let errorCode,
            let description
        ) = self,
              action == "UpdatePinhole",
              serviceType.contains("WANIPv6FirewallControl") else {
            return false
        }
        if let errorCode {
            return errorCode == 704
        }
        return Self.isNoSuchEntryDescription(description)
    }

    private static func isNoSuchEntryDescription(_ description: String?) -> Bool {
        let normalized = (description ?? "").lowercased().filter(\.isLetter)
        return normalized.contains("nosuchentry") || normalized.contains("notfound")
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func readUInt16(at index: Int) -> UInt16 {
        (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    func readUInt32(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24) | (UInt32(self[index + 1]) << 16) | (UInt32(self[index + 2]) << 8) | UInt32(self[index + 3])
    }
}
