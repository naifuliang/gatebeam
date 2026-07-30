import Foundation
import Darwin

final class MockHTTPClient: HTTPRequesting {
    var requests: [HTTPRequest] = []
    var responses: [HTTPResponse]

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw TestFailure("No mock response left for \(request.method) \(request.url)")
        }
        return responses.removeFirst()
    }
}

final class ThrowingHTTPClient: HTTPRequesting {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
        throw error
    }
}

struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func response(
    _ json: String,
    status: Int = 200,
    headers: [AnyHashable: Any] = [:]
) -> HTTPResponse {
    HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers)
}

func pcpDeletionResponse(for request: Data, resultCode: UInt8 = 0) -> Data {
    var result = request
    result[1] = 0x81
    result[3] = resultCode
    return result
}

func natPMPDeletionResponse(for request: Data, resultCode: UInt16 = 0) -> Data {
    var result = Data(repeating: 0, count: 16)
    result[1] = 130
    result[2] = UInt8((resultCode >> 8) & 0xff)
    result[3] = UInt8(resultCode & 0xff)
    result[8] = request[4]
    result[9] = request[5]
    result[10] = request[6]
    result[11] = request[7]
    return result
}

func pcpAnnounceResponse(
    resultCode: UInt8 = 0,
    epoch: UInt32 = 0
) -> Data {
    var result = Data(repeating: 0, count: 24)
    result[0] = 2
    result[1] = 0x80
    result[3] = resultCode
    result[8] = UInt8((epoch >> 24) & 0xff)
    result[9] = UInt8((epoch >> 16) & 0xff)
    result[10] = UInt8((epoch >> 8) & 0xff)
    result[11] = UInt8(epoch & 0xff)
    return result
}

func pcpMappingResponse(
    for request: Data,
    resultCode: UInt8 = 0,
    epoch: UInt32 = 0
) -> Data {
    var result = request
    result[1] = 0x81
    result[3] = resultCode
    result.replaceSubrange(8..<24, with: Data(repeating: 0, count: 16))
    result[8] = UInt8((epoch >> 24) & 0xff)
    result[9] = UInt8((epoch >> 16) & 0xff)
    result[10] = UInt8((epoch >> 8) & 0xff)
    result[11] = UInt8(epoch & 0xff)
    if request.count >= 60,
       request[4..<8].contains(where: { $0 != 0 }) {
        let clientAddress = PCPMessageCodec.addressString(
            Data(request[8..<24])
        )
        if clientAddress?.contains(":") == true,
           clientAddress?.contains(".") == false {
            result.replaceSubrange(
                44..<60,
                with: Data([
                    0x26, 0x06, 0x47, 0x00,
                    0x47, 0x00, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0x11, 0x11
                ])
            )
        } else {
            result.replaceSubrange(
                44..<60,
                with: Data([
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0xff, 0xff,
                    192, 0, 2, 53
                ])
            )
        }
    }
    return result
}

func natPMPExternalAddressResponse(
    resultCode: UInt16 = 0,
    address: [UInt8] = [203, 0, 113, 42],
    epoch: UInt32 = 0
) -> Data {
    var result = Data(repeating: 0, count: 12)
    result[1] = 128
    result[2] = UInt8((resultCode >> 8) & 0xff)
    result[3] = UInt8(resultCode & 0xff)
    result[4] = UInt8((epoch >> 24) & 0xff)
    result[5] = UInt8((epoch >> 16) & 0xff)
    result[6] = UInt8((epoch >> 8) & 0xff)
    result[7] = UInt8(epoch & 0xff)
    result.replaceSubrange(8..<12, with: address)
    return result
}

func natPMPMappingResponse(
    for request: Data,
    resultCode: UInt16 = 0,
    epoch: UInt32 = 0
) -> Data {
    var result = natPMPDeletionResponse(for: request, resultCode: resultCode)
    result[4] = UInt8((epoch >> 24) & 0xff)
    result[5] = UInt8((epoch >> 16) & 0xff)
    result[6] = UInt8((epoch >> 8) & 0xff)
    result[7] = UInt8(epoch & 0xff)
    result.replaceSubrange(12..<16, with: request[8..<12])
    return result
}

func natPMPVersionNegotiationResponse(epoch: UInt32 = 0) -> Data {
    var result = Data([0, 0, 0, 1, 0, 0, 0, 0])
    result[4] = UInt8((epoch >> 24) & 0xff)
    result[5] = UInt8((epoch >> 16) & 0xff)
    result[6] = UInt8((epoch >> 8) & 0xff)
    result[7] = UInt8(epoch & 0xff)
    return result
}

func automaticMappingConfig() -> AppConfig {
    var config = AppConfig.default
    config.mappingProtocolPreference = .automatic
    config.preferredAddressFamily = .ipv4
    config.internalPort = 5900
    config.externalPort = 45900
    config.mappingLeaseSeconds = 3600
    config.pcpNonce = Data(repeating: 13, count: 12).base64EncodedString()
    return config
}

func automaticTestRetryPolicy() -> RouterMappingRetryPolicy {
    RouterMappingRetryPolicy(
        pcpMaximumAttempts: 2,
        natPMPMaximumAttempts: 4
    )
}

func automaticUPnPService(gateway: String) -> UPnPService {
    UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(string: "http://\(gateway):5000/upnp/control/WANIPConn1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://\(gateway):5000/rootDesc.xml")!,
        deviceIdentity: "uuid:gatebeam-automatic-router"
    )
}

func encodedUPnPBindingFixture(
    service: UPnPService,
    gateway: String
) throws -> String {
    guard let descriptionURL = service.descriptionURL,
          let deviceIdentity = service.deviceIdentity else {
        throw TestFailure("UPnP binding fixture needs complete identity")
    }
    var object: [String: Any] = [
        "serviceType": service.serviceType,
        "controlURL": service.controlURL.absoluteString,
        "gatewayIdentity": gateway,
        "descriptionURL": descriptionURL.absoluteString,
        "deviceIdentity": deviceIdentity,
        "allowsCrossFamilyControl": service.allowsCrossFamilyControl
    ]
    if let ssdpBootID = service.ssdpBootID {
        object["ssdpBootID"] = ssdpBootID
    }
    if let ssdpConfigID = service.ssdpConfigID {
        object["ssdpConfigID"] = ssdpConfigID
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return "gatebeam-upnp-v1:" + data.base64EncodedString()
}

func upnpDescriptionFixture(
    service: UPnPService,
    deviceIdentity: String? = nil,
    controlURL: URL? = nil
) throws -> Data {
    guard let identity = deviceIdentity ?? service.deviceIdentity else {
        throw TestFailure("UPnP description fixture needs a UDN")
    }
    return Data("""
    <root>
      <device>
        <UDN>\(identity)</UDN>
        <serviceList>
          <service>
            <serviceType>\(service.serviceType)</serviceType>
            <controlURL>\((controlURL ?? service.controlURL).absoluteString)</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """.utf8)
}

func successfulAutomaticUPnPSOAPResponse(
    action: String,
    localAddress: String,
    internalPort: UInt16
) throws -> HTTPResponse {
    switch action {
    case "AddPortMapping":
        return response("")
    case "GetSpecificPortMappingEntry":
        return response("""
        <response>
          <NewInternalClient>\(localAddress)</NewInternalClient>
          <NewInternalPort>\(internalPort)</NewInternalPort>
          <NewEnabled>1</NewEnabled>
          <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
          <NewLeaseDuration>3600</NewLeaseDuration>
        </response>
        """)
    case "GetExternalIPAddress":
        return response("""
        <response>
          <NewExternalIPAddress>8.8.4.4</NewExternalIPAddress>
        </response>
        """)
    default:
        throw TestFailure("Unexpected automatic UPnP action \(action)")
    }
}

func upnpNoSuchEntryResponse() -> HTTPResponse {
    response("""
    <s:Envelope>
      <s:Body>
        <s:Fault>
          <detail>
            <UPnPError>
              <errorCode>714</errorCode>
              <errorDescription>NoSuchEntryInArray</errorDescription>
            </UPnPError>
          </detail>
        </s:Fault>
      </s:Body>
    </s:Envelope>
    """, status: 500)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message) }
}

func testReadUInt16(_ data: Data, at index: Int) -> UInt16 {
    (UInt16(data[index]) << 8) | UInt16(data[index + 1])
}

func testReadUInt32(_ data: Data, at index: Int) -> UInt32 {
    (UInt32(data[index]) << 24)
        | (UInt32(data[index + 1]) << 16)
        | (UInt32(data[index + 2]) << 8)
        | UInt32(data[index + 3])
}

func testCreatesMissingRecord() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-1","type":"A","name":"mac.example.com","content":"192.0.0.9","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "Mac.Example.com.",
        ipAddress: "192.0.0.9",
        token: "test-token"
    )

    try expect(result.changed, "Missing DNS record should be created")
    try expect(mock.requests.count == 2, "Create flow should make two requests")
    try expect(mock.requests[1].method == "POST", "Missing record should use POST")
    let body = try JSONSerialization.jsonObject(with: mock.requests[1].body ?? Data()) as? [String: Any]
    try expect(body?["proxied"] as? Bool == false, "VNC DNS record must be DNS-only")
    try expect(body?["name"] as? String == "mac.example.com", "Record name should be normalized")
}

func testDisablesProxyOnExistingRecord() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[{"id":"record-1","type":"A","name":"mac.example.com","content":"192.0.0.9","ttl":120,"proxied":true}]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-1","type":"A","name":"mac.example.com","content":"192.0.0.9","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "mac.example.com",
        ipAddress: "192.0.0.9",
        token: "test-token"
    )

    try expect(result.changed, "Proxied record must be changed for direct VNC")
    try expect(mock.requests[1].method == "PATCH", "Existing record should use PATCH")
}

func testCreatesMissingAAAARecord() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-v6","type":"AAAA","name":"mac.example.com","content":"2606:4700:4700::1111","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertAAAARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "mac.example.com",
        ipAddress: "2606:4700:4700::1111",
        token: "test-token"
    )

    try expect(result.changed, "Missing AAAA record should be created")
    let body = try JSONSerialization.jsonObject(with: mock.requests[1].body ?? Data()) as? [String: Any]
    try expect(body?["type"] as? String == "AAAA", "IPv6 update must write an AAAA record")
    try expect(body?["proxied"] as? Bool == false, "VNC AAAA record must be DNS-only")
}

func testRejectsNonGlobalIPv6() throws {
    let mock = MockHTTPClient(responses: [])
    let provider = CloudflareDNSProvider(http: mock)
    do {
        _ = try provider.upsertAAAARecord(
            zoneID: "0123456789abcdef0123456789abcdef",
            recordName: "mac.example.com",
            ipAddress: "fd00::10",
            token: "test-token"
        )
        throw TestFailure("A ULA must not be published as a public AAAA record")
    } catch let error as CloudflareError {
        try expect(error.localizedDescription.contains("global IPv6"), "IPv6 validation should explain the global-address requirement")
    }
    try expect(mock.requests.isEmpty, "Invalid IPv6 must fail before an API call")
}

func testClassifiesPublicIPv4WithFixedCIDRFixtures() throws {
    let publicAddresses = [
        "192.0.0.9",
        "192.0.0.10"
    ]
    let nonPublicAddresses = [
        "0.0.0.0", "0.255.255.255",
        "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
        "100.64.0.1", "100.127.255.254",
        "127.0.0.1",
        "169.254.1.1",
        "192.0.0.8", "192.0.0.170",
        "192.0.2.1", "198.51.100.1", "203.0.113.1",
        "192.88.99.1",
        "198.18.0.1", "198.19.255.254",
        "224.0.0.1", "239.255.255.255",
        "240.0.0.1", "255.255.255.255"
    ]
    let malformedAddresses = ["", "1.2.3", "1.2.3.999", "01.2.3.4", "not-an-ip"]

    for address in publicAddresses {
        try expect(PublicIPService.isPublicIPv4(address), "\(address) should be classified as public IPv4")
    }
    for address in nonPublicAddresses + malformedAddresses {
        try expect(!PublicIPService.isPublicIPv4(address), "\(address) must not be classified as public IPv4")
    }
}

func testPublicIPv4ProbeSkipsNonPublicResponses() throws {
    let mock = MockHTTPClient(responses: [
        response("0.0.0.0\n"),
        response("198.51.100.42\n"),
        response("8.8.4.4\n")
    ])
    let service = PublicIPService(http: mock)
    let address = try service.currentIPv4()

    try expect(address == "8.8.4.4", "Probe must continue until it receives a public IPv4")
    try expect(mock.requests.count == 3, "Non-public probe responses must not stop fallback")
}

func testCloudflareRejectsNonPublicAddressesBeforeRequest() throws {
    let mock = MockHTTPClient(responses: [])
    let provider = CloudflareDNSProvider(http: mock)
    let rejectedIPv4 = [
        "0.1.2.3", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1",
        "172.16.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1",
        "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255"
    ]
    let rejectedIPv6 = [
        "::", "::1", "::ffff:192.0.0.9", "64:ff9b::808:808", "100::1",
        "2001::1", "2001:db8::1", "2002:c000:0201::1", "3fff::1",
        "5f00::1", "fc00::1", "fe80::1", "ff02::1"
    ]

    for address in rejectedIPv4 {
        do {
            _ = try provider.upsertARecord(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                ipAddress: address,
                token: "test-token"
            )
            throw TestFailure("\(address) must not be published as an A record")
        } catch let error as CloudflareError {
            try expect(error.localizedDescription.contains("publicly routable"), "IPv4 rejection should explain the public routing requirement")
        }
    }
    for address in rejectedIPv6 {
        do {
            _ = try provider.upsertAAAARecord(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                ipAddress: address,
                token: "test-token"
            )
            throw TestFailure("\(address) must not be published as an AAAA record")
        } catch let error as CloudflareError {
            try expect(error.localizedDescription.contains("global IPv6"), "IPv6 rejection should explain the global-address requirement")
        }
    }
    try expect(mock.requests.isEmpty, "Rejected A and AAAA addresses must fail before any Cloudflare request")
}

func testClassifiesGlobalIPv6WithFixedCIDRFixtures() throws {
    let publicAddresses = ["2606:4700:4700::1111", "2404:6800:4003::200e"]
    let nonPublicAddresses = [
        "::", "::1", "::ffff:192.0.0.9", "64:ff9b::808:808", "100::1",
        "2001::1", "2001:db8::1", "2002:c000:0201::1", "3fff::1",
        "5f00::1", "fc00::1", "fe80::1", "ff02::1"
    ]

    for address in publicAddresses {
        try expect(PublicIPService.isGlobalIPv6(address), "\(address) should be classified as global IPv6")
    }
    for address in nonPublicAddresses {
        try expect(!PublicIPService.isGlobalIPv6(address), "\(address) must not be classified as global IPv6")
    }
}

func testDualStackPreference() throws {
    try expect(AddressFamilyPreference.dualStack.usesIPv4, "Dual stack should enable IPv4")
    try expect(AddressFamilyPreference.dualStack.usesIPv6, "Dual stack should enable IPv6")
    try expect(!AddressFamilyPreference.ipv4.usesIPv6, "IPv4-only mode should not enable IPv6")
    try expect(!AddressFamilyPreference.ipv6.usesIPv4, "IPv6-only mode should not enable IPv4")
}

func mappingFixture(
    transport: RouterMappingTransport,
    family: RouterMappingAddressFamily,
    suffix: UInt16
) -> ActiveRouterMapping {
    ActiveRouterMapping(
        transport: transport,
        addressFamily: family,
        localAddress: family == .ipv4 ? "192.0.2.\(suffix)" : "2001:db8::\(suffix)",
        gatewayAddress: family == .ipv4 ? "192.0.2.1" : "2001:db8::1",
        internalPort: 5900,
        externalPort: family == .ipv4 ? UInt16(45000 + suffix) : 5900,
        pinholeID: family == .ipv6 && transport == .upnp ? suffix : nil,
        pcpNonce: transport == .pcp ? Data(repeating: UInt8(suffix), count: 12).base64EncodedString() : nil,
        leaseExpiresAt: Date().addingTimeInterval(3600),
        renewAfter: Date().addingTimeInterval(1800)
    )
}

func trackedNATPMPFixture(
    suffix: UInt16,
    epoch: UInt32,
    now: Date,
    uptime: TimeInterval,
    boot: String
) -> ActiveRouterMapping {
    var mapping = mappingFixture(
        transport: .natpmp,
        family: .ipv4,
        suffix: suffix
    )
    mapping.routerEpoch = epoch
    mapping.routerEpochObservedAt = now
    mapping.routerEpochObservedUptime = uptime
    mapping.routerEpochBootIdentifier = boot
    mapping.leaseExpiresAt = now.addingTimeInterval(60)
    mapping.renewAfter = now.addingTimeInterval(30)
    mapping.leaseExpiresUptime = uptime + 60
    mapping.renewAfterUptime = uptime + 30
    mapping.leaseBootIdentifier = boot
    mapping.leaseAnchorWallTime = now
    mapping.leaseRemainingAtAnchor = 60
    mapping.renewRemainingAtAnchor = 30
    return mapping
}

func testRemovalReportPreservesEveryProtocolAndFamilyResult() throws {
    struct InjectedRemovalFailure: Error, LocalizedError {
        let errorDescription: String? = "injected delete failure"
    }

    let mappings = [
        mappingFixture(transport: .pcp, family: .ipv4, suffix: 10),
        mappingFixture(transport: .natpmp, family: .ipv4, suffix: 11),
        mappingFixture(transport: .upnp, family: .ipv4, suffix: 12),
        mappingFixture(transport: .pcp, family: .ipv6, suffix: 13),
        mappingFixture(transport: .upnp, family: .ipv6, suffix: 14)
    ]
    var attempted: [String] = []
    let service = RouterMappingService(removalHandler: { mapping in
        attempted.append(mapping.identifier)
        if mapping.transport == .upnp {
            throw InjectedRemovalFailure()
        }
    })

    let report = service.removeMappings(mappings)

    try expect(attempted == mappings.map(\.identifier), "Removal must attempt every tracked protocol and address family")
    try expect(report.attempts.count == mappings.count, "Removal must return one result for every attempted mapping")
    try expect(report.succeededMappings.count == 3, "Successful protocol removals must be retained in the report")
    try expect(report.remainingMappings.count == 2, "Only failed protocol removals may remain for retry")
    try expect(
        report.remainingMappings.allSatisfy { $0.transport == .upnp },
        "Partial failure state must identify the exact failed transport"
    )
    try expect(
        report.failureDescription.contains("IPv4 UPnP")
            && report.failureDescription.contains("IPv6 UPnP"),
        "Failure detail must identify both address family and protocol"
    )
}

func testProtocolMappingsProduceBoundCurrentCheckProofs() throws {
    let wallTime = Date(timeIntervalSince1970: 15_000)
    let uptime: TimeInterval = 100
    let boot = "proof-binding-boot"
    var config = automaticMappingConfig()
    config.mappingLeaseSeconds = 60

    func expectCompleteUncheckpointedProof(
        _ result: PortMappingResult,
        family: RouterMappingAddressFamily,
        transport: RouterMappingTransport,
        effectiveSource: String,
        wanAddress: String
    ) throws {
        let proof = result.currentCheckProof
        try expect(
            proof.family == family
                && proof.transport == transport
                && proof.identity.mappingIdentifier
                    == result.activeMapping.identifier
                && proof.identity.effectiveSourceAddress
                    == effectiveSource
                && proof.identity.gatewayAddress
                    == result.activeMapping.gatewayAddress
                && proof.identity.internalPort
                    == result.activeMapping.internalPort
                && proof.identity.externalPort
                    == result.activeMapping.externalPort
                && proof.boundWANAddress == wanAddress
                && proof.leaseExpiresUptime
                    == result.activeMapping.leaseExpiresUptime
                && proof.sideEffectSafetyMargin == 0.25
                && proof.sideEffectDeadlineUptime
                    == proof.leaseExpiresUptime - 0.25,
            "\(transport.displayName) proof must bind the persisted mapping identity and WAN evidence"
        )
        try expect(
            proof.mappingIdentityVerified
                && proof.boundWANEvidenceVerified
                && proof.sameBootVerified
                && proof.leaseVerified
                && proof.epochOrIGDContinuityVerified
                && !proof.checkpointed
                && !proof.isVerified,
            "\(transport.displayName) proof must require the NetworkAgent checkpoint before DDNS"
        )
    }

    config.mappingProtocolPreference = .pcp
    let pcpEffective = "10.0.0.20"
    let pcp = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(pcpEffective)
            let response = pcpMappingResponse(
                for: payload,
                epoch: 50
            )
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "PCP proof fixture response must match"
            )
            return response
        },
        nowProvider: { wallTime },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    let pcpResult = try pcp.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expectCompleteUncheckpointedProof(
        pcpResult,
        family: .ipv4,
        transport: .pcp,
        effectiveSource: pcpEffective,
        wanAddress: "192.0.2.53"
    )

    config.mappingProtocolPreference = .natpmp
    let natEffective = "10.0.0.30"
    var natActions: [String] = []
    let natPMP = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(natEffective)
            let response: Data
            if payload == Data([0, 0]) {
                natActions.append("external-address")
                response = natPMPExternalAddressResponse(
                    address: [192, 0, 2, 54],
                    epoch: 60
                )
            } else {
                natActions.append("map")
                response = natPMPMappingResponse(
                    for: payload,
                    epoch: 60
                )
            }
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "NAT-PMP proof fixture response must match"
            )
            return response
        },
        nowProvider: { wallTime },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    let natResult = try natPMP.ensureMapping(
        config: config,
        localAddress: "192.0.2.30",
        gatewayAddress: "192.0.2.1"
    )
    try expect(
        natActions == ["external-address", "map"],
        "NAT-PMP must bind one pre-MAP WAN query to the same effective source without a drifting second query"
    )
    try expectCompleteUncheckpointedProof(
        natResult,
        family: .ipv4,
        transport: .natpmp,
        effectiveSource: natEffective,
        wanAddress: "192.0.2.54"
    )

    config.mappingProtocolPreference = .upnp
    let upnpService = automaticUPnPService(
        gateway: "192.0.2.1"
    )
    var discoveryCalls = 0
    var upnpActions: [String] = []
    let upnp = RouterMappingService(
        upnpDiscoveryHandler: {
            discoveryCalls += 1
            return [upnpService]
        },
        upnpDescriptionHandler: { url in
            try expect(
                url == upnpService.descriptionURL,
                "UPnP refresh must load only the persisted IGD description URL"
            )
            return try upnpDescriptionFixture(
                service: upnpService
            )
        },
        soapRequestHandler: { url, serviceType, action, _ in
            try expect(
                url == upnpService.controlURL
                    && serviceType == upnpService.serviceType,
                "UPnP proof requests must remain bound to the original IGD service"
            )
            upnpActions.append(action)
            switch action {
            case "AddPortMapping":
                return response("")
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.40</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                  <NewLeaseDuration>60</NewLeaseDuration>
                </response>
                """)
            case "GetExternalIPAddress":
                return response(
                    "<response><NewExternalIPAddress>192.0.2.55</NewExternalIPAddress></response>"
                )
            default:
                throw TestFailure(
                    "Unexpected UPnP proof action \(action)"
                )
            }
        },
        nowProvider: { wallTime },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    let upnpResult = try upnp.ensureMapping(
        config: config,
        localAddress: "192.0.2.40",
        gatewayAddress: "192.0.2.1"
    )
    try expectCompleteUncheckpointedProof(
        upnpResult,
        family: .ipv4,
        transport: .upnp,
        effectiveSource: "192.0.2.40",
        wanAddress: "192.0.2.55"
    )
    try expect(
        upnpResult.activeMapping.pcpNonce?.isEmpty == false
            && upnpResult.currentCheckProof.identity.protocolBinding
                == upnpResult.activeMapping.pcpNonce,
        "UPnP proof must persist and bind the original IGD identity"
    )

    let discoveryCountBeforeRefresh = discoveryCalls
    let refreshed = try upnp.verifyMappingsForCurrentCheck([
        upnpResult.activeMapping
    ])
    try expect(
        discoveryCalls == discoveryCountBeforeRefresh
            && refreshed.errors.isEmpty
            && refreshed.currentCheckProofs.count == 1
            && refreshed.currentCheckProofs[0].identity
                == upnpResult.currentCheckProof.identity
            && refreshed.currentCheckProofs[0].boundWANAddress
                == "192.0.2.55",
        "UPnP current-check proof must refresh through the persisted IGD without rediscovery drift"
    )
    try expect(
        upnpActions == [
            "AddPortMapping",
            "GetSpecificPortMappingEntry",
            "GetExternalIPAddress",
            "GetSpecificPortMappingEntry",
            "GetExternalIPAddress"
        ],
        "UPnP create and refresh must verify the exact rule and WAN evidence in order"
    )
}

func testUPnPLeaseIsAlwaysRenewable() throws {
    try expect(
        RouterMappingService.renewableUPnPLeaseSeconds(requested: 0) == 60,
        "A zero requested UPnP lease must be converted to a finite renewable lease"
    )
    try expect(
        RouterMappingService.renewableUPnPLeaseSeconds(requested: 120) == 120,
        "A valid finite UPnP lease must be preserved"
    )
    try expect(
        RouterMappingService.renewableUPnPLeaseSeconds(requested: UInt32.max) == 86_400,
        "UPnP leases must stay within the scheduled renewal horizon"
    )
}

func testUPnPRemovalStaysBoundToOriginalRouter() throws {
    let originalGateway = "192.0.2.1"
    let currentGateway = "192.0.2.254"
    let originalDescriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let currentDescriptionURL = URL(string: "http://192.0.2.254:5000/rootDesc.xml")!
    let originalControlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let currentControlURL = URL(string: "http://192.0.2.254:5000/upnp/control/WANIPConn1")!
    let originalDeviceIdentity = "uuid:gatebeam-router-a"
    let currentDeviceIdentity = "uuid:gatebeam-router-b"
    let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let originalService = UPnPService(
        serviceType: serviceType,
        controlURL: originalControlURL,
        gatewayIdentity: originalGateway,
        descriptionURL: originalDescriptionURL,
        deviceIdentity: originalDeviceIdentity
    )
    let currentService = UPnPService(
        serviceType: serviceType,
        controlURL: currentControlURL,
        gatewayIdentity: currentGateway,
        descriptionURL: currentDescriptionURL,
        deviceIdentity: currentDeviceIdentity
    )
    func descriptionXML(deviceIdentity: String, controlURL: URL) -> Data {
        Data("""
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
    }

    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.internalPort = 5900
    config.externalPort = 45900
    config.mappingLeaseSeconds = 3600

    var creationDiscoveryCount = 0
    let creator = RouterMappingService(
        upnpDiscoveryHandler: {
            creationDiscoveryCount += 1
            return [originalService, currentService]
        },
        soapRequestHandler: { controlURL, _, action, _ in
            try expect(controlURL == originalControlURL, "Creation must choose the IGD bound to the supplied gateway")
            switch action {
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                  <NewLeaseDuration>3600</NewLeaseDuration>
                </response>
                """)
            case "GetExternalIPAddress":
                return response("<response><NewExternalIPAddress>192.0.0.9</NewExternalIPAddress></response>")
            default:
                return response("")
            }
        }
    )
    let tracked = try creator.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: originalGateway
    ).activeMapping
    try expect(creationDiscoveryCount == 1, "Creation should perform exactly one fixed IGD discovery")
    try expect(tracked.gatewayAddress == originalGateway, "Tracked mapping must retain the original gateway")
    try expect(tracked.pcpNonce?.hasPrefix("gatebeam-upnp-v1:") == true, "Tracked UPnP mapping must persist bound IGD metadata")

    var deletionDiscoveryCount = 0
    var verifiedDescriptionURLs: [URL] = []
    var deletionURLs: [URL] = []
    let remover = RouterMappingService(
        upnpDiscoveryHandler: {
            deletionDiscoveryCount += 1
            return [currentService]
        },
        upnpDescriptionHandler: { descriptionURL in
            verifiedDescriptionURLs.append(descriptionURL)
            try expect(descriptionURL == originalDescriptionURL, "Removal must verify only the original IGD description")
            return descriptionXML(
                deviceIdentity: originalDeviceIdentity,
                controlURL: originalControlURL
            )
        },
        soapRequestHandler: { controlURL, _, action, _ in
            deletionURLs.append(controlURL)
            switch action {
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                </response>
                """)
            case "DeletePortMapping":
                return response("")
            default:
                throw TestFailure("Unexpected IPv4 removal action \(action)")
            }
        }
    )
    let success = remover.removeMappings([tracked])
    try expect(success.allSucceeded, "The original reachable IGD should remove its tracked mapping")
    try expect(deletionDiscoveryCount == 0, "Removal must never rediscover the current network IGD")
    try expect(verifiedDescriptionURLs == [originalDescriptionURL], "Removal must verify the original IGD identity once")
    try expect(
        deletionURLs == [originalControlURL, originalControlURL],
        "Removal must query and delete only on the exact original control URL"
    )
    try expect(!deletionURLs.contains(currentControlURL), "Removal must never touch the new router")

    var idempotentIdentityChecks = 0
    var idempotentDeleteCalls = 0
    let alreadyAbsent = RouterMappingService(
        upnpDescriptionHandler: { descriptionURL in
            idempotentIdentityChecks += 1
            try expect(descriptionURL == originalDescriptionURL, "Idempotent removal must still verify the original IGD")
            return descriptionXML(
                deviceIdentity: originalDeviceIdentity,
                controlURL: originalControlURL
            )
        },
        soapRequestHandler: { controlURL, _, action, _ in
            idempotentDeleteCalls += 1
            try expect(controlURL == originalControlURL, "Idempotent removal must stay on the original control URL")
            try expect(
                action == "GetSpecificPortMappingEntry",
                "Idempotent removal must query the exact rule before deciding it is absent"
            )
            return response("""
            <s:Envelope>
              <s:Body>
                <s:Fault>
                  <detail>
                    <UPnPError>
                      <errorCode>714</errorCode>
                      <errorDescription>NoSuchEntryInArray</errorDescription>
                    </UPnPError>
                  </detail>
                </s:Fault>
              </s:Body>
            </s:Envelope>
            """, status: 500)
        }
    )
    let alreadyAbsentReport = alreadyAbsent.removeMappings([tracked])
    try expect(alreadyAbsentReport.allSucceeded, "UPnP 714 must be treated as an idempotent delete success")
    try expect(idempotentIdentityChecks == 1, "Idempotent delete must verify the original IGD exactly once")
    try expect(idempotentDeleteCalls == 1, "Idempotent cleanup must issue exactly one bound query")

    var failedDeletionDiscoveryCount = 0
    var unreachableSOAPCalls = 0
    let unreachableOriginal = RouterMappingService(
        upnpDiscoveryHandler: {
            failedDeletionDiscoveryCount += 1
            return [currentService]
        },
        upnpDescriptionHandler: { descriptionURL in
            try expect(descriptionURL == originalDescriptionURL, "Failure must stay bound to the original description URL")
            throw TestFailure("original IGD unreachable")
        },
        soapRequestHandler: { _, _, _, _ in
            unreachableSOAPCalls += 1
            return response("")
        }
    )
    let failure = unreachableOriginal.removeMappings([tracked])
    try expect(!failure.allSucceeded, "An unreachable original IGD must report deletion failure")
    try expect(failure.remainingMappings == [tracked], "Failed deletion must preserve the exact mapping for retry")
    try expect(failedDeletionDiscoveryCount == 0, "Failure must not fall back to discovering the new router")
    try expect(unreachableSOAPCalls == 0, "An unreachable original IGD must fail before any delete request")

    var changedIdentitySOAPCalls = 0
    let replacedAtSameEndpoint = RouterMappingService(
        upnpDiscoveryHandler: { [currentService] },
        upnpDescriptionHandler: { descriptionURL in
            try expect(descriptionURL == originalDescriptionURL, "Identity check must stay on the tracked endpoint")
            return descriptionXML(
                deviceIdentity: currentDeviceIdentity,
                controlURL: originalControlURL
            )
        },
        soapRequestHandler: { _, _, _, _ in
            changedIdentitySOAPCalls += 1
            return response("")
        }
    )
    let identityMismatch = replacedAtSameEndpoint.removeMappings([tracked])
    try expect(!identityMismatch.allSucceeded, "A different IGD at the same address must not inherit deletion authority")
    try expect(identityMismatch.remainingMappings == [tracked], "Identity mismatch must retain the mapping for retry")
    try expect(changedIdentitySOAPCalls == 0, "Identity mismatch must block DeletePortMapping")
}

