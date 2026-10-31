import Foundation
import Security

/// Generic secure facility requested by adapters. Secrets never enter Codable settings.
enum AgentProviderCredentials {
    private static func account(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) -> String {
        // Structured encoding avoids ambiguous separators and preserves legacy endpoint identity.
        JSONValue.array([.string(agent.rawValue)] + (profile.map { [.string($0)] } ?? []) + [.string(provider), .string(endpoint.absoluteString)]).encodedString
    }
    static func token(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws -> String? {
        try read(service: "dev.milk.agent-provider", account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
    }
    // Adapters may request a read from their previous namespace during migration.
    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AgentError.message("Provider credential could not be read from Keychain (\(status)).") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.milk.agent-provider",
                                   kSecAttrAccount as String: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile)]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Keychain removal failed (\(status)).") }; return
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AgentError.message("Keychain save failed (\(status)).") }
    }
}
