import Foundation
import Security

/// Tokens remain in Keychain; UserDefaults stores only the opt-in endpoint.
enum PlatformCredentials {
    private static let service = "local.m3desk.mvp.platform"
    static func save(_ token: String, endpoint: URL) throws {
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw CredentialError.invalid }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString]
        let updates: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
    static func load(endpoint: URL) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw CredentialError.keychain(status) }
        return token
    }
    static func remove(endpoint: URL) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
    enum CredentialError: LocalizedError {
        case invalid, keychain(OSStatus)
        var errorDescription: String? {
            switch self { case .invalid: "Informe uma credencial válida da nova API."; case .keychain(let code): "Não foi possível acessar a credencial no Keychain (\(code)). Abra Conexão para configurar." }
        }
    }
}
