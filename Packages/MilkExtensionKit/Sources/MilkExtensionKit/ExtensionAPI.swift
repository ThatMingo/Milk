import Foundation
import SwiftUI

/// API 1 is a trusted, in-process contract, not an operating-system sandbox.
public enum MilkExtensionAPI { public static let version = "1" }

/// Supported host permissions. Native code itself has Milk's process privileges.
public enum ExtensionCapability: String, Codable, CaseIterable, Hashable {
    case workspaceRead = "workspace.read", workspaceWrite = "workspace.write"
    case network, shell, gitRead = "git.read", gitWrite = "git.write", pi
    case clipboardRead = "clipboard.read", clipboardWrite = "clipboard.write", notifications, keychain
}

/// Required package identity and compatibility, read before any native code loads.
public struct ExtensionManifest: Codable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var milkApi: String
    public var minimumMilkVersion: String
    public var principalClass: String
    public var executable: String
    public var capabilities: [ExtensionCapability]
    public var author: String?
    public var description: String?
    public var icon: String?
    public var update: URL?
    public init(id: String, name: String, version: String, milkApi: String = MilkExtensionAPI.version,
                minimumMilkVersion: String = "0.7.0", principalClass: String, executable: String,
                capabilities: [ExtensionCapability] = [], author: String? = nil, description: String? = nil) {
        self.id=id; self.name=name; self.version=version; self.milkApi=milkApi; self.minimumMilkVersion=minimumMilkVersion
        self.principalClass=principalClass; self.executable=executable; self.capabilities=capabilities
        self.author=author; self.description=description
    }
}

/// Subclass this NSObject principal in a native bundle. Milk never unloads its binary.
@MainActor open class MilkExtension: NSObject {
    public required override init() { super.init() }
    open func activate(context: any ExtensionContext) async throws {}
    open func deactivate() async {}
}

/// A value snapshot passed to controlled UI/action locations. No Milk implementation objects escape.
public struct ExtensionActionContext {
    public var workspaceURL: URL?
    public var fileURL: URL?
    public var text: String?
    public init(workspaceURL: URL? = nil, fileURL: URL? = nil, text: String? = nil) {
        self.workspaceURL=workspaceURL; self.fileURL=fileURL; self.text=text
    }
}

/// Fixed, native UI slots owned by Milk. Additional slots require a core API change.
public enum ExtensionPoint: String, Codable, CaseIterable {
    case workspaceToolbar = "workspace.toolbar", chatToolbar = "chat.toolbar"
    case chatMessageActions = "chat.messageActions", composerLeading = "composer.leadingActions", composerTrailing = "composer.trailingActions"
    case codeToolbar = "code.toolbar", codeContextMenu = "code.contextMenu", fileContextMenu = "file.contextMenu"
    case gitToolbar = "git.toolbar", gitFileActions = "git.fileActions"
    case previewToolbar = "preview.toolbar", terminalToolbar = "terminal.toolbar"
}

/// Tokens are scoped to one activation; Milk removes all owned tokens even if deactivate forgets.
public struct ExtensionRegistration: Hashable {
    public let id: String
    public init(id: String) { self.id=id }
}

/// Factories stay lazy; only selected/visible contributions construct their native SwiftUI views.
public struct ExtensionViewContribution {
    public var id: String
    public var title: String
    public var systemImage: String
    public var badge: String?
    public var minimumSize: CGSize
    public var topbar: Bool
    public var priority: Int
    public var content: @MainActor (ExtensionActionContext) -> AnyView
    public init(id: String, title: String, systemImage: String, badge: String? = nil,
                minimumSize: CGSize = CGSize(width: 360, height: 300), topbar: Bool = true, priority: Int = 0,
                content: @escaping @MainActor (ExtensionActionContext) -> AnyView) {
        self.id=id; self.title=title; self.systemImage=systemImage; self.badge=badge
        self.minimumSize=minimumSize; self.topbar=topbar; self.priority=priority; self.content=content
    }
}

/// Actions in menus have contextual values and an async handler, never access to a view tree.
public struct ExtensionActionContribution {
    public var id: String
    public var title: String
    public var systemImage: String
    public var perform: @MainActor (ExtensionActionContext) async throws -> Void
    public init(id: String, title: String, systemImage: String = "puzzlepiece.extension", perform: @escaping @MainActor (ExtensionActionContext) async throws -> Void) {
        self.id=id; self.title=title; self.systemImage=systemImage; self.perform=perform
    }
}

/// A native slash command. Names are checked for collisions with core and Pi commands.
public struct ExtensionCommand {
    public var name: String
    public var summary: String
    public var perform: @MainActor (String) async throws -> Void
    public init(name: String, summary: String, perform: @escaping @MainActor (String) async throws -> Void) {
        self.name=name; self.summary=summary; self.perform=perform
    }
}

