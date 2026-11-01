import XCTest
import Security
import LocalAuthentication
@testable import Milk

final class AgentProviderCredentialTests: XCTestCase {
    private var store: CredentialTestStore!
    override func setUp() { super.setUp(); store = CredentialTestStore() }
    override func tearDown() { store.restore(); store = nil; super.tearDown() }
    func testCRUDExistenceScopingAndProtection() throws {
        let endpoint = URL(string: "http://localhost:8000/v1")!
        func save(_ value: String) throws { try AgentProviderCredentials.save(value, agent: .pi, provider: "local", endpoint: endpoint, profile: "one") }
        func read() throws -> String? { try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "one") }
        try save(" \nfixture-sub-key\r\n")
        XCTAssertEqual(try read(), "fixture-sub-key")
        XCTAssertTrue(try AgentProviderCredentials.exists(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"))
        XCTAssertNil(store.queries.last?[kSecReturnData as String])
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "two"))
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint.appendingPathComponent("other"), profile: "one"))
        try save("replacement"); XCTAssertEqual(try read(), "replacement")
        XCTAssertThrowsError(try save("bad\nkey")); XCTAssertEqual(try read(), "replacement")
        for query in store.queries {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
            XCTAssertNil(query[kSecAttrAccessGroup as String]); XCTAssertNil(query[kSecAttrAccessControl as String])
        }
        let added = try XCTUnwrap(store.queries.first { $0[kSecValueData as String] != nil })
        XCTAssertEqual(added[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try save(""); XCTAssertNil(try read())
        XCTAssertFalse(try AgentProviderCredentials.exists(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"))
    }
    func testLegacyScopedCredentialWinsAndNewEntryIsNeverOverwritten() throws {
        let endpoint = URL(string: "http://localhost:8000/v1")!
        let account = AgentProviderCredentials.account(agent: .pi, provider: "local", endpoint: endpoint, profile: "one")
        store.seedLegacy(service: "dev.milk.agent-provider", account: account, token: "scoped-old")
        store.seedLegacy(service: "dev.milk.omlx", account: endpoint.absoluteString, token: "admin-old")
        XCTAssertTrue(try AgentProviderCredentials.importLegacy(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"))
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"), "scoped-old")
        try AgentProviderCredentials.save("new-sub-key", agent: .pi, provider: "local", endpoint: endpoint, profile: "one")
        let before = store.queries.count
        XCTAssertTrue(try AgentProviderCredentials.importLegacy(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"))
        XCTAssertEqual(store.queries.count, before + 1)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"), "new-sub-key")
        XCTAssertEqual(store.items.count, 3, "Legacy entries remain for recovery")
    }
    func testMissingEntitlementFailsClosed() throws {
        AgentProviderCredentials.copyMatching = { _, _ in errSecMissingEntitlement }
        XCTAssertThrowsError(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: URL(string: "http://localhost/v1")!)) { error in
            XCTAssertTrue(error.localizedDescription.contains("provisioned"))
        }
    }
}
