import Testing
import Foundation
import Darwin
@testable import M3DeskCore

struct WorkspaceAttachmentTests {
    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let map = folder.appendingPathComponent("mapping.json")
        try Data("{\"version\":1,\"workspaces\":[]}".utf8).write(to: map)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: map.path)
        let binding = folder.appendingPathComponent("binding.json")
        try Data("{\"version\":1,\"base_url\":\"http://127.0.0.1:24886\",\"bearer_env\":\"M3_PLATFORM_DESK_BEARER\"}".utf8).write(to: binding)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binding.path)
        return (folder, map)
    }
    private func entry(_ folder: URL, project: String = "p") throws -> WorkspaceAttachment {
        try .init(folder: folder, baseURL: URL(string: "http://127.0.0.1:24886")!, tenant: "t", project: project)
    }

    @Test func canonicalizesExplicitSymlinkFolderAndPreservesOtherWorkspaces() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let actual = folder.appendingPathComponent("actual"), alias = folder.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let first = try entry(folder)
        try WorkspaceAttachmentFile.attach(first, to: map)
        let linked = try entry(alias, project: "other")
        #expect(linked.root == actual.resolvingSymlinksInPath().path)
        try WorkspaceAttachmentFile.attach(linked, to: map)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: map)) as? [String: Any])
        let entries = try #require(object["workspaces"] as? [[String: String]])
        #expect(entries.count == 2)
        #expect(entries[0]["project"] == "p")
        #expect(entries[1]["root"] == linked.root)
        #expect(try FileManager.default.attributesOfItem(atPath: map.path)[.posixPermissions] as? Int == 0o600)
        #expect(!String(decoding: try Data(contentsOf: map), as: UTF8.self).contains("token"))
    }

    @Test func repeatedIdenticalAttachmentIsIdempotentAndReassignmentIsRefused() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try entry(folder)
        try WorkspaceAttachmentFile.attach(first, to: map)
        let before = try Data(contentsOf: map)
        try WorkspaceAttachmentFile.attach(first, to: map)
        #expect(try Data(contentsOf: map) == before)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(entry(folder, project: "different"), to: map) }
        #expect(try Data(contentsOf: map) == before)
    }

    @Test func unsafePermissionsSymlinkAndMalformedMapsAreNeverOverwritten() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let attachment = try entry(folder)
        let before = try Data(contentsOf: map)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: map.path)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(attachment, to: map) }
        #expect(try Data(contentsOf: map) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: map.path)
        let alias = folder.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: map)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(attachment, to: alias) }
        try Data("{\"version\":true,\"workspaces\":[]}".utf8).write(to: map)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(attachment, to: map) }
        #expect(String(decoding: try Data(contentsOf: map), as: UTF8.self).contains("true"))
    }

    @Test func invalidFolderAndRemoteWithoutAccessReferencesAreRefused() throws {
        #expect(throws: AttachmentError.self) { try entry(URL(fileURLWithPath: "/nonexistent-synthetic-workspace")) }
        let (folder, _) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: AttachmentError.self) { try WorkspaceAttachment(folder: folder, baseURL: URL(string: "https://memory.example.invalid")!, tenant: "t", project: "p") }
        #expect(throws: AttachmentError.self) { try WorkspaceAttachment(folder: folder, baseURL: URL(string: "http://127.0.0.1:24886")!, tenant: "t", project: "p", bearerEnvironment: "secret value") }
    }

    @Test func missingUnsafeAndMismatchedLauncherBindingCannotCreateLinks() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let binding = folder.appendingPathComponent("binding.json"), before = try Data(contentsOf: map)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(entry(folder), to: map, bindingFile: folder.appendingPathComponent("missing")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binding.path)
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(entry(folder), to: map) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binding.path)
        let other = try WorkspaceAttachment(folder: folder, baseURL: URL(string: "http://127.0.0.1:12345")!, tenant: "t", project: "p")
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(other, to: map) }
        #expect(try Data(contentsOf: map) == before)
    }

    @Test func conflictingReservedOriginsAndNoncanonicalExistingRootsAreRefused() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var old: [String: String] = ["root": "/old/workspace", "base_url": "http://127.0.0.1:12345", "tenant": "t", "project": "old", "bearer_env": "M3_PLATFORM_DESK_BEARER"]
        func writeMap() throws { try JSONSerialization.data(withJSONObject: ["version": 1, "workspaces": [old]]).write(to: map) }
        try writeMap()
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(entry(folder), to: map) }
        old["base_url"] = "http://127.0.0.1:24886"; old["root"] = "/old/../workspace"
        try writeMap()
        #expect(throws: AttachmentError.self) { try WorkspaceAttachmentFile.attach(entry(folder), to: map) }
    }

    @Test func attachmentReplaceIsAtomicForConcurrentReader() throws {
        let (folder, map) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: map)
        let reader = open(map.path, O_RDONLY)
        defer { close(reader) }
        try WorkspaceAttachmentFile.attach(entry(folder), to: map)
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(reader, &bytes, bytes.count)
        #expect(Data(bytes.prefix(count)) == before)
        #expect(try Data(contentsOf: map) != before)
    }
}
