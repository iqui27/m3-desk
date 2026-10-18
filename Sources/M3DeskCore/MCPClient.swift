import Foundation

public actor MCPClient {
    public let endpoint: URL
    public let timeout: TimeInterval
    private let transport: any MCPTransport
    private var session: Session?
    private var connecting: Task<Session, Error>?
    private var connectingID: UUID?
    private var connectionGeneration = UUID()
    private var toolCache: [MCPTool]?

    private struct Session: Sendable {
        let generation: UUID
        let id: String?
        let initialization: MCPInitialization
    }
    private struct Reply: Sendable {
        let result: JSONValue
        let sessionID: String?
    }
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26"]
    private static let legacyReadOnlyTools: Set<String> = [
        "memory_search", "memory_get", "memory_search_slim", "conversation_search",
        "task_list", "task_get", "task_tree", "entity_search", "entity_get", "entity_mentions",
        "tools_list_domains", "tools_load_domain"
    ]

    public init(endpoint: URL = URL(string: "http://127.0.0.1:18080/mcp")!,
                timeout: TimeInterval = 8, transport: any MCPTransport = URLSessionMCPTransport()) {
        self.endpoint = endpoint
        self.timeout = max(0.01, timeout.isFinite ? timeout : 8)
        self.transport = transport
    }

    /// Single-flight handshake: ready only after initialize AND notifications/initialized succeed.
    @discardableResult
    public func initialize() async throws -> MCPServerInfo { try await ensureConnected().initialization.serverInfo }
    public func connectionInfo() -> MCPInitialization? { session?.initialization }

    /// Invalidates local state; does not terminate a server session still used by in-flight requests.
    public func disconnect() {
        connectionGeneration = UUID()
        connecting?.cancel()
        connecting = nil
        connectingID = nil
        session = nil
        toolCache = nil
    }

    public func listTools(refresh: Bool = false) async throws -> [MCPTool] {
        try Task.checkCancellation()
        if !refresh, let toolCache, session != nil { return toolCache }
        for attempt in 0...1 {
            let active = try await ensureConnected()
            guard active.initialization.supportsTools else { throw MCPError.unsupportedCapability("tools") }
            do {
                var tools: [MCPTool] = []
                var names = Set<String>()
                var cursors = Set<String>()
                var cursor: String?
                repeat {
                    try Task.checkCancellation()
                    guard cursors.count < 100 else { throw MCPError.paginationLoop }
                    let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
                    let result = try await rpc(method: "tools/list", params: params, session: active)
                    guard let values = result["tools"]?.arrayValue else { throw MCPError.invalidResponse }
                    for value in values {
                        let tool = try Self.decode(MCPTool.self, from: value)
                        guard !tool.name.isEmpty, tool.inputSchema.objectValue != nil,
                              names.insert(tool.name).inserted else { throw MCPError.invalidResponse }
                        tools.append(tool)
                        guard tools.count <= 10_000 else { throw MCPError.responseTooLarge }
                    }
                    if let next = result["nextCursor"], next != .null {
                        guard let nextCursor = next.stringValue, !nextCursor.isEmpty,
                              cursors.insert(nextCursor).inserted else { throw MCPError.paginationLoop }
                        cursor = nextCursor
                    } else { cursor = nil }
                } while cursor != nil
                guard active.generation == connectionGeneration else { throw CancellationError() }
                toolCache = tools
                return tools
            } catch MCPError.sessionExpired {
                invalidate(active)
                if attempt == 1 { throw MCPError.sessionExpired }
                // A new session restarts the complete catalog; never mix pages from two sessions.
            }
        }
        throw MCPError.sessionExpired
    }

    public func callReadOnlyTool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> String {
        let result = try await callTool(name, arguments: arguments, authorization: .readOnly)
        if result.isError { throw MCPError.tool(result.text.isEmpty ? "Ferramenta MCP retornou erro" : result.text) }
        if !result.text.isEmpty { return result.text }
        if let structured = result.structuredContent { return try structured.encodedString() }
        return ""
    }

    /// Mutations require an explicit service permit, advertised schema, and a matching idempotency key.
    /// Only reads are replayed after HTTP 404. A timeout on a mutation has an unknown outcome.
    public func callTool(_ name: String, arguments: [String: JSONValue] = [:],
                         authorization: MCPToolAuthorization = .readOnly) async throws -> MCPToolResult {
        let isReadOnly = try Self.validateAuthorization(authorization, name: name)
        for attempt in 0...(isReadOnly ? 1 : 0) {
            try Task.checkCancellation()
            let tools = try await listTools()
            guard let tool = tools.first(where: { $0.name == name }) else { throw MCPError.toolNotAdvertised(name) }
            try Self.validateMutation(authorization, tool: tool, arguments: arguments)
            let active = try await ensureConnected()
            do {
                let value = try await rpc(method: "tools/call", params: ["name": .string(name), "arguments": .object(arguments)], session: active)
                return try Self.decode(MCPToolResult.self, from: value)
            } catch MCPError.sessionExpired {
                invalidate(active)
                guard isReadOnly, attempt == 0 else { throw MCPError.sessionExpired }
            }
        }
        throw MCPError.sessionExpired
    }

    private func ensureConnected() async throws -> Session {
        try Task.checkCancellation()
        if let session { return session }
        let generation = connectionGeneration
        let task: Task<Session, Error>
        let attemptID: UUID
        if let connecting, let connectingID { task = connecting; attemptID = connectingID }
        else {
            attemptID = UUID()
            connectingID = attemptID
            let endpoint = endpoint, timeout = timeout, transport = transport
            task = Task {
                let reply = try await Self.sendRPC(endpoint: endpoint, timeout: timeout, transport: transport,
                    method: "initialize", params: [
                        "protocolVersion": .string(Self.supportedProtocolVersions[0]),
                        "capabilities": [:], "clientInfo": ["name": "M3Desk", "version": "0.2"]
                    ], sessionID: nil, protocolVersion: nil)
                let initialization = try Self.decode(MCPInitialization.self, from: reply.result)
                guard Self.supportedProtocolVersions.contains(initialization.protocolVersion) else {
                    throw MCPError.unsupportedProtocol(initialization.protocolVersion)
                }
                guard initialization.capabilities.objectValue != nil,
                      !initialization.serverInfo.name.isEmpty else { throw MCPError.invalidResponse }
                try await Self.sendInitialized(endpoint: endpoint, timeout: timeout, transport: transport,
                    sessionID: reply.sessionID, protocolVersion: initialization.protocolVersion)
                return Session(generation: generation, id: reply.sessionID, initialization: initialization)
            }
            connecting = task
        }
        do {
            let established = try await awaitMCPCancellable(task)
            try Task.checkCancellation()
            guard connectionGeneration == generation else { throw CancellationError() }
            session = established
            if connectingID == attemptID { connecting = nil; connectingID = nil }
            return established
        } catch {
            // A canceled waiter does not erase or cancel a handshake shared with other callers.
            if connectionGeneration == generation, connectingID == attemptID, !Task.isCancelled { connecting = nil; connectingID = nil }
            throw error
        }
    }

    private func invalidate(_ active: Session) {
        guard active.generation == connectionGeneration else { return }
        disconnect()
    }

    private func rpc(method: String, params: JSONValue, session active: Session) async throws -> JSONValue {
        let reply = try await Self.sendRPC(endpoint: endpoint, timeout: timeout, transport: transport,
            method: method, params: params, sessionID: active.id,
            protocolVersion: active.initialization.protocolVersion)
        guard active.generation == connectionGeneration else { throw CancellationError() }
        return reply.result
    }

    private static func validateAuthorization(_ authorization: MCPToolAuthorization, name: String) throws -> Bool {
        switch authorization {
        case .readOnly:
            guard legacyReadOnlyTools.contains(name) else { throw MCPError.permissionDenied(name) }
            return true
        case .scopedRead(let toolName, let permissionID):
            guard toolName == name, !permissionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.permissionDenied(name)
            }
            return true
        case .mutation(let permit):
            guard permit.toolName == name, !permit.permissionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !permit.idempotencyArgument.isEmpty, !permit.idempotencyKey.isEmpty else {
                throw MCPError.permissionDenied(name)
            }
            return false
        }
    }

    private static func validateMutation(_ authorization: MCPToolAuthorization, tool: MCPTool,
                                         arguments: [String: JSONValue]) throws {
        guard case .mutation(let permit) = authorization else { return }
        guard tool.inputSchema["properties"]?[permit.idempotencyArgument]?["type"]?.stringValue == "string",
              arguments[permit.idempotencyArgument]?.stringValue == permit.idempotencyKey else {
            throw MCPError.permissionDenied(tool.name)
        }
    }

    private static func request(endpoint: URL, timeout: TimeInterval, body: JSONValue,
                                sessionID: String?, protocolVersion: String?) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func sendRPC(endpoint: URL, timeout: TimeInterval, transport: any MCPTransport,
                                method: String, params: JSONValue, sessionID: String?, protocolVersion: String?) async throws -> Reply {
        let id = UUID().uuidString
        let request = try request(endpoint: endpoint, timeout: timeout,
            body: ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params],
            sessionID: sessionID, protocolVersion: protocolVersion)
        return try await withTimeout(timeout) {
            let response = try await transport.send(request)
            defer { response.cancel() }
            try validateStatus(response.statusCode, hasSession: sessionID != nil)
            let receivedSession = response.header("Mcp-Session-Id")
            if let receivedSession {
                guard !receivedSession.isEmpty, receivedSession.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
                    throw MCPError.invalidResponse
                }
            }
            let contentType = response.header("Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            if contentType == "text/event-stream" {
                var parser = SSEParser()
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    for event in try parser.feed(chunk) where !event.data.isEmpty {
                        let value = try decodeJSON(Data(event.data.utf8))
                        if let result = try matchingResult(value, id: id) { return Reply(result: result, sessionID: receivedSession) }
                    }
                }
                throw MCPError.invalidResponse
            }
            guard contentType == "application/json" else { throw MCPError.invalidResponse }
            var body = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard body.count + chunk.count <= 8 * 1024 * 1024 else { throw MCPError.responseTooLarge }
                body.append(chunk)
            }
            guard let result = try matchingResult(decodeJSON(body), id: id) else { throw MCPError.invalidResponse }
            return Reply(result: result, sessionID: receivedSession)
        }
    }

    private static func sendInitialized(endpoint: URL, timeout: TimeInterval, transport: any MCPTransport,
                                        sessionID: String?, protocolVersion: String) async throws {
        let request = try request(endpoint: endpoint, timeout: timeout,
            body: ["jsonrpc": "2.0", "method": "notifications/initialized"],
            sessionID: sessionID, protocolVersion: protocolVersion)
        try await withTimeout(timeout) {
            let response = try await transport.send(request)
            defer { response.cancel() }
            try validateStatus(response.statusCode, hasSession: sessionID != nil)
            guard response.statusCode == 202 || response.statusCode == 204 else { throw MCPError.invalidResponse }
            // Notifications have no JSON-RPC response. Drain the empty acknowledgement for cleanup.
            var bytes = 0
            for try await chunk in response.body {
                try Task.checkCancellation()
                bytes += chunk.count
                guard bytes <= 4096 else { throw MCPError.invalidResponse }
                guard String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
                    throw MCPError.invalidResponse
                }
            }
        }
    }

    private static func matchingResult(_ message: JSONValue, id: String) throws -> JSONValue? {
        // The negotiated March version still allows batches. Each member is matched by ID.
        if let messages = message.arrayValue {
            for value in messages { if let result = try matchingResult(value, id: id) { return result } }
            return nil
        }
        guard message.objectValue != nil, message["jsonrpc"] == "2.0" else { throw MCPError.invalidResponse }
        if message["method"] != nil { return nil } // Server notifications/requests are not this response.
        guard message["id"] == .string(id) else { return nil }
        if let error = message["error"] {
            guard message["result"] == nil, let code = error["code"]?.integerValue,
                  let text = error["message"]?.stringValue else { throw MCPError.invalidResponse }
            throw MCPError.rpc(code: code, message: text)
        }
        guard let result = message["result"] else { throw MCPError.invalidResponse }
        return result
    }

    private static func validateStatus(_ status: Int, hasSession: Bool) throws {
        if status == 404, hasSession { throw MCPError.sessionExpired }
        guard (200..<300).contains(status) else { throw MCPError.http(status) }
    }
    private static func decodeJSON(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw MCPError.invalidResponse }
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw MCPError.invalidResponse }
    }
    private static func withTimeout<Value: Sendable>(_ timeout: TimeInterval,
                                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); throw MCPError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw MCPError.invalidResponse }
                return value
            }
        } catch {
            // AsyncThrowingStream may end normally on cancellation; preserve the caller's cancellation
            // even when that EOF was tentatively decoded as an incomplete RPC response.
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? MCPError { throw error }
            if let error = error as? URLError {
                if error.code == .timedOut { throw MCPError.timeout }
                if error.code == .cancelled { throw CancellationError() }
            }
            throw MCPError.transport(error.localizedDescription)
        }
    }
}
