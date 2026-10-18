import Foundation
import Darwin
import CoreFoundation

/// One explicitly selected folder and server-authorized project, never inferred from names.
public struct WorkspaceAttachment: Codable, Equatable, Sendable {
    public let root: String
    public let baseURL: String
    public let tenant: String
    public let project: String
    public let bearerEnvironment: String
    public let cloudflareIDEnvironment: String?
    public let cloudflareSecretEnvironment: String?

    enum CodingKeys: String, CodingKey {
        case root, tenant, project
        case baseURL = "base_url", bearerEnvironment = "bearer_env"
        case cloudflareIDEnvironment = "cf_client_id_env", cloudflareSecretEnvironment = "cf_client_secret_env"
    }

    public init(folder: URL, baseURL: URL, tenant: String, project: String,
                bearerEnvironment: String = "M3_PLATFORM_DESK_BEARER",
                cloudflareIDEnvironment: String? = nil, cloudflareSecretEnvironment: String? = nil) throws {
        guard folder.isFileURL else { throw AttachmentError.invalidFolder }
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), directory.boolValue else { throw AttachmentError.invalidFolder }
        try PlatformDeskService.validateEndpoint(baseURL)
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil,
              parts.scheme?.lowercased() == "https" || ["127.0.0.1", "[::1]", "::1"].contains(parts.host?.lowercased() ?? "") else { throw AttachmentError.invalidEndpoint }
        func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex }
        guard matches(tenant, "^[A-Za-z0-9_-]{1,128}$"), matches(project, "^[A-Za-z0-9_-]{1,128}$"),
              matches(bearerEnvironment, "^[A-Za-z_][A-Za-z0-9_]*$"),
              [cloudflareIDEnvironment, cloudflareSecretEnvironment].compactMap({ $0 }).allSatisfy({ matches($0, "^[A-Za-z_][A-Za-z0-9_]*$") }),
              (cloudflareIDEnvironment == nil) == (cloudflareSecretEnvironment == nil) else { throw AttachmentError.invalidReference }
        if baseURL.scheme?.lowercased() == "https", cloudflareIDEnvironment == nil { throw AttachmentError.cloudflareRequired }
        self.root = canonical.path
        self.baseURL = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        self.tenant = tenant; self.project = project; self.bearerEnvironment = bearerEnvironment
        self.cloudflareIDEnvironment = cloudflareIDEnvironment; self.cloudflareSecretEnvironment = cloudflareSecretEnvironment
    }
}

public enum AttachmentError: LocalizedError {
    case invalidFolder, invalidEndpoint, invalidReference, cloudflareRequired, unsafeFile, invalidMapping, alreadyAttached, writeFailed, launcherMismatch
    public var errorDescription: String? {
        switch self {
        case .launcherMismatch: "O inicializador global não está configurado para este endereço. Atualize a configuração privada do inicializador antes de vincular a pasta."
        case .invalidFolder: "Selecione uma pasta local existente."
        case .invalidEndpoint: "O endereço deve ser a origem da Platform, sem caminho adicional."
        case .invalidReference: "IDs ou referências de ambiente inválidos. Informe apenas nomes de variáveis, nunca tokens."
        case .cloudflareRequired: "O acesso remoto precisa das duas referências Cloudflare Access."
        case .unsafeFile: "Mapa privado inseguro ou inacessível. Nenhum vínculo foi alterado."
        case .invalidMapping: "O mapa existente tem formato inválido. Nenhum vínculo foi alterado."
        case .alreadyAttached: "Esta pasta já possui outro vínculo. A troca automática foi recusada."
        case .writeFailed: "Não foi possível salvar o vínculo com segurança."
        }
    }
}

