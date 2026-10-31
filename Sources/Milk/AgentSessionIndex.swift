import Foundation

struct IndexedAgentSession: Identifiable, Codable, Equatable {
    var id: UUID { metadata.id }
    var metadata: AgentSessionMetadata
    var editorID: Int?
    var nativeID: String
    var nativeFile: String?
    var title: String
    var isOpen: Bool
    init(session: AgentSession, workspace: SessionWorkspace, isOpen: Bool) {
        var session = session; session.bind(workspace)
        metadata = session.metadata; editorID = session.id; nativeID = session.backendID
        nativeFile = session.sessionFile; title = session.title; self.isOpen = isOpen
    }
    var savedReference: SavedAgentSession? {
        nativeFile.map { .init(path: $0, title: title, modified: metadata.modifiedAt ?? .distantPast,
                              agentID: metadata.agentID, milkID: id, nativeID: nativeID, workspace: metadata.workspace?.url) }
    }
}

/// Metadata only: canonical conversations and editor recovery stay in Workspaces.
/// Listing retained records never starts an adapter or reads native agent history.
@MainActor final class AgentSessionIndex {
    private struct Storage: Codable { var version = 1; var records: [String: IndexedAgentSession] = [:] }
    private var storage = Storage()
    private let file: URL
    private let enabled: Bool
    private(set) var loadProblem: String?
    init(file: URL, enabled: Bool) {
        self.file = file; self.enabled = enabled
        if enabled, FileManager.default.fileExists(atPath: file.path) {
            do {
                let value = try JSONDecoder().decode(Storage.self, from: Data(contentsOf: file))
                guard value.version == 1 else { throw AgentError.message("Unsupported session index version.") }
                storage = value
            } catch { loadProblem = error.localizedDescription }
        }
    }
    func records(workspace: SessionWorkspace? = nil) -> [IndexedAgentSession] {
        storage.records.values.filter { workspace == nil || $0.metadata.workspace?.id == workspace?.id }.map { value in
            var value = value
            if value.metadata.availability.state == .available { value.metadata.availability = .init() }
            return value
        }.sorted { ($0.metadata.modifiedAt ?? .distantPast) > ($1.metadata.modifiedAt ?? .distantPast) }
    }
    func upsert(_ values: [IndexedAgentSession]) throws {
        var next = storage
        for value in values { next.records[value.id.uuidString] = value }
        guard next.records != storage.records else { return }
        try commit(next)
    }
    func remove(_ ids: Set<UUID>) throws {
        var next = storage
        for id in ids { next.records[id.uuidString] = nil }
        try commit(next)
    }
    private func commit(_ value: Storage) throws {
        guard loadProblem == nil else { throw AgentError.message("Session index retained without overwrite: " + loadProblem!) }
        if enabled {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        storage = value
    }
    func discover(_ saved: [SavedAgentSession], workspace: SessionWorkspace) throws {
        var values: [IndexedAgentSession] = []
        for saved in saved {
            if var existing = storage.records.values.first(where: { $0.metadata.agentID == saved.agentID && $0.metadata.workspace?.id == workspace.id && $0.nativeFile == saved.path }) {
                existing.title = saved.title
                if let native = saved.nativeID { existing.nativeID = native }
                values.append(existing)
            } else {
                let id = AgentSessionMetadata.stableID(["native-file", saved.agentID.rawValue, workspace.id, saved.path])
                var metadata = AgentSessionMetadata(id: id, agentID: saved.agentID, workspace: workspace, createdAt: nil)
                metadata.modifiedAt = saved.modified
                let session = AgentSession(id: -1, title: saved.title, backendID: saved.nativeID ?? UUID().uuidString, sessionFile: saved.path, metadata: metadata)
                var record = IndexedAgentSession(session: session, workspace: workspace, isOpen: false)
                record.editorID = nil; values.append(record)
            }
        }
        try upsert(values)
    }
    func cachedConversation(_ record: IndexedAgentSession, persistence: WorkspacePersistence) -> SessionConversation? {
        guard let root = record.metadata.workspace, let id = record.editorID,
              let data = persistence.load(root.url)?.shellSessions,
              let state = try? JSONDecoder().decode(AgentWorkspaceState.self, from: data), [3,4].contains(state.version),
              var session = (state.sessions + state.archived).first(where: { $0.id == id }) else { return nil }
        session.bind(root)
        guard session.metadata.id == record.id, session.agentID == record.metadata.agentID else { return nil }
        return state.conversations[id]
    }
}
