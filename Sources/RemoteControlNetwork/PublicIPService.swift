import Foundation
import Darwin

final class PublicIPService {
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
                if Self.looksLikeIPv4(value) {
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
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return number >= 0 && number <= 255
        }
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
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16 else { return false }

        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isMulticast = bytes[0] == 0xff
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        return !isUnspecified && !isLoopback && !isMulticast && !isLinkLocal && !isUniqueLocal && !isIPv4Mapped
    }

    static func isPrivateOrCGNAT(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0]
        let b = parts[1]
        if a == 10 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }
}
