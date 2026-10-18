import Foundation

public struct HandoffDraft: Codable, Equatable, Sendable {
    public var destination = "Claude · chat"
    /// Explicit local selection; server capabilities and permissions must still authorize execution.
    public var executionProviderID: String?
    public var project = ""
    public var objective = ""
    public var context = ""
    public var delta = ""
    public var sources = ""
    public var pending = ""
    public var version = "local-draft-1"
    public var workspaceIdentity: WorkspaceIdentity?
    public var subprojectID: String?
    public init() {}

    private enum CodingKeys: String, CodingKey { case destination, executionProviderID, project, objective, context, delta, sources, pending, version, workspaceIdentity, subprojectID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        destination = try values.decodeIfPresent(String.self, forKey: .destination) ?? "Claude · chat"
        executionProviderID = try values.decodeIfPresent(String.self, forKey: .executionProviderID)
        project = try values.decodeIfPresent(String.self, forKey: .project) ?? ""
        objective = try values.decodeIfPresent(String.self, forKey: .objective) ?? ""
        context = try values.decodeIfPresent(String.self, forKey: .context) ?? ""
        delta = try values.decodeIfPresent(String.self, forKey: .delta) ?? ""
        sources = try values.decodeIfPresent(String.self, forKey: .sources) ?? ""
        pending = try values.decodeIfPresent(String.self, forKey: .pending) ?? ""
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? "local-draft-1"
        workspaceIdentity = try values.decodeIfPresent(WorkspaceIdentity.self, forKey: .workspaceIdentity)
        subprojectID = try values.decodeIfPresent(String.self, forKey: .subprojectID)
    }

    /// Only for discovering old UserDefaults data; new storage uses WorkspaceIdentity.
    public var key: String { Self.legacyKey(project: project) }
    public static func legacyKey(project: String) -> String { "handoff." + project.replacingOccurrences(of: "/", with: "-") }
    public var preview: String {
        let namespace = workspaceIdentity.map { "\nContexto local: \($0.tenantID) / \($0.projectID)\nPrincipal local: \($0.principalID)" } ?? ""
        let subproject = subprojectID.map { "\nSubprojeto: \($0)" } ?? ""
        let provider = executionProviderID.map { "\nProvedor de execução selecionado (ID): \($0)" } ?? ""
        return "# Handoff · \(destination)\n\nProjeto: \(project)\(namespace)\(subproject)\(provider)\nVersão: \(version)\n\n## Objetivo\n\(objective)\n\n## Contexto mínimo\n\(context)\n\n## Delta\n\(delta)\n\n## Fontes\n\(sources)\n\n## Pendências\n\(pending)\n\nEstado: rascunho local; não enviado."
    }
}

public enum HandoffExporter {
    public static func write(_ draft: HandoffDraft, to url: URL) throws {
        try draft.preview.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Compatibility for old integrations only. Desk uses LocalCache with explicit identities.
@available(*, deprecated, message: "Use LocalCache with WorkspaceIdentity for tenant/principal isolation")
public enum DraftStore {
    private static func compatibilityKey(_ project: String) -> String { "m3desk.compat-draft.v2." + stableStorageKey([project]) }
    @discardableResult
    public static func save(_ draft: HandoffDraft, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(draft) else { return false }
        defaults.set(data, forKey: compatibilityKey(draft.project))
        return defaults.data(forKey: compatibilityKey(draft.project)) == data
    }
    public static func load(project: String, defaults: UserDefaults = .standard) -> HandoffDraft {
        for key in [compatibilityKey(project), HandoffDraft.legacyKey(project: project)] {
            if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(HandoffDraft.self, from: data), saved.project == project { return saved }
        }
        var fresh = HandoffDraft(); fresh.project = project; return fresh
    }
}
