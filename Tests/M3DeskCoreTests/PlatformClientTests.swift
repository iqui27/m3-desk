import Foundation
import Testing
@testable import M3DeskCore

private actor PlatformTestTransport: PlatformTransport {
    struct Step: Sendable {
        var response: PlatformHTTPResponse
        var delay: TimeInterval = 0
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [PlatformHTTPResponse]) { steps = responses.map { .init(response: $0) } }
    func enqueue(_ response: PlatformHTTPResponse, delay: TimeInterval = 0) { steps.append(.init(response: response, delay: delay)) }
    func send(_ request: URLRequest) async throws -> PlatformHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        if step.delay > 0 { try await Task.sleep(for: .seconds(step.delay)) }
        try Task.checkCancellation()
        return step.response
    }
}

private let platformTestRunID = "00000000-0000-4000-8000-000000000111"
private let platformTestMemoryID = "00000000-0000-4000-8000-000000000222"
private let platformTestIdentity = WorkspaceIdentity(tenantID: "org-a", projectID: "project-a", principalID: "principal-a")
private func platformJSON(_ object: [String: Any], status: Int = 200) -> PlatformHTTPResponse {
    var body = object
    if body["schema_version"] == nil { body["schema_version"] = platformSchemaVersion }
    if (200...299).contains(status), ["items", "run", "runs", "events"].contains(where: { body[$0] != nil }), body["authorized_context"] == nil {
        body["authorized_context"] = ["principal_id": "principal-a", "tenant_id": "org-a", "project_id": "project-a"]
    }
    return .init(statusCode: status, data: try! JSONSerialization.data(withJSONObject: body))
}
private func platformDiscovery(role: String = "editor", execution: Bool = false, search: Bool = true, events: Bool = true, sharing: Bool? = nil, toolExecution: Bool = true, providers: [[String: Any]]? = [["id": "local", "kind": "docker-tool"]]) -> [PlatformHTTPResponse] {
    var capabilities: [String: Any] = ["authorized_registry": true, "search": search,
        "runs": true, "durable_events": events, "agent_execution": execution, "tool_execution": toolExecution, "retrieval_mode": "lexical_pt_simple"]
    if let sharing { capabilities["document_sharing"] = sharing }
    if let providers { capabilities["execution_providers"] = providers }
    return [platformJSON(["service": "m3-platform", "capabilities": capabilities]),
     platformJSON(["principal": ["id": "principal-a"]]),
     platformJSON(["tenants": [["id": "org-a", "name": "Organization A"]],
        "projects": [["id": "project-a", "tenant_id": "org-a", "name": "Project A", "role": role]]])]
}
private func platformRun(project: String = "project-a", id: String = platformTestRunID, provider: String = "local") -> [String: Any] {
    ["id": id, "tenant_id": "org-a", "project_id": project, "objective": "Prepare a review", "status": "queued", "version": 1, "provider": provider]
}
private func platformSearch() -> PlatformHTTPResponse {
    platformJSON(["items": [["id": platformTestMemoryID, "title": "Decision", "content": "Use explicit membership", "type": "decision", "version": 2, "score": 0.8]],
        "retrieval": ["mode": "lexical_pt_simple", "embedding_ms": 0, "retrieval_ms": 4.2]])
}
private func platformEvent(id: Any = 1, runID: String = platformTestRunID, type: String = "queued") -> [String: Any] {
    ["id": id, "run_id": runID, "type": type, "payload": ["version": 1], "created_at": "2026-10-02T12:00:00.123Z"]
}
private func platformSharedMemory() -> [String: Any] {
    ["id": platformTestMemoryID, "title": "Shared decision", "content": "Explicitly granted", "type": "decision", "version": 3,
     "tenant_id": "origin-org", "project_id": "origin-project", "origin": ["tenant_id": "origin-org", "project_id": "origin-project"],
     "access": ["kind": "explicit_grant", "principal_id": "principal-a", "read_only": true]]
}
private func platformClient(_ transport: PlatformTestTransport, timeout: TimeInterval = 1) throws -> PlatformDeskService {
    try PlatformDeskService(baseURL: URL(string: "http://127.0.0.1:18999")!, credentialProvider: { "test-token" },
        transport: transport, timeout: timeout, sleep: { _ in try Task.checkCancellation() })
}
private func platformContext(_ client: PlatformDeskService) async throws -> DeskAccessContext {
    let connection = try await client.connect()
    return try #require(connection.authorizedRegistry?.contexts.first)
}
private func waitForPlatformRequests(_ count: Int, transport: PlatformTestTransport) async throws {
    for _ in 0..<100 {
        if await transport.requests.count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Expected request was never sent")
}

@Suite("Platform v1 contract and authorization")
struct PlatformClientTests {
    @Test func endpointPolicyRejectsCredentialsQueriesAndRemotePlaintext() throws {
        for endpoint in ["http://example.com", "https://name:secret@example.com", "https://example.com?token=x", "https://example.com#fragment", "file:///tmp/api"] {
            #expect(throws: PlatformClientError.invalidEndpoint) { try PlatformDeskService.validateEndpoint(URL(string: endpoint)!) }
        }
        for endpoint in ["http://127.0.0.1:8888", "http://localhost", "http://[::1]:8000", "https://example.com/platform"] {
            try PlatformDeskService.validateEndpoint(URL(string: endpoint)!)
        }
    }

    @Test func discoveryUsesIndividualCredentialAndLocalFreshnessLease() async throws {
        let transport = PlatformTestTransport(platformDiscovery())
        let timestamp = Date(timeIntervalSince1970: 1000)
        let client = try PlatformDeskService(baseURL: URL(string: "https://example.com")!, credentialProvider: { "test-token" }, transport: transport, now: { timestamp })
        let connection = try await client.connect()
        let context = try #require(connection.authorizedRegistry?.contexts.first)
        #expect(context.identity == platformTestIdentity)
        #expect(context.expiresAt == timestamp.addingTimeInterval(300))
        #expect(context.permissions.contains(.runCreate))
        #expect(connection.agentExecution == false)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    @Test func viewerAndRuntimeFlagsCannotGrantWritesOrUnsupportedFeatures() async throws {
        let transport = PlatformTestTransport(platformDiscovery(role: "viewer", search: false, events: false))
        let client = try platformClient(transport)
        let context = try await platformContext(client)
        #expect(context.permissions == [.checkpoint, .runRead])
        var draft = HandoffDraft(); draft.objective = "Forbidden"; draft.workspaceIdentity = context.identity
        do { _ = try await client.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: "key"); Issue.record("viewer wrote") }
        catch let error as DeskServiceError { if case .permissionDenied = error {} else { Issue.record("wrong denial") } }
        let count = await transport.requests.count
        #expect(count == 3)
    }

    @Test func unknownRolesDuplicateTenantAndTraversalIDsAreRejected() async throws {
        var invalid = platformDiscovery(role: "owner")
        for registry in [
            platformJSON(["tenants": [["id": "org-a", "name": "A"], ["id": "org-a", "name": "A"]], "projects": []]),
            platformJSON(["tenants": [["id": "org-a", "name": "A"]], "projects": [["id": "../other", "tenant_id": "org-a", "name": "Other", "role": "admin"]]]),
            invalid[2]
        ] {
            invalid = platformDiscovery(); invalid[2] = registry
            let client = try platformClient(PlatformTestTransport(invalid))
            do { _ = try await client.connect(); Issue.record("invalid registry accepted") }
            catch let error as DeskServiceError { if case .invalidRegistry = error {} else { Issue.record("wrong registry error") } }
        }
    }

    @Test func everySuccessfulEnvelopeRequiresVersion() async throws {
        for index in 0..<3 {
            var responses = platformDiscovery()
            responses[index] = platformJSON(["schema_version": "m3.platform.v2"])
            let client = try platformClient(PlatformTestTransport(responses))
            do { _ = try await client.connect(); Issue.record("wrong contract accepted") }
            catch { #expect(error as? PlatformClientError == .contractMismatch("m3.platform.v2")) }
        }
        let transport = PlatformTestTransport(platformDiscovery() + [platformJSON(["schema_version": "other", "items": []])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        do { _ = try await client.search(query: "query", context: context); Issue.record("wrong response version accepted") }
        catch { #expect(error as? PlatformClientError == .contractMismatch("other")) }
    }

    @Test func forgedIdentityAndExpiryCannotReuseValidContext() async throws {
        let transport = PlatformTestTransport(platformDiscovery())
        let client = try platformClient(transport); let context = try await platformContext(client)
        let forged = DeskAccessContext(identity: context.identity, permissions: context.permissions,
            authorizationRevision: context.authorizationRevision, expiresAt: context.expiresAt.addingTimeInterval(300))
        do { _ = try await client.search(query: "query", context: forged); Issue.record("forged expiry accepted") }
        catch let error as DeskServiceError { if case .permissionDenied = error {} else { Issue.record("wrong denial") } }
        let count = await transport.requests.count
        #expect(count == 3)
    }

    @Test func denialInvalidatesAllLocalLeasesEvenWithMalformedEnvelope() async throws {
        for status in [401, 403] {
            let transport = PlatformTestTransport(platformDiscovery() + [.init(statusCode: status, data: Data("invalid".utf8))])
            let client = try platformClient(transport); let context = try await platformContext(client)
            do { _ = try await client.search(query: "query", context: context); Issue.record("denial accepted") }
            catch { #expect(error as? PlatformClientError == (status == 401 ? .unauthenticated : .forbidden)) }
            do { _ = try await client.search(query: "again", context: context); Issue.record("invalidated lease reused") }
            catch let error as DeskServiceError { if case .permissionDenied = error {} else { Issue.record("wrong denial") } }
            let count = await transport.requests.count
            #expect(count == 4)
        }
    }

    @Test func safeReadRetriesAreBoundedAndSearchKeepsScopedPath() async throws {
        let unavailable = platformJSON(["error": ["code": "unavailable", "message": "busy", "retryable": true]], status: 503)
        let transport = PlatformTestTransport(platformDiscovery() + [unavailable, unavailable, platformSearch()])
        let client = try platformClient(transport); let context = try await platformContext(client)
        let items = try await client.search(query: "with / slash", context: context)
        #expect(items.count == 1)
        #expect(items[0].version == "2")
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests[3].url?.path == "/v1/tenants/org-a/projects/project-a/search")
        let body = try #require(try JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["query", "k"])
    }

    @Test func mutationUsesOnlyContractBodyAndNeverAutomaticallyRetries() async throws {
        let unavailable = platformJSON(["error": ["code": "unavailable", "message": "busy", "retryable": true]], status: 503)
        let transport = PlatformTestTransport(platformDiscovery() + [unavailable])
        let client = try platformClient(transport); let context = try await platformContext(client)
        var draft = HandoffDraft(); draft.objective = "Prepare a review"; draft.context = "Private local handoff"; draft.workspaceIdentity = context.identity
        do { _ = try await client.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: "persisted-key"); Issue.record("server failure ignored") }
        catch { #expect(error as? PlatformClientError == .server(status: 503, code: "unavailable", retryable: true)) }
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == "persisted-key")
        let body = try #require(try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["objective", "provider"])
        #expect(body["provider"] as? String == "local")
    }

    @Test func runIdentityMismatchAndConflictAreTyped() async throws {
        let transport = PlatformTestTransport(platformDiscovery() + [platformJSON(["run": platformRun(project: "other-project")]), platformJSON(["run": platformRun()]),
            platformJSON(["error": ["code": "conflict", "message": "changed", "retryable": false]], status: 409)])
        let client = try platformClient(transport); let context = try await platformContext(client)
        do { _ = try await client.run(id: platformTestRunID, context: context); Issue.record("foreign run accepted") }
        catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("wrong scope error") } }
        do { _ = try await client.resumeRun(id: platformTestRunID, context: context, idempotencyKey: "resume-key"); Issue.record("conflict ignored") }
        catch { #expect(error as? PlatformClientError == .conflict) }
        let requests = await transport.requests
        #expect(requests.last?.url?.path.hasSuffix("/resume") == true)
        #expect(requests.last?.httpBody == nil)
    }

    @Test func checkpointPreservesSourcesWithoutInventingNextActionOrBlockers() async throws {
        let transport = PlatformTestTransport(platformDiscovery() + [platformJSON([
            "items": [["id": platformTestMemoryID, "title": "Decision", "content": "Approved architecture", "type": "decision", "version": 3,
                       "tenant_id": "org-a", "project_id": "project-a"]], "runs": [platformRun()]
        ])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        let checkpoint = try #require(try await client.checkpoint(context: context))
        #expect(checkpoint.identity == context.identity)
        #expect(checkpoint.context == "Decision\nApproved architecture")
        #expect(checkpoint.nextAction.isEmpty)
        #expect(checkpoint.blockers.isEmpty)
        #expect(checkpoint.sources.first?.contains(platformTestMemoryID) == true)
        #expect(checkpoint.sources.first?.contains("versão 3") == true)
    }

    @Test func runLifecycleUsesSameIDAndPreservesVersionWithoutExecutorClaim() async throws {
        var newerRun = platformRun(); newerRun["version"] = 4
        let transport = PlatformTestTransport(platformDiscovery() + [platformJSON(["run": platformRun()], status: 201),
            platformJSON(["runs": [newerRun]]), platformJSON(["run": newerRun]), platformJSON(["run": newerRun]), platformJSON(["run": newerRun])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        var draft = HandoffDraft(); draft.objective = "Prepare a review"; draft.workspaceIdentity = context.identity
        let created = try await client.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: "persisted-key")
        #expect(created.id == platformTestRunID)
        #expect(created.status == "queued")
        let listed = try await client.runs(context: context, after: nil)
        #expect(listed.first?.version == 4)
        let resumed = try await client.resumeRun(id: created.id, context: context, idempotencyKey: "persisted-resume-key")
        let cancelled = try await client.cancelRun(id: created.id, context: context)
        #expect(resumed.id == created.id)
        #expect(cancelled.version == 4)
        let requests = await transport.requests
        #expect(requests[6].url?.path == "/v1/tenants/org-a/projects/project-a/runs/\(platformTestRunID)/resume")
        #expect(requests[6].value(forHTTPHeaderField: "Idempotency-Key") == "persisted-resume-key")
        #expect(requests[7].url?.path.hasSuffix("/cancel") == true)
    }

    @Test func retryBudgetStopsAfterThreeReadAttempts() async throws {
        let unavailable = platformJSON(["error": ["code": "quota_exceeded", "message": "busy", "retryable": true]], status: 429)
        let transport = PlatformTestTransport(platformDiscovery() + [unavailable, unavailable, unavailable, platformSearch()])
        let client = try platformClient(transport); let context = try await platformContext(client)
        do { _ = try await client.search(query: "query", context: context); Issue.record("retry budget exceeded") }
        catch { #expect(error as? PlatformClientError == .server(status: 429, code: "quota_exceeded", retryable: true)) }
        let count = await transport.requests.count
        #expect(count == 6)
    }

    @Test func eventsValidateCursorAndDeduplicateRedelivery() async throws {
        let transport = PlatformTestTransport(platformDiscovery() + [
            platformJSON(["events": [platformEvent()], "next_cursor": 1, "has_more": true]),
            platformJSON(["events": [platformEvent(), platformEvent(), platformEvent(id: "2", type: "running")], "next_cursor": 2, "has_more": false]),
            platformJSON(["events": [], "next_cursor": 1, "has_more": false])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        let first = try await client.events(runID: platformTestRunID, context: context, after: 0, limit: 100)
        #expect(first.events.map(\.id) == ["1"])
        let second = try await client.events(runID: platformTestRunID, context: context, after: first.nextCursor, limit: 100)
        // Re-delivery survives until the caller atomically saves its durable cursor.
        #expect(second.events.map(\.id) == ["1", "2"])
        #expect(second.nextCursor == 2)
        do { _ = try await client.events(runID: platformTestRunID, context: context, after: 2); Issue.record("regressing cursor accepted") }
        catch { #expect(error as? PlatformClientError == .malformedResponse) }
        let requests = await transport.requests
        #expect(requests[4].url?.query == "after=1&limit=100")
    }

    @Test func eventsRejectForeignRunAndInconsistentDuplicate() async throws {
        let transport = PlatformTestTransport(platformDiscovery() + [
            platformJSON(["events": [platformEvent(runID: "other")], "next_cursor": 1, "has_more": false]),
            platformJSON(["events": [platformEvent(), platformEvent(type: "different")], "next_cursor": 1, "has_more": false])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        do { _ = try await client.events(runID: platformTestRunID, context: context, after: 0); Issue.record("foreign event accepted") }
        catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("wrong scope error") } }
        do { _ = try await client.events(runID: platformTestRunID, context: context, after: 0); Issue.record("contradictory event accepted") }
        catch { #expect(error as? PlatformClientError == .malformedResponse) }
    }

    @Test func reconnectDiscardsInflightResponseFromOldLease() async throws {
        let transport = PlatformTestTransport(platformDiscovery())
        let client = try platformClient(transport); let context = try await platformContext(client)
        await transport.enqueue(platformSearch(), delay: 0.1)
        for response in platformDiscovery() { await transport.enqueue(response) }
        let task = Task { try await client.search(query: "old query", context: context) }
        try await waitForPlatformRequests(4, transport: transport)
        _ = try await client.connect()
        do { _ = try await task.value; Issue.record("old response accepted") }
        catch { #expect(error as? PlatformClientError == .connectionChanged) }
    }

    @Test func timeoutAndCancellationStopPendingReads() async throws {
        let transport = PlatformTestTransport([])
        await transport.enqueue(platformDiscovery()[0], delay: 1)
        let client = try platformClient(transport, timeout: 0.02)
        do { _ = try await client.connect(); Issue.record("timeout ignored") }
        catch { #expect(error as? PlatformClientError == .timeout) }
        let connectedTransport = PlatformTestTransport(platformDiscovery())
        let connected = try platformClient(connectedTransport)
        let context = try await platformContext(connected)
        await connectedTransport.enqueue(platformSearch(), delay: 1)
        let task = Task { try await connected.search(query: "cancelled", context: context) }
        try await waitForPlatformRequests(4, transport: connectedTransport)
        task.cancel()
        do { _ = try await task.value; Issue.record("cancellation ignored") }
        catch { #expect(error is CancellationError) }
    }

    @Test func redirectNeverFollowsAnotherEndpoint() async throws {
        let transport = PlatformTestTransport([.init(statusCode: 302, headers: ["Location": "https://other.example"], data: Data())])
        let client = try platformClient(transport)
        do { _ = try await client.connect(); Issue.record("redirect accepted") }
        catch { #expect(error as? PlatformClientError == .redirectDenied) }
        let count = await transport.requests.count
        #expect(count == 1)
    }

    @Test func allScopedOperationsCompareEveryAuthorizedContextField() async throws {
        for field in ["principal_id", "tenant_id", "project_id"] {
            var authorized = ["principal_id": "principal-a", "tenant_id": "org-a", "project_id": "project-a"]
            authorized[field] = "unexpected-scope"
            for operation in 0..<8 {
                // A superset body permits each operation to decode normally before the identity guard.
                let body: [String: Any] = ["authorized_context": authorized, "items": [], "runs": [], "run": platformRun(),
                    "events": [], "next_cursor": 0, "has_more": false,
                    "retrieval": ["mode": "lexical_pt_simple", "embedding_ms": 0, "retrieval_ms": 1]]
                let client = try platformClient(PlatformTestTransport(platformDiscovery(sharing: true) + [platformJSON(body)]))
                let context = try await platformContext(client)
                var draft = HandoffDraft(); draft.objective = "Scoped operation"; draft.workspaceIdentity = context.identity
                do {
                    switch operation {
                    case 0: _ = try await client.search(query: "query", context: context)
                    case 1: _ = try await client.checkpoint(context: context)
                    case 2: _ = try await client.runs(context: context, after: nil)
                    case 3: _ = try await client.run(id: platformTestRunID, context: context)
                    case 4: _ = try await client.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: "key")
                    case 5: _ = try await client.resumeRun(id: platformTestRunID, context: context, idempotencyKey: "key")
                    case 6: _ = try await client.cancelRun(id: platformTestRunID, context: context)
                    default: _ = try await client.events(runID: platformTestRunID, context: context, after: 0)
                    }
                    Issue.record("Mismatched authorized context accepted")
                } catch let error as DeskServiceError {
                    if case .invalidIdentity = error {} else { Issue.record("Wrong context error") }
                }
            }
        }
    }

    @Test func scopedSuccessWithoutAuthorizedContextIsRejected() async throws {
        let raw = try JSONSerialization.data(withJSONObject: ["schema_version": platformSchemaVersion, "runs": []])
        let client = try platformClient(PlatformTestTransport(platformDiscovery() + [.init(statusCode: 200, data: raw)]))
        let context = try await platformContext(client)
        do { _ = try await client.runs(context: context, after: nil); Issue.record("Unbound scoped response accepted") }
        catch { #expect(error as? PlatformClientError == .malformedResponse) }
    }

    @Test func explicitGrantPreservesOriginAndReadOnlyProvenance() async throws {
        let transport = PlatformTestTransport(platformDiscovery(sharing: true) + [
            platformJSON(["items": [platformSharedMemory()], "runs": []]),
            platformJSON(["items": [platformSharedMemory()], "retrieval": ["mode": "lexical_pt_simple_or", "embedding_ms": 0, "retrieval_ms": 1]])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        let checkpoint = try #require(try await client.checkpoint(context: context))
        #expect(checkpoint.identity == context.identity)
        #expect(checkpoint.sources.first?.contains("origin-org/origin-project") == true)
        #expect(checkpoint.sources.first?.contains("somente leitura") == true)
        #expect(checkpoint.sources.first?.contains("org-a/project-a") == false)
        let hits = try await client.search(query: "shared", context: context)
        #expect(hits.first?.source.contains("Compartilhada") == true)
    }

    @Test func foreignMemoryRequiresAdvertisedGrantAndConsistentProvenance() async throws {
        for variant in 0..<10 {
            var item = platformSharedMemory()
            var access: [String: Any] = ["kind": "explicit_grant", "principal_id": "principal-a", "read_only": true]
            switch variant {
            case 0: break // Capability missing, despite an asserted grant.
            case 1: access["principal_id"] = "different-principal"
            case 2: access["read_only"] = false
            case 3: access.removeValue(forKey: "read_only")
            case 4: access["kind"] = "project_membership"
            case 5: access["kind"] = "personal_owner"
            case 6: item["origin"] = ["tenant_id": "other", "project_id": "origin-project"]
            case 7: item.removeValue(forKey: "origin")
            case 8: item.removeValue(forKey: "access")
            default: access["kind"] = "inferred_from_title"
            }
            if variant != 8 { item["access"] = access }
            let transport = PlatformTestTransport(platformDiscovery(sharing: variant == 0 ? nil : true) + [platformJSON(["items": [item], "runs": []])])
            let client = try platformClient(transport); let context = try await platformContext(client)
            do { _ = try await client.checkpoint(context: context); Issue.record("Unproven shared item accepted") }
            catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("Wrong sharing error") } }
            catch { #expect(error as? PlatformClientError == .malformedResponse) }
        }
    }

    @Test func ownMemoryProvenanceStillRequiresMatchingPrincipalAndOrigin() async throws {
        for kind in ["personal_owner", "project_membership"] {
            var item = platformSharedMemory()
            item["tenant_id"] = "org-a"; item["project_id"] = "project-a"
            item["origin"] = ["tenant_id": "org-a", "project_id": "project-a"]
            item["access"] = ["kind": kind, "principal_id": "principal-a"]
            let transport = PlatformTestTransport(platformDiscovery(sharing: true) + [platformJSON(["items": [item], "runs": []])])
            let client = try platformClient(transport); let context = try await platformContext(client)
            let checkpoint = try #require(try await client.checkpoint(context: context))
            #expect(checkpoint.sources.first?.contains("org-a/project-a") == true)
            #expect(checkpoint.sources.first?.contains("Compartilhada") == false)
        }
        var item = platformSharedMemory()
        item["tenant_id"] = "org-a"; item["project_id"] = "project-a"
        item["origin"] = ["tenant_id": "org-a", "project_id": "project-a"]
        item["access"] = ["kind": "project_membership", "principal_id": "someone-else"]
        let client = try platformClient(PlatformTestTransport(platformDiscovery(sharing: true) + [platformJSON(["items": [item], "runs": []])]))
        let context = try await platformContext(client)
        do { _ = try await client.checkpoint(context: context); Issue.record("Wrong access principal accepted") }
        catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("Wrong principal error") } }
    }

    @Test func sharingCapabilityDoesNotPermitForeignRuns() async throws {
        let client = try platformClient(PlatformTestTransport(platformDiscovery(sharing: true) + [platformJSON(["runs": [platformRun(project: "origin-project")]])]))
        let context = try await platformContext(client)
        do { _ = try await client.runs(context: context, after: nil); Issue.record("Shared capability leaked runs") }
        catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("Wrong run scope error") } }
    }

    @Test func sharedResponseFromPreviousSessionCannotSurviveReconnect() async throws {
        let transport = PlatformTestTransport(platformDiscovery(sharing: true))
        let client = try platformClient(transport); let context = try await platformContext(client)
        await transport.enqueue(platformJSON(["items": [platformSharedMemory()], "runs": []]), delay: 0.1)
        for response in platformDiscovery(sharing: true) { await transport.enqueue(response) }
        let task = Task { try await client.checkpoint(context: context) }
        try await waitForPlatformRequests(4, transport: transport)
        _ = try await client.connect()
        do { _ = try await task.value; Issue.record("Stale shared response accepted") }
        catch { #expect(error as? PlatformClientError == .connectionChanged) }
    }

    @Test func providerDiscoveryPreservesMetadataAndGatesEachExecutionKind() async throws {
        let providers: [[String: Any]] = [
            ["id": "local", "kind": "docker-tool"],
            ["id": "local-model", "kind": "text-model", "model": "qwen-fixture", "experimental": true],
            ["id": "future", "kind": "autonomous-future"]]
        for enabled in [false, true] {
            let client = try platformClient(PlatformTestTransport(platformDiscovery(execution: enabled, providers: providers)))
            let connection = try await client.connect()
            #expect(connection.executionProviders.count == 3)
            #expect(connection.executionProviders[0].isSupported)
            #expect(connection.executionProviders[1].isSupported == enabled)
            #expect(connection.executionProviders[1].model == "qwen-fixture")
            #expect(connection.executionProviders[1].experimental)
            #expect(!connection.executionProviders[2].isSupported)
        }
    }

    @Test func absentUnannouncedUnknownAndDisabledProvidersNeverCreateRuns() async throws {
        let variants: [(Bool, Bool, [[String: Any]]?, String)] = [
            (true, true, nil, "local"),
            (true, true, [["id": "local", "kind": "docker-tool"]], "local-model"),
            (true, true, [["id": "future", "kind": "unknown"]], "future"),
            (false, true, [["id": "local-model", "kind": "text-model"]], "local-model"),
            (true, false, [["id": "local", "kind": "docker-tool"]], "local")]
        for (agent, tool, providers, selected) in variants {
            let transport = PlatformTestTransport(platformDiscovery(execution: agent, toolExecution: tool, providers: providers))
            let client = try platformClient(transport); let context = try await platformContext(client)
            var draft = HandoffDraft(); draft.objective = "Explicit selection"; draft.workspaceIdentity = context.identity
            do { _ = try await client.startRun(draft: draft, context: context, providerID: selected, idempotencyKey: "key"); Issue.record("Unavailable provider accepted") }
            catch let error as DeskServiceError { if case .unsupported = error {} else { Issue.record("Wrong provider error") } }
            #expect(await transport.requests.count == 3)
        }
    }

    @Test func providerIDsMustBeUniqueAndValid() async throws {
        for providers in [
            [["id": "local", "kind": "docker-tool"], ["id": "local", "kind": "text-model"]],
            [["id": "../untrusted", "kind": "text-model"]]
        ] {
            let client = try platformClient(PlatformTestTransport(platformDiscovery(execution: true, providers: providers)))
            do { _ = try await client.connect(); Issue.record("Invalid provider registry accepted") }
            catch { #expect(error as? PlatformClientError == .malformedResponse) }
        }
    }

    @Test func selectedProviderAndHistoricalModelOutputArePreservedExactly() async throws {
        let providers: [[String: Any]] = [["id": "local", "kind": "docker-tool"],
            ["id": "local-model", "kind": "text-model", "model": "current-qwen", "experimental": true]]
        var run = platformRun(provider: "local-model")
        run["status"] = "succeeded"
        run["result"] = ["text": "<script>literal result</script>", "model": "previous-small-model", "model_digest": "sha256:fixture"]
        run["checkpoint"] = ["result": ["text": "Literal checkpoint", "model": "previous-small-model"]]
        let transport = PlatformTestTransport(platformDiscovery(execution: true, providers: providers) + [platformJSON(["run": run])])
        let client = try platformClient(transport); let context = try await platformContext(client)
        var draft = HandoffDraft(); draft.objective = "Summarize"; draft.workspaceIdentity = context.identity
        let result = try await client.startRun(draft: draft, context: context, providerID: "local-model", idempotencyKey: "stable-key")
        #expect(result.providerID == "local-model")
        #expect(result.resultText == "<script>literal result</script>")
        #expect(result.checkpointText == "Literal checkpoint")
        #expect(result.resultModel == "previous-small-model")
        #expect(result.resultModelDigest == "sha256:fixture")
        let request = try #require(await transport.requests.last)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["provider"] as? String == "local-model")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
    }

    @Test func oldUnknownAndToolRunsAreNeverRelabeledByCurrentAgentCapability() async throws {
        var old = platformRun(); old.removeValue(forKey: "provider")
        var unknown = platformRun(id: "00000000-0000-4000-8000-000000000333", provider: "former-provider")
        unknown["result"] = ["text": 123, "unrecognized": "data"]
        let tool = platformRun(id: "00000000-0000-4000-8000-000000000444", provider: "local")
        let client = try platformClient(PlatformTestTransport(platformDiscovery(execution: true) + [platformJSON(["runs": [old, unknown, tool]])]))
        let context = try await platformContext(client)
        let runs = try await client.runs(context: context, after: nil)
        #expect(runs[0].providerID == nil)
        #expect(runs[0].providerLabel == "Provider não informado")
        #expect(runs[1].providerLabel.contains("tipo não identificado"))
        #expect(runs[1].resultText == nil)
        #expect(runs[2].providerLabel == "Ferramenta Docker fixa")
        var cached = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(runs[2])) as? [String: Any])
        for key in ["version", "providerID", "resultText", "checkpointText", "resultModel", "resultModelDigest"] { cached.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(DeskRun.self, from: JSONSerialization.data(withJSONObject: cached))
        #expect(restored.providerID == nil)
        #expect(restored.version == 1)
        #expect(restored.resultText == nil)
    }

    @Test func returnedProviderMustMatchSelectedProvider() async throws {
        let providers: [[String: Any]] = [["id": "local-model", "kind": "text-model"]]
        let client = try platformClient(PlatformTestTransport(platformDiscovery(execution: true, providers: providers) + [platformJSON(["run": platformRun(provider: "local")])]))
        let context = try await platformContext(client)
        var draft = HandoffDraft(); draft.objective = "Summarize"; draft.workspaceIdentity = context.identity
        do { _ = try await client.startRun(draft: draft, context: context, providerID: "local-model", idempotencyKey: "key"); Issue.record("Provider substitution accepted") }
        catch let error as DeskServiceError { if case .invalidIdentity = error {} else { Issue.record("Wrong provider mismatch error") } }
    }

    @Test func reconnectRefreshesProviderAvailabilityWithoutRewritingOldRun() async throws {
        let providers: [[String: Any]] = [["id": "local-model", "kind": "text-model"]]
        let transport = PlatformTestTransport(platformDiscovery(execution: true, providers: providers) + [platformJSON(["run": platformRun(provider: "local-model")])] + platformDiscovery(execution: false, providers: providers))
        let client = try platformClient(transport); let context = try await platformContext(client)
        let prior = try await client.run(id: platformTestRunID, context: context)
        let updated = try await client.connect()
        #expect(updated.executionProviders.first?.isSupported == false)
        #expect(prior.providerID == "local-model")
        #expect(prior.providerLabel == "Modelo textual local · experimental")
        let fresh = try #require(updated.authorizedRegistry?.contexts.first)
        var draft = HandoffDraft(); draft.objective = "New request"; draft.workspaceIdentity = fresh.identity
        do { _ = try await client.startRun(draft: draft, context: fresh, providerID: "local-model", idempotencyKey: "key"); Issue.record("Removed provider reused") }
        catch let error as DeskServiceError { if case .unsupported = error {} else { Issue.record("Wrong unavailable error") } }
        #expect(await transport.requests.count == 7)
    }

    @Test func resumeRevalidatesStoredProviderAndRejectsProviderSubstitution() async throws {
        for provider in ["missing", "former-provider", "local"] {
            var run = platformRun(provider: provider)
            if provider == "missing" { run.removeValue(forKey: "provider") }
            let transport = PlatformTestTransport(platformDiscovery() + [platformJSON(["run": run]), platformJSON(["run": platformRun(provider: "local-model")])])
            let client = try platformClient(transport); let context = try await platformContext(client)
            do { _ = try await client.resumeRun(id: platformTestRunID, context: context, idempotencyKey: "resume"); Issue.record("Unsafe resume accepted") }
            catch let error as DeskServiceError {
                switch error {
                case .unsupported: #expect(provider != "local")
                case .invalidIdentity: #expect(provider == "local")
                default: Issue.record("Wrong resume error")
                }
            }
            #expect(await transport.requests.count == (provider == "local" ? 5 : 4))
        }
    }

    @Test func failedModelPreservesProviderAndFailureCodeWithoutRawError() async throws {
        var run = platformRun(provider: "local-model")
        run["status"] = "failed"; run["version"] = 3
        run["error"] = ["code": "provider_timeout", "message": "internal detail must not be retained"]
        let client = try platformClient(PlatformTestTransport(platformDiscovery(execution: true) + [platformJSON(["run": run])]))
        let context = try await platformContext(client)
        let failed = try await client.run(id: platformTestRunID, context: context)
        #expect(failed.providerID == "local-model")
        #expect(failed.status == "failed")
        #expect(failed.version == 3)
        #expect(failed.failureCode == "provider_timeout")
        #expect(failed.resultText == nil)
        let encoded = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        #expect(!encoded.contains("internal detail"))
    }
}
