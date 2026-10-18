import CryptoKit
import Foundation

/// A local addressing namespace. These identifiers are not proof of server authorization.
public struct WorkspaceIdentity: Codable, Hashable, Sendable {
    public let tenantID: String
    public let projectID: String
    public let principalID: String

    public init(tenantID: String, projectID: String, principalID: String) {
        self.tenantID = tenantID
        self.projectID = projectID
        self.principalID = principalID
    }

    public func validate() throws {
        guard [tenantID, projectID, principalID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalStorageError.invalidIdentity
        }
    }

    /// Hashes a length-delimited tuple; separators in an identifier cannot alias another tuple.
    public var storageKey: String { stableStorageKey([tenantID, projectID, principalID]) }
}

func stableStorageKey(_ components: [String]) -> String {
    var bytes = Data()
    for component in components {
        let payload = Data(component.utf8)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(payload)
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

public enum LocalStorageError: Error, LocalizedError, Equatable {
    case invalidIdentity
    case invalidRegistry(String)
    case unsupportedVersion(Int)
    case corruptData(String)
    case namespaceMismatch
    case destinationOccupied
    case legacySourceChanged
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "Identidade local incompleta."
        case .invalidRegistry(let reason): "Configuração local inválida: \(reason)"
        case .unsupportedVersion(let version): "Versão local \(version) não suportada; arquivo preservado."
        case .corruptData(let kind): "\(kind) não pôde ser lido; arquivo preservado para recuperação."
        case .namespaceMismatch: "O arquivo pertence a outro contexto; conteúdo preservado."
        case .destinationOccupied: "Já existe um rascunho neste destino; escolha outro subprojeto para recuperar."
        case .legacySourceChanged: "O rascunho antigo mudou ou não corresponde à seleção; original preservado."
        case .io(let operation): "Não foi possível \(operation) no armazenamento local."
        }
    }
}
