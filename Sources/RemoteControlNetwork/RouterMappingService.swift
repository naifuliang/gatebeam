import Foundation
import Darwin

struct PortMappingResult {
    let protocolName: String
    let externalPort: UInt16
    let routerExternalAddress: String?
    let message: String
    var pinholeID: UInt16? = nil
}

struct RouterCapabilityResult {
    let natPMPAvailable: Bool
    let upnpAvailable: Bool
    let routerExternalAddress: String?
    var pcpAvailable: Bool = false
    var ipv6FirewallAvailable: Bool = false
}

final class RouterMappingService {
    // Router control is always local. It must never follow a system or custom
    // proxy, which could leak private IGD requests or make discovery unusable.
    private let http = HTTPClient(useSystemProxy: false)

    func externalIPv4Address(gatewayAddress: String) throws -> String {
        do {
            return try queryNATPMPExternalAddress(gatewayAddress: gatewayAddress)
        } catch {
            let service = try discoverUPnPService()
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
            let service = try discoverUPnPService()
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
            return try addNATPMPMapping(config: config, gatewayAddress: gatewayAddress)
        case .upnp:
            return try addUPnPMapping(config: config, localAddress: localAddress)
        case .automatic:
            var errors: [String] = []
            do {
                return try addPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, familyName: "IPv4")
            } catch {
                errors.append("PCP: \(error.localizedDescription)")
            }
            do {
                return try addNATPMPMapping(config: config, gatewayAddress: gatewayAddress)
            } catch {
                errors.append("NAT-PMP: \(error.localizedDescription)")
            }
            do {
                return try addUPnPMapping(config: config, localAddress: localAddress)
            } catch {
                errors.append("UPnP: \(error.localizedDescription)")
            }
            throw RouterMappingError.allProtocolsFailed(errors.joined(separator: "\n"))
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
            return try addUPnPIPv6Pinhole(config: config, localAddress: localAddress)
        case .automatic:
            var errors: [String] = []
            do {
                return try addPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, familyName: "IPv6")
            } catch {
                errors.append("PCP: \(error.localizedDescription)")
            }
            do {
                return try addUPnPIPv6Pinhole(config: config, localAddress: localAddress)
            } catch {
                errors.append("UPnP IPv6: \(error.localizedDescription)")
            }
            throw RouterMappingError.allProtocolsFailed(errors.joined(separator: "\n"))
        }
    }

    func removeMapping(config: AppConfig, localAddress: String, gatewayAddress: String) {
        if config.mappingProtocolPreference == .pcp || config.mappingProtocolPreference == .automatic {
            _ = try? sendPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, lifetime: 0)
        }
        if config.mappingProtocolPreference == .natpmp || config.mappingProtocolPreference == .automatic {
            _ = try? sendNATPMPMapping(config: config, gatewayAddress: gatewayAddress, lifetime: 0)
        }
        if config.mappingProtocolPreference == .upnp || config.mappingProtocolPreference == .automatic {
            try? deleteUPnPMapping(config: config, localAddress: localAddress)
        }
    }

    func removeIPv6Pinhole(config: AppConfig, localAddress: String, gatewayAddress: String) {
        if config.mappingProtocolPreference == .pcp || config.mappingProtocolPreference == .automatic {
            _ = try? sendPCPMapping(config: config, localAddress: localAddress, gatewayAddress: gatewayAddress, lifetime: 0)
        }
        if config.mappingProtocolPreference == .upnp || config.mappingProtocolPreference == .automatic,
           let pinholeID = config.ipv6PinholeID {
            try? deleteUPnPIPv6Pinhole(pinholeID: pinholeID)
        }
    }

    private func addPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        familyName: String
    ) throws -> PortMappingResult {
        let response = try sendPCPMapping(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gatewayAddress,
            lifetime: config.mappingLeaseSeconds
        )
        return PortMappingResult(
            protocolName: "PCP \(familyName)",
            externalPort: response.externalPort,
            routerExternalAddress: response.externalAddress,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s"
        )
    }

    private func sendPCPMapping(
        config: AppConfig,
        localAddress: String,
        gatewayAddress: String,
        lifetime: UInt32
    ) throws -> PCPMappingResponse {
        let nonce = pcpNonce(config: config)
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

    private func addNATPMPMapping(config: AppConfig, gatewayAddress: String) throws -> PortMappingResult {
        let response = try sendNATPMPMapping(config: config, gatewayAddress: gatewayAddress, lifetime: config.mappingLeaseSeconds)
        let routerExternalAddress = try? queryNATPMPExternalAddress(gatewayAddress: gatewayAddress)
        return PortMappingResult(
            protocolName: "NAT-PMP",
            externalPort: response.externalPort,
            routerExternalAddress: routerExternalAddress,
            message: "Verified TCP \(response.externalPort) -> \(config.internalPort) for \(response.lifetimeSeconds)s"
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
            throw RouterMappingError.protocolFailure("NAT-PMP result code \(resultCode)")
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

    private func addUPnPMapping(config: AppConfig, localAddress: String) throws -> PortMappingResult {
        let service = try discoverUPnPService()
        var lease = config.mappingLeaseSeconds
        do {
            try addUPnPMapping(config: config, localAddress: localAddress, service: service, lease: lease)
        } catch {
            guard lease != 0 else { throw error }
            lease = 0
            try addUPnPMapping(config: config, localAddress: localAddress, service: service, lease: lease)
        }

        try verifyUPnPMapping(config: config, localAddress: localAddress, service: service)
        let routerExternalAddress = try? queryUPnPExternalAddress(service: service)
        let leaseDescription = lease == 0 ? "permanent lease" : "\(lease)s lease"
        return PortMappingResult(
            protocolName: "UPnP IGD",
            externalPort: config.externalPort,
            routerExternalAddress: routerExternalAddress,
            message: "Verified TCP \(config.externalPort) -> \(localAddress):\(config.internalPort), \(leaseDescription)"
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

    private func verifyUPnPMapping(config: AppConfig, localAddress: String, service: UPnPService) throws {
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetSpecificPortMappingEntry xmlns:u="\(service.serviceType)">
              <NewRemoteHost></NewRemoteHost>
              <NewExternalPort>\(config.externalPort)</NewExternalPort>
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
        let values = Self.xmlValues(in: response.data)
        guard values["NewInternalClient"] == localAddress,
              values["NewInternalPort"] == String(config.internalPort),
              values["NewEnabled"] != "0" else {
            throw RouterMappingError.invalidResponse("UPnP mapping could not be confirmed after creation")
        }
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

    private func deleteUPnPMapping(config: AppConfig, localAddress: String) throws {
        let service = try discoverUPnPService()
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:DeletePortMapping xmlns:u="\(service.serviceType)">
              <NewRemoteHost></NewRemoteHost>
              <NewExternalPort>\(config.externalPort)</NewExternalPort>
              <NewProtocol>TCP</NewProtocol>
            </u:DeletePortMapping>
          </s:Body>
        </s:Envelope>
        """
        _ = localAddress
        _ = try soapRequest(controlURL: service.controlURL, serviceType: service.serviceType, action: "DeletePortMapping", body: body)
    }

    private func addUPnPIPv6Pinhole(config: AppConfig, localAddress: String) throws -> PortMappingResult {
        guard PublicIPService.isGlobalIPv6(localAddress) else {
            throw RouterMappingError.protocolFailure("UPnP IPv6 pinholes require a global IPv6 address on this Mac")
        }
        let service = try discoverUPnPIPv6FirewallService()
        let firewallStatus = try queryUPnPIPv6FirewallStatus(service: service)
        guard firewallStatus.firewallEnabled, firewallStatus.inboundPinholeAllowed else {
            throw RouterMappingError.protocolFailure("The router reports that inbound IPv6 pinholes are disabled")
        }

        let lease = min(max(config.mappingLeaseSeconds, 3600), 86_400)
        var pinholeID = config.ipv6PinholeID
        if let existingID = pinholeID {
            do {
                try updateUPnPIPv6Pinhole(service: service, pinholeID: existingID, lease: lease)
            } catch {
                pinholeID = nil
            }
        }
        if pinholeID == nil {
            pinholeID = try createUPnPIPv6Pinhole(
                service: service,
                localAddress: localAddress,
                internalPort: config.internalPort,
                lease: lease
            )
        }

        return PortMappingResult(
            protocolName: "UPnP IPv6 Firewall",
            externalPort: config.internalPort,
            routerExternalAddress: localAddress,
            message: "Opened IPv6 TCP \(config.internalPort) to \(localAddress) for \(lease)s",
            pinholeID: pinholeID
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

    private func deleteUPnPIPv6Pinhole(pinholeID: UInt16) throws {
        let service = try discoverUPnPIPv6FirewallService()
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
        _ = try soapRequest(
            controlURL: service.controlURL,
            serviceType: service.serviceType,
            action: "DeletePinhole",
            body: body
        )
    }

    private func discoverUPnPService() throws -> UPnPService {
        let services = try discoverUPnPServices()
        let candidates = services.filter {
            $0.serviceType.contains("WANIPConnection") || $0.serviceType.contains("WANPPPConnection")
        }.sorted {
            if $0.serviceType.contains("WANIPConnection") != $1.serviceType.contains("WANIPConnection") {
                return $0.serviceType.contains("WANIPConnection")
            }
            return $0.serviceType > $1.serviceType
        }
        guard let service = candidates.first else {
            throw RouterMappingError.protocolFailure("UPnP description did not contain WANIPConnection")
        }
        return service
    }

    private func discoverUPnPIPv6FirewallService() throws -> UPnPService {
        guard let service = try discoverUPnPServices().first(where: {
            $0.serviceType.contains("WANIPv6FirewallControl")
        }) else {
            throw RouterMappingError.protocolFailure("No UPnP WANIPv6FirewallControl service discovered")
        }
        return service
    }

    private func discoverUPnPServices() throws -> [UPnPService] {
        let targets = [
            "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
            "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1"
        ]
        let payloads = targets.map { target in
            Data("""
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: "ssdp:discover"\r
            MX: 2\r
            ST: \(target)\r
            \r
            """.utf8)
        }
        let responses = try udpMulticastSearch(payloads: payloads, host: "239.255.255.250", port: 1900, timeoutSeconds: 4)
        let locations = responses.compactMap { response -> URL? in
            let text = String(data: response, encoding: .utf8) ?? ""
            return Self.headerValue("location", in: text).flatMap(URL.init(string:))
        }

        var services: [UPnPService] = []
        for location in Array(Set(locations)) {
            do {
                services.append(contentsOf: try parseUPnPDescription(location: location))
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

    private func parseUPnPDescription(location: URL) throws -> [UPnPService] {
        let response = try http.request(url: location, timeout: 6)
        guard (200...299).contains(response.statusCode) else {
            throw RouterMappingError.protocolFailure("UPnP description HTTP \(response.statusCode)")
        }
        let description = UPnPDescriptionParser.parse(response.data)
        let baseURL = description.urlBase.flatMap(URL.init(string:)) ?? location
        let services = description.services.compactMap { candidate -> UPnPService? in
            guard candidate.serviceType.contains("WANIPConnection")
                    || candidate.serviceType.contains("WANPPPConnection")
                    || candidate.serviceType.contains("WANIPv6FirewallControl"),
                  let controlURL = URL(string: candidate.controlURL, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return UPnPService(serviceType: candidate.serviceType, controlURL: controlURL)
        }
        guard !services.isEmpty else {
            throw RouterMappingError.protocolFailure("UPnP description did not contain a supported WAN service")
        }
        return services
    }

    private func soapRequest(controlURL: URL, serviceType: String, action: String, body: String) throws -> HTTPResponse {
        let response = try http.request(
            url: controlURL,
            method: "POST",
            headers: [
                "Content-Type": "text/xml; charset=\"utf-8\"",
                "SOAPAction": "\"\(serviceType)#\(action)\""
            ],
            body: Data(body.utf8),
            timeout: 8
        )
        guard (200...299).contains(response.statusCode) else {
            let values = Self.xmlValues(in: response.data)
            let code = values["errorCode"].map { " code \($0)" } ?? ""
            let description = values["errorDescription"].map { ": \($0)" } ?? ""
            throw RouterMappingError.protocolFailure("UPnP \(action) failed: HTTP \(response.statusCode)\(code)\(description)")
        }
        return response
    }

    private func udpMulticastSearch(payloads: [Data], host: String, port: UInt16, timeoutSeconds: Int) throws -> [Data] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw RouterMappingError.socket("socket() failed") }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &destination.sin_addr)

        for payload in payloads {
            let sent = payload.withUnsafeBytes { bytes -> ssize_t in
                guard let base = bytes.baseAddress else { return -1 }
                return withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketFD, base, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent > 0 else { throw RouterMappingError.socket("sendto() failed") }
        }

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

    private func udpRequest(payload: Data, host: String, port: UInt16, timeoutSeconds: Int) throws -> Data {
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
            lastError = "No UDP response from \(host):\(port)"
        }
        throw RouterMappingError.timeout(lastError)
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
        guard response.count >= 60 else {
            throw RouterMappingError.invalidResponse("PCP MAP response too short")
        }
        guard response[0] == 2, response[1] == 0x81 else {
            throw RouterMappingError.invalidResponse("Unexpected PCP MAP opcode")
        }
        let resultCode = response[3]
        guard resultCode == 0 else {
            throw RouterMappingError.protocolFailure("PCP MAP result code \(resultCode)")
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

private struct UPnPService {
    let serviceType: String
    let controlURL: URL
}

private struct UPnPServiceDescription {
    let urlBase: String?
    let services: [(serviceType: String, controlURL: String)]
}

private final class UPnPDescriptionParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var text = ""
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var urlBase: String?
    private var services: [(serviceType: String, controlURL: String)] = []

    static func parse(_ data: Data) -> UPnPServiceDescription {
        let delegate = UPnPDescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return UPnPServiceDescription(urlBase: delegate.urlBase, services: delegate.services)
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
    case invalidResponse(String)
    case protocolFailure(String)
    case allProtocolsFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Router mapping is disabled"
        case .socket(let message), .timeout(let message), .invalidResponse(let message), .protocolFailure(let message), .allProtocolsFailed(let message):
            return message
        }
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
