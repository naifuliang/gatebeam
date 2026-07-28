import Foundation
import Darwin

struct PortMappingResult {
    let protocolName: String
    let externalPort: UInt16
    let routerExternalAddress: String?
    let message: String
    var pinholeID: UInt16? = nil
    let activeMapping: ActiveRouterMapping
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
    func ensureMapping(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult
    func ensureIPv6Pinhole(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult
    func removeMappings(_ mappings: [ActiveRouterMapping]) -> RouterMappingRemovalReport
    func removeLegacyMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?
    ) -> RouterMappingRemovalReport
}

final class RouterMappingService: RouterMappingServicing {
    // Router control is always local. It must never follow a system or custom
    // proxy, which could leak private IGD requests or make discovery unusable.
    private let http = HTTPClient(useSystemProxy: false)
    private let upnpDiscoveryHandler: (() throws -> [UPnPService])?
    private let upnpDescriptionHandler: ((URL) throws -> Data)?
    private let soapRequestHandler: ((URL, String, String, String) throws -> HTTPResponse)?
    private let udpRequestHandler: ((Data, String, UInt16, Int) throws -> Data)?
    private let ssdpSearchHandler: ((UPnPDiscoveryRequest) throws -> [Data])?
    private let removalHandler: ((ActiveRouterMapping) throws -> Void)?
    private let nowProvider: () -> Date

    init(
        upnpDiscoveryHandler: (() throws -> [UPnPService])? = nil,
        upnpDescriptionHandler: ((URL) throws -> Data)? = nil,
        soapRequestHandler: ((URL, String, String, String) throws -> HTTPResponse)? = nil,
        udpRequestHandler: ((Data, String, UInt16, Int) throws -> Data)? = nil,
        ssdpSearchHandler: ((UPnPDiscoveryRequest) throws -> [Data])? = nil,
        removalHandler: ((ActiveRouterMapping) throws -> Void)? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.upnpDiscoveryHandler = upnpDiscoveryHandler
        self.upnpDescriptionHandler = upnpDescriptionHandler
        self.soapRequestHandler = soapRequestHandler
        self.udpRequestHandler = udpRequestHandler
        self.ssdpSearchHandler = ssdpSearchHandler
        self.removalHandler = removalHandler
        self.nowProvider = nowProvider
    }

    static func renewableUPnPLeaseSeconds(requested: UInt32, minimum: UInt32 = 60) -> UInt32 {
        min(max(requested, minimum), 86_400)
    }

    func externalIPv4Address(gatewayAddress: String) throws -> String {
        do {
            return try queryNATPMPExternalAddress(gatewayAddress: gatewayAddress)
        } catch {
            let service = try discoverUPnPService(gatewayAddress: gatewayAddress)
            return try queryUPnPExternalAddress(service: service)
        }
    }

