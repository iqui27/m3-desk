import Foundation
import Testing
@testable import M3DeskCore

struct PlatformCacheNamespaceTests {
    @Test func clonedIdentityOnTwoServerOriginsCannotShareDraftsCursorsOrPendingKeys() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let prod = try LocalCache(directory: PlatformCacheNamespace.directory(for: URL(string: "https://prod.example/api")!, in: base))
        let test = try LocalCache(directory: PlatformCacheNamespace.directory(for: URL(string: "https://test.example/api")!, in: base))
        let identity = WorkspaceIdentity(tenantID: "same-tenant", projectID: "same-project", principalID: "same-principal")
        var draft = HandoffDraft(); draft.project = "Catálogo"; draft.context = "Production authored draft"
        try prod.saveDraft(draft, identity: identity)
        try prod.saveRunCursor(.init(identity: identity, runID: "same-run", lastEventSequence: 42))
        let fingerprint = try PendingRunOperation.fingerprint(.object(["objective": .string("task")]))
        let first = try prod.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprint)
        let second = try test.beginRunOperation(identity: identity, kind: .create, payloadFingerprint: fingerprint)
        #expect(try test.loadDraft(identity: identity, projectName: "Catálogo").draft.context.isEmpty)
        #expect(try test.loadRunCursor(identity: identity, runID: "same-run") == nil)
        #expect(first.idempotencyKey != second.idempotencyKey)
    }
    @Test func canonicalOriginKeepsPortsAndBasePathsSeparate() throws {
        let base = URL(fileURLWithPath: "/tmp/test-cache-origin")
        func key(_ string: String) throws -> URL { try PlatformCacheNamespace.directory(for: URL(string: string)!, in: base) }
        #expect(try key("https://EXAMPLE.com/api/") == key("https://example.com:443/api"))
        #expect(try key("http://127.0.0.1:19001") != key("http://127.0.0.1:19002"))
        #expect(try key("https://example.com/api//instance") != key("https://example.com/api/instance"))
        #expect(try key("https://example.com/api-a") != key("https://example.com/api-b"))
        #expect(throws: PlatformClientError.invalidEndpoint) { try key("https://token@example.com") }
    }
}
