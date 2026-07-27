import Foundation
import Darwin

final class LocalNetworkService {
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
        let candidates = addressCandidates(family: AF_INET6).filter {
            PublicIPService.isGlobalIPv6($0.address)
        }
        return candidates.max { lhs, rhs in
            ipv6Score(lhs, routeInterface: routeInterface) < ipv6Score(rhs, routeInterface: routeInterface)
        }?.address
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

    private func ipv6Score(_ candidate: InterfaceAddress, routeInterface: String?) -> Int {
        var score = 0
        let name = candidate.interfaceName.lowercased()
        let isTunnel = name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap")
            || name.hasPrefix("ipsec") || name.hasPrefix("gif") || name.hasPrefix("stf")

        if candidate.interfaceName == routeInterface { score += isTunnel ? 20 : 220 }
        if name.hasPrefix("en") { score += 140 }
        if name.hasPrefix("bridge") || name.hasPrefix("ppp") { score += 80 }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { score -= 220 }
        if isTunnel { score -= 260 }

        let attributes = ifconfigAttributes(interfaceName: candidate.interfaceName, address: candidate.address)
        if attributes.contains("secured") { score += 35 }
        if attributes.contains("temporary") { score -= 45 }
        if attributes.contains("deprecated") || attributes.contains("detached") { score -= 180 }
        return score
    }

    private func ifconfigAttributes(interfaceName: String, address: String) -> String {
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
            return output.components(separatedBy: .newlines).first {
                $0.contains("inet6 (address) ") || $0.contains("inet6 (address)%")
            }?.lowercased() ?? ""
        } catch {
            return ""
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

private enum RouteFamily {
    case ipv4
    case ipv6

    var routeArgument: String {
        self == .ipv4 ? "-inet" : "-inet6"
    }
}