func testUPnPVerificationFailurePreservesRecoveryIdentity() throws {
    let gateway = "192.0.2.1"
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: controlURL,
        gatewayIdentity: gateway,
        descriptionURL: descriptionURL,
        deviceIdentity: "uuid:gatebeam-verification-router"
    )
    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv4
    config.internalPort = 5900
    config.externalPort = 45900
    config.mappingLeaseSeconds = 3600

    var actions: [String] = []
    let mapper = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        upnpDescriptionHandler: { requestedURL in
            try expect(requestedURL == descriptionURL, "Cleanup must verify the original IGD")
            return Data("""
            <root>
              <device>
                <UDN>uuid:gatebeam-verification-router</UDN>
                <serviceList>
                  <service>
                    <serviceType>\(service.serviceType)</serviceType>
                    <controlURL>\(controlURL.absoluteString)</controlURL>
                  </service>
                </serviceList>
              </device>
            </root>
            """.utf8)
        },
        soapRequestHandler: { requestURL, _, action, _ in
            try expect(requestURL == controlURL, "Every UPnP request must stay on the selected IGD")
            actions.append(action)
            switch action {
            case "AddPortMapping":
                return response("")
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.99</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                </response>
                """)
            case "DeletePortMapping":
                throw TestFailure("A foreign mapping must never be deleted")
            default:
                throw TestFailure("Unexpected UPnP action \(action)")
            }
        }
    )

    do {
        _ = try mapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: gateway
        )
        throw TestFailure("Verification failure must not report a successful mapping")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            actions == [
                "AddPortMapping",
                "GetSpecificPortMappingEntry",
                "GetSpecificPortMappingEntry"
            ],
            "A failed post-add verification must re-query and stop before deleting a foreign rule"
        )
        try expect(recovery.mapping.transport == .upnp, "Recovery identity must retain the UPnP transport")
        try expect(recovery.mapping.addressFamily == .ipv4, "Recovery identity must retain the IPv4 family")
        try expect(recovery.mapping.gatewayAddress == gateway, "Recovery identity must retain the original gateway")
        try expect(recovery.mapping.internalPort == 5900, "Recovery identity must retain the internal port")
        try expect(recovery.mapping.externalPort == 45900, "Recovery identity must retain the external port")
        try expect(
            recovery.mapping.pcpNonce?.hasPrefix("gatebeam-upnp-v1:") == true,
            "Recovery identity must retain the bound IGD metadata required for exact deletion"
        )
        try expect(
            recovery.cleanupDescription.contains("Refusing to delete"),
            "Recovery error must explain why the foreign rule was preserved"
        )
    }
}

func testUPnPIPv6RepeatedDeleteIsIdempotentOnlyForFirewallService() throws {
    let gateway = "192.0.2.1"
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!
    let serviceType = "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1"
    let deviceIdentity = "uuid:gatebeam-ipv6-firewall"
    let service = UPnPService(
        serviceType: serviceType,
        controlURL: controlURL,
        gatewayIdentity: gateway,
        descriptionURL: descriptionURL,
        deviceIdentity: deviceIdentity,
        ssdpBootID: "101",
        ssdpConfigID: "7"
    )
    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv6
    config.internalPort = 5900
    config.mappingLeaseSeconds = 3600

    let creator = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "AddPinhole":
                return response("<response><UniqueID>77</UniqueID></response>")
            default:
                throw TestFailure("Unexpected IPv6 UPnP creation action \(action)")
            }
        }
    )
    let tracked = try creator.ensureIPv6Pinhole(
        config: config,
        localAddress: "2606:4700:4700::20",
        gatewayAddress: gateway
    ).activeMapping

    var identityChecks = 0
    var deleteCalls = 0
    let remover = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        upnpDescriptionHandler: { requestedURL in
            identityChecks += 1
            try expect(requestedURL == descriptionURL, "Repeated deletion must verify the original IPv6 IGD")
            return Data("""
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
        },
        soapRequestHandler: { requestedURL, requestedService, action, _ in
            deleteCalls += 1
            try expect(requestedURL == controlURL, "Repeated deletion must stay on the original control URL")
            try expect(requestedService == serviceType, "Repeated deletion must retain the IPv6 firewall service")
            try expect(action == "DeletePinhole", "Repeated deletion must use DeletePinhole")
            return response("""
            <s:Envelope>
              <s:Body>
                <s:Fault>
                  <detail>
                    <UPnPError>
                      <errorCode>704</errorCode>
                      <errorDescription>NoSuchEntry</errorDescription>
                    </UPnPError>
                  </detail>
                </s:Fault>
              </s:Body>
            </s:Envelope>
            """, status: 500)
        }
    )
    try expect(remover.removeMappings([tracked]).allSucceeded, "First IPv6 704 delete must be idempotent")
    try expect(remover.removeMappings([tracked]).allSucceeded, "Restarted IPv6 704 delete must remain idempotent")
    try expect(identityChecks == 2, "Each repeated delete must independently verify the original IGD")
    try expect(deleteCalls == 2, "Each repeated cleanup must issue exactly one DeletePinhole")

    let unrelatedIPv4Fault = RouterMappingError.upnpFault(
        action: "DeletePortMapping",
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        statusCode: 500,
        errorCode: 704,
        description: "NoSuchEntry"
    )
    try expect(
        !unrelatedIPv4Fault.isIdempotentIPv4UPnPDeletionMiss,
        "IPv4 DeletePortMapping must not treat unrelated 704 as success"
    )
    let wrongServiceFault = RouterMappingError.upnpFault(
        action: "DeletePinhole",
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        statusCode: 500,
        errorCode: 704,
        description: "NoSuchEntry"
    )
    try expect(
        !wrongServiceFault.isIdempotentIPv6UPnPDeletionMiss,
        "DeletePinhole 704 must not be accepted for a non-firewall service"
    )
}

func testAutomaticMappingPreservesRecoveryIdentity() throws {
    let mapping = ActiveRouterMapping(
        transport: .upnp,
        addressFamily: .ipv4,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1",
        internalPort: 5900,
        externalPort: 45900,
        pinholeID: nil,
        pcpNonce: "gatebeam-upnp-v1:test-binding",
        leaseExpiresAt: Date().addingTimeInterval(3600),
        renewAfter: Date().addingTimeInterval(1800)
    )
    let recovery = RouterMappingRecoveryRequiredError(
        mapping: mapping,
        operationDescription: "UPnP verification failed",
        cleanupDescription: "UPnP delete failed"
    )
    var laterProtocolAttempted = false

    do {
        _ = try RouterMappingService.firstSuccessfulAutomaticMapping([
            ("PCP", { throw TestFailure("PCP unavailable") }),
            ("UPnP", { throw recovery }),
            ("later protocol", {
                laterProtocolAttempted = true
                throw TestFailure("must not run")
            })
        ])
        throw TestFailure("Automatic mapping must propagate a recovery-required error")
    } catch let propagated as RouterMappingRecoveryRequiredError {
        try expect(propagated.mapping.identifier == mapping.identifier, "Automatic mode must retain the full mapping identity")
        try expect(propagated.cleanupDescription == recovery.cleanupDescription, "Automatic mode must retain the cleanup failure")
        try expect(!laterProtocolAttempted, "No protocol may run after an unclean created mapping is reported")
    }
}

func testAutomaticFallsBackToUPnPWhenUDPProtocolsDoNotRespond() throws {
    let config = automaticMappingConfig()
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let service = automaticUPnPService(gateway: gateway)
    var udpRequests: [Data] = []
    var udpTimeouts: [TimeInterval] = []
    var upnpActions: [String] = []

    let mapper = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            upnpActions.append(action)
            return try successfulAutomaticUPnPSOAPResponse(
                action: action,
                localAddress: localAddress,
                internalPort: config.internalPort
            )
        },
        udpRequestHandler: { request, _, _, timeout in
            udpRequests.append(request)
            udpTimeouts.append(timeout)
            throw RouterMappingError.uncertainAfterSend("Injected unsupported UDP protocol")
        },
        retryRandomizationProvider: { 0 },
        retryPolicy: automaticTestRetryPolicy()
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: localAddress,
        gatewayAddress: gateway
    )

    try expect(result.activeMapping.transport == .upnp, "UPnP-only router must succeed in Auto")
    try expect(
        udpRequests.filter { $0.first == 2 && $0.count == 24 }.count == 3,
        "PCP capability probe must make only three short ANNOUNCE attempts"
    )
    try expect(
        udpRequests.filter { $0 == Data([0, 0]) }.count == 3,
        "NAT-PMP capability probe must make only three short External Address attempts"
    )
    try expect(
        udpRequests.allSatisfy { $0.count == 24 || $0 == Data([0, 0]) },
        "Unsupported UDP probes must never send a MAP request"
    )
    try expect(
        udpTimeouts == [0.25, 0.5, 1, 0.25, 0.5, 1],
        "Auto capability probing must be bounded to 1.75 seconds per UDP protocol"
    )
    try expect(
        upnpActions == [
            "AddPortMapping",
            "GetSpecificPortMappingEntry",
            "GetExternalIPAddress"
        ],
        "UPnP fallback must create and verify the mapping"
    )
}

func testAutomaticUsesNATPMPOnlyAfterExternalAddressProbe() throws {
    let config = automaticMappingConfig()
    var actions: [String] = []
    var upnpAttempted = false
    let mapper = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpAttempted = true
            return []
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                actions.append("pcp-announce")
                return pcpAnnounceResponse(resultCode: 4)
            }
            if request == Data([0, 0]) {
                actions.append("natpmp-external-address")
                return natPMPExternalAddressResponse(
                    address: [192, 0, 2, 53]
                )
            }
            actions.append("natpmp-map")
            return natPMPMappingResponse(for: request)
        }
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )

    try expect(result.activeMapping.transport == .natpmp, "NAT-PMP-only router must succeed")
    try expect(
        actions == ["pcp-announce", "natpmp-external-address", "natpmp-map"],
        "NAT-PMP MAP must be sent only after a successful External Address probe"
    )
    try expect(
        result.routerExternalAddress == "192.0.2.53",
        "Probe address must be reused"
    )
    try expect(!upnpAttempted, "UPnP must not run after a verified NAT-PMP mapping")
}

func testAutomaticRecognizesNATPMPVersionNegotiationImmediately() throws {
    let config = automaticMappingConfig()
    var actions: [String] = []
    var timeouts: [TimeInterval] = []
    let mapper = RouterMappingService(
        udpRequestHandler: { request, _, _, timeout in
            timeouts.append(timeout)
            if request.first == 2 {
                actions.append("pcp-version-negotiation")
                return natPMPVersionNegotiationResponse(epoch: 40)
            }
            if request == Data([0, 0]) {
                actions.append("natpmp-external-address")
                return natPMPExternalAddressResponse(
                    address: [192, 0, 2, 54],
                    epoch: 40
                )
            }
            actions.append("natpmp-map")
            return natPMPMappingResponse(for: request, epoch: 40)
        },
        retryRandomizationProvider: { 0 }
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(
        result.activeMapping.transport == .natpmp,
        "NAT-PMP version negotiation must switch directly to NAT-PMP"
    )
    try expect(
        actions == [
            "pcp-version-negotiation",
            "natpmp-external-address",
            "natpmp-map"
        ],
        "A conclusive version response must stop PCP retries immediately"
    )
    try expect(
        timeouts == [0.25, 0.25, 0.25],
        "Version negotiation must consume only the first PCP capability attempt"
    )
}

func testAutomaticUsesPCPOnlyAfterAnnounceProbe() throws {
    let config = automaticMappingConfig()
    var actions: [String] = []
    var upnpAttempted = false
    let mapper = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpAttempted = true
            return []
        },
        udpRequestHandler: { request, _, _, _ in
            if request.count == 24 {
                actions.append("pcp-announce")
                return pcpAnnounceResponse()
            }
            actions.append("pcp-map")
            return pcpMappingResponse(for: request)
        }
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )

    try expect(result.activeMapping.transport == .pcp, "PCP-only router must succeed")
    try expect(
        result.activeMapping.routerExternalAddress
            == result.routerExternalAddress,
        "PCP MAP must persist its verified router external address with the lease"
    )
    try expect(
        actions == ["pcp-announce", "pcp-map"],
        "PCP MAP must be sent only after a successful ANNOUNCE probe"
    )
    try expect(!upnpAttempted, "No fallback may run after a verified PCP mapping")
}

func testAutomaticRetransmitsAfterSingleProbePacketLoss() throws {
    let config = automaticMappingConfig()
    var actions: [String] = []
    var timeouts: [TimeInterval] = []
    let mapper = RouterMappingService(
        udpRequestHandler: { request, _, _, timeout in
            timeouts.append(timeout)
            if request.count == 24 {
                actions.append("pcp-announce")
                if actions.count == 1 {
                    throw RouterMappingError.uncertainAfterSend(
                        "Injected first-packet loss"
                    )
                }
                return pcpAnnounceResponse()
            }
            actions.append("pcp-map")
            return pcpMappingResponse(for: request)
        },
        retryRandomizationProvider: { 0 },
        retryPolicy: automaticTestRetryPolicy()
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )

    try expect(result.activeMapping.transport == .pcp, "Single packet loss must recover")
    try expect(
        actions == ["pcp-announce", "pcp-announce", "pcp-map"],
        "The same harmless ANNOUNCE probe must be retried before MAP"
    )
    try expect(
        timeouts == [0.25, 0.5, 3],
        "Auto ANNOUNCE must use its short budget while explicit MAP keeps PCP timing"
    )
}

func testAutomaticReportsAllProtocolsUnsupportedWithoutSendingMAP() throws {
    let config = automaticMappingConfig()
    var udpRequests: [Data] = []
    var upnpDiscoveryCount = 0
    let mapper = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpDiscoveryCount += 1
            throw RouterMappingError.protocolFailure("Injected UPnP unsupported")
        },
        udpRequestHandler: { request, _, _, _ in
            udpRequests.append(request)
            if request.first == 2 {
                return pcpAnnounceResponse(resultCode: 4)
            }
            return natPMPExternalAddressResponse(resultCode: 5)
        }
    )

    do {
        _ = try mapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("All unsupported protocols must fail")
    } catch let error as RouterMappingError {
        guard case .allProtocolsFailed(let detail) = error else {
            throw TestFailure("Expected aggregate Auto failure, got \(error)")
        }
        try expect(
            detail.contains("PCP") && detail.contains("NAT-PMP") && detail.contains("UPnP"),
            "Aggregate failure must identify all attempted protocols"
        )
    }
    try expect(
        udpRequests.allSatisfy { $0.count == 24 || $0 == Data([0, 0]) },
        "Conclusive unsupported responses must never lead to MAP"
    )
    try expect(upnpDiscoveryCount == 1, "UPnP must be the final fallback")
}

func testAutomaticStopsFallbackOnlyAfterConfirmedProtocolMAPIsUncertain() throws {
    let config = automaticMappingConfig()

    var pcpActions: [String] = []
    var pcpMapRequests: [Data] = []
    var pcpUPnPAttempted = false
    let uncertainPCP = RouterMappingService(
        upnpDiscoveryHandler: {
            pcpUPnPAttempted = true
            return []
        },
        udpRequestHandler: { request, _, _, _ in
            if request.count == 24 {
                pcpActions.append("pcp-announce")
                return pcpAnnounceResponse()
            }
            pcpActions.append("pcp-map")
            pcpMapRequests.append(request)
            throw RouterMappingError.uncertainAfterSend("Injected PCP MAP response loss")
        },
        retryPolicy: automaticTestRetryPolicy()
    )
    do {
        _ = try uncertainPCP.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Confirmed PCP MAP response loss must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            pcpActions == ["pcp-announce", "pcp-map", "pcp-map"],
            "PCP MAP must exhaust its bounded retransmissions with the same transaction"
        )
        try expect(
            pcpMapRequests.count == 2
                && pcpMapRequests.dropFirst().allSatisfy { $0 == pcpMapRequests[0] },
            "Every PCP retransmission must preserve the Mapping Nonce and exact request"
        )
        try expect(recovery.mapping.transport == .pcp, "Recovery must retain PCP identity")
        try expect(recovery.mapping.pcpNonce == config.pcpNonce, "Recovery must retain PCP nonce")
        try expect(!pcpUPnPAttempted, "No fallback may run after uncertain PCP MAP")
    }

    var natPMPActions: [String] = []
    var natPMPMapRequests: [Data] = []
    var natPMPUPnPAttempted = false
    let uncertainNATPMP = RouterMappingService(
        upnpDiscoveryHandler: {
            natPMPUPnPAttempted = true
            return []
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                natPMPActions.append("pcp-unsupported")
                return pcpAnnounceResponse(resultCode: 4)
            }
            if request == Data([0, 0]) {
                natPMPActions.append("natpmp-probe")
                return natPMPExternalAddressResponse()
            }
            natPMPActions.append("natpmp-map")
            natPMPMapRequests.append(request)
            throw RouterMappingError.uncertainAfterSend(
                "Injected NAT-PMP MAP response loss"
            )
        },
        retryPolicy: automaticTestRetryPolicy()
    )
    do {
        _ = try uncertainNATPMP.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Confirmed NAT-PMP MAP response loss must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            natPMPActions == [
                "pcp-unsupported",
                "natpmp-probe",
                "natpmp-map",
                "natpmp-map",
                "natpmp-map",
                "natpmp-map"
            ],
            "NAT-PMP MAP must exhaust its bounded retransmissions"
        )
        try expect(
            natPMPMapRequests.count == 4
                && natPMPMapRequests.dropFirst().allSatisfy {
                    $0 == natPMPMapRequests[0]
                },
            "Every NAT-PMP retransmission must preserve the exact idempotent request"
        )
        try expect(
            recovery.mapping.transport == .natpmp,
            "Recovery must retain NAT-PMP identity"
        )
        try expect(!natPMPUPnPAttempted, "No fallback may run after uncertain NAT-PMP MAP")
    }

    var cancellationActions: [String] = []
    var cancellationFallbackAttempted = false
    let cancelledAfterPCPMAP = RouterMappingService(
        upnpDiscoveryHandler: {
            cancellationFallbackAttempted = true
            return []
        },
        udpRequestHandler: { request, _, _, _ in
            if request.count == 24 {
                cancellationActions.append("pcp-announce")
                return pcpAnnounceResponse()
            }
            cancellationActions.append("pcp-map-cancelled")
            throw RouterMappingError.cancelledAfterSend
        },
        retryPolicy: automaticTestRetryPolicy()
    )
    do {
        _ = try cancelledAfterPCPMAP.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Cancellation after PCP MAP must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            cancellationActions == ["pcp-announce", "pcp-map-cancelled"],
            "Cancellation after send must stop without another MAP"
        )
        try expect(
            recovery.mapping.transport == .pcp,
            "Cancellation after send must retain PCP recovery identity"
        )
        try expect(
            !cancellationFallbackAttempted,
            "Cancellation after MAP must never trigger fallback"
        )
    }
}

func testAutomaticCancellationStopsRetriesAndFallback() throws {
    let config = automaticMappingConfig()
    var cancelled = false
    var udpCallCount = 0
    var upnpAttempted = false
    let mapper = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpAttempted = true
            return []
        },
        udpRequestHandler: { _, _, _, _ in
            udpCallCount += 1
            cancelled = true
            throw RouterMappingError.uncertainAfterSend("Injected wait cancellation")
        },
        cancellationHandler: { cancelled },
        retryPolicy: automaticTestRetryPolicy()
    )

    do {
        _ = try mapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Cancellation must stop automatic mapping")
    } catch RouterMappingError.cancelled {
        try expect(udpCallCount == 1, "Cancellation must stop before retransmission")
        try expect(!upnpAttempted, "Cancellation must not trigger another protocol")
    }
}

func testAutomaticFallsBackWhenTransportNeverSentMAP() throws {
    let config = automaticMappingConfig()
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let service = automaticUPnPService(gateway: gateway)

    var transactions: [String] = []
    let sendFailure = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            try successfulAutomaticUPnPSOAPResponse(
                action: action,
                localAddress: localAddress,
                internalPort: config.internalPort
            )
        },
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(sourceAddressHint ?? "192.0.2.20")
            if payload.first == 2, payload.count == 24 {
                transactions.append("pcp-probe")
                let response = pcpAnnounceResponse()
                let accepted = try acceptsResponse(response)
                try expect(accepted, "PCP probe response must match")
                return response
            }
            if payload.first == 2 {
                transactions.append("pcp-map-send-failed")
            } else {
                transactions.append("natpmp-send-failed")
            }
            throw RouterMappingUDPError(
                underlying: .socket("Injected send() failure"),
                requestMayHaveReachedRouter: false
            )
        },
        retryPolicy: automaticTestRetryPolicy()
    )
    let result = try sendFailure.ensureMapping(
        config: config,
        localAddress: localAddress,
        gatewayAddress: gateway
    )
    try expect(result.activeMapping.transport == .upnp, "Unsent MAP must allow fallback")
    try expect(
        transactions == [
            "pcp-probe",
            "pcp-map-send-failed",
            "natpmp-send-failed"
        ],
        "A confirmed protocol with an unsent MAP must continue through safe fallbacks"
    )

    var unsafeFallbackAttempted = false
    let mayHaveReachedRouter = RouterMappingService(
        upnpDiscoveryHandler: {
            unsafeFallbackAttempted = true
            return [service]
        },
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(
                sourceAddressHint ?? "192.0.2.20"
            )
            if payload.first == 2, payload.count == 24 {
                let response = pcpAnnounceResponse()
                let accepted = try acceptsResponse(response)
                try expect(accepted, "PCP ANNOUNCE must confirm support")
                return response
            }
            throw RouterMappingUDPError(
                underlying: .timeout("Injected MAP response loss"),
                requestMayHaveReachedRouter: true
            )
        },
        retryPolicy: automaticTestRetryPolicy()
    )
    do {
        _ = try mayHaveReachedRouter.ensureMapping(
            config: config,
            localAddress: localAddress,
            gatewayAddress: gateway
        )
        throw TestFailure("A MAP that may have reached the router must be uncertain")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            recovery.mapping.transport == .pcp,
            "Transport evidence must preserve PCP recovery identity"
        )
        try expect(
            !unsafeFallbackAttempted,
            "Transport evidence that MAP may have arrived must block fallback"
        )
    }
}

