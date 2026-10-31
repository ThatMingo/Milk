import Foundation
import Combine

struct SessionConversation: Codable {
    var messages: [AgentMessage] = []
    var activities: [AgentActivity] = []
    var changes: [AgentFileChange] = []
    var draft = ""
    var attachments: [PromptAttachment] = []
    var queued: StoredPrompt?
    var permission: ComposerPermissionMode = .approval
    var modelID: String?
    var effort: String?
    var notice: String?
    var error: String?
    var scrollAnchor: String?
    var followsTail = true
}
struct StoredPrompt: Codable {
    var text: String
    var attachments: [PromptAttachment]
    var prompt: AgentPrompt { .init(text: text, attachments: attachments) }
}
struct AgentWorkspaceState: Codable {
    var version = 4
    var sessions: [AgentSession]
    var conversations: [Int: SessionConversation]
    var nextID: Int
    var archived: [AgentSession]
    var selectedAgentID: AgentID? = nil
}

/// Coordinates agent lifetimes and per-session state; filesystem/layout stay with WorkspaceStore.
@MainActor final class AgentService: ObservableObject {
    @Published private(set) var slashCommands: [Int:[AgentCommand]] = [:]
    private struct ExtensionDecision { let session: Int; let owner: String; let continuation: CheckedContinuation<Void,Error> }
    private var extensionDecisions: [String:ExtensionDecision] = [:]
    @Published var sessions: [AgentSession] = [] { didSet { persist() } }
    @Published var selectedSession = -1 {
        didSet {
            workspace.selectedSession = selectedSession
            if let i = sessions.firstIndex(where: { $0.id == selectedSession }), sessions[i].state == .unread { sessions[i].state = .idle }
            if !restoring, enabled, sessions.contains(where: { $0.id == selectedSession }) { connect(selectedSession) }
        }
    }
    @Published var conversations: [Int: SessionConversation] = [:] { didSet { persist() } }
    @Published private(set) var configuration: AgentConfiguration
    @Published private(set) var runtimeStatuses: [Int: RuntimeStatus] = [:]
    @Published private(set) var models: [Int: [AgentModel]] = [:]
    @Published private(set) var efforts: [Int: [String: [String]]] = [:]
    @Published private(set) var editingApprovals: [Int: AgentApproval] = [:]
    @Published private(set) var approvals: [Int: [AgentApproval]] = [:]
    @Published private(set) var history: [SavedAgentSession] = []
    @Published private(set) var deletingSessionPath: String?
    @Published private(set) var runningSessions: Set<Int> = []
    @Published private(set) var pendingActions: Set<Int> = []
    private struct PreviewDecision {
        var session: Int
        var configuration: PreviewConfiguration
        var continuation: CheckedContinuation<PreviewConfiguration, Error>
    }
    private var previewDecisions: [String: PreviewDecision] = [:]
    private var previewAllowances: Set<String> = []
    private var previewActivitySessions: [String: Int] = [:]
    private var archived: [AgentSession] = []
    private var backendTokens: [Int: AgentActivation] = [:]
    private var actionTokens: [Int: UUID] = [:]
    private var backends: [Int: AgentBackend] = [:]
    private var starts: [Int: Task<Void, Error>] = [:]
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private var historyDirectories: [AgentID: URL] = [:]
    @Published private(set) var projectAgentID: AgentID = .pi
    @Published private(set) var restorationIssue: String?
    @Published private(set) var indexIssue: String?
    private var retainedPayload: Data?
    private var historyRevision = UUID()
    let lifecycle: AgentLifecycleCoordinator
    private var leases: [Int: AgentRuntimeLease] = [:]
    private var actionSessions: [UUID: Int] = [:]
    private var terminating = false
    private var nextID = 0
    private var restoring = false
    private var workspaceGeneration = UUID()
    var onExtensionProblem: ((String)->Void)?
    private let workspace: WorkspaceStore
    private let defaults: UserDefaults
    private let enabled: Bool
    let registry: AgentRegistry
    let sessionIndex: AgentSessionIndex
    private let selection: AgentSelectionPreferences
    var adapter: (any AgentAdapter)? { registry.adapter(for: currentSession?.agentID ?? projectAgentID) }
    var agentIdentity: AgentID { currentSession?.agentID ?? projectAgentID }
    var capabilities: Set<AgentCapability> { adapter?.descriptor.capabilities ?? [] }
    var globalDefaultAgentID: AgentID { selection.globalDefault }
    func setGlobalDefaultAgent(_ id: AgentID) throws { try selection.setGlobalDefault(id) }
    func selectProjectAgent(_ id: AgentID) throws {
        guard registry.adapter(for: id) != nil else { throw AgentError.message("This agent is not registered.") }
        projectAgentID = id; persist()
    }
    var effectiveCapabilities: Set<AgentCapability> {
        var result = capabilities
        if selectedModel?.supportsImages != true { result.remove(.imageAttachments) }
        if (efforts[selectedSession]?[current.modelID ?? ""] ?? []).isEmpty { result.remove(.reasoningLevels) }
        return result
    }
    init(workspace: WorkspaceStore, defaults: UserDefaults, enabled: Bool, adapter: (any AgentAdapter)? = nil,
         makeBackend: (@MainActor () -> AgentBackend)? = nil, registry: AgentRegistry? = nil, sessionIndex: AgentSessionIndex? = nil, lifecycle: AgentLifecycleCoordinator? = nil) {
        self.lifecycle = lifecycle ?? AgentLifecycleCoordinator()
        self.workspace = workspace; self.defaults = defaults; self.enabled = enabled
        var registered = registry ?? AgentRegistry.standard(defaults: defaults)
        if let adapter { registered = .init(adapters: [adapter], defaultAgentID: adapter.descriptor.id) }
        if let makeBackend {
            let replacement = BackendOverrideAdapter(base: registered.defaultAdapter, factory: makeBackend)
            registered = .init(adapters: registered.adapters.map { $0.descriptor.id == registered.defaultAgentID ? replacement : $0 }, defaultAgentID: registered.defaultAgentID)
        }
        self.registry = registered
        selection = .init(defaults: defaults, registry: registered)
        self.sessionIndex = sessionIndex ?? AgentSessionIndex(file: workspace.persistence.directory.deletingLastPathComponent().appendingPathComponent("Sessions/index-v1.json"), enabled: workspace.persistence.enabled)
        configuration = .load(defaults)
    }
    func availability(_ session: AgentSession) -> SessionAvailability {
        guard let owner = registry.adapter(for: session.agentID) else { return .init(state: .agentUnavailable, detail: "The session's owning agent is unavailable; its history is retained.") }
        guard let root = workspace.workspace.map({ SessionWorkspace($0.url) }), session.metadata.workspace == nil || session.metadata.workspace == root else {
            return .init(state: .workspaceUnavailable, detail: "Open the session's owning project first.")
        }
        let inspected = owner.sessionAvailability(session, workspace: root)
        guard inspected.canAttemptResume else { return inspected }
        if sessions.contains(where: { $0.metadata.id == session.metadata.id }), let status = runtimeStatuses[session.id] {
            if status.phase == .ready { return .init(state: .available, detail: "Connected to the owning agent.") }
            if let result = status.compatibility, result.state != .supported {
                return .init(state: result.state == .invalidRuntime ? .runtimeUnavailable : .incompatibleRuntime, detail: result.detail)
            }
        }
        return inspected
    }
    func retainedSessions(allProjects: Bool = false) -> [IndexedAgentSession] {
        if allProjects { return sessionIndex.records() }
        guard let root = workspace.workspace else { return [] }
        return sessionIndex.records(workspace: SessionWorkspace(root.url))
    }
    func sessionsForBrowsing(_ scope: SessionBrowserScope) -> [IndexedAgentSession] { retainedSessions(allProjects: scope == .allProjects) }
    func reopenForBrowsing(_ saved: SavedAgentSession) {
        let wasRestoring = restoring; restoring = true
        reopen(saved)
        restoring = wasRestoring; persist()
    }
    func retainedConversation(_ record: IndexedAgentSession) -> SessionConversation? {
        if let id = record.editorID, sessions.contains(where: { $0.metadata.id == record.id }) || archived.contains(where: { $0.metadata.id == record.id }) { return conversations[id] }
        return sessionIndex.cachedConversation(record, persistence: workspace.persistence)
    }
    var current: SessionConversation {
        get { conversations[selectedSession] ?? SessionConversation(permission: configuration.defaultPermission) }
        set { conversations[selectedSession] = newValue }
    }
    var currentSession: AgentSession? { sessions.first { $0.id == selectedSession } }
    /// An empty editor-linked session is not evidence that an agent has been used.
    /// Keep native references/cached work meaningful even when its installation is gone.
    func hasAgentContext(_ session: AgentSession) -> Bool {
        let conversation = conversations[session.id] ?? .init()
        return registry.adapter(for: session.agentID)?.hasSelectedInstallation == true
            || session.sessionFile != nil || session.metadata.lastRuntimeVersion != nil
            || session.metadata.lastInstallationID != nil
            || !conversation.messages.isEmpty || !conversation.activities.isEmpty
    }
    func agentDisplayName(_ session: AgentSession) -> String? {
        guard hasAgentContext(session) else { return nil }
        return registry.adapter(for: session.agentID)?.descriptor.name ?? session.agentID.rawValue
    }
    var currentAgentDisplayName: String? { currentSession.flatMap(agentDisplayName) }
    var showsNeutralChat: Bool { currentAgentDisplayName == nil && current.messages.isEmpty && current.activities.isEmpty && restorationIssue == nil }
    var composerPlaceholder: String { busy ? "Write a follow-up…" : currentAgentDisplayName.map { "Message \($0)…" } ?? "Message…" }
    var recentHistory: [SavedAgentSession] {
        var seen = Set<String>()
        return (history + retainedSessions().compactMap(\.savedReference)).filter { saved in
            !sessions.contains { $0.agentID == saved.agentID && $0.sessionFile == saved.path } && seen.insert(saved.id).inserted
        }
    }
    func savedReference(_ session: AgentSession) -> SavedAgentSession? {
        session.sessionFile.map { .init(path: $0, title: session.title, modified: session.metadata.modifiedAt ?? .now, agentID: session.agentID, milkID: session.metadata.id, nativeID: session.backendID, workspace: session.metadata.workspace?.url) }
    }
    func reorderSession(_ id: Int, to target: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }), let to = sessions.firstIndex(where: { $0.id == target }), from != to else { return }
        let session = sessions.remove(at: from); sessions.insert(session, at: to)
    }
    func sessionDeletionUnavailableReason(_ saved: SavedAgentSession?) -> String? {
        guard let saved else { return "No saved history yet. Use Close." }
        guard let owner = registry.adapter(for: saved.agentID) else { return "The session's owning agent is unavailable." }
        if let reason = owner.sessionDeletionUnavailableReason(saved) { return reason }
        guard FileManager.default.fileExists(atPath: saved.path) else { return "No saved Pi history on disk. Use Close." }
        guard deletingSessionPath == nil else { return "A session is being deleted." }
        guard let directory = historyDirectories[saved.agentID],
              URL(fileURLWithPath: saved.path).deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else { return "Outside the active Pi session directory." }
        let matching = sessions.filter { $0.sessionFile == saved.path && $0.agentID == saved.agentID }
        guard !matching.contains(where: { runningSessions.contains($0.id) || pendingActions.contains($0.id) || starts[$0.id] != nil || approvals[$0.id]?.isEmpty == false || editingApprovals[$0.id] != nil }) else { return "Stop session work before deleting." }
        return nil
    }
    func deleteSavedSession(_ saved: SavedAgentSession) async throws {
        if let reason = sessionDeletionUnavailableReason(saved) { throw AgentError.message(reason) }
        guard let root = workspace.workspace?.url, let directory = historyDirectories[saved.agentID],
              history.contains(where: { $0.path == saved.path && $0.agentID == saved.agentID }) || sessions.contains(where: { $0.sessionFile == saved.path && $0.agentID == saved.agentID }) ||
              retainedSessions().contains(where: { $0.nativeFile == saved.path && $0.metadata.agentID == saved.agentID }) else {
            throw AgentError.message("Refresh session history before deleting this session.")
        }
        guard let service = registry.adapter(for: saved.agentID)?.fileSessionHistory else { throw AgentError.message("This agent does not support saved-file deletion.") }
        let generation = workspaceGeneration
        try service.validateDeletion(saved, workspace: root, directory: directory)
        deletingSessionPath = saved.path
        defer { deletingSessionPath = nil }
        // Detach Chat and move selection before the saved file can disappear.
        for session in sessions.filter({ $0.sessionFile == saved.path && $0.agentID == saved.agentID }) { closeSession(session.id) }
        try await lifecycle.drain(writers: [.file(saved.agentID, URL(fileURLWithPath: saved.path).resolvingSymlinksInPath().path)])
        guard workspaceGeneration == generation else { throw AgentError.message("Workspace changed; saved history was not deleted.") }
        try service.delete(saved, workspace: root, directory: directory)
        for session in archived.filter({ $0.sessionFile == saved.path && $0.agentID == saved.agentID }) {
            conversations[session.id] = nil; runtimeStatuses[session.id] = nil; models[session.id] = nil; efforts[session.id] = nil
        }
        let removed = Set(retainedSessions().filter { $0.nativeFile == saved.path && $0.metadata.agentID == saved.agentID }.map(\.id))
        do { try sessionIndex.remove(removed) } catch { indexIssue = error.localizedDescription }
        archived.removeAll { $0.sessionFile == saved.path && $0.agentID == saved.agentID }
        history.removeAll { $0.path == saved.path && $0.agentID == saved.agentID }; historyRevision = UUID()
        persist(); refreshHistory()
    }
    var busy: Bool { runningSessions.contains(selectedSession) || approvals[selectedSession]?.isEmpty == false }
    var selectedModel: AgentModel? { models[selectedSession]?.first { $0.id == current.modelID } }
    var composerModels: [ComposerModel] {
        guard capabilities.contains(.models) else { return [] }
        return (models[selectedSession] ?? []).map { model in
            let levels = efforts[selectedSession]?[model.id] ?? []
            return .init(id: model.id, name: model.name, efforts: levels.map { .init(id: $0, title: $0 == "off" ? "Off" : $0.capitalized) }, defaultEffortID: levels.first)
        }
    }
    var statusLabel: String {
        if let restorationIssue { return restorationIssue }
        if showsNeutralChat { return "No agent selected" }
        if let unavailable = unavailableReason { return unavailable }
        if let error = current.error { return "\(currentAgentDisplayName ?? "Agent") error · \(error)" }
        if currentSession?.state == .approval { return "Waiting for approval" }
        if busy { return "\(currentAgentDisplayName ?? "Agent") running · \(current.activities.last(where: { $0.status == .running })?.detail ?? "Working")" }
        return runtimeStatuses[selectedSession]?.detail ?? (workspace.workspace == nil ? "Open a project to begin" : "\(currentAgentDisplayName ?? "Agent") not connected")
    }
    var unavailableReason: String? {
        guard let session = currentSession else { return nil }
        let state = availability(session)
        return state.canAttemptResume ? nil : state.detail
    }
    func selectForBrowsing(_ id: Int) {
        let wasRestoring = restoring; restoring = true
        selectedSession = id
        restoring = wasRestoring
    }
    func openRetainedForBrowsing(_ record: IndexedAgentSession) {
        let wasRestoring = restoring; restoring = true
        openRetained(record)
        restoring = wasRestoring; persist()
    }
    func retainedAvailability(_ record: IndexedAgentSession) -> SessionAvailability {
        guard let adapter = registry.adapter(for: record.metadata.agentID) else { return .init(state: .agentUnavailable, detail: "The owning agent is unavailable. Cached history is retained.") }
        guard let root = record.metadata.workspace else { return .init(state: .workspaceUnavailable, detail: "The owning project is unknown.") }
        let session = AgentSession(id: record.editorID ?? -1, title: record.title, backendID: record.nativeID, sessionFile: record.nativeFile, metadata: record.metadata)
        return adapter.sessionAvailability(session, workspace: root)
    }
    func persist() {
        guard !restoring else { return }
        if let root = workspace.workspace, retainedPayload == nil {
            let identity = SessionWorkspace(root.url)
            let records = sessions.map { IndexedAgentSession(session: $0, workspace: identity, isOpen: true) }
                + archived.map { IndexedAgentSession(session: $0, workspace: identity, isOpen: false) }
            do { try sessionIndex.upsert(records.filter { $0.metadata.workspace == identity }) } catch { indexIssue = error.localizedDescription }
        }
        workspace.schedulePersistence()
    }
    func snapshot() -> Data? {
        if let retainedPayload { return retainedPayload }
        return try? JSONEncoder().encode(AgentWorkspaceState(sessions: sessions, conversations: conversations, nextID: nextID, archived: archived, selectedAgentID: projectAgentID))
    }
    func restore(_ data: Data?) {
        restoring = true; shutdown()
        retainedPayload = nil; restorationIssue = nil
        runtimeStatuses = [:]; models = [:]; efforts = [:]; slashCommands=[:]; refreshingSlashCommands=[:]; history = []; historyDirectories = [:]
        let saved = data.flatMap { try? JSONDecoder().decode(AgentWorkspaceState.self, from: $0) }
        let declared = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? Int
        if let data, let declared, declared >= 3, saved == nil || ![3,4].contains(declared) || (declared == 4 && ((saved?.sessions ?? []) + (saved?.archived ?? [])).contains(where: \.needsLegacyMetadata)) {
            retainedPayload = data; restorationIssue = "Agent session data is unreadable or from a newer version; it was retained without replacement."
            sessions = []; archived = []; conversations = [:]; selectedSession = workspace.selectedSession
            restoring = false; return
        }
        if let saved, [3,4].contains(saved.version) {
            projectAgentID = saved.selectedAgentID ?? .pi
            sessions = saved.sessions; conversations = saved.conversations; archived = saved.archived
            if let root = workspace.workspace {
                let identity = SessionWorkspace(root.url)
                for i in sessions.indices { sessions[i].bind(identity) }
                for i in archived.indices { archived[i].bind(identity) }
            }
            nextID = max(saved.nextID, ((sessions + archived).map(\.id) + workspace.sessions.keys.compactMap(Int.init)).max().map { $0 + 1 } ?? 0)
            for index in sessions.indices {
                if [.running, .approval].contains(sessions[index].state) { sessions[index].state = .idle }
                sessions[index].recordAvailability(availability(sessions[index]))
            }
            for key in conversations.keys {
                for index in conversations[key]!.activities.indices where conversations[key]!.activities[index].status == .running || conversations[key]!.activities[index].status == .approval {
                    conversations[key]!.activities[index].status = .cancelled
                }
                recoverQueued(key)
                conversations[key]?.messages = conversations[key]?.messages.filter { !$0.streaming } ?? []
            }
        } else {
            projectAgentID = data != nil || workspace.restoredExistingSnapshot ? .pi : selection.globalDefault
            let id = max(0, workspace.selectedSession)
            let metadata = AgentSessionMetadata(agentID: projectAgentID, workspace: workspace.workspace.map { SessionWorkspace($0.url) })
            sessions = workspace.workspace == nil ? [] : [.init(id: id, title: "New session", metadata: metadata)]
            conversations = sessions.isEmpty ? [:] : [id: .init(permission: configuration.defaultPermission)]
            archived = []
            nextID = max(id + 1, (workspace.sessions.keys.compactMap(Int.init).max() ?? -1) + 1)
        }
        let selected = workspace.selectedSession
        selectedSession = sessions.contains(where: { $0.id == selected }) ? selected : sessions.first?.id ?? -1
        restoring = false
        persist()
        if sessions.isEmpty {
            restoring = true; newSession(); restoring = false; persist()
        }
        // Restore cached work only. Agent/provider execution begins on an explicit
        // agent action, never merely because an old workspace exists at startup.
    }
    private func recoverQueued(_ id: Int) {
        guard let queued = conversations[id]?.queued else { return }
        let draft = conversations[id]?.draft ?? ""
        conversations[id]?.draft = draft.isEmpty ? queued.text : draft + "\n\n" + queued.text
        for attachment in queued.attachments where conversations[id]?.attachments.contains(where: { $0.id == attachment.id }) != true {
            conversations[id]?.attachments.append(attachment)
        }
        conversations[id]?.queued = nil
        conversations[id]?.notice = "The previous runtime stopped. Its queued instruction was restored in the draft; send it to run again."
    }
    func workspaceClosed() { shutdown(); restoring = true; sessions = []; conversations = [:]; history = []; historyDirectories = [:]; selectedSession = -1; restoring = false }
    func newSession() {
        guard let root = workspace.workspace, retainedPayload == nil else { return }
        let id = nextID; nextID += 1
        sessions.append(.init(id: id, title: "New session", metadata: .init(agentID: projectAgentID, workspace: SessionWorkspace(root.url))))
        conversations[id] = .init(permission: configuration.defaultPermission)
        selectedSession = id
    }
    func closeSession(_ id: Int) {
        // Saved Pi JSONL and editor session remain intact. Only the open session/runtime close.
        cancelPreviewDecisions(session: id)
        slashCommands[id]=nil; refreshingSlashCommands[id]=nil
        recoverQueued(id)
        invalidateRuntime(id)
        approvals[id] = nil; editingApprovals[id] = nil
        if let closed = sessions.first(where: { $0.id == id }) { archived.removeAll { $0.id == id }; archived.append(closed) }
        sessions.removeAll { $0.id == id }
        if selectedSession == id { selectedSession = sessions.first?.id ?? -1 }
        refreshHistory()
    }
    func reopen(_ saved: SavedAgentSession) {
        guard deletingSessionPath != saved.path, retainedPayload == nil else { return }
        if let open = sessions.first(where: { $0.agentID == saved.agentID && $0.sessionFile == saved.path }) { selectedSession = open.id; return }
        if let index = archived.firstIndex(where: { $0.agentID == saved.agentID && $0.sessionFile == saved.path }) {
            var restored = archived.remove(at: index); restored.state = .idle
            sessions.append(restored); selectedSession = restored.id; return
        }
        if let record = retainedSessions().first(where: { $0.metadata.agentID == saved.agentID && $0.nativeFile == saved.path }) {
            openRetained(record); return
        }
        guard let root = workspace.workspace else { return }
        let id = nextID; nextID += 1
        sessions.append(.init(id: id, title: saved.title, backendID: saved.nativeID ?? UUID().uuidString, sessionFile: saved.path,
                              metadata: .init(id: saved.milkID ?? UUID(), agentID: saved.agentID, workspace: SessionWorkspace(root.url))))
        conversations[id] = .init(permission: configuration.defaultPermission)
        selectedSession = id
    }
    func openRetained(_ record: IndexedAgentSession) {
        guard retainedPayload == nil, let root = workspace.workspace, record.metadata.workspace == SessionWorkspace(root.url) else { return }
        if let session = sessions.first(where: { $0.metadata.id == record.id }) { selectedSession = session.id; return }
        if let i = archived.firstIndex(where: { $0.metadata.id == record.id }) {
            var session = archived.remove(at: i); session.state = .idle
            sessions.append(session); selectedSession = session.id; return
        }
        if let id = record.editorID, sessions.contains(where: { $0.id == id }) || archived.contains(where: { $0.id == id }) {
            indexIssue = "Retained editor linkage conflicts with another session; history was not reassigned."; return
        }
        let id = record.editorID ?? nextID
        nextID = max(nextID, id + 1)
        let cached = retainedConversation(record)
        sessions.append(.init(id: id, title: record.title, backendID: record.nativeID, sessionFile: record.nativeFile, metadata: record.metadata))
        conversations[id] = cached ?? .init(permission: configuration.defaultPermission)
        selectedSession = id
    }
    func discoverSavedSessions(directory: URL, agentID: AgentID) throws -> [SavedAgentSession] {
        guard let root = workspace.workspace, let history = registry.adapter(for: agentID)?.fileSessionHistory else { throw AgentError.message("The owning agent cannot import saved session files.") }
        return try history.history(workspace: root.url, directory: directory).map { value in var value = value; value.agentID = agentID; return value }
    }
    private func connect(_ id: Int) {
        run(id, markError: true) { try await self.ensureBackend(id) }
    }
    /// Explicit composer model/command discovery is agent work, unlike restoring
    /// a workspace or inspecting retained metadata. No prompt is submitted here.
    func connectForDiscovery() {
        guard currentSession != nil, unavailableReason == nil, !pendingActions.contains(selectedSession) else { return }
        if backends[selectedSession] == nil && starts[selectedSession] == nil { connect(selectedSession) }
        else { refreshSlashCommands() }
    }
    private func ensureBackend(_ id: Int) async throws {
        try checkAction(id)
        guard !terminating else { throw CancellationError() }
        if let task = starts[id] { try await task.value; try checkAction(id); return }
        if backends[id] != nil { return }
        guard let root = workspace.workspace?.url, let session = sessions.first(where: { $0.id == id }) else { throw AgentError.message("Open a project and create a session first.") }
        let status = availability(session)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].recordAvailability(status) }
        guard status.canAttemptResume, let owner = registry.adapter(for: session.agentID) else { throw AgentError.message(status.detail) }
        let context = AgentBackendContext(permission: conversations[id]?.permission ?? configuration.defaultPermission, lifecycle: lifecycle)
        let generation = workspaceGeneration
        let activation = AgentActivation(agentID: session.agentID, workspace: root, sessionID: id)
        backendTokens[id] = activation
        let savedModel = conversations[id]?.modelID, savedEffort = conversations[id]?.effort
        let lease = lifecycle.beginBackend(activation: activation, purpose: .conversation,
                                    writers: AgentWriterKey.session(session, agent: session.agentID, workspace: root),
                                    factory: { owner.makeBackend(context: context) }) { backend, lease in
            try lease.check()
            guard self.workspaceGeneration == generation, self.backendTokens[id] == activation else { throw CancellationError() }
            self.backends[id] = backend
            backend.onEvent = { [weak self, weak lease] event in
                guard let self, lease?.valid == true, self.workspaceGeneration == generation,
                      self.backendTokens[id] == activation, self.sessions.contains(where: { $0.id == id }) else { return }
                self.receive(event, session: id)
            }
            try await backend.start(workspace: root, session: session)
            try lease.check()
            if let savedModel, let model = self.models[id]?.first(where: { $0.id == savedModel }) { try await backend.setModel(model) }
            try lease.check()
            if let savedEffort, let modelID = self.conversations[id]?.modelID, self.efforts[id]?[modelID]?.contains(savedEffort) == true { try await backend.setEffort(savedEffort) }
        }
        leases[id] = lease; starts[id] = lease.work
        do {
            try await lease.work.value
            try checkAction(id)
            if backendTokens[id] == activation { starts[id] = nil }
        } catch {
            if backendTokens[id] == activation {
                backends[id]?.onEvent = nil; starts[id] = nil; backends[id] = nil
                dropRuntimeDialogs(id)
            }
            // Retained by the coordinator if exit cannot be confirmed.
            try await lifecycle.stopAndWait(lease)
            throw error
        }
    }
    private func actionIsCurrent(_ id: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let context = AgentActionOwnership.current else { return true }
        return context.workspace == workspaceGeneration && context.session == id && actionTokens[id] == context.token
    }
    private func checkAction(_ id: Int) throws {
        guard actionIsCurrent(id) else { throw CancellationError() }
    }
    private func run(_ id: Int, markError: Bool = false, operation: @escaping () async throws -> Void) {
        let token = UUID()
        if actionTokens[id] == nil { actionTokens[id] = UUID() }
        let context = AgentActionContext(workspace: workspaceGeneration, session: id, token: actionTokens[id]!)
        let task = Task { [weak self] in
            await AgentActionOwnership.$current.withValue(context) {
                do { try self?.checkAction(id); try await operation() }
                catch is CancellationError { }
                catch {
                    if let self, self.actionIsCurrent(id), self.sessions.contains(where: { $0.id == id }) {
                        self.conversations[id, default: .init()].error = error.localizedDescription
                        if markError { self.setState(.error, id: id) }
                    }
                }
            }
            self?.actionTasks[token] = nil; self?.actionSessions[token] = nil
        }
        actionTasks[token] = task; actionSessions[token] = id
    }
    private func dropRuntimeDialogs(_ id: Int) {
        approvals[id] = approvals[id]?.filter { previewDecisions[$0.id] != nil || extensionDecisions[$0.id] != nil } ?? []
        if let editor = editingApprovals[id], previewDecisions[editor.id] == nil && extensionDecisions[editor.id] == nil { editingApprovals[id] = nil }
    }
    private func invalidateRuntime(_ id: Int) {
        recoverQueued(id)
        backendTokens[id] = nil; actionTokens[id] = UUID()
        for (key, session) in actionSessions where session == id { actionTasks[key]?.cancel() }
        starts.removeValue(forKey: id)?.cancel()
        backends.removeValue(forKey: id)?.onEvent = nil
        if let lease = leases.removeValue(forKey: id) { lifecycle.stop(lease) }
        slashCommands[id] = nil; refreshingSlashCommands[id] = nil
        dropRuntimeDialogs(id)
        realQueue[id] = nil; pendingActions.remove(id); runningSessions.remove(id)
        for index in conversations[id, default: .init()].messages.indices {
            conversations[id]?.messages[index].streaming = false
            if let blocks = conversations[id]?.messages[index].blocks { conversations[id]?.messages[index].blocks = blocks.map { var block = $0; block.streaming = false; return block } }
        }
    }
    func discoverPreview(root: URL) async throws -> PreviewConfiguration {
        guard !terminating, workspace.workspace?.url == root else { throw CancellationError() }
        let generation = workspaceGeneration
        guard let adapter else { throw AgentError.message("The selected agent is unavailable for Preview inspection.") }
        let result = try await adapter.discoverPreview(root: root, model: selectedModel, lifecycle: lifecycle)
        try Task.checkCancellation()
        guard workspaceGeneration == generation else { throw CancellationError() }
        return result
    }
    func submit() {
        let id = selectedSession, text = current.draft
        guard !busy, !pendingActions.contains(id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attachments = current.attachments
        pendingActions.insert(id)
        run(id, markError: true) {
            defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }
            try await self.ensureBackend(id)
            self.conversations[id]?.error = nil; self.conversations[id]?.changes = []
            // Pi's message_start event is the authoritative user transcript entry.
            try await self.backends[id]?.send(.init(text: text, attachments: attachments), intent: .prompt)
            try self.checkAction(id)
            if self.conversations[id]?.draft == text { self.conversations[id]?.draft = ""; self.conversations[id]?.attachments = [] }
        }
    }
    /// Explicitly validated RPC resource command. Attached files remain available for the next normal prompt.
    func submitSlashCommand(_ text: String, name: String) {
        let id=selectedSession, original=current.draft
        guard !busy, !pendingActions.contains(id) else { return }
        pendingActions.insert(id)
        run(id,markError:true) {
            defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }
            try await self.ensureBackend(id)
            guard self.slashCommands[id]?.contains(where:{ $0.name == name && $0.source != nil }) == true else { throw AgentError.message("Command is no longer available: /"+name) }
            try await self.backends[id]?.send(.init(text:text,attachments:[]),intent:.prompt)
            try self.checkAction(id)
            if self.conversations[id]?.draft == original { self.conversations[id]?.draft="" }
        }
    }
    func refreshSlashCommands() {
        let id=selectedSession
        guard capabilities.contains(.slashCommands), refreshingSlashCommands[id] == nil, let backend=backends[id] else { return }
        let generation=workspaceGeneration, token=backendTokens[id]
        let request=UUID()
        refreshingSlashCommands[id]=request
        run(id) {
            defer { if self.refreshingSlashCommands[id] == request { self.refreshingSlashCommands[id]=nil } }
            do { try await backend.refreshCommands() }
            catch {
                if self.workspaceGeneration == generation && self.backendTokens[id] == token { self.slashCommands[id]=[] }
            }
        }
    }
    func queueOrSteer() {
        let id = selectedSession
        guard capabilities.contains(current.queued == nil ? .followUpQueue : .steering), busy, !pendingActions.contains(id), let backend = backends[id] else { return }
        pendingActions.insert(id)
        if let queued = current.queued {
            run(id) {
                defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }
                try await backend.steerQueued(queued.prompt)
                try self.checkAction(id)
                self.conversations[id]?.notice = "Steering is delivered after the current tool calls, before Pi's next model turn."
            }
        } else {
            let prompt = StoredPrompt(text: current.draft, attachments: current.attachments)
            guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pendingActions.remove(id); return }
            run(id) {
                defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }
                try await backend.send(prompt.prompt, intent: .followUp)
                // queue_update may already have delivered/dequeued this very fast.
                try self.checkAction(id)
                if self.realQueue[id]?.isEmpty == false { self.conversations[id]?.queued = prompt }
                try self.checkAction(id)
            if self.conversations[id]?.draft == prompt.text { self.conversations[id]?.draft = ""; self.conversations[id]?.attachments = [] }
            }
        }
    }
    func cancelQueue() {
        let id = selectedSession
        run(id) { try await self.backends[id]?.clearQueue(); try self.checkAction(id); self.conversations[id]?.queued = nil }
    }
    func stop() {
        let id = selectedSession
        run(id) { guard let backend = self.backends[id] else { throw AgentError.message("Pi is disconnected; cancellation could not be sent.") }; try await backend.stop() }
    }
    func selectModel(_ id: String) {
        let session = selectedSession
        guard capabilities.contains(.models), let model = models[session]?.first(where: { $0.id == id }), !pendingActions.contains(session) else { return }
        pendingActions.insert(session)
        run(session) { defer { if self.actionIsCurrent(session) { self.pendingActions.remove(session) } }; try await self.ensureBackend(session); try await self.backends[session]?.setModel(model) }
    }
    func selectEffort(_ effort: String) {
        let id = selectedSession
        guard capabilities.contains(.reasoningLevels), let modelID = current.modelID, efforts[id]?[modelID]?.contains(effort) == true, !pendingActions.contains(id) else { return }
        pendingActions.insert(id)
        run(id) { defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }; try await self.backends[id]?.setEffort(effort) }
    }
    func setPermission(_ mode: ComposerPermissionMode) {
        let id = selectedSession
        guard !pendingActions.contains(id) else { return }
        pendingActions.insert(id)
        run(id) {
            defer { if self.actionIsCurrent(id) { self.pendingActions.remove(id) } }
            try await self.ensureBackend(id); try await self.backends[id]?.setPermission(mode)
            try self.checkAction(id)
            self.conversations[id]?.permission = mode
        }
    }
    func rename(_ id: Int, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        run(id) { try await self.ensureBackend(id); try await self.backends[id]?.rename(value) }
    }
    func respond(_ request: AgentApproval, session id: Int, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
        if respondToExtension(request,session:id,value:value,cancelled:cancelled) { return }
        if respondToPreview(request, session: id, value: value, cancelled: cancelled) { return }
        guard let backend = backends[id], request.activation == backendTokens[id],
              leases[id]?.valid == true,
              approvals[id]?.contains(request) == true || editingApprovals[id] == request else { return }
        do {
            if value == "Edit Command" { editingApprovals[id] = request }
            try backend.respond(request, value: value, confirmed: confirmed, cancelled: cancelled)
        } catch { editingApprovals[id] = nil; conversations[id]?.error = error.localizedDescription }
    }
    private var refreshingSlashCommands: [Int:UUID] = [:]
    private var realQueue: [Int: [String]] = [:]
    private func receive(_ event: AgentEvent, session id: Int) {
        switch event {
        case .historyBegin: conversations[id]?.messages = []; conversations[id]?.activities = []
        case .started: runningSessions.insert(id); conversations[id]?.error = nil; setState(.running, id: id)
        case .settled(let aborted):
            runningSessions.remove(id)
            if conversations[id]?.error == nil { setState(id == selectedSession || aborted ? .idle : .unread, id: id) }
            for index in conversations[id, default: .init()].messages.indices {
                conversations[id]?.messages[index].streaming = false
                if let blocks = conversations[id]?.messages[index].blocks { conversations[id]?.messages[index].blocks = blocks.map { var block = $0; block.streaming = false; return block } }
            }
            conversations[id]?.queued = nil; realQueue[id] = []
            approvals[id] = approvals[id]?.filter { previewDecisions[$0.id] != nil || extensionDecisions[$0.id] != nil } ?? []
            if editingApprovals[id].map({ previewDecisions[$0.id] == nil }) == true { editingApprovals[id] = nil }
            if approvals[id]?.isEmpty == false || editingApprovals[id] != nil { setState(.approval, id: id) }
            if aborted { conversations[id]?.notice = "Cancelled" }
            workspace.refresh(); workspace.checkExternalChanges(); refreshHistory()
        case .message(let message):
            if let index = conversations[id]?.messages.firstIndex(where: { $0.id == message.id }) { conversations[id]?.messages[index] = message }
            else { conversations[id, default: .init()].messages.append(message) }
        case .contentDelta(let delta):
            if let index = conversations[id]?.messages.firstIndex(where: { $0.id == delta.messageID }) { conversations[id]?.messages[index].apply(delta) }
        case .activity(let activity):
            if let index = conversations[id]?.activities.firstIndex(where: { $0.id == activity.id }) { conversations[id]?.activities[index] = activity }
            else { conversations[id, default: .init()].activities.append(activity) }
        case .changes(let files): conversations[id]?.changes = files
        case .approval(var approval):
            approval.activation = backendTokens[id]
            if approval.method == .editor { editingApprovals[id] = nil }
            approvals[id, default: []].append(approval); setState(.approval, id: id)
        case .dismissApproval(let key): approvals[id]?.removeAll { $0.id == key }; if approvals[id]?.isEmpty != false && editingApprovals[id] == nil { setState(.running, id: id) }
        case .queue(let follow, let steering):
            realQueue[id] = follow
            if follow.isEmpty { conversations[id]?.queued = nil }
            if !steering.isEmpty { conversations[id]?.notice = "Steering queued for Pi's next model turn." }
        case .state(let snapshot):
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].sessionFile = snapshot.sessionFile
                if let uuid = snapshot.sessionID { sessions[index].backendID = uuid }
                if let name = snapshot.name { sessions[index].title = name }
                if snapshot.running { runningSessions.insert(id); sessions[index].state = .running } else { runningSessions.remove(id) }
            }
            if let session = sessions.first(where: { $0.id == id }), let lease = leases[id], let root = workspace.workspace?.url {
                lifecycle.addWriters(AgentWriterKey.session(session, agent: session.agentID, workspace: root), to: lease)
            }
            conversations[id]?.modelID = snapshot.model?.id; conversations[id]?.effort = snapshot.effort
        case .slashCommands(let commands): slashCommands[id]=commands
        case .models(let values): models[id] = values
        case .extensionProblem(let text): onExtensionProblem?(text)
        case .efforts(let values, let selected):
            if let modelID = conversations[id]?.modelID { efforts[id, default: [:]][modelID] = values; conversations[id]?.effort = values.contains(selected ?? "") ? selected : values.first }
        case .sessionDirectory(let url): if let session = sessions.first(where: { $0.id == id }) { historyDirectories[session.agentID] = url }; refreshHistory()
        case .sessionName(let title): if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].title = title; sessions[i].recordModified() }
        case .notice(let text): conversations[id]?.notice = text
        case .failure(let text): conversations[id]?.error = text; setState(.error, id: id)
        case .runtime(let status):
            if status.phase == .starting || status.phase == .failed || status.phase == .stopped { slashCommands[id]=nil }
            runtimeStatuses[id] = status
            if status.phase == .ready, let i = sessions.firstIndex(where: { $0.id == id }), let owner = registry.adapter(for: sessions[i].agentID) {
                sessions[i].recordRuntime(status, adapterVersion: owner.descriptor.adapterVersion)
            }
            if status.phase == .failed {
                approvals[id] = approvals[id]?.filter { previewDecisions[$0.id] != nil || extensionDecisions[$0.id] != nil } ?? []
                dropRuntimeDialogs(id)
                runningSessions.remove(id); recoverQueued(id)
                for index in conversations[id, default: .init()].activities.indices where [.running, .approval].contains(conversations[id]!.activities[index].status) && !conversations[id]!.activities[index].id.hasPrefix("preview-") {
                    conversations[id]?.activities[index].status = .error
                    conversations[id]?.activities[index].output += "\nRuntime stopped: " + status.detail
                }
                for index in conversations[id, default: .init()].messages.indices {
                    conversations[id]?.messages[index].streaming = false
                    if let blocks = conversations[id]?.messages[index].blocks { conversations[id]?.messages[index].blocks = blocks.map { var block = $0; block.streaming = false; return block } }
                }
                invalidateRuntime(id)
                conversations[id]?.error = status.detail
                setState(approvals[id]?.isEmpty == false || editingApprovals[id] != nil ? .approval : .error, id: id)
            }
        }
    }
    private func setState(_ state: AgentSession.State, id: Int) { if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].state = state } }
    func refreshHistory() {
        guard let root = workspace.workspace?.url else { return }
        let generation = workspaceGeneration, revision = UUID()
        historyRevision = revision
        let sources = historyDirectories.compactMap { id, directory -> (AgentID, URL, any AgentFileSessionHistory)? in
            registry.adapter(for: id)?.fileSessionHistory.map { (id, directory, $0) }
        }
        Task {
            var values: [SavedAgentSession] = []
            for (id, directory, service) in sources {
                let found = await Task.detached(priority: .utility) { try? service.history(workspace: root, directory: directory) }.value ?? []
                values += found.map { item in var item = item; item.agentID = id; item.workspace = root; return item }
            }
            guard workspaceGeneration == generation, historyRevision == revision else { return }
            history = values
            do { try sessionIndex.discover(values, workspace: SessionWorkspace(root)) } catch { indexIssue = error.localizedDescription }
        }
    }
    func restart() {
        let id = selectedSession
        guard !terminating, sessions.contains(where: { $0.id == id }) else { return }
        recoverQueued(id)
        do { try workspace.persistNow() } catch { conversations[id]?.error = error.localizedDescription; return }
        invalidateRuntime(id)
        conversations[id]?.error = nil
        setState(approvals[id]?.isEmpty == false || editingApprovals[id] != nil ? .approval : .idle, id: id)
        connect(id)
    }
    var configurationChangeUnavailable: String? {
        starts.isEmpty && pendingActions.isEmpty && runningSessions.isEmpty && !sessions.contains(where: { [.running,.approval].contains($0.state) }) ? nil : "Stop running sessions and finish pending approvals before reconnecting Pi."
    }
    func updateDefaultPermission(_ mode: ComposerPermissionMode) throws {
        var value=configuration; value.defaultPermission=mode
        try value.save(defaults); configuration=value
    }
    func reconnectIdleRuntimes() throws {
        if let reason=configurationChangeUnavailable { throw AgentError.message(reason) }
        try updateConfiguration(configuration)
    }
    /// Called inside the installation admission barrier. Recover/persist drafts before
    /// stopping owned work; retained session IDs, native files and caches are untouched.
    func prepareForInstallationChange() throws {
        for session in sessions where session.agentID == .pi { recoverQueued(session.id) }
        try workspace.persistNow()
        for session in sessions where session.agentID == .pi {
            invalidateRuntime(session.id)
            setState(.idle, id: session.id)
        }
        runtimeStatuses = [:]; models = [:]; efforts = [:]; slashCommands = [:]; refreshingSlashCommands = [:]
    }
    func updateConfiguration(_ configuration: AgentConfiguration) throws {
        guard !terminating, pendingActions.subtracting(Set(starts.keys)).isEmpty, runningSessions.isEmpty, !sessions.contains(where: { [.running, .approval].contains($0.state) }) else { throw AgentError.message("Stop running sessions before changing runtime/provider configuration.") }
        try persistAgentSettings { try configuration.save(defaults); self.configuration = configuration }
    }
    /// Adapters validate/persist their own settings inside the lifecycle admission check.
    func applyAgentSettings(_ persistSettings: () throws -> Void) throws {
        guard !terminating else { throw AgentError.message("Milk is shutting down.") }
        guard !lifecycle.owned.values.contains(where: { $0.valid && $0.purpose != .conversation }) else { throw AgentError.message("Wait for agent inspection or maintenance to finish before changing settings.") }
        if let reason = configurationChangeUnavailable { throw AgentError.message(reason) }
        try persistAgentSettings(persistSettings)
    }
    /// Runtime selection may cancel a pending start under its existing stricter
    /// running/approval guard; provider edits require a fully idle runtime above.
    private func persistAgentSettings(_ persistSettings: () throws -> Void) throws {
        try workspace.persistNow()
        try persistSettings()
        for id in sessions.map(\.id) { invalidateRuntime(id) }
        lifecycle.invalidateAll()
        for id in conversations.keys { conversations[id]?.error = nil }
        runtimeStatuses = [:]; models = [:]; efforts = [:]; slashCommands=[:]; refreshingSlashCommands=[:]
        for index in sessions.indices where sessions[index].state == .error { sessions[index].state = .idle }
        if selectedSession >= 0, unavailableReason == nil { connect(selectedSession) }
    }
    /// App termination waits for conversation, pending and auxiliary resources.
    func shutdownAndWait() async -> Bool {
        terminating = true
        shutdown()
        return await lifecycle.shutdownAndWait()
    }
    func shutdown() {
        for id in sessions.map(\.id) { invalidateRuntime(id) }
        lifecycle.invalidateAll()
        slashCommands=[:]; refreshingSlashCommands=[:]
        cancelPreviewDecisions(); previewAllowances = []; previewActivitySessions = [:]
        workspaceGeneration = UUID(); backendTokens = [:]; actionTokens = [:]
        for task in actionTasks.values { task.cancel() }; actionTasks = [:]; actionSessions = [:]
        starts = [:]; backends = [:]; leases = [:]
        approvals = [:]; editingApprovals = [:]; realQueue = [:]; pendingActions = []; runningSessions = []
    }
}


