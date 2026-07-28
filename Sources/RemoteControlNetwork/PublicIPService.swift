import Foundation
import Darwin

protocol PublicIPServicing {
    func currentIPv4() throws -> String
    func currentIPv6() throws -> String
}

final class PublicIPService: PublicIPServicing {
    private let http: HTTPRequesting

    init(http: HTTPRequesting = HTTPClient(useSystemProxy: false)) {
        self.http = http
    }

    convenience init(proxyMode: NetworkProxyMode, customProxyURL: String = "") throws {
        try self.init(http: HTTPClient(proxyMode: proxyMode, customProxyURL: customProxyURL))
    }

    func currentIPv4() throws -> String {
        let endpoints = [
            "https://api.ipify.org",
            "https://ifconfig.me/ip",
            "https://checkip.amazonaws.com"
        ]

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let response = try http.request(url: URL(string: endpoint)!, timeout: 8)
                let value = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isPublicIPv4(value) {
                    return value
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NetworkError.invalidResponse("No public IPv4 endpoint returned an address")
    }

    func currentIPv6() throws -> String {
        let endpoints = [
            "https://api6.ipify.org",
            "https://v6.ident.me",
            "https://ipv6.icanhazip.com"
        ]

        var lastError: Error?
        for endpoint in endpoints {
            do {
                let response = try http.request(url: URL(string: endpoint)!, timeout: 8)
                let value = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isGlobalIPv6(value) {
                    return Self.normalizedIPv6(value) ?? value
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NetworkError.invalidResponse("No public IPv6 endpoint returned a global address")
    }

    static func looksLikeIPv4(_ value: String) -> Bool {
        ipv4Bytes(value) != nil
    }

    static func isPublicIPv4(_ value: String) -> Bool {
        guard let bytes = ipv4Bytes(value) else { return false }

        // IANA special-purpose ranges that must never become public DDNS records.
        let nonPublicRanges: [([UInt8], Int)] = [
            ([0, 0, 0, 0], 8),
            ([10, 0, 0, 0], 8),
            ([100, 64, 0, 0], 10),
            ([127, 0, 0, 0], 8),
            ([169, 254, 0, 0], 16),
            ([172, 16, 0, 0], 12),
            ([192, 0, 0, 0], 24),
            ([192, 0, 2, 0], 24),
            ([192, 88, 99, 0], 24),
            ([192, 168, 0, 0], 16),
            ([198, 18, 0, 0], 15),
            ([198, 51, 100, 0], 24),
            ([203, 0, 113, 0], 24),
            ([224, 0, 0, 0], 4),
            ([240, 0, 0, 0], 4)
        ]

        // Port Control Protocol and TURN anycast are the globally reachable
        // exceptions inside 192.0.0.0/24.
        if bytes == [192, 0, 0, 9] || bytes == [192, 0, 0, 10] {
            return true
        }
        return !nonPublicRanges.contains { isInCIDR(bytes, network: $0.0, prefixLength: $0.1) }
    }

    static func looksLikeIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    static func normalizedIPv6(_ value: String) -> String? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    static func isGlobalIPv6(_ value: String) -> Bool {
        guard let bytes = ipv6Bytes(value) else { return false }

        // Public host addresses must be global unicast. Exclude special-purpose
        // subranges within 2000::/3 as well as documentation and transition space.
        guard isInCIDR(bytes, network: [0x20] + Array(repeating: 0, count: 15), prefixLength: 3) else {
            return false
        }
        let nonPublicRanges: [([UInt8], Int)] = [
            ([0x20, 0x01, 0x00, 0x00] + Array(repeating: 0, count: 12), 23),
            ([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 12), 32),
            ([0x20, 0x02] + Array(repeating: 0, count: 14), 16),
            ([0x3f, 0xff] + Array(repeating: 0, count: 14), 20),
            ([0x5f, 0x00] + Array(repeating: 0, count: 14), 16)
        ]
        return !nonPublicRanges.contains { isInCIDR(bytes, network: $0.0, prefixLength: $0.1) }
    }

    static func isPrivateOrCGNAT(_ value: String) -> Bool {
        guard let bytes = ipv4Bytes(value) else { return false }
        let ranges: [([UInt8], Int)] = [
            ([10, 0, 0, 0], 8),
            ([100, 64, 0, 0], 10),
            ([172, 16, 0, 0], 12),
            ([192, 168, 0, 0], 16)
        ]
        return ranges.contains { isInCIDR(bytes, network: $0.0, prefixLength: $0.1) }
    }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
              String(cString: buffer) == value else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6Bytes(_ value: String) -> [UInt8]? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isInCIDR(_ address: [UInt8], network: [UInt8], prefixLength: Int) -> Bool {
        guard address.count == network.count,
              prefixLength >= 0,
              prefixLength <= address.count * 8 else {
            return false
        }

        let wholeBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        if wholeBytes > 0 && address[..<wholeBytes] != network[..<wholeBytes] {
            return false
        }
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << (8 - remainingBits)
        return address[wholeBytes] & mask == network[wholeBytes] & mask
    }
}
