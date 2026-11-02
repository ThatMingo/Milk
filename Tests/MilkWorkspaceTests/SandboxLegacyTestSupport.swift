import Foundation
@testable import Milk

/// Existing provider/native-effect/parity tests exercise explicit Sandbox OFF behavior.
/// Production ON enforcement is tested separately with real sandboxed sibling execution.
@MainActor func sandboxOffForLegacyTests() -> SandboxSettingsStore {
    let defaults = UserDefaults(suiteName: "Milk.LegacySandboxOff." + UUID().uuidString)!
    let settings = SandboxSettingsStore(defaults: defaults, persist: false)
    try! settings.setEnabled(false)
    return settings
}

// Raw protocol fixtures are explicit transport-only launches, independent of production policy entry points.
extension PiRPCClient {
    func launch(executable: URL, arguments: [String], workspace: URL, environment: [String:String], sandboxProfile: String? = nil, redactedEnvironmentKeys: Set<String> = []) throws {
        try launch(executable:executable,arguments:arguments,workspace:workspace,environment:environment,sandboxProfile:sandboxProfile,redactedEnvironmentKeys:redactedEnvironmentKeys,sandboxEnabled:sandboxProfile != nil)
    }
}
