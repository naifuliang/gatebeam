import Foundation
import CFNetwork

struct HTTPResponse {
    let statusCode: Int
    let data: Data
    let headers: [AnyHashable: Any]

    var text: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

struct HTTPRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
}

protocol HTTPRequesting {
    func request(_ request: HTTPRequest) throws -> HTTPResponse
}

extension HTTPRequesting {
    func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) throws -> HTTPResponse {
        try request(HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: timeout))
    }
}

final class HTTPClient: HTTPRequesting {
    private let session: URLSession

    init(useSystemProxy: Bool = true) {
        session = useSystemProxy
            ? .shared
            : Self.makeSession(mode: .direct, proxyURL: nil)
    }

    init(proxyMode: NetworkProxyMode, customProxyURL: String = "") throws {
        let proxyURL: URL?
        if proxyMode == .custom {
            proxyURL = try Self.validatedProxyURL(customProxyURL)
        } else {
            proxyURL = nil
        }
        session = Self.makeSession(mode: proxyMode, proxyURL: proxyURL)
    }

    static func validatedProxyURL(_ value: String) throws -> URL {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatMessage = "Use http://host:port or socks5://host:port without credentials, a path, query, or fragment"
        guard !normalized.isEmpty,
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "socks5"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw NetworkError.invalidProxyURL(formatMessage)
        }

        guard let port = components.port, (1...65_535).contains(port) else {
            throw NetworkError.invalidProxyURL("The custom proxy port must be between 1 and 65535")
        }

        guard let url = components.url else {
            throw NetworkError.invalidProxyURL("The custom proxy URL is invalid")
        }
        return url
    }

    private static func makeSession(mode: NetworkProxyMode, proxyURL: URL?) -> URLSession {
        if mode == .system {
            return .shared
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        switch mode {
        case .system:
            assertionFailure("System proxy mode should use URLSession.shared")
        case .direct:
            configuration.connectionProxyDictionary = disabledProxyDictionary
        case .custom:
            guard let proxyURL else {
                configuration.connectionProxyDictionary = disabledProxyDictionary
                break
            }
            configuration.connectionProxyDictionary = customProxyDictionary(for: proxyURL)
        }
        return URLSession(configuration: configuration)
    }

    private static var disabledProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false
        ]
    }

    private static func customProxyDictionary(for url: URL) -> [AnyHashable: Any] {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = normalizedProxyHost(url.host ?? "")
        let port = url.port ?? 0
        var dictionary = disabledProxyDictionary

        if scheme == "socks5" {
            dictionary[kCFNetworkProxiesSOCKSEnable as String] = true
            dictionary[kCFNetworkProxiesSOCKSProxy as String] = host
            dictionary[kCFNetworkProxiesSOCKSPort as String] = port
        } else {
            dictionary[kCFNetworkProxiesHTTPEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPPort as String] = port
            dictionary[kCFNetworkProxiesHTTPSEnable as String] = true
            dictionary[kCFNetworkProxiesHTTPSProxy as String] = host
            dictionary[kCFNetworkProxiesHTTPSPort as String] = port
        }

        return dictionary
    }

    private static func normalizedProxyHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else {
            return host
        }
        return String(host.dropFirst().dropLast())
    }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
        try self.request(
            request,
            cancellationHandler: { false }
        )
    }

    func request(
        _ request: HTTPRequest,
        cancellationHandler: () -> Bool
    ) throws -> HTTPResponse {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var responseError: Error?

        let task = session.dataTask(with: urlRequest) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            responseError = error
            semaphore.signal()
        }
        task.resume()

        let deadline = ProcessInfo.processInfo.systemUptime
            + request.timeout + 2
        while true {
            if cancellationHandler() {
                task.cancel()
                throw NetworkError.cancelled
            }
            let remaining = deadline
                - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                task.cancel()
                throw NetworkError.timeout
            }
            if semaphore.wait(
                timeout: .now() + min(0.05, remaining)
            ) == .success {
                break
            }
        }

        if cancellationHandler() {
            task.cancel()
            throw NetworkError.cancelled
        }
        if let responseError {
            throw responseError
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.noHTTPResponse
        }

        return HTTPResponse(statusCode: http.statusCode, data: responseData ?? Data(), headers: http.allHeaderFields)
    }
}

enum NetworkError: Error, LocalizedError {
    case noHTTPResponse
    case invalidResponse(String)
    case invalidProxyURL(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noHTTPResponse:
            return "No HTTP response"
        case .invalidResponse(let value):
            return "Invalid response: \(value)"
        case .invalidProxyURL(let value):
            return "Invalid proxy URL: \(value)"
        case .timeout:
            return "Request timed out"
        case .cancelled:
            return "Request cancelled"
        }
    }
}
