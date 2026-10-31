import Foundation
import SwiftUI
import Combine
import MilkExtensionKit

public struct OwnedExtensionView: Identifiable {
    public let id: String
    public let owner: String
    public let item: ExtensionViewContribution
}
public struct OwnedExtensionAction: Identifiable {
    public let id: String
    public let owner: String
    public let point: ExtensionPoint
    public let item: ExtensionActionContribution
}
public struct OwnedExtensionCommand: Identifiable {
    public let id: String
    public let owner: String
    public let item: ExtensionCommand
}
public struct OwnedPiTool: Identifiable {
    public let id: String
    public let owner: String
    public let item: ExtensionPiTool
    public var piName: String { "milk_" + owner.replacingOccurrences(of:".",with:"_").replacingOccurrences(of:"-",with:"_") + "_" + item.id.replacingOccurrences(of:"-",with:"_") }
}

/// Host-only storage. Every mutation is owned; extensions receive an activation-scoped facade.
@MainActor public final class ExtensionContributionRegistry: ObservableObject {
    @Published public private(set) var sidebar: [OwnedExtensionView] = []
    @Published public private(set) var panels: [OwnedExtensionView] = []
    @Published public private(set) var settings: [OwnedExtensionView] = []
    @Published public private(set) var status: [OwnedExtensionView] = []
    @Published public private(set) var views: [ExtensionPoint:[OwnedExtensionView]] = [:]
    @Published public private(set) var actions: [OwnedExtensionAction] = []
    @Published public private(set) var commands: [OwnedExtensionCommand] = []
    @Published public private(set) var tools: [OwnedPiTool] = []
    @Published public private(set) var prompts: [String:String] = [:]
    public var reservedCommands: Set<String> = ["milk-permission", "milk-native", "help", "new", "compact", "model", "settings", "reload", "login", "logout", "quit", "export", "resume", "name", "tree", "fork", "share"]
    public var onChange: (() -> Void)?
    private var owners: [String:String] = [:]
    static func identifier(owner: String, kind: String, local: String) -> String { "extension:\(owner)/\(kind):\(local)" }
    func claim(owner: String, kind: String, local: String) throws -> String {
        guard local.count <= 100, local.range(of:#"^[a-zA-Z][a-zA-Z0-9_-]*$"#,options:.regularExpression) != nil else { throw NativeExtensionError.invalid("Invalid local contribution ID: \(local)") }
        let id=Self.identifier(owner:owner,kind:kind,local:local)
        guard owners[id] == nil else { throw NativeExtensionError.invalid("Duplicate contribution: \(id)") }
        guard owners.values.filter({ $0 == owner }).count < 100 else { throw NativeExtensionError.invalid("Contribution limit reached (100 per extension).") }
        owners[id]=owner; return id
    }
    func addView(_ item: ExtensionViewContribution, owner: String, kind: String, point: ExtensionPoint? = nil) throws -> ExtensionRegistration {
        guard item.minimumSize.width.isFinite, item.minimumSize.height.isFinite,
              (180...2000).contains(item.minimumSize.width), (100...2000).contains(item.minimumSize.height) else { throw NativeExtensionError.invalid("Panel minimum size is outside supported bounds.") }
        if kind == "status", status.filter({ $0.owner == owner }).count >= 2 { throw NativeExtensionError.invalid("At most two status contributions per extension.") }
        let id=try claim(owner:owner,kind:kind,local:item.id), record=OwnedExtensionView(id:id,owner:owner,item:item)
        switch kind {
        case "sidebar": sidebar.append(record)
        case "panel": panels.append(record)
        case "settings": settings.append(record)
        case "status": status.append(record); status.sort { $0.item.priority > $1.item.priority }
        default: if let point { views[point,default:[]].append(record) }
        }
        onChange?(); return .init(id:id)
    }
    func addAction(_ item: ExtensionActionContribution, owner: String, point: ExtensionPoint) throws -> ExtensionRegistration {
        let id=try claim(owner:owner,kind:point.rawValue+".action",local:item.id)
        actions.append(.init(id:id,owner:owner,point:point,item:item)); onChange?(); return .init(id:id)
    }
    func addCommand(_ item: ExtensionCommand, owner: String) throws -> ExtensionRegistration {
        guard !reservedCommands.contains(item.name), !commands.contains(where: { $0.item.name == item.name }) else { throw NativeExtensionError.invalid("Slash command /\(item.name) conflicts with another command.") }
        let id=try claim(owner:owner,kind:"command",local:item.name)
        commands.append(.init(id:id,owner:owner,item:item)); onChange?(); return .init(id:id)
    }
    func addTool(_ item: ExtensionPiTool, owner: String, granted: Set<ExtensionCapability>) throws -> ExtensionRegistration {
        guard item.requiredCapabilities.isSubset(of:granted), item.parameters.count <= 65536,
              let schema=try JSONSerialization.jsonObject(with:item.parameters) as? [String:Any], schema["type"] as? String == "object" else { throw NativeExtensionError.invalid("Pi tool needs granted capabilities and an object JSON Schema.") }
        let record=OwnedPiTool(id:Self.identifier(owner:owner,kind:"piTool",local:item.id),owner:owner,item:item)
        guard !tools.contains(where:{ $0.piName == record.piName }) else { throw NativeExtensionError.invalid("Pi tool name collision: \(record.piName)") }
        let id=try claim(owner:owner,kind:"piTool",local:item.id)
        tools.append(record); onChange?(); return .init(id:id)
    }
    func addPrompt(id local: String, text: String, owner: String) throws -> ExtensionRegistration {
        guard text.utf8.count <= 131072 else { throw NativeExtensionError.invalid("Prompt resource exceeds 128 KB.") }
        let id=try claim(owner:owner,kind:"prompt",local:local)
        prompts[id]=text; onChange?(); return .init(id:id)
    }
    func remove(_ id: String, owner: String) {
        guard owners[id] == owner else { return }
        owners[id]=nil
        sidebar.removeAll { $0.id == id }; panels.removeAll { $0.id == id }; settings.removeAll { $0.id == id }; status.removeAll { $0.id == id }
        for point in Array(views.keys) { views[point]?.removeAll { $0.id == id } }
        actions.removeAll { $0.id == id }; commands.removeAll { $0.id == id }; tools.removeAll { $0.id == id }; prompts[id]=nil
        onChange?()
    }
    public func removeAll(owner: String) { for id in owners.filter({ $0.value == owner }).map(\.key) { remove(id,owner:owner) } }
    public func contributionCount(owner: String) -> Int { owners.values.filter { $0 == owner }.count }
    public init() {}
    public func piCatalogData() throws -> Data {
        let values: [[String:Any]]=try tools.map { ["id":$0.id,"name":$0.piName,"description":$0.item.description,"parameters":try JSONSerialization.jsonObject(with:$0.item.parameters)] }
        return try JSONSerialization.data(withJSONObject:["tools":values,"prompts":prompts],options:[.sortedKeys])
    }
}

@MainActor final class ExtensionLease {
    let id: String
    let grants: Set<ExtensionCapability>
    var active=true
    var workspace: URL?
    var observers: [@MainActor (URL?) -> Void] = []
    init(id: String, grants: Set<ExtensionCapability>, workspace: URL?) { self.id=id; self.grants=grants; self.workspace=workspace }
    func check(_ capability: ExtensionCapability? = nil) throws {
        try Task.checkCancellation()
        guard active else { throw NativeExtensionError.invalid("Extension activation has ended.") }
        if let capability, !grants.contains(capability) { throw NativeExtensionError.invalid("Capability not granted: \(capability.rawValue)") }
    }
}

@MainActor final class NativeExtensionContext: ExtensionContext, ExtensionContributions {
    let lease: ExtensionLease
    let registry: ExtensionContributionRegistry
    let storage: any ExtensionStorage
    let workspace: (any ExtensionWorkspace)?
    let network: (any ExtensionNetwork)?
    let secrets: (any ExtensionSecrets)?
    let processes: (any ExtensionProcesses)?
    let git: (any ExtensionGit)?
    let clipboard: (any ExtensionClipboard)?
    let notifications: (any ExtensionNotifications)?
    var extensionID: String { lease.id }
    var capabilities: Set<ExtensionCapability> { lease.grants }
    var contributions: any ExtensionContributions { self }
    var commandToolTokens: [String:String] = [:]
    var serviceDefinitions: [String:ExtensionBackgroundService] = [:]
    var serviceTasks: [String:Task<Void,Never>] = [:]
    let processHost: ExtensionProcessHost
    var focus: ((String) -> Void)?
    var problem: ((String) -> Void)?
    init(lease: ExtensionLease, registry: ExtensionContributionRegistry, dataRoot: URL, processHost: ExtensionProcessHost,
         authorize: @escaping @MainActor (String,URL?) async throws -> Void) {
        self.lease=lease; self.registry=registry; self.processHost=processHost
        storage=ScopedStorage(lease:lease,root:dataRoot)
        workspace=lease.grants.contains(.workspaceRead) || lease.grants.contains(.workspaceWrite) ? ScopedWorkspace(lease:lease,authorize:authorize):nil
        network=lease.grants.contains(.network) ? ScopedNetwork(lease:lease):nil
        secrets=lease.grants.contains(.keychain) ? ScopedSecrets(lease:lease,dataRoot:dataRoot):nil
        processes=lease.grants.contains(.shell) ? ScopedProcesses(lease:lease,host:processHost,authorize:authorize):nil
        git=lease.grants.contains(.gitRead) || lease.grants.contains(.gitWrite) ? ScopedGit(lease:lease,host:processHost,authorize:authorize):nil
        clipboard=lease.grants.contains(.clipboardRead) || lease.grants.contains(.clipboardWrite) ? ScopedClipboard(lease:lease):nil
        notifications=lease.grants.contains(.notifications) ? ScopedNotifications(lease:lease):nil
    }
    func sidebar(_ item: ExtensionViewContribution) throws -> ExtensionRegistration { try lease.check(); return try registry.addView(item,owner:extensionID,kind:"sidebar") }
    func panel(_ item: ExtensionViewContribution) throws -> ExtensionRegistration { try lease.check(); return try registry.addView(item,owner:extensionID,kind:"panel") }
    func settings(_ item: ExtensionViewContribution) throws -> ExtensionRegistration { try lease.check(); return try registry.addView(item,owner:extensionID,kind:"settings") }
    func status(_ item: ExtensionViewContribution) throws -> ExtensionRegistration { try lease.check(); return try registry.addView(item,owner:extensionID,kind:"status") }
    func view(at point: ExtensionPoint, _ item: ExtensionViewContribution) throws -> ExtensionRegistration {
        try lease.check()
        guard ![ExtensionPoint.codeContextMenu,.fileContextMenu,.gitFileActions].contains(point) else { throw NativeExtensionError.invalid("Context menus accept action registrations rather than view factories.") }
        return try registry.addView(item,owner:extensionID,kind:point.rawValue+".view",point:point)
    }
    func action(at point: ExtensionPoint, _ item: ExtensionActionContribution) throws -> ExtensionRegistration { try lease.check(); return try registry.addAction(item,owner:extensionID,point:point) }
    func command(_ item: ExtensionCommand) throws -> ExtensionRegistration { try lease.check(); return try registry.addCommand(item,owner:extensionID) }
    func piCommand(_ item: ExtensionCommand) throws -> ExtensionRegistration {
        try lease.check(.pi)
        let command=try self.command(item)
        do {
            let tool=ExtensionPiTool(id:"command_"+item.name,description:"Run /"+item.name+": "+item.summary,parameters:Data(#"{"type":"object","properties":{"arguments":{"type":"string"}},"required":["arguments"],"additionalProperties":false}"#.utf8)) { data,_ in
                let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                try await item.perform(json?["arguments"] as? String ?? ""); return "Command completed."
            }
            _ = try piTool(tool)
            commandToolTokens[command.id]=ExtensionContributionRegistry.identifier(owner:extensionID,kind:"piTool",local:tool.id)
            return command
        } catch { registry.remove(command.id,owner:extensionID); throw error }
    }
    func piTool(_ item: ExtensionPiTool) throws -> ExtensionRegistration { try lease.check(.pi); return try registry.addTool(item,owner:extensionID,granted:capabilities) }
    func prompt(id: String, text: String) throws -> ExtensionRegistration { try lease.check(.pi); return try registry.addPrompt(id:id,text:text,owner:extensionID) }
    func service(_ item: ExtensionBackgroundService) throws -> ExtensionRegistration {
        try lease.check()
        let id=try registry.claim(owner:extensionID,kind:"service",local:item.id)
        serviceDefinitions[id]=item; startService(id); return .init(id:id)
    }
    private func startService(_ id: String) {
        guard let item=serviceDefinitions[id], lease.active, !item.workspaceScoped || lease.workspace != nil else { return }
        let workspace=lease.workspace
        serviceTasks[id]=Task { [weak self] in
            do { try await item.run(workspace) }
            catch is CancellationError {} catch { if !Task.isCancelled { self?.reportProblem("Service \(item.id): \(error.localizedDescription)") } }
        }
    }
    func workspaceChanged(_ url: URL?) {
        lease.workspace=url
        for (id,item) in serviceDefinitions where item.workspaceScoped { serviceTasks.removeValue(forKey:id)?.cancel(); startService(id) }
        for observer in lease.observers { observer(url) }
    }
    func remove(_ token: ExtensionRegistration) { if let tool=commandToolTokens.removeValue(forKey:token.id) { registry.remove(tool,owner:extensionID) }; serviceTasks.removeValue(forKey:token.id)?.cancel(); serviceDefinitions[token.id]=nil; registry.remove(token.id,owner:extensionID) }
    func revoke() {
        lease.active=false; lease.observers=[]
        for task in serviceTasks.values { task.cancel() }; serviceTasks=[:]; serviceDefinitions=[:]
        registry.removeAll(owner:extensionID)
    }
    func focusSidebar(_ localID: String) throws {
        try lease.check()
        let id=ExtensionContributionRegistry.identifier(owner:extensionID,kind:"sidebar",local:localID)
        guard registry.sidebar.contains(where:{ $0.id == id }) else { throw NativeExtensionError.invalid("Sidebar contribution is not active.") }
        focus?(id)
    }
    func reportProblem(_ message: String) { if lease.active { problem?(String(message.prefix(4000))) } }
}