func testProductionSocketStagesPreserveUnsentEvidence() throws {
    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .pcp
    let receiverFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard receiverFD >= 0 else {
        throw TestFailure("Could not create the loopback UDP receiver")
    }
    defer { _ = Darwin.close(receiverFD) }
    var receiver = sockaddr_in()
    receiver.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    receiver.sin_family = sa_family_t(AF_INET)
    receiver.sin_port = 0
    receiver.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindStatus = withUnsafePointer(to: &receiver) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                receiverFD,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bindStatus == 0 else {
        throw TestFailure("Could not bind the loopback UDP receiver")
    }
    var receiverLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameStatus = withUnsafeMutablePointer(to: &receiver) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(receiverFD, $0, &receiverLength)
        }
    }
    guard nameStatus == 0 else {
        throw TestFailure("Could not read the loopback UDP receiver port")
    }
    let receiverPort = UInt16(bigEndian: receiver.sin_port)

    func expectUnsent(
        _ label: String,
        operations: RouterMappingUDPSocketOperations
    ) throws -> String {
        let mapper = RouterMappingService(
            retryRandomizationProvider: { 0 },
            retryPolicy: RouterMappingRetryPolicy(
                pcpMaximumAttempts: 2,
                natPMPMaximumAttempts: 1,
                pcpInitialRetryInterval: 0.01
            ),
            routerControlPort: receiverPort,
            socketOperations: operations
        )
        do {
            _ = try mapper.ensureMapping(
                config: config,
                localAddress: "192.0.2.20",
                gatewayAddress: "127.0.0.1"
            )
            throw TestFailure("\(label) failure must not create a mapping")
        } catch let error as RouterMappingUDPError {
            try expect(
                !error.requestMayHaveReachedRouter,
                "\(label) failure must prove no datagram reached the router"
            )
            return error.underlying.localizedDescription
        }
    }

    var socketCalls = 0
    var socketFailure = RouterMappingUDPSocketOperations.system
    socketFailure.makeSocket = { _, _, _ in
        socketCalls += 1
        errno = EMFILE
        return -1
    }
    let socketError = try expectUnsent("socket()", operations: socketFailure)
    try expect(socketCalls > 0, "The production socket factory must be exercised")
    try expect(
        socketError.contains("socket() failed"),
        "The socket() injection must fail at the production socket stage"
    )

    var connectCalls = 0
    var connectCloseCalls = 0
    var connectFailure = RouterMappingUDPSocketOperations.system
    connectFailure.connectSocket = { _, _, _ in
        connectCalls += 1
        errno = ENETUNREACH
        return -1
    }
    connectFailure.closeSocket = {
        connectCloseCalls += 1
        _ = Darwin.close($0)
    }
    let connectError = try expectUnsent("connect()", operations: connectFailure)
    try expect(
        connectCalls > 0 && connectCloseCalls == connectCalls,
        "Every production socket whose connect fails must be closed"
    )
    try expect(
        connectError.contains("connect() failed"),
        "The connect() injection must fail at the production connect stage"
    )

    var sendCalls = 0
    var sendCloseCalls = 0
    var sendFailure = RouterMappingUDPSocketOperations.system
    sendFailure.sendDatagram = { _, _, _ in
        sendCalls += 1
        errno = ENOBUFS
        return -1
    }
    sendFailure.closeSocket = {
        sendCloseCalls += 1
        _ = Darwin.close($0)
    }
    let sendError = try expectUnsent("send()", operations: sendFailure)
    try expect(
        sendError.contains("send() failed"),
        "The send() injection must fail at the production send stage; got \(sendError)"
    )
    try expect(
        sendCloseCalls > 0 && sendCalls == sendCloseCalls * 2,
        "Production send failures must exhaust the configured budget on every closed socket candidate (send=\(sendCalls), close=\(sendCloseCalls))"
    )
}

func testPCPBuilderUsesConnectedSourceAddress() throws {
    var config = automaticMappingConfig()
    config.pcpNonce = Data(repeating: 41, count: 12).base64EncodedString()

    func run(
        localAddressHint: String,
        selectedSourceAddress: String,
        family: AddressFamilyPreference
    ) throws -> PortMappingResult {
        var hints: [String?] = []
        var payloadAddresses: [String?] = []
        let mapper = RouterMappingService(
            udpTransactionHandler: {
                _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
                hints.append(sourceAddressHint)
                let payload = try payloadBuilder(selectedSourceAddress)
                payloadAddresses.append(
                    PCPMessageCodec.addressString(Data(payload[8..<24]))
                )
                let response = payload.count == 24
                    ? pcpAnnounceResponse()
                    : pcpMappingResponse(for: payload)
                let accepted = try acceptsResponse(response)
                try expect(accepted, "Built PCP response must match")
                return response
            },
            retryRandomizationProvider: { 0 },
            retryPolicy: automaticTestRetryPolicy()
        )
        config.preferredAddressFamily = family
        let result: PortMappingResult
        if family == .ipv6 {
            result = try mapper.ensureIPv6Pinhole(
                config: config,
                localAddress: localAddressHint,
                gatewayAddress: "fe80::1%en0"
            )
        } else {
            result = try mapper.ensureMapping(
                config: config,
                localAddress: localAddressHint,
                gatewayAddress: "192.0.2.1"
            )
        }
        try expect(
            hints == [localAddressHint, localAddressHint],
            "The injection layer must receive the caller's source-address hint"
        )
        try expect(
            payloadAddresses == [selectedSourceAddress, selectedSourceAddress],
            "ANNOUNCE and MAP must encode the connect-selected source address"
        )
        try expect(
            result.activeMapping.localAddress == selectedSourceAddress,
            "A successful PCP mapping must persist the effective client address"
        )
        return result
    }

    let ipv4Result = try run(
        localAddressHint: "192.0.2.20",
        selectedSourceAddress: "10.0.0.20",
        family: .ipv4
    )
    try expect(
        ipv4Result.activeMapping.transport == .pcp,
        "IPv4 PCP must use the connected source address"
    )
    let ipv6Result = try run(
        localAddressHint: "2001:db8::20",
        selectedSourceAddress: "2001:db8:1::20",
        family: .ipv6
    )
    try expect(
        ipv6Result.activeMapping.transport == .pcp,
        "IPv6 PCP must use the connected source address"
    )
}

func testPCPEffectiveIdentityPersistsThroughLifecycle() throws {
    let hint = "2001:db8::20"
    let effective = "fe80::20%en7"
    let gateway = "fe80::1%en7"
    let bootIdentifier = "boot-pcp-effective-identity"
    var wallTime = Date(timeIntervalSince1970: 20_000)
    var uptime: TimeInterval = 100
    var routerEpoch: UInt32 = 100
    var sourceHints: [String?] = []
    var selectedSources: [String] = []
    var payloadSources: [String?] = []
    var requestedLifetimes: [UInt32] = []

    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .pcp
    config.preferredAddressFamily = .ipv6
    config.mappingLeaseSeconds = 60
    let mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            sourceHints.append(sourceAddressHint)
            selectedSources.append(effective)
            let payload = try payloadBuilder(effective)
            payloadSources.append(
                PCPMessageCodec.addressString(Data(payload[8..<24]))
            )
            let response: Data
            if payload.count == 24 {
                response = pcpAnnounceResponse(epoch: routerEpoch)
            } else {
                requestedLifetimes.append(testReadUInt32(payload, at: 4))
                response = pcpMappingResponse(
                    for: payload,
                    epoch: routerEpoch
                )
            }
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "The effective-identity response must match its PCP request"
            )
            return response
        },
        nowProvider: { wallTime },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier },
        retryRandomizationProvider: { 0 }
    )

    let created = try mapper.ensureIPv6Pinhole(
        config: config,
        localAddress: hint,
        gatewayAddress: gateway
    ).activeMapping
    try expect(
        created.localAddress == effective,
        "Creation must replace the caller hint with the scoped effective address"
    )
    try expect(
        created.isCompatible(
            with: config,
            family: .ipv6,
            localAddress: hint,
            gatewayAddress: gateway
        ),
        "PCP compatibility must be anchored to its effective identity"
    )

    wallTime = wallTime.addingTimeInterval(10)
    uptime += 10
    routerEpoch += 10
    let health = try mapper.refreshMappingEpochs([created])
    try expect(
        health.invalidatedMappings.isEmpty
            && health.refreshedMappings.first?.localAddress == effective,
        "Epoch health must retain the same effective PCP identity"
    )
    guard let refreshed = health.refreshedMappings.first else {
        throw TestFailure("The healthy PCP mapping was not returned")
    }

    wallTime = wallTime.addingTimeInterval(10)
    uptime += 10
    routerEpoch += 10
    let renewed = try mapper.renewMapping(
        config: config,
        mapping: refreshed
    ).activeMapping
    try expect(
        renewed.localAddress == effective,
        "Renewal must preserve the effective PCP client address"
    )

    let removal = mapper.removeMappings([renewed])
    try expect(
        removal.allSucceeded,
        "Deletion with the persisted effective PCP identity must succeed"
    )
    try expect(
        sourceHints == [hint, effective, effective, effective],
        "Create may start from hint A, but health, renewal, and delete must all use effective B"
    )
    try expect(
        selectedSources.allSatisfy { $0 == effective },
        "Every transaction must retain the scoped effective source address"
    )
    try expect(
        payloadSources.allSatisfy { $0 == "fe80::20" },
        "Every PCP payload must encode effective B rather than hint A"
    )
    try expect(
        requestedLifetimes == [60, 60, 0],
        "The lifecycle must contain create, renew, and strict delete MAP requests"
    )

    var mapReachedResponseStage = false
    let changedRouteMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, _ in
            _ = try payloadBuilder("fe80::21%en7")
            mapReachedResponseStage = true
            throw TestFailure(
                "A changed effective identity must fail before MAP is sent"
            )
        },
        nowProvider: { wallTime },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    do {
        _ = try changedRouteMapper.renewMapping(
            config: config,
            mapping: renewed
        )
        throw TestFailure(
            "Renewal from a different effective PCP address must fail"
        )
    } catch let error as RouterMappingError {
        try expect(
            error.localizedDescription.contains(
                "effective client address changed"
            ),
            "Renewal must explain the effective PCP identity change"
        )
    }
    let changedDelete = changedRouteMapper.removeMappings([renewed])
    try expect(
        !mapReachedResponseStage
            && changedDelete.remainingMappings == [renewed],
        "Changed-route delete must send nothing and retain the tracked B identity"
    )
}

func testAddressChangeReasonAutoWANBudgetAndRenewalDeadline() throws {
    let baseline = Date(timeIntervalSince1970: 60_000)
    var mapping = mappingFixture(
        transport: .pcp,
        family: .ipv4,
        suffix: 20
    )
    mapping.localAddress = "192.0.2.20"
    mapping.gatewayAddress = "192.0.2.1"
    mapping.routerEpoch = 100
    mapping.routerEpochObservedAt = baseline
    mapping.routerEpochObservedUptime = 100
    mapping.routerEpochBootIdentifier = "boot-address-change"
    mapping.leaseBootIdentifier = "boot-address-change"
    mapping.leaseExpiresUptime = 160
    mapping.renewAfterUptime = 130

    let driftMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder("192.0.2.21")
            try expect(
                payload.count == 24,
                "Address drift health check must remain a harmless ANNOUNCE"
            )
            let response = pcpAnnounceResponse(epoch: 110)
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "Address drift ANNOUNCE response must parse"
            )
            return response
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 110 },
        bootIdentifierProvider: { "boot-address-change" }
    )
    let drift = try driftMapper.refreshMappingEpochs([mapping])
    try expect(
        drift.refreshedMappings.isEmpty
            && drift.invalidations.count == 1,
        "B to C must be reported as an invalidation"
    )
    guard case .effectiveClientAddressChanged(let replacement) =
            drift.invalidations[0].reason else {
        throw TestFailure(
            "B to C must not be merged with router Epoch state loss"
        )
    }
    try expect(
        replacement == "192.0.2.21"
            && drift.invalidations[0].mapping.localAddress
                == "192.0.2.20",
        "The invalidation must retain orphan B and report replacement C"
    )

    var natOnlyTimeouts: [TimeInterval] = []
    let natOnlyWAN = RouterMappingService(
        upnpDiscoveryHandler: {
            throw TestFailure(
                "NAT-PMP-only WAN discovery must not require UPnP"
            )
        },
        udpRequestHandler: { request, _, _, timeout in
            try expect(
                request == Data([0, 0]),
                "Auto WAN discovery must use the harmless NAT-PMP External Address request"
            )
            natOnlyTimeouts.append(timeout)
            return natPMPExternalAddressResponse(
                address: [100, 64, 1, 20],
                epoch: 120
            )
        }
    )
    let natOnlyAddress = try natOnlyWAN
        .externalIPv4AddressForAutomaticMapping(
            gatewayAddress: "192.0.2.1"
        )
    try expect(
        natOnlyAddress == "100.64.1.20"
            && natOnlyTimeouts == [0.25],
        "Auto WAN discovery must support NAT-PMP-only routers within the first short probe"
    )

    var fallbackTimeouts: [TimeInterval] = []
    let fallbackService = automaticUPnPService(
        gateway: "192.0.2.1"
    )
    let automaticWANFallback = RouterMappingService(
        upnpDiscoveryHandler: { [fallbackService] },
        soapRequestHandler: { _, _, action, _ in
            try expect(
                action == "GetExternalIPAddress",
                "Auto WAN fallback must query UPnP only after the short NAT-PMP budget"
            )
            return response(
                "<response><NewExternalIPAddress>203.0.113.42</NewExternalIPAddress></response>"
            )
        },
        udpRequestHandler: { _, _, _, timeout in
            fallbackTimeouts.append(timeout)
            throw RouterMappingError.timeout(
                "Injected NAT-PMP-only capability timeout"
            )
        }
    )
    let fallbackAddress = try automaticWANFallback
        .externalIPv4AddressForAutomaticMapping(
            gatewayAddress: "192.0.2.1"
        )
    try expect(
        fallbackAddress == "203.0.113.42"
            && fallbackTimeouts == [0.25, 0.5, 1],
        "Auto WAN must cap NAT-PMP at 1.75 seconds before UPnP fallback"
    )

    var renewalIntervals: [TimeInterval] = []
    var renewalConfig = automaticMappingConfig()
    renewalConfig.mappingProtocolPreference = .pcp
    renewalConfig.mappingLeaseSeconds = 60
    let renewalMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, intervals, _, payloadBuilder, acceptsResponse in
            renewalIntervals = intervals
            let payload = try payloadBuilder("192.0.2.20")
            let response = pcpMappingResponse(for: payload, epoch: 130)
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "Bounded renewal response must parse"
            )
            return response
        },
        nowProvider: { baseline.addingTimeInterval(30) },
        monotonicUptimeProvider: { 130 },
        bootIdentifierProvider: { "boot-address-change" },
        retryRandomizationProvider: { 0 }
    )
    _ = try renewalMapper.renewMapping(
        config: renewalConfig,
        mapping: mapping
    )
    try expect(
        renewalIntervals.reduce(0, +) <= 29.75
            && renewalIntervals == [3, 6, 12, 8.75],
        "PCP renewal retries must be clipped before the monotonic lease expiry"
    )

    var natMapping = mapping
    natMapping.transport = .natpmp
    natMapping.pcpNonce = nil
    var natRenewalIntervals: [TimeInterval] = []
    renewalConfig.mappingProtocolPreference = .natpmp
    let natRenewalMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, intervals, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder("192.0.2.20")
            if payload == Data([0, 0]) {
                return natPMPExternalAddressResponse(epoch: 130)
            }
            natRenewalIntervals = intervals
            let response = natPMPMappingResponse(for: payload, epoch: 130)
            let accepted = try acceptsResponse(response)
            try expect(
                accepted,
                "Bounded NAT-PMP renewal response must parse"
            )
            return response
        },
        nowProvider: { baseline.addingTimeInterval(30) },
        monotonicUptimeProvider: { 130 },
        bootIdentifierProvider: { "boot-address-change" }
    )
    _ = try natRenewalMapper.renewMapping(
        config: renewalConfig,
        mapping: natMapping
    )
    try expect(
        natRenewalIntervals.reduce(0, +) <= 29.75
            && natRenewalIntervals == [
                0.25, 0.5, 1, 2, 4, 8, 14
            ],
        "NAT-PMP renewal retries must be clipped before monotonic expiry"
    )
}

