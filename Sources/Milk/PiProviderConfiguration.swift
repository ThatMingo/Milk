import Foundation

/// Pi-specific configuration, deliberately separate from installation records.
enum PiProviderID: String, Codable, CaseIterable, Identifiable {
    case configured, local
    var id: String { rawValue }
    var title: String { self == .local ? "Local" : "Pi configured providers" }
}
enum PiLocalAuthentication: String, Codable, CaseIterable { case none, apiKey }
struct PiModelCapabilities: Codable, Equatable, Identifiable {
    var id: String
    // Server values describe this endpoint's effective runtime, not theoretical capacity.
    var contextWindow: Int?
    var maxTokens: Int?
    var reasoning: Bool?
    var images: Bool?
    var reasoningOverride: Bool?
    var imagesOverride: Bool?
    var effectiveReasoning: Bool? { reasoning ?? reasoningOverride }
    var effectiveImages: Bool? { images ?? imagesOverride }
    var contextOverride: Int?
    var outputOverride: Int?
    var effectiveContext: Int? { contextOverride ?? contextWindow }
    var effectiveOutput: Int? { outputOverride ?? maxTokens }
    var isLaunchable: Bool {
        if let context = effectiveContext, context <= 0 { return false }
        if let output = effectiveOutput, output <= 0 { return false }
        if let context = effectiveContext, let output = effectiveOutput { return output <= context }
        return true
    }
}
struct PiLocalConfiguration: Codable, Equatable {
    var endpoint = URL(string: "http://127.0.0.1:8000/v1")!
    var authentication: PiLocalAuthentication = .none
    var models: [PiModelCapabilities] = []
    var selectedModel: String?
    var apiBase: URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.path = parts.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let url = parts.url ?? endpoint
        // Accept the common host:port shorthand; preserve custom proxy paths.
        return parts.path.isEmpty ? url.appendingPathComponent("v1") : url
    }
    func validated(requireModel: Bool = false) throws -> Self {
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw AgentError.message("Enter an HTTP(S) endpoint without credentials, query, or fragment.")
        }
        guard Set(models.map(\.id)).count == models.count, models.allSatisfy({ !$0.id.isEmpty }) else {
            throw AgentError.message("Model IDs must be nonempty and unique.")
        }
        for model in models {
            for limit in [model.contextWindow, model.maxTokens, model.contextOverride, model.outputOverride].compactMap({ $0 }) {
                guard limit > 0 else { throw AgentError.message("Model limits must be positive when supplied.") }
            }
            if let context = model.effectiveContext, let output = model.effectiveOutput, output > context {
                throw AgentError.message("Output capacity cannot exceed effective context capacity for \(model.id).")
            }
        }
        if requireModel {
            guard let selectedModel, models.contains(where: { $0.id == selectedModel && $0.isLaunchable }) else {
                throw AgentError.message("Choose or enter a Local model ID before starting Pi.")
            }
        }
        return self
    }
}
struct PiProviderConfiguration: Codable, Equatable {
    var provider: PiProviderID = .configured
    var local = PiLocalConfiguration()
    static let key = "Milk.agent.pi.providers.v1"
    func save(_ defaults: UserDefaults, key: String = Self.key) throws {
        _ = try local.validated()
        defaults.set(try JSONEncoder().encode(self), forKey: key)
    }
    /// Copy only; keep the legacy bytes and Keychain item for recovery. If Keychain
    /// is unavailable migration is retried on the next read, never committed halfway.
    static func load(_ defaults: UserDefaults, key: String = Self.key) throws -> Self {
        if let data = defaults.data(forKey: key) { return try JSONDecoder().decode(Self.self, from: data) }
        guard key == Self.key else { return .init() }
        guard let data = defaults.data(forKey: AgentConfiguration.key),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let old = root["omlx"] as? [String: Any] else { return .init() }
        var result = Self()
        result.provider = old["enabled"] as? Bool == true ? .local : .configured
        if let raw = old["endpoint"] as? String, let url = URL(string: raw) { result.local.endpoint = url }
        result.local.selectedModel = old["defaultModel"] as? String
        let ids = (old["modelIDs"] as? [String] ?? []) + [result.local.selectedModel].compactMap { $0 }
        let reasoning = old["reasoningModels"] as? [String] ?? []
        let images = old["imageModels"] as? [String] ?? []
        result.local.models = Array(Set(ids)).sorted().map {
            // Legacy numeric values were global guesses. Positive flags were user declarations.
            .init(id: $0, reasoningOverride: reasoning.contains($0) ? true : nil, imagesOverride: images.contains($0) ? true : nil)
        }
        _ = try result.local.validated()
        if let token = try AgentProviderCredentials.read(service: "dev.milk.omlx", account: result.local.endpoint.absoluteString) {
            if try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: result.local.endpoint) == nil {
                try AgentProviderCredentials.save(token, agent: .pi, provider: "local", endpoint: result.local.endpoint)
            }
            result.local.authentication = .apiKey
        }
        try result.save(defaults)
        return result
    }
}
