import Foundation

public enum DeskPermission: String, Codable, Sendable { case search, checkpoint, runRead, runCreate, runEvents, runResume, runCancel }

/// Authenticated registry plus a local freshness lease. The server authorizes every request.
/// The v1 server does not issue revision/expiry; local registry entries never grant permissions.
public struct DeskAccessContext: Codable, Equatable, Sendable {
    public let identity: WorkspaceIdentity
    public let permissions: Set<DeskPermission>
    public let authorizationRevision: String
    public let expiresAt: Date
    public init(identity: WorkspaceIdentity, permissions: Set<DeskPermission>, authorizationRevision: String, expiresAt: Date) {
        self.identity = identity; self.permissions = permissions; self.authorizationRevision = authorizationRevision; self.expiresAt = expiresAt
    }
    public func allows(_ permission: DeskPermission, now: Date = Date()) -> Bool {
        !authorizationRevision.isEmpty && expiresAt > now && permissions.contains(permission)
    }
}

public struct DeskAuthorizedRegistry: Sendable {
    public let registry: LocalRegistry
    public let contexts: [DeskAccessContext]
    public let contractVersion: String
    public init(registry: LocalRegistry, contexts: [DeskAccessContext], contractVersion: String) {
        self.registry = registry; self.contexts = contexts; self.contractVersion = contractVersion
    }
}

public struct DeskExecutionProvider: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let model: String?
    public let experimental: Bool
    public let isEnabled: Bool
    public init(id: String, kind: String, model: String? = nil, experimental: Bool = false, isEnabled: Bool = true) {
        self.id = id; self.kind = kind; self.model = model; self.experimental = experimental; self.isEnabled = isEnabled
    }
    public var isSupported: Bool { isEnabled && ["docker-tool", "text-model"].contains(kind) }
    public var kindLabel: String {
        switch kind {
        case "docker-tool": "Ferramenta Docker fixa"
        case "text-model": "Modelo textual"
        default: "Provider não suportado"
        }
    }
    public var displayName: String {
        let name = kind == "text-model" ? model ?? id : kind == "docker-tool" ? "Ferramenta Docker local" : id
        return name + (experimental ? " · experimental" : "") + (isEnabled ? "" : " · indisponível")
    }
    private enum CodingKeys: String, CodingKey { case id, kind, model, experimental, isEnabled }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        experimental = try values.decodeIfPresent(Bool.self, forKey: .experimental) ?? false
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public struct DeskConnection: Sendable {
    public let serverDescription: String
    public let protocolVersion: String
    public let tools: [String]
    public let authorizedRegistry: DeskAuthorizedRegistry?
    public let agentExecution: Bool
    public let executionProviders: [DeskExecutionProvider]
    public init(serverDescription: String, protocolVersion: String, tools: [String], authorizedRegistry: DeskAuthorizedRegistry? = nil, agentExecution: Bool = false, executionProviders: [DeskExecutionProvider] = []) {
        self.serverDescription = serverDescription; self.protocolVersion = protocolVersion; self.tools = tools; self.authorizedRegistry = authorizedRegistry; self.agentExecution = agentExecution
        self.executionProviders = executionProviders
    }
}

public struct DeskMemoryHit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let content: String
    public let source: String
    public let version: String
    public init(id: String, title: String, content: String, source: String, version: String) {
        self.id = id; self.title = title; self.content = content; self.source = source; self.version = version
    }
}
public struct DeskCheckpoint: Codable, Equatable, Sendable {
    public let identity: WorkspaceIdentity
    public let version: String
    public let context: String
    public let delta: String
    public let nextAction: String
    public let blockers: String
    public let sources: [String]
    public init(identity: WorkspaceIdentity, version: String, context: String, delta: String, nextAction: String, blockers: String, sources: [String]) {
        self.identity = identity; self.version = version; self.context = context; self.delta = delta; self.nextAction = nextAction; self.blockers = blockers; self.sources = sources
    }
}
public struct DeskRun: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let identity: WorkspaceIdentity
    public let status: String
    public let summary: String
    public let cursor: String?
    public let version: Int
    public let providerID: String?
    public let resultText: String?
    public let checkpointText: String?
    public let resultModel: String?
    public let resultModelDigest: String?
    public let failureCode: String?
    public init(id: String, identity: WorkspaceIdentity, status: String, summary: String, cursor: String? = nil, version: Int = 1,
                providerID: String? = nil, resultText: String? = nil, checkpointText: String? = nil,
                resultModel: String? = nil, resultModelDigest: String? = nil, failureCode: String? = nil) {
        self.id = id; self.identity = identity; self.status = status; self.summary = summary; self.cursor = cursor; self.version = version
        self.providerID = providerID; self.resultText = resultText; self.checkpointText = checkpointText
        self.resultModel = resultModel; self.resultModelDigest = resultModelDigest
        self.failureCode = failureCode
    }
    /// Stable per-run identity, independent of current capabilities or model selection.
    public var providerLabel: String {
        switch providerID {
        case "local": "Ferramenta Docker fixa"
        case "local-model": "Modelo textual local · experimental"
        case .some(let id): "Provider \(id) · tipo não identificado"
        case .none: "Provider não informado"
        }
    }
    private enum CodingKeys: String, CodingKey {
        case id, identity, status, summary, cursor, version, providerID, resultText, checkpointText, resultModel, resultModelDigest, failureCode
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        identity = try values.decode(WorkspaceIdentity.self, forKey: .identity)
        status = try values.decode(String.self, forKey: .status)
        summary = try values.decode(String.self, forKey: .summary)
        cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        resultText = try values.decodeIfPresent(String.self, forKey: .resultText)
        checkpointText = try values.decodeIfPresent(String.self, forKey: .checkpointText)
        resultModel = try values.decodeIfPresent(String.self, forKey: .resultModel)
        resultModelDigest = try values.decodeIfPresent(String.self, forKey: .resultModelDigest)
        failureCode = try values.decodeIfPresent(String.self, forKey: .failureCode)
    }
}
public enum DeskServiceError: LocalizedError, Sendable {
    case unsupported(String), permissionDenied, invalidIdentity, invalidRegistry, unknownRunOutcome
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): reason
        case .permissionDenied: "Permissão ausente ou expirada. Reconecte para validar o acesso."
        case .invalidIdentity: "A resposta pertence a outro contexto e foi descartada."
        case .invalidRegistry: "O registry autorizado é inválido. Nenhum acesso foi concedido."
        case .unknownRunOutcome: "Não foi possível confirmar a criação do run. Consulte o estado antes de tentar novamente."
        }
    }
}