func testOperationTokenCancellationGapAndAbsoluteDeadline() throws {
    let config = automaticMappingConfig()
    var cancelledMapper: RouterMappingService!
    var mapPayloads = 0
    var upnpFallbacks = 0
    cancelledMapper = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpFallbacks += 1
            return []
        },
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(
                sourceAddressHint ?? "192.0.2.20"
            )
            if payload.count == 24 {
                let response = pcpAnnounceResponse()
                let accepted = try acceptsResponse(response)
                try expect(accepted, "ANNOUNCE response must parse")
                cancelledMapper.cancelCurrentOperations()
                return response
            }
            mapPayloads += 1
            return pcpMappingResponse(for: payload)
        },
        retryRandomizationProvider: { 0 }
    )
    do {
        _ = try cancelledMapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Cancellation between ANNOUNCE and MAP must abort")
    } catch RouterMappingError.cancelled {
        // Expected.
    }
    try expect(
        mapPayloads == 0 && upnpFallbacks == 0,
        "CANCEL_GAP must send no MAP and start no fallback"
    )

    let service = automaticUPnPService(gateway: "192.0.2.1")
    var cancelledUPnP: RouterMappingService!
    var soapActions: [String] = []
    cancelledUPnP = RouterMappingService(
        upnpDiscoveryHandler: {
            cancelledUPnP.cancelCurrentOperations()
            return [service]
        },
        soapRequestHandler: { _, _, action, _ in
            soapActions.append(action)
            return response("<response/>")
        }
    )
    var upnpConfig = config
    upnpConfig.mappingProtocolPreference = .upnp
    do {
        _ = try cancelledUPnP.ensureMapping(
            config: upnpConfig,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Cancelled SSDP discovery must abort UPnP")
    } catch RouterMappingError.cancelled {
        // Expected.
    }
    try expect(
        soapActions.isEmpty,
        "Cancellation after SSDP must prevent every SOAP MAP request"
    )

    var removalMapper: RouterMappingService!
    var removalCalls = 0
    removalMapper = RouterMappingService(
        removalHandler: { _ in
            removalCalls += 1
            removalMapper.cancelCurrentOperations()
        }
    )
    let removalReport = removalMapper.removeMappings([
        mappingFixture(transport: .upnp, family: .ipv4, suffix: 23),
        mappingFixture(transport: .upnp, family: .ipv4, suffix: 24)
    ])
    try expect(
        removalCalls == 1 && removalReport.remainingMappings.count == 2,
        "One remove token must stop before a second deletion after cancel"
    )

    var refreshMapper: RouterMappingService!
    var refreshCalls = 0
    refreshMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            refreshCalls += 1
            let payload = try payloadBuilder(
                sourceAddressHint ?? "192.0.2.20"
            )
            try expect(
                payload.count == 24,
                "Epoch refresh cancellation must use harmless ANNOUNCE"
            )
            let response = pcpAnnounceResponse(epoch: 20)
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Epoch ANNOUNCE response must parse")
            refreshMapper.cancelCurrentOperations()
            return response
        }
    )
    do {
        _ = try refreshMapper.refreshMappingEpochs([
            mappingFixture(
                transport: .pcp,
                family: .ipv4,
                suffix: 25
            ),
            mappingFixture(
                transport: .pcp,
                family: .ipv4,
                suffix: 26
            )
        ])
        throw TestFailure("Cancelled Epoch refresh must abort")
    } catch RouterMappingError.cancelled {
        // Expected.
    }
    try expect(
        refreshCalls == 1,
        "One refresh token must stop before probing a second mapping"
    )

    let baseline = Date(timeIntervalSince1970: 70_000)
    let boot = "absolute-renewal-deadline"
    var uptime: TimeInterval = 130
    var pcpCalls = 0
    let deadlineMapper = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            pcpCalls += 1
            uptime = 160
            throw RouterMappingError.uncertainAfterSend(
                "Injected process suspension after send"
            )
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot },
        retryRandomizationProvider: { 0 }
    )
    var pcp = mappingFixture(
        transport: .pcp,
        family: .ipv4,
        suffix: 20
    )
    pcp.leaseBootIdentifier = boot
    pcp.renewAfterUptime = 130
    pcp.leaseExpiresUptime = 160
    pcp.leaseAnchorWallTime = baseline
    pcp.leaseRemainingAtAnchor = 30
    var renewalConfig = config
    renewalConfig.mappingProtocolPreference = .pcp
    renewalConfig.pcpNonce = pcp.pcpNonce
    do {
        _ = try deadlineMapper.renewMapping(
            config: renewalConfig,
            mapping: pcp
        )
        throw TestFailure("A suspended PCP renewal must become uncertain")
    } catch is RouterMappingRecoveryRequiredError {
        // Expected: one packet may have reached the router.
    } catch {
        throw TestFailure(
            "PCP renewal must retain sent-MAP uncertainty, got "
                + "\(type(of: error)): \(error.localizedDescription)"
        )
    }
    try expect(
        pcpCalls == 1,
        "Absolute PCP deadline must prevent a retry after suspension"
    )

    uptime = 130
    var natPMPCalls = 0
    let deadlineNATPMP = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            if request == Data([0, 0]) {
                return natPMPExternalAddressResponse(
                    address: [192, 0, 2, 53]
                )
            }
            natPMPCalls += 1
            uptime = 160
            throw RouterMappingError.uncertainAfterSend(
                "Injected NAT-PMP suspension after send"
            )
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    var natPMP = mappingFixture(
        transport: .natpmp,
        family: .ipv4,
        suffix: 22
    )
    natPMP.leaseBootIdentifier = boot
    natPMP.renewAfterUptime = 130
    natPMP.leaseExpiresUptime = 160
    natPMP.leaseAnchorWallTime = baseline
    natPMP.leaseRemainingAtAnchor = 30
    renewalConfig.mappingProtocolPreference = .natpmp
    do {
        _ = try deadlineNATPMP.renewMapping(
            config: renewalConfig,
            mapping: natPMP
        )
        throw TestFailure("A suspended NAT-PMP renewal must become uncertain")
    } catch is RouterMappingRecoveryRequiredError {
        // Expected: one packet may have reached the router.
    } catch {
        throw TestFailure(
            "NAT-PMP renewal must retain sent-MAP uncertainty, got "
                + "\(type(of: error)): \(error.localizedDescription)"
        )
    }
    try expect(
        natPMPCalls == 1,
        "Absolute NAT-PMP deadline must prevent a retry after suspension"
    )

    uptime = 130
    var upnpActions: [String] = []
    let deadlineUPnP = RouterMappingService(
        upnpDescriptionHandler: { _ in
            try upnpDescriptionFixture(service: service)
        },
        soapRequestHandler: { _, _, action, _ in
            upnpActions.append(action)
            if action == "AddPortMapping" {
                uptime = 160
            }
            return response("<response/>")
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    var upnp = mappingFixture(
        transport: .upnp,
        family: .ipv4,
        suffix: 21
    )
    upnp.pcpNonce = try encodedUPnPBindingFixture(
        service: service,
        gateway: "192.0.2.1"
    )
    upnp.leaseBootIdentifier = boot
    upnp.renewAfterUptime = 130
    upnp.leaseExpiresUptime = 160
    upnp.leaseAnchorWallTime = baseline
    upnp.leaseRemainingAtAnchor = 30
    renewalConfig.mappingProtocolPreference = .upnp
    do {
        _ = try deadlineUPnP.renewMapping(
            config: renewalConfig,
            mapping: upnp
        )
        throw TestFailure("A suspended UPnP renewal must stop")
    } catch {
        // Expected.
    }
    try expect(
        upnpActions == ["AddPortMapping"],
        "Absolute UPnP deadline must prevent verification or later sends"
    )
}

func testUPnPRenewalRequiresPersistedIGDIdentity() throws {
    let gateway = "192.0.2.1"
    let baseline = Date(timeIntervalSince1970: 75_000)
    let boot = "upnp-bound-renewal"

    func mapping(
        service: UPnPService,
        family: RouterMappingAddressFamily,
        localAddress: String,
        pinholeID: UInt16? = nil
    ) throws -> ActiveRouterMapping {
        var result = ActiveRouterMapping(
            transport: .upnp,
            addressFamily: family,
            localAddress: localAddress,
            gatewayAddress: gateway,
            internalPort: 5900,
            externalPort: family == .ipv4 ? 45900 : 5900,
            pinholeID: pinholeID,
            pcpNonce: try encodedUPnPBindingFixture(
                service: service,
                gateway: gateway
            ),
            leaseExpiresAt: baseline.addingTimeInterval(60),
            renewAfter: baseline
        )
        result.leaseBootIdentifier = boot
        result.renewAfterUptime = 100
        result.leaseExpiresUptime = 160
        result.leaseAnchorWallTime = baseline
        result.leaseRemainingAtAnchor = 60
        return result
    }

    let ipv4Service = UPnPService(
        serviceType:
            "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(
            string:
                "http://192.0.2.1:5000/upnp/control/original-ipv4"
        )!,
        gatewayIdentity: gateway,
        descriptionURL: URL(
            string: "http://192.0.2.1:5000/original-root.xml"
        )!,
        deviceIdentity: "uuid:original-ipv4-igd"
    )
    let ipv4 = try mapping(
        service: ipv4Service,
        family: .ipv4,
        localAddress: "192.0.2.20"
    )
    var discoveryCalls = 0
    var soapCalls = 0
    let replacedUDN = RouterMappingService(
        upnpDiscoveryHandler: {
            discoveryCalls += 1
            return []
        },
        upnpDescriptionHandler: { url in
            try expect(
                url == ipv4Service.descriptionURL,
                "IPv4 renew must verify only the persisted description URL"
            )
            return try upnpDescriptionFixture(
                service: ipv4Service,
                deviceIdentity: "uuid:replacement-ipv4-igd"
            )
        },
        soapRequestHandler: { _, _, _, _ in
            soapCalls += 1
            return response("")
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { 100 },
        bootIdentifierProvider: { boot }
    )
    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .upnp
    config.internalPort = ipv4.internalPort
    config.externalPort = ipv4.externalPort
    var ipv4Recovery: ActiveRouterMapping?
    do {
        _ = try replacedUDN.renewMapping(
            config: config,
            mapping: ipv4
        )
        throw TestFailure("A replacement IPv4 UDN must block renewal")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        ipv4Recovery = recovery.mapping
        try expect(
            recovery.mapping.identifier == ipv4.identifier
                && recovery.mapping.pcpNonce == ipv4.pcpNonce
                && recovery.mapping.leaseExpiresUptime
                    == ipv4.leaseExpiresUptime
                && recovery.mapping.recoveryState
                    == .upnpIdentityChanged,
            "IPv4 identity failure must preserve the exact old recovery identity"
        )
    }
    try expect(
        discoveryCalls == 0 && soapCalls == 0,
        "IPv4 renew must neither rediscover nor send AddPortMapping "
            + "after a UDN mismatch"
    )
    guard let ipv4Recovery else {
        throw TestFailure("IPv4 identity failure must return recovery")
    }
    let blockedCleanup = replacedUDN.removeMappings([ipv4Recovery])
    try expect(
        blockedCleanup.remainingMappings == [ipv4Recovery]
            && soapCalls == 0,
        "Changed IGD identity must keep blocking cleanup and replacement "
            + "before the old monotonic lease expires"
    )

    var cleanupActions: [String] = []
    let restoredOriginal = RouterMappingService(
        upnpDescriptionHandler: { _ in
            try upnpDescriptionFixture(service: ipv4Service)
        },
        soapRequestHandler: { _, _, action, _ in
            cleanupActions.append(action)
            if action == "GetSpecificPortMappingEntry" {
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                </response>
                """)
            }
            return response("")
        },
        nowProvider: { baseline.addingTimeInterval(20) },
        monotonicUptimeProvider: { 120 },
        bootIdentifierProvider: { boot }
    )
    try expect(
        restoredOriginal.removeMappings([ipv4Recovery]).allSucceeded
            && cleanupActions
                == ["GetSpecificPortMappingEntry", "DeletePortMapping"],
        "Restored exact IGD identity must allow safe cleanup before expiry"
    )

    var expiredIdentityChecks = 0
    let expiredRecovery = RouterMappingService(
        upnpDescriptionHandler: { _ in
            expiredIdentityChecks += 1
            throw TestFailure(
                "Expired finite UPnP recovery needs no network request"
            )
        },
        nowProvider: { baseline.addingTimeInterval(60) },
        monotonicUptimeProvider: { 160 },
        bootIdentifierProvider: { boot }
    )
    try expect(
        expiredRecovery.removeMappings([ipv4Recovery]).allSucceeded
            && expiredIdentityChecks == 0,
        "Old UPnP recovery may clear at its monotonic finite-lease expiry"
    )

    var missingUDNSOAPCalls = 0
    let missingUDN = RouterMappingService(
        upnpDescriptionHandler: { _ in
            Data("""
            <root>
              <device>
                <serviceList>
                  <service>
                    <serviceType>\(ipv4Service.serviceType)</serviceType>
                    <controlURL>\(ipv4Service.controlURL.absoluteString)</controlURL>
                  </service>
                </serviceList>
              </device>
            </root>
            """.utf8)
        },
        soapRequestHandler: { _, _, _, _ in
            missingUDNSOAPCalls += 1
            return response("")
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { 100 },
        bootIdentifierProvider: { boot }
    )
    do {
        _ = try missingUDN.renewMapping(
            config: config,
            mapping: ipv4
        )
        throw TestFailure("Missing current UDN must block renewal")
    } catch is RouterMappingRecoveryRequiredError {
        // Expected.
    }
    try expect(
        missingUDNSOAPCalls == 0,
        "Persisted UDN must not be substituted when the current description omits it"
    )

    let ipv6Service = UPnPService(
        serviceType:
            "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1",
        controlURL: URL(
            string:
                "http://192.0.2.1:5000/upnp/control/original-ipv6"
        )!,
        gatewayIdentity: gateway,
        descriptionURL: URL(
            string: "http://192.0.2.1:5000/original-v6-root.xml"
        )!,
        deviceIdentity: "uuid:original-ipv6-igd",
        ssdpBootID: "201",
        ssdpConfigID: "11"
    )
    let ipv6 = try mapping(
        service: ipv6Service,
        family: .ipv6,
        localAddress: "2606:4700:4700::20",
        pinholeID: 77
    )
    discoveryCalls = 0
    soapCalls = 0
    let changedControl = RouterMappingService(
        upnpDiscoveryHandler: {
            discoveryCalls += 1
            return [
                UPnPService(
                    serviceType: ipv6Service.serviceType,
                    controlURL: URL(
                        string:
                            "http://192.0.2.1:5000/upnp/control/replacement-ipv6"
                    )!,
                    gatewayIdentity: gateway,
                    descriptionURL: ipv6Service.descriptionURL,
                    deviceIdentity: ipv6Service.deviceIdentity,
                    ssdpBootID: ipv6Service.ssdpBootID,
                    ssdpConfigID: ipv6Service.ssdpConfigID
                )
            ]
        },
        upnpDescriptionHandler: { url in
            try expect(
                url == ipv6Service.descriptionURL,
                "IPv6 renew must verify only the persisted description URL"
            )
            return try upnpDescriptionFixture(
                service: ipv6Service,
                controlURL: URL(
                    string:
                        "http://192.0.2.1:5000/upnp/control/replacement-ipv6"
                )!
            )
        },
        soapRequestHandler: { _, _, _, _ in
            soapCalls += 1
            return response("")
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { 100 },
        bootIdentifierProvider: { boot }
    )
    config.preferredAddressFamily = .ipv6
    config.externalPort = ipv6.externalPort
    config.ipv6PinholeID = ipv6.pinholeID
    do {
        _ = try changedControl.renewMapping(
            config: config,
            mapping: ipv6
        )
        throw TestFailure(
            "A replacement IPv6 control URL must block renewal"
        )
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            recovery.mapping.identifier == ipv6.identifier
                && recovery.mapping.pinholeID == 77
                && recovery.mapping.recoveryState
                    == .upnpIdentityChanged,
            "IPv6 identity failure must preserve the old pinhole recovery identity"
        )
    }
    try expect(
        discoveryCalls == 1 && soapCalls == 0,
        "IPv6 renew must rediscover SSDP identity but not send UpdatePinhole/AddPinhole "
            + "after a control URL mismatch"
    )

    var boundIPv6Actions: [String] = []
    let boundIPv6 = RouterMappingService(
        upnpDiscoveryHandler: { [ipv6Service] },
        upnpDescriptionHandler: { _ in
            try upnpDescriptionFixture(service: ipv6Service)
        },
        soapRequestHandler: { _, _, action, _ in
            boundIPv6Actions.append(action)
            if action == "GetFirewallStatus" {
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            }
            return response("")
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { 100 },
        bootIdentifierProvider: { boot }
    )
    let renewedIPv6 = try boundIPv6.renewMapping(
        config: config,
        mapping: ipv6
    )
    try expect(
        boundIPv6Actions == ["GetFirewallStatus", "UpdatePinhole"]
            && renewedIPv6.pinholeID == 77
            && renewedIPv6.activeMapping.pcpNonce == ipv6.pcpNonce,
        "Verified IPv6 renewal must stay on the original IGD and pinhole"
    )
}

func testRealUPnPDescriptionRequestCancelsURLSession() throws {
    let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard listener >= 0 else {
        throw TestFailure("Could not create loopback TCP listener")
    }
    var shouldReuse: Int32 = 1
    _ = setsockopt(
        listener,
        SOL_SOCKET,
        SO_REUSEADDR,
        &shouldReuse,
        socklen_t(MemoryLayout<Int32>.size)
    )
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        close(listener)
        throw TestFailure("Could not parse loopback TCP address")
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                listener,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bound == 0, listen(listener, 1) == 0 else {
        close(listener)
        throw TestFailure("Could not bind loopback TCP listener")
    }
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &addressLength)
        }
    }
    guard named == 0 else {
        close(listener)
        throw TestFailure("Could not read loopback TCP port")
    }
    let port = UInt16(bigEndian: address.sin_port)
    let requestArrived = DispatchSemaphore(value: 0)
    let releaseServer = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        let client = accept(listener, nil, nil)
        if client >= 0 {
            var bytes = [UInt8](repeating: 0, count: 2_048)
            _ = recv(client, &bytes, bytes.count, 0)
            requestArrived.signal()
            _ = releaseServer.wait(timeout: .now() + 2)
            close(client)
        }
        close(listener)
    }

    let location = "http://127.0.0.1:\(port)/root.xml"
    let ssdp = Data("""
    HTTP/1.1 200 OK\r
    LOCATION: \(location)\r
    USN: uuid:gatebeam-cancel-router\r
    \r
    """.utf8)
    var soapActions: [String] = []
    let mapper = RouterMappingService(
        soapRequestHandler: { _, _, action, _ in
            soapActions.append(action)
            return response("")
        },
        ssdpSearchHandler: { _ in [ssdp] }
    )
    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .upnp
    let completion = DispatchSemaphore(value: 0)
    let outcomeLock = NSLock()
    var outcome: Error?
    DispatchQueue.global(qos: .userInitiated).async {
        defer { completion.signal() }
        do {
            _ = try mapper.ensureMapping(
                config: config,
                localAddress: "192.0.2.20",
                gatewayAddress: "127.0.0.1"
            )
        } catch {
            outcomeLock.lock()
            outcome = error
            outcomeLock.unlock()
        }
    }
    guard requestArrived.wait(timeout: .now() + 2) == .success else {
        releaseServer.signal()
        throw TestFailure("URLSession did not reach the loopback server")
    }
    let started = ProcessInfo.processInfo.systemUptime
    mapper.cancelCurrentOperations()
    let completed = completion.wait(timeout: .now() + 0.75) == .success
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    releaseServer.signal()
    outcomeLock.lock()
    let captured = outcome
    outcomeLock.unlock()
    try expect(
        completed && elapsed < 0.75,
        "Cancelling UPnP must interrupt a live URLSession request promptly"
    )
    try expect(
        captured is RouterMappingError && soapActions.isEmpty,
        "Cancelled description fetch must not proceed to any SOAP MAP"
    )
    if let mappingError = captured as? RouterMappingError {
        guard case .cancelled = mappingError else {
            throw TestFailure(
                "Real URLSession cancellation must surface as cancelled"
            )
        }
    }
}

func testNATPMPEffectiveIdentityPersistsAndDriftBlocksMAP() throws {
    let hint = "192.0.2.20"
    let effective = "10.0.0.20"
    let gateway = "192.0.2.1"
    let baseline = Date(timeIntervalSince1970: 80_000)
    let boot = "natpmp-effective-source"
    var uptime: TimeInterval = 100
    var sourceHints: [String?] = []
    var selectedSources: [String] = []
    var mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            sourceHints.append(sourceAddressHint)
            selectedSources.append(effective)
            let payload = try payloadBuilder(effective)
            let response: Data
            if payload == Data([0, 0]) {
                response = natPMPExternalAddressResponse(epoch: 100)
            } else {
                response = natPMPMappingResponse(
                    for: payload,
                    epoch: 100
                )
            }
            let accepted = try acceptsResponse(response)
            try expect(accepted, "NAT-PMP response must parse")
            return response
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .natpmp
    let created = try mapper.ensureMapping(
        config: config,
        localAddress: hint,
        gatewayAddress: gateway
    ).activeMapping
    try expect(
        created.localAddress == effective
            && sourceHints.first == hint,
        "NATPMP_HINT must be replaced by the real effective source"
    )

    uptime = created.renewAfterUptime ?? 130
    let renewed = try mapper.renewMapping(
        config: config,
        mapping: created
    ).activeMapping
    try expect(
        renewed.localAddress == effective
            && sourceHints.last == effective
            && selectedSources.allSatisfy { $0 == effective },
        "NAT-PMP renew must remain bound to persisted effective identity"
    )

    var reachedDelete = false
    let changed = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder("10.0.0.21")
            if payload != Data([0, 0]) {
                reachedDelete = true
                throw TestFailure(
                    "Address drift must fail before NAT-PMP delete"
                )
            }
            let response = natPMPExternalAddressResponse(
                epoch: renewed.routerEpoch ?? 0
            )
            let accepted = try acceptsResponse(response)
            try expect(accepted, "NAT-PMP delete probe must parse")
            return response
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )
    let deletion = changed.removeMappings([renewed])
    try expect(
        !reachedDelete && deletion.remainingMappings == [renewed],
        "NAT-PMP delete must retain B when the effective source changed"
    )

    mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder("10.0.0.21")
            try expect(
                payload == Data([0, 0]),
                "NAT-PMP drift probe must be harmless"
            )
            let response = natPMPExternalAddressResponse(epoch: 110)
            let accepted = try acceptsResponse(response)
            try expect(accepted, "NAT-PMP drift response must parse")
            return response
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { uptime + 10 },
        bootIdentifierProvider: { boot }
    )
    let drift = try mapper.refreshMappingEpochs([renewed])
    guard case .effectiveClientAddressChanged(let replacement) =
            drift.invalidations.first?.reason else {
        throw TestFailure("NAT-PMP address drift needs orphan invalidation")
    }
    try expect(
        replacement == "10.0.0.21"
            && drift.invalidatedMappings == [renewed],
        "NAT-PMP drift must retain original B and report C"
    )
}

func testNATPMPDeletionRequiresProvenEpochContinuity() throws {
    let baseline = Date(timeIntervalSince1970: 85_000)
    let boot = "natpmp-delete-continuity"
    let mapping = trackedNATPMPFixture(
        suffix: 28,
        epoch: 500,
        now: baseline,
        uptime: 100,
        boot: boot
    )

    var resetPayloads: [Data] = []
    let resetRouter = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(mapping.localAddress)
            resetPayloads.append(payload)
            let response = natPMPExternalAddressResponse(epoch: 1)
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Reset Epoch probe must parse")
            return response
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 110 },
        bootIdentifierProvider: { boot }
    )
    let resetReport = resetRouter.removeMappings([mapping])
    try expect(
        resetPayloads == [Data([0, 0])]
            && resetReport.remainingMappings == [mapping],
        "Old Epoch 500 and current Epoch 1 must never send lifetime=0"
    )

    var continuousPayloads: [Data] = []
    let continuousRouter = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(mapping.localAddress)
            continuousPayloads.append(payload)
            let response: Data
            if payload == Data([0, 0]) {
                response = natPMPExternalAddressResponse(epoch: 510)
            } else {
                response = natPMPMappingResponse(
                    for: payload,
                    epoch: 510
                )
            }
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Continuous delete response must parse")
            return response
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 110 },
        bootIdentifierProvider: { boot }
    )
    let continuousReport =
        continuousRouter.removeMappings([mapping])
    try expect(
        continuousReport.allSucceeded
            && continuousPayloads.count == 2
            && continuousPayloads[0] == Data([0, 0])
            && testReadUInt32(
                continuousPayloads[1],
                at: 8
            ) == 0,
        "A continuous Epoch/source probe must precede the delete"
    )

    var crossBootCalls = 0
    let crossBootRouter = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, _, _ in
            crossBootCalls += 1
            throw TestFailure(
                "Cross-boot unknown NAT-PMP identity must not use UDP"
            )
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 10 },
        bootIdentifierProvider: { "replacement-boot" }
    )
    let crossBootReport = crossBootRouter.removeMappings([mapping])
    try expect(
        crossBootCalls == 0
            && crossBootReport.remainingMappings == [mapping],
        "Cross-boot NAT-PMP deletion must wait for natural expiry"
    )

    var naturallyExpired = mapping
    naturallyExpired.recoveryState = .clockContinuityUnverified
    naturallyExpired.leaseBootIdentifier = "replacement-boot"
    naturallyExpired.leaseExpiresUptime = 10
    naturallyExpired.recoveryBootIdentifier = "replacement-boot"
    naturallyExpired.recoverySafeAfterUptime = 20
    var expiredCalls = 0
    let expiredRouter = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, _, _, _ in
            expiredCalls += 1
            throw TestFailure(
                "Naturally expired NAT-PMP mapping needs no UDP"
            )
        },
        nowProvider: { baseline.addingTimeInterval(20) },
        monotonicUptimeProvider: { 20 },
        bootIdentifierProvider: { "replacement-boot" }
    )
    let expiredReport =
        expiredRouter.removeMappings([naturallyExpired])
    try expect(
        expiredCalls == 0 && expiredReport.allSucceeded,
        "Recovery may clear only after its conservative monotonic "
            + "natural-expiry deadline"
    )
}

func testDeletionRequestsZeroSuggestedExternalFields() throws {
    let baseline = Date(timeIntervalSince1970: 90_000)
    let uptime: TimeInterval = 100
    let boot = "delete-zero-fields"
    let pcp = mappingFixture(transport: .pcp, family: .ipv4, suffix: 31)
    let natPMP = trackedNATPMPFixture(
        suffix: 32,
        epoch: 500,
        now: baseline,
        uptime: uptime,
        boot: boot
    )
    var requests: [Data] = []
    let mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, acceptsResponse in
            let payload = try payloadBuilder(sourceAddressHint ?? "192.0.2.20")
            requests.append(payload)
            let response: Data
            if payload.first == 2 {
                response = pcpMappingResponse(for: payload)
            } else if payload == Data([0, 0]) {
                response = natPMPExternalAddressResponse(epoch: 500)
            } else {
                response = natPMPMappingResponse(
                    for: payload,
                    epoch: 500
                )
            }
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Deletion response must match")
            return response
        },
        nowProvider: { baseline },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { boot }
    )

    let report = mapper.removeMappings([pcp, natPMP])
    try expect(report.allSucceeded, "Both non-mirror deletion requests must succeed")
    try expect(
        requests.count == 3 && requests[1] == Data([0, 0]),
        "NAT-PMP delete must be preceded by one harmless identity probe"
    )

    let pcpRequest = requests[0]
    try expect(testReadUInt32(pcpRequest, at: 4) == 0, "PCP delete lifetime must be zero")
    try expect(
        testReadUInt16(pcpRequest, at: 40) == pcp.internalPort,
        "PCP delete must retain the internal port identity"
    )
    try expect(
        testReadUInt16(pcpRequest, at: 42) == 0,
        "PCP delete suggested external port must be zero"
    )
    try expect(
        pcpRequest[44..<60].allSatisfy { $0 == 0 },
        "PCP delete suggested external address must be all zero"
    )

    let natPMPRequest = requests[2]
    try expect(
        testReadUInt16(natPMPRequest, at: 4) == natPMP.internalPort,
        "NAT-PMP delete must retain the internal port identity"
    )
    try expect(
        testReadUInt16(natPMPRequest, at: 6) == 0,
        "NAT-PMP delete requested external port must be zero"
    )
    try expect(
        testReadUInt32(natPMPRequest, at: 8) == 0,
        "NAT-PMP delete lifetime must be zero"
    )
}

func testDeletionRejectsNonzeroSuccessState() throws {
    let baseline = Date(timeIntervalSince1970: 91_000)
    let uptime: TimeInterval = 100
    let boot = "delete-response-validation"
    let pcp = mappingFixture(transport: .pcp, family: .ipv4, suffix: 33)
    let natPMP = trackedNATPMPFixture(
        suffix: 34,
        epoch: 90,
        now: baseline,
        uptime: uptime,
        boot: boot
    )

    let pcpMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            let payload = try payloadBuilder(
                sourceAddressHint ?? "192.0.2.33"
            )
            var response = pcpMappingResponse(for: payload, epoch: 90)
            response[7] = 1
            return response
        }
    )
    let pcpReport = pcpMapper.removeMappings([pcp])
    try expect(
        pcpReport.remainingMappings == [pcp],
        "A PCP success delete with nonzero lifetime must retain tracked state"
    )

    for corruption in ["external-port", "lifetime"] {
        let natPMPMapper = RouterMappingService(
            udpTransactionHandler: {
                _, _, _, sourceAddressHint, payloadBuilder, _ in
                let payload = try payloadBuilder(
                    sourceAddressHint ?? "192.0.2.34"
                )
                if payload == Data([0, 0]) {
                    return natPMPExternalAddressResponse(epoch: 90)
                }
                var response = natPMPMappingResponse(
                    for: payload,
                    epoch: 90
                )
                if corruption == "external-port" {
                    response[11] = 1
                } else {
                    response[15] = 1
                }
                return response
            },
            nowProvider: { baseline },
            monotonicUptimeProvider: { uptime },
            bootIdentifierProvider: { boot }
        )
        let report = natPMPMapper.removeMappings([natPMP])
        try expect(
            report.remainingMappings == [natPMP],
            "A NAT-PMP delete with nonzero \(corruption) must retain tracked state"
        )
    }
}

func testPCPResponseValidationAndRetrySchedules() throws {
    func expectInvalid(_ operation: () throws -> Void, _ message: String) throws {
        do {
            try operation()
            throw TestFailure(message)
        } catch RouterMappingError.invalidResponse {
            return
        }
    }

    var nonzeroAnnounceLifetime = pcpAnnounceResponse()
    nonzeroAnnounceLifetime[7] = 1
    try expectInvalid(
        {
            _ = try PCPMessageCodec.parseAnnounceResponse(
                nonzeroAnnounceLifetime
            )
        },
        "ANNOUNCE with a nonzero lifetime must be rejected"
    )
    try expectInvalid(
        {
            _ = try PCPMessageCodec.parseAnnounceResponse(
                Data(repeating: 0, count: 26)
            )
        },
        "Misaligned ANNOUNCE must be rejected"
    )
    var oversizedAnnounce = Data(repeating: 0, count: 1_104)
    oversizedAnnounce[0] = 2
    oversizedAnnounce[1] = 0x80
    try expectInvalid(
        {
            _ = try PCPMessageCodec.parseAnnounceResponse(oversizedAnnounce)
        },
        "Oversized ANNOUNCE must be rejected"
    )

    let nonce = Data(repeating: 7, count: 12)
    let mapRequest = try PCPMessageCodec.makeMapRequest(
        lifetime: 3_600,
        clientAddress: "192.0.2.20",
        nonce: nonce,
        internalPort: 5_900,
        suggestedExternalPort: 45_900
    )
    let validMap = pcpMappingResponse(for: mapRequest)
    try expectInvalid(
        {
            _ = try PCPMessageCodec.parseMapResponse(
                Data(validMap.prefix(58)),
                nonce: nonce,
                internalPort: 5_900,
                requestedLifetime: 3_600
            )
        },
        "Misaligned short MAP response must be rejected"
    )
    try expectInvalid(
        {
            _ = try PCPMessageCodec.parseMapResponse(
                validMap + Data(repeating: 0, count: 1_044),
                nonce: nonce,
                internalPort: 5_900,
                requestedLifetime: 3_600
            )
        },
        "Oversized MAP response must be rejected"
    )

    let noJitter = RouterMappingService.pcpRetryIntervals(
        maximumAttempts: 12,
        randomizationProvider: { 0 }
    )
    try expect(
        noJitter == [3, 6, 12, 24, 48, 96, 192, 384, 768, 1_024, 1_024, 1_024],
        "PCP retry schedule must double from 3 seconds and cap at 1024"
    )
    let positiveJitter = RouterMappingService.pcpRetryIntervals(
        maximumAttempts: 16,
        randomizationProvider: { 0.1 }
    )
    try expect(
        abs((positiveJitter.first ?? 0) - 3.3) < 0.000_001
            && positiveJitter.allSatisfy { $0 <= 1_024 },
        "PCP jitter must stay within +10% while preserving the 1024-second cap"
    )

    var defaultPCPIntervals: [TimeInterval] = []
    var pcpConfig = automaticMappingConfig()
    pcpConfig.mappingProtocolPreference = .pcp
    let defaultPCP = RouterMappingService(
        udpTransactionHandler: {
            _, _, intervals, _, payloadBuilder, acceptsResponse in
            defaultPCPIntervals = intervals
            let payload = try payloadBuilder("192.0.2.20")
            let response = pcpMappingResponse(for: payload)
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Default PCP MAP response must match")
            return response
        },
        retryRandomizationProvider: { 0 }
    )
    _ = try defaultPCP.ensureMapping(
        config: pcpConfig,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(
        defaultPCPIntervals == [3, 6, 12, 24, 48, 96, 192, 384, 768],
        "Default PCP product policy must use nine RFC-shaped attempts"
    )

    var natPMPIntervals: [TimeInterval] = []
    let natPMP = RouterMappingService(
        udpTransactionHandler: {
            _, _, intervals, _, payloadBuilder, acceptsResponse in
            natPMPIntervals = intervals
            let payload = try payloadBuilder("192.0.2.20")
            try expect(payload == Data([0, 0]), "External Address request must be harmless")
            let response = natPMPExternalAddressResponse(
                address: [192, 0, 2, 53]
            )
            let accepted = try acceptsResponse(response)
            try expect(accepted, "NAT-PMP response must match")
            return response
        }
    )
    let externalAddress = try natPMP.externalIPv4Address(
        gatewayAddress: "192.0.2.1"
    )
    try expect(
        externalAddress == "192.0.2.53",
        "Default NAT-PMP capability request must succeed"
    )
    try expect(
        natPMPIntervals == [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64],
        "Default NAT-PMP policy must use all nine RFC 6886 attempts"
    )
}

func testEpochTrackingDetectsStateLossAndIsolatesKeys() throws {
    let baseline = Date(timeIntervalSince1970: 10_000)
    let baselineUptime: TimeInterval = 1_000
    let bootIdentifier = "boot-epoch-tests"
    var now = baseline.addingTimeInterval(10)
    var uptime = baselineUptime + 10

    func epochMapping(
        transport: RouterMappingTransport,
        gateway: String,
        localAddress: String,
        epoch: UInt32,
        family: RouterMappingAddressFamily = .ipv4,
        suffix: UInt16? = nil
    ) -> ActiveRouterMapping {
        var mapping = mappingFixture(
            transport: transport,
            family: family,
            suffix: suffix
                ?? UInt16(localAddress.split(separator: ".").last ?? "20")
                ?? 20
        )
        mapping.gatewayAddress = gateway
        mapping.localAddress = localAddress
        mapping.routerEpoch = epoch
        mapping.routerEpochObservedAt = baseline
        mapping.routerEpochObservedUptime = baselineUptime
        mapping.routerEpochBootIdentifier = bootIdentifier
        mapping.routerEpochHealthCheckAfter =
            baseline.addingTimeInterval(60)
        return mapping
    }

    let resetPCP = epochMapping(
        transport: .pcp,
        gateway: "192.0.2.1",
        localAddress: "192.0.2.20",
        epoch: 100
    )
    let healthyPCP = epochMapping(
        transport: .pcp,
        gateway: "192.0.2.2",
        localAddress: "192.0.2.21",
        epoch: 200
    )
    let healthyNATPMP = epochMapping(
        transport: .natpmp,
        gateway: "192.0.2.1",
        localAddress: "192.0.2.22",
        epoch: 300
    )

    let mapper = RouterMappingService(
        udpTransactionHandler: {
            host, _, intervals, sourceAddressHint, payloadBuilder, acceptsResponse in
            try expect(
                intervals == [0.25, 0.5],
                "Epoch health checks must use their independent 0.75-second budget"
            )
            let payload = try payloadBuilder(
                sourceAddressHint ?? "192.0.2.22"
            )
            let response: Data
            if payload.first == 2 {
                response = pcpAnnounceResponse(
                    epoch: host == "192.0.2.1" ? 5 : 210
                )
            } else {
                response = natPMPExternalAddressResponse(epoch: 309)
            }
            let accepted = try acceptsResponse(response)
            try expect(accepted, "Epoch probe response must match its protocol")
            return response
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier },
        natPMPRebuildRandomizationProvider: { 0 },
        rebuildDelayScheduler: { _, _ in }
    )
    let report = try mapper.refreshMappingEpochs([
        resetPCP,
        healthyPCP,
        healthyNATPMP
    ])
    try expect(
        report.invalidatedMappings == [resetPCP],
        "PCP Epoch rollback must invalidate only its gateway/client/protocol key"
    )
    try expect(
        Set(report.refreshedMappings.map(\.identifier))
            == Set([healthyPCP.identifier, healthyNATPMP.identifier]),
        "Healthy PCP and NAT-PMP keys must remain isolated from another reset"
    )
    try expect(
        report.refreshedMappings.first {
            $0.identifier == healthyPCP.identifier
        }?.routerEpoch == 210,
        "A healthy PCP observation must update its persisted Epoch baseline"
    )
    try expect(
        report.refreshedMappings.first {
            $0.identifier == healthyNATPMP.identifier
        }?.routerEpoch == 309,
        "A healthy NAT-PMP observation must update its persisted Epoch baseline"
    )

    let slowPCP = epochMapping(
        transport: .pcp,
        gateway: "192.0.2.3",
        localAddress: "192.0.2.23",
        epoch: 100
    )
    now = baseline.addingTimeInterval(100)
    uptime = baselineUptime + 100
    let driftMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.23")
            return pcpAnnounceResponse(epoch: 101)
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    let driftReport = try driftMapper.refreshMappingEpochs([slowPCP])
    try expect(
        driftReport.invalidatedMappings == [slowPCP],
        "RFC 6887 client/server time drift must trigger immediate recreation"
    )

    let resetNATPMP = epochMapping(
        transport: .natpmp,
        gateway: "192.0.2.4",
        localAddress: "192.0.2.24",
        epoch: 100
    )
    now = baseline.addingTimeInterval(16)
    uptime = baselineUptime + 16
    let natDriftMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.24")
            return natPMPExternalAddressResponse(epoch: 110)
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier },
        natPMPRebuildRandomizationProvider: { 0 },
        rebuildDelayScheduler: { _, _ in }
    )
    let natDriftReport = try natDriftMapper.refreshMappingEpochs([
        resetNATPMP
    ])
    try expect(
        natDriftReport.invalidatedMappings == [resetNATPMP],
        "RFC 6886 conservative Epoch estimate must detect NAT-PMP state loss"
    )

    now = baseline.addingTimeInterval(16)
    var pendingResponseEpochs: [UInt32] = [1, 2]
    let pendingMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.24")
            guard !pendingResponseEpochs.isEmpty else {
                throw TestFailure("No pending Epoch response left")
            }
            return natPMPExternalAddressResponse(
                epoch: pendingResponseEpochs.removeFirst()
            )
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier },
        natPMPRebuildRandomizationProvider: { 0 },
        rebuildDelayScheduler: { _, _ in }
    )
    _ = try pendingMapper.externalIPv4Address(
        gatewayAddress: resetNATPMP.gatewayAddress
    )
    let pendingReport = try pendingMapper.refreshMappingEpochs([
        resetNATPMP
    ])
    try expect(
        pendingReport.invalidatedMappings == [resetNATPMP],
        "WAN discovery before persisted-state seeding must still detect the Epoch reset"
    )

    let scopedPCP0 = epochMapping(
        transport: .pcp,
        gateway: "fe80::1%en0",
        localAddress: "fe80::20",
        epoch: 100,
        family: .ipv6,
        suffix: 26
    )
    let scopedPCP1 = epochMapping(
        transport: .pcp,
        gateway: "fe80::1%en1",
        localAddress: "fe80::20",
        epoch: 100,
        family: .ipv6,
        suffix: 27
    )
    now = baseline.addingTimeInterval(10)
    uptime = baselineUptime + 10
    let scopedMapper = RouterMappingService(
        udpTransactionHandler: {
            host, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "fe80::20")
            return pcpAnnounceResponse(
                epoch: host.hasSuffix("%en0") ? 5 : 110
            )
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    let scopedReport = try scopedMapper.refreshMappingEpochs([
        scopedPCP0,
        scopedPCP1
    ])
    try expect(
        scopedReport.invalidatedMappings == [scopedPCP0],
        "IPv6 link-local gateway scopes must remain isolated Epoch keys"
    )
    try expect(
        scopedReport.refreshedMappings.map(\.identifier)
            == [scopedPCP1.identifier],
        "A reset on one scoped IPv6 gateway must not invalidate another"
    )

    let concurrentMapping = epochMapping(
        transport: .pcp,
        gateway: "192.0.2.5",
        localAddress: "192.0.2.25",
        epoch: 500
    )
    now = baseline
    uptime = baselineUptime
    let concurrentMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.25")
            return pcpAnnounceResponse(epoch: 500)
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    let group = DispatchGroup()
    let errorLock = NSLock()
    var concurrentErrors: [String] = []
    for _ in 0..<32 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try concurrentMapper.refreshMappingEpochs([
                    concurrentMapping
                ])
            } catch {
                errorLock.lock()
                concurrentErrors.append(error.localizedDescription)
                errorLock.unlock()
            }
        }
    }
    try expect(
        group.wait(timeout: .now() + 3) == .success,
        "Concurrent Epoch observations must not deadlock"
    )
    try expect(
        concurrentErrors.isEmpty,
        "Concurrent Epoch observations must remain thread-safe"
    )
}

func testEpochUsesMonotonicTimeAndFailsClosedAcrossPersistence() throws {
    let baselineWall = Date(timeIntervalSince1970: 30_000)
    let baselineUptime: TimeInterval = 1_000
    let bootA = "boot-monotonic-a"
    var mapping = mappingFixture(
        transport: .pcp,
        family: .ipv4,
        suffix: 28
    )
    mapping.gatewayAddress = "192.0.2.28"
    mapping.localAddress = "192.0.2.28"
    mapping.routerEpoch = 100
    mapping.routerEpochObservedAt = baselineWall
    mapping.routerEpochObservedUptime = baselineUptime
    mapping.routerEpochBootIdentifier = bootA
    mapping.routerEpochHealthCheckAfter =
        baselineWall.addingTimeInterval(60)

    var wall = baselineWall.addingTimeInterval(10)
    var uptime = baselineUptime + 10
    var responseEpoch: UInt32 = 110
    let mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? mapping.localAddress)
            return pcpAnnounceResponse(epoch: responseEpoch)
        },
        nowProvider: { wall },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootA }
    )

    var current = try mapper.refreshMappingEpochs([mapping])
        .refreshedMappings[0]
    wall = wall.addingTimeInterval(3_600)
    uptime += 10
    responseEpoch += 10
    var report = try mapper.refreshMappingEpochs([current])
    try expect(
        report.invalidatedMappings.isEmpty,
        "An in-process NTP forward jump must not replace monotonic elapsed time"
    )
    current = report.refreshedMappings[0]

    wall = wall.addingTimeInterval(-7_200)
    uptime += 10
    responseEpoch += 10
    report = try mapper.refreshMappingEpochs([current])
    try expect(
        report.invalidatedMappings.isEmpty,
        "An in-process NTP backward jump must not become negative elapsed time"
    )
    current = report.refreshedMappings[0]

    uptime -= 1
    responseEpoch += 1
    report = try mapper.refreshMappingEpochs([current])
    try expect(
        report.invalidatedMappings == [current],
        "A monotonic clock rollback must fail closed"
    )

    func persistedReport(
        wall: Date,
        uptime: TimeInterval,
        boot: String
    ) throws -> RouterMappingEpochReport {
        let fresh = RouterMappingService(
            udpTransactionHandler: {
                _, _, _, sourceAddressHint, payloadBuilder, _ in
                _ = try payloadBuilder(
                    sourceAddressHint ?? mapping.localAddress
                )
                return pcpAnnounceResponse(epoch: 110)
            },
            nowProvider: { wall },
            monotonicUptimeProvider: { uptime },
            bootIdentifierProvider: { boot }
        )
        return try fresh.refreshMappingEpochs([mapping])
    }

    let forward = try persistedReport(
        wall: baselineWall.addingTimeInterval(3_600),
        uptime: baselineUptime + 10,
        boot: bootA
    )
    try expect(
        forward.invalidatedMappings == [mapping],
        "A persisted wall-clock forward jump must fail closed"
    )
    let backward = try persistedReport(
        wall: baselineWall.addingTimeInterval(-10),
        uptime: baselineUptime + 10,
        boot: bootA
    )
    try expect(
        backward.invalidatedMappings == [mapping],
        "A persisted wall-clock backward jump must fail closed"
    )
    let rebooted = try persistedReport(
        wall: baselineWall.addingTimeInterval(10),
        uptime: 10,
        boot: "boot-monotonic-b"
    )
    try expect(
        rebooted.invalidatedMappings == [mapping],
        "A system boot identity change must invalidate persisted router state"
    )
}

func testNATPMPResetDelayBoundariesCancellationAndSerialization() throws {
    let baseline = Date(timeIntervalSince1970: 40_000)
    let bootIdentifier = "boot-natpmp-delay"

    func mapping(_ suffix: UInt16) -> ActiveRouterMapping {
        var result = mappingFixture(
            transport: .natpmp,
            family: .ipv4,
            suffix: suffix
        )
        result.gatewayAddress = "192.0.2.40"
        result.routerEpoch = 100
        result.routerEpochObservedAt = baseline
        result.routerEpochObservedUptime = 100
        result.routerEpochBootIdentifier = bootIdentifier
        result.routerEpochHealthCheckAfter =
            baseline.addingTimeInterval(60)
        return result
    }

    func runBoundary(_ randomSample: Double) throws -> [TimeInterval] {
        var delays: [TimeInterval] = []
        var transactionCount = 0
        let mapper = RouterMappingService(
            udpTransactionHandler: {
                _, _, _, sourceAddressHint, payloadBuilder, _ in
                transactionCount += 1
                _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.40")
                return natPMPExternalAddressResponse(epoch: 1)
            },
            nowProvider: { baseline.addingTimeInterval(10) },
            monotonicUptimeProvider: { 110 },
            bootIdentifierProvider: { bootIdentifier },
            natPMPRebuildRandomizationProvider: { randomSample },
            rebuildDelayScheduler: { delay, cancelled in
                try expect(!cancelled(), "Boundary delay must not be cancelled")
                delays.append(delay)
            }
        )
        let mappings = [mapping(40), mapping(41)]
        let report = try mapper.refreshMappingEpochs(mappings)
        try expect(
            report.invalidatedMappings == mappings,
            "Every mapping on the restarted NAT-PMP gateway must be invalidated"
        )
        try expect(
            transactionCount == 2 && delays.count == 1,
            "One gateway must be probed serially and delayed exactly once before rebuild"
        )
        return delays
    }

    let zeroBoundary = try runBoundary(0)
    try expect(
        zeroBoundary == [0],
        "The RFC 6886 rebuild delay must support the zero-second boundary"
    )
    let fiveBoundary = try runBoundary(1)
    try expect(
        fiveBoundary == [5],
        "The RFC 6886 rebuild delay must support the five-second boundary"
    )

    let cancelledMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? "192.0.2.40")
            return natPMPExternalAddressResponse(epoch: 1)
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 110 },
        bootIdentifierProvider: { bootIdentifier },
        cancellationHandler: { true },
        natPMPRebuildRandomizationProvider: { 1 },
        rebuildDelayScheduler: { _, cancelled in
            if cancelled() {
                throw RouterMappingError.cancelled
            }
        }
    )
    do {
        _ = try cancelledMapper.refreshMappingEpochs([mapping(42)])
        throw TestFailure("Cancelled NAT-PMP rebuild delay must abort")
    } catch RouterMappingError.cancelled {
        // Expected.
    }

    var pcpDelayCount = 0
    var pcp = mappingFixture(
        transport: .pcp,
        family: .ipv4,
        suffix: 43
    )
    pcp.gatewayAddress = "192.0.2.43"
    pcp.localAddress = "192.0.2.43"
    pcp.routerEpoch = 100
    pcp.routerEpochObservedAt = baseline
    pcp.routerEpochObservedUptime = 100
    pcp.routerEpochBootIdentifier = bootIdentifier
    let pcpMapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, _, sourceAddressHint, payloadBuilder, _ in
            _ = try payloadBuilder(sourceAddressHint ?? pcp.localAddress)
            return pcpAnnounceResponse(epoch: 1)
        },
        nowProvider: { baseline.addingTimeInterval(10) },
        monotonicUptimeProvider: { 110 },
        bootIdentifierProvider: { bootIdentifier },
        rebuildDelayScheduler: { _, _ in pcpDelayCount += 1 }
    )
    _ = try pcpMapper.refreshMappingEpochs([pcp])
    try expect(
        pcpDelayCount == 0,
        "NAT-PMP rebuild delay must not be applied to a solicited PCP health probe"
    )
}

func testTransactionInjectionIgnoresBadDatagramsAndAcceptsLateResponse() throws {
    let config = automaticMappingConfig()
    var transactionCalls = 0
    var mapPayloadBuilds = 0
    let mapper = RouterMappingService(
        udpTransactionHandler: {
            _, _, intervals, sourceAddressHint, payloadBuilder, acceptsResponse in
            transactionCalls += 1
            let payload = try payloadBuilder(sourceAddressHint ?? "192.0.2.20")
            if payload.count == 24 {
                let response = pcpAnnounceResponse()
                let accepted = try acceptsResponse(response)
                try expect(accepted, "ANNOUNCE must match")
                return response
            }

            mapPayloadBuilds += 1
            try expect(intervals.count == 2, "MAP must expose the complete retry budget once")
            let acceptedDamaged = try acceptsResponse(Data([2, 0]))
            try expect(
                !acceptedDamaged,
                "A damaged datagram must be ignored"
            )
            var mismatched = pcpMappingResponse(for: payload)
            mismatched[24] ^= 0xff
            let acceptedMismatched = try acceptsResponse(mismatched)
            try expect(
                !acceptedMismatched,
                "A response for another Mapping Nonce must be ignored"
            )
            let lateResponse = pcpMappingResponse(for: payload)
            let acceptedLate = try acceptsResponse(lateResponse)
            try expect(
                acceptedLate,
                "A late matching response must be accepted within the transaction"
            )
            return lateResponse
        },
        retryRandomizationProvider: { 0 },
        retryPolicy: automaticTestRetryPolicy()
    )

    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(result.activeMapping.transport == .pcp, "Late PCP response must succeed")
    try expect(
        transactionCalls == 2 && mapPayloadBuilds == 1,
        "ANNOUNCE and MAP must each use one transaction/socket-level injection"
    )
}

func testRealUDPTransactionReusesSourcePortAndAcceptsLateResponse() throws {
    let serverFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard serverFD >= 0 else {
        throw TestFailure("Could not create loopback UDP server")
    }
    defer { close(serverFD) }

    var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(
        serverFD,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw TestFailure("Could not set loopback UDP receive timeout")
    }

    var serverAddress = sockaddr_in()
    serverAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    serverAddress.sin_family = sa_family_t(AF_INET)
    serverAddress.sin_port = 0
    guard "127.0.0.1".withCString({
        inet_pton(AF_INET, $0, &serverAddress.sin_addr)
    }) == 1 else {
        throw TestFailure("Could not encode loopback server address")
    }
    let bindStatus = withUnsafePointer(to: &serverAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                serverFD,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard bindStatus == 0 else {
        throw TestFailure(
            "Could not bind loopback UDP server: \(String(cString: strerror(errno)))"
        )
    }

    var boundAddress = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(serverFD, $0, &boundLength)
        }
    }
    guard nameStatus == 0 else {
        throw TestFailure("Could not read loopback UDP server port")
    }
    let serverPort = UInt16(bigEndian: boundAddress.sin_port)

    func receiveDatagram() throws -> (Data, sockaddr_in) {
        var buffer = [UInt8](repeating: 0, count: 2_048)
        var source = sockaddr_in()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(
                        serverFD,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        $0,
                        &sourceLength
                    )
                }
            }
        }
        guard count > 0 else {
            throw TestFailure("Loopback UDP server timed out waiting for a datagram")
        }
        return (Data(buffer.prefix(count)), source)
    }

    func sendDatagram(_ data: Data, to destination: sockaddr_in) throws {
        var destination = destination
        let count = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        serverFD,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard count == data.count else {
            throw TestFailure("Loopback UDP server could not send a complete datagram")
        }
    }

    let serverFinished = DispatchSemaphore(value: 0)
    var serverError: Error?
    var selectedSourceAddress: String?
    var firstMAPSourcePort: in_port_t?
    var secondMAPSourcePort: in_port_t?
    DispatchQueue(label: "GatebeamTests.PCPLoopback").async {
        defer { serverFinished.signal() }
        do {
            let (announce, announceSource) = try receiveDatagram()
            guard announce.count == 24 else {
                throw TestFailure("First PCP datagram must be ANNOUNCE")
            }
            selectedSourceAddress = PCPMessageCodec.addressString(
                Data(announce[8..<24])
            )
            try sendDatagram(pcpAnnounceResponse(), to: announceSource)

            let (firstMAP, firstMAPSource) = try receiveDatagram()
            guard firstMAP.count == 60 else {
                throw TestFailure("Second PCP datagram must be MAP")
            }
            firstMAPSourcePort = firstMAPSource.sin_port
            try sendDatagram(Data([2, 0]), to: firstMAPSource)
            var mismatched = pcpMappingResponse(for: firstMAP)
            mismatched[24] ^= 0xff
            try sendDatagram(mismatched, to: firstMAPSource)

            let (secondMAP, secondMAPSource) = try receiveDatagram()
            secondMAPSourcePort = secondMAPSource.sin_port
            guard secondMAP == firstMAP else {
                throw TestFailure("PCP retransmission must preserve the exact MAP payload")
            }
            try sendDatagram(
                pcpMappingResponse(for: secondMAP),
                to: secondMAPSource
            )
        } catch {
            serverError = error
        }
    }

    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .automatic
    let mapper = RouterMappingService(
        retryRandomizationProvider: { 0 },
        retryPolicy: RouterMappingRetryPolicy(
            pcpMaximumAttempts: 2,
            natPMPMaximumAttempts: 1,
            pcpInitialRetryInterval: 0.05
        ),
        routerControlPort: serverPort
    )
    let result = try mapper.ensureMapping(
        config: config,
        localAddress: "192.0.2.20",
        gatewayAddress: "127.0.0.1"
    )
    guard serverFinished.wait(timeout: .now() + 3) == .success else {
        throw TestFailure("Loopback PCP server did not finish")
    }
    if let serverError {
        throw serverError
    }
    try expect(
        result.activeMapping.transport == .pcp,
        "A late matching PCP response must complete the real transaction"
    )
    try expect(
        selectedSourceAddress == "127.0.0.1",
        "PCP payload must use the source address selected by connect/getsockname"
    )
    try expect(
        result.activeMapping.localAddress == "127.0.0.1"
            && result.activeMapping.routerEpochObservedUptime != nil
            && result.activeMapping.routerEpochBootIdentifier?.isEmpty == false
            && result.activeMapping.routerEpochHealthCheckAfter != nil,
        "The real transport must persist effective identity and complete Epoch clock metadata"
    )
    try expect(
        firstMAPSourcePort != nil && firstMAPSourcePort == secondMAPSourcePort,
        "PCP retransmissions must reuse the same UDP socket and source port"
    )

    let sendStarted = DispatchSemaphore(value: 0)
    let cancelledFinished = DispatchSemaphore(value: 0)
    var cancellationOperations = RouterMappingUDPSocketOperations.system
    cancellationOperations.sendDatagram = { socketFD, bytes, count in
        let result = Darwin.send(socketFD, bytes, count, 0)
        if result == count {
            sendStarted.signal()
        }
        return result
    }
    let cancellationMapper = RouterMappingService(
        retryRandomizationProvider: { 0 },
        retryPolicy: RouterMappingRetryPolicy(
            pcpMaximumAttempts: 9,
            natPMPMaximumAttempts: 9,
            pcpInitialRetryInterval: 3
        ),
        routerControlPort: serverPort,
        socketOperations: cancellationOperations
    )
    config.mappingProtocolPreference = .pcp
    DispatchQueue(label: "GatebeamTests.PCPCancellation").async {
        defer { cancelledFinished.signal() }
        _ = try? cancellationMapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "127.0.0.1"
        )
    }
    guard sendStarted.wait(timeout: .now() + 2) == .success else {
        throw TestFailure("Cancellation test did not enter real send/poll")
    }
    let cancellationStartedAt = ProcessInfo.processInfo.systemUptime
    cancellationMapper.cancelCurrentOperations()
    try expect(
        cancelledFinished.wait(timeout: .now() + 0.75) == .success,
        "Cancellation must interrupt recv/backoff without waiting for PCP RTO"
    )
    try expect(
        ProcessInfo.processInfo.systemUptime - cancellationStartedAt < 0.75,
        "Cancellation must return within the short cooperative bound"
    )
}

func testRealIPv6PCPPayloadUsesConnectedSourceAddress() throws {
    let serverFD = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
    guard serverFD >= 0 else {
        throw TestFailure("Could not create IPv6 loopback UDP server")
    }
    defer { close(serverFD) }

    var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(
        serverFD,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw TestFailure("Could not set IPv6 loopback receive timeout")
    }

    var serverAddress = sockaddr_in6()
    serverAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    serverAddress.sin6_family = sa_family_t(AF_INET6)
    serverAddress.sin6_port = 0
    guard "::1".withCString({
        inet_pton(AF_INET6, $0, &serverAddress.sin6_addr)
    }) == 1 else {
        throw TestFailure("Could not encode IPv6 loopback address")
    }
    let bindStatus = withUnsafePointer(to: &serverAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                serverFD,
                $0,
                socklen_t(MemoryLayout<sockaddr_in6>.size)
            )
        }
    }
    guard bindStatus == 0 else {
        throw TestFailure(
            "Could not bind IPv6 loopback UDP server: "
                + String(cString: strerror(errno))
        )
    }

    var boundAddress = sockaddr_in6()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(serverFD, $0, &boundLength)
        }
    }
    guard nameStatus == 0 else {
        throw TestFailure("Could not read IPv6 loopback UDP server port")
    }
    let serverPort = UInt16(bigEndian: boundAddress.sin6_port)

    let serverFinished = DispatchSemaphore(value: 0)
    var serverError: Error?
    var payloadSourceAddress: String?
    var sourceFamily: sa_family_t?
    var usedIPv4MappedEncoding = false
    DispatchQueue(label: "GatebeamTests.PCPIPv6Loopback").async {
        defer { serverFinished.signal() }
        do {
            var buffer = [UInt8](repeating: 0, count: 2_048)
            var source = sockaddr_in6()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        recvfrom(
                            serverFD,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            $0,
                            &sourceLength
                        )
                    }
                }
            }
            guard count == 60 else {
                throw TestFailure("IPv6 PCP server expected one MAP datagram")
            }
            let request = Data(buffer.prefix(count))
            let addressBytes = Data(request[8..<24])
            payloadSourceAddress = PCPMessageCodec.addressString(addressBytes)
            sourceFamily = source.sin6_family
            usedIPv4MappedEncoding =
                addressBytes[0..<10].allSatisfy { $0 == 0 }
                && addressBytes[10] == 0xff
                && addressBytes[11] == 0xff

            let response = pcpMappingResponse(for: request, epoch: 50)
            let sent = response.withUnsafeBytes { bytes in
                withUnsafePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        sendto(
                            serverFD,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            $0,
                            sourceLength
                        )
                    }
                }
            }
            guard sent == response.count else {
                throw TestFailure("IPv6 PCP server could not send response")
            }
        } catch {
            serverError = error
        }
    }

    var config = automaticMappingConfig()
    config.mappingProtocolPreference = .pcp
    config.preferredAddressFamily = .ipv6
    let mapper = RouterMappingService(
        retryRandomizationProvider: { 0 },
        retryPolicy: RouterMappingRetryPolicy(
            pcpMaximumAttempts: 2,
            natPMPMaximumAttempts: 1,
            pcpInitialRetryInterval: 0.05
        ),
        routerControlPort: serverPort
    )
    let result = try mapper.ensureIPv6Pinhole(
        config: config,
        localAddress: "2001:db8::20",
        gatewayAddress: "::1"
    )
    guard serverFinished.wait(timeout: .now() + 3) == .success else {
        throw TestFailure("IPv6 loopback PCP server did not finish")
    }
    if let serverError {
        throw serverError
    }
    try expect(
        result.activeMapping.transport == .pcp,
        "Real IPv6 PCP MAP must succeed"
    )
    try expect(
        sourceFamily == sa_family_t(AF_INET6),
        "Real PCP datagram must originate from an IPv6 socket"
    )
    try expect(
        payloadSourceAddress == "::1" && !usedIPv4MappedEncoding,
        "PCP payload must contain the native IPv6 source selected by getsockname"
    )
    try expect(
        result.activeMapping.localAddress == "::1",
        "The real IPv6 mapping identity must use the getsockname source"
    )
}

func testIPv6PinholeRenewalPreservesOldIDUnlessExplicitlyMissing() throws {
    let gateway = "192.0.2.1"
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!
    let serviceType = "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1"
    let service = UPnPService(
        serviceType: serviceType,
        controlURL: controlURL,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:gatebeam-renew-router",
        ssdpBootID: "301",
        ssdpConfigID: "13"
    )
    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv6
    config.internalPort = 5900
    config.mappingLeaseSeconds = 3600
    config.ipv6PinholeID = 77

    var timeoutActions: [String] = []
    let timeoutMapper = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            timeoutActions.append(action)
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "UpdatePinhole":
                throw RouterMappingError.timeout("Injected UpdatePinhole timeout")
            default:
                throw TestFailure("Unexpected action after renewal timeout: \(action)")
            }
        }
    )
    do {
        _ = try timeoutMapper.ensureIPv6Pinhole(
            config: config,
            localAddress: "2606:4700:4700::20",
            gatewayAddress: gateway
        )
        throw TestFailure("UpdatePinhole timeout must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            timeoutActions == ["GetFirewallStatus", "UpdatePinhole"],
            "Renewal timeout must not issue AddPinhole"
        )
        try expect(recovery.mapping.pinholeID == 77, "Renewal uncertainty must retain the old pinhole ID")
        try expect(recovery.mapping.gatewayAddress == gateway, "Renewal uncertainty must retain the original gateway")
        try expect(
            recovery.mapping.pcpNonce?.hasPrefix("gatebeam-upnp-v1:") == true,
            "Renewal uncertainty must retain the bound IGD identity"
        )
    }

    var missingActions: [String] = []
    let missingMapper = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            missingActions.append(action)
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "UpdatePinhole":
                return response("""
                <fault>
                  <errorCode>704</errorCode>
                  <errorDescription>NoSuchEntry</errorDescription>
                </fault>
                """, status: 500)
            case "AddPinhole":
                return response("<response><UniqueID>88</UniqueID></response>")
            default:
                throw TestFailure("Unexpected missing-pinhole action: \(action)")
            }
        }
    )
    let replacement = try missingMapper.ensureIPv6Pinhole(
        config: config,
        localAddress: "2606:4700:4700::20",
        gatewayAddress: gateway
    )
    try expect(
        missingActions == ["GetFirewallStatus", "UpdatePinhole", "AddPinhole"],
        "Only explicit 704/NoSuchEntry may create a replacement pinhole"
    )
    try expect(replacement.pinholeID == 88, "Explicitly missing pinhole must track the replacement ID")
    try expect(replacement.activeMapping.pinholeID == 88, "Replacement mapping identity must contain only the new ID")
}

func testTemporaryAccessCapsEveryRouterLease() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let remainingSeconds: UInt32 = 1800
    var base = AppConfig.default
    base.remoteAccessEnabled = true
    base.preferredAddressFamily = .ipv4
    base.internalPort = 5900
    base.externalPort = 45900
    base.mappingLeaseSeconds = 86_400
    base.accessExpiresAt = now.addingTimeInterval(TimeInterval(remainingSeconds))
    base.pcpNonce = Data(repeating: 21, count: 12).base64EncodedString()

    func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    var pcpLease: UInt32?
    var pcpConfig = base
    pcpConfig.mappingProtocolPreference = .pcp
    let pcp = RouterMappingService(
        udpRequestHandler: { payload, _, _, _ in
            pcpLease = uint32(payload, at: 4)
            return pcpMappingResponse(for: payload)
        },
        nowProvider: { now }
    )
    let pcpResult = try pcp.ensureMapping(
        config: pcpConfig,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(pcpLease == remainingSeconds, "PCP lease must not exceed temporary access")
    try expect(
        pcpResult.activeMapping.leaseExpiresAt == base.accessExpiresAt,
        "PCP tracking must use the bounded lease deadline"
    )

    var natLease: UInt32?
    var natConfig = base
    natConfig.mappingProtocolPreference = .natpmp
    let natpmp = RouterMappingService(
        udpRequestHandler: { payload, _, _, _ in
            if payload.count == 2 {
                return Data([0, 128, 0, 0, 0, 0, 0, 1, 192, 0, 0, 9])
            }
            natLease = uint32(payload, at: 8)
            var reply = Data([0, 130, 0, 0, 0, 0, 0, 1])
            reply.append(UInt8(natConfig.internalPort >> 8))
            reply.append(UInt8(natConfig.internalPort & 0xff))
            reply.append(UInt8(natConfig.externalPort >> 8))
            reply.append(UInt8(natConfig.externalPort & 0xff))
            for shift in [24, 16, 8, 0] {
                reply.append(UInt8((remainingSeconds >> UInt32(shift)) & 0xff))
            }
            return reply
        },
        nowProvider: { now }
    )
    let natResult = try natpmp.ensureMapping(
        config: natConfig,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(natLease == remainingSeconds, "NAT-PMP lease must not exceed temporary access")
    try expect(
        natResult.activeMapping.leaseExpiresAt == base.accessExpiresAt,
        "NAT-PMP tracking must use the bounded lease deadline"
    )

    let ipv4Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!,
        gatewayIdentity: "192.0.2.1",
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:lease-router"
    )
    var upnpIPv4Lease: UInt32?
    var upnp4Config = base
    upnp4Config.mappingProtocolPreference = .upnp
    let upnp4 = RouterMappingService(
        upnpDiscoveryHandler: { [ipv4Service] },
        soapRequestHandler: { _, _, action, body in
            switch action {
            case "AddPortMapping":
                try expect(
                    body.contains("<NewLeaseDuration>\(remainingSeconds)</NewLeaseDuration>"),
                    "UPnP IPv4 request must use the temporary-access remainder"
                )
                upnpIPv4Lease = remainingSeconds
                return response("")
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                  <NewLeaseDuration>\(remainingSeconds)</NewLeaseDuration>
                </response>
                """)
            case "GetExternalIPAddress":
                return response("<response><NewExternalIPAddress>192.0.0.9</NewExternalIPAddress></response>")
            default:
                throw TestFailure("Unexpected bounded UPnP IPv4 action \(action)")
            }
        },
        nowProvider: { now }
    )
    let upnp4Result = try upnp4.ensureMapping(
        config: upnp4Config,
        localAddress: "192.0.2.20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(upnpIPv4Lease == remainingSeconds, "UPnP IPv4 lease must be finite and bounded")
    try expect(
        upnp4Result.activeMapping.leaseExpiresAt == base.accessExpiresAt,
        "UPnP IPv4 tracking must use the bounded lease deadline"
    )

    let ipv6Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!,
        gatewayIdentity: "192.0.2.1",
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:lease-router",
        ssdpBootID: "401",
        ssdpConfigID: "17"
    )
    var upnpIPv6Lease: UInt32?
    var upnp6Config = base
    upnp6Config.preferredAddressFamily = .ipv6
    upnp6Config.mappingProtocolPreference = .upnp
    let upnp6 = RouterMappingService(
        upnpDiscoveryHandler: { [ipv6Service] },
        soapRequestHandler: { _, _, action, body in
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "AddPinhole":
                try expect(
                    body.contains("<LeaseTime>\(remainingSeconds)</LeaseTime>"),
                    "UPnP IPv6 request must use the temporary-access remainder"
                )
                upnpIPv6Lease = remainingSeconds
                return response("<response><UniqueID>91</UniqueID></response>")
            default:
                throw TestFailure("Unexpected bounded UPnP IPv6 action \(action)")
            }
        },
        nowProvider: { now }
    )
    let upnp6Result = try upnp6.ensureIPv6Pinhole(
        config: upnp6Config,
        localAddress: "2606:4700:4700::20",
        gatewayAddress: "192.0.2.1"
    )
    try expect(upnpIPv6Lease == remainingSeconds, "UPnP IPv6 lease must be finite and bounded")
    try expect(
        upnp6Result.activeMapping.leaseExpiresAt == base.accessExpiresAt,
        "UPnP IPv6 tracking must use the bounded lease deadline"
    )
}

