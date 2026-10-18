import Foundation

public let platformSchemaVersion = "m3.platform.v1"

public enum PlatformClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint, missingCredential, unauthenticated, forbidden, conflict
    case contractMismatch(String), malformedResponse, invalidRequest, redirectDenied
    case timeout, connectionChanged, responseTooLarge
    case server(status: Int, code: String, retryable: Bool)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use HTTPS ou um endereço de loopback para a API Platform."
        case .missingCredential: "Informe uma credencial individual da API Platform."
        case .unauthenticated: "A credencial não é mais válida. Reconecte para autenticar novamente."
        case .forbidden: "O servidor negou o acesso ao projeto. O contexto autorizado foi invalidado."
        case .conflict: "O servidor encontrou um conflito. Consulte o estado antes de repetir a operação."
        case .contractMismatch: "A API usa uma versão de contrato incompatível com este Desk."
        case .malformedResponse: "A resposta da API não corresponde ao contrato validado."
        case .invalidRequest: "A solicitação contém um identificador ou campo inválido."
        case .redirectDenied: "A API tentou redirecionar a conexão; a credencial não foi encaminhada."
        case .timeout: "A API não respondeu dentro do prazo."
        case .connectionChanged: "A conexão mudou durante a solicitação; a resposta foi descartada."
        case .responseTooLarge: "A resposta da API excedeu o limite local."
        case .server(let status, _, _): "A API recusou a solicitação (HTTP \(status))."
        }
    }
}

/// Runtime discovery, not a promise that an agent executor is configured.
public struct PlatformCapabilities: Decodable, Equatable, Sendable {
    public let authorizedRegistry: Bool
    public let search: Bool
    public let runs: Bool
    public let durableEvents: Bool
    public let agentExecution: Bool
    public let retrievalMode: String
    public let documentSharing: Bool
    public let toolExecution: Bool
    public let executionProviders: [DeskExecutionProvider]
    enum CodingKeys: String, CodingKey {
        case authorizedRegistry = "authorized_registry", search, runs
        case durableEvents = "durable_events", agentExecution = "agent_execution", retrievalMode = "retrieval_mode"
        case documentSharing = "document_sharing"
        case toolExecution = "tool_execution", executionProviders = "execution_providers"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        authorizedRegistry = try values.decode(Bool.self, forKey: .authorizedRegistry)
        search = try values.decode(Bool.self, forKey: .search)
        runs = try values.decode(Bool.self, forKey: .runs)
        durableEvents = try values.decode(Bool.self, forKey: .durableEvents)
        agentExecution = try values.decode(Bool.self, forKey: .agentExecution)
        retrievalMode = try values.decode(String.self, forKey: .retrievalMode)
        documentSharing = try values.decodeIfPresent(Bool.self, forKey: .documentSharing) ?? false
        let toolEnabled = try values.decodeIfPresent(Bool.self, forKey: .toolExecution) ?? false
        toolExecution = toolEnabled
        let agentEnabled = agentExecution
        executionProviders = try values.decodeIfPresent([DeskExecutionProvider].self, forKey: .executionProviders)?.map { provider in
            let enabled = provider.kind == "text-model" ? agentEnabled : provider.kind == "docker-tool" ? toolEnabled : false
            return .init(id: provider.id, kind: provider.kind, model: provider.model, experimental: provider.experimental, isEnabled: enabled)
        } ?? []
    }
}

