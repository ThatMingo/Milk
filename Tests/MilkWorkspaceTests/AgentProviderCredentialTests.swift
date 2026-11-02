import XCTest
import Security
@testable import Milk

final class AgentProviderCredentialTests: XCTestCase {
    private var store: CredentialTestStore!
    override func setUp() { super.setUp(); store = CredentialTestStore() }
    override func tearDown() { store.restore(); store = nil; super.tearDown() }
    func testCRUDExistenceScopingAndOrdinaryKeychainAttributes() throws {
        let endpoint = URL(string: "http://localhost:8000/v1")!
        func save(_ value: String) throws { try AgentProviderCredentials.save(value, agent: .pi, provider: "local", endpoint: endpoint, profile: "one") }
        func read() throws -> String? { try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "one") }
        try save(" \nfixture-sub-key\r\n")
        XCTAssertEqual(try read(), "fixture-sub-key")
        XCTAssertTrue(try AgentProviderCredentials.exists(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"))
        XCTAssertNil(store.queries.last?[kSecReturnData as String])
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "two"))
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint.appendingPathComponent("other"), profile: "one"))
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "other", endpoint: endpoint, profile: "one"))
        XCTAssertNil(try AgentProviderCredentials.token(agent: .init(rawValue:"other"), provider: "local", endpoint: endpoint, profile: "one"))
        try save("replacement"); XCTAssertEqual(try read(), "replacement")
        XCTAssertThrowsError(try save("bad\nkey")); XCTAssertEqual(try read(), "replacement")
        for query in store.queries {
            XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
            XCTAssertNil(query[kSecAttrSynchronizable as String])
            XCTAssertNil(query[kSecUseAuthenticationContext as String])
            XCTAssertNil(query[kSecAttrAccessGroup as String]); XCTAssertNil(query[kSecAttrAccessControl as String])
        }
        let added = try XCTUnwrap(store.queries.first { $0[kSecValueData as String] != nil })
        XCTAssertNil(added[kSecAttrAccessible as String])
        XCTAssertTrue(store.queryInteractionStates.allSatisfy { !$0 })
        XCTAssertTrue(store.interactionAllowed,"Restore the caller's prior interaction state")
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
        XCTAssertEqual(store.queries.count, before + 2,"Metadata then explicit authorization read; no older namespace lookup")
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: "one"), "new-sub-key")
        XCTAssertEqual(store.items.count, 3, "Legacy entries remain for recovery")
    }
    func testUnavailableAndAuthorizationErrorsFailClosedWithoutProvisioningOrFallback() throws {
        for status in [errSecNotAvailable,errSecInteractionNotAllowed,errSecAuthFailed,errSecMissingEntitlement] {
            AgentProviderCredentials.copyMatching = { _, _ in status }
            XCTAssertThrowsError(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: URL(string: "http://localhost/v1")!)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Keychain"))
                XCTAssertTrue(error.localizedDescription.contains("No file or settings fallback"))
                XCTAssertFalse(error.localizedDescription.contains("provision"))
            }
            XCTAssertTrue(store.interactionAllowed)
        }
        XCTAssertTrue(store.items.isEmpty)
    }
    func testInteractionScopeRestoresNestedExplicitRecoveryAndErrors() throws {
        store.interactionAllowed=false
        XCTAssertThrowsError(try AgentProviderCredentials.withKeychain(interactive:true) {
            XCTAssertTrue(store.interactionAllowed)
            try AgentProviderCredentials.withKeychain { XCTAssertFalse(store.interactionAllowed) }
            XCTAssertTrue(store.interactionAllowed)
            throw CancellationError()
        })
        XCTAssertFalse(store.interactionAllowed)
        XCTAssertEqual(store.interactionChanges,[true,false,true,false])
        AgentProviderCredentials.getInteractionAllowed = { _ in errSecNotAvailable }
        var invoked=false
        XCTAssertThrowsError(try AgentProviderCredentials.withKeychain { invoked=true })
        XCTAssertFalse(invoked)
    }
    func testExplicitRecoveryAloneMayAuthorizeExistingCredential() throws {
        let endpoint=URL(string:"http://localhost:8000/v1")!
        try AgentProviderCredentials.save("synthetic",agent:.pi,provider:"local",endpoint:endpoint,profile:"one")
        store.queryInteractionStates=[]
        XCTAssertTrue(try AgentProviderCredentials.importLegacy(agent:.pi,provider:"local",endpoint:endpoint,profile:"one"))
        XCTAssertEqual(store.queryInteractionStates,[false,true])
        XCTAssertEqual(store.items.count,1)
    }
    func testWriteAndInteractionFailuresNeverFallBack() throws {
        let endpoint=URL(string:"http://localhost:8000/unavailable")!
        AgentProviderCredentials.update = { _,_ in errSecItemNotFound }
        AgentProviderCredentials.add = { _,_ in errSecNotAvailable }
        XCTAssertThrowsError(try AgentProviderCredentials.save("synthetic",agent:.pi,provider:"local",endpoint:endpoint,profile:"one"))
        AgentProviderCredentials.delete = { _ in errSecNotAvailable }
        XCTAssertThrowsError(try AgentProviderCredentials.save("",agent:.pi,provider:"local",endpoint:endpoint,profile:"one"))
        XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.interactionAllowed)
        AgentProviderCredentials.setInteractionAllowed = { _ in errSecNotAvailable }
        var invoked=false
        XCTAssertThrowsError(try AgentProviderCredentials.withKeychain { invoked=true })
        XCTAssertFalse(invoked)
    }
}