func testTemporaryAccessRejectsMappingsCompletedPastAbsoluteDeadline() throws {
    let start = Date(timeIntervalSince1970: 2_100_000_000)
    let deadline = start.addingTimeInterval(5)
    let gateway = "192.0.2.1"
    let localIPv4 = "192.0.2.20"
    let localIPv6 = "2606:4700:4700::20"

    func baseConfig(
        family: AddressFamilyPreference,
        preference: MappingProtocolPreference
    ) -> AppConfig {
        var config = AppConfig.default
        config.remoteAccessEnabled = true
        config.preferredAddressFamily = family
        config.mappingProtocolPreference = preference
        config.internalPort = 5900
        config.externalPort = 45900
        config.mappingLeaseSeconds = 3600
        config.accessExpiresAt = deadline
        config.pcpNonce = Data(repeating: 31, count: 12).base64EncodedString()
        return config
    }

    func expectLateMappingIsCompensated(
        _ name: String,
        expectedTransport: RouterMappingTransport,
        expectedFamily: RouterMappingAddressFamily,
        cleanup: () -> [ActiveRouterMapping],
        operation: () throws -> PortMappingResult
    ) throws {
        do {
            _ = try operation()
            throw TestFailure("\(name) must not return a mapping completed after the absolute deadline")
        } catch is RouterMappingRecoveryRequiredError {
            throw TestFailure("\(name) confirmed cleanup must not leave recovery state")
        } catch let failure as TestFailure {
            throw failure
        } catch {
            try expect(
                error.localizedDescription.contains("closed immediately"),
                "\(name) must explain that the late mapping was immediately closed"
            )
        }
        let cleanedMappings = cleanup()
        try expect(cleanedMappings.count == 1, "\(name) must perform exactly one immediate cleanup")
        try expect(
            cleanedMappings[0].transport == expectedTransport
                && cleanedMappings[0].addressFamily == expectedFamily
                && cleanedMappings[0].leaseExpiresAt > deadline,
            "\(name) cleanup must preserve the exact over-deadline mapping identity"
        )
    }

    var pcpNow = start
    var pcpCleanup: [ActiveRouterMapping] = []
    let pcp = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            pcpNow = deadline.addingTimeInterval(1)
            return pcpDeletionResponse(for: request)
        },
        removalHandler: { pcpCleanup.append($0) },
        nowProvider: { pcpNow }
    )
    try expectLateMappingIsCompensated(
        "PCP",
        expectedTransport: .pcp,
        expectedFamily: .ipv4,
        cleanup: { pcpCleanup }
    ) {
        try pcp.ensureMapping(
            config: baseConfig(family: .ipv4, preference: .pcp),
            localAddress: localIPv4,
            gatewayAddress: gateway
        )
    }

    var natNow = start
    var natCleanup: [ActiveRouterMapping] = []
    let natpmp = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            if request == Data([0, 0]) {
                return natPMPExternalAddressResponse(
                    address: [192, 0, 2, 53]
                )
            }
            natNow = deadline.addingTimeInterval(1)
            var reply = natPMPDeletionResponse(for: request)
            reply[12] = request[8]
            reply[13] = request[9]
            reply[14] = request[10]
            reply[15] = request[11]
            return reply
        },
        removalHandler: { natCleanup.append($0) },
        nowProvider: { natNow }
    )
    do {
        _ = try natpmp.ensureMapping(
            config: baseConfig(family: .ipv4, preference: .natpmp),
            localAddress: localIPv4,
            gatewayAddress: gateway
        )
        throw TestFailure("NAT-PMP must not return a mapping completed after the absolute deadline")
    } catch is RouterMappingRecoveryRequiredError {
        throw TestFailure("NAT-PMP confirmed cleanup must not leave recovery state")
    } catch let failure as TestFailure {
        throw failure
    } catch {
        try expect(error.localizedDescription.contains("closed immediately"), "NAT-PMP must report immediate cleanup")
    }
    try expect(
        natCleanup.count == 1
            && natCleanup[0].transport == .natpmp
            && natCleanup[0].leaseExpiresAt > deadline,
        "NAT-PMP must clean the exact over-deadline mapping"
    )

    let ipv4Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:absolute-deadline-router"
    )
    var upnp4Now = start
    var upnp4Cleanup: [ActiveRouterMapping] = []
    let upnp4 = RouterMappingService(
        upnpDiscoveryHandler: { [ipv4Service] },
        soapRequestHandler: { _, _, action, _ in
            switch action {
            case "AddPortMapping":
                upnp4Now = deadline.addingTimeInterval(1)
                return response("")
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>\(localIPv4)</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                  <NewLeaseDuration>5</NewLeaseDuration>
                </response>
                """)
            default:
                throw TestFailure("Unexpected late UPnP IPv4 action \(action)")
            }
        },
        removalHandler: { upnp4Cleanup.append($0) },
        nowProvider: { upnp4Now }
    )
    do {
        _ = try upnp4.ensureMapping(
            config: baseConfig(family: .ipv4, preference: .upnp),
            localAddress: localIPv4,
            gatewayAddress: gateway
        )
        throw TestFailure("UPnP IPv4 must not return a mapping completed after the absolute deadline")
    } catch is RouterMappingRecoveryRequiredError {
        throw TestFailure("UPnP IPv4 confirmed cleanup must not leave recovery state")
    } catch let failure as TestFailure {
        throw failure
    } catch {
        try expect(error.localizedDescription.contains("closed immediately"), "UPnP IPv4 must report immediate cleanup")
    }
    try expect(
        upnp4Cleanup.count == 1
            && upnp4Cleanup[0].transport == .upnp
            && upnp4Cleanup[0].addressFamily == .ipv4,
        "UPnP IPv4 must clean the exact late rule"
    )

    let ipv6Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:absolute-deadline-router",
        ssdpBootID: "501",
        ssdpConfigID: "19"
    )
    var upnp6Now = start
    var upnp6Cleanup: [ActiveRouterMapping] = []
    let upnp6 = RouterMappingService(
        upnpDiscoveryHandler: { [ipv6Service] },
        soapRequestHandler: { _, _, action, _ in
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "AddPinhole":
                upnp6Now = deadline.addingTimeInterval(1)
                return response("<response><UniqueID>99</UniqueID></response>")
            default:
                throw TestFailure("Unexpected late UPnP IPv6 action \(action)")
            }
        },
        removalHandler: { upnp6Cleanup.append($0) },
        nowProvider: { upnp6Now }
    )
    do {
        _ = try upnp6.ensureIPv6Pinhole(
            config: baseConfig(family: .ipv6, preference: .upnp),
            localAddress: localIPv6,
            gatewayAddress: gateway
        )
        throw TestFailure("UPnP IPv6 must not return a pinhole completed after the absolute deadline")
    } catch is RouterMappingRecoveryRequiredError {
        throw TestFailure("UPnP IPv6 confirmed cleanup must not leave recovery state")
    } catch let failure as TestFailure {
        throw failure
    } catch {
        try expect(error.localizedDescription.contains("closed immediately"), "UPnP IPv6 must report immediate cleanup")
    }
    try expect(
        upnp6Cleanup.count == 1
            && upnp6Cleanup[0].transport == .upnp
            && upnp6Cleanup[0].addressFamily == .ipv6
            && upnp6Cleanup[0].pinholeID == 99,
        "UPnP IPv6 must clean the exact late pinhole"
    )

    var failedCleanupNow = start
    let failedCleanup = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            failedCleanupNow = deadline.addingTimeInterval(1)
            return pcpDeletionResponse(for: request)
        },
        removalHandler: { _ in
            throw RouterMappingError.uncertainAfterSend("Injected immediate cleanup response loss")
        },
        nowProvider: { failedCleanupNow }
    )
    do {
        _ = try failedCleanup.ensureMapping(
            config: baseConfig(family: .ipv4, preference: .pcp),
            localAddress: localIPv4,
            gatewayAddress: gateway
        )
        throw TestFailure("An unconfirmed late cleanup must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            recovery.mapping.transport == .pcp
                && recovery.mapping.leaseExpiresAt > deadline
                && recovery.cleanupDescription.contains("Immediate cleanup could not be confirmed"),
            "Late cleanup uncertainty must preserve the exact over-deadline mapping"
        )
    }
}

func testUPnPAddVerificationRequiresExplicitEnabledOne() throws {
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:enabled-contract-router"
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv4
    config.mappingLeaseSeconds = 600
    let description = Data("""
    <root>
      <device>
        <UDN>\(service.deviceIdentity ?? "")</UDN>
        <serviceList>
          <service>
            <serviceType>\(service.serviceType)</serviceType>
            <controlURL>\(service.controlURL.absoluteString)</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """.utf8)

    for variant in [
        (name: "missing", enabled: ""),
        (name: "disabled", enabled: "<NewEnabled>0</NewEnabled>"),
        (name: "invalid", enabled: "<NewEnabled>true</NewEnabled>")
    ] {
        var actions: [String] = []
        let mapper = RouterMappingService(
            upnpDiscoveryHandler: { [service] },
            upnpDescriptionHandler: { _ in description },
            soapRequestHandler: { _, _, action, _ in
                actions.append(action)
                switch action {
                case "AddPortMapping":
                    return response("")
                case "GetSpecificPortMappingEntry":
                    return response("""
                    <response>
                      <NewInternalClient>\(localAddress)</NewInternalClient>
                      <NewInternalPort>5900</NewInternalPort>
                      \(variant.enabled)
                      <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                      <NewLeaseDuration>600</NewLeaseDuration>
                    </response>
                    """)
                default:
                    throw TestFailure("Unexpected \(variant.name) UPnP action \(action)")
                }
            }
        )
        do {
            _ = try mapper.ensureMapping(
                config: config,
                localAddress: localAddress,
                gatewayAddress: gateway
            )
            throw TestFailure("\(variant.name) NewEnabled must fail UPnP creation verification")
        } catch let recovery as RouterMappingRecoveryRequiredError {
            try expect(
                recovery.mapping.transport == .upnp
                    && recovery.operationDescription.contains("verification failed")
                    && recovery.cleanupDescription.contains("Refusing to delete"),
                "\(variant.name) NewEnabled must preserve exact fail-closed recovery state"
            )
        } catch let failure as TestFailure {
            throw failure
        } catch {
            throw TestFailure("\(variant.name) NewEnabled must require recovery after cleanup cannot be verified")
        }
        try expect(
            actions == [
                "AddPortMapping",
                "GetSpecificPortMappingEntry",
                "GetSpecificPortMappingEntry"
            ],
            "\(variant.name) NewEnabled must re-query during immediate cleanup and never issue DeletePortMapping"
        )
    }
}

func testLegacyUPnPReconciliationRequiresExactRuleIdentity() throws {
    let gateway = "192.0.2.1"
    let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let deviceIdentity = "uuid:legacy-router"
    let service = UPnPService(
        serviceType: serviceType,
        controlURL: controlURL,
        gatewayIdentity: gateway,
        descriptionURL: descriptionURL,
        deviceIdentity: deviceIdentity
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .upnp
    config.internalPort = 5900
    config.externalPort = 45900

    var actions: [String] = []
    let reconciler = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        upnpDescriptionHandler: { requestedURL in
            try expect(requestedURL == descriptionURL, "Legacy deletion must verify the reconciled IGD")
            return Data("""
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
        },
        soapRequestHandler: { _, _, action, _ in
            actions.append(action)
            switch action {
            case "GetSpecificPortMappingEntry":
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                  <NewLeaseDuration>600</NewLeaseDuration>
                </response>
                """)
            case "DeletePortMapping":
                return response("")
            default:
                throw TestFailure("Unexpected legacy reconciliation action \(action)")
            }
        }
    )
    let report = reconciler.removeLegacyMappings(
        config: config,
        localIPv4: "192.0.2.20",
        gatewayIPv4: gateway,
        localIPv6: nil,
        gatewayIPv6: nil
    )
    try expect(report.allSucceeded, "A verified legacy UPnP rule must be deleted")
    try expect(report.succeededMappings.count == 1, "A verified legacy UPnP rule must yield one successful deletion")
    try expect(
        report.succeededMappings[0].pcpNonce?.hasPrefix("gatebeam-upnp-v1:") == true,
        "A legacy UPnP deletion must retain bound IGD metadata"
    )
    try expect(
        actions == [
            "GetSpecificPortMappingEntry",
            "GetSpecificPortMappingEntry",
            "DeletePortMapping"
        ],
        "Legacy reconciliation and deletion must each query before the exact delete"
    )

    let mismatch = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, _, _ in
            response("""
            <response>
              <NewInternalClient>192.0.2.99</NewInternalClient>
              <NewInternalPort>5900</NewInternalPort>
              <NewEnabled>1</NewEnabled>
              <NewPortMappingDescription>Other App</NewPortMappingDescription>
            </response>
            """)
        }
    )
    let mismatchReport = mismatch.removeLegacyMappings(
        config: config,
        localIPv4: "192.0.2.20",
        gatewayIPv4: gateway,
        localIPv6: nil,
        gatewayIPv6: nil
    )
    try expect(!mismatchReport.allSucceeded, "A mismatched legacy UPnP rule must fail closed")
    try expect(
        mismatchReport.failureDescription.contains("Refusing to delete"),
        "Legacy mismatch must explain the fail-closed decision"
    )
    try expect(
        mismatchReport.remainingMappings.count == 1,
        "Legacy mismatch must retain a bound recovery identity"
    )
}

func testLegacyAutomaticRemovalUsesStrictProtocolOrder() throws {
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let deviceIdentity = "uuid:automatic-legacy-router"
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
    config.remoteAccessEnabled = true
    config.preferredAddressFamily = .ipv4
    config.mappingProtocolPreference = .automatic
    config.internalPort = 5900
    config.externalPort = 45900
    config.pcpNonce = Data(repeating: 21, count: 12).base64EncodedString()

    func remove(using mapper: RouterMappingService) -> RouterMappingRemovalReport {
        mapper.removeLegacyMappings(
            config: config,
            localIPv4: localAddress,
            gatewayIPv4: gateway,
            localIPv6: nil,
            gatewayIPv6: nil
        )
    }

    var pcpOnlyActions: [String] = []
    var pcpOnlyDiscoveryCount = 0
    let pcpOnly = RouterMappingService(
        upnpDiscoveryHandler: {
            pcpOnlyDiscoveryCount += 1
            return [service]
        },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "GetSpecificPortMappingEntry", "UPnP must only check for a remaining rule")
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                pcpOnlyActions.append("PCP")
                return pcpDeletionResponse(for: request)
            }
            pcpOnlyActions.append("NAT-PMP")
            return natPMPDeletionResponse(for: request)
        }
    )
    let pcpOnlyReport = remove(using: pcpOnly)
    try expect(
        !pcpOnlyReport.allSucceeded,
        "Legacy NAT-PMP without persisted Epoch identity must remain"
    )
    try expect(
        pcpOnlyReport.succeededMappings.map(\.transport) == [.pcp]
            && pcpOnlyReport.remainingMappings.map(\.transport)
                == [.natpmp],
        "Automatic cleanup must retain only the unproven NAT-PMP identity"
    )
    try expect(
        pcpOnlyActions == ["PCP"],
        "Legacy NAT-PMP must not send a delete without Epoch proof"
    )
    try expect(
        pcpOnlyDiscoveryCount == 1,
        "A UDP delete response has no ownership proof, so UPnP must still be checked"
    )

    var natPMPActions: [String] = []
    var natPMPDiscoveryCount = 0
    let natPMPOnly = RouterMappingService(
        upnpDiscoveryHandler: {
            natPMPDiscoveryCount += 1
            return [service]
        },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "GetSpecificPortMappingEntry", "UPnP must only check for a remaining rule")
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                natPMPActions.append("PCP unsupported")
                return pcpDeletionResponse(for: request, resultCode: 4)
            }
            natPMPActions.append("NAT-PMP")
            return natPMPDeletionResponse(for: request)
        }
    )
    let natPMPReport = remove(using: natPMPOnly)
    try expect(
        !natPMPReport.allSucceeded,
        "A legacy NAT-PMP rule without Epoch proof must fail closed"
    )
    try expect(
        natPMPReport.succeededMappings.isEmpty
            && natPMPReport.remainingMappings.map(\.transport)
                == [.natpmp],
        "NAT-PMP-only cleanup must retain the unknown legacy identity"
    )
    try expect(
        natPMPActions == ["PCP unsupported"],
        "Conclusive PCP unsupported must not authorize a NAT-PMP delete"
    )
    try expect(
        natPMPDiscoveryCount == 1,
        "NAT-PMP success must not suppress the independent UPnP ownership check"
    )

    var upnpUDPActions: [String] = []
    var upnpSOAPActions: [String] = []
    let upnpOnly = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        upnpDescriptionHandler: { requestedURL in
            try expect(requestedURL == descriptionURL, "UPnP cleanup must verify the discovered IGD")
            return description
        },
        soapRequestHandler: { requestURL, _, action, body in
            try expect(requestURL == controlURL, "UPnP cleanup must stay on the selected IGD")
            upnpSOAPActions.append(action)
            switch action {
            case "GetSpecificPortMappingEntry":
                try expect(
                    body.contains("<NewExternalPort>45900</NewExternalPort>")
                        && body.contains("<NewProtocol>TCP</NewProtocol>"),
                    "Every UPnP query must select the exact external port and TCP protocol"
                )
                return response("""
                <response>
                  <NewInternalClient>192.0.2.20</NewInternalClient>
                  <NewInternalPort>5900</NewInternalPort>
                  <NewEnabled>1</NewEnabled>
                  <NewPortMappingDescription>Remote Control Network</NewPortMappingDescription>
                </response>
                """)
            case "DeletePortMapping":
                return response("")
            default:
                throw TestFailure("Unexpected legacy UPnP action \(action)")
            }
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                upnpUDPActions.append("PCP unsupported")
                return pcpDeletionResponse(for: request, resultCode: 9)
            }
            upnpUDPActions.append("NAT-PMP unsupported")
            return natPMPDeletionResponse(for: request, resultCode: 5)
        }
    )
    let upnpReport = remove(using: upnpOnly)
    try expect(
        !upnpReport.allSucceeded,
        "Matched UPnP cleanup must not erase unknown NAT-PMP recovery"
    )
    try expect(
        upnpReport.succeededMappings.map(\.transport) == [.upnp]
            && upnpReport.remainingMappings.map(\.transport)
                == [.natpmp],
        "UPnP cleanup must retain only the unproven NAT-PMP identity"
    )
    try expect(
        upnpUDPActions == ["PCP unsupported"],
        "UPnP cleanup must not issue an unproven NAT-PMP delete first"
    )
    try expect(
        upnpSOAPActions == [
            "GetSpecificPortMappingEntry",
            "GetSpecificPortMappingEntry",
            "DeletePortMapping"
        ],
        "UPnP must reconcile, re-query on the bound IGD, then delete"
    )

    var foreignActions: [String] = []
    let foreignRule = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            foreignActions.append(action)
            return response("""
            <response>
              <NewInternalClient>192.0.2.99</NewInternalClient>
              <NewInternalPort>5900</NewInternalPort>
              <NewEnabled>1</NewEnabled>
              <NewPortMappingDescription>Other App</NewPortMappingDescription>
            </response>
            """)
        },
        udpRequestHandler: { request, _, _, _ in
            request.first == 2
                ? pcpDeletionResponse(for: request, resultCode: 4)
                : natPMPDeletionResponse(for: request, resultCode: 5)
        }
    )
    let foreignReport = remove(using: foreignRule)
    try expect(!foreignReport.allSucceeded, "A foreign UPnP rule must make cleanup fail closed")
    try expect(
        foreignReport.remainingMappings.map(\.transport)
            == [.natpmp, .upnp],
        "A foreign UPnP rule must retain both unknown NAT-PMP and bound UPnP recovery identities"
    )
    try expect(
        foreignActions == ["GetSpecificPortMappingEntry"],
        "A foreign UPnP rule must never reach DeletePortMapping"
    )

    var unsupportedActions: [String] = []
    let unsupported = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            unsupportedActions.append(action)
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, _, _, _ in
            request.first == 2
                ? pcpDeletionResponse(for: request, resultCode: 1)
                : natPMPDeletionResponse(for: request, resultCode: 1)
        }
    )
    let unsupportedReport = remove(using: unsupported)
    try expect(
        !unsupportedReport.allSucceeded
            && unsupportedReport.remainingMappings.map(\.transport)
                == [.natpmp],
        "Legacy NAT-PMP without Epoch proof must remain even when PCP is unsupported and UPnP is absent"
    )
    try expect(
        unsupportedActions == ["GetSpecificPortMappingEntry"],
        "A no-entry result must not issue DeletePortMapping"
    )

    var uncertainPCPActions: [String] = []
    var uncertainPCPDiscoveryCount = 0
    let uncertainPCP = RouterMappingService(
        upnpDiscoveryHandler: {
            uncertainPCPDiscoveryCount += 1
            return [service]
        },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "GetSpecificPortMappingEntry", "UPnP must only check for a remaining rule")
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                uncertainPCPActions.append("PCP uncertain")
                throw RouterMappingError.uncertainAfterSend("Injected PCP deletion response loss")
            }
            uncertainPCPActions.append("NAT-PMP")
            return natPMPDeletionResponse(for: request)
        }
    )
    let uncertainPCPReport = remove(using: uncertainPCP)
    try expect(!uncertainPCPReport.allSucceeded, "Uncertain PCP deletion must fail closed")
    try expect(
        uncertainPCPReport.remainingMappings.map(\.transport)
            == [.pcp, .natpmp],
        "Uncertain PCP deletion must also retain unknown legacy NAT-PMP"
    )
    try expect(
        uncertainPCPReport.succeededMappings.isEmpty,
        "Unknown legacy NAT-PMP must not be reported as deleted"
    )
    try expect(
        uncertainPCPActions == ["PCP uncertain"],
        "Uncertain PCP cleanup must not authorize legacy NAT-PMP deletion"
    )
    try expect(uncertainPCPDiscoveryCount == 1, "Uncertain PCP cleanup must not suppress the UPnP ownership check")

    var uncertainNATPMPActions: [String] = []
    var uncertainNATPMPDiscoveryCount = 0
    let uncertainNATPMP = RouterMappingService(
        upnpDiscoveryHandler: {
            uncertainNATPMPDiscoveryCount += 1
            return [service]
        },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "GetSpecificPortMappingEntry", "UPnP must only check for a remaining rule")
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                uncertainNATPMPActions.append("PCP unsupported")
                return pcpDeletionResponse(for: request, resultCode: 4)
            }
            uncertainNATPMPActions.append("NAT-PMP uncertain")
            throw RouterMappingError.uncertainAfterSend("Injected NAT-PMP deletion response loss")
        }
    )
    let uncertainNATPMPReport = remove(using: uncertainNATPMP)
    try expect(!uncertainNATPMPReport.allSucceeded, "Uncertain NAT-PMP deletion must fail closed")
    try expect(
        uncertainNATPMPReport.remainingMappings.map(\.transport) == [.natpmp],
        "Uncertain NAT-PMP deletion must retain only the NAT-PMP recovery identity"
    )
    try expect(
        uncertainNATPMPActions == ["PCP unsupported"],
        "Legacy NAT-PMP must fail before any state-changing request"
    )
    try expect(
        uncertainNATPMPDiscoveryCount == 1,
        "NAT-PMP uncertainty must not suppress the independent UPnP ownership check"
    )

    let allUncertain = RouterMappingService(
        upnpDiscoveryHandler: {
            throw RouterMappingError.timeout("Injected UPnP discovery timeout")
        },
        udpRequestHandler: { request, _, _, _ in
            if request.first == 2 {
                throw RouterMappingError.uncertainAfterSend("Injected PCP deletion response loss")
            }
            throw RouterMappingError.uncertainAfterSend("Injected NAT-PMP deletion response loss")
        }
    )
    let allUncertainReport = remove(using: allUncertain)
    try expect(!allUncertainReport.allSucceeded, "Every uncertain protocol must fail cleanup closed")
    try expect(
        allUncertainReport.remainingMappings.map(\.transport) == [.pcp, .natpmp, .upnp],
        "Automatic cleanup must preserve every exact unresolved protocol without collapsing state"
    )

    var discoveryFailureCalls = 0
    let discoveryFailure = RouterMappingService(
        upnpDiscoveryHandler: {
            discoveryFailureCalls += 1
            throw RouterMappingError.timeout("Injected UPnP discovery timeout")
        },
        udpRequestHandler: { request, _, _, _ in
            request.first == 2
                ? pcpDeletionResponse(for: request, resultCode: 4)
                : natPMPDeletionResponse(for: request, resultCode: 5)
        }
    )
    let discoveryFailureReport = remove(using: discoveryFailure)
    try expect(!discoveryFailureReport.allSucceeded, "UPnP discovery timeout must remain unknown")
    try expect(
        discoveryFailureReport.remainingMappings.map(\.transport)
            == [.natpmp, .upnp],
        "UPnP discovery timeout must retain both NAT-PMP and UPnP recovery identities"
    )
    try expect(discoveryFailureCalls == 1, "UPnP discovery must be attempted exactly once")

    var dualStackActions: [String] = []
    let partialDualStack = RouterMappingService(
        upnpDiscoveryHandler: { [service] },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "GetSpecificPortMappingEntry", "IPv4 UPnP cleanup must only check for a rule")
            return upnpNoSuchEntryResponse()
        },
        udpRequestHandler: { request, host, _, _ in
            if host == gateway, request.first == 2 {
                dualStackActions.append("IPv4 PCP")
                return pcpDeletionResponse(for: request)
            }
            if host == gateway {
                dualStackActions.append("IPv4 NAT-PMP unsupported")
                return natPMPDeletionResponse(for: request, resultCode: 5)
            }
            dualStackActions.append("IPv6 PCP uncertain")
            throw RouterMappingError.uncertainAfterSend(
                "Injected IPv6 PCP deletion response loss"
            )
        }
    )
    var dualStackConfig = config
    dualStackConfig.preferredAddressFamily = .dualStack
    let partialReport = partialDualStack.removeLegacyMappings(
        config: dualStackConfig,
        localIPv4: localAddress,
        gatewayIPv4: gateway,
        localIPv6: "2606:4700:4700::20",
        gatewayIPv6: "fe80::1%en0"
    )
    try expect(!partialReport.allSucceeded, "Partial dual-stack cleanup must fail closed")
    try expect(
        partialReport.succeededMappings.map(\.addressFamily) == [.ipv4],
        "Partial cleanup must retain the confirmed IPv4 deletion"
    )
    try expect(
        partialReport.remainingMappings.map(\.addressFamily)
            == [.ipv4, .ipv6],
        "Partial cleanup must preserve unknown IPv4 NAT-PMP and uncertain IPv6 identities"
    )
    try expect(
        dualStackActions == ["IPv4 PCP", "IPv6 PCP uncertain"],
        "Dual-stack cleanup must skip unproven legacy NAT-PMP deletion"
    )

    var ipv6AutomaticConfig = config
    ipv6AutomaticConfig.preferredAddressFamily = .ipv6
    ipv6AutomaticConfig.ipv6PinholeID = 77
    let ipv6Automatic = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            pcpDeletionResponse(for: request)
        }
    )
    let ipv6AutomaticReport = ipv6Automatic.removeLegacyMappings(
        config: ipv6AutomaticConfig,
        localIPv4: nil,
        gatewayIPv4: nil,
        localIPv6: "2606:4700:4700::20",
        gatewayIPv6: "fe80::1%en0"
    )
    try expect(!ipv6AutomaticReport.allSucceeded, "An unverifiable legacy IPv6 UPnP pinhole must fail closed")
    try expect(
        ipv6AutomaticReport.succeededMappings.map(\.transport) == [.pcp]
            && ipv6AutomaticReport.remainingMappings.map(\.transport) == [.upnp],
        "IPv6 Automatic must retain both the confirmed PCP cleanup and exact UPnP manual-recovery identity"
    )
}

func testUPnPUncertainAddRecoveryQueriesBeforeDelete() throws {
    let gateway = "192.0.2.1"
    let localAddress = "192.0.2.20"
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"
    let deviceIdentity = "uuid:uncertain-add-router"
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
            try expect(action == "AddPortMapping", "The fixture must lose only the Add response")
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
        throw TestFailure("Uncertain AddPortMapping must require recovery")
    } catch let captured as RouterMappingRecoveryRequiredError {
        recovery = captured
    }

    var foreignActions: [String] = []
    let foreignRemover = RouterMappingService(
        upnpDescriptionHandler: { _ in description },
        soapRequestHandler: { _, _, action, body in
            foreignActions.append(action)
            try expect(
                body.contains("<NewExternalPort>45900</NewExternalPort>")
                    && body.contains("<NewProtocol>TCP</NewProtocol>"),
                "Recovery must query the exact external port and protocol"
            )
            return response("""
            <response>
              <NewInternalClient>192.0.2.99</NewInternalClient>
              <NewInternalPort>5900</NewInternalPort>
              <NewEnabled>1</NewEnabled>
              <NewPortMappingDescription>Other App</NewPortMappingDescription>
            </response>
            """)
        }
    )
    let foreignReport = foreignRemover.removeMappings([recovery.mapping])
    try expect(!foreignReport.allSucceeded, "A foreign rule must keep uncertain Add recovery unresolved")
    try expect(
        foreignActions == ["GetSpecificPortMappingEntry"],
        "A foreign rule must stop recovery before DeletePortMapping"
    )

    let enabledVariants: [(name: String, element: String, mayDelete: Bool)] = [
        ("missing", "", false),
        ("disabled", "<NewEnabled>0</NewEnabled>", false),
        ("invalid", "<NewEnabled>yes</NewEnabled>", false),
        ("enabled", "<NewEnabled> \n 1 \t</NewEnabled>", true)
    ]
    for variant in enabledVariants {
        var actions: [String] = []
        let remover = RouterMappingService(
            upnpDescriptionHandler: { _ in description },
            soapRequestHandler: { _, _, action, _ in
                actions.append(action)
                switch action {
                case "GetSpecificPortMappingEntry":
                    return response("""
                    <response>
                      <NewExternalPort>45900</NewExternalPort>
                      <NewProtocol>TCP</NewProtocol>
                      <NewInternalClient>192.0.2.20</NewInternalClient>
                      <NewInternalPort>5900</NewInternalPort>
                      \(variant.element)
                      <NewPortMappingDescription>Gatebeam</NewPortMappingDescription>
                    </response>
                    """)
                case "DeletePortMapping":
                    return response("")
                default:
                    throw TestFailure("Unexpected \(variant.name) recovery action \(action)")
                }
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
            "\(variant.name) NewEnabled must follow the fail-closed recovery action contract"
        )
    }

    var timeoutActions: [String] = []
    let timeoutRemover = RouterMappingService(
        upnpDescriptionHandler: { _ in description },
        soapRequestHandler: { _, _, action, _ in
            timeoutActions.append(action)
            throw RouterMappingError.timeout("Injected recovery query timeout")
        }
    )
    let timeoutReport = timeoutRemover.removeMappings([recovery.mapping])
    try expect(!timeoutReport.allSucceeded, "An unconfirmed recovery query must fail closed")
    try expect(
        timeoutActions == ["GetSpecificPortMappingEntry"],
        "An unconfirmed recovery query must never issue DeletePortMapping"
    )
}

func testUPnPAddResponseLossPreservesFiniteRecoveryState() throws {
    var now = Date(timeIntervalSince1970: 2_000_100_000)
    var uptime: TimeInterval = 100
    let bootIdentifier = "upnp-response-loss-boot"
    let gateway = "192.0.2.1"
    let ipv4Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/WANIPConn1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:response-loss-router"
    )
    var config = AppConfig.default
    config.remoteAccessEnabled = true
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv4
    config.mappingLeaseSeconds = 3600
    config.accessExpiresAt = now.addingTimeInterval(900)

    let ipv4Mapper = RouterMappingService(
        upnpDiscoveryHandler: { [ipv4Service] },
        soapRequestHandler: { _, _, action, _ in
            try expect(action == "AddPortMapping", "Response-loss fixture must stop after AddPortMapping")
            throw RouterMappingError.timeout("Injected AddPortMapping response loss")
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    do {
        _ = try ipv4Mapper.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: gateway
        )
        throw TestFailure("AddPortMapping response loss must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(recovery.mapping.addressFamily == .ipv4, "IPv4 response loss must retain family")
        try expect(recovery.mapping.externalPort == config.externalPort, "IPv4 response loss must retain exact port")
        try expect(
            recovery.mapping.pcpNonce?.hasPrefix("gatebeam-upnp-v1:") == true,
            "IPv4 response loss must retain exact IGD identity"
        )
        try expect(
            recovery.mapping.leaseExpiresAt == config.accessExpiresAt,
            "IPv4 uncertain exposure must remain bounded by temporary access"
        )
    }

    let ipv6Service = UPnPService(
        serviceType: "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1",
        controlURL: URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!,
        gatewayIdentity: gateway,
        descriptionURL: URL(string: "http://192.0.2.1:5000/rootDesc.xml")!,
        deviceIdentity: "uuid:response-loss-router",
        ssdpBootID: "601",
        ssdpConfigID: "23"
    )
    var ipv6Config = config
    ipv6Config.preferredAddressFamily = .ipv6
    let ipv6Mapper = RouterMappingService(
        upnpDiscoveryHandler: { [ipv6Service] },
        soapRequestHandler: { _, _, action, _ in
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "AddPinhole":
                return response("<response></response>")
            default:
                throw TestFailure("Unexpected IPv6 response-loss action \(action)")
            }
        },
        nowProvider: { now },
        monotonicUptimeProvider: { uptime },
        bootIdentifierProvider: { bootIdentifier }
    )
    let unknownExposure: ActiveRouterMapping
    do {
        _ = try ipv6Mapper.ensureIPv6Pinhole(
            config: ipv6Config,
            localAddress: "2606:4700:4700::20",
            gatewayAddress: gateway
        )
        throw TestFailure("Missing AddPinhole UniqueID must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        unknownExposure = recovery.mapping
        try expect(unknownExposure.pinholeID == nil, "Unknown IPv6 exposure must not invent a pinhole ID")
        try expect(
            unknownExposure.leaseExpiresAt == ipv6Config.accessExpiresAt,
            "Unknown IPv6 exposure must retain its finite lease deadline"
        )
    }
    try expect(
        !ipv6Mapper.removeMappings([unknownExposure]).allSucceeded,
        "Unknown IPv6 exposure must block cleanup completion before its lease expires"
    )
    now = unknownExposure.leaseExpiresAt.addingTimeInterval(1)
    uptime = (unknownExposure.leaseExpiresUptime ?? uptime) + 1
    try expect(
        ipv6Mapper.removeMappings([unknownExposure]).allSucceeded,
        "Unknown IPv6 exposure must clear idempotently after its finite lease expires"
    )
}

func testIPv6ScopedSSDPAllowsSameUDNDualStackControlURL() throws {
    let gateway = "fe80::1%en0"
    let descriptionURL = URL(string: "http://192.0.2.1:5000/rootDesc.xml")!
    let controlURL = URL(string: "http://192.0.2.1:5000/upnp/control/IPv6Firewall1")!
    let deviceIdentity = "uuid:dual-stack-igd"
    let serviceType = "urn:schemas-upnp-org:service:WANIPv6FirewallControl:1"
    let bootIDHeader = ["BOOTID", "UPNP", "ORG"].joined(
        separator: "."
    )
    let configIDHeader = ["CONFIGID", "UPNP", "ORG"].joined(
        separator: "."
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
    var searches: [UPnPDiscoveryRequest] = []
    var actions: [String] = []
    let mapper = RouterMappingService(
        upnpDescriptionHandler: { requestedURL in
            try expect(requestedURL == descriptionURL, "IPv6 SSDP must use the advertised LOCATION")
            return description
        },
        soapRequestHandler: { requestedURL, _, action, _ in
            try expect(requestedURL == controlURL, "Same-UDN dual-stack control must use the advertised IPv4 URL")
            actions.append(action)
            switch action {
            case "GetFirewallStatus":
                return response("""
                <response>
                  <FirewallEnabled>1</FirewallEnabled>
                  <InboundPinholeAllowed>1</InboundPinholeAllowed>
                </response>
                """)
            case "AddPinhole":
                return response("<response><UniqueID>77</UniqueID></response>")
            case "UpdatePinhole":
                return response("")
            case "DeletePinhole":
                return response("")
            default:
                throw TestFailure("Unexpected IPv6 SSDP action \(action)")
            }
        },
        ssdpSearchHandler: { request in
            searches.append(request)
            return [Data("""
            HTTP/1.1 200 OK\r
            LOCATION: \(descriptionURL.absoluteString)\r
            USN: \(deviceIdentity)::urn:schemas-upnp-org:device:InternetGatewayDevice:2\r
            \(bootIDHeader): 701\r
            \(configIDHeader): 29\r
            ST: \(serviceType)\r
            \r
            """.utf8)]
        }
    )
    var config = AppConfig.default
    config.mappingProtocolPreference = .upnp
    config.preferredAddressFamily = .ipv6
    config.mappingLeaseSeconds = 600
    let result = try mapper.ensureIPv6Pinhole(
        config: config,
        localAddress: "2606:4700:4700::20",
        gatewayAddress: gateway
    )
    config.ipv6PinholeID = result.pinholeID
    try expect(searches.count == 1, "IPv6 pinhole creation must perform one scoped SSDP search")
    try expect(searches[0].addressFamily == .ipv6, "IPv6 firewall discovery must use an IPv6 socket")
    try expect(searches[0].host.lowercased() == "ff02::c", "IPv6 SSDP must target FF02::C")
    try expect(searches[0].interfaceName == "en0", "IPv6 SSDP must bind the default gateway scope")
    try expect(
        searches[0].payloads.allSatisfy {
            String(data: $0, encoding: .utf8)?.contains("HOST: [FF02::C]:1900") == true
        },
        "Every IPv6 SSDP request must carry the scoped multicast Host header"
    )
    let renewed = try mapper.renewMapping(
        config: config,
        mapping: result.activeMapping
    )
    try expect(
        renewed.pinholeID == result.pinholeID,
        "Matching SSDP BOOTID/CONFIGID must permit an ID-only UpdatePinhole"
    )
    try expect(
        mapper.removeMappings([result.activeMapping]).allSucceeded,
        "A same-UDN dual-stack control URL must remain bound for exact deletion"
    )
    try expect(
        searches.count == 3,
        "IPv6 ID-only renewal and deletion must each rediscover the persisted SSDP identity"
    )
    try expect(
        actions == [
            "GetFirewallStatus",
            "AddPinhole",
            "GetFirewallStatus",
            "UpdatePinhole",
            "DeletePinhole"
        ],
        "IPv6 lifecycle actions must stay ordered"
    )

    func ssdpResponse(
        bootID: String?,
        configID: String?
    ) -> Data {
        let bootHeader = bootID.map {
            "\(bootIDHeader): \($0)\r\n"
        } ?? ""
        let configHeader = configID.map {
            "\(configIDHeader): \($0)\r\n"
        } ?? ""
        return Data("""
        HTTP/1.1 200 OK\r
        LOCATION: \(descriptionURL.absoluteString)\r
        USN: \(deviceIdentity)::urn:schemas-upnp-org:device:InternetGatewayDevice:2\r
        \(bootHeader)\(configHeader)ST: \(serviceType)\r
        \r
        """.utf8)
    }

    let changedIdentities: [
        (name: String, bootID: String?, configID: String?)
    ] = [
        ("changed BOOTID", "702", "29"),
        ("changed CONFIGID", "701", "30"),
        ("missing BOOTID", nil, "29"),
        ("missing CONFIGID", "701", nil)
    ]
    for identity in changedIdentities {
        var unsafeSOAPCalls = 0
        let changed = RouterMappingService(
            upnpDescriptionHandler: { _ in description },
            soapRequestHandler: { _, _, _, _ in
                unsafeSOAPCalls += 1
                return response("")
            },
            ssdpSearchHandler: { _ in
                [
                    ssdpResponse(
                        bootID: identity.bootID,
                        configID: identity.configID
                    )
                ]
            }
        )
        do {
            _ = try changed.renewMapping(
                config: config,
                mapping: result.activeMapping
            )
            throw TestFailure(
                "\(identity.name) must block ID-only UpdatePinhole"
            )
        } catch is RouterMappingRecoveryRequiredError {
            // Expected: preserve the original finite recovery identity.
        }
        let report = changed.removeMappings(
            [result.activeMapping]
        )
        try expect(
            !report.allSucceeded
                && report.remainingMappings == [result.activeMapping],
            "\(identity.name) must retain IPv6 pinhole recovery until finite lease expiry"
        )
        try expect(
            unsafeSOAPCalls == 0,
            "\(identity.name) must block ID-only DeletePinhole"
        )
    }

    func ssdpPacket(
        location: URL = descriptionURL,
        identity: String = deviceIdentity,
        bootIDs: [String] = ["701"],
        configIDs: [String] = ["29"]
    ) -> Data {
        var lines = [
            "HTTP/1.1 200 OK",
            "LOCATION: \(location.absoluteString)",
            "USN: \(identity)::urn:schemas-upnp-org:device:InternetGatewayDevice:2"
        ]
        lines.append(contentsOf: bootIDs.map {
            "\(bootIDHeader): \($0)"
        })
        lines.append(contentsOf: configIDs.map {
            "\(configIDHeader): \($0)"
        })
        lines.append("ST: \(serviceType)")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func expectIdentityConflict(
        _ name: String,
        responses: [Data],
        descriptionData: Data = description
    ) throws {
        var unsafeSOAPCalls = 0
        let conflicting = RouterMappingService(
            upnpDescriptionHandler: { _ in
                descriptionData
            },
            soapRequestHandler: { _, _, _, _ in
                unsafeSOAPCalls += 1
                return response("")
            },
            ssdpSearchHandler: { _ in responses }
        )
        do {
            _ = try conflicting.renewMapping(
                config: config,
                mapping: result.activeMapping
            )
            throw TestFailure(
                "\(name) must block ID-only UpdatePinhole"
            )
        } catch is RouterMappingRecoveryRequiredError {
            // Expected.
        }
        let removal = conflicting.removeMappings(
            [result.activeMapping]
        )
        try expect(
            !removal.allSucceeded
                && removal.remainingMappings
                    == [result.activeMapping],
            "\(name) must retain finite IPv6 recovery state"
        )
        try expect(
            unsafeSOAPCalls == 0,
            "\(name) must block both UpdatePinhole and DeletePinhole"
        )
    }

    let alternateDescriptionURL = URL(
        string: "http://192.0.2.2:5000/rootDesc.xml"
    )!
    try expectIdentityConflict(
        "Same normalized UDN with multiple LOCATION values",
        responses: [
            ssdpPacket(),
            ssdpPacket(
                location: alternateDescriptionURL,
                identity: "UUID:DUAL-STACK-IGD"
            )
        ]
    )
    try expectIdentityConflict(
        "Same normalized UDN with multiple BOOTID values",
        responses: [
            ssdpPacket(),
            ssdpPacket(
                identity: "UUID:DUAL-STACK-IGD",
                bootIDs: ["702"]
            )
        ]
    )
    try expectIdentityConflict(
        "Same normalized UDN with multiple CONFIGID values",
        responses: [
            ssdpPacket(),
            ssdpPacket(
                identity: "UUID:DUAL-STACK-IGD",
                configIDs: ["30"]
            )
        ]
    )
    try expectIdentityConflict(
        "Conflicting duplicate SSDP identity header",
        responses: [
            ssdpPacket(bootIDs: ["701", "702"])
        ]
    )
    let conflictingStaticDescription = Data("""
    <root>
      <device>
        <UDN>\(deviceIdentity)</UDN>
        <serviceList>
          <service>
            <serviceType>\(serviceType)</serviceType>
            <controlURL>\(controlURL.absoluteString)</controlURL>
          </service>
          <service>
            <serviceType>\(serviceType)</serviceType>
            <controlURL>http://192.0.2.1:5000/upnp/control/replacement</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """.utf8)
    try expectIdentityConflict(
        "Same normalized UDN with conflicting static control endpoints",
        responses: [ssdpPacket()],
        descriptionData: conflictingStaticDescription
    )

    var legacy = result.activeMapping
    legacy.pcpNonce = try encodedUPnPBindingFixture(
        service: UPnPService(
            serviceType: serviceType,
            controlURL: controlURL,
            gatewayIdentity: gateway,
            descriptionURL: descriptionURL,
            deviceIdentity: deviceIdentity,
            allowsCrossFamilyControl: true
        ),
        gateway: gateway
    )
    var legacyDiscoveryCalls = 0
    var legacySOAPCalls = 0
    let legacyRemover = RouterMappingService(
        upnpDescriptionHandler: { _ in description },
        soapRequestHandler: { _, _, _, _ in
            legacySOAPCalls += 1
            return response("")
        },
        ssdpSearchHandler: { _ in
            legacyDiscoveryCalls += 1
            return [
                ssdpResponse(
                    bootID: "701",
                    configID: "29"
                )
            ]
        }
    )
    let legacyReport = legacyRemover.removeMappings([legacy])
    try expect(
        !legacyReport.allSucceeded
            && legacyReport.remainingMappings == [legacy],
        "A legacy IPv6 binding without SSDP IDs must migrate conservatively"
    )
    try expect(
        legacyDiscoveryCalls == 0 && legacySOAPCalls == 0,
        "Legacy missing metadata must fail before SSDP or ID-only SOAP"
    )
}

func testPCPMapCodec() throws {
    let nonce = Data(0..<12)
    let request = try PCPMessageCodec.makeMapRequest(
        lifetime: 3600,
        clientAddress: "192.168.1.24",
        nonce: nonce,
        internalPort: 5900,
        suggestedExternalPort: 45900
    )
    try expect(request.count == 60, "PCP MAP request must be 60 bytes")
    try expect(request[0] == 2 && request[1] == 1, "PCP request must use version 2 and MAP opcode")
    try expect(Array(request[18..<20]) == [0xff, 0xff], "IPv4 PCP client address must be IPv4-mapped IPv6")
    try expect(Data(request[24..<36]) == nonce, "PCP MAP nonce must occupy bytes 24 through 35")

    var responseData = request
    responseData[1] = 0x81
    responseData.replaceSubrange(44..<60, with: try PCPMessageCodec.addressBytes("203.0.113.42"))
    let parsed = try PCPMessageCodec.parseMapResponse(
        responseData,
        nonce: nonce,
        internalPort: 5900,
        requestedLifetime: 3600
    )
    try expect(parsed.externalPort == 45900, "PCP response should preserve the assigned external port")
    try expect(parsed.lifetimeSeconds == 3600, "PCP response should preserve the assigned lifetime")
    try expect(parsed.externalAddress == "203.0.113.42", "PCP should decode an IPv4-mapped external address")

    let ipv6 = "2001:db8:1234::24"
    let roundTrip = PCPMessageCodec.addressString(try PCPMessageCodec.addressBytes(ipv6))
    try expect(roundTrip == ipv6, "PCP should round-trip a native IPv6 address")
}

func testLocalIPv6SelectionUsesAnonymousFixtures() throws {
    let candidates = [
        LocalIPv6Candidate(interfaceName: "utun7", address: "2606:4700:7::7", attributes: ["secured"]),
        LocalIPv6Candidate(interfaceName: "en0", address: "2606:4700:1::10", attributes: ["secured"]),
        LocalIPv6Candidate(interfaceName: "en1", address: "2606:4700:2::20", attributes: ["temporary"]),
        LocalIPv6Candidate(interfaceName: "en2", address: "fd00::10", attributes: []),
        LocalIPv6Candidate(interfaceName: "en3", address: "fe80::10", attributes: [])
    ]

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "utun7"
    )
    try expect(selected == "2606:4700:1::10", "Physical global IPv6 must beat a tunnel route and non-global addresses")
}

func testLocalIPv6SelectionPrefersDefaultPhysicalRoute() throws {
    let candidates = [
        LocalIPv6Candidate(interfaceName: "en0", address: "2606:4700:1::10", attributes: ["secured"]),
        LocalIPv6Candidate(interfaceName: "en1", address: "2606:4700:2::20", attributes: ["secured"])
    ]

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "en1"
    )
    try expect(selected == "2606:4700:2::20", "The default physical IPv6 route must win among global candidates")
}

func testLocalIPv6SelectionRejectsOnlyULAAndLinkLocalFixtures() throws {
    let candidates = [
        LocalIPv6Candidate(interfaceName: "en0", address: "fd00::10", attributes: ["secured"]),
        LocalIPv6Candidate(interfaceName: "en1", address: "fe80::20", attributes: ["secured"])
    ]

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "en0"
    )
    try expect(selected == nil, "ULA and link-local fixtures must never be selected as public IPv6")
}

