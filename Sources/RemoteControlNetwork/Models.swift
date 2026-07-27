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
    var lastCheckedAt: Date?

    static let initial = AppStatus(
        ddnsStatus: .unknown("DDNS not checked yet"),
        routerStatus: .unknown("Router mapping not checked yet"),
        remoteDesktopStatus: .unknown("Remote desktop not checked yet"),
        externalReachabilityStatus: .unknown("External reachability not checked yet"),
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

enum MappingProtocolPreference: String, Codable, CaseIterable {
    case automatic
    case pcp
    case upnp
    case natpmp
    case disabled
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
            return "Uses the validated HTTP, HTTPS, or SOCKS proxy URL below."
        }
    }
}

struct AppConfig: Codable {
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
    var ipv6PinholeID: UInt16? = nil
    var pcpNonce: String? = nil
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
        checkIntervalSeconds: 300,
        externalProbeHost: "",
        accessExpiresAt: nil,
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
        case ipv6PinholeID
        case pcpNonce
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
        ipv6PinholeID: UInt16? = nil,
        pcpNonce: String? = nil,
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
        self.checkIntervalSeconds = checkIntervalSeconds
        self.externalProbeHost = externalProbeHost
        self.accessExpiresAt = accessExpiresAt
        self.ipv6PinholeID = ipv6PinholeID
        self.pcpNonce = pcpNonce
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
        checkIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .checkIntervalSeconds) ?? defaults.checkIntervalSeconds
        externalProbeHost = try container.decodeIfPresent(String.self, forKey: .externalProbeHost) ?? defaults.externalProbeHost
        accessExpiresAt = try container.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
        ipv6PinholeID = try container.decodeIfPresent(UInt16.self, forKey: .ipv6PinholeID)
        pcpNonce = try container.decodeIfPresent(String.self, forKey: .pcpNonce)
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
        try container.encode(checkIntervalSeconds, forKey: .checkIntervalSeconds)
        try container.encode(externalProbeHost, forKey: .externalProbeHost)
        try container.encodeIfPresent(accessExpiresAt, forKey: .accessExpiresAt)
        try container.encodeIfPresent(ipv6PinholeID, forKey: .ipv6PinholeID)
        try container.encodeIfPresent(pcpNonce, forKey: .pcpNonce)
        try container.encode(ddnsProxyMode, forKey: .ddnsProxyMode)
        try container.encode(publicIPProxyMode, forKey: .publicIPProxyMode)
        try container.encode(customProxyURL, forKey: .customProxyURL)
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
