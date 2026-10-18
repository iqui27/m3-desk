import Foundation

/// REST adapter for the opt-in Platform boundary. Never forwards to the legacy MCP bridge.
public actor PlatformDeskService: DeskService {
    private let baseURL: URL
    private let credentialProvider: @Sendable () async throws -> String
    private let transport: any PlatformTransport
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var generation = UUID()
    private var token: String?
    private var capabilities: PlatformCapabilities?
    private var contexts: [WorkspaceIdentity: DeskAccessContext] = [:]

    public init(baseURL: URL, credentialProvider: @escaping @Sendable () async throws -> String,
                transport: any PlatformTransport = URLSessionPlatformTransport(), timeout: TimeInterval = 20,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) throws {
        try Self.validateEndpoint(baseURL)
        guard timeout.isFinite && timeout > 0 else { throw PlatformClientError.invalidRequest }
        self.baseURL = baseURL; self.credentialProvider = credentialProvider; self.transport = transport
        self.timeout = timeout; self.now = now; self.sleep = sleep
    }

    public init(baseURL: URL, token: String, transport: any PlatformTransport = URLSessionPlatformTransport()) throws {
        try self.init(baseURL: baseURL, credentialProvider: { token }, transport: transport)
    }

    public nonisolated static func validateEndpoint(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              parts.port == nil || (1...65535).contains(parts.port!) else { throw PlatformClientError.invalidEndpoint }
    }

    public func connect() async throws -> DeskConnection {
        invalidate()
        let revision = generation
        do {
            let credential = try await credentialProvider()
            try current(revision)
            guard !credential.isEmpty, credential.count <= 8192,
                  !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
                throw PlatformClientError.missingCredential
            }
            token = credential
            let discovery: PlatformCapabilitiesEnvelope = try await request(["v1", "capabilities"], revision: revision, authenticated: false)
            guard discovery.service == "m3-platform", discovery.capabilities.authorizedRegistry else {
                throw DeskServiceError.unsupported("Esta API não disponibiliza registry autorizado compatível.")
            }
            let me: PlatformMeEnvelope = try await request(["v1", "me"], revision: revision)
            let registry: PlatformRegistryEnvelope = try await request(["v1", "registry"], revision: revision)
            try current(revision)
            let principal = me.principal.id
            guard Self.validIdentifier(principal), registry.tenants.allSatisfy({ Self.validPathID($0.id) }),
                  registry.projects.allSatisfy({ Self.validPathID($0.id) && Self.validPathID($0.tenant_id) && ["viewer", "editor", "admin"].contains($0.role) }) else {
                throw DeskServiceError.invalidRegistry
            }
            let localRegistry = LocalRegistry(
                tenants: registry.tenants.map { .init(id: $0.id, name: $0.name, kind: .organization) },
                projects: registry.projects.map { .init(id: $0.id, name: $0.name, detail: "Acesso \($0.role)", tenantID: $0.tenant_id) },
                principalID: principal)
            do { try localRegistry.validate() } catch { throw DeskServiceError.invalidRegistry }
            let caps = discovery.capabilities
            guard Set(caps.executionProviders.map(\.id)).count == caps.executionProviders.count,
                  caps.executionProviders.allSatisfy({ Self.validProviderID($0.id) && Self.validIdentifier($0.kind) && ($0.model == nil || Self.validIdentifier($0.model!)) }) else {
                throw PlatformClientError.malformedResponse
            }
            // v1 has no server-issued revision or expiry. This is only a local freshness lease.
            let deadline = now().addingTimeInterval(5 * 60)
            let access = registry.projects.map { project in
                var permissions: Set<DeskPermission> = [.checkpoint]
                if caps.search { permissions.insert(.search) }
                if caps.runs {
                    permissions.insert(.runRead)
                    if caps.durableEvents { permissions.insert(.runEvents) }
                    if project.role != "viewer" { permissions.formUnion([.runCreate, .runResume, .runCancel]) }
                }
                return DeskAccessContext(identity: .init(tenantID: project.tenant_id, projectID: project.id, principalID: principal),
                    permissions: permissions, authorizationRevision: revision.uuidString, expiresAt: deadline)
            }
            capabilities = caps
            contexts = Dictionary(uniqueKeysWithValues: access.map { ($0.identity, $0) })
            return DeskConnection(serverDescription: discovery.service, protocolVersion: platformSchemaVersion,
                tools: [], authorizedRegistry: .init(registry: localRegistry, contexts: access, contractVersion: platformSchemaVersion),
                agentExecution: caps.agentExecution, executionProviders: caps.executionProviders)
        } catch {
            if revision == generation { invalidate() }
            throw error
        }
    }

    public func search(query: String, context: DeskAccessContext) async throws -> [DeskMemoryHit] {
        let revision = try require(context, .search)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 4096 else { throw PlatformClientError.invalidRequest }
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "k": 20])
        let result: PlatformSearchEnvelope = try await request(path(context, "search"), method: "POST", body: body, revision: revision)
        try finish(context, .search, revision)
        try validate(result, context: context)
        guard result.retrieval.embedding_ms.isFinite, result.retrieval.embedding_ms >= 0,
              result.retrieval.retrieval_ms.isFinite, result.retrieval.retrieval_ms >= 0,
              !result.retrieval.mode.isEmpty else { throw PlatformClientError.malformedResponse }
        return try memories(result.items, context: context)
    }

    public func checkpoint(context: DeskAccessContext) async throws -> DeskCheckpoint? {
        let revision = try require(context, .checkpoint)
        let result: PlatformCheckpointEnvelope = try await request(path(context, "checkpoint"), revision: revision)
        try finish(context, .checkpoint, revision)
        try validate(result, context: context)
        let items = try memories(result.items, context: context)
        let runs = try result.runs.map { try convert($0, context: context) }
        guard !items.isEmpty || !runs.isEmpty else { return nil }
        let version = stableStorageKey(result.items.map { "\($0.id):\($0.version)" }.sorted()
            + result.runs.map { "\($0.id):\($0.version)" }.sorted())
        return DeskCheckpoint(identity: context.identity, version: version,
            context: items.map { "\($0.title)\n\($0.content)" }.joined(separator: "\n\n"),
            delta: "Snapshot autorizado: \(items.count) memórias e \(runs.count) runs.",
            nextAction: "", blockers: "", sources: items.map { "\($0.source) · versão \($0.version)" })
    }

    public func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) async throws -> DeskRun {
        let revision = try require(context, .runCreate)
        try requireProvider(providerID)
        guard draft.workspaceIdentity == context.identity else { throw DeskServiceError.invalidIdentity }
        guard !draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.objective.count <= 16000 else { throw PlatformClientError.invalidRequest }
        try validateKey(idempotencyKey)
        // The contract accepts objective/provider only. The full handoff remains a separate local export.
        let body = try JSONSerialization.data(withJSONObject: ["objective": draft.objective, "provider": providerID])
        let result: PlatformRunEnvelope = try await request(path(context, "runs"), method: "POST", body: body,
            key: idempotencyKey, safeRead: false, revision: revision)
        try finish(context, .runCreate, revision)
        try validate(result, context: context)
        return try convert(result.run, context: context, expectedProvider: providerID)
    }

    public func runs(context: DeskAccessContext, after cursor: String?) async throws -> [DeskRun] {
        let revision = try require(context, .runRead)
        guard cursor == nil || cursor == "" else { throw DeskServiceError.unsupported("A lista de runs v1 não usa cursor; acompanhe cada run pelos eventos incrementais.") }
        let result: PlatformRunsEnvelope = try await request(path(context, "runs"), revision: revision)
        try finish(context, .runRead, revision)
        try validate(result, context: context)
        let runs = try result.runs.map { try convert($0, context: context) }
        guard Set(runs.map(\.id)).count == runs.count else { throw PlatformClientError.malformedResponse }
        return runs
    }

    public func run(id: String, context: DeskAccessContext) async throws -> DeskRun {
        let revision = try require(context, .runRead)
        try validateRunID(id)
        let result: PlatformRunEnvelope = try await request(path(context, "runs", id), revision: revision)
        try finish(context, .runRead, revision)
        try validate(result, context: context)
        return try convert(result.run, context: context, expectedID: id)
    }

    public func resumeRun(id: String, context: DeskAccessContext, idempotencyKey: String) async throws -> DeskRun {
        let revision = try require(context, .runResume)
        try validateRunID(id); try validateKey(idempotencyKey)
        // Resume preserves a run's original provider; do not reinterpret it from current global flags.
        let existing = try await run(id: id, context: context)
        guard let providerID = existing.providerID else { throw DeskServiceError.unsupported("O run não informa seu provider; consulte o estado antes de retomar.") }
        try requireProvider(providerID)
        try finish(context, .runResume, revision)
        let result: PlatformRunEnvelope = try await request(path(context, "runs", id, "resume"), method: "POST",
            key: idempotencyKey, safeRead: false, revision: revision)
        try finish(context, .runResume, revision)
        try validate(result, context: context)
        return try convert(result.run, context: context, expectedID: id, expectedProvider: providerID)
    }

    public func cancelRun(id: String, context: DeskAccessContext) async throws -> DeskRun {
        let revision = try require(context, .runCancel)
        try validateRunID(id)
        let result: PlatformRunEnvelope = try await request(path(context, "runs", id, "cancel"), method: "POST", safeRead: false, revision: revision)
        try finish(context, .runCancel, revision)
        try validate(result, context: context)
        return try convert(result.run, context: context, expectedID: id)
    }

    public func events(runID: String, context: DeskAccessContext, after: Int, limit: Int = 100) async throws -> PlatformEventPage {
        let revision = try require(context, .runEvents)
        try validateRunID(runID)
        guard after >= 0, (1...500).contains(limit) else { throw PlatformClientError.invalidRequest }
        let result: PlatformEventsEnvelope = try await request(path(context, "runs", runID, "events"),
            query: [.init(name: "after", value: String(after)), .init(name: "limit", value: String(limit))], revision: revision)
        try finish(context, .runEvents, revision)
        try validate(result, context: context)
        guard result.next_cursor >= after, !result.has_more || result.next_cursor > after,
              !result.events.isEmpty || result.next_cursor == after,
              result.events.count <= limit else { throw PlatformClientError.malformedResponse }
        // Only the caller can acknowledge delivery after saving events and cursor together.
        // Dedupe this page, but retain re-deliveries across calls so cancelled UI updates lose nothing.
        var known: [String: PlatformRunEvent] = [:]
        var fresh: [PlatformRunEvent] = []
        for event in result.events {
            guard event.runID == runID else { throw DeskServiceError.invalidIdentity }
            guard Self.validIdentifier(event.id), !event.type.isEmpty, Self.validTimestamp(event.createdAt) else { throw PlatformClientError.malformedResponse }
            if let sequence = Int(event.id), sequence <= 0 || sequence > result.next_cursor { throw PlatformClientError.malformedResponse }
            if let prior = known[event.id] {
                guard prior == event else { throw PlatformClientError.malformedResponse }
            } else { known[event.id] = event; fresh.append(event) }
        }
        return .init(events: fresh, nextCursor: result.next_cursor, hasMore: result.has_more)
    }

    private func require(_ context: DeskAccessContext, _ permission: DeskPermission) throws -> UUID {
        guard let issued = contexts[context.identity], issued == context, issued.allows(permission, now: now()), token != nil else {
            throw DeskServiceError.permissionDenied
        }
        return generation
    }
    private func finish(_ context: DeskAccessContext, _ permission: DeskPermission, _ revision: UUID) throws {
        try current(revision); _ = try require(context, permission)
    }
    private func current(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard revision == generation else { throw PlatformClientError.connectionChanged }
    }
    private func invalidate() {
        generation = UUID(); token = nil; capabilities = nil; contexts.removeAll()
    }
    private func path(_ context: DeskAccessContext, _ parts: String...) -> [String] {
        ["v1", "tenants", context.identity.tenantID, "projects", context.identity.projectID] + parts
    }
    private static func validIdentifier(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.count <= 512
        && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validPathID(_ id: String) -> Bool {
        validIdentifier(id) && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
    }
    private func validateRunID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw PlatformClientError.invalidRequest }
    }
    private func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.count <= 200, key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw PlatformClientError.invalidRequest }
    }
    private static func validProviderID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
        }
    }
    private func requireProvider(_ id: String) throws {
        guard Self.validProviderID(id), capabilities?.executionProviders.contains(where: { $0.id == id && $0.isSupported }) == true else {
            throw DeskServiceError.unsupported("Este provider não está anunciado e habilitado nesta conexão. Reconecte para atualizar as opções.")
        }
    }
    private static func validTimestamp(_ value: String) -> Bool {
        let parser = ISO8601DateFormatter()
        if parser.date(from: value) != nil { return true }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) != nil
    }
    private func validate<T: PlatformScopedEnvelope>(_ envelope: T, context: DeskAccessContext) throws {
        guard envelope.authorized_context.identity == context.identity else { throw DeskServiceError.invalidIdentity }
    }
    private func memories(_ items: [PlatformMemory], context: DeskAccessContext) throws -> [DeskMemoryHit] {
        guard Set(items.map(\.id)).count == items.count else { throw PlatformClientError.malformedResponse }
        return try items.map { item in
            let sharing = capabilities?.documentSharing == true
            // With the sharing extension, both origin representations and explicit access provenance are mandatory.
            if sharing && (item.tenant_id == nil || item.project_id == nil || item.origin == nil || item.access == nil) {
                throw PlatformClientError.malformedResponse
            }
            let originTenant = item.tenant_id ?? context.identity.tenantID
            let originProject = item.project_id ?? context.identity.projectID
            guard Self.validIdentifier(originTenant), Self.validIdentifier(originProject) else { throw PlatformClientError.malformedResponse }
            if let origin = item.origin {
                guard item.tenant_id == origin.tenant_id, item.project_id == origin.project_id else { throw DeskServiceError.invalidIdentity }
            }
            let isForeign = originTenant != context.identity.tenantID || originProject != context.identity.projectID
            var isShared = false
            if let access = item.access {
                guard access.principal_id == context.identity.principalID else { throw DeskServiceError.invalidIdentity }
                switch access.kind {
                case "explicit_grant":
                    guard sharing, access.read_only == true else { throw DeskServiceError.invalidIdentity }
                    isShared = true
                case "personal_owner", "project_membership":
                    guard !isForeign else { throw DeskServiceError.invalidIdentity }
                default: throw PlatformClientError.malformedResponse
                }
            }
            guard !isForeign || isShared else { throw DeskServiceError.invalidIdentity }
            guard UUID(uuidString: item.id) != nil, item.version > 0, item.score == nil || item.score!.isFinite else { throw PlatformClientError.malformedResponse }
            let provenance = isShared ? "Compartilhada · somente leitura · origem \(originTenant)/\(originProject)" : "Platform · \(originTenant)/\(originProject)"
            return .init(id: item.id, title: item.title, content: item.content,
                source: "\(provenance) · \(item.id)", version: String(item.version))
        }
    }
    private func convert(_ run: PlatformWireRun, context: DeskAccessContext, expectedID: String? = nil, expectedProvider: String? = nil) throws -> DeskRun {
        guard run.tenant_id == context.identity.tenantID, run.project_id == context.identity.projectID,
              expectedID == nil || expectedID == run.id,
              expectedProvider == nil || expectedProvider == run.provider else { throw DeskServiceError.invalidIdentity }
        guard UUID(uuidString: run.id) != nil, run.version > 0,
              run.provider == nil || Self.validProviderID(run.provider!),
              ["queued", "running", "succeeded", "failed", "cancelled"].contains(run.status) else { throw PlatformClientError.malformedResponse }
        let result = object(run.result)
        let checkpoint = object(run.checkpoint)
        let checkpointResult = object(checkpoint?["result"])
        return DeskRun(id: run.id, identity: context.identity, status: run.status, summary: run.objective, version: run.version,
            providerID: run.provider, resultText: string(result?["text"]),
            checkpointText: string(checkpoint?["text"]) ?? string(checkpointResult?["text"]),
            resultModel: string(result?["model"]), resultModelDigest: string(result?["model_digest"]), failureCode: run.error?.code)
    }
    private func object(_ value: PlatformJSONValue?) -> [String: PlatformJSONValue]? {
        guard case .object(let fields) = value else { return nil }; return fields
    }
    private func string(_ value: PlatformJSONValue?) -> String? {
        guard case .string(let text) = value else { return nil }; return text
    }

    private func request<T: PlatformEnvelope>(_ path: [String], method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], key: String? = nil, safeRead: Bool = true, revision: UUID,
        authenticated: Bool = true) async throws -> T {
        try current(revision)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let segments = try path.map { part -> String in
            guard Self.validPathID(part), let encoded = part.addingPercentEncoding(withAllowedCharacters: allowed) else { throw PlatformClientError.invalidRequest }
            return encoded
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([prefix].filter { !$0.isEmpty } + segments).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PlatformClientError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if authenticated {
            guard let token else { throw PlatformClientError.missingCredential }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for attempt in 0...2 {
            try current(revision)
            let response = try await send(request)
            try current(revision)
            // Denial invalidates the local lease even if the error envelope is malformed.
            if response.statusCode == 401 || response.statusCode == 403 {
                invalidate()
                throw response.statusCode == 401 ? PlatformClientError.unauthenticated : .forbidden
            }
            if (300...399).contains(response.statusCode) { throw PlatformClientError.redirectDenied }
            guard response.data.count <= 8 * 1024 * 1024 else { throw PlatformClientError.responseTooLarge }
            let decoder = JSONDecoder()
            let header: PlatformHeader
            do { header = try decoder.decode(PlatformHeader.self, from: response.data) }
            catch { throw PlatformClientError.malformedResponse }
            guard header.schema_version == platformSchemaVersion else { throw PlatformClientError.contractMismatch(header.schema_version) }
            if !(200...299).contains(response.statusCode) {
                guard let failure = try? decoder.decode(PlatformErrorEnvelope.self, from: response.data) else { throw PlatformClientError.malformedResponse }
                if response.statusCode == 409 { throw PlatformClientError.conflict }
                let retryHeader = response.header("Retry-After")
                let retryAfter = retryHeader.flatMap(Double.init)
                if safeRead, attempt < 2, [429, 503].contains(response.statusCode), failure.error.retryable,
                   retryHeader == nil || retryAfter != nil,
                   retryAfter == nil || (retryAfter!.isFinite && retryAfter! >= 0 && retryAfter! <= 2) {
                    try await sleep(retryAfter ?? (0.25 * pow(2, Double(attempt))))
                    continue
                }
                throw PlatformClientError.server(status: response.statusCode, code: failure.error.code, retryable: failure.error.retryable)
            }
            do { return try decoder.decode(T.self, from: response.data) }
            catch { throw PlatformClientError.malformedResponse }
        }
        throw PlatformClientError.malformedResponse
    }

    private func send(_ request: URLRequest) async throws -> PlatformHTTPResponse {
        let transport = transport, timeout = timeout
        do {
            return try await withThrowingTaskGroup(of: PlatformHTTPResponse.self) { group in
                group.addTask { try await transport.send(request) }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); throw PlatformClientError.timeout }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw PlatformClientError.malformedResponse }
                return response
            }
        } catch let error as URLError where error.code == .timedOut { throw PlatformClientError.timeout }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
    }
}
