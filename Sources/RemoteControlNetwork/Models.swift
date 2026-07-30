import Foundation

enum CheckState: String, Codable {
    case unknown
    case checking
    case ok
    case warning
    case failed
    case disabled
}

struct ComponentStatus: Codable {
    var state: CheckState
    var message: String
    var detail: String
    var updatedAt: Date

    static func unknown(_ message: String = "Not checked yet") -> ComponentStatus {
        ComponentStatus(state: .unknown, message: message, detail: "", updatedAt: Date())
    }

    static func disabled(_ message: String) -> ComponentStatus {
        ComponentStatus(state: .disabled, message: message, detail: "", updatedAt: Date())
    }

    static func ok(_ message: String, detail: String = "") -> ComponentStatus {
        ComponentStatus(state: .ok, message: message, detail: detail, updatedAt: Date())
    }

    static func warning(_ message: String, detail: String = "") -> ComponentStatus {
        ComponentStatus(state: .warning, message: message, detail: detail, updatedAt: Date())
    }

    static func failed(_ message: String, detail: String = "") -> ComponentStatus {
        ComponentStatus(state: .failed, message: message, detail: detail, updatedAt: Date())
    }
}

struct AppStatus: Codable {
    var ddnsStatus: ComponentStatus
    var routerStatus: ComponentStatus
    var remoteDesktopStatus: ComponentStatus
    var externalReachabilityStatus: ComponentStatus
    var publicAddress: String?
    var localAddress: String?
    var gatewayAddress: String?
    var publicIPv6Address: String? = nil
    var localIPv6Address: String? = nil
    var gatewayIPv6Address: String? = nil
    var externalPort: UInt16?
    var ipv6ExternalPort: UInt16? = nil
    var connectionURL: String?
    var connectionURLIPv4: String? = nil
    var connectionURLIPv6: String? = nil
    var settingsErrorMessage: String? = nil
    var lastCheckedAt: Date?

    static let initial = AppStatus(
        ddnsStatus: .unknown("DDNS not checked yet"),
        routerStatus: .unknown("Router mapping not checked yet"),
        remoteDesktopStatus: .unknown("Remote desktop not checked yet"),
        externalReachabilityStatus: .unknown("Local-origin TCP check not run yet"),
        publicAddress: nil,
        localAddress: nil,
        gatewayAddress: nil,
        externalPort: nil,
        connectionURL: nil,
        lastCheckedAt: nil
    )
}

enum DNSProvider: String, Codable, CaseIterable {
    case disabled
    case cloudflare
}

enum CloudflareTokenMutation: Equatable {
    case keepExisting
    case replace(String)
    case explicitRemove

    func validated() throws -> CloudflareTokenMutation {
        switch self {
        case .keepExisting, .explicitRemove:
            return self
        case .replace(let token):
            let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw CloudflareTokenMutationError.emptyReplacement
            }
            return .replace(normalized)
        }
    }
}

enum CloudflareTokenMutationError: Error, LocalizedError {
    case emptyReplacement

    var errorDescription: String? {
        "A replacement Cloudflare token cannot be empty. Use the explicit Remove Token action instead."
    }
}

enum CloudflareTokenReadState: Equatable {
    case unknown
    case missing
    case available(String)
    case unavailable
}

enum RemoteConnectionURLPolicy {
    static let unavailableText = "Unavailable while remote access is off"

    static func displayURL(
        remoteAccessEnabled: Bool,
        status: AppStatus
    ) -> String {
        guard remoteAccessEnabled else { return unavailableText }
        return status.connectionURL ?? "No connection URL yet"
    }

    static func primaryCopyURL(
        remoteAccessEnabled: Bool,
        status: AppStatus
    ) -> String? {
        guard remoteAccessEnabled else { return nil }
        return status.connectionURLIPv4 ?? status.connectionURL
    }

    static func ipv6CopyURL(
        remoteAccessEnabled: Bool,
        status: AppStatus
    ) -> String? {
        guard remoteAccessEnabled else { return nil }
        return status.connectionURLIPv6
    }
}

