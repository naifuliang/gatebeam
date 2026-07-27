import Foundation
import Darwin

final class NetworkAgent {
    private let configStore: AppConfigStore
    private let keychain: KeychainStore
    private let localNetworkService = LocalNetworkService()
    private let routerMappingService = RouterMappingService()
    private let launchAgentManager = LaunchAgentManager()
    private let queue = DispatchQueue(label: "RemoteControlNetwork.NetworkAgent", qos: .utility)
    private let sideEffectsEnabled: Bool
    private var timer: DispatchSourceTimer?
    private var cachedCloudflareToken: String?
    private(set) var status = AppStatus.initial
    private(set) var config: AppConfig

    var onStatusChanged: ((AppStatus) -> Void)?
    var onConfigChanged: ((AppConfig) -> Void)?

    init(
        configStore: AppConfigStore,
        keychain: KeychainStore,
        initialConfig: AppConfig? = nil,
        sideEffectsEnabled: Bool = true
    ) {
        self.configStore = configStore
        self.keychain = keychain
        self.config = initialConfig ?? configStore.load()
        self.sideEffectsEnabled = sideEffectsEnabled
    }

    func start() {
        runCheck()
        queue.async {
            self.restartTimer()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func runCheck() {
        publish { current in
            current.ddnsStatus = ComponentStatus(state: .checking, message: "Checking DDNS", detail: "", updatedAt: Date())
            current.routerStatus = ComponentStatus(state: .checking, message: "Checking router access", detail: "", updatedAt: Date())
            current.remoteDesktopStatus = ComponentStatus(state: .checking, message: "Checking remote desktop", detail: "", updatedAt: Date())
            current.externalReachabilityStatus = ComponentStatus(state: .checking, message: "Checking reachability", detail: "", updatedAt: Date())
        }
        queue.async {
            self.performCheck()
        }
    }

    func saveConfig(_ newConfig: AppConfig) {
        queue.async {
            let oldConfig = self.config
            self.config = newConfig
            guard self.sideEffectsEnabled else {
                DispatchQueue.main.async {
                    self.onConfigChanged?(newConfig)
                }
                return
            }
            self.configStore.save(newConfig)
            self.launchAgentManager.setEnabled(newConfig.startAtLogin)
            DispatchQueue.main.async {
                self.onConfigChanged?(newConfig)
            }

            if oldConfig.remoteAccessEnabled && !newConfig.remoteAccessEnabled {
                self.removeMappings(config: oldConfig)
            }
            if oldConfig.checkIntervalSeconds != newConfig.checkIntervalSeconds {
                self.restartTimer()
            }
            self.performCheck()
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
        next.accessExpiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        saveConfig(next)
    }

    func cloudflareToken() -> String {
        if let cachedCloudflareToken {
            return cachedCloudflareToken
        }
        guard sideEffectsEnabled else { return "" }
        let token = (try? keychain.get(account: "cloudflare-api-token")) ?? ""
        cachedCloudflareToken = token
        return token
    }

    func saveCloudflareToken(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedCloudflareToken == normalized {
            return
        }
        guard sideEffectsEnabled else {
            cachedCloudflareToken = normalized
            return
        }
        if normalized.isEmpty {
            keychain.delete(account: "cloudflare-api-token")
        } else {
            try keychain.set(normalized, account: "cloudflare-api-token")
        }
        cachedCloudflareToken = normalized
    }

    func loadCloudflareZones(
        token: String? = nil,
        proxyMode: NetworkProxyMode? = nil,
        customProxyURL: String? = nil,
        completion: @escaping (Result<[CloudflareZoneSummary], Error>) -> Void
    ) {
        queue.async {
            do {
                let candidate = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.cloudflareToken()
                guard !candidate.isEmpty else {
                    throw CloudflareError.configuration("Cloudflare API token is missing")
                }
                let provider = try self.makeDNSProvider(
                    mode: proxyMode ?? self.config.ddnsProxyMode,
                    customProxyURL: customProxyURL ?? self.config.customProxyURL
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
    }

    func validateCloudflareConfiguration(
        zoneID: String,
        recordName: String,
        token: String? = nil,
        proxyMode: NetworkProxyMode? = nil,
        customProxyURL: String? = nil,
        completion: @escaping (Result<CloudflareValidationResult, Error>) -> Void
    ) {
        queue.async {
            do {
                let candidate = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.cloudflareToken()
                guard !candidate.isEmpty else {
                    throw CloudflareError.configuration("Cloudflare API token is missing")
                }
                let provider = try self.makeDNSProvider(
                    mode: proxyMode ?? self.config.ddnsProxyMode,
                    customProxyURL: customProxyURL ?? self.config.customProxyURL
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
    }

    private func performCheck() {
        var next = AppStatus.initial
        var workingConfig = config
        var configChanged = false

        if let expiresAt = workingConfig.accessExpiresAt, expiresAt <= Date() {
            let expiredConfig = workingConfig
            workingConfig.remoteAccessEnabled = false
            workingConfig.accessExpiresAt = nil
            removeMappings(config: expiredConfig)
            configChanged = true
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

        if localNetworkService.isTCPPortListening(port: workingConfig.internalPort) {
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
                let address = try currentPublicIPv4(config: workingConfig, gatewayAddress: gatewayIPv4)
                next.publicAddress = address
                if PublicIPService.isPrivateOrCGNAT(address) {
                    let internetAddress = try? makePublicIPService(config: workingConfig).currentIPv4()
                    let suffix = internetAddress.map { " Internet-facing address: \($0)." } ?? ""
                    ipv4Issue = "Router WAN address \(address) is private or CGNAT.\(suffix)"
                } else {
                    ddnsIPv4 = address
                }
            } catch {
                ipv4Issue = error.localizedDescription
            }
        }

        var ddnsIPv6: String?
        var ipv6Issue: String?
        if workingConfig.preferredAddressFamily.usesIPv6 {
            if let localIPv6 {
                ddnsIPv6 = localIPv6
                if let internetIPv6 = try? makePublicIPService(config: workingConfig).currentIPv6() {
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
            next.ddnsStatus = updateDDNS(
                config: workingConfig,
                ipv4Address: ddnsIPv4,
                ipv6Address: ddnsIPv6,
                ipv4Issue: ipv4Issue,
                ipv6Issue: ipv6Issue
            )
            let mapping = ensureRouterMappings(
                config: workingConfig,
                localIPv4: localIPv4,
                gatewayIPv4: gatewayIPv4,
                localIPv6: localIPv6,
                gatewayIPv6: gatewayIPv6,
                remoteDesktopStatus: next.remoteDesktopStatus
            )
            next.routerStatus = mapping.status
            if let port = mapping.ipv4Port { next.externalPort = port }
            next.ipv6ExternalPort = mapping.ipv6Port
            if mapping.pinholeID != workingConfig.ipv6PinholeID {
                workingConfig.ipv6PinholeID = mapping.pinholeID
                configChanged = true
            }
        }

        buildConnectionURLs(config: workingConfig, status: &next)
        next.externalReachabilityStatus = verifyExternalReachability(config: workingConfig, status: next)
        next.lastCheckedAt = Date()

        if configChanged {
            config = workingConfig
            configStore.save(workingConfig)
            DispatchQueue.main.async {
                self.onConfigChanged?(workingConfig)
            }
        }
        publish(next)
    }

    private func updateDDNS(
        config: AppConfig,
        ipv4Address: String?,
        ipv6Address: String?,
        ipv4Issue: String?,
        ipv6Issue: String?
    ) -> ComponentStatus {
        guard config.dnsProvider != .disabled else {
            return .disabled("DDNS is disabled")
        }
        guard !config.cloudflareZoneID.isEmpty, !config.dnsRecordName.isEmpty else {
            return .warning("Cloudflare is not configured", detail: "Select a domain and enter the subdomain and API token.")
        }
        let token = cloudflareToken()
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
                    let result = try dnsProvider.upsertARecord(
                        zoneID: config.cloudflareZoneID,
                        recordName: config.dnsRecordName,
                        ipAddress: ipv4Address,
                        token: token
                    )
                    successes.append(result.message)
                } catch {
                    failures.append("A: \(error.localizedDescription)")
                }
            } else {
                failures.append("A: \(ipv4Issue ?? "No public IPv4 address")")
            }
        }
        if config.preferredAddressFamily.usesIPv6 {
            if let ipv6Address {
                do {
                    let result = try dnsProvider.upsertAAAARecord(
                        zoneID: config.cloudflareZoneID,
                        recordName: config.dnsRecordName,
                        ipAddress: ipv6Address,
                        token: token
                    )
                    successes.append(result.message)
                    if let ipv6Issue { notes.append("IPv6 note: \(ipv6Issue)") }
                } catch {
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

    private func currentPublicIPv4(config: AppConfig, gatewayAddress: String?) throws -> String {
        if let gatewayAddress,
           let routerAddress = try? routerMappingService.externalIPv4Address(gatewayAddress: gatewayAddress),
           PublicIPService.looksLikeIPv4(routerAddress) {
            return routerAddress
        }
        return try makePublicIPService(config: config).currentIPv4()
    }

    private func makeDNSProvider(mode: NetworkProxyMode, customProxyURL: String) throws -> CloudflareDNSProvider {
        try CloudflareDNSProvider(proxyMode: mode, customProxyURL: customProxyURL)
    }

    private func makePublicIPService(config: AppConfig) throws -> PublicIPService {
        try PublicIPService(
            proxyMode: config.publicIPProxyMode,
            customProxyURL: config.customProxyURL
        )
    }

    private func ensureRouterMappings(
        config: AppConfig,
        localIPv4: String?,
        gatewayIPv4: String?,
        localIPv6: String?,
        gatewayIPv6: String?,
        remoteDesktopStatus: ComponentStatus
    ) -> RouterMappingOutcome {
        guard config.mappingProtocolPreference != .disabled else {
            return RouterMappingOutcome(status: .disabled("Router mapping is disabled"))
        }
        guard remoteDesktopStatus.state == .ok else {
            return RouterMappingOutcome(status: .failed("Remote desktop is not ready", detail: remoteDesktopStatus.detail))
        }

        var successes: [String] = []
        var failures: [String] = []
        var ipv4Port: UInt16?
        var ipv6Port: UInt16?
        var pinholeID = config.ipv6PinholeID

        if config.preferredAddressFamily.usesIPv4 {
            if let localIPv4, let gatewayIPv4 {
                do {
                    let result = try routerMappingService.ensureMapping(
                        config: config,
                        localAddress: localIPv4,
                        gatewayAddress: gatewayIPv4
                    )
                    ipv4Port = result.externalPort
                    successes.append("IPv4: \(result.message) via \(result.protocolName)")
                } catch {
                    failures.append("IPv4: \(error.localizedDescription)")
                }
            } else {
                failures.append("IPv4: local address or default gateway is unavailable")
            }
        }

        if config.preferredAddressFamily.usesIPv6 {
            if let localIPv6, let gatewayIPv6 {
                do {
                    let result = try routerMappingService.ensureIPv6Pinhole(
                        config: config,
                        localAddress: localIPv6,
                        gatewayAddress: gatewayIPv6
                    )
                    ipv6Port = result.externalPort
                    if let resultID = result.pinholeID { pinholeID = resultID }
                    successes.append("IPv6: \(result.message) via \(result.protocolName)")
                } catch {
                    failures.append("IPv6: \(error.localizedDescription)")
                }
            } else {
                failures.append("IPv6: global address or default gateway is unavailable")
            }
        }

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
            pinholeID: pinholeID
        )
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

    private func verifyExternalReachability(config: AppConfig, status: AppStatus) -> ComponentStatus {
        guard config.remoteAccessEnabled else {
            return .disabled("Remote access is off")
        }

        if !config.dnsRecordName.isEmpty {
            var missing: [String] = []
            if config.preferredAddressFamily.usesIPv4, resolveAddress(config.dnsRecordName, family: AF_INET) == nil {
                missing.append("A")
            }
            if config.preferredAddressFamily.usesIPv6, resolveAddress(config.dnsRecordName, family: AF_INET6) == nil {
                missing.append("AAAA")
            }
            if !missing.isEmpty {
                return .warning("DNS has not fully resolved yet", detail: "Missing \(missing.joined(separator: " and ")) for \(config.dnsRecordName)")
            }
        }

        let probeHost = config.externalProbeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if probeHost.isEmpty {
            return .warning("External probe not configured", detail: "Router access was attempted, but true internet reachability needs an outside probe.")
        }

        var checks: [Bool] = []
        if config.preferredAddressFamily.usesIPv4,
           let address = resolveAddress(probeHost, family: AF_INET) {
            checks.append(localNetworkService.isTCPPortOpen(host: address, port: status.externalPort ?? config.externalPort, timeout: 4))
        }
        if config.preferredAddressFamily.usesIPv6,
           let address = resolveAddress(probeHost, family: AF_INET6) {
            checks.append(localNetworkService.isTCPPortOpen(host: address, port: status.ipv6ExternalPort ?? config.externalPort, timeout: 4))
        }
        if checks.contains(true) {
            return checks.allSatisfy { $0 }
                ? .ok("External probe connected", detail: probeHost)
                : .warning("External probe is partially reachable", detail: probeHost)
        }
        return .failed("External probe could not connect", detail: probeHost)
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

    private func removeMappings(config: AppConfig) {
        if config.preferredAddressFamily.usesIPv4,
           let local = localNetworkService.localIPv4Address(),
           let gateway = localNetworkService.defaultGatewayIPv4() {
            routerMappingService.removeMapping(config: config, localAddress: local, gatewayAddress: gateway)
        }
        if config.preferredAddressFamily.usesIPv6,
           let local = localNetworkService.globalIPv6Address(),
           let gateway = localNetworkService.defaultGatewayIPv6() {
            routerMappingService.removeIPv6Pinhole(config: config, localAddress: local, gatewayAddress: gateway)
        }
    }

    private func publish(_ update: (inout AppStatus) -> Void) {
        var next = status
        update(&next)
        publish(next)
    }

    private func publish(_ next: AppStatus) {
        status = next
        DispatchQueue.main.async {
            self.onStatusChanged?(next)
        }
    }

    private func restartTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.checkIntervalSeconds, repeating: config.checkIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.performCheck()
        }
        self.timer = timer
        timer.resume()
    }
}

private struct RouterMappingOutcome {
    let status: ComponentStatus
    var ipv4Port: UInt16? = nil
    var ipv6Port: UInt16? = nil
    var pinholeID: UInt16? = nil
}
