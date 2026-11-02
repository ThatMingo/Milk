import XCTest
@testable import Milk

final class SandboxProviderParityTests: XCTestCase {
    @MainActor func testConfiguredProviderRetainsNativeAuthThenDeclaredEnvironmentAuthentication() async throws {
        let files = FileManager.default
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = files.temporaryDirectory.appendingPathComponent("Milk-Configured-Parity-"+UUID().uuidString)
        let profile = root.appendingPathComponent("profile"), workspace = root.appendingPathComponent("project")
        for url in [profile,workspace] { try files.createDirectory(at:url,withIntermediateDirectories:true) }
        defer { try? files.removeItem(at:root) }
        let server = Process(), output = Pipe(), log = root.appendingPathComponent("requests.jsonl")
        server.executableURL = URL(fileURLWithPath:"/usr/bin/python3"); server.arguments = ["-u",project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        server.environment = ["PATH":"/usr/bin:/bin","MILK_FIXTURE_AUTH":"external-key","MILK_FIXTURE_REQUEST_LOG":log.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice; try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding:output.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        let models = try JSONSerialization.data(withJSONObject:["providers":["custom":["api":"openai-completions","baseUrl":"http://127.0.0.1:\(port)/v1","apiKey":"$CUSTOM_PROVIDER_AUTH","models":[["id":"milk-fixture","contextWindow":32000,"maxTokens":2048]]]]])
        let auth = Data(#"{"custom":{"type":"api_key","key":"external-fixture-secret"}}"#.utf8)
        try models.write(to:profile.appendingPathComponent("models.json")); try auth.write(to:profile.appendingPathComponent("auth.json"))
        try Data(#"{"defaultProvider":"custom","defaultModel":"milk-fixture"}"#.utf8).write(to:profile.appendingPathComponent("settings.json"))
        let suite = "Milk.ConfiguredParity."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var policy = SandboxConfiguration(home:root); policy.protectedLocations = []
        defaults.set(try JSONEncoder().encode(policy),forKey:SandboxSettingsStore.key)
        for native in [true,false] {
            if !native { try files.removeItem(at:profile.appendingPathComponent("auth.json")) }
            let runtime = PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["PI_CODING_AGENT_DIR":profile.path,"CUSTOM_PROVIDER_AUTH":native ? "wrong-environment-value" : "external-fixture-secret"])
            let backend = PiBackend(sandboxSettings:SandboxSettingsStore(defaults:defaults,home:root),runtime:runtime)
            defer { backend.shutdown() }
            var settled = false, failed = false, selected: AgentModel?
            backend.onEvent = { if case .settled = $0 { settled = true }; if case .failure = $0 { failed = true }; if case .state(let state) = $0 { selected = state.model } }
            try await backend.start(workspace:workspace,session:.init(id:native ? 1 : 2,title:"Configured provider"))
            XCTAssertEqual(selected?.provider,"custom")
            try await backend.send(.init(text:"Configured provider fixture",attachments:[]),intent:.prompt)
            let end = Date().addingTimeInterval(15)
            while !settled && !failed { guard Date() < end else { throw AgentError.message("Configured provider did not settle") }; try await Task.sleep(nanoseconds:20_000_000) }
            XCTAssertFalse(failed)
            try await backend.shutdownAndWait()
            XCTAssertEqual(try Data(contentsOf:profile.appendingPathComponent("models.json")),models)
            if native { XCTAssertEqual(try Data(contentsOf:profile.appendingPathComponent("auth.json")),auth) }
        }
        let requests = try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode(JSONValue.self,from:Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"].string == "POST" && $0["accepted"].bool }.count,2)
    }
    @MainActor func testScopedReplacementServerRevocationKeychainDeletionAndNoneWithRealPi() async throws {
        let files = FileManager.default
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = files.temporaryDirectory.appendingPathComponent("Milk-Provider-Parity-"+UUID().uuidString)
        let workspace = root.appendingPathComponent("project"), profile = root.appendingPathComponent("profile")
        for url in [workspace,profile] { try files.createDirectory(at:url,withIntermediateDirectories:true) }
        defer { try? files.removeItem(at:root) }
        let control = root.appendingPathComponent("mode"), log = root.appendingPathComponent("requests.jsonl")
        try Data("key".utf8).write(to:control)
        let server = Process(), portPipe = Pipe()
        server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = ["-u",project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        server.environment = ["PATH":"/usr/bin:/bin","MILK_FIXTURE_AUTH_FILE":control.path,"MILK_FIXTURE_REQUEST_LOG":log.path]
        server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding:portPipe.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        let endpoint = URL(string:"http://127.0.0.1:\(port)/v1")!
        let credentials = CredentialTestStore(); defer { credentials.restore() }
        let identity = PiProviderProfileIdentity(directory:profile).rawValue
        let first = "fixture-local-secret", replacement = "fixture-replacement-secret"
        try AgentProviderCredentials.save(first,agent:.pi,provider:"local",endpoint:endpoint,profile:identity)
        let stale = Data(#"{"milk-local":{"type":"api_key","key":"stale-admin-fixture"}}"#.utf8)
        try stale.write(to:profile.appendingPathComponent("auth.json"))
        let suite = "Milk.ProviderParity."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var policy = SandboxConfiguration(home:root); policy.protectedLocations = []
        defaults.set(try JSONEncoder().encode(policy),forKey:SandboxSettingsStore.key)
        let settings = SandboxSettingsStore(defaults:defaults,home:root)
        var configuration = PiProviderConfiguration(); configuration.provider = .local
        configuration.local.endpoint = endpoint; configuration.local.authentication = .apiKey
        configuration.local.models = try await PiLocalDiscovery().inspect(configuration.local,token:first).models
        configuration.local.selectedModel = "milk-fixture"
        func backend(_ config: PiProviderConfiguration, profile target: URL = profile) -> PiBackend {
            var agent = AgentConfiguration(); agent.defaultPermission = .autonomous
            return PiBackend(sandboxSettings:settings,runtime:PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["PI_CODING_AGENT_DIR":target.path,"MILK_PI_LOCAL_KEY":"ambient-must-not-win"]),configuration:agent,providerConfiguration:config,providerProfileIdentityLoader:{ PiProviderProfileIdentity(directory:target).rawValue })
        }
        func requests() throws -> [JSONValue] {
            try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode(JSONValue.self,from:Data($0.utf8)) }
        }
        @MainActor func chat(_ backend: PiBackend) async throws {
            var settled = false, failed = false
            backend.onEvent = { if case .settled = $0 { settled = true }; if case .failure = $0 { failed = true } }
            try await backend.send(.init(text:"phase4 provider fixture",attachments:[]),intent:.prompt)
            let end = Date().addingTimeInterval(15)
            while !settled && !failed { guard Date() < end else { throw AgentError.message("Provider fixture did not settle") }; try await Task.sleep(nanoseconds:20_000_000) }
        }
        let initial = backend(configuration); defer { initial.shutdown() }
        try await initial.start(workspace:workspace,session:.init(id:1,title:"Initial")); try await chat(initial); try await initial.shutdownAndWait()
        XCTAssertEqual(try requests().last?["auth_generation"].number,1)
        XCTAssertEqual(try requests().last?["accepted"].bool,true)

        try AgentProviderCredentials.save(replacement,agent:.pi,provider:"local",endpoint:endpoint,profile:identity)
        try Data("key2".utf8).write(to:control)
        _ = try await PiLocalDiscovery().inspect(configuration.local,token:replacement)
        let updated = backend(configuration); defer { updated.shutdown() }
        try await updated.start(workspace:workspace,session:.init(id:2,title:"Replacement")); try await chat(updated)
        XCTAssertEqual(try requests().last?["auth_generation"].number,2); XCTAssertEqual(try requests().last?["accepted"].bool,true)
        XCTAssertEqual(try Data(contentsOf:profile.appendingPathComponent("auth.json")),stale,"User auth.json must not be rewritten")
        try Data("revoked".utf8).write(to:control)
        do { _ = try await PiLocalDiscovery().inspect(configuration.local,token:replacement); XCTFail("Revoked discovery succeeded") } catch { XCTAssertTrue(error.localizedDescription.contains("authentication")) }
        try await chat(updated)
        XCTAssertEqual(try requests().last?["auth_generation"].number,2); XCTAssertEqual(try requests().last?["accepted"].bool,false)
        try await updated.shutdownAndWait()

        for other in [false,true] {
            var scoped = configuration; let target = other ? root.appendingPathComponent("other-profile") : profile
            try files.createDirectory(at:target,withIntermediateDirectories:true)
            if !other { scoped.local.endpoint = URL(string:"http://127.0.0.1:\(port)/another/v1")! }
            let missing = backend(scoped,profile:target)
            do { try await missing.start(workspace:workspace,session:.init(id:3,title:"Other scope")); XCTFail("Another profile/endpoint inherited the key") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Keychain"),error.localizedDescription) }
            try await missing.shutdownAndWait()
        }
        try AgentProviderCredentials.save("",agent:.pi,provider:"local",endpoint:endpoint,profile:identity)
        let removed = backend(configuration)
        do { try await removed.start(workspace:workspace,session:.init(id:4,title:"Deleted")); XCTFail("Ambient/stale auth restored a deleted key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Keychain"),error.localizedDescription) }
        try await removed.shutdownAndWait()
        configuration.local.authentication = .none; try Data("none".utf8).write(to:control)
        let none = backend(configuration); defer { none.shutdown() }
        try await none.start(workspace:workspace,session:.init(id:5,title:"None")); try await chat(none); try await none.shutdownAndWait()
        XCTAssertEqual(try requests().last?["has_auth"].bool,false); XCTAssertEqual(try requests().last?["accepted"].bool,true)
        for case let file as URL in files.enumerator(at:root,includingPropertiesForKeys:nil)! where ["json","jsonl"].contains(file.pathExtension) {
            let text = try String(contentsOf:file,encoding:.utf8)
            XCTAssertFalse(text.contains(first),file.lastPathComponent); XCTAssertFalse(text.contains(replacement),file.lastPathComponent)
        }
    }
}
