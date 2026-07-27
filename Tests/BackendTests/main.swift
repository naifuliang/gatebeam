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

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message) }
}

func testCreatesMissingRecord() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-1","type":"A","name":"mac.example.com","content":"203.0.113.10","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "Mac.Example.com.",
        ipAddress: "203.0.113.10",
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
        response(#"{"success":true,"errors":[],"result":[{"id":"record-1","type":"A","name":"mac.example.com","content":"203.0.113.10","ttl":120,"proxied":true}]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-1","type":"A","name":"mac.example.com","content":"203.0.113.10","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "mac.example.com",
        ipAddress: "203.0.113.10",
        token: "test-token"
    )

    try expect(result.changed, "Proxied record must be changed for direct VNC")
    try expect(mock.requests[1].method == "PATCH", "Existing record should use PATCH")
}

func testCreatesMissingAAAARecord() throws {
    let mock = MockHTTPClient(responses: [
        response(#"{"success":true,"errors":[],"result":[]}"#),
        response(#"{"success":true,"errors":[],"result":{"id":"record-v6","type":"AAAA","name":"mac.example.com","content":"2001:db8::10","ttl":120,"proxied":false}}"#)
    ])
    let provider = CloudflareDNSProvider(http: mock)
    let result = try provider.upsertAAAARecord(
        zoneID: "0123456789abcdef0123456789abcdef",
        recordName: "mac.example.com",
        ipAddress: "2001:db8::10",
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

func testDualStackPreference() throws {
    try expect(AddressFamilyPreference.dualStack.usesIPv4, "Dual stack should enable IPv4")
    try expect(AddressFamilyPreference.dualStack.usesIPv6, "Dual stack should enable IPv6")
    try expect(!AddressFamilyPreference.ipv4.usesIPv6, "IPv4-only mode should not enable IPv6")
    try expect(!AddressFamilyPreference.ipv6.usesIPv4, "IPv6-only mode should not enable IPv4")
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

func testLocalIPv6SelectionIsGlobal() throws {
    if let address = LocalNetworkService().globalIPv6Address() {
        try expect(PublicIPService.isGlobalIPv6(address), "Selected local IPv6 must be globally routable")
        print("INFO: selected global IPv6 \(address)")
    }
}

func testOlderConfigDecodesWithoutIPv6State() throws {
    let encoded = try JSONEncoder().encode(AppConfig.default)
    var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    object.removeValue(forKey: "ipv6PinholeID")
    object.removeValue(forKey: "pcpNonce")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
    try expect(decoded.ipv6PinholeID == nil, "Older configs should default the IPv6 pinhole ID to nil")
    try expect(decoded.pcpNonce == nil, "Older configs should default the PCP nonce to nil")
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
            ipAddress: "203.0.113.10",
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
    ("supports dual-stack preference", testDualStackPreference),
    ("encodes and decodes PCP MAP", testPCPMapCodec),
    ("selects a global local IPv6", testLocalIPv6SelectionIsGlobal),
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
