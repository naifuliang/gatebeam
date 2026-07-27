import Foundation
import Darwin

private let configStore = AppConfigStore()
private let keychain = KeychainStore(
    useDataProtectionKeychain: false,
    service: "io.github.naifuliang.gatebeam.diagnostics-v2"
)
private let cloudflare = CloudflareDNSProvider()
private let publicIPService = PublicIPService()
private let localNetwork = LocalNetworkService()
private let routerMapping = RouterMappingService()
private var runtimeToken: String?

private func requireToken() throws -> String {
    if let runtimeToken, !runtimeToken.isEmpty {
        return runtimeToken
    }
    guard let token = try keychain.get(account: "cloudflare-api-token"), !token.isEmpty else {
        throw DiagnosticError.message("No Cloudflare token in Keychain. Run: backend-diagnostics store-token")
    }
    return token
}

private func readHiddenToken() throws -> String {
    guard isatty(STDIN_FILENO) == 1 else {
        throw DiagnosticError.message("Token entry requires an interactive Terminal")
    }
    guard let pointer = getpass("Cloudflare API token (input hidden): ") else {
        throw DiagnosticError.message("Could not read token")
    }
    let token = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
        throw DiagnosticError.message("Token was empty")
    }
    return token
}

private func storeToken() throws {
    let token = try readHiddenToken()
    try keychain.set(token, account: "cloudflare-api-token")
    print("Saved Cloudflare token to macOS Keychain.")
}

private func listZones() throws {
    let zones = try cloudflare.listZones(token: requireToken())
    guard !zones.isEmpty else {
        throw DiagnosticError.message("Token is active but no accessible Cloudflare zones were returned")
    }
    print("Cloudflare token is active. Accessible zones: \(zones.count)")
    for zone in zones {
        print("- \(zone.name) [\(zone.status)]")
    }
}

private func configureCloudflareRecord(_ requestedName: String) throws {
    let recordName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
    guard !recordName.isEmpty else {
        throw DiagnosticError.message("DNS record name is empty")
    }

    let zones = try cloudflare.listZones(token: requireToken())
    guard let zone = zones
        .filter({ recordName == $0.name.lowercased() || recordName.hasSuffix(".\($0.name.lowercased())") })
        .max(by: { $0.name.count < $1.name.count }) else {
        throw DiagnosticError.message("No accessible Cloudflare zone contains \(recordName)")
    }

    var config = configStore.load()
    config.dnsProvider = .cloudflare
    config.cloudflareZoneID = zone.id
    config.dnsRecordName = recordName
    configStore.save(config)
    print("Configured Cloudflare record: \(recordName)")
    print("Matched zone: \(zone.name)")
}

private func checkCloudflare(writeRecord: Bool) throws {
    let config = configStore.load()
    guard !config.cloudflareZoneID.isEmpty, !config.dnsRecordName.isEmpty else {
        throw DiagnosticError.message("Choose a Cloudflare zone and DNS record name first")
    }

    let token = try requireToken()
    let validation = try cloudflare.validateConfiguration(
        zoneID: config.cloudflareZoneID,
        recordName: config.dnsRecordName,
        token: token
    )
    print("Cloudflare configuration valid: \(validation.zoneName) [\(validation.zoneStatus)]")
    if let content = validation.recordContent {
        print("Existing A record: \(config.dnsRecordName) -> \(content)")
    } else {
        print("A record does not exist yet; the app can create it.")
    }

    guard writeRecord else { return }
    let publicAddress: String
    if let gatewayAddress = localNetwork.defaultGatewayIPv4(),
       let routerAddress = try? routerMapping.externalIPv4Address(gatewayAddress: gatewayAddress) {
        publicAddress = routerAddress
        print("DDNS address source: router WAN (NAT-PMP/UPnP)")
    } else {
        publicAddress = try publicIPService.currentIPv4()
        print("DDNS address source: external HTTPS fallback")
    }
    let result = try cloudflare.upsertARecord(
        zoneID: config.cloudflareZoneID,
        recordName: config.dnsRecordName,
        ipAddress: publicAddress,
        token: token
    )
    print("DDNS write verified: \(config.dnsRecordName) -> \(result.content)")
    print(result.changed ? "Cloudflare record was created or updated." : "Cloudflare record already matched; no write was needed.")
}