enum MappingProtocolPreference: String, Codable, CaseIterable {
    case automatic
    case pcp
    case upnp
    case natpmp
    case disabled
}

enum RouterMappingTransport: String, Codable, CaseIterable {
    case pcp
    case natpmp
    case upnp

    var displayName: String {
        switch self {
        case .pcp: return "PCP"
        case .natpmp: return "NAT-PMP"
        case .upnp: return "UPnP"
        }
    }

    var preference: MappingProtocolPreference {
        switch self {
        case .pcp: return .pcp
        case .natpmp: return .natpmp
        case .upnp: return .upnp
        }
    }
}

enum RouterMappingAddressFamily: String, Codable, CaseIterable {
    case ipv4
    case ipv6

    var displayName: String {
        self == .ipv4 ? "IPv4" : "IPv6"
    }
}

enum RouterMappingRecoveryState: String, Codable {
    case effectiveClientAddressChanged
    case wallClockRollback
    case clockContinuityUnverified
    case upnpIdentityChanged
}

struct ActiveRouterMapping: Codable, Equatable {
    var transport: RouterMappingTransport
    var addressFamily: RouterMappingAddressFamily
    var localAddress: String
    var gatewayAddress: String
    var internalPort: UInt16
    var externalPort: UInt16
    var routerExternalAddress: String? = nil
    var pinholeID: UInt16?
    var pcpNonce: String?
    var leaseExpiresAt: Date
    var renewAfter: Date
    var routerEpoch: UInt32? = nil
    var routerEpochObservedAt: Date? = nil
    var routerEpochObservedUptime: TimeInterval? = nil
    var routerEpochBootIdentifier: String? = nil
    var routerEpochHealthCheckAfter: Date? = nil
    var routerEpochHealthCheckUptime: TimeInterval? = nil
    var leaseExpiresUptime: TimeInterval? = nil
    var renewAfterUptime: TimeInterval? = nil
    var leaseBootIdentifier: String? = nil
    var leaseAnchorWallTime: Date? = nil
    var leaseRemainingAtAnchor: TimeInterval? = nil
    var renewRemainingAtAnchor: TimeInterval? = nil
    var recoveryState: RouterMappingRecoveryState? = nil
    var replacementLocalAddress: String? = nil
    var recoverySafeAfterUptime: TimeInterval? = nil
    var recoveryBootIdentifier: String? = nil

    var identifier: String {
        [
            addressFamily.rawValue,
            transport.rawValue,
            localAddress,
            gatewayAddress,
            String(internalPort),
            String(externalPort),
            pinholeID.map(String.init) ?? "",
            pcpNonce ?? ""
        ].joined(separator: "|")
    }

    func isCompatible(
        with config: AppConfig,
        family: RouterMappingAddressFamily,
        localAddress: String,
        gatewayAddress: String
    ) -> Bool {
        let localAddressMatches = transport == .pcp
            || transport == .natpmp
            || self.localAddress == localAddress
        guard addressFamily == family,
              localAddressMatches,
              self.gatewayAddress == gatewayAddress,
              internalPort == config.internalPort else {
            return false
        }
        if family == .ipv4, externalPort != config.externalPort {
            return false
        }
        switch config.mappingProtocolPreference {
        case .automatic:
            return true
        case .pcp:
            return transport == .pcp
        case .natpmp:
            return family == .ipv4 && transport == .natpmp
        case .upnp:
            return transport == .upnp
        case .disabled:
            return false
        }
    }
}

struct RouterMappingRecoveryRequiredError: Error, LocalizedError {
    let mapping: ActiveRouterMapping
    let operationDescription: String
    let cleanupDescription: String

    var errorDescription: String? {
        [
            operationDescription,
            "Automatic cleanup failed: \(cleanupDescription)",
            "Recovery mapping: \(mapping.identifier)"
        ].joined(separator: "\n")
    }
}

