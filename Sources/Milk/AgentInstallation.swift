import Foundation

struct AgentInstallationID: RawRepresentable, Hashable, Codable { let rawValue: String }
enum AgentInstallationOwnership: String, Codable { case milkManaged, external, applicationBundle }
enum AgentInstallationSource: String, Codable { case milkApproved, userSelected, applicationBundle }

/// Code identity only. No credential, data-directory or session ownership is implied.
struct AgentInstallationRecord: Identifiable, Codable, Equatable {
    let id: AgentInstallationID
    let agentID: AgentID
    let ownership: AgentInstallationOwnership
    let source: AgentInstallationSource
    let executable: URL
    var expectedVersion: String? = nil
    var executableSHA256: String? = nil
}
struct AgentDataProfile: Equatable {
    enum Ownership { case sharedExisting, ephemeralMilk }
    let directory: URL
    let ownership: Ownership
}
enum AgentCompatibilityState: String, Codable {
    case supported, unsupported, untested, incompatibleIntegration, invalidRuntime
}
struct AgentCompatibilityResult: Equatable, Codable {
    enum Evidence: String, Codable { case versionOnly, integrationHandshake }
    let state: AgentCompatibilityState
    let version: String?
    let adapterVersion: String
    let evidence: Evidence
    let detail: String
    var usable: Bool { state == .supported && evidence == .integrationHandshake }
    func requireUsable() throws { if !usable { throw AgentCompatibilityError(result: self) } }
}
struct AgentCompatibilityError: LocalizedError {
    let result: AgentCompatibilityResult
    var errorDescription: String? { result.detail }
}
