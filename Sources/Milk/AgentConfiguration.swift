import Foundation
import Security

// Never resolve or prefer PATH for selecting a runtime.
enum PiRuntimeMode: Codable, Equatable {
    case bundled
    case external(URL)
    var isBundled: Bool { if case .bundled = self { return true }; return false }
}
struct OMLXConfiguration: Codable, Equatable {
    var enabled = false
    var endpoint = URL(string: "http://127.0.0.1:8000")!
    var modelIDs: [String] = []
    var defaultModel: String?
    // Optional declared capabilities for servers whose /v1/models omits them.
    var reasoningModels: [String] = []
    var imageModels: [String] = []
    var contextWindow = 32768
    var maxTokens = 8192
    init() {}
    private enum CodingKeys:String,CodingKey { case enabled,endpoint,modelIDs,defaultModel,reasoningModels,imageModels,contextWindow,maxTokens }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        enabled=(try? values.decode(Bool.self,forKey:.enabled)) ?? false
        endpoint=(try? values.decode(URL.self,forKey:.endpoint)) ?? URL(string:"http://127.0.0.1:8000")!
        modelIDs=(try? values.decode([String].self,forKey:.modelIDs)) ?? []
        defaultModel=try? values.decode(String.self,forKey:.defaultModel)
        reasoningModels=(try? values.decode([String].self,forKey:.reasoningModels)) ?? []
        imageModels=(try? values.decode([String].self,forKey:.imageModels)) ?? []
        contextWindow=(try? values.decode(Int.self,forKey:.contextWindow)) ?? 32768
        maxTokens=(try? values.decode(Int.self,forKey:.maxTokens)) ?? 8192
    }
    private var normalizedEndpoint: URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        parts?.path = endpoint.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return parts?.url ?? endpoint
    }
    var apiBase: URL { normalizedEndpoint.path.hasSuffix("/v1") ? normalizedEndpoint : normalizedEndpoint.appendingPathComponent("v1") }
    var serverBase: URL { normalizedEndpoint.path.hasSuffix("/v1") ? normalizedEndpoint.deletingLastPathComponent() : normalizedEndpoint }
    func validated() throws -> Self {
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw AgentError.message("Enter an HTTP(S) oMLX endpoint without credentials, query, or fragment.")
        }
        guard contextWindow > 0, maxTokens > 0, maxTokens <= contextWindow else { throw AgentError.message("Invalid model token limits.") }
        return self
    }
}
struct AgentConfiguration: Codable, Equatable {
    var runtime: PiRuntimeMode = .bundled
    var omlx = OMLXConfiguration()
    var defaultPermission: ComposerPermissionMode = .approval
    init() {}
    private enum CodingKeys:String,CodingKey { case runtime,omlx,defaultPermission }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        runtime=(try? values.decode(PiRuntimeMode.self,forKey:.runtime)) ?? .bundled
        omlx=(try? values.decode(OMLXConfiguration.self,forKey:.omlx)) ?? OMLXConfiguration()
        defaultPermission=(try? values.decode(ComposerPermissionMode.self,forKey:.defaultPermission)) ?? .approval
    }
    // No arbitrary launch arguments: session, RPC and permission invariants are owned by Milk.
    static let key = "Milk.agent.configuration.v3"
    static func load(_ defaults: UserDefaults) -> Self {
        var value=defaults.data(forKey:key).flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? Self()
        if (try? value.omlx.validated()) == nil { value.omlx=OMLXConfiguration() }
        if case .external(let url)=value.runtime, !url.isFileURL || !url.path.hasPrefix("/") { value.runtime = .bundled }
        return value
    }
    func save(_ defaults: UserDefaults) throws { defaults.set(try JSONEncoder().encode(self), forKey: Self.key) }
}

/// Tokens stay in the user's Keychain, outside the bundle and restoration snapshots.
enum OMLXCredentials {
    private static let service = "dev.milk.omlx"
    static func token(endpoint: URL) throws -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: endpoint.absoluteString, kSecReturnData as String: true]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AgentError.message("oMLX token could not be read from Keychain (\(status)).") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, endpoint: URL) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Keychain token removal failed (\(status)).") }; return
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AgentError.message("Keychain token save failed (\(status)).") }
    }
}
