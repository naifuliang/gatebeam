import Foundation
import CFNetwork

struct ProxyPolicyTestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProxyPolicyTestFailure(message) }
}

func proxyValue<T>(_ dictionary: [AnyHashable: Any]?, _ key: CFString, as type: T.Type = T.self) -> T? {
    dictionary?[key as String] as? T
}

func privateChild<T>(_ instance: Any, named label: String, as _: T.Type = T.self) throws -> T {
    guard let value = Mirror(reflecting: instance).children.first(where: { $0.label == label })?.value as? T else {
        throw ProxyPolicyTestFailure("Could not inspect \(label) on \(Swift.type(of: instance))")
    }
    return value
}

func proxyDictionary(for client: HTTPClient) throws -> [AnyHashable: Any]? {
    let session: URLSession = try privateChild(client, named: "session")
    return session.configuration.connectionProxyDictionary
}

func proxyDictionary(forProvider provider: CloudflareDNSProvider) throws -> [AnyHashable: Any]? {
    let http: HTTPRequesting = try privateChild(provider, named: "http")
    guard let client = http as? HTTPClient else {
        throw ProxyPolicyTestFailure("Cloudflare provider did not use HTTPClient")
    }
    return try proxyDictionary(for: client)
}

func proxyDictionary(forPublicIPService service: PublicIPService) throws -> [AnyHashable: Any]? {
    let http: HTTPRequesting = try privateChild(service, named: "http")
    guard let client = http as? HTTPClient else {
        throw ProxyPolicyTestFailure("PublicIPService did not use HTTPClient")
    }
    return try proxyDictionary(for: client)
}

func proxyDictionary(forRouter service: RouterMappingService) throws -> [AnyHashable: Any]? {
    let client: HTTPClient = try privateChild(service, named: "http")
    return try proxyDictionary(for: client)
}

func testProxyModeCasesAreStable() throws {
    try expect(NetworkProxyMode.system.rawValue == "system", "NetworkProxyMode.system must retain its persisted value")
    try expect(NetworkProxyMode.direct.rawValue == "direct", "NetworkProxyMode.direct must retain its persisted value")
    try expect(NetworkProxyMode.custom.rawValue == "custom", "NetworkProxyMode.custom must retain its persisted value")
    try expect(NetworkProxyMode.allCases == [.system, .direct, .custom], "Proxy mode order should match the settings segmented control")
}

func testSystemModeLeavesProxyConfigurationUntouched() throws {
    let client = try HTTPClient(proxyMode: .system)
    let proxies = try proxyDictionary(for: client)
    try expect(proxies == nil, "System mode must defer proxy selection to macOS")
}

func testDirectModeDisablesEverySystemProxyPath() throws {
    let client = try HTTPClient(proxyMode: .direct)
    let proxies = try proxyDictionary(for: client)

    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == false, "Direct mode must disable HTTP proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSEnable, as: Bool.self) == false, "Direct mode must disable HTTPS proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSEnable, as: Bool.self) == false, "Direct mode must disable SOCKS proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoConfigEnable, as: Bool.self) == false, "Direct mode must disable PAC")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoDiscoveryEnable, as: Bool.self) == false, "Direct mode must disable proxy auto-discovery")
}

func testCustomModeBuildsACompleteProxyDictionary() throws {
    let client = try HTTPClient(proxyMode: .custom, customProxyURL: "socks5://127.0.0.1:7890")
    let proxies = try proxyDictionary(for: client)

    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSEnable, as: Bool.self) == true, "Custom SOCKS mode must be enabled")
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSProxy, as: String.self) == "127.0.0.1", "Custom SOCKS host must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSPort, as: Int.self) == 7890, "Custom SOCKS port must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == false, "Custom SOCKS mode must not inherit HTTP proxy settings")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSEnable, as: Bool.self) == false, "Custom SOCKS mode must not inherit HTTPS proxy settings")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoConfigEnable, as: Bool.self) == false, "Custom mode must not inherit PAC")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoDiscoveryEnable, as: Bool.self) == false, "Custom mode must not inherit proxy auto-discovery")
}

