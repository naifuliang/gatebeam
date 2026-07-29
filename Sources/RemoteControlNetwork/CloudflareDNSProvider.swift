import Foundation

struct CloudflareDNSResult {
    let changed: Bool
    let recordID: String
    let content: String
    let message: String
}

struct CloudflareValidationResult {
    let zoneName: String
    let zoneStatus: String
    let recordID: String?
    let recordContent: String?
    let ipv6RecordID: String?
    let ipv6RecordContent: String?
}

enum CloudflareDNSRecordType: String {
    case a = "A"
    case aaaa = "AAAA"
}

struct CloudflareZoneSummary: Codable, Equatable {
    let id: String
    let name: String
    let status: String
}

enum CloudflarePermissionGuidance {
    static let dnsWriteDenied = "Cloudflare denied DNS access for the selected zone. Grant Zone/DNS/Edit and Zone/Zone/Read to this token for the target zone."
}

enum CloudflareOperation: String, Equatable {
    case verifyToken
    case listZones
    case readZone
    case listDNSRecords
    case createDNSRecord
    case updateDNSRecord

    var localizedAction: String {
        switch self {
        case .verifyToken:
            return "verifying the API token"
        case .listZones:
            return "listing zones"
        case .readZone:
            return "reading the selected zone"
        case .listDNSRecords:
            return "reading DNS records"
        case .createDNSRecord:
            return "creating the DNS record"
        case .updateDNSRecord:
            return "updating the DNS record"
        }
    }
}

enum CloudflareServiceFailure: Equatable {
    case transport
    case invalidResponse(httpStatus: Int)
    case rejected(httpStatus: Int, safeCodes: [Int])
    case permissionDenied
}

enum CloudflareConfigurationIssue: Equatable {
    case missingToken
    case emptyRecordName
    case recordOutsideZone
    case multipleRecords(CloudflareDNSRecordType)
    case invalidPublicIPv4
    case invalidGlobalIPv6
    case inactiveToken
    case invalidZoneID
}

enum CloudflareError: Error, LocalizedError, Equatable {
    case service(operation: CloudflareOperation, failure: CloudflareServiceFailure)
    case configuration(CloudflareConfigurationIssue)

    var errorDescription: String? {
        switch self {
        case .service(_, .permissionDenied):
            return CloudflarePermissionGuidance.dnsWriteDenied
        case .service(let operation, .transport):
            return "Could not contact Cloudflare while \(operation.localizedAction). Check the selected connection route and try again."
        case .service(let operation, .invalidResponse):
            return "Cloudflare returned an invalid response while \(operation.localizedAction)."
        case .service(let operation, .rejected):
            return "Cloudflare rejected the request while \(operation.localizedAction). Review the token permissions and try again."
        case .configuration(let issue):
            switch issue {
            case .missingToken:
                return "Cloudflare API token is missing."
            case .emptyRecordName:
                return "DNS record name is empty."
            case .recordOutsideZone:
                return "The DNS record is not inside the selected Cloudflare zone."
            case .multipleRecords(let type):
                return "Multiple \(type.rawValue) records exist for this name. Keep one record for DDNS."
            case .invalidPublicIPv4:
                return "IPv4 address is not publicly routable."
            case .invalidGlobalIPv6:
                return "IPv6 address is not a valid global IPv6 address."
            case .inactiveToken:
                return "Cloudflare API token is not active."
            case .invalidZoneID:
                return "Cloudflare Zone ID must be 32 hexadecimal characters."
            }
        }
    }

    func containsSafeCode(_ code: Int) -> Bool {
        guard case .service(_, .rejected(_, let safeCodes)) = self else {
            return false
        }
        return safeCodes.contains(code)
    }
}

final class CloudflareDNSProvider {
    private let http: HTTPRequesting
    private let decoder = JSONDecoder()
    private static let safeErrorCodeAllowlist: Set<Int> = [6003]

    init(http: HTTPRequesting = HTTPClient()) {
        self.http = http
    }

    convenience init(proxyMode: NetworkProxyMode, customProxyURL: String = "") throws {
        try self.init(http: HTTPClient(proxyMode: proxyMode, customProxyURL: customProxyURL))
    }

