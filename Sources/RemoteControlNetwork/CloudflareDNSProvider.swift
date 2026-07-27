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

final class CloudflareDNSProvider {
    private let http: HTTPRequesting
    private let decoder = JSONDecoder()

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
            let response = try http.request(
                url: components.url!,
                headers: authorizationHeaders(token: token),
                timeout: 15
            )
            let envelope: CloudflareEnvelope<[CloudflareZone]> = try decodeEnvelope(
                response,
                context: "List zones"
            )
            zones.append(contentsOf: try requireResult(envelope, response: response, context: "List zones").map {
                CloudflareZoneSummary(id: $0.id, name: $0.name, status: $0.status)
            })
            totalPages = max(1, envelope.resultInfo?.totalPages ?? 1)
            page += 1
        } while page <= totalPages

        return zones.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func validateConfiguration(zoneID: String, recordName: String, token: String) throws -> CloudflareValidationResult {
        try validateZoneID(zoneID)
        let normalizedRecordName = normalizeDNSName(recordName)
        guard !normalizedRecordName.isEmpty else {
            throw CloudflareError.configuration("DNS record name is empty")
        }

        try verifyActiveToken(token)

        let zone: CloudflareZone = try apiRequest(
            url: URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)")!,
            headers: authorizationHeaders(token: token),
            context: "Read zone"
        )
        let zoneName = normalizeDNSName(zone.name)
        guard normalizedRecordName == zoneName || normalizedRecordName.hasSuffix(".\(zoneName)") else {
            throw CloudflareError.configuration("DNS record \(recordName) is not inside zone \(zone.name)")
        }

        let ipv4Records = try listRecords(type: .a, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        let ipv6Records = try listRecords(type: .aaaa, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        guard ipv4Records.count <= 1 else {
            throw CloudflareError.configuration("Multiple A records exist for \(recordName); keep one record for DDNS")
        }
        guard ipv6Records.count <= 1 else {
            throw CloudflareError.configuration("Multiple AAAA records exist for \(recordName); keep one record for DDNS")
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
        guard PublicIPService.looksLikeIPv4(ipAddress) else {
            throw CloudflareError.configuration("Invalid IPv4 address: \(ipAddress)")
        }
        return try upsertRecord(type: .a, zoneID: zoneID, recordName: recordName, address: ipAddress, token: token)
    }

    func upsertAAAARecord(zoneID: String, recordName: String, ipAddress: String, token: String) throws -> CloudflareDNSResult {
        guard PublicIPService.isGlobalIPv6(ipAddress) else {
            throw CloudflareError.configuration("Invalid global IPv6 address: \(ipAddress)")
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
            throw CloudflareError.configuration("DNS record name is empty")
        }

        let records = try listRecords(type: type, zoneID: zoneID, recordName: normalizedRecordName, token: token)
        guard records.count <= 1 else {
            throw CloudflareError.configuration("Multiple \(type.rawValue) records exist for \(recordName); keep one record for DDNS")
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
            context: "List DNS record"
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
            context: "Create DNS record"
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
            context: "Update DNS record"
        )
        return CloudflareDNSResult(changed: true, recordID: record.id, content: address, message: "Updated \(type.rawValue) record to \(address)")
    }

    private func apiRequest<Result: Decodable>(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil,
        context: String
    ) throws -> Result {
        let response = try http.request(url: url, method: method, headers: headers, body: body, timeout: 15)
        let envelope: CloudflareEnvelope<Result> = try decodeEnvelope(response, context: context)
        return try requireResult(envelope, response: response, context: context)
    }

    private func verifyActiveToken(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudflareError.configuration("Cloudflare API token is empty")
        }
        do {
            let tokenResult: CloudflareTokenResult = try apiRequest(
                url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!,
                headers: authorizationHeaders(token: token),
                context: "Verify token"
            )
            guard tokenResult.status == "active" else {
                throw CloudflareError.configuration("Cloudflare API token is \(tokenResult.status)")
            }
        } catch let error as CloudflareError {
            // Account-owned tokens use an account-specific verify endpoint. Without an
            // account ID, the following zone request is the authoritative permission check.
            if token.hasPrefix("cfut_"), error.localizedDescription.contains("6003") {
                return
            }
            throw error
        }
    }

    private func decodeEnvelope<Result: Decodable>(
        _ response: HTTPResponse,
        context: String
    ) throws -> CloudflareEnvelope<Result> {
        do {
            return try decoder.decode(CloudflareEnvelope<Result>.self, from: response.data)
        } catch {
            let detail = response.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw CloudflareError.api("\(context) returned an invalid response (HTTP \(response.statusCode)): \(detail)")
        }
    }

    private func requireResult<Result>(
        _ envelope: CloudflareEnvelope<Result>,
        response: HTTPResponse,
        context: String
    ) throws -> Result {
        guard (200...299).contains(response.statusCode), envelope.success, let result = envelope.result else {
            let messages = envelope.errors.map { message in
                if let code = message.code { return "\(code): \(message.message)" }
                return message.message
            }.joined(separator: "; ")
            let detail = messages.isEmpty ? "HTTP \(response.statusCode)" : messages
            throw CloudflareError.api("\(context) failed: \(detail)")
        }
        return result
    }

    private func validateZoneID(_ zoneID: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard zoneID.count == 32, zoneID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CloudflareError.configuration("Cloudflare Zone ID must be 32 hexadecimal characters")
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

enum CloudflareError: Error, LocalizedError {
    case api(String)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .api(let message), .configuration(let message): return message
        }
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
    let message: String
}
