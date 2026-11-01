import Foundation

/// Translation into Pi's documented configuration; no extension provider stack.
enum PiProviderSupport {
    static let providerID = "milk-local"
    static let credentialVariable = "MILK_PI_LOCAL_KEY"
    static let noAuthVariable = "MILK_PI_LOCAL_NO_AUTH"
    static let displayName = "Local (Milk Pi settings)"
    static func apply(_ configuration: PiProviderConfiguration, directory: URL, environment: inout [String: String], credential: String? = nil, profile: String? = nil) throws {
        environment.removeValue(forKey: credentialVariable)
        environment.removeValue(forKey: noAuthVariable)
        let file = directory.appendingPathComponent("models.json")
        var root: [String: Any] = [:]
        let existing = try? Data(contentsOf: file)
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing, options: [.json5Allowed]) as? [String: Any] else {
                throw AgentError.message("Pi models.json must contain an object. The original file was preserved.")
            }
            root = parsed
        } else if FileManager.default.fileExists(atPath: file.path) {
            throw AgentError.message("Pi models.json could not be read. The original file was preserved.")
        }
        guard root["providers"] == nil || root["providers"] is [String: Any] else { throw AgentError.message("Pi models.json providers must be an object.") }
        var providers = root["providers"] as? [String: Any] ?? [:]
        if providers[providerID] != nil, (providers[providerID] as? [String: Any])?["name"] as? String != displayName {
            if configuration.provider == .configured { return }
            throw AgentError.message("Pi already has a provider named \(providerID). Rename it before configuring Local in Milk; nothing was replaced.")
        }
        if configuration.provider == .local {
            let local = try configuration.local.validated(requireModel: true)
            let models: [[String: Any]] = local.models.filter(\.isLaunchable).map { model in
                var value: [String: Any] = ["id": model.id]
                if let context = model.effectiveContext { value["contextWindow"] = context }
                if let output = model.effectiveOutput { value["maxTokens"] = output }
                if let reasoning = model.effectiveReasoning { value["reasoning"] = reasoning }
                if let images = model.effectiveImages { value["input"] = images ? ["text", "image"] : ["text"] }
                return value
            }
            var value: [String: Any] = ["name": displayName, "api": "openai-completions", "baseUrl": local.apiBase.absoluteString, "models": models,
                                        "authHeader": local.authentication == .apiKey]
            if local.authentication == .apiKey {
                guard let raw = try credential ?? AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: local.endpoint, profile: profile),
                      case let key = try AgentProviderCredentials.normalized(raw), !key.isEmpty else {
                    throw AgentError.message("The Local API key is missing from Keychain.")
                }
                environment[credentialVariable] = key
                value["apiKey"] = "$" + credentialVariable
            } else {
                // Pi's catalog requires an availability key. The documented headers
                // hook removes Authorization before the request reaches the server.
                environment[noAuthVariable] = "1"
                value["apiKey"] = "local-no-auth"
            }
            providers[providerID] = value
        } else {
            guard providers[providerID] != nil else { return }
            providers.removeValue(forKey: providerID)
        }
        root["providers"] = providers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let existing, let old = try? JSONSerialization.jsonObject(with: existing, options: [.json5Allowed]),
           NSDictionary(dictionary: root).isEqual(to: old as? [AnyHashable: Any] ?? [:]) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing {
            // Original bytes (including JSONC comments) retained before normalization.
            let backup = directory.appendingPathComponent("models.pre-milk-local.\(UUID().uuidString).json")
            try existing.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