func testParsesIPv6AttributesFromFixedIfconfigFixture() throws {
    let ifconfigOutput = """
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet6 fe80::aede:48ff:fe00:1122%en0 prefixlen 64 secured scopeid 0x6
        inet6 2606:4700:42:0:ABCD:0:0:10 prefixlen 64 autoconf secured
        inet6 2606:4700:42::20%en0 prefixlen 64 autoconf temporary
        inet6 2606:4700:42::30 prefixlen 64 deprecated autoconf temporary
        inet6 2606:4700:42::40 prefixlen 64 detached autoconf
    """

    let stable = LocalNetworkService.interfaceAddressAttributes(
        in: ifconfigOutput,
        address: "2606:4700:42::abcd:0:0:10"
    )
    try expect(stable.contains("autoconf"), "Stable autoconf attribute should be parsed")
    try expect(stable.contains("secured"), "Stable secured attribute should be parsed")
    try expect(!stable.contains("temporary"), "Stable address must not inherit another inet6 line's attributes")

    let temporary = LocalNetworkService.interfaceAddressAttributes(
        in: ifconfigOutput,
        address: "2606:4700:42::20"
    )
    try expect(temporary.contains("temporary"), "Scoped temporary address should match its unscoped candidate")
    try expect(temporary.contains("autoconf"), "Temporary autoconf attribute should be parsed")

    let deprecated = LocalNetworkService.interfaceAddressAttributes(
        in: ifconfigOutput,
        address: "2606:4700:42::30"
    )
    try expect(deprecated.contains("deprecated"), "Deprecated attribute should be parsed")

    let detached = LocalNetworkService.interfaceAddressAttributes(
        in: ifconfigOutput,
        address: "2606:4700:42::40"
    )
    try expect(detached.contains("detached"), "Detached attribute should be parsed")

    let missing = LocalNetworkService.interfaceAddressAttributes(
        in: ifconfigOutput,
        address: "2606:4700:42::99"
    )
    try expect(missing.isEmpty, "Unknown address must not inherit interface-level attributes")
}