public indirect enum PlatformJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([Self]), object([String: Self])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct PlatformRunEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let runID: String
    public let type: String
    public let payload: PlatformJSONValue
    public let createdAt: String
    enum CodingKeys: String, CodingKey { case id, runID = "run_id", type, payload, createdAt = "created_at" }
    public init(id: String, runID: String, type: String, payload: PlatformJSONValue, createdAt: String) {
        self.id = id; self.runID = runID; self.type = type; self.payload = payload; self.createdAt = createdAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let numericID = try? c.decode(Int.self, forKey: .id) { id = String(numericID) }
        else { id = try c.decode(String.self, forKey: .id) }
        runID = try c.decode(String.self, forKey: .runID)
        type = try c.decode(String.self, forKey: .type)
        payload = try c.decode(PlatformJSONValue.self, forKey: .payload)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

public struct PlatformEventPage: Codable, Equatable, Sendable {
    public let events: [PlatformRunEvent]
    public let nextCursor: Int
    public let hasMore: Bool
    public init(events: [PlatformRunEvent], nextCursor: Int, hasMore: Bool) {
        self.events = events; self.nextCursor = nextCursor; self.hasMore = hasMore
    }
}

protocol PlatformEnvelope: Decodable, Sendable { var schema_version: String { get } }
protocol PlatformScopedEnvelope: PlatformEnvelope { var authorized_context: PlatformAuthorizedContext { get } }
struct PlatformAuthorizedContext: Decodable, Sendable {
    let principal_id: String; let tenant_id: String; let project_id: String
    var identity: WorkspaceIdentity { .init(tenantID: tenant_id, projectID: project_id, principalID: principal_id) }
}
struct PlatformHeader: Decodable { let schema_version: String }
struct PlatformCapabilitiesEnvelope: PlatformEnvelope {
    let schema_version: String; let service: String; let capabilities: PlatformCapabilities
}
struct PlatformMeEnvelope: PlatformEnvelope {
    struct Principal: Decodable, Sendable { let id: String }
    let schema_version: String; let principal: Principal
}
struct PlatformRegistryEnvelope: PlatformEnvelope {
    struct Tenant: Decodable, Sendable { let id: String; let name: String }
    struct Project: Decodable, Sendable { let id: String; let tenant_id: String; let name: String; let role: String }
    let schema_version: String; let tenants: [Tenant]; let projects: [Project]
}
struct PlatformMemory: Decodable, Sendable {
    struct Origin: Decodable, Sendable { let tenant_id: String; let project_id: String }
    struct Access: Decodable, Sendable { let kind: String; let principal_id: String; let read_only: Bool? }
    let id: String; let title: String; let content: String; let type: String; let version: Int
    let score: Double?
    // Present on checkpoint/recent responses; search may omit them by contract.
    let tenant_id: String?; let project_id: String?
    let origin: Origin?; let access: Access?
}
struct PlatformSearchEnvelope: PlatformScopedEnvelope {
    struct Retrieval: Decodable, Sendable { let mode: String; let embedding_ms: Double; let retrieval_ms: Double }
    let schema_version: String; let items: [PlatformMemory]; let retrieval: Retrieval
    let authorized_context: PlatformAuthorizedContext
}
struct PlatformWireRun: Decodable, Sendable {
    struct Failure: Decodable, Sendable { let code: String? }
    let id: String; let tenant_id: String; let project_id: String
    let objective: String; let status: String; let version: Int
    let provider: String?
    let result: PlatformJSONValue?
    let checkpoint: PlatformJSONValue?
    let error: Failure?
}
struct PlatformCheckpointEnvelope: PlatformScopedEnvelope {
    let schema_version: String; let items: [PlatformMemory]; let runs: [PlatformWireRun]
    let authorized_context: PlatformAuthorizedContext
}
struct PlatformRunsEnvelope: PlatformScopedEnvelope {
    let schema_version: String; let runs: [PlatformWireRun]; let authorized_context: PlatformAuthorizedContext
}
struct PlatformRunEnvelope: PlatformScopedEnvelope {
    let schema_version: String; let run: PlatformWireRun; let authorized_context: PlatformAuthorizedContext
}
struct PlatformEventsEnvelope: PlatformScopedEnvelope {
    let schema_version: String; let events: [PlatformRunEvent]; let next_cursor: Int; let has_more: Bool
    let authorized_context: PlatformAuthorizedContext
}
struct PlatformErrorEnvelope: PlatformEnvelope {
    struct Detail: Decodable, Sendable { let code: String; let message: String; let retryable: Bool }
    let schema_version: String; let error: Detail
}