// Preview uses the same request model, permission mode, nonmodal popup and command editor as Pi.
@MainActor extension AgentService {
    private func previewAllowanceKey(_ config: PreviewConfiguration, session: Int) -> String {
        "\(session)\n\(workspace.workspace?.url.path ?? "")\n\(config.directory.path)\n\(config.kind.rawValue)\n\(config.command)"
    }
    func authorizePreview(_ config: PreviewConfiguration) async throws -> PreviewConfiguration {
        let id = selectedSession
        guard sessions.contains(where: { $0.id == id }) else { throw AgentError.message("Create or select a Pi session to approve Preview startup.") }
        if current.permission == .autonomous || previewAllowances.contains(previewAllowanceKey(config, session: id)) { return config }
        let key = "milk-preview-" + UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                previewDecisions[key] = .init(session: id, configuration: config, continuation: continuation)
                let command = config.kind == .staticFiles ? "Milk static preview · " + config.entryPath : config.command
                approvals[id, default: []].append(.init(id: key, method: .select, title: "Start project Preview", message: "", options: config.kind == .staticFiles ? ["Deny", "Allow Once", "Allow for Session"] : ["Deny", "Edit Command", "Allow Once", "Allow for Session"], tool: "bash", command: command, workingDirectory: config.directory.path, reason: "Start the project's Preview server.", effect: config.kind == .staticFiles ? "Serve project files read-only on loopback until Stop or workspace close." : "Execute this command with your user permissions until Stop or workspace close.", origin: .milkPreview))
                setState(.approval, id: id)
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.finishPreviewDecision(key, result: .failure(CancellationError())) } })
    }
    private func respondToPreview(_ request: AgentApproval, session: Int, value: String?, cancelled: Bool) -> Bool {
        guard var decision = previewDecisions[request.id], decision.session == session else { return false }
        if !cancelled, value == "Edit Command" {
            approvals[session]?.removeAll { $0.id == request.id }
            var editor = request; editor.method = .editor; editor.prefill = decision.configuration.command
            editingApprovals[session] = editor
            return true
        }
        if cancelled || value == "Deny" { finishPreviewDecision(request.id, result: .failure(AgentError.message("Preview startup was denied."))); return true }
        if request.method == .editor, let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { decision.configuration.command = value }
        else if !["Allow Once", "Allow for Session"].contains(value ?? "") { return true }
        if value == "Allow for Session" { previewAllowances.insert(previewAllowanceKey(decision.configuration, session: session)) }
        finishPreviewDecision(request.id, result: .success(decision.configuration)); return true
    }
    private func finishPreviewDecision(_ key: String, result: Result<PreviewConfiguration, Error>) {
        guard let decision = previewDecisions.removeValue(forKey: key) else { return }
        approvals[decision.session]?.removeAll { $0.id == key }
        if editingApprovals[decision.session]?.id == key { editingApprovals[decision.session] = nil }
        if approvals[decision.session]?.isEmpty != false, editingApprovals[decision.session] == nil { setState(runningSessions.contains(decision.session) ? .running : .idle, id: decision.session) }
        decision.continuation.resume(with: result)
    }
    private func cancelPreviewDecisions(session: Int? = nil) {
        cancelExtensionDecisions(session:session)
        for key in Array(previewDecisions.keys) where session == nil || previewDecisions[key]?.session == session {
            finishPreviewDecision(key, result: .failure(CancellationError()))
        }
    }
    func recordPreviewActivity(id: String, output: String, status: AgentActivity.Status) {
        let session = previewActivitySessions[id] ?? selectedSession
        guard conversations[session] != nil else { return }
        previewActivitySessions[id] = session
        if let index = conversations[session]?.activities.firstIndex(where: { $0.id == id }) {
            conversations[session]?.activities[index].output = String(output.suffix(262144))
            conversations[session]?.activities[index].status = status
        } else {
            conversations[session]?.activities.append(.init(id: id, kind: "Command", detail: "Project Preview", afterMessageID: conversations[session]?.messages.last?.id, output: String(output.suffix(262144)), status: status))
        }
    }
}


