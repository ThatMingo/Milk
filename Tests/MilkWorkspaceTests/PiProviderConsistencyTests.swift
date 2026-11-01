import XCTest
import CryptoKit
@testable import Milk

final class PiProviderConsistencyTests: XCTestCase {
    private var credentials: CredentialTestStore!
    override func setUp() { super.setUp(); credentials = CredentialTestStore() }
    override func tearDown() { credentials.restore(); credentials = nil; super.tearDown() }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    // Local artifact fixture only: exercises the real installer with the pinned binary.
    private func archive(_ files: [(String, Data)]) -> Data {
        var result = Data()
        for (name, data) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ text: String, _ offset: Int) { for (i, byte) in text.utf8.enumerated() { header[offset+i] = byte } }
            field(name, 0); field("0000700", 100); field("0000000", 108); field("0000000", 116)
            field(String(format: "%011o", data.count), 124); field("00000000000", 136)
            for i in 148..<156 { header[i] = 32 }; header[156] = 48; field("ustar", 257)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148)
            result.append(contentsOf: header); result.append(data)
            if data.count % 512 != 0 { result.append(Data(repeating: 0, count: 512-data.count % 512)) }
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    @MainActor func testSettingsWiringAndProductionOwnershipAudit() throws {
        let fixture = try Phase6Fixture(self)
        try fixture.manager.migrateLegacySelection(.bundled)
        let adapter = PiAdapter(runtime: fixture.manager.runtime, installations: fixture.manager, defaults: fixture.defaults)
        let workspace = try fixture.workspace()
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: false, adapter: adapter)
        defer { agent.shutdown() }
        XCTAssertEqual(AgentManagerModel(manager: fixture.manager).status, "Not installed")
        XCTAssertEqual(adapter.settingsProvider?.settingsSections.map(\.id), ["pi.configuration"])
        let draft = PiSettingsModel(agent: agent, adapter: adapter)
        XCTAssertEqual(draft.configuration.provider, .configured)
        draft.configuration.provider = .local
        draft.model = "exact/settings:model"
        XCTAssertNoThrow(try draft.edited())
        _ = adapter.settingsView(section: "pi.configuration", agent: agent)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let global = try source("Sources/Milk/SettingsView.swift")
        XCTAssertTrue(global.contains("AgentsSettingsView(state:state)")); XCTAssertFalse(global.contains("omlx")); XCTAssertFalse(global.contains("PiProviderID"))
        let host = try source("Sources/Milk/AgentsSettingsView.swift")
        XCTAssertTrue(host.contains("model.status")); XCTAssertTrue(host.contains("This Pi uses an isolated Milk profile."))
        XCTAssertTrue(host.contains("This uses your existing Pi setup. Changes may also affect Pi outside Milk."))
        XCTAssertTrue(host.contains("adapter.settingsProvider"))
        let pi = try source("Sources/Milk/PiSettings.swift")
        XCTAssertTrue(pi.contains("if model.configuration.provider == .local { localRows }"))
        XCTAssertTrue(pi.contains("profile: profile")); XCTAssertTrue(pi.contains("profile: profileIdentity"))
        let core = try source("Sources/Milk/AgentService.swift")
        XCTAssertFalse(core.contains("omlx")); XCTAssertFalse(core.contains("PiLocalDiscovery")); XCTAssertFalse(core.contains("telemetryTask"))
        let bridge = try source("Runtime/MilkPiIntegration.ts")
        XCTAssertFalse(bridge.contains("registerProvider")); XCTAssertFalse(bridge.contains("contextWindow"))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" && !file.lastPathComponent.contains("Verification") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for removed in ["OMLXConfiguration", "OMLXService", "MILK_OMLX_", "32768", "/chat/completions", "/api/status", "/health"] {
                XCTAssertFalse(text.contains(removed), file.path+": "+removed)
            }
            if file.lastPathComponent != "StaticPreviewServer.swift" { XCTAssertFalse(text.contains("8192"), file.path) }
        }
    }
    @MainActor func testRealManagedInstallLocalSwitchingResumeAndReinstall() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Consistency-"+UUID().uuidString).resolvingSymlinksInPath()
        let defaultsName = "Milk.Consistency."+UUID().uuidString, defaults = UserDefaults(suiteName: defaultsName)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: root) }
        let resources = project.appendingPathComponent("Runtime"), source = resources.appendingPathComponent("PiRuntime")
        let manifest = try JSONDecoder().decode(PiRuntimeManifest.self, from: Data(contentsOf: source.appendingPathComponent("runtime-manifest.json")))
        var pins = manifest.runtimeFiles; pins["pi"] = manifest.executableSHA256
        pins["package.json"] = digest(try Data(contentsOf: source.appendingPathComponent("package.json")))
        var contents: [(String, Data)] = []
        for (name, pin) in pins.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: source.appendingPathComponent(name)); XCTAssertEqual(digest(data), pin)
            contents.append(("pi/"+name, data))
        }
        let tar = archive(contents)
        let release = PiCatalogRelease(version: manifest.version, platform: "darwin", architecture: PiInstallationCatalog.architecture,
            source: URL(string: manifest.source)!, artifacts: [.init(url: URL(string: "https://fixture.invalid/local-pinned-pi.tar")!, sha256: digest(tar), binarySuffix: nil, destination: "pi")],
            files: pins, executables: ["pi"], notices: ["LICENSE"], provenance: "Disposable local pinned-runtime integration fixture")
        let existingDirectory = root.appendingPathComponent("terminal-profile"), home = root.appendingPathComponent("home")
        let runtime = PiRuntimeService(resources: resources, environmentOverrides: ["HOME": home.path, "PI_CODING_AGENT_DIR": existingDirectory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        let notices = root.appendingPathComponent("notices")
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try Data("Disposable fixture notice".utf8).write(to: notices.appendingPathComponent("LICENSE"))
        let manager = PiInstallationManager(store: .init(root: root.appendingPathComponent("Milk/Agents/pi")), lifecycle: .init(), runtime: runtime,
            catalog: .init(releases: [release]), notices: notices, download: { _, destination in try tar.write(to: destination) })
        try manager.migrateLegacySelection(.bundled)
        let managedID = try await manager.install()
        XCTAssertEqual(AgentManagerModel(manager: manager).selectedRecord?.ownership, .milkManaged)
        let adapter = PiAdapter(runtime: runtime, installations: manager, defaults: defaults)
        let managedProfile = try manager.selectedProfile(), managedIdentity = try adapter.providerProfileIdentity.rawValue
        XCTAssertEqual(managedProfile.ownership, .milkManaged)
        XCTAssertNotEqual(managedProfile.directory, existingDirectory)
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, directory: root.appendingPathComponent("Milk/Workspaces"), enabled: false))
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter, lifecycle: manager.lifecycle)
        defer { agent.shutdown() }
        let extensionService = ExtensionService(runtime: runtime); extensionService.installations = manager
        func marker(_ directory: URL, name: String) throws {
            let extensions = directory.appendingPathComponent("extensions")
            try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
            try Data("export default function(pi) { pi.registerCommand('profile-marker', { handler: async (_args, ctx) => ctx.ui.notify('\(name)') }); }".utf8).write(to: extensions.appendingPathComponent(name+".ts"))
        }
        try marker(managedProfile.directory, name: "managed-marker")
        try marker(existingDirectory, name: "existing-marker")
        let server = Process(), output = Pipe(), control = root.appendingPathComponent("auth-mode"), log = root.appendingPathComponent("requests.jsonl")
        try Data("none".utf8).write(to: control)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path; environment["MILK_FIXTURE_AUTH_FILE"] = control.path; environment["MILK_FIXTURE_REQUEST_LOG"] = log.path
        server.environment = environment; server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
        var identities = [managedIdentity]
        defer { for identity in identities { try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: identity) } }
        var config = PiProviderConfiguration(); config.provider = .local; config.local.endpoint = endpoint
        config.local.selectedModel = "org/Qwen:Q4_K_M"
        config.local.models = try await PiLocalDiscovery().inspect(config.local, token: nil).models.map { discovered in
            var model = discovered
            if model.id == "org/Qwen:Q4_K_M" { model.contextWindow = nil; model.maxTokens = nil }
            if model.id == "reasoning-fixture" { model.contextOverride = 65536 }
            if model.id == "milk-fixture" { model.outputOverride = 2000 }
            return model
        }
        // Context override and output Auto are independent. First model is entirely unknown.
        try adapter.saveProviderSettings(config, token: nil, agent: agent)
        var retainedSession = AgentSession(id: 1, title: "Managed consistency")
        @MainActor func run(_ session: AgentSession, prompt: Bool, expectedMarker: String, expectedNoAuth: Bool) async throws -> String {
            let before = (try? String(contentsOf: log, encoding: .utf8).split(separator: "\n").count) ?? 0
            let backend = adapter.makeBackend(context: .init(permission: .autonomous, lifecycle: manager.lifecycle))
            var path: String?, sessionID: String?, settled = false, failures: [String] = [], markers = "", commands: [AgentCommand] = [], models: [AgentModel] = [], levels: [String] = [], history: [AgentMessage] = []
            backend.onEvent = { event in
                switch event {
                case .state(let state): path = state.sessionFile; sessionID = state.sessionID
                case .models(let value): models = value
                case .efforts(let value, _): levels = value
                case .slashCommands(let value): commands = value
                case .notice(let value): markers += value
                case .settled: settled = true
                case .failure(let value): failures.append(value)
                case .history(let snapshot): history = snapshot.messages
                case .message(let value): history.append(value)
                default: break
                }
            }
            do {
                try await backend.start(workspace: root, session: session)
                XCTAssertEqual(sessionID, session.backendID)
                XCTAssertTrue(models.contains { $0.modelID == "org/Qwen:Q4_K_M" })
                XCTAssertFalse(levels.isEmpty)
                for configured in try adapter.providerConfiguration().local.models {
                    let reported = try XCTUnwrap(models.first { $0.modelID == configured.id && $0.provider == PiProviderSupport.providerID })
                    if let context = configured.effectiveContext { XCTAssertEqual(reported.contextWindow, context) }
                    if let output = configured.effectiveOutput { XCTAssertEqual(reported.maxTokens, output) }
                }
                XCTAssertTrue(commands.contains { $0.name == "profile-marker" })
                try await backend.send(.init(text: "/profile-marker", attachments: []), intent: .prompt)
                XCTAssertTrue(markers.contains(expectedMarker), markers)
                if prompt {
                    settled = false
                    try await backend.send(.init(text: "integration fixture response", attachments: []), intent: .prompt)
                    let deadline = Date().addingTimeInterval(20)
                    while !settled { guard Date() < deadline else { throw AgentError.message("Fixture inference timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
                    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
                } else { XCTAssertTrue(history.contains { $0.role == "user" && $0.text.contains("integration fixture response") }) }
                try await backend.shutdownAndWait()
                let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").dropFirst(before).map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                if prompt {
                    XCTAssertTrue(requests.contains { $0["method"].string == "POST" && $0["model"].string == "org/Qwen:Q4_K_M" })
                    XCTAssertTrue(requests.allSatisfy { $0["has_auth"].bool == !expectedNoAuth })
                }
                return try XCTUnwrap(path)
            } catch { try? await backend.shutdownAndWait(); throw error }
        }
        retainedSession.sessionFile = try await run(retainedSession, prompt: true, expectedMarker: "managed-marker", expectedNoAuth: true)
        XCTAssertTrue(retainedSession.sessionFile!.hasPrefix(managedProfile.directory.path+"/"))
        let originalHistory = try Data(contentsOf: URL(fileURLWithPath: retainedSession.sessionFile!))
        let modelsFile = managedProfile.directory.appendingPathComponent("models.json")
        var serialized = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: modelsFile))
        let configuredModels = serialized["providers"][PiProviderSupport.providerID]["models"].array
        let unknown = try XCTUnwrap(configuredModels.first { $0["id"].string == "org/Qwen:Q4_K_M" })
        XCTAssertNil(unknown["contextWindow"].number); XCTAssertNil(unknown["maxTokens"].number)
        let contextOverride = try XCTUnwrap(configuredModels.first { $0["id"].string == "reasoning-fixture" })
        XCTAssertEqual(contextOverride["contextWindow"].number, 65536); XCTAssertEqual(contextOverride["maxTokens"].number, 4000)
        let outputOverride = try XCTUnwrap(configuredModels.first { $0["id"].string == "milk-fixture" })
        XCTAssertEqual(outputOverride["contextWindow"].number, 64000); XCTAssertEqual(outputOverride["maxTokens"].number, 2000)
        config.local.authentication = .apiKey
        try adapter.saveProviderSettings(config, token: "fixture-local-secret", agent: agent)
        try Data("key".utf8).write(to: control)
        _ = try await run(.init(id: 2, title: "Managed key"), prompt: true, expectedMarker: "managed-marker", expectedNoAuth: false)
        // Register two distinct Existing Pi executables, with no real-user profile access.
        let firstExecutable = root.appendingPathComponent("external-one/pi"), secondExecutable = root.appendingPathComponent("external-two/pi")
        for executable in [firstExecutable, secondExecutable] {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent("pi"), to: executable)
            try FileManager.default.copyItem(at: source.appendingPathComponent("package.json"), to: executable.deletingLastPathComponent().appendingPathComponent("package.json"))
        }
        let externalOne = try await manager.registerExternal(firstExecutable), externalTwo = try await manager.registerExternal(secondExecutable)
        try await manager.select(externalOne)
        let externalIdentity = try adapter.providerProfileIdentity.rawValue; identities.append(externalIdentity)
        XCTAssertEqual(try manager.selectedProfile().directory.path, existingDirectory.path)
        XCTAssertEqual(PiSettingsModel(agent: agent, adapter: adapter).configuration, PiProviderConfiguration())
        var externalConfig = config; externalConfig.local.models[0].outputOverride = 5000
        try adapter.saveProviderSettings(externalConfig, token: "external-fixture-secret", agent: agent)
        try Data("external-key".utf8).write(to: control)
        let existingSession = try await run(.init(id: 3, title: "Existing"), prompt: true, expectedMarker: "existing-marker", expectedNoAuth: false)
        XCTAssertTrue(existingSession.hasPrefix(existingDirectory.path+"/"))
        extensionService.refresh(workspace: nil)
        XCTAssertTrue(extensionService.records.contains { $0.name == "existing-marker" }); XCTAssertFalse(extensionService.records.contains { $0.name == "managed-marker" })
        try await manager.select(externalTwo)
        let secondIdentity = try adapter.providerProfileIdentity.rawValue; identities.append(secondIdentity)
        XCTAssertEqual(secondIdentity, externalIdentity)
        XCTAssertEqual(try adapter.providerConfiguration(), externalConfig)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: secondIdentity), "external-fixture-secret")
        var sharedConfig = externalConfig; sharedConfig.local.models[0].outputOverride = 5500
        try sharedConfig.save(defaults, key: manager.providerSettingsKey)
        externalConfig = sharedConfig
        try await manager.select(externalOne); XCTAssertEqual(try adapter.providerConfiguration(), externalConfig)
        try await manager.select(managedID); XCTAssertEqual(try adapter.providerConfiguration(), config)
        extensionService.refresh(workspace: nil)
        XCTAssertTrue(extensionService.records.contains { $0.name == "managed-marker" }); XCTAssertFalse(extensionService.records.contains { $0.name == "existing-marker" })
        try Data("key".utf8).write(to: control)
        _ = try await run(retainedSession, prompt: false, expectedMarker: "managed-marker", expectedNoAuth: false)
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: retainedSession.sessionFile!)).starts(with: originalHistory))
        let foreign = adapter.makeBackend(context: .init(permission: .approval))
        do { try await foreign.start(workspace: root, session: .init(id: 4, title: "Wrong profile", sessionFile: existingSession)); XCTFail("Managed Pi cannot resume a foreign profile file") } catch { XCTAssertTrue(error.localizedDescription.contains("different Pi profile"), error.localizedDescription) }
        try await foreign.shutdownAndWait()
        try await manager.removeManagedPi()
        XCTAssertNil(manager.store.state.selected); XCTAssertThrowsError(try manager.selectedInstallation())
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: managedIdentity), "fixture-local-secret")
        _ = try await manager.install()
        XCTAssertEqual(try manager.selectedProfile(), managedProfile); XCTAssertEqual(try adapter.providerProfileIdentity.rawValue, managedIdentity)
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        _ = try await run(retainedSession, prompt: false, expectedMarker: "managed-marker", expectedNoAuth: false)
        serialized = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: modelsFile))
        XCTAssertEqual(serialized["providers"][PiProviderSupport.providerID]["baseUrl"].string, endpoint.absoluteString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path))
    }
}
