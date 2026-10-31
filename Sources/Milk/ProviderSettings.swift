import Foundation

// Only actual configured adapters appear in the catalog. Runtime selection stays separate.
enum PiProviderID:String,CaseIterable,Identifiable { case omlx; var id:String {rawValue}; var title:String {switch self {case .omlx:return "oMLX"}} }
enum ProviderConfigurationKind { case omlx }
struct ProviderModelStatus:Identifiable {var id:String;var state:String?;var loaded:Bool?}
struct ProviderInspection {
    var reachable=false
    var authenticated:Bool?
    var checkedAt:Date?
    var detail="Not tested"
    var models:[ProviderModelStatus]=[]
    var memoryBytes:Double?
    init() {}
    init(omlx:OMLXStatus) {
        reachable=omlx.reachable;authenticated=omlx.authenticated;checkedAt=omlx.checkedAt;detail=omlx.detail;memoryBytes=omlx.memoryBytes
        models=omlx.models.map {.init(id:$0.id,state:$0.state,loaded:$0.loaded)}
    }
}
@MainActor protocol ProviderSettingsAdapter {
    var id:PiProviderID {get}
    var configurationKind:ProviderConfigurationKind {get}
    func isEnabled(in configuration:AgentConfiguration)->Bool
    func setEnabled(_ enabled:Bool,in configuration:inout AgentConfiguration)
    func inspect(agent:AgentService,configuration:AgentConfiguration,token:String?) async throws -> ProviderInspection
}
struct OMLXProviderSettingsAdapter:ProviderSettingsAdapter {
    let id=PiProviderID.omlx
    let configurationKind=ProviderConfigurationKind.omlx
    func isEnabled(in configuration:AgentConfiguration)->Bool {configuration.omlx.enabled}
    func setEnabled(_ enabled:Bool,in configuration:inout AgentConfiguration) {configuration.omlx.enabled=enabled}
    func inspect(agent:AgentService,configuration:AgentConfiguration,token:String?) async throws -> ProviderInspection {
        ProviderInspection(omlx:try await agent.testOMLX(configuration.omlx,token:token))
    }
}
@MainActor enum ProviderSettingsCatalog {
    static func adapter(for id:PiProviderID) -> any ProviderSettingsAdapter {
        switch id {case .omlx:return OMLXProviderSettingsAdapter()}
    }
}