/// Only metadata is persisted. This does not provision credentials or prove an agent connection.
public enum WorkspaceAttachmentFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/m3-platform-bridge/mapping.json")
    }
    private static func origin(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              ["http", "https"].contains(scheme), parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil else { return nil }
        return "\(scheme)://\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))"
    }

    private static func validateBinding(_ file: URL, attachment: WorkspaceAttachment) throws {
        guard attachment.bearerEnvironment == "M3_PLATFORM_DESK_BEARER" else { return }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AttachmentError.launcherMismatch }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= 4096 else { throw AttachmentError.launcherMismatch }
        var bytes = [UInt8](repeating: 0, count: 4097), total = 0
        while total < bytes.count {
            let capacity = bytes.count - total
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: total), capacity) }
            if n < 0 { if errno == EINTR { continue }; throw AttachmentError.launcherMismatch }
            if n == 0 { break }; total += n
        }
        guard total <= 4096,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(total))) as? [String: Any],
              Set(object.keys) == ["version", "base_url", "bearer_env"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let base = object["base_url"] as? String, origin(base) != nil, origin(base) == origin(attachment.baseURL),
              object["bearer_env"] as? String == attachment.bearerEnvironment else { throw AttachmentError.launcherMismatch }
    }

    public static func attach(_ attachment: WorkspaceAttachment, to file: URL, bindingFile: URL? = nil) throws {
        // The client registration already owns this directory. Never create or traverse a substituted directory.
        let parent = file.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.standardizedFileURL.path else { throw AttachmentError.unsafeFile }
        var directoryInfo = stat()
        guard lstat(parent.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o022 == 0 else { throw AttachmentError.unsafeFile }
        try validateBinding(bindingFile ?? parent.appendingPathComponent("binding.json"), attachment: attachment)
        let lock = open(parent.appendingPathComponent(".attachment.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw AttachmentError.unsafeFile }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o077 == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AttachmentError.unsafeFile }
        defer { flock(lock, LOCK_UN) }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AttachmentError.unsafeFile }
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0, original.st_mode & S_IFMT == S_IFREG, original.st_uid == getuid(),
              original.st_mode & 0o077 == 0, original.st_size <= 1_048_576 else { throw AttachmentError.unsafeFile }
        var bytes = [UInt8](repeating: 0, count: 1_048_577)
        var count = 0
        while count < bytes.count {
            let capacity = bytes.count - count
            let readCount = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: count), capacity) }
            if readCount < 0 { if errno == EINTR { continue }; throw AttachmentError.unsafeFile }
            if readCount == 0 { break }; count += readCount
        }
        guard count <= 1_048_576 else { throw AttachmentError.invalidMapping }
        let data = Data(bytes.prefix(count))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "workspaces"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let entries = object["workspaces"] as? [[String: Any]] else { throw AttachmentError.invalidMapping }
        let allowed: Set<String> = ["root", "base_url", "tenant", "project", "bearer_env", "cf_client_id_env", "cf_client_secret_env"]
        let required: Set<String> = ["root", "base_url", "tenant", "project", "bearer_env"]
        var roots = Set<String>()
        for entry in entries {
            guard Set(entry.keys).isSubset(of: allowed), required.isSubset(of: Set(entry.keys)), entry.values.allSatisfy({ $0 is String }),
                  let root = entry["root"] as? String, root.hasPrefix("/"),
                  URL(fileURLWithPath: root).standardizedFileURL.path == root,
                  !root.contains("//"), root == "/" || !root.hasSuffix("/"),
                  !root.contains("\0"), roots.insert(root).inserted else { throw AttachmentError.invalidMapping }
        }
        for entry in entries where entry["bearer_env"] as? String == "M3_PLATFORM_DESK_BEARER" && attachment.bearerEnvironment == "M3_PLATFORM_DESK_BEARER" {
            guard let base = entry["base_url"] as? String, origin(base) != nil, origin(base) == origin(attachment.baseURL) else { throw AttachmentError.launcherMismatch }
        }
        let encoded = try JSONEncoder().encode(attachment)
        let next = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        if let existing = entries.first(where: { $0["root"] as? String == attachment.root }) {
            guard NSDictionary(dictionary: existing).isEqual(to: next) else { throw AttachmentError.alreadyAttached }
            return
        }
        let output = try JSONSerialization.data(withJSONObject: ["version": 1, "workspaces": entries + [next]], options: [.prettyPrinted, .sortedKeys])
        let temp = parent.appendingPathComponent(".mapping-\(UUID().uuidString).tmp")
        let writer = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard writer >= 0 else { throw AttachmentError.writeFailed }
        defer { close(writer); unlink(temp.path) }
        var written = 0
        while written < output.count {
            let n = output.withUnsafeBytes { write(writer, $0.baseAddress!.advanced(by: written), output.count - written) }
            if n < 0 { if errno == EINTR { continue }; throw AttachmentError.writeFailed }
            guard n > 0 else { throw AttachmentError.writeFailed }; written += n
        }
        guard fchmod(writer, 0o600) == 0, fsync(writer) == 0 else { throw AttachmentError.writeFailed }
        var latest = stat()
        guard lstat(file.path, &latest) == 0, latest.st_ino == original.st_ino, latest.st_dev == original.st_dev,
              latest.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, latest.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              latest.st_size == original.st_size else { throw AttachmentError.unsafeFile }
        guard rename(temp.path, file.path) == 0 else { throw AttachmentError.writeFailed }
    }
}