func testLocalIPv6SelectionPrefersStableFixedIfconfigCandidate() throws {
    let ifconfigOutput = """
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet6 2606:4700:10::10 prefixlen 64 autoconf secured
    en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet6 2606:4700:20::20%en1 prefixlen 64 autoconf temporary
        inet6 2606:4700:20::30 prefixlen 64 deprecated autoconf
        inet6 2606:4700:20::40 prefixlen 64 detached autoconf
    utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
        inet6 2606:4700:70::70 prefixlen 64 secured
    """
    let addresses = [
        ("en0", "2606:4700:10::10"),
        ("en1", "2606:4700:20::20"),
        ("en1", "2606:4700:20::30"),
        ("en1", "2606:4700:20::40"),
        ("utun7", "2606:4700:70::70"),
        ("en2", "fd12:3456::10"),
        ("en3", "fe80::10")
    ]
    let candidates = addresses.map { interfaceName, address in
        LocalIPv6Candidate(
            interfaceName: interfaceName,
            address: address,
            attributes: LocalNetworkService.interfaceAddressAttributes(in: ifconfigOutput, address: address)
        )
    }

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "en1"
    )
    try expect(
        selected == "2606:4700:10::10",
        "Stable physical IPv6 must beat a temporary default-route address, unusable addresses, and a tunnel"
    )
}