/// JSON Schema and JSON arguments/results are confined to the Pi boundary.
public struct ExtensionPiTool {
    public var id: String
    public var description: String
    public var parameters: Data
    public var requiredCapabilities: Set<ExtensionCapability>
    public var perform: @MainActor (Data, ExtensionActionContext) async throws -> String
    public init(id: String, description: String, parameters: Data, requiredCapabilities: Set<ExtensionCapability> = [],
                perform: @escaping @MainActor (Data, ExtensionActionContext) async throws -> String) {
        self.id=id; self.description=description; self.parameters=parameters
        self.requiredCapabilities=requiredCapabilities; self.perform=perform
    }
}

/// A managed task receives cancellation on disable, workspace departure (if scoped), and quit.
public struct ExtensionBackgroundService {
    public var id: String
    public var workspaceScoped: Bool
    public var run: @MainActor (URL?) async throws -> Void
    public init(id: String, workspaceScoped: Bool = false, run: @escaping @MainActor (URL?) async throws -> Void) {
        self.id=id; self.workspaceScoped=workspaceScoped; self.run=run
    }
}

/// Registrations are tied to this activation, and rejected after it is revoked.
@MainActor public protocol ExtensionContributions: AnyObject {
    @discardableResult func sidebar(_ item: ExtensionViewContribution) throws -> ExtensionRegistration
    @discardableResult func panel(_ item: ExtensionViewContribution) throws -> ExtensionRegistration
    @discardableResult func settings(_ item: ExtensionViewContribution) throws -> ExtensionRegistration
    @discardableResult func status(_ item: ExtensionViewContribution) throws -> ExtensionRegistration
    @discardableResult func view(at point: ExtensionPoint, _ item: ExtensionViewContribution) throws -> ExtensionRegistration
    @discardableResult func action(at point: ExtensionPoint, _ item: ExtensionActionContribution) throws -> ExtensionRegistration
    @discardableResult func command(_ item: ExtensionCommand) throws -> ExtensionRegistration
    /// Adds a Milk slash command plus a model-callable Pi bridge command tool. Requires pi.
    @discardableResult func piCommand(_ item: ExtensionCommand) throws -> ExtensionRegistration
    @discardableResult func piTool(_ item: ExtensionPiTool) throws -> ExtensionRegistration
    @discardableResult func prompt(id: String, text: String) throws -> ExtensionRegistration
    @discardableResult func service(_ item: ExtensionBackgroundService) throws -> ExtensionRegistration
    func remove(_ token: ExtensionRegistration)
}

/// Always available, namespaced user data. Relative paths cannot escape this extension's data root.
@MainActor public protocol ExtensionStorage: AnyObject {
    func read(_ relativePath: String) throws -> Data?
    func write(_ data: Data, to relativePath: String) throws
    func remove(_ relativePath: String) throws
}
@MainActor public protocol ExtensionWorkspace: AnyObject {
    var url: URL? { get throws }
    func read(_ relativePath: String) async throws -> Data
    func write(_ data: Data, to relativePath: String) async throws
    /// Fires for workspace switches and file-change notifications, scoped to the activation.
    func observe(_ handler: @escaping @MainActor (URL?) -> Void) throws
}
@MainActor public protocol ExtensionNetwork: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
@MainActor public protocol ExtensionSecrets: AnyObject {
    func read(_ key: String) throws -> String?
    func write(_ value: String?, for key: String) throws
}
public struct ExtensionProcess: Hashable {
    public let id: UUID
    public let pid: Int32
    public init(id: UUID, pid: Int32) { self.id=id; self.pid=pid }
}
@MainActor public protocol ExtensionProcesses: AnyObject {
    /// Launches a direct executable in an owned group with a minimal environment. No daemonizing.
    func launch(executable: URL, arguments: [String], workspaceScoped: Bool) async throws -> ExtensionProcess
    func stop(_ process: ExtensionProcess) async
}
@MainActor public protocol ExtensionGit: AnyObject {
    func run(arguments: [String], writing: Bool) async throws -> String
}
@MainActor public protocol ExtensionClipboard: AnyObject {
    func read() throws -> String?
    func write(_ text: String) throws
}
@MainActor public protocol ExtensionNotifications: AnyObject {
    func post(title: String, body: String) async throws
}

/// Capability-gated services are nil unless granted. Retained services revoke access on disable.
@MainActor public protocol ExtensionContext: AnyObject {
    var extensionID: String { get }
    var capabilities: Set<ExtensionCapability> { get }
    var contributions: any ExtensionContributions { get }
    var storage: any ExtensionStorage { get }
    var workspace: (any ExtensionWorkspace)? { get }
    var network: (any ExtensionNetwork)? { get }
    var secrets: (any ExtensionSecrets)? { get }
    var processes: (any ExtensionProcesses)? { get }
    var git: (any ExtensionGit)? { get }
    var clipboard: (any ExtensionClipboard)? { get }
    var notifications: (any ExtensionNotifications)? { get }
    func focusSidebar(_ localID: String) throws
    func reportProblem(_ message: String)
}