func testCustomHTTPModeConfiguresBothHTTPAndHTTPS() throws {
    let client = try HTTPClient(proxyMode: .custom, customProxyURL: "http://proxy.example.test:8080")
    let proxies = try proxyDictionary(for: client)

    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == true, "Custom HTTP mode must enable HTTP proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPProxy, as: String.self) == "proxy.example.test", "Custom HTTP host must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPPort, as: Int.self) == 8080, "Custom HTTP port must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSEnable, as: Bool.self) == true, "Custom HTTP mode must enable HTTPS proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSProxy, as: String.self) == "proxy.example.test", "Custom HTTPS host must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSPort, as: Int.self) == 8080, "Custom HTTPS port must be preserved")
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSEnable, as: Bool.self) == false, "Custom HTTP mode must not inherit SOCKS proxy settings")
}

func expectInvalidProxyURL(_ value: String, _ message: String) throws {
    do {
        _ = try HTTPClient(proxyMode: .custom, customProxyURL: value)
        throw ProxyPolicyTestFailure(message)
    } catch NetworkError.invalidProxyURL {
        // Expected.
    }
}

func testCustomProxyValidationRejectsUnsupportedForms() throws {
    let invalidValues: [(String, String)] = [
        ("proxy.example.test:8080", "Custom proxy URLs must include an explicit supported scheme"),
        ("https://proxy.example.test:8443", "TLS-to-proxy must not be accepted until it is implemented correctly"),
        ("socks://127.0.0.1:1080", "The ambiguous socks scheme must not be accepted"),
        ("http://proxy.example.test", "HTTP custom proxies must include an explicit port"),
        ("socks5://127.0.0.1", "SOCKS5 custom proxies must include an explicit port"),
        ("http://proxy.example.test/", "A trailing path separator must not be accepted"),
        ("http://proxy.example.test:8080/proxy", "Custom proxy paths must not be accepted"),
        ("http://proxy.example.test:8080?mode=direct", "Custom proxy queries must not be accepted"),
        ("http://proxy.example.test:8080#local", "Custom proxy fragments must not be accepted"),
        ("http://user@proxy.example.test:8080", "Custom proxy usernames must not be persisted in the URL"),
        ("socks5://user:secret@127.0.0.1:1080", "Custom proxy credentials must not be persisted in the URL"),
        ("http://proxy.example.test:0", "Port zero must not be accepted"),
        ("http://proxy.example.test:65536", "Ports above 65535 must not be accepted")
    ]

    for (value, message) in invalidValues {
        try expectInvalidProxyURL(value, message)
    }
}

func testCustomProxyPortBoundariesAreAccepted() throws {
    let lowerBound = try HTTPClient(proxyMode: .custom, customProxyURL: "http://proxy.example.test:1")
    let upperBound = try HTTPClient(proxyMode: .custom, customProxyURL: "socks5://127.0.0.1:65535")
    let lowerProxies = try proxyDictionary(for: lowerBound)
    let upperProxies = try proxyDictionary(for: upperBound)

    try expect(proxyValue(lowerProxies, kCFNetworkProxiesHTTPPort, as: Int.self) == 1, "Port 1 must be accepted")
    try expect(proxyValue(upperProxies, kCFNetworkProxiesSOCKSPort, as: Int.self) == 65_535, "Port 65535 must be accepted")
}

func testCustomHTTPIPv6LiteralIsNormalizedForCFNetwork() throws {
    let client = try HTTPClient(proxyMode: .custom, customProxyURL: "http://[2001:db8::10]:8080")
    let proxies = try proxyDictionary(for: client)

    try expect(
        proxyValue(proxies, kCFNetworkProxiesHTTPProxy, as: String.self) == "2001:db8::10",
        "CFNetwork must receive an unbracketed HTTP IPv6 proxy host"
    )
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPPort, as: Int.self) == 8080, "The HTTP IPv6 proxy port must be preserved")
}

func testCustomSOCKSIPv6LiteralIsNormalizedForCFNetwork() throws {
    let client = try HTTPClient(proxyMode: .custom, customProxyURL: "socks5://[2001:db8::20]:1080")
    let proxies = try proxyDictionary(for: client)

    try expect(
        proxyValue(proxies, kCFNetworkProxiesSOCKSProxy, as: String.self) == "2001:db8::20",
        "CFNetwork must receive an unbracketed SOCKS5 IPv6 proxy host"
    )
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSPort, as: Int.self) == 1080, "The SOCKS5 IPv6 proxy port must be preserved")
}

