import Foundation

public struct PlatformHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode; self.headers = headers; self.data = data
    }
    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

public protocol PlatformTransport: Sendable {
    /// Implementations must honor task cancellation and must not forward authenticated redirects.
    func send(_ request: URLRequest) async throws -> PlatformHTTPResponse
}

private final class PlatformSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A private ephemeral session prevents credentials and responses entering shared URL caches/cookies.
public final class URLSessionPlatformTransport: PlatformTransport, Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: PlatformSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> PlatformHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlatformClientError.malformedResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8 * 1024 * 1024 else { throw PlatformClientError.responseTooLarge }
            data.append(byte)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        }
        return PlatformHTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}
