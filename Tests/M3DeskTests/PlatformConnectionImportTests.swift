import Darwin
import Foundation
import Testing
@testable import M3Desk

struct PlatformConnectionImportTests {
    private let syntheticToken = "synthetic-test-token-not-a-credential"

    private func encodedConnection() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "base_url": "http://127.0.0.1:18123/api",
            "principal_id": "fixture-principal",
            "token": syntheticToken
        ])
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desk-connection-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("connection.json")
            try data.write(to: file)
            try body(file)
        }
    }

    @Test func validFilePreservesAllConnectionFields() throws {
        try withFile(encodedConnection()) { file in
            let connection = try PlatformConnectionImport.load(from: file)
            #expect(connection.baseURL.absoluteString == "http://127.0.0.1:18123/api")
            #expect(connection.principalID == "fixture-principal")
            #expect(connection.token == syntheticToken)
            #expect(connection.profileNotice.isEmpty)
        }
    }

    @Test func reviewMetadataProducesOnlyNonCredentialProfileNotice() throws {
        let payload: [String: Any] = ["base_url": "http://127.0.0.1:18123", "principal_id": "fixture-principal", "token": syntheticToken,
            "name": "Fixture de revisão", "snapshotIsCurrentProduction": false, "requiresMacActive": true]
        try withFile(JSONSerialization.data(withJSONObject: payload)) { file in
            let imported = try PlatformConnectionImport.load(from: file)
            #expect(imported.profileNotice.contains("Fixture de revisão"))
            #expect(imported.profileNotice.contains("sem sincronização contínua"))
            #expect(imported.profileNotice.contains("Inferência neste Mac"))
            #expect(!imported.profileNotice.contains(syntheticToken))
        }
    }

    @Test func invalidOrCredentialBearingProfileNamesAreRejected() throws {
        for name in [String(repeating: "x", count: 161), "Perfil\nquebrado", "Perfil " + syntheticToken] {
            let payload = ["base_url": "https://fixture.example", "principal_id": "fixture-principal", "token": syntheticToken, "name": name]
            try withFile(JSONSerialization.data(withJSONObject: payload)) { file in
                #expect(throws: PlatformConnectionImport.ImportError.invalidMetadata) { try PlatformConnectionImport.load(from: file) }
            }
        }
    }

    @Test func sizeBoundaryAccepts64KiBAndRejectsOneAdditionalByte() throws {
        var boundary = try encodedConnection()
        boundary.append(Data(repeating: 0x20, count: 64 * 1024 - boundary.count))
        try withFile(boundary) { file in
            let connection = try PlatformConnectionImport.load(from: file)
            #expect(connection.principalID == "fixture-principal")
        }
        boundary.append(0x20)
        try withFile(boundary) { file in
            #expect(throws: PlatformConnectionImport.ImportError.fileTooLarge) {
                try PlatformConnectionImport.load(from: file)
            }
        }
    }

    @Test func malformedDataHasSanitizedErrorWithoutTokenOrFilePath() throws {
        try withFile(Data("{\"token\":\"\(syntheticToken)\",".utf8)) { file in
            do {
                _ = try PlatformConnectionImport.load(from: file)
                Issue.record("Malformed JSON was accepted")
            } catch {
                #expect(error as? PlatformConnectionImport.ImportError == .invalidFormat)
                #expect(!error.localizedDescription.contains(syntheticToken))
                #expect(!error.localizedDescription.contains(file.path))
            }
        }
    }

    @Test func absentNullAndBlankPrincipalOrTokenAreRejected() throws {
        let valid: [String: Any] = ["base_url": "https://fixture.example/api", "principal_id": "fixture-principal", "token": syntheticToken]
        let missingValues: [Any?] = [nil, NSNull(), "", " \n\t "]
        for field in ["base_url", "principal_id", "token"] {
            for missingValue in missingValues {
                var payload = valid
                if let missingValue { payload[field] = missingValue } else { payload.removeValue(forKey: field) }
                try withFile(JSONSerialization.data(withJSONObject: payload)) { file in
                    #expect(throws: PlatformConnectionImport.ImportError.missingFields) {
                        try PlatformConnectionImport.load(from: file)
                    }
                }
            }
        }
    }

    @Test func wrongFieldTypeAndRelativeOrMalformedURLsAreRejected() throws {
        try withFile(Data(#"{"base_url":"https://fixture.example","principal_id":"fixture-principal","token":123}"#.utf8)) { file in
            #expect(throws: PlatformConnectionImport.ImportError.invalidFormat) { try PlatformConnectionImport.load(from: file) }
        }
        for address in ["relative/path", "https://fixture.example/bad path", "https://[invalid"] {
            let data = try JSONSerialization.data(withJSONObject: ["base_url": address, "principal_id": "fixture-principal", "token": syntheticToken])
            try withFile(data) { file in
                #expect(throws: PlatformConnectionImport.ImportError.invalidURL) { try PlatformConnectionImport.load(from: file) }
            }
        }
    }

    @Test func endpointSecurityPolicyIsDeferredToPlatformService() throws {
        // Importing is staging only; an absolute HTTP URL must still be rejected by the activation policy.
        let data = try JSONSerialization.data(withJSONObject: ["base_url": "http://fixture.example/api", "principal_id": "fixture-principal", "token": syntheticToken])
        try withFile(data) { file in
            let imported = try PlatformConnectionImport.load(from: file)
            #expect(imported.baseURL.scheme == "http")
        }
    }

    @Test func rejectsRemoteURLDirectorySymlinkAndFIFO() throws {
        #expect(throws: PlatformConnectionImport.ImportError.invalidFile) {
            try PlatformConnectionImport.load(from: URL(string: "https://fixture.example/connection.json")!)
        }
        #expect(throws: PlatformConnectionImport.ImportError.invalidFile) {
            try PlatformConnectionImport.load(from: URL(string: "file://remote-host/connection.json")!)
        }
        try withDirectory { directory in
            #expect(throws: PlatformConnectionImport.ImportError.invalidFile) { try PlatformConnectionImport.load(from: directory) }
            let target = directory.appendingPathComponent("target.json")
            try encodedConnection().write(to: target)
            let link = directory.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: PlatformConnectionImport.ImportError.unreadableFile) { try PlatformConnectionImport.load(from: link) }
            let fifo = directory.appendingPathComponent("connection.pipe")
            let result = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
            #expect(result == 0)
            if result == 0 {
                #expect(throws: PlatformConnectionImport.ImportError.invalidFile) { try PlatformConnectionImport.load(from: fifo) }
            }
        }
    }

    @Test func nonexistentFileErrorDoesNotIncludeItsPath() throws {
        try withDirectory { directory in
            let missing = directory.appendingPathComponent("sensitive-filename-marker.json")
            do {
                _ = try PlatformConnectionImport.load(from: missing)
                Issue.record("Missing file was accepted")
            } catch {
                #expect(error as? PlatformConnectionImport.ImportError == .unreadableFile)
                #expect(!error.localizedDescription.contains(missing.lastPathComponent))
                #expect(!error.localizedDescription.contains(missing.path))
            }
        }
    }
}
