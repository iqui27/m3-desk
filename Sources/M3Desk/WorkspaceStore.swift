import AppKit
import Combine
import Foundation
import M3DeskCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var section: AppSection = .workspace
    @Published private(set) var selectedProject: Project?
    @Published var selectedTenantID = ""
    @Published var selectedSubproject = ""
    @Published var projectFilter = ""
    @Published var memoryQuery = "" { didSet { if oldValue != memoryQuery { invalidateSearch() } } }
    @Published var verificationNotice = ""
    @Published var connectionState = "Conexão do Desk não verificada"
    @Published private(set) var connectionReady = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isSearching = false
    @Published var memoryResults: [String] = []
    @Published var memorySearchState = "Selecione um projeto e conecte para validar as capacidades."
    @Published var handoff = HandoffDraft()
    @Published var handoffFeedback = ""
    @Published var localNotice = ""
    @Published var storageError = ""
    @Published private(set) var draftWritable = true
    @Published private(set) var registryLabel = "Configuração local · acesso remoto não validado"
    @Published private(set) var capabilitiesMessage = "Conecte ao M3 para verificar o acesso a este projeto."
    @Published private(set) var supportsScopedSearch = false
    @Published private(set) var canExecuteRun = false
    @Published private(set) var canRegisterRun = false
    @Published private(set) var executionProviders: [DeskExecutionProvider] = []
    @Published var platformEndpoint = ""
    @Published var platformCredential = ""
    @Published private(set) var platformProfileNotice = ""
    @Published private(set) var isValidatingPlatformConnection = false
    @Published private(set) var platformConnectionValidationMessage = ""
    @Published var showConnectionSettings = false
    @Published var showHandoffPreview = false
    @Published var showRecovery = false
    @Published private(set) var recoveryCandidates: [LegacyDraftCandidate] = []
    @Published private(set) var selectedRunID = ""
    @Published private(set) var runEvents: [PlatformRunEvent] = []
    @Published private(set) var isLoadingEvents = false
    @Published private(set) var eventsStatus = ""
    @Published private(set) var checkpointError = ""
    @Published private(set) var isRunning = false
    @Published private(set) var runs: [DeskRun] = []
    @Published private(set) var pendingRunNotice = ""
    @Published var runStatus = "Nenhum run remoto consultado."
    @Published private(set) var checkpointSummary = ""
    @Published private(set) var checkpointSources: [String] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var tenants: [WorkspaceTenant] = []

    private var service: any DeskService
    private var agentExecution = false
    private var eventsTask: Task<Void, Never>?
    private var eventGeneration = UUID()
    private var pollingTask: Task<Void, Never>?
    private var cache: LocalCache?
    private var localCache: LocalCache?
    private var platformCache: LocalCache?
    private let defaults: UserDefaults
    private let preview: Bool
    private var registry = LocalRegistry.builtIn
    private var contexts: [WorkspaceIdentity: DeskAccessContext] = [:]
    private var usesServerRegistry = false
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var connectionGeneration = UUID()
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var lastReconnectFailure: Date?
    private var searchTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runListTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var remoteCheckpoint: DeskCheckpoint?
    private var lastSavedDraft: HandoffDraft?
    private let registryURL: URL?
    private let platformServiceFactory: @Sendable (URL, String) throws -> any DeskService
    private let loadPlatformCredential: (URL) throws -> String
    private let savePlatformCredential: (String, URL) throws -> Void
    private var platformValidationTask: Task<Void, Never>?
    private var platformValidationGeneration = UUID()
    private var expectedPlatformPrincipalID: String?
    private var activePlatformEndpoint: URL?

    init(preview: Bool = false, service: (any DeskService)? = nil, cache: LocalCache? = nil, defaults: UserDefaults? = nil, registry: LocalRegistry? = nil,
         platformServiceFactory: @escaping @Sendable (URL, String) throws -> any DeskService = { try PlatformDeskService(baseURL: $0, token: $1) },
         loadPlatformCredential: @escaping (URL) throws -> String = { try PlatformCredentials.load(endpoint: $0) },
         savePlatformCredential: @escaping (String, URL) throws -> Void = { try PlatformCredentials.save($0, endpoint: $1) }) {
        self.preview = preview
        self.platformServiceFactory = platformServiceFactory
        self.loadPlatformCredential = loadPlatformCredential
        self.savePlatformCredential = savePlatformCredential
        self.service = service ?? UnavailableDeskService(reason: "Configure a conexão individual com a M3 Platform. O MCP legado está desativado.")
        if let defaults { self.defaults = defaults }
        else if preview { self.defaults = UserDefaults(suiteName: "local.m3desk.preview.\(UUID().uuidString)")! }
        else if Bundle.main.bundleIdentifier == "local.m3desk.mvp" { self.defaults = .standard }
        else { self.defaults = UserDefaults(suiteName: "local.m3desk.mvp") ?? .standard }
        let support = cache?.directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("M3Desk", isDirectory: true)
        registryURL = preview ? nil : support.appendingPathComponent("registry.json")
        do {
            self.cache = try cache ?? LocalCache(directory: preview ? FileManager.default.temporaryDirectory.appendingPathComponent("M3Desk-preview-\(UUID().uuidString)") : support)
            if let registry { self.registry = registry }
            else if let registryURL, FileManager.default.fileExists(atPath: registryURL.path) { self.registry = try LocalRegistry.load(from: registryURL) }
            try self.registry.validate()
        } catch { storageError = "Não foi possível carregar a configuração local: \(error.localizedDescription)" }
        localCache = self.cache
        platformEndpoint = self.defaults.string(forKey: "platform.endpoint") ?? ""
        if self.defaults.bool(forKey: "platform.enabled") {
            platformProfileNotice = self.defaults.string(forKey: "platform.profileNotice") ?? ""
        }
        if service == nil, !preview, self.defaults.bool(forKey: "platform.enabled") {
            expectedPlatformPrincipalID = self.defaults.string(forKey: "platform.principal")
            do {
                guard let url = URL(string: platformEndpoint) else { throw PlatformClientError.invalidEndpoint }
                activePlatformEndpoint = url
                self.service = try PlatformDeskService(baseURL: url, credentialProvider: { try PlatformCredentials.load(endpoint: url) })
                self.platformCache = try LocalCache(directory: PlatformCacheNamespace.directory(for: url, in: support))
            } catch { storageError = error.localizedDescription; self.service = UnavailableDeskService(reason: error.localizedDescription) }
        }
        projects = self.registry.projects; tenants = self.registry.tenants
        var restored: WorkspaceSelection?
        do { restored = try self.cache?.loadSelection(principalID: self.registry.principalID) }
        catch { storageError = "Seleção não recuperada: \(error.localizedDescription)" }
        let project = restored.flatMap { selection in projects.first { $0.id == selection.identity.projectID && $0.tenantID == selection.identity.tenantID } } ?? projects.first
        if let project { select(project); if let subproject = restored?.subprojectID { selectSubproject(subproject) } }
        else { selectedTenantID = tenants.first?.id ?? "" }
    }

    var identity: WorkspaceIdentity? {
        selectedProject.map { WorkspaceIdentity(tenantID: $0.tenantID, projectID: $0.id, principalID: registry.principalID) }
    }
    var visibleProjects: [Project] {
        projects.filter { $0.tenantID == selectedTenantID && (projectFilter.isEmpty || ($0.name + " " + $0.detail).localizedCaseInsensitiveContains(projectFilter)) }
    }
    var selectedProviderID: String { handoff.executionProviderID ?? "" }
    var selectedExecutionProvider: DeskExecutionProvider? { executionProviders.first { $0.id == selectedProviderID && $0.isSupported } }
    func selectProvider(_ id: String) {
        guard !isRunning, id.isEmpty || executionProviders.contains(where: { $0.id == id && $0.isSupported }) else { return }
        handoff.executionProviderID = id.isEmpty ? nil : id
        saveDraft(); updateCapabilities()
    }
    var selectedSubprojectName: String { selectedProject?.subprojects.first { $0.id == selectedSubproject }?.name ?? "" }
    var canRefreshRunEvents: Bool { connectionReady && currentContext?.allows(.runEvents) == true && !selectedRunID.isEmpty }
    var canRefreshRuns: Bool { currentContext?.allows(.runRead) == true && connectionReady }
    private var currentContext: DeskAccessContext? { identity.flatMap { contexts[$0] } }

    func selectTenant(_ id: String) {
        guard tenants.contains(where: { $0.id == id }) else { return }
        guard persistBeforeLeaving() else { selectedTenantID = selectedProject?.tenantID ?? selectedTenantID; return }
        if let first = projects.first(where: { $0.tenantID == id }) { select(first) }
        else {
            invalidateContext(); selectedTenantID = id; selectedProject = nil; selectedSubproject = ""
            handoff = HandoffDraft(); lastSavedDraft = nil; pendingRunNotice = ""; updateCapabilities()
        }
    }

    func select(_ project: Project) {
        guard projects.contains(where: { $0.id == project.id && $0.tenantID == project.tenantID }) else { return }
        guard persistBeforeLeaving() else { return }
        invalidateContext()
        selectedProject = project; selectedTenantID = project.tenantID; selectedSubproject = ""
        loadDraft(); persistSelection(); updateCapabilities(); refreshCheckpoint()
    }

    func selectSubproject(_ id: String) {
        guard id.isEmpty || selectedProject?.subprojects.contains(where: { $0.id == id }) == true else { return }
        guard id != selectedSubproject else { return }
        guard persistBeforeLeaving() else { return }
        invalidateContext(); selectedSubproject = id; loadDraft(); persistSelection(); updateCapabilities()
    }

    private func loadDraft() {
        guard let identity, let project = selectedProject else { return }
        storageError = ""; localNotice = ""; handoffFeedback = ""; pendingRunNotice = ""; draftWritable = true
        let name = selectedSubprojectName.isEmpty ? project.name : "\(project.name) / \(selectedSubprojectName)"
        // Only the explicitly retained legacy namespace can claim legacy UserDefaults entries.
        let canMigrate = identity.tenantID == "local-workspace" && identity.principalID == "local-user" && !usesServerRegistry
        do {
            guard let cache else { throw CocoaError(.fileNoSuchFile) }
            let result = try cache.loadDraft(identity: identity, projectName: name, subprojectID: selectedSubproject.isEmpty ? nil : selectedSubproject, legacyProjectNames: canMigrate ? [name] : [], legacyDefaults: defaults)
            handoff = result.draft; lastSavedDraft = handoff
            localNotice = result.notices.map(\.description).joined(separator: " · ")
            refreshPendingOperations()
        } catch {
            var empty = HandoffDraft(); empty.project = name; handoff = empty; lastSavedDraft = nil
            draftWritable = false; storageError = "Rascunho preservado no disco, mas não pôde ser lido: \(error.localizedDescription)"
        }
    }

    @discardableResult func saveDraft() -> Bool {
        guard let identity else { return true }
        guard draftWritable, let cache else { return false }
        guard handoff != lastSavedDraft else { return true }
        var snapshot = handoff
        snapshot.workspaceIdentity = identity
        snapshot.subprojectID = selectedSubproject.isEmpty ? nil : selectedSubproject
        do {
            try cache.saveDraft(snapshot, identity: identity, subprojectID: snapshot.subprojectID)
            handoff = snapshot; lastSavedDraft = snapshot; storageError = ""
            handoffFeedback = "Salvo neste Mac"
            return true
        } catch { storageError = "Não foi possível salvar. Mantenha este projeto aberto ou exporte o rascunho: \(error.localizedDescription)"; return false }
    }
    private func persistBeforeLeaving() -> Bool { !draftWritable || saveDraft() }
    private func persistSelection() {
        guard let identity else { return }
        do { try cache?.saveSelection(WorkspaceSelection(identity: identity, subprojectID: selectedSubproject.isEmpty ? nil : selectedSubproject)) }
        catch { storageError = "Seleção não salva: \(error.localizedDescription)" }
    }

    private func invalidateSearch() {
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID(); isSearching = false
        memoryResults = []; memorySearchState = "Nenhuma busca executada neste contexto."
    }
    private func invalidateContext() {
        generation = UUID(); invalidateSearch(); checkpointTask?.cancel(); runTask?.cancel(); runListTask?.cancel(); expiryTask?.cancel(); eventsTask?.cancel(); pollingTask?.cancel(); eventGeneration = UUID()
        remoteCheckpoint = nil; checkpointSummary = ""; checkpointSources = []; checkpointError = ""; runs = []; isRunning = false; selectedRunID = ""; runEvents = []; isLoadingEvents = false; eventsStatus = ""
        runStatus = "Nenhum run remoto consultado neste projeto."
    }

    func connectIfNeeded() {
        guard !preview, !connectionReady, !isConnecting else { return }
        checkMCP()
    }

    func checkMCP() {
        reconnectTask?.cancel(); reconnectAttempts = 0
        connectRemote()
    }

    private func connectRemote() {
        guard !preview else { connectionState = "Preview local · MCP não consultado"; return }
        connectionTask?.cancel(); connectionGeneration = UUID()
        let token = connectionGeneration
        invalidateContext(); contexts = [:]; executionProviders = []; agentExecution = false; connectionReady = false; isConnecting = true; updateCapabilities()
        connectionState = "Conectando ao M3…"
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.connect()
                guard !Task.isCancelled, token == connectionGeneration else { return }
                if let expectedPlatformPrincipalID, result.authorizedRegistry?.registry.principalID != expectedPlatformPrincipalID {
                    throw PlatformConnectionActivationError.principalMismatch
                }
                guard let authorized = result.authorizedRegistry else { throw DeskServiceError.invalidRegistry }
                try acceptRegistry(authorized)
                agentExecution = result.agentExecution
                executionProviders = result.executionProviders
                connectionReady = true; isConnecting = false
                connectionState = "Desk conectado · identidade e projetos verificados"
                updateCapabilities(); refreshCheckpoint()
                if canRefreshRuns { refreshRuns() }
            } catch {
                guard !Task.isCancelled, token == connectionGeneration else { return }
                isConnecting = false; connectionReady = false; contexts = [:]; updateCapabilities()
                connectionState = "Offline · \(error.localizedDescription)"
                if usesServerRegistry { registryLabel = "Último registry recebido · conexão não validada" }
                scheduleReconnect(after: error)
            }
        }
    }

    private func acceptRegistry(_ authorized: DeskAuthorizedRegistry) throws {
        guard persistBeforeLeaving() else { throw DeskServiceError.invalidRegistry }
        let destinationCache = platformCache ?? cache
        let target = try prepareRegistry(authorized, destinationCache: destinationCache)
        installRegistry(authorized, destinationCache: destinationCache, target: target)
    }

    /// Complete all throwing validation before replacing the active account or its credential.
    private func prepareRegistry(_ authorized: DeskAuthorizedRegistry, destinationCache: LocalCache?) throws -> Project? {
        try authorized.registry.validate()
        guard !authorized.contractVersion.isEmpty else { throw DeskServiceError.invalidRegistry }
        let principal = authorized.registry.principalID
        let validIdentities = Set(authorized.registry.projects.map { WorkspaceIdentity(tenantID: $0.tenantID, projectID: $0.id, principalID: principal) })
        guard authorized.contexts.allSatisfy({ validIdentities.contains($0.identity) }), Set(authorized.contexts.map(\.identity)).count == authorized.contexts.count else { throw DeskServiceError.invalidRegistry }
        let previous = identity
        // Resolve persisted state before changing the active principal. A corrupt selection must not
        // associate the previous principal's authored draft with the next account.
        let remembered = try destinationCache?.loadSelection(principalID: principal)
        let sameCache = destinationCache?.directory == cache?.directory
        let preferred = sameCache && previous?.principalID == principal ? previous : remembered?.identity
        return authorized.registry.projects.first { $0.id == preferred?.projectID && $0.tenantID == preferred?.tenantID } ?? authorized.registry.projects.first
    }

    private func installRegistry(_ authorized: DeskAuthorizedRegistry, destinationCache: LocalCache?, target: Project?) {
        cache = destinationCache
        registry = authorized.registry; projects = registry.projects; tenants = registry.tenants
        contexts = Dictionary(uniqueKeysWithValues: authorized.contexts.map { ($0.identity, $0) })
        usesServerRegistry = true; registryLabel = "Registry autorizado · \(authorized.contractVersion)"
        selectedProject = nil; selectedSubproject = ""; lastSavedDraft = nil
        if let target { select(target) }
        else { selectedTenantID = tenants.first?.id ?? ""; handoff = HandoffDraft() }
    }

    private func updateCapabilities() {
        expiryTask?.cancel()
        supportsScopedSearch = connectionReady && currentContext?.allows(.search) == true
        canRegisterRun = connectionReady && currentContext?.allows(.runCreate) == true && executionProviders.contains(where: \.isSupported)
        canExecuteRun = canRegisterRun && agentExecution && selectedExecutionProvider?.kind == "text-model"
        if !connectionReady {
            capabilitiesMessage = "Rascunhos disponíveis neste Mac. Reconecte para validar acesso remoto."
        } else if !usesServerRegistry {
            capabilitiesMessage = "Este servidor não informa isolamento por projeto. Busca e execução por projeto indisponíveis."
        } else if currentContext == nil {
            capabilitiesMessage = "O servidor não concedeu acesso remoto a este projeto."
        } else {
            capabilitiesMessage = "Permissões verificadas pelo servidor para este projeto."
            if let context = currentContext {
                let delay = max(0, context.expiresAt.timeIntervalSinceNow)
                if delay == 0 { revokeExpiredAccess(); return }
                let token = generation
                expiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, token == generation else { return }
                    revokeExpiredAccess()
                }
            }
        }
    }
    private func revokeExpiredAccess() {
        invalidateContext(); supportsScopedSearch = false; canExecuteRun = false; canRegisterRun = false
        capabilitiesMessage = "Permissão expirada. Reconecte para revalidar o acesso."
        connectionState = "Desk: acesso ao projeto expirado · verifique a conexão"
    }

    func searchMemory() {
        let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { memorySearchState = "Digite uma busca."; return }
        guard connectionReady, let context = currentContext, context.allows(.search) else { memorySearchState = capabilitiesMessage; return }
        invalidateSearch(); let token = searchGeneration; let scope = generation
        isSearching = true; memorySearchState = "Buscando no projeto autorizado…"
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await service.search(query: query, context: context)
                guard !Task.isCancelled, token == searchGeneration, scope == generation, identity == context.identity, currentContext == context, context.allows(.search) else { return }
                memoryResults = hits.map { "\($0.title)\n\($0.content)\n\nFonte: \($0.source) · versão \($0.version)" }
                memorySearchState = "\(hits.count) resultado(s) · projeto autorizado · apenas nesta sessão"
                isSearching = false
            } catch {
                guard !Task.isCancelled, token == searchGeneration, scope == generation else { return }
                isSearching = false; memoryResults = []; memorySearchState = error.localizedDescription
                handleAccessFailure(error)
            }
        }
    }

    private func refreshCheckpoint() {
        guard connectionReady, selectedSubproject.isEmpty, let context = currentContext, context.allows(.checkpoint) else { return }
        let token = generation
        checkpointTask = Task { [weak self] in
            guard let self else { return }
            do {
                let checkpoint = try await service.checkpoint(context: context)
                guard !Task.isCancelled, token == generation, currentContext == context, context.allows(.checkpoint) else { return }
                if let checkpoint {
                    guard checkpoint.identity == identity else { throw DeskServiceError.invalidIdentity }
                    remoteCheckpoint = checkpoint
                    checkpointSummary = "Versão \(checkpoint.version)\n\(checkpoint.context)\n\nMudanças: \(checkpoint.delta)\nPróxima ação: \(checkpoint.nextAction)\nBloqueios: \(checkpoint.blockers)"
                    checkpointSources = checkpoint.sources
                }
            } catch { guard token == generation, !Task.isCancelled else { return }; checkpointSummary = ""; remoteCheckpoint = nil; checkpointError = error.localizedDescription; handleAccessFailure(error) }
        }
    }
    func adoptCheckpoint() {
        guard let checkpoint = remoteCheckpoint, checkpoint.identity == identity, currentContext?.allows(.checkpoint) == true, draftWritable else { return }
        // Explicit user action creates a local draft; no automatic remote checkpoint overwrite.
        handoff.context = checkpoint.context; handoff.delta = checkpoint.delta; handoff.objective = checkpoint.nextAction
        handoff.pending = checkpoint.blockers; handoff.sources = checkpoint.sources.joined(separator: "\n"); handoff.version = checkpoint.version
        saveDraft()
    }

    func executeHandoff() {
        guard !isRunning, canRegisterRun, let provider = selectedExecutionProvider, let context = currentContext, context.allows(.runCreate), !handoff.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, saveDraft(), let cache else { return }
        guard handoff.objective.count <= 16000 else { runStatus = "O objetivo deve ter no máximo 16.000 caracteres. O rascunho foi preservado."; return }
        let draft = handoff; let token = generation
        let operation: PendingRunOperation
        do {
            let payload: JSONValue = .object(["objective": .string(draft.objective), "provider": .string(provider.id)])
            operation = try cache.beginRunOperation(identity: context.identity, kind: .create, payloadFingerprint: try PendingRunOperation.fingerprint(payload))
        } catch { storageError = "Não foi possível registrar a tentativa localmente: \(error.localizedDescription)"; return }
        refreshPendingOperations()
        isRunning = true; runStatus = "Registrando o objetivo no backend autorizado…"
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let run = try await service.startRun(draft: draft, context: context, providerID: provider.id, idempotencyKey: operation.idempotencyKey)
                guard !Task.isCancelled, token == generation, currentContext == context, context.allows(.runCreate) else { return }
                guard run.identity == identity, run.providerID == provider.id else { throw DeskServiceError.invalidIdentity }
                try cache.completeRunOperation(operation)
                refreshPendingOperations()
                runListTask?.cancel()
                upsertRun(run); runStatus = "\(run.status) · \(run.summary)"; isRunning = false; selectRun(run)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                isRunning = false; runStatus = "Resultado não confirmado: \(error.localizedDescription). A tentativa foi preservada para reconciliação."
                handleAccessFailure(error)
            }
        }
    }
    func refreshRuns() {
        guard connectionReady, let context = currentContext, context.allows(.runRead) else { runStatus = capabilitiesMessage; return }
        runListTask?.cancel(); let token = generation
        runStatus = "Consultando execuções autorizadas…"
        runListTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await service.runs(context: context, after: nil)
                guard !Task.isCancelled, token == generation, currentContext == context, context.allows(.runRead) else { return }
                guard results.allSatisfy({ $0.identity == identity }) else { throw DeskServiceError.invalidIdentity }
                let prior = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
                runs = results.map { incoming in
                    if let current = prior[incoming.id], current.version > incoming.version { return current }; return incoming
                }; runStatus = results.isEmpty ? "Nenhum run encontrado neste projeto." : "\(results.count) execução(ões) recuperada(s)."
                if let selected = runs.first(where: { $0.id == selectedRunID }) ?? runs.first { selectRun(selected) }
            } catch { guard token == generation, !Task.isCancelled else { return }; runStatus = error.localizedDescription; handleAccessFailure(error) }
        }
    }

    private func refreshPendingOperations() {
        pendingRunNotice = ""
        guard let identity, let cache else { pendingRunNotice = ""; return }
        do {
            let pending = try cache.pendingRunOperations(identity: identity)
            pendingRunNotice = pending.isEmpty ? "" : "\(pending.count) tentativa(s) aguardam confirmação. Atualize as execuções; repetir o mesmo objetivo com o mesmo executor reutiliza a chave salva, inclusive após reiniciar."
        } catch { storageError = "Não foi possível ler as tentativas pendentes: \(error.localizedDescription)" }
    }
    private func upsertRun(_ incoming: DeskRun) {
        guard incoming.identity == identity else { return }
        if let current = runs.first(where: { $0.id == incoming.id }), current.version > incoming.version { return }
        if let index = runs.firstIndex(where: { $0.id == incoming.id }) { runs[index] = incoming } else { runs.insert(incoming, at: 0) }
    }
    func canResume(_ run: DeskRun) -> Bool {
        connectionReady && run.failureCode != "effect_requires_reconciliation" && executionProviders.contains(where: { $0.id == run.providerID && $0.isSupported }) && run.identity == identity && currentContext?.allows(.runResume) == true && ["failed", "cancelled"].contains(run.status) && !isRunning
    }
    func canCancel(_ run: DeskRun) -> Bool {
        connectionReady && run.identity == identity && currentContext?.allows(.runCancel) == true && ["queued", "running"].contains(run.status) && !isRunning
    }
    func selectRun(_ incoming: DeskRun) {
        let run = runs.first(where: { $0.id == incoming.id && $0.version > incoming.version }) ?? incoming
        guard run.identity == identity else { return }
        if selectedRunID != run.id {
            eventsTask?.cancel(); eventGeneration = UUID(); runEvents = []; selectedRunID = run.id
        }
        refreshRunEvents()
        pollingTask?.cancel()
        guard ["queued", "running"].contains(run.status) else { return }
        let scope = generation
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, scope == generation, selectedRunID == run.id, let context = currentContext, context.allows(.runRead) else { return }
                do {
                    let latest = try await service.run(id: run.id, context: context)
                    guard !Task.isCancelled, scope == generation, latest.identity == identity, context == currentContext else { return }
                    upsertRun(latest)
                    if let effective = runs.first(where: { $0.id == latest.id }) { runStatus = "\(effective.status) · \(effective.summary)" }
                    if !isLoadingEvents { refreshRunEvents() }
                    if let effective = runs.first(where: { $0.id == latest.id }), !["queued", "running"].contains(effective.status) { return }
                } catch {
                    guard !Task.isCancelled, scope == generation else { return }
                    runStatus = "Acompanhamento interrompido: \(error.localizedDescription). Reconecte para retomar."
                    handleAccessFailure(error); return
                }
            }
        }
    }
    func refreshRunEvents() {
        guard connectionReady, let context = currentContext, context.allows(.runEvents), !selectedRunID.isEmpty else { return }
        guard let cache else { eventsStatus = "Eventos indisponíveis: o armazenamento do cursor precisa ser recuperado."; return }
        eventsTask?.cancel(); eventGeneration = UUID()
        let token = eventGeneration; let scope = generation; let runID = selectedRunID
        isLoadingEvents = true; eventsStatus = "Recuperando eventos desde o cursor salvo…"
        eventsTask = Task { [weak self] in
            guard let self else { return }
            do {
                var cursor = try cache.loadRunCursor(identity: context.identity, runID: runID)?.lastEventSequence ?? 0
                var pages = 0
                repeat {
                    let page = try await service.events(runID: runID, context: context, after: cursor, limit: 100)
                    guard !Task.isCancelled, scope == generation, token == eventGeneration, context == currentContext, context.allows(.runEvents), selectedRunID == runID else { return }
                    guard page.nextCursor >= cursor, page.events.allSatisfy({ $0.runID == runID }), !page.hasMore || page.nextCursor > cursor else { throw DeskServiceError.invalidIdentity }
                    var seen = Set(runEvents.map(\.id))
                    let newEvents = page.events.filter { seen.insert($0.id).inserted }
                    try cache.saveRunCursor(LocalRunCursor(identity: context.identity, runID: runID, cursor: String(page.nextCursor), lastEventSequence: page.nextCursor))
                    runEvents.append(contentsOf: newEvents)
                    if runEvents.count > 500 { runEvents.removeFirst(runEvents.count - 500) }
                    cursor = page.nextCursor; pages += 1
                    if !page.hasMore { break }
                    if pages % 50 == 0 { await Task.yield() }
                } while !Task.isCancelled
                guard token == eventGeneration, scope == generation, !Task.isCancelled else { return }
                isLoadingEvents = false; eventsStatus = "Cursor \(cursor) salvo · \(runEvents.count) evento(s) nesta sessão"
            } catch {
                guard token == eventGeneration, scope == generation, !Task.isCancelled else { return }
                isLoadingEvents = false; eventsStatus = "Eventos não atualizados: \(error.localizedDescription)"; handleAccessFailure(error)
            }
        }
    }
    func resumeRun(_ run: DeskRun) {
        guard canResume(run), let context = currentContext, let cache else { return }
        let operation: PendingRunOperation
        do {
            operation = try cache.beginRunOperation(identity: context.identity, kind: .resume, payloadFingerprint: try PendingRunOperation.fingerprint(.object(["run_id": .string(run.id), "operation": .string("resume")])), runID: run.id)
        } catch { storageError = error.localizedDescription; return }
        refreshPendingOperations()
        let token = generation; isRunning = true; runStatus = "Solicitando retomada do mesmo run…"
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await service.resumeRun(id: run.id, context: context, idempotencyKey: operation.idempotencyKey)
                guard token == generation, !Task.isCancelled, context == currentContext else { return }
                guard updated.identity == identity, updated.id == run.id, updated.providerID == run.providerID else { throw DeskServiceError.invalidIdentity }
                try cache.completeRunOperation(operation)
                refreshPendingOperations()
                runListTask?.cancel(); upsertRun(updated); isRunning = false; runStatus = "\(updated.status) · mesmo run retomado"; selectRun(updated)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                isRunning = false; runStatus = "Retomada não confirmada: \(error.localizedDescription)"; handleAccessFailure(error)
            }
        }
    }
    func cancelRun(_ run: DeskRun) {
        guard canCancel(run), let context = currentContext else { return }
        let token = generation; isRunning = true; runStatus = "Solicitando cancelamento…"
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await service.cancelRun(id: run.id, context: context)
                guard token == generation, !Task.isCancelled, context == currentContext else { return }
                guard updated.identity == identity, updated.id == run.id, updated.providerID == run.providerID else { throw DeskServiceError.invalidIdentity }
                runListTask?.cancel(); upsertRun(updated); isRunning = false; runStatus = "\(updated.status) · estado confirmado pelo servidor"; selectRun(updated)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                isRunning = false; runStatus = "Cancelamento não confirmado: \(error.localizedDescription). Atualize o run antes de repetir."; handleAccessFailure(error)
            }
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case PlatformClientError.timeout = error { return true }
        if case PlatformClientError.server(let status, _, let retryable) = error { return status == 503 && retryable }
        if case MCPError.timeout = error { return true }
        if case MCPError.transport = error { return true }
        return false
    }
    private func scheduleReconnect(after error: Error) {
        guard !preview, isTransient(error) else { return }
        if let lastReconnectFailure, Date().timeIntervalSince(lastReconnectFailure) > 60 { reconnectAttempts = 0 }
        guard reconnectAttempts < 3 else { return }
        lastReconnectFailure = Date()
        reconnectAttempts += 1
        let delay = TimeInterval(1 << reconnectAttempts)
        let token = connectionGeneration
        reconnectTask?.cancel()
        connectionState = "Offline · nova tentativa em \(Int(delay)) s"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, token == connectionGeneration, !connectionReady else { return }
            connectRemote()
        }
    }
    private func handleAccessFailure(_ error: Error) {
        let denied: Bool
        if case DeskServiceError.permissionDenied = error { denied = true }
        else if case PlatformClientError.unauthenticated = error { denied = true }
        else if case PlatformClientError.forbidden = error { denied = true }
        else { denied = false }
        if denied {
            invalidateContext(); contexts = [:]; connectionReady = false; updateCapabilities()
            connectionState = "Acesso remoto não autorizado · reconecte"
            registryLabel = usesServerRegistry ? "Acesso ao registry invalidado" : registryLabel
        } else if isTransient(error) {
            invalidateContext(); contexts = [:]; connectionReady = false; updateCapabilities()
            connectionState = "Offline · \(error.localizedDescription)"
            scheduleReconnect(after: error)
        }
    }


    var attachmentProject: WorkspaceProject? {
        guard connectionReady, usesServerRegistry, activePlatformEndpoint != nil,
              let context = currentContext, context.expiresAt > Date(), !context.authorizationRevision.isEmpty,
              let project = selectedProject,
              currentContext?.identity.tenantID == project.tenantID,
              currentContext?.identity.projectID == project.id else { return nil }
        return project
    }

    func attachWorkspace(folder: URL, project: WorkspaceProject) throws {
        // Recheck after the panel returns: neither a stale selection nor a cached registry grants scope.
        guard attachmentProject == project, !isConnecting, !isValidatingPlatformConnection,
              let endpoint = activePlatformEndpoint else { throw DeskServiceError.invalidRegistry }
        let remote = endpoint.scheme?.lowercased() == "https"
        let attachment = try WorkspaceAttachment(folder: folder, baseURL: endpoint, tenant: project.tenantID, project: project.id,
            cloudflareIDEnvironment: remote ? "M3_PLATFORM_CF_CLIENT_ID" : nil,
            cloudflareSecretEnvironment: remote ? "M3_PLATFORM_CF_CLIENT_SECRET" : nil)
        try WorkspaceAttachmentFile.attach(attachment, to: WorkspaceAttachmentFile.defaultURL)
    }

    func configurePlatform() {
        guard !isValidatingPlatformConnection else { return }
        let enteredCredential = platformCredential
        platformCredential = ""
        do {
            guard let url = URL(string: platformEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PlatformCredentials.CredentialError.invalid }
            try PlatformDeskService.validateEndpoint(url)
            let credential = try enteredCredential.isEmpty ? loadPlatformCredential(url) : enteredCredential
            try validatePlatformConnection(url: url, credential: credential, expectedPrincipalID: nil)
        } catch { platformConnectionValidationMessage = "Conexão não alterada. \(error.localizedDescription)" }
    }

    func importPlatformConnection(from url: URL) {
        guard !isValidatingPlatformConnection else { return }
        platformCredential = ""
        do {
            let imported = try PlatformConnectionImport.load(from: url)
            try validatePlatformConnection(url: imported.baseURL, credential: imported.token, expectedPrincipalID: imported.principalID, profileNotice: imported.profileNotice)
        } catch { platformConnectionValidationMessage = "Conexão não importada. \(error.localizedDescription)" }
    }

    private func validatePlatformConnection(url: URL, credential: String, expectedPrincipalID: String?, profileNotice: String = "") throws {
        try PlatformDeskService.validateEndpoint(url)
        guard !credential.isEmpty, credential.count <= 8192,
              !credential.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw PlatformCredentials.CredentialError.invalid
        }
        guard let base = registryURL?.deletingLastPathComponent() else { throw DeskServiceError.unsupported("Configuração remota indisponível no preview.") }
        let candidate = try platformServiceFactory(url, credential)
        platformValidationGeneration = UUID()
        let revision = platformValidationGeneration
        isValidatingPlatformConnection = true
        platformConnectionValidationMessage = "Validando credencial, identidade e projetos no servidor…"
        platformValidationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == platformValidationGeneration {
                    isValidatingPlatformConnection = false; platformValidationTask = nil
                }
            }
            do {
                let result = try await candidate.connect()
                guard !Task.isCancelled, revision == platformValidationGeneration else { return }
                guard let authorized = result.authorizedRegistry else { throw DeskServiceError.invalidRegistry }
                if let expectedPrincipalID, authorized.registry.principalID != expectedPrincipalID {
                    throw PlatformConnectionActivationError.principalMismatch
                }
                let nextCache = try LocalCache(directory: PlatformCacheNamespace.directory(for: url, in: base))
                let target = try prepareRegistry(authorized, destinationCache: nextCache)
                guard persistBeforeLeaving() else { throw PlatformConnectionActivationError.unsavedDraft }
                // No await or throwing profile operation follows this credential commit.
                try savePlatformCredential(credential, url)
                connectionTask?.cancel(); connectionGeneration = UUID(); reconnectTask?.cancel(); reconnectAttempts = 0
                invalidateContext(); connectionReady = false; isConnecting = false
                service = candidate; platformCache = nextCache; activePlatformEndpoint = url
                self.expectedPlatformPrincipalID = authorized.registry.principalID
                defaults.set(url.absoluteString, forKey: "platform.endpoint")
                defaults.set(authorized.registry.principalID, forKey: "platform.principal")
                defaults.set(true, forKey: "platform.enabled")
                defaults.set(profileNotice, forKey: "platform.profileNotice")
                platformProfileNotice = profileNotice
                platformEndpoint = url.absoluteString; storageError = ""
                installRegistry(authorized, destinationCache: nextCache, target: target)
                agentExecution = result.agentExecution; executionProviders = result.executionProviders
                connectionReady = true; connectionState = "Desk conectado · identidade e projetos verificados"
                platformConnectionValidationMessage = "Identidade validada: \(authorized.registry.principalID) · \(authorized.registry.projects.count) projetos autorizados."
                updateCapabilities(); refreshCheckpoint()
                if canRefreshRuns { refreshRuns() }
                showConnectionSettings = false
            } catch {
                guard !Task.isCancelled, revision == platformValidationGeneration else { return }
                platformConnectionValidationMessage = "Conexão não alterada. \(error.localizedDescription)"
            }
        }
    }

    func cancelPlatformConnectionValidation() {
        if isValidatingPlatformConnection { platformConnectionValidationMessage = "Validação cancelada. Conexão não alterada." }
        platformValidationGeneration = UUID(); platformValidationTask?.cancel(); platformValidationTask = nil
        isValidatingPlatformConnection = false; platformCredential = ""
    }
    func refreshRecoveryCandidates() {
        do { recoveryCandidates = try cache?.recoveryCandidates(defaults: defaults) ?? [] }
        catch { storageError = error.localizedDescription }
    }
    var canRecoverLegacyDraft: Bool {
        guard let identity, let cache, !usesServerRegistry, draftWritable else { return false }
        return !FileManager.default.fileExists(atPath: cache.draftURL(identity: identity, subprojectID: selectedSubproject.isEmpty ? nil : selectedSubproject).path) && handoff.objective.isEmpty && handoff.context.isEmpty && handoff.delta.isEmpty && handoff.sources.isEmpty && handoff.pending.isEmpty
    }
    func recoverLegacy(_ candidate: LegacyDraftCandidate) {
        guard canRecoverLegacyDraft, let identity, let cache else { storageError = "Selecione um contexto local vazio para recuperar o rascunho."; return }
        do {
            handoff = try cache.recoverLegacy(candidate, identity: identity, subprojectID: selectedSubproject.isEmpty ? nil : selectedSubproject, defaults: defaults)
            lastSavedDraft = handoff; showRecovery = false; localNotice = "Rascunho recuperado. O original foi preservado."; refreshRecoveryCandidates()
        } catch { storageError = error.localizedDescription }
    }

    func copyHandoff() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoff.preview, forType: .string)
        handoffFeedback = "Copiado · não enviado"
    }
    func exportHandoff() {
        let snapshot = handoff; let panel = NSSavePanel(); panel.nameFieldStringValue = "handoff.md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try HandoffExporter.write(snapshot, to: url); self?.handoffFeedback = "Exportado · não enviado" }
            catch { self?.storageError = "Exportação falhou: \(error.localizedDescription)" }
        }
    }
    func configureRegistry() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try importRegistry(from: url) }
            catch { storageError = "Configuração não importada: \(error.localizedDescription)" }
        }
    }
    func importRegistry(from url: URL) throws {
        guard !isValidatingPlatformConnection else { throw DeskServiceError.unsupported("Aguarde a validação da conexão.") }
        let imported = try LocalRegistry.load(from: url)
        try imported.validate()
        guard persistBeforeLeaving() else { throw CocoaError(.fileWriteUnknown) }
        if let registryURL { try imported.save(to: registryURL) }
        connectionTask?.cancel(); connectionGeneration = UUID(); invalidateContext()
        cache = localCache; registry = imported; projects = registry.projects; tenants = registry.tenants; contexts = [:]; usesServerRegistry = false
        connectionReady = false; isConnecting = false; registryLabel = "Configuração local importada · acesso remoto não validado"
        selectedProject = nil; lastSavedDraft = nil; selectedSubproject = ""
        if let first = projects.first { select(first) } else { selectedTenantID = tenants.first?.id ?? ""; handoff = HandoffDraft() }
        updateCapabilities()
    }
}

private enum PlatformConnectionActivationError: LocalizedError {
    case principalMismatch, unsavedDraft
    var errorDescription: String? {
        switch self {
        case .principalMismatch: "A identidade autenticada não corresponde à conexão configurada."
        case .unsavedDraft: "Não foi possível salvar o rascunho atual. Exporte-o antes de mudar a conexão."
        }
    }
}