@MainActor extension AgentService {
    func authorizeExtensionAction(owner: String, action: String, workspace root: URL?, session: Int?) async throws {
        let id=session ?? selectedSession
        guard workspace.workspace?.url == root, sessions.contains(where:{ $0.id == id }) else { throw AgentError.message("Extension workspace/session is unavailable.") }
        if (conversations[id]?.permission ?? configuration.defaultPermission) == .autonomous { return }
        let key="milk-extension-"+UUID().uuidString
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                extensionDecisions[key] = .init(session:id,owner:owner,continuation:continuation)
                approvals[id,default:[]].append(.init(id:key,method:.select,title:"Extension approval · "+owner,message:action,options:["Deny","Allow Once"],tool:owner,action:action,workingDirectory:root?.path,reason:"An installed Milk Extension requested this action.",effect:"Run with Milk's user permissions.",origin:.milkExtension))
                setState(.approval,id:id)
            }
        },onCancel:{ [weak self] in Task { @MainActor in self?.finishExtensionDecision(key,allowed:false) } })
    }
    private func respondToExtension(_ request: AgentApproval, session: Int, value: String?, cancelled: Bool) -> Bool {
        guard extensionDecisions[request.id]?.session == session else { return false }
        finishExtensionDecision(request.id,allowed:!cancelled && value == "Allow Once"); return true
    }
    private func finishExtensionDecision(_ key: String, allowed: Bool) {
        guard let decision=extensionDecisions.removeValue(forKey:key) else { return }
        approvals[decision.session]?.removeAll { $0.id == key }
        if approvals[decision.session]?.isEmpty != false { setState(runningSessions.contains(decision.session) ? .running:.idle,id:decision.session) }
        if allowed { decision.continuation.resume() } else { decision.continuation.resume(throwing:AgentError.message("Extension action denied or cancelled.")) }
    }
    private func cancelExtensionDecisions(session: Int? = nil) {
        for (key,decision) in extensionDecisions where session == nil || decision.session == session { finishExtensionDecision(key,allowed:false) }
    }
}
