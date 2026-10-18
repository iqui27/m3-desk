import Foundation

/// Lossless JSON at actor boundaries. Integer identifiers are never rounded through Double.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integerValue: Int64? { if case .integer(let value) = self { value } else { nil } }
    public func encodedString() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

extension JSONValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int64) { self = .integer(value) } }
extension JSONValue: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .number(value) } }
extension JSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSONValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: JSONValue...) { self = .array(elements) } }
extension JSONValue: ExpressibleByDictionaryLiteral { public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) } }

public struct MCPServerInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) { self.name = name; self.version = version }
}

public struct MCPInitialization: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let serverInfo: MCPServerInfo
    public let capabilities: JSONValue
    public let instructions: String?
    public var supportsTools: Bool { capabilities["tools"]?.objectValue != nil }
}

public struct MCPTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let annotations: JSONValue?
    public var readOnlyHint: Bool? { annotations?["readOnlyHint"]?.boolValue }
    public init(name: String, description: String? = nil, inputSchema: JSONValue,
                outputSchema: JSONValue? = nil, annotations: JSONValue? = nil) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
        self.outputSchema = outputSchema; self.annotations = annotations
    }
}

/// Retains every field (including annotations and future block types), with typed common accessors.
public struct MCPContentBlock: Codable, Equatable, Sendable {
    public let value: JSONValue
    public var type: String { value["type"]?.stringValue ?? "unknown" }
    public var text: String? { type == "text" ? value["text"]?.stringValue : nil }
    public var resource: JSONValue? { value["resource"] }
    public var mimeType: String? { value["mimeType"]?.stringValue }
    public init(value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct MCPToolResult: Codable, Equatable, Sendable {
    public let content: [MCPContentBlock]
    public let structuredContent: JSONValue?
    public let isError: Bool
    public let meta: JSONValue?
    public var text: String { content.compactMap(\.text).joined(separator: "\n") }
    enum CodingKeys: String, CodingKey { case content, structuredContent, isError; case meta = "_meta" }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode([MCPContentBlock].self, forKey: .content)
        structuredContent = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }
}

/// The service creates this only after checking its versioned backend capability and actual permission.
/// Tool annotations are hints, and are deliberately insufficient to authorize a mutation.
public struct MCPMutationPermit: Equatable, Sendable {
    public let toolName: String
    public let permissionID: String
    public let idempotencyArgument: String
    public let idempotencyKey: String
    public init(toolName: String, permissionID: String, idempotencyArgument: String, idempotencyKey: String) {
        self.toolName = toolName; self.permissionID = permissionID
        self.idempotencyArgument = idempotencyArgument; self.idempotencyKey = idempotencyKey
    }
}

public enum MCPToolAuthorization: Sendable {
    /// Restricted to the client's legacy read-only allowlist; still requires an advertised tool.
    case readOnly
    /// For new, server-authorized scoped contracts; the service verifies permission before passing it.
    case scopedRead(toolName: String, permissionID: String)
    case mutation(MCPMutationPermit)
}

public enum MCPError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unsupportedProtocol(String)
    case unsupportedCapability(String)
    case permissionDenied(String)
    case toolNotAdvertised(String)
    case server(String)
    case rpc(code: Int64, message: String)
    case tool(String)
    case timeout
    case transport(String)
    case http(Int)
    case sessionExpired
    case responseTooLarge
    case paginationLoop

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Resposta MCP inválida ou sem o identificador esperado"
        case .unsupportedProtocol(let value): "Versão MCP não suportada: \(value)"
        case .unsupportedCapability(let value): "Capacidade MCP indisponível: \(value)"
        case .permissionDenied(let name): "Ferramenta não permitida neste cliente: \(name)"
        case .toolNotAdvertised(let name): "Ferramenta não anunciada pelo servidor: \(name)"
        case .server(let message), .tool(let message): message
        case .rpc(let code, let message): "MCP \(code): \(message)"
        case .timeout: "MCP excedeu o tempo limite"
        case .transport(let message): "MCP indisponível: \(message)"
        case .http(let status): "MCP retornou HTTP \(status)"
        case .sessionExpired: "Sessão MCP expirada; reconecte antes de confirmar outra operação"
        case .responseTooLarge: "Resposta MCP excedeu o limite de tamanho"
        case .paginationLoop: "Paginação MCP inválida"
        }
    }
}
