import Foundation

public enum ExtensionPermission: String, Codable, Sendable, CaseIterable {
    case workspaceRead = "workspace.read", workspaceWrite = "workspace.write", processExecute = "process.execute"
    case network, pi = "pi.interact", git, github, ui = "ui.contribute", preview, language
}
public struct ExtensionContribution: Codable, Sendable, Equatable {
    public enum Point: String, Codable, Sendable { case command, sidebar, inspector, toolbar, contextMenu, preview, languageService, status }
    public let id: String
    public let point: Point
    public let title: String
}
public struct ExtensionManifest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let version: String
    public let protocolVersion: Int
    public let entry: String
    public let permissions: Set<ExtensionPermission>
    public let contributions: [ExtensionContribution]
    public func validate() throws {
        guard protocolVersion == 1, !id.isEmpty, !version.isEmpty else { throw MilkError.message("Incompatible extension manifest") }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."), !entry.isEmpty else { throw MilkError.message("Extension entry must be a relative package path") }
        guard Set(contributions.map(\.id)).count == contributions.count else { throw MilkError.message("Duplicate contribution identity") }
        if !contributions.isEmpty && !permissions.contains(.ui) { throw MilkError.message("Contributions require ui.contribute") }
    }
}
public struct ExtensionEnvelope: Codable, Sendable {
    public var protocolVersion = 1
    public var requestID: UUID
    public var extensionID: String
    public var method: String
    public var payload: JSONValue
    public init(extensionID: String, method: String, payload: JSONValue) { requestID = UUID(); self.extensionID = extensionID; self.method = method; self.payload = payload }
}
public actor ExtensionRegistry {
    private var installed: [String: ExtensionManifest] = [:]
    private var enabled: Set<String> = []
    private var grants: [String: Set<ExtensionPermission>] = [:]
    private let persistenceURL: URL?
    private struct Saved: Codable { var version = 1; var manifests: [ExtensionManifest]; var enabled: Set<String>; var grants: [String: Set<ExtensionPermission>] }
    public init(directory: URL? = nil) { persistenceURL = directory?.appendingPathComponent("registry.json") }
    public func restore() throws {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: persistenceURL))
        guard saved.version == 1 else { throw MilkError.message("Unsupported extension registry version") }
        var loaded: [String: ExtensionManifest] = [:]
        for manifest in saved.manifests {
            try manifest.validate()
            guard loaded.updateValue(manifest, forKey: manifest.id) == nil else { throw MilkError.message("Duplicate extension identity in registry") }
        }
        installed = loaded; grants = saved.grants
        enabled = Set(saved.enabled.filter { id in installed[id]?.permissions.isSubset(of: grants[id, default: []]) == true })
    }
    private func persist() throws {
        guard let persistenceURL else { return }
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Saved(manifests: Array(installed.values), enabled: enabled, grants: grants)).write(to: persistenceURL, options: .atomic)
    }
    public func register(_ manifest: ExtensionManifest, enabled: Bool = false, granted: Set<ExtensionPermission> = []) throws {
        try manifest.validate(); installed[manifest.id] = manifest
        self.grants[manifest.id] = granted.intersection(manifest.permissions)
        if enabled && manifest.permissions.isSubset(of: granted) { self.enabled.insert(manifest.id) } else { self.enabled.remove(manifest.id) }
        try persist()
    }
    public func authorize(extensionID: String, permission: ExtensionPermission) -> Bool { enabled.contains(extensionID) && grants[extensionID, default: []].contains(permission) }
    public func disable(_ id: String) throws { enabled.remove(id); try persist() }
    public func uninstall(_ id: String) throws { enabled.remove(id); installed.removeValue(forKey: id); grants.removeValue(forKey: id); try persist() }
    public func manifests() -> [ExtensionManifest] { installed.values.sorted { $0.id < $1.id } }
}

@objc public protocol MilkExtensionHostProtocol {
    func evaluate(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
}