    func inspectCapabilities(gatewayAddress: String) throws -> RouterCapabilityResult {
        var natPMPAvailable = false
        var upnpAvailable = false
        var externalAddress: String?
        var errors: [String] = []

        do {
            externalAddress = try queryNATPMPExternalAddress(gatewayAddress: gatewayAddress)
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

    func ensureMapping(config: AppConfig, localAddress: String, gatewayAddress: String) throws -> PortMappingResult {
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
                    try self.addPCPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        familyName: "IPv4"
                    )
                }),
                ("NAT-PMP", {
                    try self.addNATPMPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress
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
                    try self.addPCPMapping(
                        config: config,
                        localAddress: localAddress,
                        gatewayAddress: gatewayAddress,
                        familyName: "IPv6"
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

    static func firstSuccessfulAutomaticMapping(
        _ attempts: [(String, () throws -> PortMappingResult)]
    ) throws -> PortMappingResult {
        var errors: [String] = []
        for (name, attempt) in attempts {
            do {
                return try attempt()
            } catch let recovery as RouterMappingRecoveryRequiredError {
                throw recovery
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        throw RouterMappingError.allProtocolsFailed(errors.joined(separator: "\n"))
    }

    func removeMappings(_ mappings: [ActiveRouterMapping]) -> RouterMappingRemovalReport {
        RouterMappingRemovalReport(
            attempts: mappings.map { mapping in
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
        )
    }

    func removeLegacyMappings(
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
            try removalHandler(mapping)
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
                lifetime: 0
            )
        case (.ipv4, .natpmp):
            _ = try sendNATPMPMapping(
                config: config,
                gatewayAddress: mapping.gatewayAddress,
                lifetime: 0
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
                if nowProvider() >= mapping.leaseExpiresAt {
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
        pinholeID: UInt16? = nil,
        protocolState: String? = nil
    ) -> ActiveRouterMapping {
        let now = nowProvider()
        let effectiveLifetime = max(1, lifetime)
        let expiresAt = now.addingTimeInterval(TimeInterval(effectiveLifetime))
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
            pinholeID: pinholeID,
            pcpNonce: protocolState ?? (transport == .pcp ? config.pcpNonce : nil),
            leaseExpiresAt: expiresAt,
            renewAfter: expiresAt.addingTimeInterval(-renewalLead)
        )
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

        let remaining = floor(expiresAt.timeIntervalSince(nowProvider()))
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
        guard now < deadline, mapping.leaseExpiresAt <= deadline else {
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

    private func addPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        familyName: String
    ) throws -> PortMappingResult {
        let nonce = pcpNonce(config: config)
        let family: RouterMappingAddressFamily = familyName == "IPv6" ? .ipv6 : .ipv4
        let requestedLease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "PCP"
        )
        let response: PCPMappingResponse
        do {
            response = try sendPCPMapping(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                lifetime: requestedLease,
                nonce: nonce
            )
        } catch {
            guard Self.isUncertainCreationError(error) else { throw error }
            var candidate = activeMapping(
                config: config,
                transport: .pcp,
                family: family,
                localAddress: localAddress,
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
        var mapping = activeMapping(
            config: config,
            transport: .pcp,
            family: family,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            externalPort: response.externalPort,
            lifetime: response.lifetimeSeconds
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
        return PortMappingResult(
            protocolName: "PCP \(familyName)",
            externalPort: response.externalPort,
            routerExternalAddress: response.externalAddress,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s",
            activeMapping: mapping
        )
    }

    private func sendPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        lifetime: UInt32,
        nonce suppliedNonce: Data? = nil
    ) throws -> PCPMappingResponse {
        let nonce = suppliedNonce ?? pcpNonce(config: config)
        let request = try PCPMessageCodec.makeMapRequest(
            lifetime: lifetime,
            clientAddress: localAddress,
            nonce: nonce,
            internalPort: config.internalPort,
            suggestedExternalPort: config.externalPort
        )

        let response = try udpRequest(payload: request, host: gatewayAddress, port: 5351, timeoutSeconds: 3)
        return try PCPMessageCodec.parseMapResponse(
            response,
            nonce: nonce,
            internalPort: config.internalPort,
            requestedLifetime: lifetime
        )
    }

    private func addNATPMPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        let requestedLease = try effectiveLeaseSeconds(
            config: config,
            protocolName: "NAT-PMP"
        )
        let response: NATPMPMappingResponse
        do {
            response = try sendNATPMPMapping(
                config: config,
                gatewayAddress: gatewayAddress,
                lifetime: requestedLease
            )
        } catch {
            guard Self.isUncertainCreationError(error) else { throw error }
            let candidate = activeMapping(
                config: config,
                transport: .natpmp,
                family: .ipv4,
                localAddress: localAddress,
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
        var mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "NAT-PMP",
            mapping: activeMapping(
                config: config,
                transport: .natpmp,
                family: .ipv4,
                localAddress: localAddress,
                gatewayAddress: gatewayAddress,
                externalPort: response.externalPort,
                lifetime: response.lifetimeSeconds
            )
        )
        guard response.lifetimeSeconds <= requestedLease else {
            throw RouterMappingRecoveryRequiredError(
                mapping: mapping,
                operationDescription:
                    "NAT-PMP returned a \(response.lifetimeSeconds)s lease after Gatebeam requested at most \(requestedLease)s.",
                cleanupDescription: "The overlong lease must be removed before temporary access can be trusted."
            )
        }
        let routerExternalAddress = try? queryNATPMPExternalAddress(gatewayAddress: gatewayAddress)
        mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "NAT-PMP",
            mapping: mapping
        )
        return PortMappingResult(
            protocolName: "NAT-PMP",
            externalPort: response.externalPort,
            routerExternalAddress: routerExternalAddress,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s",
            activeMapping: mapping
        )
    }

    private func sendNATPMPMapping(config: AppConfig, gatewayAddress: String, lifetime: UInt32) throws -> NATPMPMappingResponse {
        var request = Data()
        request.append(0)
        request.append(2)
        request.append(contentsOf: [0, 0])
        request.appendUInt16(config.internalPort)
        request.appendUInt16(config.externalPort)
        request.appendUInt32(lifetime)

        let response = try udpRequest(payload: request, host: gatewayAddress, port: 5351, timeoutSeconds: 3)
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
            throw RouterMappingError.invalidResponse("NAT-PMP confirmed unexpected internal port \(internalPort)")
        }
        if lifetime > 0, lifetimeSeconds == 0 {
            throw RouterMappingError.protocolFailure("NAT-PMP router returned a zero-second lease")
        }
        return NATPMPMappingResponse(
            externalPort: externalPort,
            lifetimeSeconds: lifetimeSeconds
        )
    }

    private func queryNATPMPExternalAddress(gatewayAddress: String) throws -> String {
        let response = try udpRequest(payload: Data([0, 0]), host: gatewayAddress, port: 5351, timeoutSeconds: 3)
        guard response.count >= 12, response[0] == 0, response[1] == 128 else {
            throw RouterMappingError.invalidResponse("Invalid NAT-PMP public address response")
        }
        let resultCode = response.readUInt16(at: 2)
        guard resultCode == 0 else {
            throw RouterMappingError.protocolFailure("NAT-PMP public address result code \(resultCode)")
        }
        return "\(response[8]).\(response[9]).\(response[10]).\(response[11])"
    }

    private func addUPnPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        let service = try discoverUPnPService(gatewayAddress: gatewayAddress)
        let binding = try UPnPControlBinding(service: service, gatewayAddress: gatewayAddress).encoded()
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
        let routerExternalAddress = try? queryUPnPExternalAddress(service: service)
        mapping = try enforceAbsoluteAccessDeadline(
            config: config,
            protocolName: "UPnP IPv4",
            mapping: mapping
        )
        return PortMappingResult(
            protocolName: "UPnP IGD",
            externalPort: config.externalPort,
            routerExternalAddress: routerExternalAddress,
            message: "Verified TCP \(config.externalPort) -> \(localAddress):\(config.internalPort), \(confirmedLease)s lease",
            activeMapping: mapping
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
        gatewayAddress: String
    ) throws -> PortMappingResult {
        guard PublicIPService.isGlobalIPv6(localAddress) else {
            throw RouterMappingError.protocolFailure("UPnP IPv6 pinholes require a global IPv6 address on this Mac")
        }
        let service = try discoverUPnPIPv6FirewallService(gatewayAddress: gatewayAddress)
        let binding = try UPnPControlBinding(service: service, gatewayAddress: gatewayAddress).encoded()
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

        let mapping = try enforceAbsoluteAccessDeadline(
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
        return PortMappingResult(
            protocolName: "UPnP IPv6 Firewall",
            externalPort: config.internalPort,
            routerExternalAddress: localAddress,
            message: "Opened IPv6 TCP \(config.internalPort) to \(localAddress) for \(lease)s",
            pinholeID: pinholeID,
            activeMapping: mapping
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
            allowsCrossFamilyControl: binding.allowsCrossFamilyControl
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
        try verifyBoundUPnPIdentity(service)
        return service
    }

    private func verifyBoundUPnPIdentity(_ service: UPnPService) throws {
        guard let descriptionURL = service.descriptionURL,
              let expectedIdentity = service.deviceIdentity,
              !expectedIdentity.isEmpty else {
            throw RouterMappingError.protocolFailure(
                "The tracked UPnP mapping predates IGD device identity metadata"
            )
        }
        let currentServices = try parseUPnPDescription(
            location: descriptionURL,
            fallbackDeviceIdentity: expectedIdentity,
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
            return try upnpDiscoveryHandler()
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
            responses = try ssdpSearchHandler(request)
        } else {
            switch addressFamily {
            case .ipv4:
                responses = try udpMulticastSearchIPv4(request)
            case .ipv6:
                responses = try udpMulticastSearchIPv6(request)
            }
        }
        let endpoints = responses.compactMap { response -> (URL, String?)? in
            let text = String(data: response, encoding: .utf8) ?? ""
            guard let location = Self.headerValue("location", in: text).flatMap(URL.init(string:)) else {
                return nil
            }
            return (location, Self.headerValue("usn", in: text))
        }

        var services: [UPnPService] = []
        var seenLocations = Set<String>()
        for (location, deviceIdentity) in endpoints
            where seenLocations.insert(location.absoluteString).inserted {
            do {
                services.append(
                    contentsOf: try parseUPnPDescription(
                        location: location,
                        fallbackDeviceIdentity: deviceIdentity,
                        gatewayIdentityOverride: addressFamily == .ipv6 ? gatewayAddress : nil,
                        allowsCrossFamilyControl: addressFamily == .ipv6
                    )
                )
            } catch {
                continue
            }
        }

        guard !services.isEmpty else {
            throw RouterMappingError.protocolFailure("No UPnP IGD service discovered")
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
        allowsCrossFamilyControl: Bool = false
    ) throws -> [UPnPService] {
        let data: Data
        if let upnpDescriptionHandler {
            data = try upnpDescriptionHandler(location)
        } else {
            let response = try http.request(url: location, timeout: 6)
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
                allowsCrossFamilyControl: allowsCrossFamilyControl
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
            response = try soapRequestHandler(controlURL, serviceType, action, body)
        } else {
            response = try http.request(
                url: controlURL,
                method: "POST",
                headers: [
                    "Content-Type": "text/xml; charset=\"utf-8\"",
                    "SOAPAction": "\"\(serviceType)#\(action)\""
                ],
                body: Data(body.utf8),
                timeout: 8
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
        return receiveSSDPResponses(socketFD: socketFD, timeoutSeconds: request.timeoutSeconds)
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
        return receiveSSDPResponses(socketFD: socketFD, timeoutSeconds: request.timeoutSeconds)
    }

    private func sendSSDPPayloads<Address>(
        _ payloads: [Data],
        socketFD: Int32,
        destination: inout Address
    ) throws {
        for payload in payloads {
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
        }
    }

    private func receiveSSDPResponses(
        socketFD: Int32,
        timeoutSeconds: Int
    ) -> [Data] {
        var responses: [Data] = []
        let started = Date()
        while Date().timeIntervalSince(started) < Double(timeoutSeconds) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count > 0 {
                responses.append(Data(buffer.prefix(count)))
            } else {
                break
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

    private func udpRequest(payload: Data, host: String, port: UInt16, timeoutSeconds: Int) throws -> Data {
        if let udpRequestHandler {
            return try udpRequestHandler(payload, host, port, timeoutSeconds)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var results: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &results)
        guard lookup == 0, let first = results else {
            let detail = lookup == 0 ? "no address" : String(cString: gai_strerror(lookup))
            throw RouterMappingError.socket("Could not resolve UDP destination \(host): \(detail)")
        }
        defer { freeaddrinfo(results) }

        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var lastError = "No usable UDP address for \(host)"
        while let current = pointer {
            pointer = current.pointee.ai_next
            let socketFD = socket(
                current.pointee.ai_family,
                current.pointee.ai_socktype,
                current.pointee.ai_protocol
            )
            guard socketFD >= 0 else {
                lastError = "socket() failed for \(host)"
                continue
            }

            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = Darwin.connect(socketFD, current.pointee.ai_addr, current.pointee.ai_addrlen)
            guard connected == 0 else {
                lastError = "connect() failed for \(host):\(port)"
                close(socketFD)
                continue
            }

            let sent = payload.withUnsafeBytes { bytes -> ssize_t in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(socketFD, base, payload.count, 0)
            }
            guard sent == payload.count else {
                lastError = "send() failed for \(host):\(port)"
                close(socketFD)
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = recv(socketFD, &buffer, buffer.count, 0)
            close(socketFD)
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            throw RouterMappingError.uncertainAfterSend(
                "No UDP response from \(host):\(port) after the request was sent"
            )
        }
        throw RouterMappingError.timeout(lastError)
    }

    private static func isUncertainCreationError(_ error: Error) -> Bool {
        guard let mappingError = error as? RouterMappingError else { return false }
        switch mappingError {
        case .uncertainAfterSend, .invalidResponse:
            return true
        default:
            return false
        }
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

    private static func headerValue(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
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
}

struct PCPMessageCodec {
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
        request.appendUInt16(suggestedExternalPort)
        request.append(Data(repeating: 0, count: 16))
        return request
    }

    static func parseMapResponse(
        _ response: Data,
        nonce: Data,
        internalPort: UInt16,
        requestedLifetime: UInt32
    ) throws -> PCPMappingResponse {
        guard response.count >= 24 else {
            throw RouterMappingError.invalidResponse("PCP MAP response too short")
        }
        guard response[0] == 2, response[1] == 0x81 else {
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
        guard confirmedInternalPort == internalPort else {
            throw RouterMappingError.invalidResponse("PCP confirmed unexpected internal port \(confirmedInternalPort)")
        }
        if requestedLifetime > 0, responseLifetime == 0 {
            throw RouterMappingError.protocolFailure("PCP router returned a zero-second lease")
        }
        return PCPMappingResponse(
            externalPort: externalPort,
            lifetimeSeconds: responseLifetime,
            externalAddress: addressString(Data(response[44..<60]))
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
}

struct UPnPService {
    let serviceType: String
    let controlURL: URL
    let gatewayIdentity: String
    var descriptionURL: URL? = nil
    var deviceIdentity: String? = nil
    var allowsCrossFamilyControl: Bool = false

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

    private enum CodingKeys: String, CodingKey {
        case serviceType
        case controlURL
        case gatewayIdentity
        case descriptionURL
        case deviceIdentity
        case allowsCrossFamilyControl
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
        gatewayIdentity = normalizedGatewayIdentity(gatewayAddress)
        self.descriptionURL = descriptionURL.absoluteString
        self.deviceIdentity = normalizedUPnPDeviceIdentity(deviceIdentity)
        self.allowsCrossFamilyControl = service.allowsCrossFamilyControl
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
    case socket(String)
    case timeout(String)
    case uncertainAfterSend(String)
    case invalidResponse(String)
    case protocolFailure(String)
    case pcpResultCode(UInt8)
    case natPMPResultCode(UInt16)
    case upnpFault(action: String, serviceType: String, statusCode: Int, errorCode: Int?, description: String?)
    case allProtocolsFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Router mapping is disabled"
        case .socket(let message), .timeout(let message), .uncertainAfterSend(let message), .invalidResponse(let message), .protocolFailure(let message), .allProtocolsFailed(let message):
            return message
        case .pcpResultCode(let code):
            return "PCP MAP result code \(code)"
        case .natPMPResultCode(let code):
            return "NAT-PMP result code \(code)"
        case .upnpFault(let action, _, let statusCode, let errorCode, let description):
            let code = errorCode.map { " code \($0)" } ?? ""
            let detail = description.map { ": \($0)" } ?? ""
            return "UPnP \(action) failed: HTTP \(statusCode)\(code)\(detail)"
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
