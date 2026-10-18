import Testing
import Foundation
@testable import M3Desk
import M3DeskCore

actor ControlledDeskService: DeskService {
    var registry: LocalRegistry
    var permissions: Set<DeskPermission>
    var authorized: Bool
    var principal: String
    var searchCalls = 0
    var queryDelays: [String: UInt64] = [:]
    var denySearch = false
    var failCreate = false
    var createKeys: [String] = []
    var createProviders: [String] = []
    var providers: [DeskExecutionProvider] = [.init(id: "local", kind: "docker-tool"), .init(id: "local-model", kind: "text-model", model: "synthetic-model", experimental: true)]
    var eventCursors: [Int] = []
    var lifetime: TimeInterval = 300
    var listDelay: UInt64 = 0
    var createdRunID = "run-1"
    var createdRunVersion = 1
    var connectFailures = 0
    init(registry: LocalRegistry = .builtIn, permissions: Set<DeskPermission> = [.search, .checkpoint, .runRead, .runCreate, .runEvents, .runResume, .runCancel], authorized: Bool = true) {
        self.registry = registry; self.permissions = permissions; self.authorized = authorized; principal = registry.principalID
    }
    func setDelay(_ query: String, _ nanoseconds: UInt64) { queryDelays[query] = nanoseconds }
    func setDenySearch() { denySearch = true }
    func setProviders(_ value: [DeskExecutionProvider]) { providers = value }
    func setFailCreate(_ fail: Bool) { failCreate = fail }
    func setConnectFailures(_ value: Int) { connectFailures = value }
    func setListDelay(_ value: UInt64) { listDelay = value }
    func setCreatedRun(_ id: String, version: Int) { createdRunID = id; createdRunVersion = version }
    func setLifetime(_ value: TimeInterval) { lifetime = value }
    func connect() async throws -> DeskConnection {
        if connectFailures > 0 { connectFailures -= 1; throw URLError(.notConnectedToInternet) }
        let contexts = registry.projects.map { project in DeskAccessContext(identity: .init(tenantID: project.tenantID, projectID: project.id, principalID: principal), permissions: permissions, authorizationRevision: "test-lease", expiresAt: Date().addingTimeInterval(lifetime)) }
        return DeskConnection(serverDescription: "Synthetic test service", protocolVersion: "m3.platform.v1", tools: [], authorizedRegistry: authorized ? .init(registry: registry, contexts: contexts, contractVersion: "m3.platform.v1") : nil, agentExecution: true, executionProviders: providers)
    }
    func search(query: String, context: DeskAccessContext) async throws -> [DeskMemoryHit] {
        searchCalls += 1
        if let delay = queryDelays[query] { try? await Task.sleep(nanoseconds: delay) }
        if denySearch { throw PlatformClientError.forbidden }
        return [.init(id: "hit-\(query)", title: query, content: "synthetic \(context.identity.projectID)", source: "test", version: "1")]
    }
    func checkpoint(context: DeskAccessContext) async throws -> DeskCheckpoint? { nil }
    func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) async throws -> DeskRun {
        createKeys.append(idempotencyKey); createProviders.append(providerID)
        if failCreate { throw PlatformClientError.timeout }
        return DeskRun(id: createdRunID, identity: context.identity, status: "failed", summary: "Synthetic registered objective", version: createdRunVersion, providerID: providerID)
    }
    func runs(context: DeskAccessContext, after cursor: String?) async throws -> [DeskRun] {
        if listDelay > 0 { try? await Task.sleep(nanoseconds: listDelay) }
        return [.init(id: "run-1", identity: context.identity, status: "failed", summary: "Synthetic test run", providerID: "local")]
    }
    func events(runID: String, context: DeskAccessContext, after: Int, limit: Int) async throws -> PlatformEventPage {
        eventCursors.append(after)
        let event = PlatformRunEvent(id: "event-1", runID: runID, type: "test", payload: .object([:]), createdAt: "2026-10-02T12:00:00Z")
        return .init(events: [event], nextCursor: max(1, after), hasMore: false)
    }
}

