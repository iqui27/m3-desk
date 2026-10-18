import Foundation

public struct WorkspaceSelection: Codable, Equatable, Sendable {
    public var identity: WorkspaceIdentity
    public var subprojectID: String?
    public init(identity: WorkspaceIdentity, subprojectID: String? = nil) { self.identity = identity; self.subprojectID = subprojectID }
}

/// Resume metadata only. Never place authorization tokens or remote payloads in the cursor.
public struct LocalRunCursor: Codable, Equatable, Sendable {
    public let identity: WorkspaceIdentity
    public let runID: String
    public var cursor: String?
    public var lastEventSequence: Int?
    public var updatedAt: Date
    public init(identity: WorkspaceIdentity, runID: String, cursor: String? = nil, lastEventSequence: Int? = nil, updatedAt: Date = Date()) {
        self.identity = identity; self.runID = runID; self.cursor = cursor; self.lastEventSequence = lastEventSequence; self.updatedAt = updatedAt
    }
}

/// Retry metadata for an operation whose remote outcome may be unknown. Payloads and credentials are never persisted.
public struct PendingRunOperation: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case create, resume }
    public var id: String { idempotencyKey }
    public let identity: WorkspaceIdentity
    public let kind: Kind
    public let payloadFingerprint: String
    public let idempotencyKey: String
    public let runID: String?
    public let createdAt: Date

    public init(identity: WorkspaceIdentity, kind: Kind, payloadFingerprint: String, idempotencyKey: String = UUID().uuidString,
                runID: String? = nil, createdAt: Date = Date()) {
        self.identity = identity; self.kind = kind; self.payloadFingerprint = payloadFingerprint
        self.idempotencyKey = idempotencyKey; self.runID = runID; self.createdAt = createdAt
    }

    /// Include every field of the logical request, including agent/checkpoint/version, but no bearer credential.
    public static func fingerprint(_ payload: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return stableStorageKey([String(decoding: try encoder.encode(payload), as: UTF8.self)])
    }

    fileprivate func validate() throws {
        try identity.validate()
        guard payloadFingerprint.count == 64,
              payloadFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              kind != .resume || runID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              kind != .create || runID == nil else { throw LocalStorageError.invalidIdentity }
    }
}

public enum DraftNotice: Equatable, Sendable, CustomStringConvertible {
    case migratedLegacy, legacyCollision, legacyCorrupt, ambiguousLegacy, legacyAlreadyAssigned
    public var description: String {
        switch self {
        case .migratedLegacy: "Rascunho antigo recuperado; original preservado."
        case .legacyCollision: "Uma chave antiga corresponde a outro nome; use recuperação explícita."
        case .legacyCorrupt: "Há um rascunho antigo ilegível; original preservado."
        case .ambiguousLegacy: "Mais de um rascunho antigo corresponde ao projeto; escolha na recuperação."
        case .legacyAlreadyAssigned: "O rascunho antigo já foi atribuído a outro contexto ou requer recuperação explícita."
        }
    }
}

public struct DraftLoadResult: Equatable, Sendable {
    public let draft: HandoffDraft
    public let notices: [DraftNotice]
    public init(draft: HandoffDraft, notices: [DraftNotice] = []) { self.draft = draft; self.notices = notices }
}

public struct LegacyDraftCandidate: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case recoverable, malformed, keyMismatch, alreadyAssigned }
    public var id: String { key }
    public let key: String
    public let projectName: String?
    public let status: Status
    /// Rejects a changed source between listing and recovery; not a content preview.
    public let fingerprint: String
}