    func listZones(token: String) throws -> [CloudflareZoneSummary] {
        try verifyActiveToken(token)

        var zones: [CloudflareZoneSummary] = []
        var page = 1
        var totalPages = 1
        repeat {
            var components = URLComponents(string: "https://api.cloudflare.com/client/v4/zones")!
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "order", value: "name"),
                URLQueryItem(name: "direction", value: "asc")
            ]
            let pageResult: ([CloudflareZone], CloudflareResultInfo?) = try apiRequestPage(
                url: components.url!,
                headers: authorizationHeaders(token: token),
                operation: .listZones
            )
            zones.append(contentsOf: pageResult.0.map {
                CloudflareZoneSummary(id: $0.id, name: $0.name, status: $0.status)
            })
            totalPages = max(1, pageResult.1?.totalPages ?? 1)
            page += 1
        } while page <= totalPages

        return zones.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func validateConfiguration(zoneID: String, recordName: String, token: String) throws -> CloudflareValidationResult {
        try validateZoneID(zoneID)
        let normalizedRecordName = normalizeDNSName(recordName)
        guard !normalizedRecordName.isEmpty else {
            throw CloudflareError.configuration(.emptyRecordName)
        }

        try verifyActiveToken(token)

        let zone: CloudflareZone = try apiRequest(
            url: URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)")!,
            headers: authorizationHeaders(token: token),
            operation: .readZone
        )
        let zoneName = normalizeDNSName(zone.name)
        guard normalizedRecordName == zoneName || normalizedRecordName.hasSuffix(".\(zoneName)") else {
            throw CloudflareError.configuration(.recordOutsideZone)
        }

        let ipv4Records = try listRecords(type: .a, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        let ipv6Records = try listRecords(type: .aaaa, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        guard ipv4Records.count <= 1 else {
            throw CloudflareError.configuration(.multipleRecords(.a))
        }
        guard ipv6Records.count <= 1 else {
            throw CloudflareError.configuration(.multipleRecords(.aaaa))
        }

        return CloudflareValidationResult(
            zoneName: zone.name,
            zoneStatus: zone.status,
            recordID: ipv4Records.first?.id,
            recordContent: ipv4Records.first?.content,
            ipv6RecordID: ipv6Records.first?.id,
            ipv6RecordContent: ipv6Records.first?.content
        )
    }

    func upsertARecord(zoneID: String, recordName: String, ipAddress: String, token: String) throws -> CloudflareDNSResult {
        guard PublicIPService.isPublicIPv4(ipAddress) else {
            throw CloudflareError.configuration(.invalidPublicIPv4)
        }
        return try upsertRecord(type: .a, zoneID: zoneID, recordName: recordName, address: ipAddress, token: token)
    }

    func upsertAAAARecord(zoneID: String, recordName: String, ipAddress: String, token: String) throws -> CloudflareDNSResult {
        guard PublicIPService.isGlobalIPv6(ipAddress) else {
            throw CloudflareError.configuration(.invalidGlobalIPv6)
        }
        return try upsertRecord(type: .aaaa, zoneID: zoneID, recordName: recordName, address: ipAddress, token: token)
    }

    private func upsertRecord(
        type: CloudflareDNSRecordType,
        zoneID: String,
        recordName: String,
        address: String,
        token: String
    ) throws -> CloudflareDNSResult {
        try validateZoneID(zoneID)
        let normalizedRecordName = normalizeDNSName(recordName)
        guard !normalizedRecordName.isEmpty else {
            throw CloudflareError.configuration(.emptyRecordName)
        }

        let records = try listRecords(type: type, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        guard records.count <= 1 else {
            throw CloudflareError.configuration(.multipleRecords(type))
        }

        if let existing = records.first {
            let isDNSOnly = existing.proxied == false
            if existing.content == address, isDNSOnly, existing.ttl == 120 {
                return CloudflareDNSResult(
                    changed: false,
                    recordID: existing.id,
                    content: address,
                    message: "\(type.rawValue) already points to \(address)"
                )
            }
            return try updateRecord(
                type: type,
                zoneID: zoneID,
                recordID: existing.id,
                recordName: normalizedRecordName,
                address: address,
                token: token
            )
        }

        return try createRecord(type: type, zoneID: zoneID, recordName: normalizedRecordName, address: address, token: token)
    }

    private func listRecords(
        type: CloudflareDNSRecordType,
        zoneID: String,
        recordName: String,
        token: String
    ) throws -> [CloudflareRecord] {
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records")!
        components.queryItems = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "name", value: recordName),
            URLQueryItem(name: "match", value: "all")
        ]
        return try apiRequest(
            url: components.url!,
            headers: authorizationHeaders(token: token),
            operation: .listDNSRecords
        )
    }

    private func createRecord(
        type: CloudflareDNSRecordType,
        zoneID: String,
        recordName: String,
        address: String,
        token: String
    ) throws -> CloudflareDNSResult {
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records")!
        let payload = CloudflareRecordWrite(type: type.rawValue, name: recordName, content: address, ttl: 120, proxied: false)
        let record: CloudflareRecord = try apiRequest(
            url: url,
            method: "POST",
            headers: writeHeaders(token: token),
            body: try JSONEncoder().encode(payload),
            operation: .createDNSRecord
        )
        return CloudflareDNSResult(changed: true, recordID: record.id, content: address, message: "Created \(type.rawValue) record \(recordName)")
    }

    private func updateRecord(
        type: CloudflareDNSRecordType,
        zoneID: String,
        recordID: String,
        recordName: String,
        address: String,
        token: String
    ) throws -> CloudflareDNSResult {
        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records/\(recordID)")!
        let payload = CloudflareRecordWrite(type: type.rawValue, name: recordName, content: address, ttl: 120, proxied: false)
        let record: CloudflareRecord = try apiRequest(
            url: url,
            method: "PATCH",
            headers: writeHeaders(token: token),
            body: try JSONEncoder().encode(payload),
            operation: .updateDNSRecord
        )
        return CloudflareDNSResult(changed: true, recordID: record.id, content: address, message: "Updated \(type.rawValue) record to \(address)")
    }

    private func apiRequest<Result: Decodable>(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil,
        operation: CloudflareOperation
    ) throws -> Result {
        try apiRequestPage(
            url: url,
            method: method,
            headers: headers,
            body: body,
            operation: operation
        ).0
    }

    private func apiRequestPage<Result: Decodable>(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil,
        operation: CloudflareOperation
    ) throws -> (Result, CloudflareResultInfo?) {
        let response: HTTPResponse
        do {
            response = try http.request(
                url: url,
                method: method,
                headers: headers,
                body: body,
                timeout: 15
            )
        } catch {
            throw CloudflareError.service(operation: operation, failure: .transport)
        }
        if response.statusCode == 403 {
            throw CloudflareError.service(operation: operation, failure: .permissionDenied)
        }
        let envelope: CloudflareEnvelope<Result> = try decodeEnvelope(
            response,
            operation: operation
        )
        let result = try requireResult(
            envelope,
            response: response,
            operation: operation
        )
        return (result, envelope.resultInfo)
    }

    private func verifyActiveToken(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudflareError.configuration(.missingToken)
        }
        do {
            let tokenResult: CloudflareTokenResult = try apiRequest(
                url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!,
                headers: authorizationHeaders(token: token),
                operation: .verifyToken
            )
            guard tokenResult.status == "active" else {
                throw CloudflareError.configuration(.inactiveToken)
            }
        } catch let error as CloudflareError {
            // Account-owned tokens use an account-specific verify endpoint. Without an
            // account ID, the following zone request is the authoritative permission check.
            if token.hasPrefix("cfut_"), error.containsSafeCode(6003) {
                return
            }
            throw error
        }
    }

    private func decodeEnvelope<Result: Decodable>(
        _ response: HTTPResponse,
        operation: CloudflareOperation
    ) throws -> CloudflareEnvelope<Result> {
        do {
            return try decoder.decode(CloudflareEnvelope<Result>.self, from: response.data)
        } catch {
            throw CloudflareError.service(
                operation: operation,
                failure: .invalidResponse(httpStatus: response.statusCode)
            )
        }
    }

    private func requireResult<Result>(
        _ envelope: CloudflareEnvelope<Result>,
        response: HTTPResponse,
        operation: CloudflareOperation
    ) throws -> Result {
        guard (200...299).contains(response.statusCode), envelope.success else {
            let safeCodes = envelope.errors.compactMap(\.code).filter {
                Self.safeErrorCodeAllowlist.contains($0)
            }
            throw CloudflareError.service(
                operation: operation,
                failure: .rejected(
                    httpStatus: response.statusCode,
                    safeCodes: Array(Set(safeCodes)).sorted()
                )
            )
        }
        guard let result = envelope.result else {
            throw CloudflareError.service(
                operation: operation,
                failure: .invalidResponse(httpStatus: response.statusCode)
            )
        }
        return result
    }

    private func validateZoneID(_ zoneID: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard zoneID.count == 32, zoneID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CloudflareError.configuration(.invalidZoneID)
        }
    }

    private func normalizeDNSName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func authorizationHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
    }

    private func writeHeaders(token: String) -> [String: String] {
        var headers = authorizationHeaders(token: token)
        headers["Content-Type"] = "application/json"
        return headers
    }
}

