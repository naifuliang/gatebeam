import Foundation

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

struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, data: Data(json.utf8), headers: [:])
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
        deviceIdentity: deviceIdentity
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

func testAutomaticStopsAfterUncertainPCPOrNATPMPRequest() throws {
    var config = AppConfig.default
    config.mappingProtocolPreference = .automatic
    config.preferredAddressFamily = .ipv4
    config.internalPort = 5900
    config.externalPort = 45900
    config.mappingLeaseSeconds = 3600
    config.pcpNonce = Data(repeating: 13, count: 12).base64EncodedString()

    var pcpCalls = 0
    let uncertainPCP = RouterMappingService(
        udpRequestHandler: { _, _, _, _ in
            pcpCalls += 1
            throw RouterMappingError.uncertainAfterSend("Injected PCP response loss")
        }
    )
    do {
        _ = try uncertainPCP.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Uncertain PCP creation must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(pcpCalls == 1, "Automatic must stop immediately after uncertain PCP creation")
        try expect(recovery.mapping.transport == .pcp, "PCP uncertainty must retain PCP identity")
        try expect(recovery.mapping.gatewayAddress == "192.0.2.1", "PCP uncertainty must retain the gateway")
        try expect(recovery.mapping.internalPort == 5900, "PCP uncertainty must retain the internal port")
        try expect(recovery.mapping.externalPort == 45900, "PCP uncertainty must retain the candidate external port")
        try expect(recovery.mapping.pcpNonce == config.pcpNonce, "PCP uncertainty must retain the nonce")
    }

    var udpActions: [String] = []
    var upnpDiscoveryCount = 0
    let uncertainNATPMP = RouterMappingService(
        upnpDiscoveryHandler: {
            upnpDiscoveryCount += 1
            return []
        },
        udpRequestHandler: { payload, _, _, _ in
            if payload.first == 2 {
                udpActions.append("pcp-rejected")
                var rejected = payload
                rejected[1] = 0x81
                rejected[3] = 2
                return rejected
            }
            udpActions.append("natpmp-uncertain")
            throw RouterMappingError.uncertainAfterSend("Injected NAT-PMP response loss")
        }
    )
    do {
        _ = try uncertainNATPMP.ensureMapping(
            config: config,
            localAddress: "192.0.2.20",
            gatewayAddress: "192.0.2.1"
        )
        throw TestFailure("Uncertain NAT-PMP creation must require recovery")
    } catch let recovery as RouterMappingRecoveryRequiredError {
        try expect(
            udpActions == ["pcp-rejected", "natpmp-uncertain"],
            "A clear PCP rejection may fall back, but uncertain NAT-PMP must stop Automatic"
        )
        try expect(upnpDiscoveryCount == 0, "UPnP must not run after uncertain NAT-PMP creation")
        try expect(recovery.mapping.transport == .natpmp, "NAT-PMP uncertainty must retain protocol identity")
        try expect(recovery.mapping.gatewayAddress == "192.0.2.1", "NAT-PMP uncertainty must retain the gateway")
        try expect(recovery.mapping.internalPort == 5900, "NAT-PMP uncertainty must retain the internal port")
        try expect(recovery.mapping.externalPort == 45900, "NAT-PMP uncertainty must retain the candidate external port")
    }
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
        deviceIdentity: "uuid:gatebeam-renew-router"
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
            var reply = payload
            reply[1] = 0x81
            reply[3] = 0
            return reply
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
        deviceIdentity: "uuid:lease-router"
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
        udpRequestHandler: { request, _, _, _ in
            pcpOnlyActions.append("PCP")
            return pcpDeletionResponse(for: request)
        }
    )
    let pcpOnlyReport = remove(using: pcpOnly)
    try expect(pcpOnlyReport.allSucceeded, "A confirmed PCP deletion must close legacy Automatic")
    try expect(
        pcpOnlyReport.succeededMappings.map(\.transport) == [.pcp],
        "PCP-only cleanup must retain the exact successful protocol"
    )
    try expect(pcpOnlyActions == ["PCP"], "PCP success must stop before NAT-PMP")
    try expect(pcpOnlyDiscoveryCount == 0, "PCP success must stop before UPnP discovery")

    var natPMPActions: [String] = []
    var natPMPDiscoveryCount = 0
    let natPMPOnly = RouterMappingService(
        upnpDiscoveryHandler: {
            natPMPDiscoveryCount += 1
            return [service]
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
    try expect(natPMPReport.allSucceeded, "A confirmed NAT-PMP deletion must close legacy Automatic")
    try expect(
        natPMPReport.succeededMappings.map(\.transport) == [.natpmp],
        "NAT-PMP-only cleanup must retain the exact successful protocol"
    )
    try expect(
        natPMPActions == ["PCP unsupported", "NAT-PMP"],
        "Automatic must try NAT-PMP only after conclusive PCP unsupported"
    )
    try expect(natPMPDiscoveryCount == 0, "NAT-PMP success must stop before UPnP discovery")

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
    try expect(upnpReport.allSucceeded, "An exactly matched legacy UPnP rule must be deleted")
    try expect(
        upnpReport.succeededMappings.map(\.transport) == [.upnp],
        "UPnP-only cleanup must retain the exact successful protocol"
    )
    try expect(
        upnpUDPActions == ["PCP unsupported", "NAT-PMP unsupported"],
        "UPnP must run only after both UDP protocols are conclusively unsupported"
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
        foreignReport.remainingMappings.map(\.transport) == [.upnp],
        "A foreign UPnP rule must retain only the bound UPnP recovery identity"
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
        unsupportedReport.allSucceeded && unsupportedReport.attempts.isEmpty,
        "Unsupported UDP protocols followed by no UPnP entry must close idempotently"
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
        udpRequestHandler: { _, _, _, _ in
            uncertainPCPActions.append("PCP uncertain")
            throw RouterMappingError.uncertainAfterSend("Injected PCP deletion response loss")
        }
    )
    let uncertainPCPReport = remove(using: uncertainPCP)
    try expect(!uncertainPCPReport.allSucceeded, "Uncertain PCP deletion must fail closed")
    try expect(
        uncertainPCPReport.remainingMappings.map(\.transport) == [.pcp],
        "Uncertain PCP deletion must retain only the PCP recovery identity"
    )
    try expect(uncertainPCPActions == ["PCP uncertain"], "Uncertain PCP must stop Automatic")
    try expect(uncertainPCPDiscoveryCount == 0, "Uncertain PCP must block UPnP discovery")

    var uncertainNATPMPActions: [String] = []
    var uncertainNATPMPDiscoveryCount = 0
    let uncertainNATPMP = RouterMappingService(
        upnpDiscoveryHandler: {
            uncertainNATPMPDiscoveryCount += 1
            return [service]
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
        uncertainNATPMPActions == ["PCP unsupported", "NAT-PMP uncertain"],
        "NAT-PMP uncertainty must stop Automatic after conclusive PCP unsupported"
    )
    try expect(uncertainNATPMPDiscoveryCount == 0, "NAT-PMP uncertainty must block UPnP discovery")

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
        discoveryFailureReport.remainingMappings.map(\.transport) == [.upnp],
        "UPnP discovery timeout must retain a manual-recovery identity"
    )
    try expect(discoveryFailureCalls == 1, "UPnP discovery must be attempted exactly once")

    var dualStackPCPCalls = 0
    let partialDualStack = RouterMappingService(
        udpRequestHandler: { request, _, _, _ in
            dualStackPCPCalls += 1
            if dualStackPCPCalls == 1 {
                return pcpDeletionResponse(for: request)
            }
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
        partialReport.remainingMappings.map(\.addressFamily) == [.ipv6],
        "Partial cleanup must preserve only the uncertain IPv6 identity"
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
        nowProvider: { now }
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
        deviceIdentity: "uuid:response-loss-router"
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
        nowProvider: { now }
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
    try expect(
        mapper.removeMappings([result.activeMapping]).allSucceeded,
        "A same-UDN dual-stack control URL must remain bound for exact deletion"
    )
    try expect(searches.count == 1, "Deletion must use persisted IGD identity without rediscovery")
    try expect(actions == ["GetFirewallStatus", "AddPinhole", "DeletePinhole"], "IPv6 lifecycle actions must stay ordered")
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

func testReportsCloudflareAPIError() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":false,"errors":[{"code":9109,"message":"Invalid access token"}],"result":null}"#, status: 403)
    ])
    let provider = CloudflareDNSProvider(http: mock)

    do {
        _ = try provider.upsertARecord(
            zoneID: "0123456789abcdef0123456789abcdef",
            recordName: "mac.example.com",
            ipAddress: "192.0.0.9",
            token: "bad-token"
        )
        throw TestFailure("Invalid token response should fail")
    } catch let error as CloudflareError {
        try expect(error.localizedDescription.contains("9109"), "Cloudflare error code should be preserved")
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
    ("keeps UPnP leases renewable", testUPnPLeaseIsAlwaysRenewable),
    ("binds UPnP removal to the original router", testUPnPRemovalStaysBoundToOriginalRouter),
    ("preserves UPnP recovery identity after verification failure", testUPnPVerificationFailurePreservesRecoveryIdentity),
    ("repeats IPv6 UPnP deletion idempotently", testUPnPIPv6RepeatedDeleteIsIdempotentOnlyForFirewallService),
    ("preserves recovery identity in automatic mode", testAutomaticMappingPreservesRecoveryIdentity),
    ("stops automatic fallback after uncertain UDP creation", testAutomaticStopsAfterUncertainPCPOrNATPMPRequest),
    ("preserves IPv6 pinhole ID on uncertain renewal", testIPv6PinholeRenewalPreservesOldIDUnlessExplicitlyMissing),
    ("caps every router lease to temporary access", testTemporaryAccessCapsEveryRouterLease),
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
    ("reports API error", testReportsCloudflareAPIError),
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
