import Foundation

/// The single app-side Pi policy. Packaging pins remain separate build inputs.
enum PiCompatibilityPolicy {
    static let adapterVersion = "1"
    static let supportedVersions: Set<String> = ["1.4.0"]
    static func result(_ state: AgentCompatibilityState, version: String?, detail: String,
                       evidence: AgentCompatibilityResult.Evidence = .versionOnly) -> AgentCompatibilityResult {
        .init(state: state, version: version, adapterVersion: adapterVersion, evidence: evidence, detail: detail)
    }
    static func evaluate(version: String) -> AgentCompatibilityResult {
        if supportedVersions.contains(version) { return result(.supported, version: version, detail: "Pi \(version): version supported; RPC integration not yet verified.") }
        guard version.range(of: #"^\d+\.\d+\.\d+([+-].+)?$"#, options: .regularExpression) != nil else {
            return result(.invalidRuntime, version: version, detail: "Pi returned an invalid version: \(version).")
        }
        if version.compare("1.4.0", options: .numeric) == .orderedAscending {
            return result(.unsupported, version: version, detail: "Pi \(version) is unsupported. This adapter supports \(supportedVersions.sorted().joined(separator: ", ")).")
        }
        return result(.untested, version: version, detail: "Pi \(version) is untested with this adapter. This adapter supports \(supportedVersions.sorted().joined(separator: ", ")).")
    }
    static func requireSupportedVersion(_ value: AgentCompatibilityResult) throws {
        guard value.state == .supported else { throw AgentCompatibilityError(result: value) }
    }
    static func incompatible(version: String?, _ detail: String) -> AgentCompatibilityError {
        .init(result: result(.incompatibleIntegration, version: version, detail: detail))
    }
    static func verified(version: String) -> AgentCompatibilityResult {
        result(.supported, version: version, detail: "Pi \(version) RPC and Milk integration verified.", evidence: .integrationHandshake)
    }
    /// Validate the same required reply shapes in live startup and candidate probing.
    static func validate(_ command: String, reply: JSONValue, version: String?) throws {
        let valid: Bool
        switch command {
        case "get_state":
            if case .object = reply { valid = reply["sessionId"].string?.isEmpty == false } else { valid = false }
        case "get_available_thinking_levels":
            if case .array(let values) = reply["levels"] { valid = !values.isEmpty && values.allSatisfy { $0.string != nil } } else { valid = false }
        default:
            let key = ["get_commands": "commands", "get_available_models": "models", "get_messages": "messages"][command]!
            if case .array = reply[key] { valid = true } else { valid = false }
        }
        guard valid else { throw incompatible(version: version, "Pi returned an incompatible \(command) reply.") }
    }
}
