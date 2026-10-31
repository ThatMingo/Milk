import Foundation
import CryptoKit

/// Code ownership determines profile ownership, independently of executable location.
@MainActor enum PiProfile {
    static func existing(environment: [String: String]) -> AgentDataProfile {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = environment["PI_CODING_AGENT_DIR"].map { raw in
            raw == "~" ? home : raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))) : URL(fileURLWithPath: raw)
        } ?? home.appendingPathComponent(".pi/agent")
        return .init(directory: directory, ownership: .sharedExisting)
    }
    static func managed(store: AgentInstallationStore) throws -> AgentDataProfile {
        let directory = store.root.appendingPathComponent("profile", isDirectory: true)
        try store.rejectLinks(directory)
        // Reject linked persistent state, including nested links, rather than allowing
        // a managed profile to read/write a different profile through a symlink.
        if let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in entries { try store.rejectLinks(file) }
        }
        return .init(directory: directory, ownership: .milkManaged)
    }
}
extension PiInstallationManager {
    func selectedProfile() throws -> AgentDataProfile {
        if store.state.selected == nil, !store.state.useLegacyRuntime { return try PiProfile.managed(store: store) }
        let installation = try selectedInstallation(verifyIntegrity: false)
        return try profile(for: installation)
    }
    func profile(for installation: AgentInstallationRecord?) throws -> AgentDataProfile {
        if installation?.ownership == .milkManaged { return try PiProfile.managed(store: store) }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(runtime.environmentOverrides) { _, new in new }
        return PiProfile.existing(environment: environment)
    }
    func providerProfileIdentity() throws -> PiProviderProfileIdentity {
        let profile = try selectedProfile()
        return .init(directory: profile.directory)
    }
    var providerSettingsKey: String {
        // The managed key already uniquely names the preserved managed profile.
        let managed = !store.state.useLegacyRuntime && (store.state.selected == nil || store.state.managed.contains { $0.id == store.state.selected })
        let sameManagedDirectory = (try? selectedProfile().directory.standardizedFileURL.resolvingSymlinksInPath().path) == store.root.appendingPathComponent("profile").standardizedFileURL.resolvingSymlinksInPath().path
        if managed || sameManagedDirectory { return PiProviderConfiguration.key + ".managed." + store.root.path }
        return (try? providerProfileIdentity().settingsKey) ?? PiProviderConfiguration.key + ".unavailable"
    }
}

/// Stable, non-secret identity; managed revisions share their persistent directory.
/// Runtime registration is deliberately excluded: one resolved directory is one profile.
struct PiProviderProfileIdentity: Equatable {
    let rawValue: String
    init(directory: URL) {
        // Retain the original domain marker so managed profile hashes remain unchanged.
        let parts = ["pi-profile-v1", directory.standardizedFileURL.resolvingSymlinksInPath().path, "managed"]
        let data = try! JSONEncoder().encode(parts)
        rawValue = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var settingsKey: String { PiProviderConfiguration.key + ".profile." + rawValue }
}

@MainActor enum PiProfileIdentitySupport {
    static func identity(runtime: PiRuntimeService, installations: PiInstallationManager?, mode: PiRuntimeMode) throws -> PiProviderProfileIdentity {
        if let installations { return try installations.providerProfileIdentity() }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(runtime.environmentOverrides) { _, value in value }
        let profile = PiProfile.existing(environment: environment)
        return .init(directory: profile.directory)
    }
}