enum AddressFamilyPreference: String, Codable, CaseIterable {
    case ipv4
    case dualStack
    case ipv6

    var usesIPv4: Bool {
        self == .ipv4 || self == .dualStack
    }

    var usesIPv6: Bool {
        self == .ipv6 || self == .dualStack
    }
}

enum NetworkProxyMode: String, Codable, CaseIterable {
    case system
    case direct
    case custom

    var displayName: String {
        switch self {
        case .system: return "System"
        case .direct: return "Direct"
        case .custom: return "Custom"
        }
    }

    var behaviorDescription: String {
        switch self {
        case .system:
            return "Uses the proxy configuration provided by macOS."
        case .direct:
            return "Bypasses URLSession HTTP, HTTPS, SOCKS, and PAC proxies. TUN and VPN routes still apply."
        case .custom:
            return "Uses the validated HTTP or SOCKS5 proxy URL below."
        }
    }
}

struct AppConfig: Codable {
    static let minimumCheckIntervalSeconds: TimeInterval = 60
    static let maximumCheckIntervalSeconds: TimeInterval = 24 * 60 * 60
    static let defaultCheckIntervalSeconds: TimeInterval = 300

    var remoteAccessEnabled: Bool
    var dnsProvider: DNSProvider
    var cloudflareZoneID: String
    var dnsRecordName: String
    var preferredAddressFamily: AddressFamilyPreference
    var mappingProtocolPreference: MappingProtocolPreference
    var internalPort: UInt16
    var externalPort: UInt16
    var mappingLeaseSeconds: UInt32
    var autoRenewMapping: Bool
    var startAtLogin: Bool
    var checkIntervalSeconds: TimeInterval
    var externalProbeHost: String
    var accessExpiresAt: Date?
    var accessExpiresUptime: TimeInterval? = nil
    var accessBootIdentifier: String? = nil
    var accessAnchorWallTime: Date? = nil
    var accessRemainingAtAnchor: TimeInterval? = nil
    var ipv6PinholeID: UInt16? = nil
    var pcpNonce: String? = nil
    var activeRouterMappings: [ActiveRouterMapping]
    var ddnsProxyMode: NetworkProxyMode
    var publicIPProxyMode: NetworkProxyMode
    var customProxyURL: String

    static let `default` = AppConfig(
        remoteAccessEnabled: false,
        dnsProvider: .cloudflare,
        cloudflareZoneID: "",
        dnsRecordName: "",
        preferredAddressFamily: .dualStack,
        mappingProtocolPreference: .automatic,
        internalPort: 5900,
        externalPort: UInt16(Int.random(in: 41000...60999)),
        mappingLeaseSeconds: 3600,
        autoRenewMapping: true,
        startAtLogin: false,
        checkIntervalSeconds: defaultCheckIntervalSeconds,
        externalProbeHost: "",
        accessExpiresAt: nil,
        activeRouterMappings: [],
        ddnsProxyMode: .system,
        publicIPProxyMode: .direct,
        customProxyURL: ""
    )

    private enum CodingKeys: String, CodingKey {
        case remoteAccessEnabled
        case dnsProvider
        case cloudflareZoneID
        case dnsRecordName
        case preferredAddressFamily
        case mappingProtocolPreference
        case internalPort
        case externalPort
        case mappingLeaseSeconds
        case autoRenewMapping
        case startAtLogin
        case checkIntervalSeconds
        case externalProbeHost
        case accessExpiresAt
        case accessExpiresUptime
        case accessBootIdentifier
        case accessAnchorWallTime
        case accessRemainingAtAnchor
        case ipv6PinholeID
        case pcpNonce
        case activeRouterMappings
        case ddnsProxyMode
        case publicIPProxyMode
        case customProxyURL
    }

