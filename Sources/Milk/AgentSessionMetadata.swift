import Foundation
import CryptoKit

struct SessionWorkspace: Codable, Equatable, Hashable {
    let id: String
    let url: URL
    init(_ url: URL) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        id = SHA256.hash(data: Data(self.url.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
enum SessionAvailabilityState: String, Codable {
    case unverified, available, agentUnavailable, runtimeUnavailable, incompatibleRuntime
    case authenticationRequired, missingData, unsupportedFormat, invalidData, workspaceUnavailable
}
struct SessionAvailability: Codable, Equatable {
    var state: SessionAvailabilityState = .unverified
    var detail = "Resume has not been verified."
    var canAttemptResume: Bool { state == .unverified || state == .available }
}

struct AgentSessionMetadata: Codable, Equatable {
    let id: UUID
    let agentID: AgentID
    private(set) var workspace: SessionWorkspace?
    var createdAt: Date?
    var modifiedAt: Date?
    var lastUsedAt: Date?
    var availability = SessionAvailability()
    var lastRuntimeVersion: String?
    var lastAdapterVersion: String?
    // Associations are diagnostic/resume hints, never authority to mutate a profile.
    var lastInstallationID: AgentInstallationID?
    var dataProfileDirectory: URL?

    init(id: UUID = UUID(), agentID: AgentID = .pi, workspace: SessionWorkspace? = nil, createdAt: Date? = .now) {
        self.id = id; self.agentID = agentID; self.workspace = workspace
        self.createdAt = createdAt; modifiedAt = createdAt
    }
    mutating func bind(_ workspace: SessionWorkspace) { if self.workspace == nil { self.workspace = workspace } }
    static func stableID(_ components: [String]) -> UUID {
        // Length-safe encoding avoids path/native-ID separator collisions.
        let bytes = try! JSONEncoder().encode(components)
        var hash = Array(SHA256.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50; hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
    }
}

/// A small global preference; production only registers/selects Pi in this phase.
@MainActor struct AgentSelectionPreferences {
    static let key = "Milk.agents.default.v1"
    let defaults: UserDefaults
    let registry: AgentRegistry
    var globalDefault: AgentID {
        defaults.string(forKey: Self.key).map { AgentID(rawValue: $0) } ?? registry.defaultAgentID
    }
    func setGlobalDefault(_ id: AgentID) throws {
        guard registry.adapter(for: id) != nil else { throw AgentError.message("This agent is not registered.") }
        defaults.set(id.rawValue, forKey: Self.key)
    }
}
