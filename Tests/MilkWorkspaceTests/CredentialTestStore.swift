import Foundation
import Security
@testable import Milk

/// Test-only SecItem simulation. Tests never touch the personal Keychain.
final class CredentialTestStore {
    var items: [String: Data] = [:]
    var queries: [[String: Any]] = []
    private let oldCopy = AgentProviderCredentials.copyMatching
    private let oldAdd = AgentProviderCredentials.add
    private let oldUpdate = AgentProviderCredentials.update
    private let oldDelete = AgentProviderCredentials.delete
    private func identity(_ q: [String: Any]) -> String {
        "\(q[kSecUseDataProtectionKeychain as String] as? Bool ?? false)|\(q[kSecAttrService as String]!)|\(q[kSecAttrAccount as String]!)"
    }
    init() {
        AgentProviderCredentials.copyMatching = { [unowned self] raw, result in
            let q = raw as! [String: Any]; self.queries.append(q)
            guard let data = self.items[self.identity(q)] else { return errSecItemNotFound }
            if q[kSecReturnData as String] as? Bool == true { result?.pointee = data as CFData }
            return errSecSuccess
        }
        AgentProviderCredentials.add = { [unowned self] raw, _ in
            let q = raw as! [String: Any]; self.queries.append(q)
            let id = self.identity(q)
            guard self.items[id] == nil else { return errSecDuplicateItem }
            self.items[id] = q[kSecValueData as String] as? Data; return errSecSuccess
        }
        AgentProviderCredentials.update = { [unowned self] raw, attributes in
            let q = raw as! [String: Any]; self.queries.append(q)
            let id = self.identity(q)
            guard self.items[id] != nil else { return errSecItemNotFound }
            self.items[id] = (attributes as! [String: Any])[kSecValueData as String] as? Data; return errSecSuccess
        }
        AgentProviderCredentials.delete = { [unowned self] raw in
            let q = raw as! [String: Any]; self.queries.append(q)
            return self.items.removeValue(forKey: self.identity(q)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
    func restore() {
        AgentProviderCredentials.copyMatching = oldCopy; AgentProviderCredentials.add = oldAdd
        AgentProviderCredentials.update = oldUpdate; AgentProviderCredentials.delete = oldDelete
    }
    func seedLegacy(service: String, account: String, token: String) {
        items["false|\(service)|\(account)"] = Data(token.utf8)
    }
}