    init(
        remoteAccessEnabled: Bool,
        dnsProvider: DNSProvider,
        cloudflareZoneID: String,
        dnsRecordName: String,
        preferredAddressFamily: AddressFamilyPreference,
        mappingProtocolPreference: MappingProtocolPreference,
        internalPort: UInt16,
        externalPort: UInt16,
        mappingLeaseSeconds: UInt32,
        autoRenewMapping: Bool,
        startAtLogin: Bool,
        checkIntervalSeconds: TimeInterval,
        externalProbeHost: String,
        accessExpiresAt: Date?,
        accessExpiresUptime: TimeInterval? = nil,
        accessBootIdentifier: String? = nil,
        accessAnchorWallTime: Date? = nil,
        accessRemainingAtAnchor: TimeInterval? = nil,
        ipv6PinholeID: UInt16? = nil,
        pcpNonce: String? = nil,
        activeRouterMappings: [ActiveRouterMapping] = [],
        ddnsProxyMode: NetworkProxyMode = .system,
        publicIPProxyMode: NetworkProxyMode = .direct,
        customProxyURL: String = ""
    ) {
        self.remoteAccessEnabled = remoteAccessEnabled
        self.dnsProvider = dnsProvider
        self.cloudflareZoneID = cloudflareZoneID
        self.dnsRecordName = dnsRecordName
        self.preferredAddressFamily = preferredAddressFamily
        self.mappingProtocolPreference = mappingProtocolPreference
        self.internalPort = internalPort
        self.externalPort = externalPort
        self.mappingLeaseSeconds = mappingLeaseSeconds
        self.autoRenewMapping = autoRenewMapping
        self.startAtLogin = startAtLogin
        self.checkIntervalSeconds = Self.normalizedCheckInterval(checkIntervalSeconds)
        self.externalProbeHost = externalProbeHost
        self.accessExpiresAt = accessExpiresAt
        self.accessExpiresUptime = accessExpiresUptime
        self.accessBootIdentifier = accessBootIdentifier
        self.accessAnchorWallTime = accessAnchorWallTime
        self.accessRemainingAtAnchor = accessRemainingAtAnchor
        self.ipv6PinholeID = ipv6PinholeID
        self.pcpNonce = pcpNonce
        self.activeRouterMappings = activeRouterMappings
        self.ddnsProxyMode = ddnsProxyMode
        self.publicIPProxyMode = publicIPProxyMode
        self.customProxyURL = customProxyURL
    }

