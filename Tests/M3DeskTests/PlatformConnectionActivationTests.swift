import Foundation
import Testing
@testable import M3Desk
import M3DeskCore

private enum ActivationFixtureFailure: Error { case credentialWrite }

/// Synchronous credential hooks and actor services share one ordered journal.
private final class ActivationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) { lock.withLock { entries.append(entry) } }
    var events: [String] { lock.withLock { entries } }
}

/// Deliberately ignores Task cancellation so a late connect exercises the generation guard.
private actor ActivationGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}

private actor ActivationDeskService: DeskService {
    private var registry: LocalRegistry
    private let journal: ActivationJournal
    private let name: String
    private let gate: ActivationGate?
    private let rejectAuthentication: Bool
    private(set) var connectCount = 0

    init(registry: LocalRegistry, journal: ActivationJournal, name: String,
         gate: ActivationGate? = nil, rejectAuthentication: Bool = false) {
        self.registry = registry; self.journal = journal; self.name = name
        self.gate = gate; self.rejectAuthentication = rejectAuthentication
    }
    func connect() async throws -> DeskConnection {
        connectCount += 1
        journal.record("\(name).connect.started")
        if let gate { await gate.wait() }
        if rejectAuthentication {
            journal.record("\(name).connect.denied")
            throw PlatformClientError.unauthenticated
        }
        let contexts = registry.projects.map { project in
            DeskAccessContext(identity: .init(tenantID: project.tenantID, projectID: project.id, principalID: registry.principalID),
                permissions: [.search, .checkpoint], authorizationRevision: "synthetic-activation-lease",
                expiresAt: Date().addingTimeInterval(300))
        }
        journal.record("\(name).connect.succeeded")
        return DeskConnection(serverDescription: name, protocolVersion: platformSchemaVersion, tools: [],
            authorizedRegistry: .init(registry: registry, contexts: contexts, contractVersion: platformSchemaVersion))
    }
    func changePrincipal(to value: String) { registry.principalID = value }
    func search(query: String, context: DeskAccessContext) async throws -> [DeskMemoryHit] { [] }
    func checkpoint(context: DeskAccessContext) async throws -> DeskCheckpoint? { nil }
    func startRun(draft: HandoffDraft, context: DeskAccessContext, providerID: String, idempotencyKey: String) async throws -> DeskRun {
        throw DeskServiceError.unsupported("Activation fixture has no execution provider")
    }
    func runs(context: DeskAccessContext, after cursor: String?) async throws -> [DeskRun] { [] }
}

@MainActor
struct PlatformConnectionActivationTests {
    private let oldEndpoint = "https://existing-profile.example.invalid"
    private let newEndpoint = "https://candidate-profile.example.invalid"
    private let syntheticToken = "synthetic-activation-token"

