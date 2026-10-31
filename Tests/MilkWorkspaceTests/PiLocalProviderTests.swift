import XCTest
@testable import Milk

final class PiLocalProviderTests: XCTestCase {
    @MainActor func testUnknownPartialAndExplicitLimitsAreSerializedPerModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Local-Limits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = PiProviderConfiguration(); config.provider = .local
        config.local.selectedModel = "exact/org:model-Q4"
        config.local.models = [
            .init(id: "exact/org:model-Q4"),
            .init(id: "context-only", contextWindow: 96000),
            .init(id: "output-only", maxTokens: 6000),
            .init(id: "override", contextOverride: 72000, outputOverride: 5000),
            .init(id: "reported-effective", contextWindow: 64000, maxTokens: 4000, contextOverride: 90000, outputOverride: 8000)
        ]
        XCTAssertNoThrow(try config.local.validated(requireModel: true))
        var environment: [String: String] = [:]
        try PiProviderSupport.apply(config, directory: root, environment: &environment)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("models.json")))
        let models = json["providers"][PiProviderSupport.providerID]["models"].array
        XCTAssertEqual(models.map { $0["id"].string }, config.local.models.map { Optional($0.id) })
        XCTAssertNil(models[0]["contextWindow"].number); XCTAssertNil(models[0]["maxTokens"].number)
        XCTAssertEqual(models[1]["contextWindow"].number, 96000); XCTAssertNil(models[1]["maxTokens"].number)
        XCTAssertNil(models[2]["contextWindow"].number); XCTAssertEqual(models[2]["maxTokens"].number, 6000)
        XCTAssertEqual(models[3]["contextWindow"].number, 72000); XCTAssertEqual(models[3]["maxTokens"].number, 5000)
        XCTAssertEqual(models[4]["contextWindow"].number, 90000); XCTAssertEqual(models[4]["maxTokens"].number, 8000)
        XCTAssertEqual(environment[PiProviderSupport.noAuthVariable], "1")
        XCTAssertNil(config.local.models[0].effectiveContext); XCTAssertNil(config.local.models[0].effectiveOutput)
    }
    @MainActor func testOverridePrecedenceIndependentlyForContextAndOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Limit-Precedence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contexts: [(Int?, Int?, Int?)] = [(131072, nil, 131072), (131072, 65536, 65536), (nil, 65536, 65536), (nil, nil, nil)]
        let outputs: [(Int?, Int?, Int?)] = [(16000, nil, 16000), (16000, 8000, 8000), (nil, 8000, 8000), (nil, nil, nil)]
        var config = PiProviderConfiguration(); config.provider = .local
        for (i, context) in contexts.enumerated() {
            for (j, output) in outputs.enumerated() {
                config.local.models.append(.init(id: "case-\(i)-\(j)", contextWindow: context.0, maxTokens: output.0, contextOverride: context.1, outputOverride: output.1))
            }
        }
        config.local.selectedModel = "case-0-0"
        let original = config.local.models
        var environment: [String: String] = [:]
        try PiProviderSupport.apply(config, directory: root, environment: &environment)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("models.json")))
        let serialized = json["providers"][PiProviderSupport.providerID]["models"].array
        for (i, context) in contexts.enumerated() {
            for (j, output) in outputs.enumerated() {
                let model = try XCTUnwrap(serialized.first { $0["id"].string == "case-\(i)-\(j)" })
                XCTAssertEqual(model["contextWindow"].number, context.2.map(Double.init))
                XCTAssertEqual(model["maxTokens"].number, output.2.map(Double.init))
            }
        }
        XCTAssertEqual(config.local.models, original, "Serialization must preserve reported metadata and explicit overrides separately")
    }
    @MainActor func testUnknownLimitsDoNotBlockSettingsSave() throws {
        let fixture = try Phase6Fixture(self)
        try fixture.manager.migrateLegacySelection(.bundled)
        _ = try PiProfile.managed(store: fixture.manager.store)
        let adapter = PiAdapter(runtime: fixture.manager.runtime, installations: fixture.manager, defaults: fixture.defaults)
        let workspace = try fixture.workspace()
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: false, adapter: adapter)
        let model = PiSettingsModel(agent: agent, adapter: adapter)
        model.configuration.provider = .local; model.model = "unknown/exact:ID"
        model.save()
        XCTAssertTrue(model.result.hasPrefix("Saved."), model.result)
        let saved = try adapter.providerConfiguration()
        XCTAssertEqual(saved.local.selectedModel, "unknown/exact:ID")
        XCTAssertNil(saved.local.models.first?.effectiveContext); XCTAssertNil(saved.local.models.first?.effectiveOutput)
        agent.shutdown()
    }
    @MainActor func testAPIKeyTranslationUsesOnlySelectedProfileAndClearsNoAuthFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Local-Auth-" + UUID().uuidString)
        let endpoint = URL(string: "http://127.0.0.1:8000/" + UUID().uuidString)!
        let first = PiProviderProfileIdentity(directory: root.appendingPathComponent("first")).rawValue
        let second = PiProviderProfileIdentity(directory: root.appendingPathComponent("second")).rawValue
        defer {
            try? FileManager.default.removeItem(at: root)
            try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: first)
            try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: second)
        }
        try AgentProviderCredentials.save("first-secret", agent: .pi, provider: "local", endpoint: endpoint, profile: first)
        try AgentProviderCredentials.save("second-secret", agent: .pi, provider: "local", endpoint: endpoint, profile: second)
        var config = PiProviderConfiguration(); config.provider = .local; config.local.endpoint = endpoint
        config.local.models = [.init(id: "exact:model")]; config.local.selectedModel = "exact:model"
        var environment: [String: String] = [:]
        try PiProviderSupport.apply(config, directory: root, environment: &environment, profile: first)
        XCTAssertNil(environment[PiProviderSupport.credentialVariable])
        config.local.authentication = .apiKey
        try PiProviderSupport.apply(config, directory: root, environment: &environment, profile: second)
        XCTAssertEqual(environment[PiProviderSupport.credentialVariable], "second-secret")
        XCTAssertNil(environment[PiProviderSupport.noAuthVariable])
        let data = try Data(contentsOf: root.appendingPathComponent("models.json"))
        let manifest = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(manifest.contains("first-secret")); XCTAssertFalse(manifest.contains("second-secret"))
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: first), "first-secret")
    }
}
