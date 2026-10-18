import SwiftUI
import AppKit
import Foundation
import M3DeskCore

@main
struct M3DeskApp: App {
    @StateObject private var store: WorkspaceStore

    init() {
        let arguments = CommandLine.arguments
        let isPreview = arguments.contains("--render-preview")
        if isPreview {
            _store = StateObject(wrappedValue: WorkspaceStore(preview: true))
            PreviewRenderer.run()
            Foundation.exit(0)
        }
        let verificationFlags = ["--verification-profile", "--platform-endpoint", "--credential-file"]
        if arguments.contains(where: { argument in verificationFlags.contains { argument.hasPrefix($0) } }) {
            _store = StateObject(wrappedValue: VerificationLaunch.makeStore(arguments: arguments))
        } else {
            _store = StateObject(wrappedValue: WorkspaceStore())
        }
    }

    var body: some Scene {
        WindowGroup("M3 Desk") {
            ContentView(store: store)
                .tint(.orange)
                .task { store.connectIfNeeded() }
        }
        .defaultSize(width: 1240, height: 810)
        .commands {
            SidebarCommands()
            CommandMenu("Contexto") {
                Button("Preparar contexto") { store.section = .handoff }
                    .keyboardShortcut("K", modifiers: [.command, .shift])
                    .disabled(store.selectedProject == nil)
                Button("Buscar memória") { store.section = .memory }
                    .keyboardShortcut("F", modifiers: [.command])
                Divider()
                Button("Reconectar ao M3") { store.checkMCP() }
                    .disabled(store.isConnecting)
                Button("Conexão…") { store.showConnectionSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Button("Recuperar rascunhos antigos…") {
                    store.refreshRecoveryCandidates()
                    store.showRecovery = true
                }
            }
        }
    }
}

/// Explicit developer launch mode. All persistence is scoped to the supplied profile;
/// configuration failure never opens the user's normal profile or the legacy bridge.
@MainActor
private enum VerificationLaunch {
    private struct CredentialFile: Decodable { let base_url: String?; let token: String }
    private enum ConfigurationError: LocalizedError {
        case invalidArguments, endpointMismatch, invalidCredential
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "A validação exige um perfil absoluto e argumentos sem duplicidade; endereço e arquivo de credencial devem ser fornecidos juntos."
            case .endpointMismatch: "O endereço de validação diverge do endereço autorizado no arquivo de credencial."
            case .invalidCredential: "O arquivo de credencial de validação é inválido ou ilegível."
            }
        }
    }

    static func makeStore(arguments: [String]) -> WorkspaceStore {
        do {
            guard let path = try argument("--verification-profile", in: arguments), path.hasPrefix("/") else { throw ConfigurationError.invalidArguments }
            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let endpoint = try argument("--platform-endpoint", in: arguments)
            let credentialPath = try argument("--credential-file", in: arguments)
            guard (endpoint == nil) == (credentialPath == nil) else { throw ConfigurationError.invalidArguments }
            let service: any DeskService
            if let endpoint, let credentialPath {
                guard credentialPath.hasPrefix("/"), let url = URL(string: endpoint) else { throw ConfigurationError.invalidArguments }
                let file = URL(fileURLWithPath: credentialPath)
                let data: Data
                do { data = try Data(contentsOf: file, options: .mappedIfSafe) }
                catch { throw ConfigurationError.invalidCredential }
                guard data.count <= 65_536, let credential = try? JSONDecoder().decode(CredentialFile.self, from: data) else { throw ConfigurationError.invalidCredential }
                if let expected = credential.base_url {
                    guard URL(string: expected)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw ConfigurationError.endpointMismatch }
                }
                let token = credential.token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { throw ConfigurationError.invalidCredential }
                service = try PlatformDeskService(baseURL: url, token: token)
            } else {
                service = UnavailableDeskService(reason: "Backend de validação não configurado. Nenhuma conexão legada foi iniciada.")
            }
            let cacheDirectory: URL
            if let endpoint, let url = URL(string: endpoint) {
                cacheDirectory = try PlatformCacheNamespace.directory(for: url, in: directory)
            } else { cacheDirectory = directory }
            let cache = try LocalCache(directory: cacheDirectory)
            guard let defaults = UserDefaults(suiteName: "local.m3desk.verification.\(UUID().uuidString)") else { throw ConfigurationError.invalidArguments }
            let store = WorkspaceStore(service: service, cache: cache, defaults: defaults, registry: .builtIn)
            store.platformEndpoint = endpoint ?? ""
            store.verificationNotice = endpoint == nil ? "Validação isolada · perfil local de teste" : "Validação isolada · backend configurado"
            return store
        } catch {
            let store = WorkspaceStore(preview: true, service: UnavailableDeskService(reason: "Configuração de validação inválida."))
            store.verificationNotice = "Validação isolada indisponível · nenhuma conexão iniciada"
            store.storageError = (error as? ConfigurationError)?.errorDescription ?? "Não foi possível abrir a configuração de validação. O perfil normal não foi usado."
            return store
        }
    }

    private static func argument(_ flag: String, in arguments: [String]) throws -> String? {
        let indices = arguments.indices.filter { arguments[$0] == flag || arguments[$0].hasPrefix(flag + "=") }
        guard indices.count <= 1 else { throw ConfigurationError.invalidArguments }
        guard let index = indices.first else { return nil }
        if arguments[index].hasPrefix(flag + "=") {
            let value = String(arguments[index].dropFirst(flag.count + 1))
            guard !value.isEmpty else { throw ConfigurationError.invalidArguments }
            return value
        }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { throw ConfigurationError.invalidArguments }
        return arguments[index + 1]
    }
}
