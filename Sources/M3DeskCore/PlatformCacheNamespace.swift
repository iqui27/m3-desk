import Foundation

/// Storage origin is independent from API identity: cloned databases may reuse every ID.
public enum PlatformCacheNamespace {
    public static func directory(for endpoint: URL, in base: URL) throws -> URL {
        try PlatformDeskService.validateEndpoint(endpoint)
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased(), let scheme = parts.scheme?.lowercased() else { throw PlatformClientError.invalidEndpoint }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        let path = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = stableStorageKey([scheme, host, String(port), path])
        return base.appendingPathComponent("Platform-v1", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }
}