private func checkRouter() throws {
    let config = configStore.load()
    guard localNetwork.isTCPPortOpen(port: config.internalPort) else {
        throw DiagnosticError.message("Local TCP port \(config.internalPort) is closed. Enable macOS Screen Sharing or Remote Management first.")
    }
    guard let localAddress = localNetwork.localIPv4Address() else {
        throw DiagnosticError.message("Could not determine the LAN IPv4 address")
    }
    guard let gatewayAddress = localNetwork.defaultGatewayIPv4() else {
        throw DiagnosticError.message("Could not determine the default gateway")
    }

    print("Local service verified: \(localAddress):\(config.internalPort)")
    print("Default gateway: \(gatewayAddress)")
    let result = try routerMapping.ensureMapping(
        config: config,
        localAddress: localAddress,
        gatewayAddress: gatewayAddress
    )
    print("Router mapping verified with \(result.protocolName): \(result.message)")
    if let routerExternalAddress = result.routerExternalAddress {
        print("Router-reported public address: \(routerExternalAddress)")
    }
}

private func inspectRouter() throws {
    let config = configStore.load()
    let portIsOpen = localNetwork.isTCPPortOpen(port: config.internalPort)
    guard let localAddress = localNetwork.localIPv4Address() else {
        throw DiagnosticError.message("Could not determine the LAN IPv4 address")
    }
    guard let gatewayAddress = localNetwork.defaultGatewayIPv4() else {
        throw DiagnosticError.message("Could not determine the default gateway")
    }

    print("Local address: \(localAddress)")
    print("Local TCP \(config.internalPort): \(portIsOpen ? "listening" : "closed")")
    print("Default gateway: \(gatewayAddress)")
    let result = try routerMapping.inspectCapabilities(gatewayAddress: gatewayAddress)
    print("NAT-PMP: \(result.natPMPAvailable ? "available" : "not detected")")
    print("UPnP IGD: \(result.upnpAvailable ? "available" : "not detected")")
    if let routerExternalAddress = result.routerExternalAddress {
        print("Router-reported public address: \(routerExternalAddress)")
        if let directAddress = try? publicIPService.currentIPv4() {
            print("Direct no-proxy public address: \(directAddress)")
            print(directAddress == routerExternalAddress ? "Public address sources agree." : "WARNING: direct and router addresses differ.")
        }
    }
}

private func removeRouterAccess() {
    var config = configStore.load()
    if let localAddress = localNetwork.localIPv4Address(),
       let gatewayAddress = localNetwork.defaultGatewayIPv4() {
        routerMapping.removeMapping(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        )
        print("Requested removal of IPv4 PCP, NAT-PMP, and UPnP mappings.")
    }
    if let localAddress = localNetwork.globalIPv6Address(),
       let gatewayAddress = localNetwork.defaultGatewayIPv6() {
        routerMapping.removeIPv6Pinhole(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress
        )
        print("Requested removal of IPv6 PCP and UPnP pinholes.")
    }
    config.remoteAccessEnabled = false
    config.accessExpiresAt = nil
    config.ipv6PinholeID = nil
    configStore.save(config)
    print("Remote access is now disabled in the saved configuration.")
}

private func printUsage() {
    print("""
    Usage: backend-diagnostics <command>

      store-token       Securely save a Cloudflare API token in Keychain
      zones             Verify token and list accessible Cloudflare zones
      configure-record  Select the matching zone and save a full DNS record name
      cloudflare-read   Validate configured zone and record without changing DNS
      cloudflare        Validate and create/update the configured A record
      cloudflare-stdin  Read a token without storing it, then validate and update DNS
      router-read       Inspect local port and router capabilities without changing mappings
      router            Verify local port and create/confirm router mapping
      router-remove     Remove app-managed mappings and disable remote access
      all               Run Cloudflare write and router mapping verification
    """)
}

private enum DiagnosticError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "help"
    switch command {
    case "store-token":
        try storeToken()
    case "zones":
        try listZones()
    case "configure-record":
        guard arguments.count == 2 else {
            throw DiagnosticError.message("Usage: backend-diagnostics configure-record <full-dns-name>")
        }
        try configureCloudflareRecord(arguments[1])
    case "cloudflare-read":
        try checkCloudflare(writeRecord: false)
    case "cloudflare":
        try checkCloudflare(writeRecord: true)
    case "cloudflare-stdin":
        runtimeToken = try readHiddenToken()
        try checkCloudflare(writeRecord: true)
        runtimeToken = nil
    case "router":
        try checkRouter()
    case "router-read":
        try inspectRouter()
    case "router-remove":
        removeRouterAccess()
    case "all":
        try checkCloudflare(writeRecord: true)
        try checkRouter()
    case "help", "--help", "-h":
        printUsage()
    default:
        printUsage()
        throw DiagnosticError.message("Unknown command: \(command)")
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
