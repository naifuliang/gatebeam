import Foundation
import Darwin

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
    private var recoveryFailure: RouterMappingRecoveryRequiredError?
    private var legacyRemovalReport = RouterMappingRemovalReport(attempts: [])
    private var storedLegacyRemovalCallCount = 0
    var failAllRemovals = false
    var beforeRemoval: (() -> Void)?
    var externalIPv4 = "8.8.8.8"

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

    func externalIPv4Address(gatewayAddress: String) throws -> String {
        operations.increment()
        return externalIPv4
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

    private func ensure(
        family: RouterMappingAddressFamily,
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String
    ) throws -> PortMappingResult {
        operations.increment()
        lock.lock()
        storedEnsureCalls.append(family)
        let shouldFail = failedEnsureFamilies.contains(family)
        let injectedRecovery = recoveryFailure
        lock.unlock()
        if let injectedRecovery {
            throw injectedRecovery
        }
        if shouldFail {
            throw SimulatedRouterFailure(operation: "\(family.displayName) ensure")
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
        let mapping = ActiveRouterMapping(
            transport: transport,
            addressFamily: family,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            internalPort: config.internalPort,
            externalPort: externalPort,
            pinholeID: pinholeID,
            pcpNonce: transport == .pcp ? config.pcpNonce : nil,
            leaseExpiresAt: Date().addingTimeInterval(3600),
            renewAfter: Date().addingTimeInterval(1800)
        )
        return PortMappingResult(
            protocolName: transport.displayName,
            externalPort: externalPort,
            routerExternalAddress: family == .ipv4 ? "8.8.8.8" : localAddress,
            message: "mock renewable lease",
            pinholeID: pinholeID,
            activeMapping: mapping
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

func waitUntil(
    timeout: TimeInterval = 3,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
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
    agent.stop()
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
        try coordinator.persist(config: config, token: "never-persisted")
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

    let normalized = try coordinator.persist(config: config, token: "test-token")
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

    _ = try coordinator.persist(config: config, token: "test-token")
    try expect(savedConfig?.customProxyURL == "", "Unused custom proxy values must be cleared before config persistence")
}

func testValidProxyPersistsInOrder() throws {
    var config = AppConfig.default
    config.publicIPProxyMode = .custom
    config.customProxyURL = "socks5://[2001:db8::1]:1080"

    var calls: [String] = []
    let coordinator = SettingsPersistenceCoordinator(
        persistSettings: { config, token in
            calls.append("transaction:\(token):\(config.customProxyURL)")
            return config
        }
    )

    try coordinator.persist(config: config, token: "test-token")
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
        try coordinator.persist(config: .default, token: "test-token")
        throw IntegrationContractFailure("A token persistence failure must be propagated")
    } catch is TokenWriteFailure {
        // Expected: config persistence must not run after a failed token write.
    }
    try expect(calls == ["transaction"], "Transaction failure must propagate without reporting persistence success")
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
    let loadedToken = try agent.loadCloudflareToken()
    try expect(loadedToken == existingToken, "The fixture token must load before deletion")

    do {
        try agent.persistSettings(config: .default, token: "")
        throw IntegrationContractFailure("A Keychain delete error must propagate through settings persistence")
    } catch is SimulatedKeychainFailure {
        // Expected.
    }

    try expect(!FileManager.default.fileExists(atPath: agentConfigPath(baseDirectory)), "A failed token deletion must block config persistence")
    try expect(agent.cloudflareToken() == existingToken, "A failed deletion must preserve the cached token for UI rollback")
    try expect(
        agent.status.settingsErrorMessage?.contains("Could not delete") == true,
        "A Keychain delete failure must be visible in settings"
    )

    deleteShouldFail = false
    try agent.persistSettings(config: .default, token: "")
    try expect(FileManager.default.fileExists(atPath: agentConfigPath(baseDirectory)), "A successful retry may persist config after Keychain deletion")
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
    try expect(
        KeychainStore.isStrongDesignatedRequirement(
            #"cdhash H"1111111111111111111111111111111111111111" or cdhash H"2222222222222222222222222222222222222222""#
        ),
        "A pure exact-build cdhash set must be accepted for Developer Preview"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork""#
        ),
        "An identifier-only requirement must be rejected"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" or cdhash H"1111111111111111111111111111111111111111""#
        ),
        "A cdhash requirement with a weak identifier alternative must be rejected"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"true or cdhash H"1111111111111111111111111111111111111111""#
        ),
        "A cdhash requirement with a permissive alternative must be rejected"
    )
    try expect(
        KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TEAMID1234"#
        ),
        "A canonical TN3127 Developer ID Application requirement must be accepted"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = "TEAMID1234""#
        ),
        "An Apple Development-like requirement must be rejected"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.14] exists and certificate leaf[subject.OU] = "TEAMID1234""#
        ),
        "A Developer ID Installer-like requirement must be rejected"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMID1234""#
        ),
        "Certificate OID fields without existence constraints must be rejected"
    )
    try expect(
        !KeychainStore.isStrongDesignatedRequirement(
            #"identifier "com.local.RemoteControlNetwork" or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TEAMID1234")"#
        ),
        "A Developer ID requirement with a weak OR alternative must be rejected"
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

func testLegacyMigrationSerializesConcurrentEmptySave() throws {
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

    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.authorizeSavedCloudflareToken { authorizationResult = $0 }
    try expect(
        currentCopyWritten.wait(timeout: .now() + 3) == .success,
        "Migration must reach the verified current-service copy"
    )

    var saveResult: Result<AppConfig, Error>?
    agent.persistSettingsAsync(config: .default, token: "") { saveResult = $0 }
    Thread.sleep(forTimeInterval: 0.05)
    lock.lock()
    let eventsWhileMigrationIsBlocked = events
    lock.unlock()
    try expect(
        !eventsWhileMigrationIsBlocked.contains("delete:\(currentService)"),
        "An empty save submitted during migration must not touch Keychain before authorization finishes"
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
        legacyDelete != nil && currentDelete != nil && legacyDelete! < currentDelete!,
        "Legacy cleanup must finish before the queued save deletes the current item"
    )
    try expect(finalValues.isEmpty, "The queued empty save must leave neither legacy nor current token behind")
    try expect(agent.cloudflareToken().isEmpty, "The UI token cache must match the serialized empty save")
    try expect(agent.status.settingsErrorMessage == nil, "Successful migration and deletion must clear Keychain errors")
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
    let initialLoad = try agent.loadCloudflareToken(interaction: .background)
    try expect(
        initialLoad == "initial-token",
        "The ordering fixture must begin with a cached token"
    )

    var deleteResult: Result<AppConfig, Error>?
    var writeResult: Result<AppConfig, Error>?
    var authorizationResult: Result<KeychainAuthorizationOutcome, Error>?
    agent.persistSettingsAsync(config: .default, token: "") { deleteResult = $0 }
    agent.persistSettingsAsync(config: .default, token: "replacement-token") { writeResult = $0 }
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
        try agent.persistSettings(config: requestedConfig, token: "after-token")
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
    config.dnsProvider = .disabled
    config.preferredAddressFamily = .ipv4
    config.checkIntervalSeconds = 0
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        checkExecutionObserver: { checkExecutions.increment() },
        localNetworkService: local,
        routerMappingService: MockRouterMappingService()
    )

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
    agent.stop()
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
    agent.stop()
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
    agent.runCheck()
    try expect(
        sideEffectEntered.wait(timeout: .now() + 2) == .success,
        "The check must pause after its final generation validation while holding the side-effect gate"
    )

    var disabled = config
    disabled.remoteAccessEnabled = false
    var saveCompleted = false
    agent.persistSettingsAsync(config: disabled, token: "") { result in
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
    agent.stop()
}

func testRouterWANIPv4RequiresPublicRoutability() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "router-wan-public-selection")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let router = MockRouterMappingService()
    let publicIP = MockPublicIPService()
    var config = AppConfig.default
    config.preferredAddressFamily = .ipv4
    let agent = NetworkAgent(
        configStore: AppConfigStore(baseDirectory: baseDirectory),
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: router,
        publicIPServiceFactory: { _ in publicIP },
        emergencyMappingJournal: emergencyJournal(in: baseDirectory)
    )

    router.externalIPv4 = "8.8.8.8"
    let publicRouter = try agent.currentPublicIPv4(
        config: config,
        gatewayAddress: "192.0.2.1",
        revision: 0
    )
    try expect(publicRouter.publicAddress == "8.8.8.8", "A public router WAN address must take priority")
    try expect(publicIP.ipv4CallCount == 0, "A public router WAN address must avoid the fallback probe")

    let specialAddresses = [
        "0.0.0.0",
        "127.0.0.1",
        "169.254.1.2",
        "224.0.0.1",
        "240.0.0.1"
    ]
    for address in specialAddresses {
        router.externalIPv4 = address
        let discovery = try agent.currentPublicIPv4(
            config: config,
            gatewayAddress: "192.0.2.1",
            revision: 0
        )
        try expect(
            discovery.publicAddress == publicIP.ipv4,
            "\(address) must fall back to the independent public-IP probe"
        )
        try expect(!discovery.blocksDDNS, "\(address) must not be misdiagnosed as RFC1918 or CGNAT")
    }

    for address in ["192.168.1.20", "100.64.1.20"] {
        router.externalIPv4 = address
        let discovery = try agent.currentPublicIPv4(
            config: config,
            gatewayAddress: "192.0.2.1",
            revision: 0
        )
        try expect(discovery.publicAddress == publicIP.ipv4, "Private WAN addresses still need a public diagnostic address")
        try expect(discovery.blocksDDNS, "RFC1918 and CGNAT WAN addresses must block A-record updates")
    }
    agent.stop()
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

    var requested = previous
    requested.remoteAccessEnabled = false
    var completionArrived = false
    var completionWasOnMain = false
    var completionError: Error?
    let startedAt = Date()
    agent.persistSettingsAsync(config: requested, token: "") { result in
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
    agent.stop()
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
    agent.stop()
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

func testLegacyAutomaticCleanupPersistsOnlyUnknownProtocol() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "legacy-automatic-cleanup")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    var previous = AppConfig.default
    previous.remoteAccessEnabled = true
    previous.dnsProvider = .disabled
    previous.preferredAddressFamily = .ipv4
    previous.mappingProtocolPreference = .automatic
    previous.pcpNonce = Data(repeating: 27, count: 12).base64EncodedString()
    previous.activeRouterMappings = []

    let unknown = ActiveRouterMapping(
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
    let store = AppConfigStore(baseDirectory: baseDirectory)
    try store.save(previous)
    let router = MockRouterMappingService()
    router.setLegacyRemovalReport(
        RouterMappingRemovalReport(
            attempts: [
                RouterMappingRemovalAttempt(
                    mapping: unknown,
                    errorDescription: "NAT-PMP deletion response was uncertain"
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

    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil {
            router.legacyRemovalCallCount == 1
                && agent.status.settingsErrorMessage?.contains("retained the failed rules") == true
        },
        "An uncertain legacy protocol must block the close transaction"
    )
    try expect(agent.config.remoteAccessEnabled, "Legacy uncertainty must keep remote access enabled")
    try expect(
        agent.config.activeRouterMappings == [unknown],
        "Only the exact uncertain legacy protocol may be retained for retry"
    )
    let failedDiskState = try store.load()
    try expect(
        failedDiskState.activeRouterMappings == [unknown],
        "The exact uncertain legacy protocol must be checkpointed on disk"
    )

    agent.setRemoteAccessEnabled(false)
    try expect(
        waitUntil {
            !agent.config.remoteAccessEnabled
                && agent.config.activeRouterMappings.isEmpty
                && router.removalCalls == [unknown]
        },
        "A retry must use the persisted exact protocol instead of rerunning Automatic discovery"
    )
    try expect(
        router.legacyRemovalCallCount == 1,
        "Once an uncertain protocol is known, retries must not run the legacy Automatic batch again"
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

        var requested = previous
        applyChange(&requested)
        do {
            _ = try agent.persistSettings(config: requested, token: "")
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

    var requested = previous
    requested.externalPort += 1
    do {
        _ = try agent.persistSettings(config: requested, token: "")
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
    agent.stop()
}

func testTemporaryAccessUsesIndependentExpirationTimer() throws {
    let baseDirectory = try makeTemporaryDirectory(named: "independent-expiration")
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let clock = LockedClock(Date(timeIntervalSince1970: 2_000_200_000))
    let expiresAt = clock.now().addingTimeInterval(30 * 60)
    let mapping = activeMappingFixture(
        transport: .pcp,
        family: .ipv4,
        renewAfter: clock.now().addingTimeInterval(15 * 60),
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
    agent.stop()
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
    agent.stop()
}

func testMappingRenewalWindowAndAddressChangeReconciliation() throws {
    func runCheck(with mapping: ActiveRouterMapping, router: MockRouterMappingService) throws -> NetworkAgent {
        let baseDirectory = try makeTemporaryDirectory(named: "mapping-renewal-\(UUID().uuidString)")
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.dnsProvider = .disabled
        config.preferredAddressFamily = .ipv4
        config.mappingProtocolPreference = .pcp
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
    freshAgent.stop()

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
    renewalAgent.stop()

    let oldAddress = activeMappingFixture(
        transport: .pcp,
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
    changedAgent.stop()
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
    agent.stop()
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
    let firstAgent = NetworkAgent(
        configStore: failingStore,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: failingRouter,
        emergencyMappingJournal: durableEmergencyJournal
    )
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
    firstAgent.stop()

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
        emergencyMappingJournal: durableEmergencyJournal
    )
    recoveredAgent.runCheck()
    try expect(
        waitUntil {
            recoveredRouter.removalCalls.map(\.identifier) == journaled.map(\.identifier)
                && (try? recoveredStore.loadMappingRecoveryJournal().isEmpty) == true
        },
        "The next launch must clean the journal before any new router mapping work"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Recovery cleanup must not create a replacement mapping")
    recoveredAgent.stop()
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
        emergencyMappingJournal: durableEmergencyJournal
    )
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
    firstAgent.stop()

    let recoveredRouter = MockRouterMappingService()
    let recoveredAgent = NetworkAgent(
        configStore: AppConfigStore(configURL: configURL),
        keychain: inMemoryKeychain(),
        initialConfig: .default,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: recoveredRouter,
        emergencyMappingJournal: durableEmergencyJournal
    )
    recoveredAgent.runCheck()
    try expect(
        waitUntil {
            recoveredRouter.removalCalls.map(\.identifier)
                == emergencyMappings.map(\.identifier)
                && (try? durableEmergencyJournal.load().isEmpty) == true
        },
        "A restart must load and remove emergency mappings before any replacement work"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Emergency recovery must not create a new router mapping")
    recoveredAgent.stop()
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
    let firstAgent = NetworkAgent(
        configStore: store,
        keychain: inMemoryKeychain(),
        initialConfig: config,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: failingRouter,
        emergencyMappingJournal: failingEmergency,
        fallbackMappingJournal: durableFallback
    )
    firstAgent.runCheck()
    try expect(
        waitUntil {
            failingRouter.ensureCalls == [.ipv4]
                && failingRouter.removalCalls.map(\.identifier).contains(uncleanMapping.identifier)
                && (try? durableFallback.load().map(\.identifier)) == [uncleanMapping.identifier]
        },
        "Emergency and primary journal failures plus delete failure must reach the durable fallback"
    )
    let failureDetail = firstAgent.status.routerStatus.detail
    try expect(failureDetail.contains(uncleanMapping.identifier), "The surfaced error must retain the full mapping identity")
    try expect(failureDetail.contains("Emergency journal failed"), "The surfaced error must include the emergency journal failure")
    try expect(failureDetail.contains("Primary journal failed"), "The surfaced error must include the primary journal failure")
    try expect(failureDetail.contains("Immediate cleanup retry failed"), "The surfaced error must include the second delete failure")

    firstAgent.runCheck()
    try expect(
        waitUntil {
            failingRouter.removalCalls.count >= 2
        },
        "A later check must retry the in-memory recovery identity"
    )
    try expect(
        failingRouter.ensureCalls == [.ipv4],
        "An in-memory recovery identity must block every new mapping attempt"
    )
    firstAgent.stop()

    let recoveredRouter = MockRouterMappingService()
    let recoveredAgent = NetworkAgent(
        configStore: AppConfigStore(configURL: configURL),
        keychain: inMemoryKeychain(),
        initialConfig: .default,
        localNetworkService: MockLocalNetworkService(),
        routerMappingService: recoveredRouter,
        emergencyMappingJournal: emergencyJournal(in: baseDirectory),
        fallbackMappingJournal: durableFallback
    )
    recoveredAgent.runCheck()
    try expect(
        waitUntil {
            recoveredRouter.removalCalls.map(\.identifier) == [uncleanMapping.identifier]
                && (try? durableFallback.load().isEmpty) == true
        },
        "A restart must recover the third-journal identity and clear it after idempotent cleanup"
    )
    try expect(recoveredRouter.ensureCalls.isEmpty, "Fallback recovery must finish before any new mapping")
    recoveredAgent.stop()
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
    try expectFailClosed(primaryAgent, router: primaryRouter, sourceName: "Primary recovery journal")
    try primaryStore.saveMappingRecoveryJournal([])
    primaryAgent.runCheck()
    try expect(
        waitUntil {
            primaryRouter.ensureCalls == [.ipv4]
        },
        "Recovery state must unlock only after all three sources read and clean successfully"
    )
    primaryAgent.stop()

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
    try expectFailClosed(
        emergencyAgent,
        router: emergencyRouter,
        sourceName: "Emergency recovery journal"
    )
    emergencyAgent.stop()

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
    try expectFailClosed(
        fallbackAgent,
        router: fallbackRouter,
        sourceName: "Fallback recovery journal"
    )
    fallbackAgent.stop()
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
    agent.runCheck()
    try expect(primaryReads.current == 0, "Disabled side effects must not read the primary production journal")
    try expect(emergencyReads.current == 0, "Disabled side effects must not read the emergency production journal")
    try expect(fallbackReads.current == 0, "Disabled side effects must not read the fallback production journal")
    agent.stop()
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

    agent.start()
    agent.runCheck()
    agent.setRemoteAccessEnabled(false)
    _ = try agent.persistSettings(config: .default, token: "")
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
    ("disabled side-effects check isolation", testDisabledSideEffectsRejectChecks),
    ("disabled side-effects config isolation", testDisabledSideEffectsDoNotReadSuppliedConfigStore),
    ("Keychain read error propagation", testKeychainReadFailurePropagates),
    ("Keychain delete rollback", testKeychainDeleteFailurePreservesTokenAndBlocksConfig),
    ("Keychain single-flight and failure latch", testKeychainSingleFlightAndFailureLatch),
    ("Keychain explicit legacy migration", testKeychainLegacyMigrationRequiresExplicitAuthorization),
    ("Keychain signing requirement classification", testKeychainRequirementClassificationRejectsWeakAlternatives),
    ("Keychain current item ACL refresh", testCurrentKeychainItemAuthorizationRefreshesAccess),
    ("Keychain legacy cleanup retry", testLegacyCleanupFailureRetriesWithoutLosingSecureCopy),
    ("Keychain explicit authorization latch", testExplicitKeychainAuthorizationClearsFailureLatch),
    ("Keychain migration and concurrent empty save", testLegacyMigrationSerializesConcurrentEmptySave),
    ("Keychain stale read and authorization ordering", testOldBackgroundReadCannotOverwriteAuthorizationSuccess),
    ("Keychain delete write authorize restart ordering", testDeleteWriteAuthorizeOrderingSurvivesBackendRestart),
    ("real config write failure", testConfigStoreReportsRealWriteFailure),
    ("settings transaction rollback", testSettingsTransactionRollsBackOnConfigWriteFailure),
    ("serialized concurrent state", testConcurrentStateAccessDoesNotDeadlock),
    ("check coalescing and interval storm resistance", testCheckCoalescingPreventsQueuedStorms),
    ("stale check cancellation before router side effects", testConfigMutationInvalidatesAnOldCheckBeforeRouterSideEffects),
    ("linearized final side-effect window", testSideEffectGateLinearizesTheFinalCheckWindow),
    ("router WAN public IPv4 selection", testRouterWANIPv4RequiresPublicRoutability),
    ("asynchronous settings persistence", testPersistSettingsAsyncNeverBlocksTheMainThread),
    ("superseded save mapping checkpoint merge", testSupersededSavePreservesCompletedMappingCleanup),
    ("local-origin TCP status semantics", testLocalOriginTCPStatusSemantics),
    ("start-at-login result visibility", testStartAtLoginFailureIsVisibleAndRevertsConfig),
    ("mapping disable retry state", testRemoteAccessDisableRetainsFailedMappingForRetry),
    ("legacy Automatic exact retry state", testLegacyAutomaticCleanupPersistsOnlyUnknownProtocol),
    ("UPnP recovery explicit enabled contract", testUPnPRecoveryRequiresExplicitEnabledRule),
    ("mapping identity transaction", testMappingIdentityChangeMustDeleteOldRuleFirst),
    ("post-cleanup persistence truth", testPostCleanupPersistenceFailureKeepsTruthfulMappingState),
    ("temporary access cleanup retry", testTemporaryAccessExpiryDoesNotHideCleanupFailure),
    ("independent temporary access expiration", testTemporaryAccessUsesIndependentExpirationTimer),
    ("temporary access shortens existing router lease", testTemporaryAccessRevokesAnExistingOverlongLease),
    ("mapping renewal and address reconciliation", testMappingRenewalWindowAndAddressChangeReconciliation),
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
