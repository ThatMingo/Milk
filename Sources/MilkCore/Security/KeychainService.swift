import Foundation
import Security
import OSLog

public protocol CredentialStoring: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}
public struct KeychainService: CredentialStoring {
    private let service: String
    public init(service: String = "Milk.credentials") { self.service = service }
    private func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    public func read(account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw MilkError.message("Keychain read failed (\(status))") }
        return result as? Data
    }
    public func write(_ data: Data, account: String) throws {
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var add = q; add[kSecValueData as String] = data; status = SecItemAdd(add as CFDictionary, nil) }
        guard status == errSecSuccess else { throw MilkError.message("Keychain write failed (\(status))") }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MilkError.message("Keychain delete failed (\(status))") }
    }
}
public enum Diagnostics {
    private static let logger = Logger(subsystem: "dev.thatmingo.Milk", category: "lifecycle")
    /// Only fixed categories/codes belong here. Raw external text is never public log data.
    public static func event(_ category: String, code: Int = 0) { logger.info("\(category, privacy: .private) code=\(code)") }
}
