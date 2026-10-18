import Testing
import Foundation
@testable import M3Desk
import M3DeskCore

@MainActor struct WorkspaceAttachmentEligibilityTests {
    @Test func disconnectedAndExpiredRegistryCannotAttachFolders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "attachment-store-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledDeskService()
        await service.setLifetime(0.3)
        let store = WorkspaceStore(service: UnavailableDeskService(reason: "synthetic"), cache: try LocalCache(directory: folder), defaults: defaults,
            registry: .builtIn, platformServiceFactory: { _, _ in service }, loadPlatformCredential: { _ in "synthetic" }, savePlatformCredential: { _, _ in })
        #expect(store.attachmentProject == nil)
        store.platformEndpoint = "http://127.0.0.1:24886"
        store.platformCredential = "synthetic"
        store.configurePlatform()
        for _ in 0..<100 { if store.connectionReady { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.connectionReady)
        #expect(store.attachmentProject != nil)
        store.platformEndpoint = "http://127.0.0.1:12345" // Unsaved edits must not change the active attachment origin.
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.attachmentProject == nil)
        #expect(store.connectionState.contains("expirado"))
        if let project = store.selectedProject {
            #expect(throws: DeskServiceError.self) { try store.attachWorkspace(folder: folder, project: project) }
        }
    }
}
