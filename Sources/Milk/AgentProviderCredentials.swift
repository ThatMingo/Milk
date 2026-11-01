import Foundation
import Security
import LocalAuthentication

/// The only persistent secret store. No fallback to the file-based Keychain.
/// The app's default, provisioned access group is private to Milk.
enum AgentProviderCredentials {
    static let service = "dev.milk.agent-provider.dp.v1"
    // Internal injection point for isolated tests; production always calls Security.framework.
    static var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    static var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    static var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    static var delete: (CFDictionary) -> OSStatus = SecItemDelete

    static func normalized(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AgentError.message("The API key contains whitespace or control characters. Paste the key alone.")
        }
        return value
    }
    static func account(agent: AgentID, provider: String, endpoint: URL, profile: String?) -> String {
        JSONValue.array([.string(agent.rawValue)] + (profile.map { [.string($0)] } ?? []) + [.string(provider), .string(endpoint.absoluteString)]).encodedString
    }
    static func query(service: String, account: String, protection: Bool = true, interactive: Bool = false) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: protection,
            kSecAttrSynchronizable as String: false]
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            value[kSecUseAuthenticationContext as String] = context
        }
        return value
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            if status == errSecMissingEntitlement {
                throw AgentError.message("Secure credential storage requires a provisioned Milk build with its application identifier entitlement. Ad-hoc builds cannot save or read API keys. See docs/API_KEYCHAIN.md.")
            }
            throw AgentError.message("Keychain operation failed (\(status)). Unlock your login session or use a provisioned Milk build.")
        }
    }
    static func token(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws -> String? {
        try read(service: service, account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
    }
    static func exists(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws -> Bool {
        var query = query(service: service, account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // No kSecReturnData: UI checks must not retrieve the secret.
        let status = copyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status); return true
    }
    static func read(service: String, account: String, protection: Bool = true, interactive: Bool = false) throws -> String? {
        var query = query(service: service, account: account, protection: protection, interactive: interactive)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AgentError.message("The stored credential is not a UTF-8 API key.")
        }
        return try normalized(value)
    }
    static func save(_ token: String, agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws {
        let token = try normalized(token)
        let query = query(service: service, account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
        if token.isEmpty {
            let status = delete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }; return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = add(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        try check(status)
    }
    /// Explicit Settings action only. A successful import is its own durable marker.
    /// Never overwrite a newer scoped credential, and never delete the original.
    static func importLegacy(agent: AgentID, provider: String, endpoint: URL, profile: String) throws -> Bool {
        if try exists(agent: agent, provider: provider, endpoint: endpoint, profile: profile) { return true }
        let scoped = account(agent: agent, provider: provider, endpoint: endpoint, profile: profile)
        let unscoped = account(agent: agent, provider: provider, endpoint: endpoint, profile: nil)
        for (service, account) in [("dev.milk.agent-provider", scoped), ("dev.milk.agent-provider", unscoped), ("dev.milk.omlx", endpoint.absoluteString)] {
            if let token = try read(service: service, account: account, protection: false, interactive: true), !token.isEmpty {
                try save(token, agent: agent, provider: provider, endpoint: endpoint, profile: profile)
                guard try self.token(agent: agent, provider: provider, endpoint: endpoint, profile: profile) == token else {
                    throw AgentError.message("Imported credential could not be verified. The original remains in Keychain.")
                }
                return true
            }
        }
        return false
    }
}
