import XCTest
@testable import Milk

/// Actual pinned Pi RPC, isolated agent data and deterministic loopback discovery/inference.
final class PiProviderRoutingTests: XCTestCase {
    @MainActor private func wait(_ label: String, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() {
            guard Date() < deadline else { throw AgentError.message("Timed out: " + label) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor private func exercise(authentication: PiLocalAuthentication, unknownLimits: Bool = false) async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Local-RPC-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("Workspace"), directory = root.appendingPathComponent("agent"), log = root.appendingPathComponent("requests.jsonl")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        var env = ProcessInfo.processInfo.environment
        env["MILK_FIXTURE_AUTH"] = authentication == .none ? "none" : "key"; env["MILK_FIXTURE_REQUEST_LOG"] = log.path
        server.environment = env; server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        var configuration = PiProviderConfiguration(); configuration.provider = .local
        configuration.local.endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
        configuration.local.authentication = authentication
        let endpoint = configuration.local.endpoint
        let identity = PiProviderProfileIdentity(directory: directory).rawValue
        defer { try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: identity) }
        let token = authentication == .apiKey ? "fixture-local-secret" : nil
        if let token { try AgentProviderCredentials.save(token, agent: .pi, provider: "local", endpoint: endpoint, profile: identity) }
        configuration.local.models = try await PiLocalDiscovery().inspect(configuration.local, token: token).models
        if unknownLimits {
            configuration.local.models = configuration.local.models.map { value in
                var value = value; value.contextWindow = nil; value.maxTokens = nil; return value
            }
        }
        configuration.local.selectedModel = "org/Qwen:Q4_K_M"
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        let adapter = PiAdapter(runtime: runtime, providerConfiguration: { configuration })
        let backend = adapter.makeBackend(context: .init(permission: .autonomous)); defer { backend.shutdown() }
        var models: [AgentModel] = [], current: AgentModel?, levels: [String] = [], selectedEffort: String?, path: String?, settled = 0, messages: [AgentMessage] = [], failures: [String] = []
        backend.onEvent = { event in
            switch event {
            case .models(let value): models = value
            case .state(let snapshot): current = snapshot.model; path = snapshot.sessionFile
            case .efforts(let value, let selected): levels = value; selectedEffort = selected
            case .message(let message): messages.append(message)
            case .settled: settled += 1
            case .failure(let error): failures.append(error)
            default: break
            }
        }
        let session = AgentSession(id: 8, title: "Preserved identity")
        try await backend.start(workspace: workspace, session: session)
        XCTAssertEqual(current?.provider, PiProviderSupport.providerID); XCTAssertEqual(current?.modelID, "org/Qwen:Q4_K_M")
        if unknownLimits {
            XCTAssertNotNil(current?.contextWindow); XCTAssertNotNil(current?.maxTokens) // Pi owns effective defaults.
        } else { XCTAssertEqual(current?.contextWindow, 64000); XCTAssertEqual(current?.maxTokens, 4000) }
        XCTAssertTrue(models.contains { $0.modelID == "reasoning-fixture" && $0.supportsReasoning == true })
        XCTAssertEqual(levels, ["off"])
        // These choices and levels are all returned by Pi, never queried from Chat.
        try await backend.setModel(try XCTUnwrap(models.first { $0.modelID == "reasoning-fixture" }))
        XCTAssertGreaterThan(levels.count, 1)
        let effort = try XCTUnwrap(levels.last); try await backend.setEffort(effort); XCTAssertEqual(selectedEffort, effort)
        try await backend.send(.init(text: "local routing fixture", attachments: []), intent: .prompt)
        try await wait("Pi response") { settled == 1 }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let sessionFile = try XCTUnwrap(path)
        try await backend.shutdownAndWait()
        if authentication == .none {
            // Existing native history can still reference the removed legacy provider.
            let file = URL(fileURLWithPath: sessionFile)
            let original = try String(contentsOf: file, encoding: .utf8)
            let legacy = original.replacingOccurrences(of: "\"provider\":\"milk-local\"", with: "\"provider\":\"omlx\"")
            XCTAssertNotEqual(original, legacy)
            try Data(legacy.utf8).write(to: file)
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: sessionFile))
        // Changing provider settings must not reassign or recreate a saved session.
        configuration.local.selectedModel = "org/Qwen:Q4_K_M"
        let resumed = adapter.makeBackend(context: .init(permission: .approval)); defer { resumed.shutdown() }
        var restored: [AgentMessage] = [], sessionID: String?
        resumed.onEvent = { event in
            if case .message(let message) = event { restored.append(message) }
            if case .state(let state) = event { sessionID = state.sessionID }
        }
        var retained = session; retained.sessionFile = sessionFile
        try await resumed.start(workspace: workspace, session: retained)
        XCTAssertEqual(sessionID, session.backendID); XCTAssertEqual(retained.agentID, .pi)
        XCTAssertTrue(restored.contains { $0.role == "user" && $0.text.contains("local routing fixture") })
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: sessionFile)).starts(with: before))
        try await resumed.shutdownAndWait()
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"].string == "GET" }.map { $0["path"].string }, ["/v1/models"], "No health/status polling during Pi startup or inference")
        XCTAssertTrue(requests.contains { $0["method"].string == "POST" && $0["model"].string == "reasoning-fixture" })
        XCTAssertTrue(requests.allSatisfy {
            if authentication == .apiKey { return $0["has_auth"].bool && !$0["placeholder"].bool }
            return !$0["has_auth"].bool
        })
        let persisted = try String(contentsOf: directory.appendingPathComponent("models.json"), encoding: .utf8)
        if unknownLimits {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(persisted.utf8))
            for model in json["providers"][PiProviderSupport.providerID]["models"].array {
                XCTAssertNil(model["contextWindow"].number); XCTAssertNil(model["maxTokens"].number)
            }
        }
        XCTAssertFalse(persisted.contains("fixture-local-secret")); XCTAssertFalse(persisted.contains("32768")); XCTAssertFalse(persisted.contains("8192"))
    }
    @MainActor func testUnknownLimitsUsePiDefaultsAndTrueNoAuth() async throws { try await exercise(authentication: .none, unknownLimits: true) }
    @MainActor func testNoAuthPiRPCStartupModelThinkingAndResume() async throws { try await exercise(authentication: .none) }
    @MainActor func testAPIKeyPiRPCStartupModelThinkingAndResume() async throws { try await exercise(authentication: .apiKey) }
}