    @MainActor private struct Harness {
        let store: WorkspaceStore
        let defaults: UserDefaults
        let suiteName: String
        let directory: URL
        let cache: LocalCache
        let candidate: ActivationDeskService
        let gate: ActivationGate
        let journal: ActivationJournal
        let oldIdentity: WorkspaceIdentity
        let targetIdentity: WorkspaceIdentity
        func cleanup() {
            store.cancelPlatformConnectionValidation()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func registry(principal: String, suffix: String) -> LocalRegistry {
        .init(tenants: [.init(id: "tenant-\(suffix)", name: "Synthetic \(suffix)", kind: .personal)],
              projects: [.init(id: "project-\(suffix)", name: "Synthetic project \(suffix)", detail: "", tenantID: "tenant-\(suffix)")],
              principalID: principal)
    }

    private func makeHarness(rejectAuthentication: Bool = false, credentialSaveFails: Bool = false) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("platform-activation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cache = try LocalCache(directory: directory.appendingPathComponent("cache", isDirectory: true))
        let suiteName = "platform-activation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(oldEndpoint, forKey: "platform.endpoint")
        defaults.set(true, forKey: "platform.enabled")
        let oldRegistry = registry(principal: "synthetic-existing-principal", suffix: "existing")
        let targetRegistry = registry(principal: "synthetic-target-principal", suffix: "target")
        let journal = ActivationJournal(), gate = ActivationGate()
        let current = ActivationDeskService(registry: oldRegistry, journal: journal, name: "current")
        let candidate = ActivationDeskService(registry: targetRegistry, journal: journal, name: "candidate", gate: gate,
            rejectAuthentication: rejectAuthentication)
        let store = WorkspaceStore(service: current, cache: cache, defaults: defaults, registry: oldRegistry,
            platformServiceFactory: { _, _ in journal.record("candidate.factory"); return candidate },
            loadPlatformCredential: { _ in journal.record("credential.load"); return "synthetic-stored-token" },
            savePlatformCredential: { _, _ in
                journal.record("credential.save.attempt")
                if credentialSaveFails { throw ActivationFixtureFailure.credentialWrite }
                journal.record("credential.save.succeeded")
            })
        store.checkMCP()
        await waitUntil { !store.isConnecting }
        #expect(store.connectionReady)
        let oldIdentity = try #require(store.identity)
        store.handoff.context = "Unsaved authored context in the existing profile"
        let targetIdentity = WorkspaceIdentity(tenantID: "tenant-target", projectID: "project-target", principalID: "synthetic-target-principal")
        return .init(store: store, defaults: defaults, suiteName: suiteName, directory: directory, cache: cache,
            candidate: candidate, gate: gate, journal: journal, oldIdentity: oldIdentity, targetIdentity: targetIdentity)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for connection activation state")
    }
    private func beginConfiguration(_ harness: Harness) async {
        harness.store.platformEndpoint = newEndpoint
        harness.store.platformCredential = syntheticToken
        harness.store.configurePlatform()
        await waitUntil { harness.journal.events.contains("candidate.connect.started") }
    }
    private func expectExistingProfile(_ harness: Harness) {
        #expect(harness.store.identity == harness.oldIdentity)
        #expect(harness.store.connectionReady)
        #expect(harness.store.supportsScopedSearch)
        #expect(harness.store.handoff.context == "Unsaved authored context in the existing profile")
        #expect(harness.defaults.string(forKey: "platform.endpoint") == oldEndpoint)
        #expect(harness.defaults.bool(forKey: "platform.enabled"))
    }
    private func importFile(_ harness: Harness, principalID: String) throws -> URL {
        let url = harness.directory.appendingPathComponent("synthetic-connection.json")
        let data = try JSONSerialization.data(withJSONObject: ["base_url": newEndpoint, "principal_id": principalID, "token": syntheticToken])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    @Test func authenticationFailurePreservesActiveProfileWithoutCredentialOrDefaultsWrite() async throws {
        let harness = try await makeHarness(rejectAuthentication: true)
        defer { harness.cleanup() }
        let defaultsBefore = harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?
        await beginConfiguration(harness)
        #expect(harness.store.isValidatingPlatformConnection)
        expectExistingProfile(harness)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        expectExistingProfile(harness)
        #expect(!harness.store.platformConnectionValidationMessage.isEmpty)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        #expect((harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?) == defaultsBefore)
    }

    @Test func importedPrincipalMismatchNeverReattributesDraftOrPersistsCandidate() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let defaultsBefore = harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?
        let file = try importFile(harness, principalID: "synthetic-wrong-principal")
        harness.store.importPlatformConnection(from: file)
        await waitUntil { harness.journal.events.contains("candidate.connect.started") }
        expectExistingProfile(harness)
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        expectExistingProfile(harness)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        #expect(!harness.store.platformConnectionValidationMessage.isEmpty)
        #expect((harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?) == defaultsBefore)
    }

    @Test func successfulImportAuthenticatesBeforeSavingAndInstallsWithoutSecondConnect() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let file = try importFile(harness, principalID: harness.targetIdentity.principalID)
        harness.store.importPlatformConnection(from: file)
        await waitUntil { harness.journal.events.contains("candidate.connect.started") }
        expectExistingProfile(harness)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        #expect(harness.store.identity == harness.targetIdentity)
        #expect(harness.store.connectionReady)
        #expect(harness.defaults.string(forKey: "platform.endpoint") == newEndpoint)
        #expect(harness.defaults.bool(forKey: "platform.enabled"))
        let events = harness.journal.events
        let authenticated = try #require(events.firstIndex(of: "candidate.connect.succeeded"))
        let saved = try #require(events.firstIndex(of: "credential.save.succeeded"))
        #expect(authenticated < saved)
        #expect(await harness.candidate.connectCount == 1)
        #expect(try harness.cache.loadDraft(identity: harness.oldIdentity, projectName: "Synthetic project existing").draft.context == "Unsaved authored context in the existing profile")
        #expect(harness.store.handoff.context.isEmpty)
    }