/// Persists local authoring and resume metadata. Deliberately no remote-memory cache API.
public final class LocalCache {
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("M3Desk", isDirectory: true).appendingPathComponent("Local-v2", isDirectory: true)
    }
    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL = LocalCache.applicationSupportDirectory) throws {
        self.directory = directory; self.fileManager = .default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw LocalStorageError.io("abrir a pasta") }
    }

    private struct DraftEnvelope: Codable { let schemaVersion: Int; let identity: WorkspaceIdentity; let subprojectID: String?; let draft: HandoffDraft }
    private struct SelectionEnvelope: Codable { let schemaVersion: Int; let selection: WorkspaceSelection }
    private struct CursorEnvelope: Codable { let schemaVersion: Int; let cursor: LocalRunCursor }
    private struct OperationEnvelope: Codable { let schemaVersion: Int; let operation: PendingRunOperation }
    private struct MigrationReceipt: Codable { let legacyKey: String; let identity: WorkspaceIdentity; let subprojectID: String? }

    public func draftURL(identity: WorkspaceIdentity, subprojectID: String? = nil) -> URL {
        directory.appendingPathComponent("draft-" + stableStorageKey([identity.tenantID, identity.projectID, identity.principalID, subprojectID == nil ? "project" : "subproject", subprojectID ?? ""]) + ".json")
    }

    private func receiptURL(_ legacyKey: String) -> URL { directory.appendingPathComponent("migration-" + stableStorageKey([legacyKey]) + ".json") }
    private func read<T: Decodable>(_ type: T.Type, from url: URL, label: String) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LocalStorageError.io("ler \(label)") }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw LocalStorageError.corruptData(label) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL, exclusively: Bool = false) throws {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(value)
            try bytes.write(to: url, options: exclusively ? [.withoutOverwriting] : [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw LocalStorageError.io("salvar os dados") }
    }

    private func validateSlot(_ subprojectID: String?) throws {
        if let subprojectID, subprojectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LocalStorageError.invalidIdentity }
    }

    private func readDraft(identity: WorkspaceIdentity, subprojectID: String?) throws -> HandoffDraft? {
        guard let envelope = try read(DraftEnvelope.self, from: draftURL(identity: identity, subprojectID: subprojectID), label: "O rascunho local") else { return nil }
        guard envelope.schemaVersion == 2 else { throw LocalStorageError.unsupportedVersion(envelope.schemaVersion) }
        guard envelope.identity == identity, envelope.subprojectID == subprojectID,
              envelope.draft.workspaceIdentity == identity, envelope.draft.subprojectID == subprojectID else { throw LocalStorageError.namespaceMismatch }
        return envelope.draft
    }

    public func saveDraft(_ draft: HandoffDraft, identity: WorkspaceIdentity, subprojectID: String? = nil) throws {
        try identity.validate(); try validateSlot(subprojectID)
        // Corrupt or foreign existing data must never be replaced by an empty editor.
        _ = try readDraft(identity: identity, subprojectID: subprojectID)
        if let storedIdentity = draft.workspaceIdentity,
           storedIdentity != identity || draft.subprojectID != subprojectID { throw LocalStorageError.namespaceMismatch }
        var scoped = draft; scoped.workspaceIdentity = identity; scoped.subprojectID = subprojectID
        try write(DraftEnvelope(schemaVersion: 2, identity: identity, subprojectID: subprojectID, draft: scoped), to: draftURL(identity: identity, subprojectID: subprojectID))
    }

    public func loadDraft(identity: WorkspaceIdentity, projectName: String, subprojectID: String? = nil, legacyProjectNames: [String] = [], legacyDefaults: UserDefaults = .standard) throws -> DraftLoadResult {
        try identity.validate(); try validateSlot(subprojectID)
        if let existing = try readDraft(identity: identity, subprojectID: subprojectID) { return .init(draft: existing) }
        var fresh = HandoffDraft(); fresh.project = projectName; fresh.workspaceIdentity = identity; fresh.subprojectID = subprojectID
        var notices: [DraftNotice] = []
        var eligible: [(String, HandoffDraft)] = []
        let allowedNames = Set(legacyProjectNames)
        for key in Set(legacyProjectNames.map(HandoffDraft.legacyKey)).sorted() {
            guard legacyDefaults.object(forKey: key) != nil else { continue }
            guard let data = legacyDefaults.data(forKey: key), let draft = try? JSONDecoder().decode(HandoffDraft.self, from: data) else { notices.append(.legacyCorrupt); continue }
            guard allowedNames.contains(draft.project), HandoffDraft.legacyKey(project: draft.project) == key else { notices.append(.legacyCollision); continue }
            // Old storage cannot prove tenant membership. Known old names opt in explicitly.
            if try read(MigrationReceipt.self, from: receiptURL(key), label: "O registro de migração") != nil { notices.append(.legacyAlreadyAssigned); continue }
            eligible.append((key, draft))
        }
        guard eligible.count == 1, notices.isEmpty else {
            if eligible.count > 1 { notices.append(.ambiguousLegacy) }
            return .init(draft: fresh, notices: notices)
        }
        let (key, draft) = eligible[0]
        try claimLegacy(key: key, identity: identity, subprojectID: subprojectID)
        var migrated = draft; migrated.workspaceIdentity = identity; migrated.subprojectID = subprojectID
        try saveDraft(migrated, identity: identity, subprojectID: subprojectID)
        return .init(draft: migrated, notices: [.migratedLegacy])
    }

    private func claimLegacy(key: String, identity: WorkspaceIdentity, subprojectID: String?) throws {
        try write(MigrationReceipt(legacyKey: key, identity: identity, subprojectID: subprojectID), to: receiptURL(key), exclusively: true)
    }

    /// Lists metadata only, including orphaned names and malformed keys.
    public func recoveryCandidates(defaults: UserDefaults = .standard) throws -> [LegacyDraftCandidate] {
        try defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("handoff.") }.sorted().map { key in
            guard let data = defaults.data(forKey: key) else { return .init(key: key, projectName: nil, status: .malformed, fingerprint: "") }
            let fingerprint = stableStorageKey([data.base64EncodedString()])
            guard let draft = try? JSONDecoder().decode(HandoffDraft.self, from: data) else { return .init(key: key, projectName: nil, status: .malformed, fingerprint: fingerprint) }
            let receipt = try read(MigrationReceipt.self, from: receiptURL(key), label: "O registro de migração")
            let status: LegacyDraftCandidate.Status = receipt != nil ? .alreadyAssigned : HandoffDraft.legacyKey(project: draft.project) == key ? .recoverable : .keyMismatch
            return .init(key: key, projectName: draft.project, status: status, fingerprint: fingerprint)
        }
    }

    /// Explicit recovery assigns an orphan or collision to an empty slot; never deletes old data.
    public func recoverLegacy(_ candidate: LegacyDraftCandidate, identity: WorkspaceIdentity, subprojectID: String? = nil, defaults: UserDefaults = .standard) throws -> HandoffDraft {
        try identity.validate(); try validateSlot(subprojectID)
        guard !fileManager.fileExists(atPath: draftURL(identity: identity, subprojectID: subprojectID).path) else { throw LocalStorageError.destinationOccupied }
        guard candidate.key.hasPrefix("handoff."), let data = defaults.data(forKey: candidate.key),
              stableStorageKey([data.base64EncodedString()]) == candidate.fingerprint,
              var draft = try? JSONDecoder().decode(HandoffDraft.self, from: data),
              draft.project == candidate.projectName else { throw LocalStorageError.legacySourceChanged }
        // An earlier claim does not prevent an explicit user-directed recovery copy.
        if try read(MigrationReceipt.self, from: receiptURL(candidate.key), label: "O registro de migração") == nil {
            try claimLegacy(key: candidate.key, identity: identity, subprojectID: subprojectID)
        }
        draft.workspaceIdentity = identity; draft.subprojectID = subprojectID
        try saveDraft(draft, identity: identity, subprojectID: subprojectID)
        return draft
    }

    public func saveSelection(_ selection: WorkspaceSelection) throws {
        try selection.identity.validate(); try validateSlot(selection.subprojectID)
        _ = try loadSelection(principalID: selection.identity.principalID)
        let url = directory.appendingPathComponent("selection-" + stableStorageKey([selection.identity.principalID]) + ".json")
        try write(SelectionEnvelope(schemaVersion: 1, selection: selection), to: url)
    }

    public func loadSelection(principalID: String) throws -> WorkspaceSelection? {
        let url = directory.appendingPathComponent("selection-" + stableStorageKey([principalID]) + ".json")
        guard let envelope = try read(SelectionEnvelope.self, from: url, label: "A seleção local") else { return nil }
        guard envelope.schemaVersion == 1 else { throw LocalStorageError.unsupportedVersion(envelope.schemaVersion) }
        guard envelope.selection.identity.principalID == principalID else { throw LocalStorageError.namespaceMismatch }
        try envelope.selection.identity.validate(); try validateSlot(envelope.selection.subprojectID)
        return envelope.selection
    }

    public func saveRunCursor(_ cursor: LocalRunCursor) throws {
        try validateCursor(cursor)
        if let existing = try loadRunCursor(identity: cursor.identity, runID: cursor.runID) {
            // Opaque cursors cannot be ordered. The sequence is authoritative; missing/older updates never reset it.
            if let previous = existing.lastEventSequence {
                guard let next = cursor.lastEventSequence, next >= previous else { return }
                if next == previous, existing.cursor != nil { return }
            } else if cursor.lastEventSequence == nil, cursor.updatedAt < existing.updatedAt { return }
        }
        try write(CursorEnvelope(schemaVersion: 1, cursor: cursor), to: cursorURL(identity: cursor.identity, runID: cursor.runID))
    }

    public func loadRunCursor(identity: WorkspaceIdentity, runID: String) throws -> LocalRunCursor? {
        try identity.validate()
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalStorageError.invalidIdentity }
        let url = cursorURL(identity: identity, runID: runID)
        let legacyURL = directory.appendingPathComponent("cursor-" + stableStorageKey([identity.storageKey, runID]) + ".json")
        guard let envelope = try read(CursorEnvelope.self, from: fileManager.fileExists(atPath: url.path) ? url : legacyURL, label: "O cursor local") else { return nil }
        guard envelope.schemaVersion == 1 else { throw LocalStorageError.unsupportedVersion(envelope.schemaVersion) }
        guard envelope.cursor.identity == identity, envelope.cursor.runID == runID else { throw LocalStorageError.namespaceMismatch }
        try validateCursor(envelope.cursor)
        return envelope.cursor
    }

    /// Files carry the namespace in their prefix, so restart discovery does not depend on a separately committed index.
    public func listRunCursors(identity: WorkspaceIdentity) throws -> [LocalRunCursor] {
        try identity.validate()
        let prefix = "cursor-" + identity.storageKey + "-"
        var results: [String: LocalRunCursor] = [:]
        for url in try localFiles() where url.lastPathComponent.hasPrefix("cursor-") && url.pathExtension == "json" {
            // Compatibility: old cursor names contained only one hash; inspect their envelope without modifying them.
            let legacy = url.deletingPathExtension().lastPathComponent.count == "cursor-".count + 64
            guard url.lastPathComponent.hasPrefix(prefix) || legacy else { continue }
            guard let envelope = try read(CursorEnvelope.self, from: url, label: "O cursor local") else { continue }
            guard envelope.cursor.identity == identity else {
                if !legacy { throw LocalStorageError.namespaceMismatch }
                continue
            }
            guard envelope.schemaVersion == 1 else { throw LocalStorageError.unsupportedVersion(envelope.schemaVersion) }
            try validateCursor(envelope.cursor)
            let cursor = try loadRunCursor(identity: identity, runID: envelope.cursor.runID) ?? envelope.cursor
            results[cursor.runID] = cursor
        }
        return results.values.sorted { $0.updatedAt == $1.updatedAt ? $0.runID < $1.runID : $0.updatedAt > $1.updatedAt }
    }

    /// Call before sending create/resume. Repeating the same logical request returns its original key after a restart.
    public func beginRunOperation(identity: WorkspaceIdentity, kind: PendingRunOperation.Kind, payloadFingerprint: String,
                                  runID: String? = nil) throws -> PendingRunOperation {
        let operation = PendingRunOperation(identity: identity, kind: kind, payloadFingerprint: payloadFingerprint, runID: runID)
        try operation.validate()
        let url = operationURL(operation)
        if let existing = try readOperation(from: url) {
            guard sameLogicalOperation(existing, operation) else { throw LocalStorageError.namespaceMismatch }
            return existing
        }
        do { try write(OperationEnvelope(schemaVersion: 1, operation: operation), to: url, exclusively: true) }
        catch {
            // Another caller may have claimed the same intent while this one was preparing it.
            if let existing = try readOperation(from: url), sameLogicalOperation(existing, operation) { return existing }
            throw error
        }
        return operation
    }

    public func pendingRunOperations(identity: WorkspaceIdentity) throws -> [PendingRunOperation] {
        try identity.validate()
        let prefix = "operation-" + identity.storageKey + "-"
        return try localFiles().filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.compactMap { url in
            guard let operation = try readOperation(from: url) else { return nil }
            guard operation.identity == identity else { throw LocalStorageError.namespaceMismatch }
            return operation
        }.sorted { $0.createdAt == $1.createdAt ? $0.idempotencyKey < $1.idempotencyKey : $0.createdAt < $1.createdAt }
    }

    /// Only clear after a confirmed outcome. An old completion cannot erase a newly prepared operation.
    public func completeRunOperation(_ operation: PendingRunOperation) throws {
        try operation.validate()
        let url = operationURL(operation)
        guard let existing = try readOperation(from: url) else { return }
        guard existing == operation else { throw LocalStorageError.namespaceMismatch }
        do { try fileManager.removeItem(at: url) } catch { throw LocalStorageError.io("concluir a operação") }
    }

    private func readOperation(from url: URL) throws -> PendingRunOperation? {
        guard let envelope = try read(OperationEnvelope.self, from: url, label: "A operação pendente") else { return nil }
        guard envelope.schemaVersion == 1 else { throw LocalStorageError.unsupportedVersion(envelope.schemaVersion) }
        try envelope.operation.validate()
        return envelope.operation
    }
    private func sameLogicalOperation(_ lhs: PendingRunOperation, _ rhs: PendingRunOperation) -> Bool {
        lhs.identity == rhs.identity && lhs.kind == rhs.kind && lhs.payloadFingerprint == rhs.payloadFingerprint && lhs.runID == rhs.runID
    }
    private func localFiles() throws -> [URL] {
        do { return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch { throw LocalStorageError.io("listar os dados") }
    }
    private func validateCursor(_ cursor: LocalRunCursor) throws {
        try cursor.identity.validate()
        guard !cursor.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cursor.lastEventSequence.map({ $0 >= 0 }) ?? true else { throw LocalStorageError.invalidIdentity }
    }
    private func cursorURL(identity: WorkspaceIdentity, runID: String) -> URL {
        directory.appendingPathComponent("cursor-" + identity.storageKey + "-" + stableStorageKey([runID]) + ".json")
    }
    private func operationURL(_ operation: PendingRunOperation) -> URL {
        directory.appendingPathComponent("operation-" + operation.identity.storageKey + "-" + stableStorageKey([operation.kind.rawValue, operation.payloadFingerprint, operation.runID ?? ""]) + ".json")
    }
}
