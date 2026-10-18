import Darwin
import Foundation

/// A staged connection file. Loading does not validate authorization, activate an endpoint, or save a credential.
struct PlatformConnectionImport {
    let baseURL: URL
    let principalID: String
    let token: String
    let profileNotice: String

    private static let maximumFileBytes = 64 * 1024

    static func load(from fileURL: URL) throws -> PlatformConnectionImport {
        guard fileURL.isFileURL,
              fileURL.host == nil || fileURL.host == "" || fileURL.host?.lowercased() == "localhost",
              fileURL.user == nil, fileURL.password == nil, fileURL.port == nil,
              fileURL.query == nil, fileURL.fragment == nil,
              fileURL.path.hasPrefix("/"), !fileURL.path.utf8.contains(0) else {
            throw ImportError.invalidFile
        }

        // Inspect the opened descriptor rather than checking a path and reopening it. O_NONBLOCK
        // prevents a FIFO from blocking before fstat can reject it; O_NOFOLLOW rejects a final symlink.
        let descriptor = fileURL.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw ImportError.unreadableFile }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else { throw ImportError.unreadableFile }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportError.invalidFile }
        guard attributes.st_size >= 0, attributes.st_size <= Int64(maximumFileBytes) else { throw ImportError.fileTooLarge }

        // Never read an unbounded file. A single extra byte detects growth beyond the limit after fstat.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let requested = min(buffer.count, maximumFileBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ImportError.unreadableFile
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumFileBytes else { throw ImportError.fileTooLarge }
        }

        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw ImportError.invalidFormat }
        guard let rawURL = payload.baseURL, let principalID = payload.principalID, let token = payload.token,
              [rawURL, principalID, token].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ImportError.missingFields
        }
        // Strict absolute URL parsing only. PlatformDeskService owns scheme/origin/security policy.
        guard let baseURL = URL(string: rawURL, encodingInvalidCharacters: false), baseURL.scheme != nil else {
            throw ImportError.invalidURL
        }
        let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            guard name.count <= 160, !name.contains(token),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ImportError.invalidMetadata
            }
        }
        var notices: [String] = []
        if let name, !name.isEmpty { notices.append(name) }
        if payload.snapshotIsCurrentProduction == false {
            notices.append("Snapshot fechado de revisão, sem sincronização contínua. O MCP original continua autoritativo.")
        }
        if payload.requiresMacActive == true {
            notices.append("Inferência neste Mac; mantenha-o ativo para executar o modelo textual.")
        }
        return PlatformConnectionImport(baseURL: baseURL, principalID: principalID, token: token, profileNotice: notices.joined(separator: "\n"))
    }

    // Decode-only and private: the staged public shape intentionally has no encoding or description conformance.
    private struct Payload: Decodable {
        let baseURL: String?
        let principalID: String?
        let token: String?
        let name: String?
        let snapshotIsCurrentProduction: Bool?
        let requiresMacActive: Bool?
        private enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case principalID = "principal_id"
            case token
            case name, snapshotIsCurrentProduction, requiresMacActive
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case invalidFile
        case unreadableFile
        case fileTooLarge
        case invalidFormat
        case missingFields
        case invalidURL
        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Selecione um arquivo regular neste Mac."
            case .unreadableFile: "Não foi possível ler o arquivo de conexão."
            case .fileTooLarge: "O arquivo de conexão deve ter no máximo 64 KiB."
            case .invalidFormat: "O arquivo não contém uma conexão JSON válida."
            case .missingFields: "A conexão precisa de base_url, principal_id e token não vazios."
            case .invalidURL: "O endereço da conexão precisa ser uma URL absoluta válida."
            case .invalidMetadata: "A identificação do perfil precisa ser curta e não conter credenciais ou caracteres de controle."
            }
        }
    }
}