    @Test func credentialSaveFailureKeepsThePreviousProfileUsable() async throws {
        let harness = try await makeHarness(credentialSaveFails: true)
        defer { harness.cleanup() }
        let defaultsBefore = harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?
        await beginConfiguration(harness)
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        expectExistingProfile(harness)
        #expect(harness.journal.events.contains("candidate.connect.succeeded"))
        #expect(harness.journal.events.contains("credential.save.attempt"))
        #expect(!harness.journal.events.contains("credential.save.succeeded"))
        #expect(!harness.store.platformConnectionValidationMessage.isEmpty)
        #expect((harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?) == defaultsBefore)
    }

    @Test func cancellationRejectsSuccessfulLateResponseWithoutTouchingActiveProfile() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let defaultsBefore = harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?
        await beginConfiguration(harness)
        harness.store.cancelPlatformConnectionValidation()
        #expect(!harness.store.isValidatingPlatformConnection)
        expectExistingProfile(harness)
        await harness.gate.release()
        await waitUntil { harness.journal.events.contains("candidate.connect.succeeded") }
        // Let the awaiting MainActor validation task process the intentionally late response.
        for _ in 0..<5 { await Task.yield() }
        expectExistingProfile(harness)
        #expect(!harness.store.isValidatingPlatformConnection)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        #expect((harness.defaults.persistentDomain(forName: harness.suiteName) as NSDictionary?) == defaultsBefore)
    }

    @Test func corruptDestinationSelectionPreventsCredentialCommit() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let destination = try LocalCache(directory: PlatformCacheNamespace.directory(for: URL(string: newEndpoint)!, in: harness.cache.directory))
        try destination.saveSelection(.init(identity: harness.targetIdentity))
        let selectionFile = try #require(FileManager.default.contentsOfDirectory(at: destination.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("selection-") })
        try Data("broken-json".utf8).write(to: selectionFile)
        await beginConfiguration(harness)
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        expectExistingProfile(harness)
        #expect(!harness.journal.events.contains("credential.save.attempt"))
        #expect(try String(contentsOf: selectionFile, encoding: .utf8) == "broken-json")
    }

    @Test func reconnectRejectsChangedPrincipalWithoutLegacyFallback() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        await beginConfiguration(harness)
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        #expect(harness.store.identity == harness.targetIdentity)
        #expect(harness.defaults.string(forKey: "platform.principal") == harness.targetIdentity.principalID)
        await harness.candidate.changePrincipal(to: "synthetic-unexpected-principal")
        harness.store.checkMCP()
        await waitUntil { !harness.store.isConnecting }
        #expect(!harness.store.connectionReady)
        #expect(!harness.store.supportsScopedSearch)
        #expect(harness.store.identity == harness.targetIdentity)
        #expect(harness.defaults.bool(forKey: "platform.enabled"))
        #expect(harness.defaults.string(forKey: "platform.endpoint") == newEndpoint)
        #expect(harness.store.memoryResults.isEmpty)
    }

    @Test func profileNoticeCommitsOnlyAfterAuthenticationAndSurvivesStoreRestart() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let file = try importFile(harness, principalID: harness.targetIdentity.principalID)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        payload["name"] = "Snapshot de revisão sintético"
        payload["snapshotIsCurrentProduction"] = false
        payload["requiresMacActive"] = true
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        harness.store.importPlatformConnection(from: file)
        await waitUntil { harness.journal.events.contains("candidate.connect.started") }
        #expect(harness.store.platformProfileNotice.isEmpty)
        #expect(harness.defaults.string(forKey: "platform.profileNotice") == nil)
        await harness.gate.release()
        await waitUntil { !harness.store.isValidatingPlatformConnection }
        #expect(harness.store.platformProfileNotice.contains("Snapshot de revisão sintético"))
        #expect(!harness.store.platformProfileNotice.contains(syntheticToken))
        let restarted = WorkspaceStore(service: harness.candidate, cache: harness.cache, defaults: harness.defaults)
        #expect(restarted.platformProfileNotice == harness.store.platformProfileNotice)
    }
}
