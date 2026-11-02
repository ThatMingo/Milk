import Foundation
import Combine

@MainActor final class SandboxSettingsStore: ObservableObject {
    static let key = "Milk.sandbox.configuration.v1"
    @Published private(set) var configuration: SandboxConfiguration
    @Published private(set) var problem: String?
    private let defaults: UserDefaults
    private let persist: Bool
    private let home: URL
    private let resolver = SandboxPathResolver()
    init(defaults: UserDefaults = .standard, persist: Bool = true,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults; self.persist = persist; self.home = home
        configuration = .init(home: home)
        if let data = defaults.data(forKey: Self.key) {
            do {
                let decoder = JSONDecoder(); decoder.userInfo[.sandboxHome] = home
                let decoded = try decoder.decode(SandboxConfiguration.self, from: data)
                try decoded.validate(); configuration = decoded
            } catch { problem = "Saved Sandbox settings could not be loaded. Policy remains unavailable until settings are saved again." }
        } else if defaults.object(forKey: Self.key) != nil {
            problem = "Saved Sandbox settings have an invalid format. Policy remains unavailable until settings are saved again."
        }
    }
    var isValid: Bool { problem == nil }
    func setEnabled(_ value: Bool) throws { var c = configuration; c.enabled = value; try save(c) }
    func setTimeout(seconds: Double) throws { var c = configuration; c.autonomousTimeoutSeconds = seconds; try save(c) }
    func projectConfiguration(for project: URL) throws -> SandboxProjectConfiguration {
        configuration.projects[try projectKey(project)] ?? .init()
    }
    func setProjectAccess(_ value: SandboxFolderAccess, project: URL) throws {
        var c = configuration; let key = try projectKey(project)
        var p = c.projects[key] ?? .init(); p.access = value; c.projects[key] = p; try save(c)
    }
    func putFolder(_ url: URL, access: SandboxFolderAccess, id: String? = nil, project: URL? = nil) throws {
        let path = try resolver.resolve(url)
        guard path.isDirectory else { throw SandboxSettingsError.message("Choose an existing folder.") }
        var c = configuration
        let entry = SandboxFolderGrant(id: id ?? UUID().uuidString, url: path.canonicalURL, access: access)
        if let project {
            let key = try projectKey(project); var p = c.projects[key] ?? .init()
            p.allowedFolders.removeAll { $0.id == entry.id || $0.url == entry.url }; p.allowedFolders.append(entry); c.projects[key] = p
        } else {
            c.globalAllowedFolders.removeAll { $0.id == entry.id || $0.url == entry.url }; c.globalAllowedFolders.append(entry)
        }
        try save(c)
    }
    func removeFolder(_ id: String, project: URL? = nil) throws {
        var c = configuration
        if let project {
            let key = try projectKey(project); var p = c.projects[key] ?? .init()
            p.allowedFolders.removeAll { $0.id == id }; c.projects[key] = p
        } else { c.globalAllowedFolders.removeAll { $0.id == id } }
        try save(c)
    }
    func putProtectedLocation(_ url: URL, id: String? = nil) throws {
        let path = try resolver.resolve(url)
        var c = configuration
        let entry = SandboxProtectedLocation(id: id ?? UUID().uuidString, url: path.canonicalURL)
        c.protectedLocations.removeAll { $0.id == entry.id || $0.url.path == entry.url.path }; c.protectedLocations.append(entry)
        try save(c)
    }
    func removeProtectedLocation(_ id: String) throws {
        var c = configuration; c.protectedLocations.removeAll { $0.id == id }; try save(c)
    }
    func restoreRecommendedDefaults() throws {
        var c = configuration
        for entry in SandboxConfiguration.recommendedLocations(home: home) where !c.protectedLocations.contains(where: { $0.url.path == entry.url.path }) {
            // If a recommended entry was edited to another location, preserve the edit as custom.
            var restored = entry
            if c.protectedLocations.contains(where: { $0.id == restored.id }) { restored.id = UUID().uuidString }
            c.protectedLocations.append(restored)
        }
        try save(c)
    }
    func context(roots: SandboxScopeRoots, interaction: ComposerPermissionMode, subject: SandboxSubject = .executor) -> SandboxPolicyContext {
        let project = try? projectConfiguration(for: roots.project)
        return .init(configuration: configuration, projectConfiguration: project ?? .init(), roots: roots,
                     interaction: interaction, subject: subject, configurationIsValid: isValid && (project != nil || !configuration.enabled))
    }
    private func projectKey(_ project: URL) throws -> String {
        let path = try resolver.resolve(project)
        guard path.isDirectory else { throw SandboxSettingsError.message("The project folder is unavailable.") }
        return path.canonicalURL.path
    }
    private func save(_ value: SandboxConfiguration) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        if persist { defaults.set(data, forKey: Self.key) }
        configuration = value; problem = nil
    }

}
enum SandboxSettingsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
