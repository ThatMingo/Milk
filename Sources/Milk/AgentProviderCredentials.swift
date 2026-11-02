import Foundation
import Security

/// Ordinary macOS file-based Keychain is the only persistent secret store.
/// Default creator ACLs are retained; no provisioning, shared group or file fallback.
enum AgentProviderCredentials {
    static let service = "dev.milk.agent-provider.login.v1"
    // Internal injection point for isolated tests; production always calls Security.framework.
    static var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    static var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    static var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    static var delete: (CFDictionary) -> OSStatus = SecItemDelete
    static var getInteractionAllowed = SecKeychainGetUserInteractionAllowed
    static var setInteractionAllowed = SecKeychainSetUserInteractionAllowed
    private static let interactionLock = NSRecursiveLock()

    /// File-Keychain UI controls are process-scoped, unlike DP authentication contexts.
    /// No suspension inside the lock. Restore prior state even when the SecItem call fails.
    static func withKeychain<T>(interactive: Bool = false, _ body: () throws -> T) throws -> T {
        interactionLock.lock(); defer { interactionLock.unlock() }
        var previous: DarwinBoolean = false
        try check(getInteractionAllowed(&previous))
        let changed = previous.boolValue != interactive
        if changed { try check(setInteractionAllowed(interactive)) }
        let result: Result<T, Error>
        do { result = .success(try body()) } catch { result = .failure(error) }
        if changed { try check(setInteractionAllowed(previous.boolValue)) }
        return try result.get()
    }

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
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AgentError.message("Keychain operation failed (\(status)). Unlock your login Keychain. If Milk was rebuilt, use Recover Stored Key in Pi Settings to authorize this build, then retry. No file or settings fallback was used.")
        }
    }
    static func token(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws -> String? {
        try read(service: service, account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
    }
    static func exists(agent: AgentID, provider: String, endpoint: URL, profile: String? = nil) throws -> Bool {
        var query = query(service: service, account: account(agent: agent, provider: provider, endpoint: endpoint, profile: profile))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // No kSecReturnData: UI checks must not retrieve the secret.
        let status = try withKeychain { copyMatching(query as CFDictionary, nil) }
        if status == errSecItemNotFound { return false }
        try check(status); return true
    }
    static func read(service: String, account: String, interactive: Bool = false) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try withKeychain(interactive: interactive) { copyMatching(query as CFDictionary, &result) }
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
            let status = try withKeychain { delete(query as CFDictionary) }
            if status != errSecItemNotFound { try check(status) }; return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = try withKeychain { () -> OSStatus in
            let status = update(query as CFDictionary, attributes as CFDictionary)
            return status == errSecItemNotFound ? add(query.merging(attributes) { _, b in b } as CFDictionary, nil) : status
        }
        try check(status)
    }
    /// Explicit Settings action only. A successful import is its own durable marker.
    /// Never overwrite a newer scoped credential, and never delete the original.
    static func importLegacy(agent: AgentID, provider: String, endpoint: URL, profile: String) throws -> Bool {
        let scoped = account(agent: agent, provider: provider, endpoint: endpoint, profile: profile)
        if try exists(agent: agent, provider: provider, endpoint: endpoint, profile: profile) {
            // This explicit Settings action may authorize the current build's default ACL.
            // Do not replace the selected credential or consult an older namespace.
            return try read(service: service, account: scoped, interactive: true) != nil
        }
        let unscoped = account(agent: agent, provider: provider, endpoint: endpoint, profile: nil)
        for (service, account) in [("dev.milk.agent-provider", scoped), ("dev.milk.agent-provider", unscoped), ("dev.milk.omlx", endpoint.absoluteString)] {
            if let token = try read(service: service, account: account, interactive: true), !token.isEmpty {
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
