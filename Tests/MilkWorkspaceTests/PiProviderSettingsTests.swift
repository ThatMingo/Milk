import XCTest
import Security
@testable import Milk

private final class LocalDiscoveryProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class PiProviderSettingsTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let name = "Milk.Provider.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Local-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func discovery(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> PiLocalDiscovery {
        LocalDiscoveryProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocalDiscoveryProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); LocalDiscoveryProtocol.handler = nil }
        return .init(session: session)
    }
    func testEndpointValidationAndProxyPaths() throws {
        var local = PiLocalConfiguration()
        for raw in ["http://127.0.0.1:8000", "http://127.0.0.1:8000/v1/"] {
            local.endpoint = URL(string: raw)!; XCTAssertEqual(try local.validated().apiBase.absoluteString, "http://127.0.0.1:8000/v1")
        }
        local.endpoint = URL(string: "https://server.example/proxy/openai/")!
        XCTAssertEqual(local.apiBase.absoluteString, "https://server.example/proxy/openai")
        for raw in ["file:///tmp/config", "https://user:secret@example.com", "https://example.com?key=secret", "http://host/#fragment"] {
            local.endpoint = URL(string: raw)!; XCTAssertThrowsError(try local.validated())
        }
    }
    func testNoAuthDiscoveryPreservesExactIDsAndUnknownCapabilities() async throws {
        let service = discovery { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"data":[{"id":"org/Qwen:Q4_K_M"},{"id":"org/Qwen:Q4_K_M"},{"id":"other","max_model_len":999999}]}"#)
        }
        let result = try await service.inspect(.init(), token: "must-not-be-sent")
        XCTAssertEqual(result.models.map(\.id), ["org/Qwen:Q4_K_M", "other"])
        for model in result.models {
            XCTAssertNil(model.effectiveContext); XCTAssertNil(model.effectiveOutput)
            XCTAssertNil(model.effectiveReasoning); XCTAssertNil(model.effectiveImages); XCTAssertTrue(model.isLaunchable)
        }
    }
    func testAPIKeyDiscoveryAndExplicitLimitOverridesPreserveReportedMetadata() async throws {
        let service = discovery { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-secret")
            return (200, #"{"data":[{"id":"one","context_window":262144,"effective_context_window":131072,"max_tokens":16000,"effective_max_tokens":4000,"reasoning":true,"input":["text","image"]},{"id":"two","context_window":90000,"max_tokens":3000,"reasoning":false}]}"#)
        }
        var local = PiLocalConfiguration(); local.authentication = .apiKey
        let result = try await service.inspect(local, token: "scoped-secret")
        var first = try XCTUnwrap(result.models.first); first.contextOverride = 262144; first.outputOverride = 12000
        XCTAssertEqual(first.effectiveContext, 262144); XCTAssertEqual(first.effectiveOutput, 12000)
        XCTAssertEqual(first.contextWindow, 131072); XCTAssertEqual(first.maxTokens, 4000)
        XCTAssertEqual(first.effectiveReasoning, true); XCTAssertEqual(first.effectiveImages, true)
        XCTAssertEqual(result.models[1].contextWindow, 90000); XCTAssertNil(result.models[1].images)
    }
    func testAuthenticationFailureMalformedDiscoveryAndUnavailableEndpoint() async throws {
        var local = PiLocalConfiguration(); local.authentication = .apiKey
        do { _ = try await discovery { _ in XCTFail("Missing key should not send a request"); return (200, "{}") }.inspect(local, token: nil); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
        for (code, body) in [(401, "{}"), (200, "{}"), (200, "not-json")] {
            do { _ = try await discovery { _ in (code, body) }.inspect(.init(), token: nil); XCTFail() } catch {}
        }
        do { _ = try await discovery { _ in throw URLError(.cannotConnectToHost) }.inspect(.init(), token: nil); XCTFail() } catch {}
    }
    func testScopedKeychainNeverSerializesSecrets() throws {
        let endpoint = URL(string: "http://127.0.0.1:8000/" + UUID().uuidString)!
        defer { try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint) }
        try AgentProviderCredentials.save("scoped-secret", agent: .pi, provider: "local", endpoint: endpoint)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint), "scoped-secret")
        XCTAssertNil(try AgentProviderCredentials.token(agent: .init(rawValue: "test-agent"), provider: "local", endpoint: endpoint))
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "other", endpoint: endpoint))
        var value = PiProviderConfiguration(); value.local.endpoint = endpoint
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(text.contains("scoped-secret")); XCTAssertFalse(text.contains("apiKey"))
        try AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint)
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint))
    }
    func testLegacyMigrationCopiesCredentialAndFlagsDiscardsGlobalLimitsAndIsIdempotent() throws {
        let defaults = preferences(), endpoint = URL(string: "http://127.0.0.1:8000/legacy-" + UUID().uuidString)!
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.milk.omlx", kSecAttrAccount as String: endpoint.absoluteString]
        XCTAssertEqual(SecItemAdd(query.merging([kSecValueData as String: Data("legacy-secret".utf8)]) { _, b in b } as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(query as CFDictionary); try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint) }
        let data = try JSONSerialization.data(withJSONObject: ["omlx": ["enabled": true, "endpoint": endpoint.absoluteString, "modelIDs": ["exact/model:Q4"], "defaultModel": "exact/model:Q4", "reasoningModels": ["exact/model:Q4"], "imageModels": ["exact/model:Q4"], "contextWindow": 32768, "maxTokens": 8192]])
        defaults.set(data, forKey: AgentConfiguration.key)
        let value = try PiProviderConfiguration.load(defaults)
        XCTAssertEqual(value.provider, .local); XCTAssertEqual(value.local.endpoint, endpoint)
        XCTAssertEqual(value.local.authentication, .apiKey); XCTAssertEqual(value.local.selectedModel, "exact/model:Q4")
        let model = try XCTUnwrap(value.local.models.first)
        XCTAssertEqual(model.effectiveReasoning, true); XCTAssertEqual(model.effectiveImages, true)
        XCTAssertNil(model.effectiveContext); XCTAssertNil(model.effectiveOutput)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint), "legacy-secret")
        XCTAssertEqual(try AgentProviderCredentials.read(service: "dev.milk.omlx", account: endpoint.absoluteString), "legacy-secret")
        let saved = defaults.data(forKey: PiProviderConfiguration.key)
        XCTAssertEqual(try PiProviderConfiguration.load(defaults), value)
        XCTAssertEqual(defaults.data(forKey: PiProviderConfiguration.key), saved)
        XCTAssertEqual(defaults.data(forKey: AgentConfiguration.key), data)
        XCTAssertFalse(String(decoding: saved!, as: UTF8.self).contains("legacy-secret"))
    }
    func testPermissionSavesPreserveUnmigratedLegacyStateAndDisabledProviderRemainsDisabled() throws {
        let defaults = preferences()
        let endpoint = "http://127.0.0.1:8000/unused-" + UUID().uuidString
        defaults.set(try JSONSerialization.data(withJSONObject: ["omlx": ["enabled": false, "endpoint": endpoint, "defaultModel": "retained"]]), forKey: AgentConfiguration.key)
        var settings = AgentConfiguration.load(defaults); settings.defaultPermission = .autonomous; try settings.save(defaults)
        let migrated = try PiProviderConfiguration.load(defaults)
        XCTAssertEqual(migrated.provider, .configured); XCTAssertEqual(migrated.local.endpoint.absoluteString, endpoint)
        XCTAssertEqual(migrated.local.selectedModel, "retained"); XCTAssertEqual(AgentConfiguration.load(defaults).defaultPermission, .autonomous)
    }
    func testInvalidMigrationIsNonDestructiveAndRetryable() throws {
        let defaults = preferences(), data = Data(#"{"omlx":{"enabled":true,"endpoint":"file:///tmp/no"}}"#.utf8)
        defaults.set(data, forKey: AgentConfiguration.key)
        XCTAssertThrowsError(try PiProviderConfiguration.load(defaults))
        XCTAssertNil(defaults.data(forKey: PiProviderConfiguration.key)); XCTAssertEqual(defaults.data(forKey: AgentConfiguration.key), data)
    }
    @MainActor func testPiConfigurationMergeUnknownLimitsAndReadOnlyFileSafety() throws {
        let directory = try temporary(), file = directory.appendingPathComponent("models.json")
        let original = Data("{ // existing user configuration\n \"providers\": {\"existing\": {\"baseUrl\":\"http://example.com\"}}, \"extra\":true, }".utf8)
        try original.write(to: file)
        var value = PiProviderConfiguration(); value.provider = .local; value.local.selectedModel = "not-in-catalog"
        value.local.models = [.init(id: "org/Qwen:Q4")]
        var environment: [String: String] = [:]
        XCTAssertThrowsError(try PiProviderSupport.apply(value, directory: directory, environment: &environment))
        XCTAssertEqual(try Data(contentsOf: file), original)
        value.local.selectedModel = "org/Qwen:Q4"
        value.local.models[0].contextOverride = 64000; value.local.models[0].outputOverride = 4000
        try PiProviderSupport.apply(value, directory: directory, environment: &environment)
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(root["providers"]["existing"]["baseUrl"].string, "http://example.com")
        let model = root["providers"][PiProviderSupport.providerID]["models"].array[0]
        XCTAssertEqual(model["id"].string, "org/Qwen:Q4"); XCTAssertEqual(model["contextWindow"].number, 64000)
        XCTAssertNil(model["reasoning"].boolValue); XCTAssertTrue(model["input"].array.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("models.pre-milk-local.") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        try PiProviderSupport.apply(value, directory: directory, environment: &environment)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 2)
        value.provider = .configured; try PiProviderSupport.apply(value, directory: directory, environment: &environment)
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        XCTAssertNil(restored["providers"][PiProviderSupport.providerID]["name"].string)
        XCTAssertEqual(restored["providers"]["existing"]["baseUrl"].string, "http://example.com")
    }
    @MainActor func testMalformedPiConfigurationIsNeverOverwritten() throws {
        let directory = try temporary(), file = directory.appendingPathComponent("models.json"), bytes = Data("malformed".utf8)
        try bytes.write(to: file)
        var environment: [String: String] = [:]
        XCTAssertThrowsError(try PiProviderSupport.apply(.init(), directory: directory, environment: &environment))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    @MainActor func testSettingsBoundarySessionOwnershipDraftsAndActiveRunBarrier() throws {
        let defaults = preferences(), root = try temporary()
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, enabled: false))
        let adapter = PiAdapter(runtime: .init(environmentOverrides: ["PI_CODING_AGENT_DIR": root.path]), defaults: defaults)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter)
        agent.sessions = [.init(id: 7, title: "Keep", metadata: .init(agentID: .pi))]
        agent.conversations[7] = .init(draft: "keep draft")
        let identity = agent.sessions[0].backendID
        XCTAssertEqual(adapter.settingsSections.map(\.id), ["pi.configuration"])
        XCTAssertEqual(agent.registry.adapters.map(\.descriptor.id), [.pi])
        let draft = PiSettingsModel(agent: agent, adapter: adapter)
        draft.configuration.provider = .local; draft.model = "one"; draft.context = "64000"; draft.output = "4000"
        draft.save(); XCTAssertTrue(draft.result.hasPrefix("Saved."), draft.result)
        XCTAssertEqual(agent.sessions[0].agentID, .pi); XCTAssertEqual(agent.sessions[0].backendID, identity)
        XCTAssertEqual(agent.conversations[7]?.draft, "keep draft")
        agent.sessions[0].state = .running
        let before = defaults.data(forKey: try adapter.providerProfileIdentity.settingsKey)
        draft.model = "blocked"; draft.save()
        XCTAssertEqual(defaults.data(forKey: try adapter.providerProfileIdentity.settingsKey), before)
        XCTAssertTrue(draft.result.contains("Stop running"))
        agent.shutdown()
    }
    @MainActor func testSaveClearsSecretDraftRetainsUnchangedCredentialAndInstallationState() throws {
        let defaults = preferences(), root = try temporary(), endpoint = URL(string: "http://127.0.0.1:8000/" + UUID().uuidString)!
        let profile = PiProviderProfileIdentity(directory: root).rawValue
        defer { try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: profile) }
        var provider = PiProviderConfiguration(); provider.local.endpoint = endpoint; try provider.save(defaults, key: PiProviderProfileIdentity(directory: root).settingsKey)
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, enabled: false))
        let adapter = PiAdapter(runtime: .init(environmentOverrides: ["PI_CODING_AGENT_DIR": root.path]), defaults: defaults)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter)
        let model = PiSettingsModel(agent: agent, adapter: adapter)
        model.configuration.provider = .local; model.configuration.local.authentication = .apiKey
        model.model = "one"; model.context = "64000"; model.output = "4000"
        model.token = "draft-secret"; model.replaceToken = true
        model.save(); XCTAssertTrue(model.result.hasPrefix("Saved."), model.result)
        XCTAssertEqual(model.token, ""); XCTAssertFalse(model.replaceToken); XCTAssertTrue(model.tokenStored)
        model.save(); XCTAssertTrue(model.result.hasPrefix("Saved."), model.result)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: profile), "draft-secret")
        XCTAssertTrue(agent.configuration.runtime.isBundled); XCTAssertTrue(agent.lifecycle.owned.isEmpty)
        let manifest = try String(contentsOf: root.appendingPathComponent("models.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("draft-secret")); XCTAssertTrue(manifest.contains("$MILK_PI_LOCAL_KEY"))
        // A malformed existing Pi file must fail before replacing the saved key/draft.
        let file = root.appendingPathComponent("models.json"), malformed = Data("malformed".utf8)
        try malformed.write(to: file)
        model.token = "must-not-save"; model.replaceToken = true; model.save()
        XCTAssertFalse(model.result.hasPrefix("Saved."))
        XCTAssertEqual(try Data(contentsOf: file), malformed)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: profile), "draft-secret")
        // Removing a key is usable by switching to None, and requires no new key.
        try Data(manifest.utf8).write(to: file)
        model.configuration.local.authentication = .none; model.token = ""; model.replaceToken = true
        model.save(); XCTAssertTrue(model.result.hasPrefix("Saved."), model.result)
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: profile))

    }
    func testProductionSourceHasNoLegacyProviderInjectionOrGlobalPolling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("32768"), file.path); XCTAssertFalse(text.contains("contextWindow = 8192"), file.path)
            XCTAssertFalse(text.contains("MILK_OMLX_"), file.path)
        }
        let core = try String(contentsOf: root.appendingPathComponent("Sources/Milk/AgentService.swift"), encoding: .utf8)
        XCTAssertFalse(core.contains("Telemetry")); XCTAssertFalse(core.contains("omlx")); XCTAssertFalse(core.contains("PiLocalDiscovery"))
        let global = try String(contentsOf: root.appendingPathComponent("Sources/Milk/SettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(global.contains("PiProviderID")); XCTAssertFalse(global.contains("omlx")); XCTAssertFalse(global.contains("ProviderConfigurationRows"))
        let bridge = try String(contentsOf: root.appendingPathComponent("Runtime/MilkPiIntegration.ts"), encoding: .utf8)
        XCTAssertFalse(bridge.contains("registerProvider")); XCTAssertFalse(bridge.contains("contextWindow"))
    }
}