func testOldConfigMigratesToSafeDirectPublicIP() throws {
    let legacyJSON = """
    {
      "remoteAccessEnabled": false,
      "dnsProvider": "cloudflare",
      "cloudflareZoneID": "",
      "dnsRecordName": "",
      "preferredAddressFamily": "dualStack",
      "mappingProtocolPreference": "automatic",
      "internalPort": 5900,
      "externalPort": 5900,
      "mappingLeaseSeconds": 3600,
      "autoRenewMapping": true,
      "startAtLogin": false,
      "checkIntervalSeconds": 300,
      "externalProbeHost": "",
      "accessExpiresAt": null
    }
    """

    let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(legacyJSON.utf8))
    try expect(decoded.ddnsProxyMode == .system, "Legacy configurations must preserve the existing system-proxy behavior for Cloudflare")
    try expect(decoded.publicIPProxyMode == .direct, "Legacy configurations must migrate public-IP discovery to direct mode")
    try expect(decoded.customProxyURL.isEmpty, "Legacy configurations must not invent a custom proxy URL")
}

func testServicePoliciesStayIndependent() throws {
    var config = AppConfig.default
    config.ddnsProxyMode = .custom
    config.publicIPProxyMode = .direct
    config.customProxyURL = "socks5://127.0.0.1:7890"

    let cloudflare = try CloudflareDNSProvider(proxyMode: config.ddnsProxyMode, customProxyURL: config.customProxyURL)
    let publicIP = try PublicIPService(proxyMode: config.publicIPProxyMode, customProxyURL: config.customProxyURL)
    let cloudflareProxies = try proxyDictionary(forProvider: cloudflare)
    let publicIPProxies = try proxyDictionary(forPublicIPService: publicIP)

    try expect(proxyValue(cloudflareProxies, kCFNetworkProxiesSOCKSEnable, as: Bool.self) == true, "Cloudflare policy should accept a custom proxy")
    try expect(proxyValue(publicIPProxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == false, "Public-IP policy must remain independently configurable")
}

func testCloudflareAndPublicIPHaveDistinctDefaultPolicies() throws {
    let cloudflareProxies = try proxyDictionary(forProvider: CloudflareDNSProvider())
    let publicIPProxies = try proxyDictionary(forPublicIPService: PublicIPService())
    try expect(cloudflareProxies == nil, "Cloudflare requests should use the system-proxy default")
    try expect(proxyValue(publicIPProxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == false, "Public-IP discovery must bypass system proxies by default")
}

func testRouterLocalHTTPIsAlwaysDirect() throws {
    let proxies = try proxyDictionary(forRouter: RouterMappingService())
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPEnable, as: Bool.self) == false, "Router-local HTTP must disable HTTP proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesHTTPSEnable, as: Bool.self) == false, "Router-local HTTP must disable HTTPS proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesSOCKSEnable, as: Bool.self) == false, "Router-local HTTP must disable SOCKS proxy")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoConfigEnable, as: Bool.self) == false, "Router-local HTTP must disable PAC")
    try expect(proxyValue(proxies, kCFNetworkProxiesProxyAutoDiscoveryEnable, as: Bool.self) == false, "Router-local HTTP must disable auto-discovery")
}

let tests: [(String, () throws -> Void)] = [
    ("keeps ProxyMode persistence stable", testProxyModeCasesAreStable),
    ("lets macOS own system proxy selection", testSystemModeLeavesProxyConfigurationUntouched),
    ("disables all proxy paths in direct mode", testDirectModeDisablesEverySystemProxyPath),
    ("builds a SOCKS custom proxy dictionary", testCustomModeBuildsACompleteProxyDictionary),
    ("builds an HTTP custom proxy dictionary", testCustomHTTPModeConfiguresBothHTTPAndHTTPS),
    ("rejects unsupported custom proxy forms", testCustomProxyValidationRejectsUnsupportedForms),
    ("accepts valid custom proxy port boundaries", testCustomProxyPortBoundariesAreAccepted),
    ("normalizes an HTTP IPv6 proxy host", testCustomHTTPIPv6LiteralIsNormalizedForCFNetwork),
    ("normalizes a SOCKS5 IPv6 proxy host", testCustomSOCKSIPv6LiteralIsNormalizedForCFNetwork),
    ("migrates legacy configuration safely", testOldConfigMigratesToSafeDirectPublicIP),
    ("keeps DDNS and public-IP policies independent", testServicePoliciesStayIndependent),
    ("uses distinct Cloudflare and public-IP defaults", testCloudflareAndPublicIPHaveDistinctDefaultPolicies),
    ("keeps router-local HTTP direct", testRouterLocalHTTPIsAlwaysDirect)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
    print("Proxy policy tests passed: \(tests.count)")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
