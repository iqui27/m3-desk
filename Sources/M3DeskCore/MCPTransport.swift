import Foundation

public struct MCPTransportResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>
    /// Releases a streaming HTTP response even when the matching RPC arrives before stream EOF.
    public let cancel: @Sendable () -> Void
    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.statusCode = statusCode; self.headers = headers; self.body = body; self.cancel = cancel
    }
    public func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

public protocol MCPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MCPTransportResponse
}

public struct URLSessionMCPTransport: MCPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> MCPTransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let reader = Task {
            do {
                var chunk = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    // Yield complete SSE lines promptly; also bound binary/JSON chunk size.
                    if byte == 10 || byte == 13 || chunk.count >= 4096 {
                        continuation.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in reader.cancel() }
        return MCPTransportResponse(statusCode: http.statusCode, headers: headers, body: body, cancel: {
            reader.cancel()
            continuation.finish()
        })
    }
}

/// A caller can cancel its wait without canceling a connection shared with another caller.
private final class MCPTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

func awaitMCPCancellable<Value: Sendable>(_ task: Task<Value, Error>) async throws -> Value {
    let waiter = MCPTaskWaiter<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
            Task { waiter.finish(await task.result) }
        }
    } onCancel: { waiter.finish(.failure(CancellationError())) }
}
