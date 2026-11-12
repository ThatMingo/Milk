import Foundation

/// The single app-side Pi policy. Packaging pins remain separate build inputs.
///
/// Two different questions are deliberately kept apart:
///   * eligibility — may this version be built and inspected at all?
///   * verification — has this exact revision completed the isolated Milk RPC
///     handshake on this machine?
/// A newly discovered stable upstream release is eligible for the isolated
/// compatibility probe before anyone approves it. Normal user sessions still
/// require successful verification.
enum PiCompatibilityPolicy {
    static let adapterVersion = "1"
    /// The adapter baseline. Releases older than this are never eligible.
    static let minimumEligibleVersion = PiSemanticVersion(major: 1, minor: 4, patch: 0, prerelease: nil)
    /// Revisions Milk ships metadata for, used as the compatibility floor and by
    /// fixture/bundled paths. Not an approval list for future releases.
    static let baselineVersions: Set<String> = ["1.4.0"]

    static func result(_ state: AgentCompatibilityState, version: String?, detail: String,
                       evidence: AgentCompatibilityResult.Evidence = .versionOnly) -> AgentCompatibilityResult {
        .init(state: state, version: version, adapterVersion: adapterVersion, evidence: evidence, detail: detail)
    }
    /// `verified` is the set of versions whose probe handshake succeeded on this
    /// machine (held in the installation store), not a compiled allow-list.
    static func evaluate(version: String, verified: Set<String> = []) -> AgentCompatibilityResult {
        guard let parsed = PiSemanticVersion.parse(version) else {
            return result(.invalidRuntime, version: version, detail: "Pi returned an invalid version: \(version).")
        }
        if parsed < minimumEligibleVersion {
            return result(.unsupported, version: parsed.text, detail: "Pi \(parsed.text) is older than the Pi \(minimumEligibleVersion.text) baseline this adapter supports.")
        }
        if baselineVersions.contains(parsed.text) {
            return result(.supported, version: parsed.text, detail: "Pi \(parsed.text): adapter baseline; RPC integration not yet verified.")
        }
        if verified.contains(parsed.text) {
            return result(.supported, version: parsed.text, detail: "Pi \(parsed.text) passed the isolated Milk RPC compatibility probe on this machine.",
                          evidence: .integrationHandshake)
        }
        let kind = parsed.isStable ? "stable" : "pre-release"
        return result(.untested, version: parsed.text, detail: "Pi \(kind) \(parsed.text) has not been verified with this adapter yet. Run the compatibility check before using it for sessions.")
    }
    /// Gate for the isolated compatibility probe: structurally eligible versions
    /// may be inspected without prior approval.
    static func requireProbeEligible(_ value: AgentCompatibilityResult) throws {
        guard value.state == .supported || value.state == .untested else { throw AgentCompatibilityError(result: value) }
    }
    /// Gate for ordinary session launch: only verified runtimes may run user work.
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
