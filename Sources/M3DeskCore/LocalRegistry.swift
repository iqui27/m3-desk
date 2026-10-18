import Foundation

public struct WorkspaceTenant: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case organization, personal }
    public let id: String
    public var name: String
    public var kind: Kind
    public init(id: String, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }
}

public struct WorkspaceSubproject: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct WorkspaceProject: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var detail: String
    public let tenantID: String
    public var subprojects: [WorkspaceSubproject]
    public init(id: String, name: String, detail: String, tenantID: String, subprojects: [WorkspaceSubproject] = []) {
        self.id = id; self.name = name; self.detail = detail; self.tenantID = tenantID; self.subprojects = subprojects
    }

    private enum CodingKeys: String, CodingKey { case id, name, detail, tenantID, subprojects }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        tenantID = try values.decode(String.self, forKey: .tenantID)
        subprojects = try values.decodeIfPresent([WorkspaceSubproject].self, forKey: .subprojects) ?? []
    }
}

/// Explicit local configuration, never presented as a server registry or membership list.
public struct LocalRegistry: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var tenants: [WorkspaceTenant]
    public var projects: [WorkspaceProject]
    public var principalID: String
    public var sourceLabel: String { "Configuração local · autorização remota não verificada" }

    public init(tenants: [WorkspaceTenant], projects: [WorkspaceProject], principalID: String, schemaVersion: Int = 1) {
        self.tenants = tenants; self.projects = projects; self.principalID = principalID; self.schemaVersion = schemaVersion
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw LocalStorageError.unsupportedVersion(schemaVersion) }
        guard !principalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalStorageError.invalidIdentity }
        guard Set(tenants.map(\.id)).count == tenants.count,
              tenants.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalStorageError.invalidRegistry("organizações com ID vazio ou duplicado")
        }
        var keys = Set<WorkspaceIdentity>()
        for project in projects {
            let identity = WorkspaceIdentity(tenantID: project.tenantID, projectID: project.id, principalID: principalID)
            try identity.validate()
            guard tenants.contains(where: { $0.id == project.tenantID }) else { throw LocalStorageError.invalidRegistry("organização do projeto não encontrada") }
            guard keys.insert(identity).inserted, !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalStorageError.invalidRegistry("projetos com nome vazio ou ID duplicado na mesma organização")
            }
            guard Set(project.subprojects.map(\.id)).count == project.subprojects.count,
                  project.subprojects.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw LocalStorageError.invalidRegistry("subprojetos com ID vazio ou duplicado")
            }
        }
    }

    public func contains(_ identity: WorkspaceIdentity, subprojectID: String? = nil) -> Bool {
        guard identity.principalID == principalID, let project = projects.first(where: { $0.tenantID == identity.tenantID && $0.id == identity.projectID }) else { return false }
        return subprojectID.map { id in project.subprojects.contains { $0.id == id } } ?? true
    }

    public static func load(from url: URL) throws -> LocalRegistry {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LocalStorageError.io("ler a configuração") }
        let registry: LocalRegistry
        do { registry = try JSONDecoder().decode(Self.self, from: data) } catch { throw LocalStorageError.corruptData("A configuração local") }
        try registry.validate()
        return registry
    }

    public func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(self).write(to: url, options: .atomic) } catch { throw LocalStorageError.io("salvar a configuração") }
    }

    public static let builtIn = LocalRegistry(
        tenants: [.init(id: "local-workspace", name: "Projetos locais", kind: .organization), .init(id: "local-personal", name: "Pessoal", kind: .personal)],
        projects: [
            .init(id: "monumenta", name: "Monumenta / BB", detail: "Diário", tenantID: "local-workspace"),
            .init(id: "studionext", name: "StudioNext / OncoTrials", detail: "Sustentação sob demanda", tenantID: "local-workspace"),
            .init(id: "secti", name: "SECTI", detail: "Frente institucional", tenantID: "local-workspace"),
            .init(id: "hinnova", name: "H-INNOVA", detail: "Newsroom · Rota Segura", tenantID: "local-workspace", subprojects: [.init(id: "newsroom", name: "Newsroom"), .init(id: "rota-segura", name: "Rota Segura")]),
            .init(id: "velaris", name: "Velaris / ASSA ABLOY", detail: "Testes aguardando empresa", tenantID: "local-workspace"),
            .init(id: "nuvio", name: "Nuvio", detail: "Hobby", tenantID: "local-workspace")
        ], principalID: "local-user"
    )
}
