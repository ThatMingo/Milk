import AppKit
import Combine

// Global defaults live in UserDefaults; workspace layouts, sessions and Preview memories
// remain in their existing stores. Secrets never enter this model.
enum MilkAppearance: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
@MainActor final class SettingsService: ObservableObject {
    private let defaults: UserDefaults
    private let persist: Bool
    @Published var appearance: MilkAppearance { didSet { save("appearance", appearance.rawValue); applyAppearance() } }
    @Published var restoreWorkspace: Bool { didSet { save("restoreWorkspace", restoreWorkspace) } }
    @Published var previewDevice: PreviewDevice { didSet { save("previewDevice", previewDevice.rawValue) } }
    @Published var automaticUpdates: Bool { didSet { save("automaticUpdates", automaticUpdates) } }
    @Published var gitSideBySide: Bool { didSet { save("gitSideBySide", gitSideBySide) } }
    @Published var refreshExtensionsOnOpen: Bool { didSet { save("refreshExtensionsOnOpen", refreshExtensionsOnOpen) } }
    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults=defaults; self.persist=persist
        appearance=MilkAppearance(rawValue: defaults.string(forKey:"Milk.settings.appearance") ?? "") ?? .system
        restoreWorkspace=defaults.object(forKey:"Milk.settings.restoreWorkspace") as? Bool ?? true
        previewDevice=PreviewDevice(rawValue:defaults.string(forKey:"Milk.settings.previewDevice") ?? "") ?? .desktop
        automaticUpdates=defaults.object(forKey:"Milk.settings.automaticUpdates") as? Bool ?? false
        gitSideBySide=defaults.object(forKey:"Milk.settings.gitSideBySide") as? Bool ?? defaults.object(forKey:"Milk.git.sideBySide") as? Bool ?? false
        refreshExtensionsOnOpen=defaults.object(forKey:"Milk.settings.refreshExtensionsOnOpen") as? Bool ?? true
    }
    private func save(_ key:String,_ value:Any) { if persist { defaults.set(value,forKey:"Milk.settings."+key) } }
    func applyAppearance() {
        NSApp.appearance=appearance == .system ? nil : NSAppearance(named:appearance == .dark ? .darkAqua:.aqua)
        for window in NSApp.windows { window.appearance=nil; window.backgroundColor=window.isOpaque ? NSColor(MilkTheme.canvas):.clear; window.contentView?.needsDisplay=true }
    }
    func resetGeneralAndPreview() {
        appearance = .system; restoreWorkspace=true; previewDevice = .desktop
        automaticUpdates=false; refreshExtensionsOnOpen=true
    }
    static func validatedEditor(_ value:EditorPreferences) -> EditorPreferences {
        var result=value
        result.fontSize=value.fontSize.isFinite ? min(32,max(9,value.fontSize)):12.5
        result.indentWidth=min(8,max(1,value.indentWidth))
        return result
    }
}

/// Drafts and validation belong here; both the takeover and native menu use this service.
@MainActor final class RuntimeSettingsModel: ObservableObject {
    @Published var providerID:PiProviderID = .omlx
    @Published private(set) var connectionStatus:ProviderInspection?
    var providerAdapter:any ProviderSettingsAdapter { ProviderSettingsCatalog.adapter(for:providerID) }
    var providerEnabled:Bool {
        get {providerAdapter.isEnabled(in:configuration)}
        set {var value=configuration;providerAdapter.setEnabled(newValue,in:&value);configuration=value}
    }
    func selectProvider(_ id:PiProviderID) {providerID=id;providerEnabled=true;connectionStatus=nil}
    @Published var configuration: AgentConfiguration
    @Published var endpoint: String
    @Published var token = ""
    @Published var replaceToken = false
    @Published var model: String
    @Published var detected: [String]
    @Published var reasoning = false
    @Published var images = false
    @Published var result = ""
    @Published var busy = false
    @Published var tokenStored = false
    let agent: AgentService
    init(agent:AgentService,runtime:PiRuntimeService = PiRuntimeService()) {
        self.agent=agent; configuration=agent.configuration
        endpoint=agent.configuration.omlx.endpoint.absoluteString
        model=agent.configuration.omlx.defaultModel ?? ""; detected=agent.configuration.omlx.modelIDs
        reasoning=configuration.omlx.reasoningModels.contains(model); images=configuration.omlx.imageModels.contains(model)
        tokenStored=(try? OMLXCredentials.token(endpoint:configuration.omlx.endpoint)) != nil
    }
    func editToken(_ value:String) { token=value; replaceToken=true }
    func edited() throws -> AgentConfiguration {
        var value=configuration
        // Provider edits never select, validate or replace an agent installation.
        guard let url=URL(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw AgentError.message("Invalid endpoint.") }
        value.omlx.endpoint=url; _ = try value.omlx.validated()
        value.omlx.defaultModel=model.isEmpty ? nil:model
        value.omlx.modelIDs=Array(Set(detected+(model.isEmpty ? []:[model]))).sorted()
        value.omlx.reasoningModels.removeAll { $0 == model }; value.omlx.imageModels.removeAll { $0 == model }
        if reasoning && !model.isEmpty { value.omlx.reasoningModels.append(model) }
        if images && !model.isEmpty { value.omlx.imageModels.append(model) }
        return value
    }
    func testConnection() {
        busy=true
        Task {
            defer { busy=false }
            do {
                let value=try edited()
                let status=try await providerAdapter.inspect(agent:agent,configuration:value,token:replaceToken ? token:nil)
                connectionStatus=status
                detected=status.models.map(\.id)
                if model.isEmpty { model=detected.first ?? "" }
                result=status.detail + (status.memoryBytes.map { " · Memory: \(ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.memory))" } ?? "")
            } catch { connectionStatus = ProviderInspection(); result="Connection failed: \(error.localizedDescription)" }
        }
    }
    func save() {
        busy=true
        Task {
            defer { busy=false }
            do {
                let value=try edited()
                if value.omlx.enabled && value.omlx.defaultModel == nil { throw AgentError.message("Detect or enter an oMLX model first.") }
                try agent.updateConfiguration(value,token:replaceToken ? token:nil)
                configuration=value; token=""; replaceToken=false
                tokenStored=(try? OMLXCredentials.token(endpoint:value.omlx.endpoint)) != nil
                result="Saved. Idle runtimes reconnect with this configuration."
            } catch { result=error.localizedDescription }
        }
    }
}