private struct CloudflareEnvelope<Result: Decodable>: Decodable {
    let success: Bool
    let result: Result?
    let errors: [CloudflareAPIMessage]
    let resultInfo: CloudflareResultInfo?

    private enum CodingKeys: String, CodingKey {
        case success
        case result
        case errors
        case resultInfo = "result_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        result = try container.decodeIfPresent(Result.self, forKey: .result)
        errors = try container.decodeIfPresent([CloudflareAPIMessage].self, forKey: .errors) ?? []
        resultInfo = try container.decodeIfPresent(CloudflareResultInfo.self, forKey: .resultInfo)
    }
}

private struct CloudflareResultInfo: Decodable {
    let totalPages: Int

    private enum CodingKeys: String, CodingKey {
        case totalPages = "total_pages"
    }
}

private struct CloudflareTokenResult: Decodable {
    let status: String
}

private struct CloudflareZone: Decodable {
    let id: String
    let name: String
    let status: String
}

private struct CloudflareRecord: Codable {
    let id: String
    let type: String
    let name: String
    let content: String
    let ttl: Int?
    let proxied: Bool?
}

private struct CloudflareRecordWrite: Codable {
    let type: String
    let name: String
    let content: String
    let ttl: Int
    let proxied: Bool
}

private struct CloudflareAPIMessage: Decodable {
    let code: Int?
}