func testLocalIPv6SelectionRejectsTemporaryAddress() throws {
    let candidates = [
        LocalIPv6Candidate(interfaceName: "en0", address: "2606:4700:1::10", attributes: ["deprecated"]),
        LocalIPv6Candidate(interfaceName: "en0", address: "2606:4700:1::20", attributes: ["detached"]),
        LocalIPv6Candidate(interfaceName: "en0", address: "2606:4700:1::30", attributes: ["autoconf", "temporary"])
    ]

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "en0"
    )
    try expect(selected == nil, "DDNS must not publish a temporary IPv6 address when no stable address exists")
}

func testLocalIPv6SelectionRejectsTunnelOnlyIfconfigFixture() throws {
    let ifconfigOutput = """
    utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
        inet6 2606:4700:70::70 prefixlen 64 secured
    tun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
        inet6 2606:4700:71::71 prefixlen 64 autoconf secured
    tap0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet6 2606:4700:72::72 prefixlen 64 secured
    ipsec0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400
        inet6 2606:4700:73::73 prefixlen 64 secured
    ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1492
        inet6 2606:4700:74::74 prefixlen 64 secured
    """
    let addresses = [
        ("utun7", "2606:4700:70::70"),
        ("tun0", "2606:4700:71::71"),
        ("tap0", "2606:4700:72::72"),
        ("ipsec0", "2606:4700:73::73"),
        ("ppp0", "2606:4700:74::74")
    ]
    let candidates = addresses.map { interfaceName, address in
        LocalIPv6Candidate(
            interfaceName: interfaceName,
            address: address,
            attributes: LocalNetworkService.interfaceAddressAttributes(in: ifconfigOutput, address: address)
        )
    }

    let selected = LocalNetworkService.selectGlobalIPv6Address(
        candidates: candidates,
        routeInterface: "utun7"
    )
    try expect(selected == nil, "Tunnel-only global IPv6 fixtures must never produce a DDNS AAAA candidate")
    for (interfaceName, _) in addresses {
        try expect(
            !LocalNetworkService.isAllowedDDNSIPv6Interface(interfaceName),
            "\(interfaceName) must remain ineligible even when it is the only default-route candidate"
        )
    }
}

func testOlderConfigDecodesWithoutIPv6State() throws {
    let encoded = try JSONEncoder().encode(AppConfig.default)
    var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    object.removeValue(forKey: "ipv6PinholeID")
    object.removeValue(forKey: "pcpNonce")
    object.removeValue(forKey: "activeRouterMappings")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
    try expect(decoded.ipv6PinholeID == nil, "Older configs should default the IPv6 pinhole ID to nil")
    try expect(decoded.pcpNonce == nil, "Older configs should default the PCP nonce to nil")
    try expect(decoded.activeRouterMappings.isEmpty, "Older configs should default tracked router mappings to an empty list")
}

func testReportsCloudflareDNSPermissionGuidanceWithoutResponseSecrets() throws {
    let mock = MockHTTPClient(responses: [
        response(
            #"{"success":false,"errors":[{"code":9109,"message":"secret-marker"}],"result":null}"#,
            status: 403
        )
    ])
    let provider = CloudflareDNSProvider(http: mock)

    do {
        _ = try provider.upsertARecord(
            zoneID: "0123456789abcdef0123456789abcdef",
            recordName: "mac.example.com",
            ipAddress: "192.0.0.9",
            token: "bad-token"
        )
        throw TestFailure("A denied DNS-record request should fail")
    } catch let error as CloudflareError {
        try expect(
            error.localizedDescription == CloudflarePermissionGuidance.dnsWriteDenied,
            "A DNS-record 403 must explain the exact target-zone permissions"
        )
        try expect(
            !error.localizedDescription.contains("secret-marker"),
            "A DNS-record 403 must not expose response-body details"
        )
    }
}

func testReportsCloudflareCreatePermissionGuidance() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[]}"#),
        response(
            #"{"success":false,"errors":[{"code":10000,"message":"secret-create-marker"}],"result":null}"#,
            status: 403
        )
    ])
    let provider = CloudflareDNSProvider(http: mock)

    do {
        _ = try provider.upsertARecord(
            zoneID: "0123456789abcdef0123456789abcdef",
            recordName: "mac.example.com",
            ipAddress: "192.0.0.9",
            token: "under-scoped-token"
        )
        throw TestFailure("A denied first DNS write should fail")
    } catch let error as CloudflareError {
        try expect(
            error.localizedDescription == CloudflarePermissionGuidance.dnsWriteDenied,
            "The first denied DNS write must request Zone/DNS/Edit and Zone/Zone/Read"
        )
        try expect(
            !error.localizedDescription.contains("secret-create-marker"),
            "The first denied DNS write must not expose the Cloudflare response body"
        )
    }
}

private let cloudflareTokenPrefix = "cf" + "ut_"
private let cloudflareResponseToken = cloudflareTokenPrefix + "RESPONSE_SECRET_123"
private let cloudflareTransportToken = cloudflareTokenPrefix + "TRANSPORT_SECRET"

private let cloudflareSecretFragments = [
    cloudflareResponseToken,
    "Authorization: Bearer response-secret",
    "proxy-user:proxy-password",
    "<html>private gateway response</html>",
    "9109: server-controlled-message"
]

private func cloudflareErrorFixture(
    operation: CloudflareOperation,
    body: String,
    status: Int
) throws -> CloudflareError {
    let secretHeaders: [AnyHashable: Any] = [
        "Authorization": "Bearer cfut_HEADER_SECRET",
        "Proxy-Authorization": "Basic proxy-password",
        "X-Debug-Secret": "header-secret"
    ]
    let failing = response(body, status: status, headers: secretHeaders)
    let verifySuccess = response(
        #"{"success":true,"errors":[],"result":{"id":"token-1","status":"active"}}"#
    )
    let emptyRecords = response(#"{"success":true,"errors":[],"result":[]}"#)
    let existingRecord = response(
        #"{"success":true,"errors":[],"result":[{"id":"record-1","type":"A","name":"mac.example.com","content":"192.0.0.10","ttl":120,"proxied":false}]}"#
    )
    let provider: CloudflareDNSProvider

    do {
        switch operation {
        case .verifyToken:
            provider = CloudflareDNSProvider(http: MockHTTPClient(responses: [failing]))
            _ = try provider.listZones(token: "request-token")
        case .listZones:
            provider = CloudflareDNSProvider(
                http: MockHTTPClient(responses: [verifySuccess, failing])
            )
            _ = try provider.listZones(token: "request-token")
        case .readZone:
            provider = CloudflareDNSProvider(
                http: MockHTTPClient(responses: [verifySuccess, failing])
            )
            _ = try provider.validateConfiguration(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                token: "request-token"
            )
        case .listDNSRecords:
            provider = CloudflareDNSProvider(http: MockHTTPClient(responses: [failing]))
            _ = try provider.upsertARecord(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                ipAddress: "192.0.0.9",
                token: "request-token"
            )
        case .createDNSRecord:
            provider = CloudflareDNSProvider(
                http: MockHTTPClient(responses: [emptyRecords, failing])
            )
            _ = try provider.upsertARecord(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                ipAddress: "192.0.0.9",
                token: "request-token"
            )
        case .updateDNSRecord:
            provider = CloudflareDNSProvider(
                http: MockHTTPClient(responses: [existingRecord, failing])
            )
            _ = try provider.upsertARecord(
                zoneID: "0123456789abcdef0123456789abcdef",
                recordName: "mac.example.com",
                ipAddress: "192.0.0.9",
                token: "request-token"
            )
        }
        throw TestFailure("\(operation.rawValue) fixture should fail")
    } catch let error as CloudflareError {
        return error
    }
}

private func assertCloudflareErrorIsSanitized(
    _ error: CloudflareError,
    operation: CloudflareOperation,
    expectedFailure: CloudflareServiceFailure
) throws {
    try expect(
        error == .service(operation: operation, failure: expectedFailure),
        "\(operation.rawValue) must preserve only its controlled operation/failure model"
    )
    let uiStatus = ComponentStatus.failed(
        "Cloudflare request failed",
        detail: error.localizedDescription
    )
    let surfaces = [
        error.localizedDescription,
        String(describing: error),
        String(reflecting: error),
        (error as NSError).localizedDescription,
        uiStatus.message,
        uiStatus.detail
    ]
    let forbidden = cloudflareSecretFragments + [
        "cfut_HEADER_SECRET",
        "proxy-password",
        "header-secret",
        "response-secret",
        "server-controlled-message"
    ]
    for surface in surfaces {
        for secret in forbidden {
            try expect(
                !surface.localizedCaseInsensitiveContains(secret),
                "\(operation.rawValue) leaked a response/header/credential fragment through an error or UI surface"
            )
        }
    }
}

func testCloudflareErrorsSanitizeJSONAndNonJSONAcrossEveryOperation() throws {
    let operations: [CloudflareOperation] = [
        .verifyToken,
        .listZones,
        .readZone,
        .listDNSRecords,
        .createDNSRecord,
        .updateDNSRecord
    ]
    let joinedSecrets = cloudflareSecretFragments.joined(separator: " | ")
    let jsonBody = """
    {"success":false,"errors":[{"code":9109,"message":"\(joinedSecrets)"}],"result":null}
    """
    let nonJSONBody = joinedSecrets

    for operation in operations {
        let structured = try cloudflareErrorFixture(
            operation: operation,
            body: jsonBody,
            status: 500
        )
        try assertCloudflareErrorIsSanitized(
            structured,
            operation: operation,
            expectedFailure: .rejected(httpStatus: 500, safeCodes: [])
        )

        let invalid = try cloudflareErrorFixture(
            operation: operation,
            body: nonJSONBody,
            status: 502
        )
        try assertCloudflareErrorIsSanitized(
            invalid,
            operation: operation,
            expectedFailure: .invalidResponse(httpStatus: 502)
        )
    }
}

func testCloudflare403UsesFixedPermissionGuidanceAcrossEveryOperation() throws {
    let body = cloudflareSecretFragments.joined(separator: "\n")
    for operation in [
        CloudflareOperation.verifyToken,
        .listZones,
        .readZone,
        .listDNSRecords,
        .createDNSRecord,
        .updateDNSRecord
    ] {
        let error = try cloudflareErrorFixture(
            operation: operation,
            body: body,
            status: 403
        )
        try assertCloudflareErrorIsSanitized(
            error,
            operation: operation,
            expectedFailure: .permissionDenied
        )
        try expect(
            error.localizedDescription == CloudflarePermissionGuidance.dnsWriteDenied,
            "Every Cloudflare 403 must use the same fixed local permission guidance"
        )
    }
}

func testCloudflareTransportErrorDoesNotExposeUnderlyingRequestDetails() throws {
    let underlying = TestFailure(
        "\(cloudflareTransportToken) Authorization Bearer proxy-user:proxy-password https://private.example"
    )
    let provider = CloudflareDNSProvider(http: ThrowingHTTPClient(error: underlying))
    do {
        _ = try provider.listZones(token: "request-token")
        throw TestFailure("A transport failure should be mapped")
    } catch let error as CloudflareError {
        try assertCloudflareErrorIsSanitized(
            error,
            operation: .verifyToken,
            expectedFailure: .transport
        )
        try expect(
            !error.localizedDescription.contains("private.example"),
            "Transport errors must not expose request or proxy locations"
        )
    }
}

func testCloudflareValidationErrorsDoNotEchoResponseValues() throws {
    let inactiveProvider = CloudflareDNSProvider(
        http: MockHTTPClient(responses: [
            response(
                #"{"success":true,"errors":[],"result":{"id":"token-1","status":"cfut_STATUS_SECRET proxy-password"}}"#
            )
        ])
    )
    do {
        _ = try inactiveProvider.listZones(token: "request-token")
        throw TestFailure("A non-active token status should fail")
    } catch let error as CloudflareError {
        try expect(
            error == .configuration(.inactiveToken),
            "A non-active token status must map to a fixed configuration issue"
        )
        try expect(
            !error.localizedDescription.contains("cfut_")
                && !error.localizedDescription.contains("proxy-password"),
            "A server-controlled token status must not enter an error"
        )
    }

    let zoneProvider = CloudflareDNSProvider(
        http: MockHTTPClient(responses: [
            response(#"{"success":true,"errors":[],"result":{"id":"token-1","status":"active"}}"#),
            response(
                #"{"success":true,"errors":[],"result":{"id":"zone-1","name":"cfut_ZONE_SECRET.proxy-password","status":"active"}}"#
            )
        ])
    )
    do {
        _ = try zoneProvider.validateConfiguration(
            zoneID: "0123456789abcdef0123456789abcdef",
            recordName: "mac.example.com",
            token: "request-token"
        )
        throw TestFailure("A record outside the selected zone should fail")
    } catch let error as CloudflareError {
        try expect(
            error == .configuration(.recordOutsideZone),
            "A server-controlled zone name must map to a fixed configuration issue"
        )
        try expect(
            !error.localizedDescription.contains("cfut_")
                && !error.localizedDescription.contains("proxy-password"),
            "A server-controlled zone name must not enter an error"
        )
    }
}

func testListsZonesAcrossPages() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":{"id":"token-1","status":"active"}}"#),
        response(#"{"success":true,"errors":[],"result":[{"id":"zone-b","name":"b.example","status":"active"}],"result_info":{"total_pages":2}}"#),
        response(#"{"success":true,"errors":[],"result":[{"id":"zone-a","name":"a.example","status":"active"}],"result_info":{"total_pages":2}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let zones = try provider.listZones(token: "test-token")

    try expect(zones.map(\.name) == ["a.example", "b.example"], "Zones should be paginated and sorted")
    try expect(mock.requests.count == 3, "Token verification plus two zone pages expected")
}

func testListsZonesWithAccountOwnedToken() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":false,"errors":[{"code":6003,"message":"Invalid request headers"}],"result":null}"#, status: 400),
        response(#"{"success":true,"errors":[],"result":[{"id":"zone-a","name":"example.com","status":"active"}],"result_info":{"total_pages":1}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let zones = try provider.listZones(token: "cfut_account-token")

    try expect(zones.map(\.name) == ["example.com"], "Account-owned token should be proven by the zone request")
    try expect(mock.requests.count == 2, "Account token should fall through to zone listing")
}

let tests: [(String, () throws -> Void)] = [
    ("creates missing record", testCreatesMissingRecord),
    ("disables proxy", testDisablesProxyOnExistingRecord),
    ("creates missing AAAA record", testCreatesMissingAAAARecord),
    ("rejects non-global IPv6", testRejectsNonGlobalIPv6),
    ("classifies public IPv4 CIDRs", testClassifiesPublicIPv4WithFixedCIDRFixtures),
    ("skips non-public IPv4 probe responses", testPublicIPv4ProbeSkipsNonPublicResponses),
    ("rejects non-public DNS addresses before request", testCloudflareRejectsNonPublicAddressesBeforeRequest),
    ("classifies global IPv6 CIDRs", testClassifiesGlobalIPv6WithFixedCIDRFixtures),
    ("supports dual-stack preference", testDualStackPreference),
    ("reports every mapping removal result", testRemovalReportPreservesEveryProtocolAndFamilyResult),
    ("binds current-check proof for every mapping protocol", testProtocolMappingsProduceBoundCurrentCheckProofs),
    ("keeps UPnP leases renewable", testUPnPLeaseIsAlwaysRenewable),
    ("binds UPnP removal to the original router", testUPnPRemovalStaysBoundToOriginalRouter),
    ("preserves UPnP recovery identity after verification failure", testUPnPVerificationFailurePreservesRecoveryIdentity),
    ("repeats IPv6 UPnP deletion idempotently", testUPnPIPv6RepeatedDeleteIsIdempotentOnlyForFirewallService),
    ("preserves recovery identity in automatic mode", testAutomaticMappingPreservesRecoveryIdentity),
    ("falls back to UPnP after harmless UDP probes", testAutomaticFallsBackToUPnPWhenUDPProtocolsDoNotRespond),
    ("probes NAT-PMP before automatic mapping", testAutomaticUsesNATPMPOnlyAfterExternalAddressProbe),
    ("recognizes NAT-PMP version negotiation immediately", testAutomaticRecognizesNATPMPVersionNegotiationImmediately),
    ("probes PCP before automatic mapping", testAutomaticUsesPCPOnlyAfterAnnounceProbe),
    ("retransmits a lost automatic probe", testAutomaticRetransmitsAfterSingleProbePacketLoss),
    ("reports every automatic protocol unsupported", testAutomaticReportsAllProtocolsUnsupportedWithoutSendingMAP),
    ("stops fallback only after uncertain confirmed MAP", testAutomaticStopsFallbackOnlyAfterConfirmedProtocolMAPIsUncertain),
    ("cancels automatic UDP retries and fallback", testAutomaticCancellationStopsRetriesAndFallback),
    ("falls back when UDP transport never sends MAP", testAutomaticFallsBackWhenTransportNeverSentMAP),
    ("preserves unsent evidence in production socket stages", testProductionSocketStagesPreserveUnsentEvidence),
    ("builds PCP payload from connected source", testPCPBuilderUsesConnectedSourceAddress),
    ("keeps effective PCP identity through lifecycle", testPCPEffectiveIdentityPersistsThroughLifecycle),
    ("separates address drift and bounds renewal", testAddressChangeReasonAutoWANBudgetAndRenewalDeadline),
    ("cancels one operation token across protocol chains", testOperationTokenCancellationGapAndAbsoluteDeadline),
    ("binds UPnP renewal to persisted IGD identity", testUPnPRenewalRequiresPersistedIGDIdentity),
    ("cancels real UPnP URLSession description requests", testRealUPnPDescriptionRequestCancelsURLSession),
    ("keeps effective NAT-PMP identity through lifecycle", testNATPMPEffectiveIdentityPersistsAndDriftBlocksMAP),
    ("requires NAT-PMP Epoch continuity before delete", testNATPMPDeletionRequiresProvenEpochContinuity),
    ("zeros suggested external fields on deletion", testDeletionRequestsZeroSuggestedExternalFields),
    ("rejects nonzero successful deletion state", testDeletionRejectsNonzeroSuccessState),
    ("validates PCP responses and retry schedules", testPCPResponseValidationAndRetrySchedules),
    ("detects isolated router Epoch state loss", testEpochTrackingDetectsStateLossAndIsolatesKeys),
    ("uses monotonic Epoch time and fail-closed persistence", testEpochUsesMonotonicTimeAndFailsClosedAcrossPersistence),
    ("delays serialized NAT-PMP reset rebuilds", testNATPMPResetDelayBoundariesCancellationAndSerialization),
    ("ignores bad UDP datagrams and accepts late response", testTransactionInjectionIgnoresBadDatagramsAndAcceptsLateResponse),
    ("reuses the real UDP source port for PCP retries", testRealUDPTransactionReusesSourcePortAndAcceptsLateResponse),
    ("uses native IPv6 source in real PCP payload", testRealIPv6PCPPayloadUsesConnectedSourceAddress),
    ("preserves IPv6 pinhole ID on uncertain renewal", testIPv6PinholeRenewalPreservesOldIDUnlessExplicitlyMissing),
    ("caps every router lease to temporary access", testTemporaryAccessCapsEveryRouterLease),
    ("enforces temporary access absolute router deadlines", testTemporaryAccessRejectsMappingsCompletedPastAbsoluteDeadline),
    ("requires explicit enabled UPnP creation state", testUPnPAddVerificationRequiresExplicitEnabledOne),
    ("reconciles legacy UPnP only after exact identity match", testLegacyUPnPReconciliationRequiresExactRuleIdentity),
    ("removes legacy Automatic in strict protocol order", testLegacyAutomaticRemovalUsesStrictProtocolOrder),
    ("queries uncertain UPnP Add recovery before deletion", testUPnPUncertainAddRecoveryQueriesBeforeDelete),
    ("preserves finite recovery state after UPnP add response loss", testUPnPAddResponseLossPreservesFiniteRecoveryState),
    ("discovers IPv6 firewall service with scoped SSDP", testIPv6ScopedSSDPAllowsSameUDNDualStackControlURL),
    ("encodes and decodes PCP MAP", testPCPMapCodec),
    ("selects physical IPv6 from anonymous fixtures", testLocalIPv6SelectionUsesAnonymousFixtures),
    ("prefers default physical IPv6 route", testLocalIPv6SelectionPrefersDefaultPhysicalRoute),
    ("rejects ULA and link-local IPv6 fixtures", testLocalIPv6SelectionRejectsOnlyULAAndLinkLocalFixtures),
    ("parses fixed ifconfig IPv6 attributes", testParsesIPv6AttributesFromFixedIfconfigFixture),
    ("prefers stable IPv6 from fixed ifconfig fixture", testLocalIPv6SelectionPrefersStableFixedIfconfigCandidate),
    ("rejects temporary IPv6", testLocalIPv6SelectionRejectsTemporaryAddress),
    ("rejects tunnel-only fixed ifconfig IPv6", testLocalIPv6SelectionRejectsTunnelOnlyIfconfigFixture),
    ("decodes older config", testOlderConfigDecodesWithoutIPv6State),
    ("reports DNS permission guidance", testReportsCloudflareDNSPermissionGuidanceWithoutResponseSecrets),
    ("reports first DNS write permission guidance", testReportsCloudflareCreatePermissionGuidance),
    ("sanitizes every Cloudflare JSON and non-JSON error path", testCloudflareErrorsSanitizeJSONAndNonJSONAcrossEveryOperation),
    ("uses fixed permission guidance for every Cloudflare 403", testCloudflare403UsesFixedPermissionGuidanceAcrossEveryOperation),
    ("sanitizes Cloudflare transport errors", testCloudflareTransportErrorDoesNotExposeUnderlyingRequestDetails),
    ("sanitizes Cloudflare validation response values", testCloudflareValidationErrorsDoNotEchoResponseValues),
    ("lists paginated zones", testListsZonesAcrossPages),
    ("supports account-owned token", testListsZonesWithAccountOwnedToken)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
    print("Backend tests passed: \(tests.count)")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
