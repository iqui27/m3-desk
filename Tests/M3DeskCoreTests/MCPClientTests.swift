import Foundation
import Testing
@testable import M3DeskCore

private actor ScriptedMCPTransport: MCPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> MCPTransportResponse
    private let handler: Handler
    private var requests: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> MCPTransportResponse {
        let index = requests.count; requests.append(request)
        return try await handler(request, index)
    }
    func recordedRequests() -> [URLRequest] { requests }
}

private func rpcRequest(_ request: URLRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
}
private func response(_ value: JSONValue, status: Int = 200, session: String? = nil) throws -> MCPTransportResponse {
    var headers = ["Content-Type": "application/json"]
    if let session { headers["Mcp-Session-Id"] = session }
    let data = try JSONEncoder().encode(value)
    return MCPTransportResponse(statusCode: status, headers: headers, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
}
private func reply(_ request: URLRequest, result: JSONValue, session: String? = nil) throws -> MCPTransportResponse {
    try response(["jsonrpc": "2.0", "id": rpcRequest(request)["id"] ?? .null, "result": result], session: session)
}
private func initializedResponse(_ request: URLRequest, protocolVersion: String = "2025-03-26", tools: Bool = true) throws -> MCPTransportResponse {
    try reply(request, result: ["protocolVersion": .string(protocolVersion), "serverInfo": ["name": "Test", "version": "1"], "capabilities": tools ? ["tools": [:]] : [:]], session: "session-test")
}
private func notificationResponse() -> MCPTransportResponse {
    MCPTransportResponse(statusCode: 202, body: AsyncThrowingStream { $0.finish() })
}
private func toolList(_ names: [String] = ["memory_search"]) -> JSONValue {
    ["tools": .array(names.map { ["name": .string($0), "inputSchema": ["type": "object", "properties": ["idempotency_key": ["type": "string"]]]] })]
}
private func standardResponse(_ request: URLRequest) throws -> MCPTransportResponse {
    switch try rpcRequest(request)["method"]?.stringValue {
    case "initialize": return try initializedResponse(request)
    case "notifications/initialized": return notificationResponse()
    case "tools/list": return try reply(request, result: toolList())
    default: return try reply(request, result: ["content": [["type": "text", "text": "ok"]]])
    }
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class MCPClientTests {
    @Test func testReadOnlyAllowlistRejectsMutationBeforeNetworking() async {
        let transport = ScriptedMCPTransport { _, _ in Issue.record("unauthorized request reached network"); return notificationResponse() }
        let client = MCPClient(transport: transport)
        do { _ = try await client.callReadOnlyTool("memory_write"); Issue.record("mutation accepted") }
        catch { #expect((error as? MCPError) == (.permissionDenied("memory_write"))) }
        let requests = await transport.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test func testHandshakeNegotiatesVersionAndSendsInitializedBeforeTools() async throws {
        let transport = ScriptedMCPTransport { request, _ in try standardResponse(request) }
        let client = MCPClient(transport: transport)
        let text = try await client.callReadOnlyTool("memory_search", arguments: ["query": "retomar", "k": 2])
        #expect((text) == ("ok"))
        let requests = await transport.recordedRequests()
        #expect((try requests.map { try rpcRequest($0)["method"]?.stringValue }) == (["initialize", "notifications/initialized", "tools/list", "tools/call"]))
        #expect((requests[0].value(forHTTPHeaderField: "Mcp-Session-Id")) == nil)
        for request in requests.dropFirst() {
            #expect((request.value(forHTTPHeaderField: "Mcp-Session-Id")) == ("session-test"))
            #expect((request.value(forHTTPHeaderField: "MCP-Protocol-Version")) == ("2025-03-26"))
        }
        #expect((try rpcRequest(requests[1])["id"]) == nil)
        let info = await client.connectionInfo()
        #expect((info?.protocolVersion) == ("2025-03-26"))
    }

    @Test func testConcurrentInitializeIsSingleFlightAndOneCancelledWaiterDoesNotCancelOthers() async throws {
        let transport = ScriptedMCPTransport { request, _ in
            if try rpcRequest(request)["method"] == "initialize" { try await Task.sleep(for: .milliseconds(80)) }
            return try standardResponse(request)
        }
        let client = MCPClient(transport: transport)
        let first = Task { try await client.initialize() }
        let second = Task { try await client.initialize() }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        do { _ = try await first.value; Issue.record("canceled waiter succeeded") } catch { #expect(error is CancellationError) }
        let info = try await second.value
        #expect((info.name) == ("Test"))
        _ = try await client.initialize()
        let requests = await transport.recordedRequests()
        #expect((requests.count) == (2))
    }

    @Test func testCancelledTransportHandshakeCanReconnect() async throws {
        let transport = ScriptedMCPTransport { request, index in
            if index == 0 { throw URLError(.cancelled) }
            return try standardResponse(request)
        }
        let client = MCPClient(transport: transport)
        do { _ = try await client.initialize(); Issue.record("canceled transport succeeded") }
        catch { #expect(error is CancellationError) }
        let info = try await client.initialize()
        #expect(info.name == "Test")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
    }

    @Test func testUnsupportedProtocolNeverBecomesReady() async throws {
        let transport = ScriptedMCPTransport { request, _ in try initializedResponse(request, protocolVersion: "2099-01-01") }
        let client = MCPClient(transport: transport)
        do { _ = try await client.initialize(); Issue.record("unknown version accepted") }
        catch { #expect((error as? MCPError) == (.unsupportedProtocol("2099-01-01"))) }
        let info = await client.connectionInfo()
        #expect((info) == nil)
    }

    @Test func testInitializedFailureCanReconnect() async throws {
        let transport = ScriptedMCPTransport { request, index in
            if index == 1 { return try response([:], status: 500) }
            return try standardResponse(request)
        }
        let client = MCPClient(transport: transport)
        do { _ = try await client.initialize(); Issue.record("notification failure ignored") } catch { #expect((error as? MCPError) == (.http(500))) }
        let firstInfo = await client.connectionInfo()
        #expect((firstInfo) == nil)
        _ = try await client.initialize()
        let requests = await transport.recordedRequests()
        #expect((requests.count) == (4))
    }

    @Test func testMissingToolsCapabilityAndUnadvertisedToolAreRejected() async throws {
        let noTools = ScriptedMCPTransport { request, _ in
            if try rpcRequest(request)["method"] == "initialize" { return try initializedResponse(request, tools: false) }
            return notificationResponse()
        }
        do { _ = try await MCPClient(transport: noTools).listTools(); Issue.record("missing capability accepted") }
        catch { #expect((error as? MCPError) == (.unsupportedCapability("tools"))) }
        let transport = ScriptedMCPTransport { request, _ in try standardResponse(request) }
        do { _ = try await MCPClient(transport: transport).callReadOnlyTool("memory_get"); Issue.record("unadvertised tool accepted") }
        catch { #expect((error as? MCPError) == (.toolNotAdvertised("memory_get"))) }
    }

    @Test func testRead404ReinitializesAndRefreshesCatalogExactlyOnce() async throws {
        let transport = ScriptedMCPTransport { request, index in
            if index == 3 { return try response([:], status: 404) }
            return try standardResponse(request)
        }
        let result = try await MCPClient(transport: transport).callReadOnlyTool("memory_search")
        #expect((result) == ("ok"))
        let requests = await transport.recordedRequests()
        #expect((try requests.map { try rpcRequest($0)["method"]?.stringValue }) == (["initialize", "notifications/initialized", "tools/list", "tools/call", "initialize", "notifications/initialized", "tools/list", "tools/call"]))
    }

    @Test func testMutationRequiresIdempotencySchemaAndIsNeverAutomaticallyReplayed() async throws {
        let transport = ScriptedMCPTransport { request, _ in
            let method = try rpcRequest(request)["method"]
            if method == "tools/list" { return try reply(request, result: toolList(["scoped_write"])) }
            if method == "tools/call" { return try response([:], status: 404) }
            return try standardResponse(request)
        }
        let client = MCPClient(transport: transport)
        let permit = MCPMutationPermit(toolName: "scoped_write", permissionID: "verified-write", idempotencyArgument: "idempotency_key", idempotencyKey: "stable-key")
        do { _ = try await client.callTool("scoped_write", arguments: [:], authorization: .mutation(permit)); Issue.record("missing key accepted") }
        catch { #expect((error as? MCPError) == (.permissionDenied("scoped_write"))) }
        do { _ = try await client.callTool("scoped_write", arguments: ["idempotency_key": "stable-key"], authorization: .mutation(permit)); Issue.record("expired mutation accepted") }
        catch { #expect((error as? MCPError) == (.sessionExpired)) }
        let requests = await transport.recordedRequests()
        #expect((try requests.filter { try rpcRequest($0)["method"] == "tools/call" }.count) == (1))
    }

    @Test func testSSEMatchesResponseAfterNotificationsAndPreservesAllBlocks() async throws {
        let canceled = CancellationFlag()
        let transport = ScriptedMCPTransport { request, _ in
            guard try rpcRequest(request)["method"] == "tools/call" else { return try standardResponse(request) }
            let id = try #require(rpcRequest(request)["id"]?.stringValue)
            let payload: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "result": ["content": [["type": "text", "text": "ação 🧭"], ["type": "image", "data": "AA==", "mimeType": "image/png"], ["type": "text", "text": "segundo"]], "structuredContent": ["count": 2], "isError": true]]
            let frame = ": keepalive\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\ndata: \(try payload.encodedString())\r\n\r\n"
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            for byte in Data(frame.utf8) { continuation.yield(Data([byte])) }
            // The server may leave the stream open after its reply; the client must release it.
            return MCPTransportResponse(statusCode: 200, headers: ["CONTENT-TYPE": "text/event-stream; charset=utf-8"], body: stream, cancel: { canceled.mark(); continuation.finish() })
        }
        let result = try await MCPClient(transport: transport).callTool("memory_search")
        #expect(result.isError)
        #expect((result.content.count) == (3))
        #expect((result.text) == ("ação 🧭\nsegundo"))
        #expect((result.content[1].mimeType) == ("image/png"))
        #expect((result.structuredContent?["count"]) == (2))
        #expect(canceled.isMarked)
    }

    @Test func testTextConvenienceThrowsToolErrorInsteadOfDisplayingSuccess() async throws {
        let transport = ScriptedMCPTransport { request, _ in
            if try rpcRequest(request)["method"] == "tools/call" { return try reply(request, result: ["content": [["type": "text", "text": "denied"]], "isError": true]) }
            return try standardResponse(request)
        }
        do { _ = try await MCPClient(transport: transport).callReadOnlyTool("memory_search"); Issue.record("isError ignored") }
        catch { #expect((error as? MCPError) == (.tool("denied"))) }
    }

    @Test func testTimeoutAndCallerCancellationReleaseStreamingBody() async throws {
        let timeoutFlag = CancellationFlag()
        let transport = ScriptedMCPTransport { _, _ in
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            return MCPTransportResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: stream, cancel: { timeoutFlag.mark(); continuation.finish() })
        }
        do { _ = try await MCPClient(timeout: 0.03, transport: transport).initialize(); Issue.record("stalled stream succeeded") }
        catch { #expect((error as? MCPError) == (.timeout)) }
        #expect(timeoutFlag.isMarked)
        let canceled = CancellationFlag()
        let callTransport = ScriptedMCPTransport { request, _ in
            if try rpcRequest(request)["method"] != "tools/call" { return try standardResponse(request) }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            return MCPTransportResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: stream, cancel: { canceled.mark(); continuation.finish() })
        }
        let client = MCPClient(transport: callTransport)
        let task = Task { try await client.callReadOnlyTool("memory_search") }
        for _ in 0..<100 {
            if await callTransport.recordedRequests().count == 4 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("canceled request succeeded") } catch { #expect(error is CancellationError) }
        #expect(canceled.isMarked)
    }

    @Test func testRPCErrorMalformedJSONAndWrongIDAreRejected() async throws {
        for mode in 0..<3 {
            let transport = ScriptedMCPTransport { request, _ in
                guard try rpcRequest(request)["method"] == "tools/call" else { return try standardResponse(request) }
                if mode == 0 { return try response(["jsonrpc": "2.0", "id": rpcRequest(request)["id"]!, "error": ["code": -32602, "message": "bad args"]]) }
                if mode == 1 { return MCPTransportResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: AsyncThrowingStream { $0.yield(Data("not json".utf8)); $0.finish() }) }
                return try response(["jsonrpc": "2.0", "id": "foreign", "result": [:]])
            }
            do { _ = try await MCPClient(transport: transport).callTool("memory_search"); Issue.record("invalid result accepted") }
            catch { #expect((error as? MCPError) == (mode == 0 ? .rpc(code: -32602, message: "bad args") : .invalidResponse)) }
        }
    }

    @Test func testPaginationLoopRejected() async throws {
        let transport = ScriptedMCPTransport { request, index in
            if try rpcRequest(request)["method"] == "tools/list" { return try reply(request, result: ["tools": [], "nextCursor": "same"]) }
            return try standardResponse(request)
        }
        do { _ = try await MCPClient(transport: transport).listTools(); Issue.record("cursor loop accepted") }
        catch { #expect((error as? MCPError) == (.paginationLoop)) }
    }

    @Test func testIncrementalSSEMultilineBOMCRLFAndIncompleteEOF() throws {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        let source = "\u{FEFF}:comment\r\nid: 7\r\nevent: update\r\ndata: ação\r\ndata: 🧭\r\n\r\nid: bad\0id\ndata: next\n\ndata: unfinished"
        for byte in Data(source.utf8) { events += try parser.feed(Data([byte])) }
        #expect((events) == ([.init(event: "update", id: "7", data: "ação\n🧭"), .init(event: "message", id: "7", data: "next")]))
        var limited = SSEParser(maximumEventBytes: 8)
        expectFailure(try limited.feed(Data("data: oversized\n\n".utf8))) { #expect(($0 as? MCPError) == (.responseTooLarge)) }
        var invalid = SSEParser()
        expectFailure(try invalid.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 10])))
    }

    @Test func testLargeIntegerAndUnknownContentFieldsRoundTrip() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"id\":9007199254740993}".utf8))
        #expect((value["id"]?.integerValue) == (9_007_199_254_740_993))
        let block = MCPContentBlock(value: ["type": "future", "nested": ["unknown": true]])
        #expect((try JSONDecoder().decode(MCPContentBlock.self, from: JSONEncoder().encode(block))) == (block))
    }
}

// Reports a missing throw through Swift Testing while retaining focused checks of the error payload.
func expectFailure<Value>(_ value: @autoclosure () throws -> Value, _ check: (any Error) -> Void = { _ in }) {
    do { _ = try value(); Issue.record("Expected operation to throw") } catch { check(error) }
}
