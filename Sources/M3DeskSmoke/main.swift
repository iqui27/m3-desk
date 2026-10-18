import Foundation
import M3DeskCore

@main
struct M3DeskSmoke {
    static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") · \(label)")
            if !condition { failures += 1 }
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m3desk-smoke-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = try LocalCache(directory: directory)
            let a = WorkspaceIdentity(tenantID: "fixture-org-a", projectID: "same-id", principalID: "fixture-user")
            let b = WorkspaceIdentity(tenantID: "fixture-org-b", projectID: "same-id", principalID: "fixture-user")
            var draft = HandoffDraft(); draft.project = "Synthetic smoke"; draft.objective = "Verify local resume"; draft.workspaceIdentity = a
            try cache.saveDraft(draft, identity: a)
            check(try cache.loadDraft(identity: a, projectName: draft.project).draft.objective == draft.objective, "draft retomado no mesmo namespace")
            check(try cache.loadDraft(identity: b, projectName: draft.project).draft.objective.isEmpty, "tenant distinto não recebe draft")
            let url = directory.appendingPathComponent("handoff.md"); try HandoffExporter.write(draft, to: url)
            check(try String(contentsOf: url, encoding: .utf8) == draft.preview, "exportação corresponde à prévia")
            check(draft.preview.contains("rascunho local"), "handoff continua local")
        } catch { print("FAIL · armazenamento local: \(error.localizedDescription)"); failures += 1 }

        if CommandLine.arguments.contains("--live-mcp") {
            do {
                let client = MCPClient(timeout: 15)
                let info = try await client.initialize()
                let tools = try await client.listTools()
                check(!tools.isEmpty, "MCP real initialize/initialized/tools: \(info.name) \(info.version), \(tools.count) ferramentas")
                do { _ = try await client.callReadOnlyTool("memory_write"); check(false, "mutação legada deveria ser recusada") }
                catch { check(true, "mutação fora da allowlist recusada") }
            } catch { print("FAIL · MCP real: \(error.localizedDescription)"); failures += 1 }
        }
        if CommandLine.arguments.contains("--live-platform") {
            do {
                let environment = ProcessInfo.processInfo.environment
                guard let endpoint = environment["M3_PLATFORM_SMOKE_ENDPOINT"].flatMap(URL.init(string:)), let credentialFile = environment["M3_PLATFORM_SMOKE_TOKEN_FILE"] else {
                    throw DeskServiceError.unsupported("Configure endpoint e arquivo privado da credencial de teste.")
                }
                struct ProtectedConnection: Decodable { let base_url: String; let token: String }
                let protected = try JSONDecoder().decode(ProtectedConnection.self, from: Data(contentsOf: URL(fileURLWithPath: credentialFile)))
                guard URL(string: protected.base_url) == endpoint else { throw PlatformClientError.invalidEndpoint }
                let token = protected.token
                let service = try PlatformDeskService(baseURL: endpoint, token: token)
                let connection = try await service.connect()
                guard let authorized = connection.authorizedRegistry, let context = authorized.contexts.first(where: { $0.identity.projectID == "p_mare_catalogo" }) ?? authorized.contexts.first else { throw DeskServiceError.invalidRegistry }
                check(!authorized.registry.projects.isEmpty, "API real: principal/registry autorizado")
                let hits = try await service.search(query: "catálogo", context: context)
                check(!hits.isEmpty, "API real: busca autorizada com conteúdo concluída, \(hits.count) resultado(s); conteúdo omitido")
                do {
                    let checkpoint = try await service.checkpoint(context: context)
                    check(checkpoint != nil, "API real: checkpoint autorizado recuperado")
                    let shared = checkpoint?.sources.filter { $0.hasPrefix("Compartilhada · somente leitura · origem ") }.count ?? 0
                    if CommandLine.arguments.contains("--exercise-fixture-runs") {
                        check(shared > 0, "API real de teste: \(shared) fontes com grant explícito e origem preservada")
                    }
                } catch { print("FAIL · API real: checkpoint: \(error.localizedDescription)"); failures += 1 }
                let runs = try await service.runs(context: context, after: nil)
                check(true, "API real: \(runs.count) run(s) autorizado(s)")
                if CommandLine.arguments.contains("--exercise-fixture-runs") {
                    var draft = HandoffDraft(); draft.objective = "Synthetic M3 Desk smoke: reply with OK. No tools or external actions."; draft.workspaceIdentity = context.identity
                    let key = "desk-smoke-\(UUID().uuidString)"
                    let first = try await service.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: key)
                    let replay = try await service.startRun(draft: draft, context: context, providerID: "local", idempotencyKey: key)
                    check(first.id == replay.id, "API real de teste: replay idempotente retorna mesmo run")
                    let page = try await service.events(runID: first.id, context: context, after: 0, limit: 100)
                    let resumed = try await service.events(runID: first.id, context: context, after: page.nextCursor, limit: 100)
                    check(resumed.nextCursor >= page.nextCursor, "API real de teste: cursor de eventos monotônico após reconexão lógica")
                    let cancelled = try await service.cancelRun(id: first.id, context: context)
                    check(cancelled.id == first.id, "API real de teste: cancelamento consulta mesmo run")
                    let reconnected = try PlatformDeskService(baseURL: endpoint, token: token)
                    let renewed = try await reconnected.connect()
                    guard let renewedContext = renewed.authorizedRegistry?.contexts.first(where: { $0.identity == context.identity }) else { throw DeskServiceError.invalidIdentity }
                    let recovered = try await reconnected.run(id: first.id, context: renewedContext)
                    let incremental = try await reconnected.events(runID: first.id, context: renewedContext, after: page.nextCursor, limit: 100)
                    check(recovered.id == first.id && incremental.nextCursor >= page.nextCursor, "API real de teste: nova conexão recupera mesmo run/cursor")
                    if ["cancelled", "failed"].contains(recovered.status) {
                        let resumedRun = try await reconnected.resumeRun(id: first.id, context: renewedContext, idempotencyKey: key + "-resume")
                        check(resumedRun.id == first.id && resumedRun.version > first.version, "API real de teste: resume conserva ID e avança versão")
                        _ = try await reconnected.cancelRun(id: first.id, context: renewedContext)
                    }
                }
                if CommandLine.arguments.contains("--exercise-local-model") {
                    guard connection.executionProviders.contains(where: { $0.id == "local-model" && $0.isSupported && $0.kind == "text-model" }) else {
                        throw DeskServiceError.unsupported("Provider local-model não anunciado como modelo textual habilitado.")
                    }
                    var modelDraft = HandoffDraft(); modelDraft.objective = "Reply with exactly ACK."; modelDraft.workspaceIdentity = context.identity; modelDraft.executionProviderID = "local-model"
                    let initial: DeskRun
                    let replay: DeskRun
                    if let index = CommandLine.arguments.firstIndex(of: "--resume-local-model-run") {
                        guard CommandLine.arguments.indices.contains(index + 1) else { throw PlatformClientError.invalidRequest }
                        let existingID = CommandLine.arguments[index + 1]
                        let existing = try await service.run(id: existingID, context: context)
                        guard existing.providerID == "local-model", existing.summary == modelDraft.objective else { throw DeskServiceError.invalidIdentity }
                        let key = "desk-model-resume-" + existingID
                        initial = try await service.resumeRun(id: existingID, context: context, idempotencyKey: key)
                        replay = try await service.resumeRun(id: existingID, context: context, idempotencyKey: key)
                        check(initial.id == existingID && initial.providerID == existing.providerID, "LLM real de teste: retomada explícita conserva ID e provider originais")
                    } else {
                        let key = "desk-model-smoke-\(UUID().uuidString)"
                        initial = try await service.startRun(draft: modelDraft, context: context, providerID: "local-model", idempotencyKey: key)
                        replay = try await service.startRun(draft: modelDraft, context: context, providerID: "local-model", idempotencyKey: key)
                    }
                    check(initial.id == replay.id && replay.providerID == "local-model", "LLM real de teste: replay conserva run e provider escolhido")
                    var latest = replay
                    for _ in 0..<45 {
                        if ["succeeded", "failed", "cancelled"].contains(latest.status) { break }
                        try await Task.sleep(for: .seconds(1))
                        latest = try await service.run(id: initial.id, context: context)
                    }
                    check(latest.status == "succeeded" && latest.providerID == "local-model" && latest.resultText?.isEmpty == false, "LLM real de teste: resultado textual não vazio em run succeeded")
                    let events = try await service.events(runID: initial.id, context: context, after: 0, limit: 100)
                    check(events.events.contains { $0.type == "run.succeeded" } && events.nextCursor > 0, "LLM real de teste: conclusão registrada em eventos duráveis")
                    let fresh = try PlatformDeskService(baseURL: endpoint, token: token)
                    let renewed = try await fresh.connect()
                    guard let refreshed = renewed.authorizedRegistry?.contexts.first(where: { $0.identity == context.identity }) else { throw DeskServiceError.invalidIdentity }
                    let recovered = try await fresh.run(id: initial.id, context: refreshed)
                    check(recovered.providerID == latest.providerID && recovered.resultText == latest.resultText, "LLM real de teste: reconexão preserva provider e resultado")
                    let priorTools = runs.filter { $0.providerID == "local" }
                    check(!priorTools.isEmpty && priorTools.allSatisfy { $0.providerLabel.contains("Ferramenta") }, "Histórico local permanece ferramenta com capability global de modelo ativa")
                    print("INFO · run local-model: \(initial.id); objetivo sintético transmitido: Reply with exactly ACK.; estado: \(latest.status); falha: \(latest.failureCode ?? "nenhuma"); resultado: \(latest.resultText ?? "ausente"); modelo retornado: \(latest.resultModel ?? "não informado")")
                }
                print("INFO · agent_execution anunciado: \(connection.agentExecution); ferramenta e modelo são identificados pelo provider de cada run")
            } catch { print("FAIL · Platform real: \(error.localizedDescription)"); failures += 1 }
        }
        print(failures == 0 ? "SMOKE PASS" : "SMOKE FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
