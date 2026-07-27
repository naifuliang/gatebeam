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
        guard !normalized.isEmpty,
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks", "socks5"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw NetworkError.invalidProxyURL(
                "Use http://host:port, https://host:port, or socks5://host:port without credentials, a path, query, or fragment"
            )
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
        let host = url.host ?? ""
        let port = url.port ?? defaultProxyPort(for: scheme)
        var dictionary = disabledProxyDictionary

        if scheme == "socks" || scheme == "socks5" {
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

    private static func defaultProxyPort(for scheme: String) -> Int {
        switch scheme {
        case "https": return 443
        case "socks", "socks5": return 1080
        default: return 80
        }
    }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
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

        if semaphore.wait(timeout: .now() + request.timeout + 2) == .timedOut {
            task.cancel()
            throw NetworkError.timeout
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
        }
    }
}
