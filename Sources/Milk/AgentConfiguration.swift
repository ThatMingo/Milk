import Foundation

// Never resolve or prefer PATH for selecting a runtime.
enum PiRuntimeMode: Codable, Equatable {
    case bundled
    case external(URL)
    var isBundled: Bool { if case .bundled = self { return true }; return false }
}
struct AgentConfiguration: Codable, Equatable {
    var runtime: PiRuntimeMode = .bundled
    var defaultPermission: ComposerPermissionMode = .approval
    init() {}
    private enum CodingKeys:String,CodingKey { case runtime,defaultPermission }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        runtime=(try? values.decode(PiRuntimeMode.self,forKey:.runtime)) ?? .bundled
        defaultPermission=(try? values.decode(ComposerPermissionMode.self,forKey:.defaultPermission)) ?? .approval
    }
    // No arbitrary launch arguments: session, RPC and permission invariants are owned by Milk.
    static let key = "Milk.agent.configuration.v3"
    static func load(_ defaults: UserDefaults) -> Self {
        var value=defaults.data(forKey:key).flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? Self()
        if case .external(let url)=value.runtime, !url.isFileURL || !url.path.hasPrefix("/") { value.runtime = .bundled }
        return value
    }
    func save(_ defaults: UserDefaults) throws {
        // Preserve unmapped legacy fields for adapter-owned migration/recovery.
        var root = defaults.data(forKey: Self.key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        root.merge(current) { _, new in new }
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: Self.key)
    }
}
