import Foundation

// Durable configuration only. Live identities, approvals and grants deliberately are not Codable.
enum SandboxFolderAccess: String, Codable, CaseIterable {
    case readOnly, readWrite
    var title: String { self == .readOnly ? "Read Only" : "Read & Write" }
    func permits(_ action: SandboxFileAction) -> Bool { action == .read || self == .readWrite }
}
enum SandboxFileAction: String { case read, write, delete }
struct SandboxFolderGrant: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var url: URL
    var access: SandboxFolderAccess = .readOnly
}
struct SandboxProtectedLocation: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var url: URL
}
struct SandboxProjectConfiguration: Codable, Equatable {
    var access: SandboxFolderAccess = .readWrite
    var allowedFolders: [SandboxFolderGrant] = []
}
struct SandboxConfiguration: Codable, Equatable {
    var version = 1
    var enabled = true
    var globalAllowedFolders: [SandboxFolderGrant] = []
    var protectedLocations: [SandboxProtectedLocation]
    var autonomousTimeoutSeconds: Double = 30
    var projects: [String: SandboxProjectConfiguration] = [:]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        protectedLocations = Self.recommendedLocations(home: home)
    }
    static func recommendedLocations(home: URL) -> [SandboxProtectedLocation] {
        [".ssh", ".gnupg", "Library/Keychains", "Library/Safari", "Library/Containers/com.apple.Safari",
         "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox"].map {
            .init(id: "recommended:" + $0, url: home.appendingPathComponent($0))
        }
    }
    enum CodingKeys: String, CodingKey { case version, enabled, globalAllowedFolders, protectedLocations, autonomousTimeoutSeconds, projects }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        globalAllowedFolders = try c.decodeIfPresent([SandboxFolderGrant].self, forKey: .globalAllowedFolders) ?? []
        // Missing registry is a pre-sandbox settings migration; [] means the user removed every entry.
        protectedLocations = try c.decodeIfPresent([SandboxProtectedLocation].self, forKey: .protectedLocations)
            ?? Self.recommendedLocations(home: decoder.userInfo[.sandboxHome] as? URL ?? FileManager.default.homeDirectoryForCurrentUser)
        autonomousTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .autonomousTimeoutSeconds) ?? 30
        projects = try c.decodeIfPresent([String: SandboxProjectConfiguration].self, forKey: .projects) ?? [:]
    }
}

enum SandboxSubject { case agentRuntime, executor, extensionWorker }
enum SandboxEnvironmentDomain {
    case agentRuntime, milkExecutor, milkExtensionWorker
    // Interface for later launchers, not environment construction or a broker.
    var mayReceiveConfiguredProviderCredential: Bool { self == .agentRuntime }
    var requiresIndependentSanitizedEnvironment: Bool { self != .agentRuntime }
}
struct SandboxProfileRoot: Equatable {
    enum Ownership { case managed, existing }
    let id: String
    let agentID: AgentID
    let url: URL
    let ownership: Ownership
}
struct SandboxScopeRoots {
    var project: URL
    var activeProfile: SandboxProfileRoot? = nil
    var inactiveProfiles: [SandboxProfileRoot] = []
    // Milk constructs these per purpose; never accept cache roots from model-supplied input.
    var writableBuildRoots: [URL] = []
}
struct SandboxPolicyContext {
    var configuration: SandboxConfiguration
    var projectConfiguration: SandboxProjectConfiguration
    var roots: SandboxScopeRoots
    var interaction: ComposerPermissionMode
    var subject: SandboxSubject = .executor
    var configurationIsValid = true
}
enum SandboxPolicyOutcome: Equatable {
    case allow, deny, requireSandboxApproval, requireProtectedLocationApproval, sandboxDisabled
}
enum SandboxPolicyRule: String {
    case disabled, invalidConfiguration, unresolvedPath, ambiguousRoots, protectedLocation, inactiveProfile
    case projectReadOnly, allowedFolder, activeProfile, project, buildRoot, outsideProject
    case temporaryGrant, staleOwnership
}
struct SandboxPolicyDecision {
    let outcome: SandboxPolicyOutcome
    let rule: SandboxPolicyRule
    let action: SandboxFileAction
    let path: SandboxResolvedPath?
    var boundaries: Set<String> = []
    var subject: SandboxSubject = .executor
    var requiresApproval: Bool { outcome == .requireSandboxApproval || outcome == .requireProtectedLocationApproval }
}

extension SandboxConfiguration {
    func validate() throws {
        let value = self
        guard value.version == 1, value.autonomousTimeoutSeconds.isFinite, value.autonomousTimeoutSeconds > 0 else {
            throw SandboxSettingsError.message("Use a positive timeout and a supported Sandbox settings version.")
        }
        let entries = value.globalAllowedFolders.map { ($0.id, $0.url) }
            + value.protectedLocations.map { ($0.id, $0.url) }
            + value.projects.values.flatMap { $0.allowedFolders.map { ($0.id, $0.url) } }
        guard Set(entries.map(\.0)).count == entries.count,
              entries.allSatisfy({ !$0.0.isEmpty && $0.1.isFileURL && ($0.1.host == nil || $0.1.host == "" || $0.1.host == "localhost") && $0.1.path.hasPrefix("/") && !$0.1.path.utf8.contains(0) }),
              value.projects.keys.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            throw SandboxSettingsError.message("Sandbox locations must be unambiguous local paths with unique identifiers.")
        }
    }
}

extension CodingUserInfoKey {
    static let sandboxHome = CodingUserInfoKey(rawValue: "Milk.sandbox.home")!
}