public protocol DeskService: Sendable {
    func connect() async throws -> DeskConnection
    func search(query: String, context: DeskAccessContext) async throws -> [DeskMemoryHit]
    func checkpoint(context: DeskAccessContext) async throws -> DeskCheckpoint?
    func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) async throws -> DeskRun
    func runs(context: DeskAccessContext, after cursor: String?) async throws -> [DeskRun]
    func run(id: String, context: DeskAccessContext) async throws -> DeskRun
    func events(runID: String, context: DeskAccessContext, after: Int, limit: Int) async throws -> PlatformEventPage
    func resumeRun(id: String, context: DeskAccessContext, idempotencyKey: String) async throws -> DeskRun
    func cancelRun(id: String, context: DeskAccessContext) async throws -> DeskRun
}
public extension DeskService {
    func run(id: String, context: DeskAccessContext) async throws -> DeskRun { throw DeskServiceError.unsupported("Consulta individual de run indisponível.") }
    func events(runID: String, context: DeskAccessContext, after: Int, limit: Int) async throws -> PlatformEventPage { throw DeskServiceError.unsupported("Eventos indisponíveis.") }
    func resumeRun(id: String, context: DeskAccessContext, idempotencyKey: String) async throws -> DeskRun { throw DeskServiceError.unsupported("Retomada indisponível.") }
    func cancelRun(id: String, context: DeskAccessContext) async throws -> DeskRun { throw DeskServiceError.unsupported("Cancelamento indisponível.") }
}

/// Legacy MCP discovery does not imply tenant/project authorization.
/// Scoped operations stay unavailable until a versioned server adapter validates identity.
public actor MCPDeskService: DeskService {
    private let client: MCPClient
    public init(client: MCPClient = MCPClient()) { self.client = client }
    public func connect() async throws -> DeskConnection {
        let server = try await client.initialize()
        let tools = try await client.listTools()
        return DeskConnection(serverDescription: "\(server.name) \(server.version)", protocolVersion: await client.connectionInfo()?.protocolVersion ?? "MCP", tools: tools.map(\.name))
    }
    public func search(query: String, context: DeskAccessContext) throws -> [DeskMemoryHit] { throw unavailable }
    public func checkpoint(context: DeskAccessContext) throws -> DeskCheckpoint? { throw unavailable }
    public func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) throws -> DeskRun { throw unavailable }
    public func runs(context: DeskAccessContext, after cursor: String?) throws -> [DeskRun] { throw unavailable }
    private var unavailable: DeskServiceError { .unsupported("O MCP conectado não possui um contrato de projeto autorizado. Busca e execução por projeto aguardam esse contrato.") }
}

/// Invalid opt-in configuration stays closed; it must never fall back to the legacy bridge.
public struct UnavailableDeskService: DeskService {
    private let reason: String
    public init(reason: String) { self.reason = reason }
    public func connect() async throws -> DeskConnection { throw DeskServiceError.unsupported(reason) }
    public func search(query: String, context: DeskAccessContext) async throws -> [DeskMemoryHit] { throw DeskServiceError.unsupported(reason) }
    public func checkpoint(context: DeskAccessContext) async throws -> DeskCheckpoint? { throw DeskServiceError.unsupported(reason) }
    public func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) async throws -> DeskRun { throw DeskServiceError.unsupported(reason) }
    public func runs(context: DeskAccessContext, after cursor: String?) async throws -> [DeskRun] { throw DeskServiceError.unsupported(reason) }
}
