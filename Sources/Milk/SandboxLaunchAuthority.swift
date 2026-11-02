import Foundation

/// Propagates host-owned policy through pre-RPC resolution without Pi-supplied authority.
struct SandboxLaunchAuthority {
    let configuration: SandboxConfiguration
    let isValid: Bool
    let inactiveProfiles: [SandboxProfileRoot]
    var settings: SandboxSettingsStore? = nil
    @TaskLocal static var current: SandboxLaunchAuthority?
    @MainActor static func capture(settings: SandboxSettingsStore? = nil, profiles: [SandboxProfileRoot] = []) -> Self {
        if let current { return current }
        let store=settings ?? SandboxSettingsStore()
        var known=profiles
        let home=FileManager.default.homeDirectoryForCurrentUser
        for item in [SandboxProfileRoot(id:"purpose-managed",agentID:.pi,url:home.appendingPathComponent("Library/Application Support/Milk/Agents/pi/profile"),ownership:.managed),
                     .init(id:"purpose-existing",agentID:.pi,url:home.appendingPathComponent(".pi/agent"),ownership:.existing)] {
            if !known.contains(where:{ (try? SandboxPathResolver().resolve($0.url).canonicalURL) == (try? SandboxPathResolver().resolve(item.url).canonicalURL) }) { known.append(item) }
        }
        return .init(configuration:store.configuration,isValid:store.isValid,inactiveProfiles:known,settings:store)
    }
    @MainActor func check() throws {
        guard isValid else { throw AgentError.message("Sandbox policy is unavailable. Save valid Sandbox settings before execution.") }
        try configuration.validate()
        if let settings {
            var current=settings.configuration, expected=configuration
            current.autonomousTimeoutSeconds=30; expected.autonomousTimeoutSeconds=30
            guard settings.isValid, current == expected else { throw CancellationError() }
        }
    }
}
