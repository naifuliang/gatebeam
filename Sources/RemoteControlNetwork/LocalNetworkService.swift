import Foundation
import Darwin

protocol LocalNetworkServicing {
    func localIPv4Address() -> String?
    func globalIPv6Address() -> String?
    func defaultGatewayIPv4() -> String?
    func defaultGatewayIPv6() -> String?
    func isTCPPortListening(port: UInt16, timeout: TimeInterval) -> Bool
    func isTCPPortOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool
}

final class LocalNetworkService: LocalNetworkServicing {
    func localIPv4Address() -> String? {
        if let interfaceName = defaultRouteInfo(family: .ipv4)?.interfaceName,
           let address = firstUsableAddress(family: AF_INET, matching: { $0 == interfaceName }) {
            return address
        }

        return firstUsableAddress(family: AF_INET) { name in
            name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ppp")
        }
    }

    func globalIPv6Address() -> String? {
        let routeInterface = defaultRouteInfo(family: .ipv6)?.interfaceName
        let candidates = addressCandidates(family: AF_INET6).map {
            LocalIPv6Candidate(
                interfaceName: $0.interfaceName,
                address: $0.address,
                attributes: ifconfigAttributes(interfaceName: $0.interfaceName, address: $0.address)
            )
        }
        return Self.selectGlobalIPv6Address(candidates: candidates, routeInterface: routeInterface)
    }

    func defaultGatewayIPv4() -> String? {
        defaultRouteInfo(family: .ipv4)?.gateway
    }

    func defaultGatewayIPv6() -> String? {
        defaultRouteInfo(family: .ipv6)?.gateway
    }

    func defaultRouteInterfaceIPv6() -> String? {
        defaultRouteInfo(family: .ipv6)?.interfaceName
    }

    func isTCPPortListening(port: UInt16, timeout: TimeInterval = 2) -> Bool {
        isTCPPortOpen(host: "127.0.0.1", port: port, timeout: timeout)
            || isTCPPortOpen(host: "::1", port: port, timeout: timeout)
    }

    func isTCPPortOpen(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 2) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        var arguments = ["-z", "-G", String(max(1, Int(timeout)))]
        if host.contains(":") {
            arguments.append("-6")
        }
        arguments.append(contentsOf: [host, String(port)])
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func firstUsableAddress(family: Int32, matching nameMatches: (String) -> Bool) -> String? {
        addressCandidates(family: family).first { nameMatches($0.interfaceName) }?.address
    }

    private func addressCandidates(family: Int32) -> [InterfaceAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [InterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer?.pointee {
            pointer = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback, let socketAddress = interface.ifa_addr else { continue }
            guard Int32(socketAddress.pointee.sa_family) == family else { continue }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            var address = String(cString: hostname)
            if let scopeIndex = address.firstIndex(of: "%") {
                address = String(address[..<scopeIndex])
            }
            candidates.append(InterfaceAddress(interfaceName: name, address: address))
        }
        return candidates
    }

    static func selectGlobalIPv6Address(
        candidates: [LocalIPv6Candidate],
        routeInterface: String?
    ) -> String? {
        candidates
            .filter {
                PublicIPService.isGlobalIPv6($0.address)
                    && isAllowedDDNSIPv6Interface($0.interfaceName)
                    && !$0.attributes.contains("temporary")
                    && !$0.attributes.contains("deprecated")
                    && !$0.attributes.contains("detached")
            }
            .max { lhs, rhs in
                ipv6Score(lhs, routeInterface: routeInterface) < ipv6Score(rhs, routeInterface: routeInterface)
            }?
            .address
    }

    static func isAllowedDDNSIPv6Interface(_ interfaceName: String) -> Bool {
        let name = interfaceName.lowercased()
        let blockedPrefixes = [
            "utun", "tun", "tap", "ipsec", "ppp", "gif", "stf",
            "awdl", "llw", "p2p", "lo", "vmnet", "vboxnet",
            "docker", "tailscale", "wireguard", "wg"
        ]
        return !blockedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func ipv6Score(_ candidate: LocalIPv6Candidate, routeInterface: String?) -> Int {
        var score = 0
        let name = candidate.interfaceName.lowercased()

        if candidate.interfaceName == routeInterface { score += 220 }
        if name.hasPrefix("en") { score += 140 }
        if name.hasPrefix("bridge") || name.hasPrefix("bond") || name.hasPrefix("vlan") { score += 80 }

        if candidate.attributes.contains("secured") { score += 35 }
        return score
    }

    static func interfaceAddressAttributes(in output: String, address: String) -> Set<String> {
        guard let targetAddress = normalizedIPv6WithoutScope(address) else { return [] }

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0].lowercased() == "inet6",
                  normalizedIPv6WithoutScope(fields[1]) == targetAddress else {
                continue
            }
            return Set(fields.dropFirst(2).map { $0.lowercased() })
        }
        return []
    }

    private static func normalizedIPv6WithoutScope(_ address: String) -> String? {
        let unscoped = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        return PublicIPService.normalizedIPv6(unscoped.lowercased())
    }

    private func ifconfigAttributes(interfaceName: String, address: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [interfaceName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else { return [] }
            return Self.interfaceAddressAttributes(in: output, address: address)
        } catch {
            return []
        }
    }

    private func defaultRouteInfo(family: RouteFamily) -> (gateway: String, interfaceName: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", family.routeArgument, "default"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }
        var gateway: String?
        var interfaceName: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interfaceName = trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let gateway, !gateway.isEmpty, let interfaceName, !interfaceName.isEmpty else { return nil }
        if family == .ipv6, gateway.contains(":"), !gateway.contains("%") {
            return ("\(gateway)%\(interfaceName)", interfaceName)
        }
        return (gateway, interfaceName)
    }
}

private struct InterfaceAddress {
    let interfaceName: String
    let address: String
}

struct LocalIPv6Candidate {
    let interfaceName: String
    let address: String
    let attributes: Set<String>
}

private enum RouteFamily {
    case ipv4
    case ipv6

    var routeArgument: String {
        self == .ipv4 ? "-inet" : "-inet6"
    }
}