@MainActor
struct M3DeskTests {
    private func makeStore(service: any DeskService, cache: LocalCache? = nil, defaults: UserDefaults? = nil) throws -> WorkspaceStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("desk-tests-\(UUID().uuidString)")
        return WorkspaceStore(service: service, cache: try cache ?? LocalCache(directory: folder), defaults: defaults ?? UserDefaults(suiteName: "desk-tests-\(UUID().uuidString)")!, registry: .builtIn)
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Timed out waiting for state")
    }
    private func connect(_ store: WorkspaceStore) async { store.checkMCP(); await waitUntil { !store.isConnecting }; #expect(store.connectionReady) }

    @Test func unconfiguredDeskRemainsOfflineWithoutLegacyDiscovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unconfigured-desk-\(UUID().uuidString)")
        let suite = "unconfigured-desk-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkspaceStore(cache: try LocalCache(directory: directory), defaults: defaults, registry: .builtIn)
        store.checkMCP()
        await waitUntil { !store.isConnecting }
        #expect(!store.connectionReady)
        #expect(!store.supportsScopedSearch)
        #expect(!store.canRegisterRun)
        #expect(store.connectionState.contains("Configure a conexão individual"))
        #expect(!defaults.bool(forKey: "platform.enabled"))
    }

    @Test func testFilterAndMemoryQueryDoNotChangeSelection() throws {
        let store = try makeStore(service: ControlledDeskService())
        let selection = store.identity
        store.projectFilter = "H-INNOVA"; store.memoryQuery = "decisão"
        #expect(store.visibleProjects.map(\.id) == ["hinnova"])
        #expect(store.identity == selection)
        #expect(AppSection.allCases.count == 4)
    }
    @Test func testLegacyDiscoveryDoesNotGrantScopedSearchOrRun() async throws {
        let service = ControlledDeskService(authorized: false)
        let store = try makeStore(service: service)
        store.checkMCP(); await waitUntil { !store.isConnecting }
        #expect(!store.connectionReady)
        store.memoryQuery = "sensitive"; store.searchMemory()
        #expect(!(store.supportsScopedSearch)); #expect(!(store.canRegisterRun))
        let calls = await service.searchCalls; #expect(calls == 0)
        #expect(store.memoryResults.isEmpty)
    }
    @Test func testLateSearchNeverAppearsAfterProjectSwitch() async throws {
        let service = ControlledDeskService(); await service.setDelay("old", 250_000_000)
        let store = try makeStore(service: service); await connect(store)
        store.memoryQuery = "old"; store.searchMemory()
        try? await Task.sleep(for: .milliseconds(30))
        store.select(store.projects[1])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.memoryResults.isEmpty); #expect(!(store.isSearching))
        #expect(store.selectedProject?.id == "studionext")
    }
    @Test func testLatestQueryWinsAndDeniedClearsRemoteState() async throws {
        let service = ControlledDeskService(); await service.setDelay("old", 200_000_000)
        let store = try makeStore(service: service); await connect(store)
        store.memoryQuery = "old"; store.searchMemory()
        try? await Task.sleep(for: .milliseconds(20))
        store.memoryQuery = "new"; store.searchMemory()
        await waitUntil { !store.isSearching }
        try? await Task.sleep(for: .milliseconds(230))
        #expect(store.memoryResults.first?.contains("new") == true)
        await service.setDenySearch(); store.memoryQuery = "denied"; store.searchMemory()
        await waitUntil { !store.isSearching }
        #expect(store.memoryResults.isEmpty); #expect(!(store.connectionReady)); #expect(!(store.supportsScopedSearch))
    }
    @Test func testDraftSurvivesProjectSwitchAndStoreRestart() throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults(suiteName: "draft-restart-\(UUID().uuidString)")!
        let service = ControlledDeskService()
        let first = try makeStore(service: service, cache: cache, defaults: defaults)
        first.handoff.context = "Authored locally"; #expect(first.saveDraft())
        first.select(first.projects[1]); first.handoff.objective = "Other project"; #expect(first.saveDraft())
        let restarted = try makeStore(service: service, cache: cache, defaults: defaults)
        #expect(restarted.selectedProject?.id == "studionext")
        #expect(restarted.handoff.objective == "Other project")
        restarted.select(restarted.projects[0]); #expect(restarted.handoff.context == "Authored locally")
    }
    @Test func testRegistrationIsDistinctFromAgentExecutionAndRetryKeySurvivesRestart() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults(suiteName: "idempotency-\(UUID().uuidString)")!
        let service = ControlledDeskService(); await service.setFailCreate(true)
        let first = try makeStore(service: service, cache: cache, defaults: defaults); await connect(first)
        #expect(first.canRegisterRun); #expect(!(first.canExecuteRun))
        first.handoff.objective = "One logical task"; first.selectProvider("local"); first.executeHandoff(); await waitUntil { !first.isRunning }
        let second = try makeStore(service: service, cache: cache, defaults: defaults); await connect(second)
        second.executeHandoff(); await waitUntil { !second.isRunning }
        let keys = await service.createKeys; #expect(keys.count == 2); #expect(keys.first == keys.last)
    }
    @Test func testEventsDeduplicateAndResumeAtPersistedCursor() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = ControlledDeskService()
        let store = try makeStore(service: service, cache: cache); await connect(store)
        await waitUntil { store.runEvents.count == 1 && !store.isLoadingEvents }
        store.refreshRunEvents(); await waitUntil { !store.isLoadingEvents }
        #expect(store.runEvents.count == 1)
        let restarted = try makeStore(service: service, cache: cache); await connect(restarted)
        await waitUntil { !restarted.isLoadingEvents && restarted.runEvents.count == 1 }
        let cursors = await service.eventCursors; #expect(cursors.first == 0); #expect(cursors.dropFirst().allSatisfy { $0 >= 1 })
    }
    @Test func testExpiredLeaseClearsRemotePayloadButKeepsDraft() async throws {
        let service = ControlledDeskService(); await service.setLifetime(0.15)
        let store = try makeStore(service: service); await connect(store)
        store.handoff.context = "Local context"; store.saveDraft()
        store.memoryQuery = "fresh"; store.searchMemory(); await waitUntil { !store.isSearching }
        await waitUntil { !store.supportsScopedSearch }
        #expect(store.memoryResults.isEmpty); #expect(store.handoff.context == "Local context")
    }
    @Test func testCorruptNewPrincipalSelectionCannotReattributeExistingDraft() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var remote = LocalRegistry.builtIn; remote.principalID = "new-principal"
        let target = WorkspaceIdentity(tenantID: "local-workspace", projectID: "monumenta", principalID: "new-principal")
        try cache.saveSelection(.init(identity: target))
        let selectionFile = try #require(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("selection-") })
        try Data("broken-json".utf8).write(to: selectionFile)
        let store = try makeStore(service: ControlledDeskService(registry: remote), cache: cache)
        store.handoff.context = "Original principal authored this"; #expect(store.saveDraft())
        store.checkMCP(); await waitUntil { !store.isConnecting }
        #expect(!store.connectionReady)
        #expect(store.identity?.principalID == "local-user")
        #expect(store.handoff.context == "Original principal authored this")
        #expect(store.saveDraft())
        #expect(try cache.loadDraft(identity: target, projectName: "Monumenta / BB").draft.context.isEmpty)
    }
    @Test func testLateRunListCannotEraseNewlyRegisteredRun() async throws {
        let service = ControlledDeskService()
        let store = try makeStore(service: service); await connect(store)
        await waitUntil { !store.runs.isEmpty }
        await service.setListDelay(250_000_000); await service.setCreatedRun("new-run", version: 2)
        store.refreshRuns(); try? await Task.sleep(for: .milliseconds(20))
        store.handoff.objective = "New objective"; store.selectProvider("local"); store.executeHandoff()
        await waitUntil { !store.isRunning }
        try? await Task.sleep(for: .milliseconds(280))
        #expect(store.runs.contains { $0.id == "new-run" && $0.version == 2 })
    }

    @Test func testKeychainRoundTripUsesUniqueTemporaryAccount() throws {
        let endpoint = URL(string: "https://m3desk-verification.invalid/\(UUID().uuidString)")!
        defer { try? PlatformCredentials.remove(endpoint: endpoint) }
        let synthetic = "synthetic-verification-\(UUID().uuidString)"
        try PlatformCredentials.save(synthetic, endpoint: endpoint)
        let matches = try PlatformCredentials.load(endpoint: endpoint) == synthetic
        #expect(matches)
        try PlatformCredentials.remove(endpoint: endpoint)
        #expect(throws: (any Error).self) { try PlatformCredentials.load(endpoint: endpoint) }
    }

    @Test func testTransientDisconnectAutomaticallyReconnectsWithoutChangingDraft() async throws {
        let service = ControlledDeskService(); await service.setConnectFailures(1)
        let store = try makeStore(service: service)
        store.handoff.context = "Local progress before disconnect"; store.saveDraft()
        store.checkMCP()
        await waitUntil { store.connectionReady }
        #expect(store.handoff.context == "Local progress before disconnect")
        #expect(store.supportsScopedSearch)
    }

    @Test func testOversizedObjectiveDoesNotPersistPendingMutation() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = ControlledDeskService()
        let store = try makeStore(service: service, cache: cache); await connect(store)
        await waitUntil { !store.runs.isEmpty }
        store.handoff.objective = String(repeating: "x", count: 16001)
        store.selectProvider("local")
        store.executeHandoff()
        #expect(try cache.pendingRunOperations(identity: #require(store.identity)).isEmpty)
        #expect(await service.createKeys.isEmpty)
        #expect(store.runStatus.contains("16.000"))
    }

    @Test func testCorruptDestinationDraftDoesNotCarryPreviousPendingNotice() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = ControlledDeskService(); await service.setFailCreate(true)
        let store = try makeStore(service: service, cache: cache); await connect(store)
        store.handoff.objective = "Synthetic uncertain result"; store.selectProvider("local"); store.executeHandoff()
        await waitUntil { !store.isRunning }
        #expect(!store.pendingRunNotice.isEmpty)
        let other = store.projects[1]
        let target = WorkspaceIdentity(tenantID: other.tenantID, projectID: other.id, principalID: "local-user")
        var draft = HandoffDraft(); draft.project = other.name
        try cache.saveDraft(draft, identity: target)
        try Data("broken-json".utf8).write(to: cache.draftURL(identity: target))
        store.select(other)
        #expect(store.pendingRunNotice.isEmpty)
        #expect(!store.draftWritable)
    }

    @Test func testExplicitProviderSelectionAndPerRunClassification() async throws {
        let service = ControlledDeskService(); let store = try makeStore(service: service); await connect(store)
        store.handoff.objective = "Respond with ACK"
        store.executeHandoff()
        #expect(await service.createKeys.isEmpty)
        #expect(store.selectedProviderID.isEmpty)
        await waitUntil { !store.runs.isEmpty }
        #expect(store.runs.first?.providerID == "local")
        #expect(store.runs.first?.providerLabel.contains("Ferramenta") == true)
        store.selectProvider("local-model"); #expect(store.canExecuteRun)
        store.executeHandoff(); await waitUntil { !store.isRunning }
        #expect(await service.createProviders == ["local-model"])
    }
    @Test func testProviderChangesGetSeparateRetryKeysAndSelectionSurvivesRestart() async throws {
        let cache = try LocalCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults(suiteName: "provider-restart-\(UUID().uuidString)")!
        let service = ControlledDeskService(); await service.setFailCreate(true)
        let first = try makeStore(service: service, cache: cache, defaults: defaults); await connect(first)
        first.handoff.objective = "Same objective"; first.selectProvider("local-model"); first.executeHandoff()
        await waitUntil { !first.isRunning }
        let second = try makeStore(service: service, cache: cache, defaults: defaults); await connect(second)
        #expect(second.selectedProviderID == "local-model")
        second.executeHandoff(); await waitUntil { !second.isRunning }
        await connect(second); second.selectProvider("local"); second.executeHandoff(); await waitUntil { !second.isRunning }
        let keys = await service.createKeys
        #expect(keys.count == 3); #expect(keys[0] == keys[1]); #expect(keys[1] != keys[2])
        #expect(await service.createProviders == ["local-model", "local-model", "local"])
    }
    @Test func testProviderRemovedOnReconnectCannotBeDispatched() async throws {
        let service = ControlledDeskService(); let store = try makeStore(service: service); await connect(store)
        store.handoff.objective = "Remember my choice"; store.selectProvider("local-model")
        await service.setProviders([.init(id: "local", kind: "docker-tool")]); await connect(store)
        #expect(store.selectedProviderID == "local-model")
        #expect(store.selectedExecutionProvider == nil)
        store.executeHandoff(); #expect(await service.createKeys.isEmpty)
        store.select(store.projects[1]); #expect(store.selectedProviderID.isEmpty)
    }

    @Test func testUncertainEffectRequiresServerReconciliationBeforeAnotherResume() async throws {
        let service = ControlledDeskService(); let store = try makeStore(service: service); await connect(store)
        let identity = try #require(store.identity)
        let run = DeskRun(id: "run-uncertain", identity: identity, status: "failed", summary: "Synthetic uncertain effect", providerID: "local-model", failureCode: "effect_requires_reconciliation")
        #expect(!store.canResume(run))
        let retryable = DeskRun(id: "run-failed", identity: identity, status: "failed", summary: "Synthetic retryable failure", providerID: "local-model")
        #expect(store.canResume(retryable))
    }

}