    init(from decoder: Decoder) throws {
        let defaults = AppConfig.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteAccessEnabled) ?? defaults.remoteAccessEnabled
        dnsProvider = try container.decodeIfPresent(DNSProvider.self, forKey: .dnsProvider) ?? defaults.dnsProvider
        cloudflareZoneID = try container.decodeIfPresent(String.self, forKey: .cloudflareZoneID) ?? defaults.cloudflareZoneID
        dnsRecordName = try container.decodeIfPresent(String.self, forKey: .dnsRecordName) ?? defaults.dnsRecordName
        preferredAddressFamily = try container.decodeIfPresent(AddressFamilyPreference.self, forKey: .preferredAddressFamily) ?? defaults.preferredAddressFamily
        mappingProtocolPreference = try container.decodeIfPresent(MappingProtocolPreference.self, forKey: .mappingProtocolPreference) ?? defaults.mappingProtocolPreference
        internalPort = try container.decodeIfPresent(UInt16.self, forKey: .internalPort) ?? defaults.internalPort
        externalPort = try container.decodeIfPresent(UInt16.self, forKey: .externalPort) ?? defaults.externalPort
        mappingLeaseSeconds = try container.decodeIfPresent(UInt32.self, forKey: .mappingLeaseSeconds) ?? defaults.mappingLeaseSeconds
        autoRenewMapping = try container.decodeIfPresent(Bool.self, forKey: .autoRenewMapping) ?? defaults.autoRenewMapping
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
        let decodedCheckInterval = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .checkIntervalSeconds
        ) ?? defaults.checkIntervalSeconds
        checkIntervalSeconds = Self.normalizedCheckInterval(decodedCheckInterval)
        externalProbeHost = try container.decodeIfPresent(String.self, forKey: .externalProbeHost) ?? defaults.externalProbeHost
        accessExpiresAt = try container.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
        accessExpiresUptime = try container.decodeIfPresent(TimeInterval.self, forKey: .accessExpiresUptime)
        accessBootIdentifier = try container.decodeIfPresent(String.self, forKey: .accessBootIdentifier)
        accessAnchorWallTime = try container.decodeIfPresent(Date.self, forKey: .accessAnchorWallTime)
        accessRemainingAtAnchor = try container.decodeIfPresent(TimeInterval.self, forKey: .accessRemainingAtAnchor)
        ipv6PinholeID = try container.decodeIfPresent(UInt16.self, forKey: .ipv6PinholeID)
        pcpNonce = try container.decodeIfPresent(String.self, forKey: .pcpNonce)
        activeRouterMappings = try container.decodeIfPresent([ActiveRouterMapping].self, forKey: .activeRouterMappings) ?? []
        ddnsProxyMode = try container.decodeIfPresent(NetworkProxyMode.self, forKey: .ddnsProxyMode) ?? .system
        publicIPProxyMode = try container.decodeIfPresent(NetworkProxyMode.self, forKey: .publicIPProxyMode) ?? .direct
        customProxyURL = try container.decodeIfPresent(String.self, forKey: .customProxyURL) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteAccessEnabled, forKey: .remoteAccessEnabled)
        try container.encode(dnsProvider, forKey: .dnsProvider)
        try container.encode(cloudflareZoneID, forKey: .cloudflareZoneID)
        try container.encode(dnsRecordName, forKey: .dnsRecordName)
        try container.encode(preferredAddressFamily, forKey: .preferredAddressFamily)
        try container.encode(mappingProtocolPreference, forKey: .mappingProtocolPreference)
        try container.encode(internalPort, forKey: .internalPort)
        try container.encode(externalPort, forKey: .externalPort)
        try container.encode(mappingLeaseSeconds, forKey: .mappingLeaseSeconds)
        try container.encode(autoRenewMapping, forKey: .autoRenewMapping)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(Self.normalizedCheckInterval(checkIntervalSeconds), forKey: .checkIntervalSeconds)
        try container.encode(externalProbeHost, forKey: .externalProbeHost)
        try container.encodeIfPresent(accessExpiresAt, forKey: .accessExpiresAt)
        try container.encodeIfPresent(accessExpiresUptime, forKey: .accessExpiresUptime)
        try container.encodeIfPresent(accessBootIdentifier, forKey: .accessBootIdentifier)
        try container.encodeIfPresent(accessAnchorWallTime, forKey: .accessAnchorWallTime)
        try container.encodeIfPresent(accessRemainingAtAnchor, forKey: .accessRemainingAtAnchor)
        try container.encodeIfPresent(ipv6PinholeID, forKey: .ipv6PinholeID)
        try container.encodeIfPresent(pcpNonce, forKey: .pcpNonce)
        try container.encode(activeRouterMappings, forKey: .activeRouterMappings)
        try container.encode(ddnsProxyMode, forKey: .ddnsProxyMode)
        try container.encode(publicIPProxyMode, forKey: .publicIPProxyMode)
        try container.encode(customProxyURL, forKey: .customProxyURL)
    }

    static func normalizedCheckInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else {
            return defaultCheckIntervalSeconds
        }
        return min(max(value, minimumCheckIntervalSeconds), maximumCheckIntervalSeconds)
    }

    func normalizedForPersistence() -> AppConfig {
        var normalized = self
        normalized.checkIntervalSeconds = Self.normalizedCheckInterval(checkIntervalSeconds)
        return normalized
    }

    mutating func clearTemporaryAccessExpiration() {
        accessExpiresAt = nil
        accessExpiresUptime = nil
        accessBootIdentifier = nil
        accessAnchorWallTime = nil
        accessRemainingAtAnchor = nil
    }
}

extension CheckState {
    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking"
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .disabled: return "Disabled"
        }
    }
}
