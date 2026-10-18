import Foundation
import Testing
@testable import M3DeskCore

final class IdentityPersistenceTests {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let identity = WorkspaceIdentity(tenantID: "org-a", projectID: "project", principalID: "member-a")
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3DeskTests-" + UUID().uuidString)
        suite = "M3DeskTests." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
    }
    deinit {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
    }
    private func draft(_ project: String = "Original", objective: String = "Preservar rascunho") -> HandoffDraft {
        var draft = HandoffDraft(); draft.project = project; draft.objective = objective; return draft
    }
    private func legacy(_ draft: HandoffDraft, key: String? = nil) throws -> Data {
        let data = try JSONEncoder().encode(draft)
        defaults.set(data, forKey: key ?? draft.key)
        return data
    }

    @Test func testVersion020DraftWithoutProviderDecodesWithoutSelectingOne() throws {
        let oldPayload = Data(#"{"destination":"Codex","project":"Catálogo","objective":"Retomar tarefa","context":"Contexto preservado","delta":"Mudança anterior","sources":"Fonte local","pending":"Revisar","version":"local-draft-1","workspaceIdentity":{"tenantID":"org-a","projectID":"project","principalID":"member-a"},"subprojectID":"newsroom"}"#.utf8)
        let oldDraft = try JSONDecoder().decode(HandoffDraft.self, from: oldPayload)
        #expect(oldDraft.executionProviderID == nil)
        #expect(oldDraft.destination == "Codex")
        #expect(oldDraft.objective == "Retomar tarefa")
        #expect(oldDraft.context == "Contexto preservado")
        #expect(oldDraft.workspaceIdentity == identity)
        #expect(oldDraft.subprojectID == "newsroom")
        let roundTrip = try JSONDecoder().decode(HandoffDraft.self, from: JSONEncoder().encode(oldDraft))
        #expect(roundTrip == oldDraft)
        #expect(!oldDraft.preview.contains("Provedor de execução selecionado"))
    }

    @Test func testProviderSelectionPersistsPerNamespaceAndSubprojectAfterRestart() throws {
        let cache = try LocalCache(directory: directory)
        let otherTenant = WorkspaceIdentity(tenantID: "org-b", projectID: identity.projectID, principalID: identity.principalID)
        let otherPrincipal = WorkspaceIdentity(tenantID: identity.tenantID, projectID: identity.projectID, principalID: "member-b")
        var primary = draft("Catálogo"); primary.executionProviderID = "provider-a"
        var secondary = draft("Catálogo"); secondary.executionProviderID = "provider-b"
        var subproject = draft("Catálogo"); subproject.executionProviderID = "provider-subproject"
        try cache.saveDraft(primary, identity: identity)
        try cache.saveDraft(secondary, identity: otherTenant)
        try cache.saveDraft(draft("Catálogo"), identity: otherPrincipal)
        try cache.saveDraft(subproject, identity: identity, subprojectID: "newsroom")
        let reopened = try LocalCache(directory: directory)
        #expect(try reopened.loadDraft(identity: identity, projectName: "Catálogo", legacyDefaults: defaults).draft.executionProviderID == "provider-a")
        #expect(try reopened.loadDraft(identity: otherTenant, projectName: "Catálogo", legacyDefaults: defaults).draft.executionProviderID == "provider-b")
        #expect(try reopened.loadDraft(identity: otherPrincipal, projectName: "Catálogo", legacyDefaults: defaults).draft.executionProviderID == nil)
        #expect(try reopened.loadDraft(identity: identity, projectName: "Catálogo", subprojectID: "newsroom", legacyDefaults: defaults).draft.executionProviderID == "provider-subproject")
    }

    @Test func testSameObjectiveDifferentProviderHasDistinctPersistentOperationKeys() throws {
        let cache = try LocalCache(directory: directory)
        let objective = "Mesmo objetivo sintético"
        let fingerprintA = try PendingRunOperation.fingerprint(["objective": .string(objective), "provider": "provider-a"])
        let fingerprintB = try PendingRunOperation.fingerprint(["objective": .string(objective), "provider": "provider-b"])
        let operationA = try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprintA)
        let operationB = try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprintB)
        #expect(fingerprintA != fingerprintB)
        #expect(operationA.idempotencyKey != operationB.idempotencyKey)
        let reopened = try LocalCache(directory: directory)
        #expect(try reopened.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprintA) == operationA)
        #expect(try reopened.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprintB) == operationB)
        #expect(try reopened.pendingRunOperations(identity: identity).count == 2)
    }

    @Test func testSelectedProviderAppearsInLocalExportWithoutClaimingExecution() throws {
        var selected = draft(); selected.executionProviderID = "codex-approved"
        #expect(selected.preview.contains("Provedor de execução selecionado (ID): codex-approved"))
        #expect(selected.preview.contains("Estado: rascunho local; não enviado."))
        _ = try LocalCache(directory: directory)
        let url = directory.appendingPathComponent("handoff.md")
        try HandoffExporter.write(selected, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == selected.preview)
        let roundTrip = try JSONDecoder().decode(HandoffDraft.self, from: JSONEncoder().encode(selected))
        #expect(roundTrip.executionProviderID == "codex-approved")
        #expect(roundTrip == selected)
    }

    @Test func testNamespaceSeparatesTenantPrincipalProjectAndSubprojectIncludingSeparators() throws {
        let cache = try LocalCache(directory: directory)
        let identities = [identity, .init(tenantID: "org-b", projectID: "project", principalID: "member-a"), .init(tenantID: "org-a", projectID: "project", principalID: "member-b"), .init(tenantID: "org-a", projectID: "project/child", principalID: "member-a")]
        for (index, value) in identities.enumerated() { try cache.saveDraft(draft(objective: "draft-\(index)"), identity: value) }
        try cache.saveDraft(draft(objective: "subproject"), identity: identity, subprojectID: "project/child")
        for (index, value) in identities.enumerated() { #expect((try cache.loadDraft(identity: value, projectName: "Renamed", legacyDefaults: defaults).draft.objective) == ("draft-\(index)")) }
        #expect((try cache.loadDraft(identity: identity, projectName: "Renamed", subprojectID: "project/child", legacyDefaults: defaults).draft.objective) == ("subproject"))
        #expect((WorkspaceIdentity(tenantID: "a/b", projectID: "c", principalID: "d").storageKey) != (WorkspaceIdentity(tenantID: "a", projectID: "b/c", principalID: "d").storageKey))
    }

    @Test func testAcceptanceCatalogDraftsSameNameAndPrincipalRemainDistinct() throws {
        let cache = try LocalCache(directory: directory)
        let mare = WorkspaceIdentity(tenantID: "t_mare", projectID: "p_mare_catalogo", principalID: "u_duplo")
        let cedro = WorkspaceIdentity(tenantID: "t_cedro", projectID: "p_cedro_catalogo", principalID: "u_duplo")
        try cache.saveDraft(draft("Catálogo", objective: "Revisar a janela de Maré às 04:15 UTC."), identity: mare)
        try cache.saveDraft(draft("Catálogo", objective: "Revisar a janela de Cedro às 01:20 UTC."), identity: cedro)
        let reopened = try LocalCache(directory: directory)
        #expect(try reopened.loadDraft(identity: mare, projectName: "Catálogo", legacyDefaults: defaults).draft.objective == "Revisar a janela de Maré às 04:15 UTC.")
        #expect(try reopened.loadDraft(identity: cedro, projectName: "Catálogo", legacyDefaults: defaults).draft.objective == "Revisar a janela de Cedro às 01:20 UTC.")
    }

    @Test func testLegacyMigrationPreservesOriginalAndCannotAutoAssignTwice() throws {
        let cache = try LocalCache(directory: directory)
        let old = draft("Original")
        let data = try legacy(old)
        let result = try cache.loadDraft(identity: identity, projectName: "Renamed", legacyProjectNames: ["Original"], legacyDefaults: defaults)
        #expect((result.notices) == ([.migratedLegacy]))
        #expect((result.draft.objective) == (old.objective))
        #expect((result.draft.workspaceIdentity) == (identity))
        #expect((defaults.data(forKey: old.key)) == (data))
        let other = WorkspaceIdentity(tenantID: "another-org", projectID: identity.projectID, principalID: identity.principalID)
        let second = try cache.loadDraft(identity: other, projectName: "Original", legacyProjectNames: ["Original"], legacyDefaults: defaults)
        #expect((second.notices) == ([.legacyAlreadyAssigned]))
        #expect(second.draft.objective.isEmpty)
    }

    @Test func testLegacyKeyCollisionNeverSilentlyCopiesForeignDraft() throws {
        let cache = try LocalCache(directory: directory)
        let old = draft("a-b")
        let data = try legacy(old)
        let result = try cache.loadDraft(identity: identity, projectName: "a/b", legacyProjectNames: ["a/b"], legacyDefaults: defaults)
        #expect((result.notices) == ([.legacyCollision]))
        #expect(result.draft.objective.isEmpty)
        #expect((defaults.data(forKey: old.key)) == (data))
        #expect(!(FileManager.default.fileExists(atPath: cache.draftURL(identity: identity).path)))
    }

    @Test func testAmbiguousOrCorruptLegacyRequiresExplicitRecovery() throws {
        let cache = try LocalCache(directory: directory)
        _ = try legacy(draft("Old A")); _ = try legacy(draft("Old B"))
        let ambiguous = try cache.loadDraft(identity: identity, projectName: "New", legacyProjectNames: ["Old A", "Old B"], legacyDefaults: defaults)
        #expect((ambiguous.notices) == ([.ambiguousLegacy]))
        defaults.set(Data("broken".utf8), forKey: "handoff.Corrupt")
        let corrupt = try cache.loadDraft(identity: identity, projectName: "New", legacyProjectNames: ["Old A", "Corrupt"], legacyDefaults: defaults)
        #expect((corrupt.notices) == ([.legacyCorrupt]))
        #expect(corrupt.draft.objective.isEmpty)
        #expect((try cache.recoveryCandidates(defaults: defaults).count) == (3))
    }

    @Test func testExplicitRecoveryRejectsChangedSourceAndOccupiedDestination() throws {
        let cache = try LocalCache(directory: directory)
        _ = try legacy(draft("Old"))
        let candidate = try #require(cache.recoveryCandidates(defaults: defaults).first)
        _ = try legacy(draft("Old", objective: "changed"))
        expectFailure(try cache.recoverLegacy(candidate, identity: identity, defaults: defaults)) { #expect(($0 as? LocalStorageError) == (.legacySourceChanged)) }
        let freshCandidate = try #require(cache.recoveryCandidates(defaults: defaults).first)
        let recovered = try cache.recoverLegacy(freshCandidate, identity: identity, defaults: defaults)
        #expect((recovered.objective) == ("changed"))
        expectFailure(try cache.recoverLegacy(freshCandidate, identity: identity, defaults: defaults)) { #expect(($0 as? LocalStorageError) == (.destinationOccupied)) }
    }

    @Test func testCorruptDestinationIsPreservedOnLoadAndSave() throws {
        let cache = try LocalCache(directory: directory)
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: cache.draftURL(identity: identity))
        expectFailure(try cache.loadDraft(identity: identity, projectName: "Original", legacyDefaults: defaults))
        expectFailure(try cache.saveDraft(draft(), identity: identity))
        #expect((try Data(contentsOf: cache.draftURL(identity: identity))) == (bytes))
    }

    @Test func testForeignDraftCannotOverwriteCurrentNamespace() throws {
        let cache = try LocalCache(directory: directory)
        var foreign = draft(); foreign.workspaceIdentity = .init(tenantID: "other", projectID: "project", principalID: "member-a")
        expectFailure(try cache.saveDraft(foreign, identity: identity)) { #expect(($0 as? LocalStorageError) == (.namespaceMismatch)) }
    }

    @Test func testSelectionPersistsPerPrincipalAcrossRestart() throws {
        let cache = try LocalCache(directory: directory)
        try cache.saveSelection(.init(identity: identity, subprojectID: "newsroom"))
        let reopened = try LocalCache(directory: directory)
        #expect((try reopened.loadSelection(principalID: identity.principalID)) == (.init(identity: identity, subprojectID: "newsroom")))
        #expect((try reopened.loadSelection(principalID: "another-member")) == nil)
    }

    @Test func testRunCursorIsMonotonicAndDiscoverablePerIdentityAfterRestart() throws {
        let cache = try LocalCache(directory: directory)
        let latest = LocalRunCursor(identity: identity, runID: "run", cursor: "opaque-20", lastEventSequence: 20)
        try cache.saveRunCursor(latest)
        try cache.saveRunCursor(.init(identity: identity, runID: "run", cursor: "opaque-10", lastEventSequence: 10))
        try cache.saveRunCursor(.init(identity: identity, runID: "run", cursor: nil, lastEventSequence: nil))
        try cache.saveRunCursor(.init(identity: identity, runID: "run", cursor: "foreign-equal", lastEventSequence: 20))
        let reopened = try LocalCache(directory: directory)
        #expect((try reopened.loadRunCursor(identity: identity, runID: "run")) == (latest))
        #expect((try reopened.listRunCursors(identity: identity)) == ([latest]))
        #expect(try reopened.listRunCursors(identity: .init(tenantID: "other", projectID: "project", principalID: "member-a")).isEmpty)
        try cache.saveRunCursor(.init(identity: identity, runID: "run", cursor: "opaque-21", lastEventSequence: 21))
        #expect((try reopened.loadRunCursor(identity: identity, runID: "run")?.lastEventSequence) == (21))
    }

    @Test func testOldCursorFilenameRemainsReadableAndListed() throws {
        let cache = try LocalCache(directory: directory)
        let old = LocalRunCursor(identity: identity, runID: "legacy", cursor: "5", lastEventSequence: 5)
        struct Envelope: Encodable { let schemaVersion = 1; let cursor: LocalRunCursor }
        let path = directory.appendingPathComponent("cursor-" + stableStorageKey([identity.storageKey, old.runID]) + ".json")
        try JSONEncoder().encode(Envelope(cursor: old)).write(to: path)
        #expect((try cache.loadRunCursor(identity: identity, runID: old.runID)) == (old))
        #expect((try cache.listRunCursors(identity: identity)) == ([old]))
    }

    @Test func testPendingOperationsReuseKeyAfterRestartAndOnlyStoreFingerprint() throws {
        let payload: JSONValue = ["objective": "private objective text", "agent_id": "agent-1", "checkpoint": "v7"]
        let fingerprint = try PendingRunOperation.fingerprint(payload)
        let first = try LocalCache(directory: directory).beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprint)
        let reopened = try LocalCache(directory: directory)
        let retry = try reopened.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprint)
        #expect((first) == (retry))
        #expect((try reopened.pendingRunOperations(identity: identity)) == ([first]))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!(text.contains("private objective text")))
        #expect(text.contains(first.idempotencyKey))
    }

    @Test func testPendingOperationNamespacesLogicalPayloadAndCompletion() throws {
        let cache = try LocalCache(directory: directory)
        let a = try PendingRunOperation.fingerprint(["objective": "a", "agent_id": "one"])
        let b = try PendingRunOperation.fingerprint(["agent_id": "two", "objective": "a"])
        let first = try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: a)
        let different = try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: b)
        let resume = try cache.beginRunOperation(identity: identity, kind: .resume, payloadFingerprint: a, runID: "run")
        #expect((first.idempotencyKey) != (different.idempotencyKey))
        #expect((first.idempotencyKey) != (resume.idempotencyKey))
        #expect((try cache.pendingRunOperations(identity: identity).count) == (3))
        try cache.completeRunOperation(first)
        let newIntent = try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: a)
        #expect((first.idempotencyKey) != (newIntent.idempotencyKey))
        expectFailure(try cache.completeRunOperation(first)) { #expect(($0 as? LocalStorageError) == (.namespaceMismatch)) }
        #expect((try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: a)) == (newIntent))
        expectFailure(try cache.beginRunOperation(identity: identity, kind: .resume, payloadFingerprint: a))
        expectFailure(try cache.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: "invalid"))
    }

    @Test func testPayloadFingerprintIsCanonicalForDictionaryOrder() throws {
        #expect((try PendingRunOperation.fingerprint(["b": 2, "a": 1])) == (try PendingRunOperation.fingerprint(["a": 1, "b": 2])))
        #expect((try PendingRunOperation.fingerprint(["a": "1"])) != (try PendingRunOperation.fingerprint(["a": 1])))
    }

    @Test func testRegistryRequiresValidNamespaceAndExplicitMembership() throws {
        let registry = LocalRegistry(tenants: [.init(id: "org-a", name: "A", kind: .organization)], projects: [.init(id: "project", name: "P", detail: "", tenantID: "org-a")], principalID: "member-a")
        try registry.validate()
        #expect(registry.contains(identity))
        #expect(!(registry.contains(identity, subprojectID: "missing")))
        #expect(!(registry.contains(.init(tenantID: "org-a", projectID: "project", principalID: "stranger"))))
        var invalid = registry; invalid.projects.append(registry.projects[0])
        expectFailure(try invalid.validate())
        invalid = registry; invalid.projects = [.init(id: "project", name: "P", detail: "", tenantID: "missing")]
        expectFailure(try invalid.validate())
    }

    @Test func testHandoffPreviewIsLocalAndIncludesExplicitIdentity() throws {
        var value = draft(); value.workspaceIdentity = identity
        #expect(value.preview.contains("rascunho local; não enviado"))
        #expect(value.preview.contains("org-a / project"))
        #expect(value.preview.contains("member-a"))
    }
}
