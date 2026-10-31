import Foundation

struct AgentSession: Identifiable, Codable {
    enum State: String, Codable { case running = "Running", idle = "Idle", approval = "Needs approval", error = "Error", unread = "Finished unread" }
    let id: Int // Compatibility mapping into WorkspaceStore's editor sessions.
    var title: String
    var state: State
    var backendID: String
    var sessionFile: String?
    private(set) var metadata: AgentSessionMetadata
    private var legacyIdentity = false
    var agentID: AgentID { metadata.agentID }
    var needsLegacyMetadata: Bool { legacyIdentity }
    init(id: Int, title: String, state: State = .idle, backendID: String = UUID().uuidString,
         sessionFile: String? = nil, metadata: AgentSessionMetadata = .init()) {
        self.id = id; self.title = title; self.state = state; self.backendID = backendID
        self.sessionFile = sessionFile; self.metadata = metadata
    }
    private enum CodingKeys: String, CodingKey { case id, title, state, backendID, sessionFile, metadata }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        state = try values.decode(State.self, forKey: .state); backendID = try values.decode(String.self, forKey: .backendID)
        sessionFile = try values.decodeIfPresent(String.self, forKey: .sessionFile)
        if let saved = try values.decodeIfPresent(AgentSessionMetadata.self, forKey: .metadata) { metadata = saved }
        else { metadata = .init(agentID: .pi, createdAt: nil); legacyIdentity = true }
    }
    mutating func bind(_ workspace: SessionWorkspace) {
        if legacyIdentity {
            metadata = .init(id: AgentSessionMetadata.stableID(["legacy", metadata.agentID.rawValue, workspace.id, String(id), backendID, sessionFile ?? ""]),
                             agentID: metadata.agentID, workspace: workspace, createdAt: nil)
            legacyIdentity = false
        }
        metadata.bind(workspace)
    }
    mutating func recordAvailability(_ value: SessionAvailability) { metadata.availability = value }
    mutating func recordModified() { metadata.modifiedAt = .now }
    mutating func recordRuntime(_ status: RuntimeStatus, adapterVersion: String) {
        metadata.lastUsedAt = .now; metadata.lastRuntimeVersion = status.version
        metadata.lastAdapterVersion = adapterVersion
        metadata.lastInstallationID = status.runtimeIdentity?.installation?.id
        metadata.dataProfileDirectory = status.dataProfile?.directory
        metadata.availability = .init(state: .available, detail: "Connected to the owning agent.")
    }
}

struct AgentMessage: Identifiable, Codable, Equatable {
    var id: String
    var role: String
    var text: String
    var streaming = false
    var blocks: [AgentContentBlock]?
}
struct AgentActivity: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case running, completed, error, cancelled, approval }
    var id: String
    var kind: String
    var detail: String
    var afterMessageID: String?
    var output = ""
    var status: Status = .running
    var started = Date()
    var duration: Double?
}
struct AgentFileChange: Identifiable, Codable, Equatable {
    var id: String { path }
    var path: String
    var kind: String
    var added: Int?
    var removed: Int?
}
struct PromptAttachment: Identifiable, Codable, Equatable {
    var id: String { url.path }
    var url: URL
    var projectFile: Bool
}
struct AgentPrompt {
    var text: String
    var attachments: [PromptAttachment] = []
}
struct AgentModel: Identifiable, Equatable {
    var id: String { provider + "/" + modelID }
    var provider: String
    var modelID: String
    var name: String
    var supportsImages: Bool
}
struct AgentSnapshot {
    var sessionFile: String?
    var sessionID: String?
    var name: String?
    var model: AgentModel?
    var effort: String?
    var running: Bool
}
struct AgentApproval: Identifiable, Equatable {
    var id: String
    var method: AgentDialogMethod
    var title: String
    var message: String
    var options: [String] = []
    var prefill: String = ""
    var timeout: Double?
    var activityID: String?
    var tool: String?
    var action: String?
    var command: String?
    var workingDirectory: String?
    var reason: String?
    var effect: String?
    var risk: String?
    var origin: AgentDialogOrigin = .agentExtension
    var activation: AgentActivation? = nil
}
struct AgentCommand: Identifiable, Equatable {
    enum Source: String { case `extension`, prompt, skill }
    struct SourceInfo: Equatable {
        var path: String?, source: String?, scope: String?, origin: String?, baseDir: String?
    }
    var id: String { name }
    let name: String
    let description: String?
    var source: Source? = .extension
    var sourceInfo: SourceInfo? = nil

}
enum AgentEvent {
    case slashCommands([AgentCommand])
    case historyBegin
    case started, settled(aborted: Bool)
    case message(AgentMessage), contentDelta(AgentContentDelta)
    case activity(AgentActivity)
    case changes([AgentFileChange])
    case approval(AgentApproval), dismissApproval(String)
    case queue(followUp: [String], steering: [String])
    case state(AgentSnapshot), models([AgentModel]), efforts([String], selected: String?)
    case sessionDirectory(URL), sessionName(String)
    case notice(String), failure(String), runtime(RuntimeStatus), extensionProblem(String)
}
struct RuntimeStatus: Equatable {
    typealias Phase = AgentConnectionPhase
    var phase: Phase
    var version: String?
    var bundled: Bool
    var detail: String
    var runtimeIdentity: AgentRuntimeIdentity? = nil
    var compatibility: AgentCompatibilityResult? = nil
    var dataProfile: AgentDataProfile? = nil
}

/// UI and workspace code consume only Milk domain models.
@MainActor protocol AgentBackend: AgentOwnedResource {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    func start(workspace: URL, session: AgentSession) async throws
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws
    func stop() async throws
    func clearQueue() async throws
    func steerQueued(_ prompt: AgentPrompt) async throws
    func setModel(_ model: AgentModel) async throws
    func setEffort(_ effort: String) async throws
    func setPermission(_ mode: ComposerPermissionMode) async throws
    func rename(_ title: String) async throws
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws
    func refreshCommands() async throws
    func shutdown()
    /// Return only after this backend can no longer write its session file.
    func shutdownAndWait() async throws
}

// Backends without dynamic command discovery report no extra catalog.
extension AgentBackend {
    func refreshCommands() async throws {}
    func send(_ prompt: AgentPrompt) async throws { try await send(prompt, intent: .prompt) }
    // Existing presentation call sites remain unchanged while the backend contract is typed.
    func respond(_ approval: AgentApproval, value: String?, confirmed: Bool?, cancelled: Bool) throws {
        let response: AgentDialogResponse
        if cancelled { response = .cancelled }
        else if let value { response = .value(value) }
        else if let confirmed { response = .confirmed(confirmed) }
        else { response = .cancelled }
        try respond(approval, response: response)
    }
}

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// JSON exists only at the Pi/HTTP boundaries, never in SwiftUI components.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var text: String { string ?? array.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n") }
    var encodedString: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }
}
