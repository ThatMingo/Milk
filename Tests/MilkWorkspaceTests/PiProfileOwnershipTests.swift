import XCTest
@testable import Milk

final class PiProfileOwnershipTests: XCTestCase {
    private var credentials: CredentialTestStore!
    override func setUp() { super.setUp(); credentials = CredentialTestStore() }
    override func tearDown() { credentials.restore(); credentials = nil; super.tearDown() }

    @MainActor func testProviderStateFollowsCanonicalDirectoryNotExecutable() async throws {
        let fixture = try Phase6Fixture(self), manager = fixture.manager
        try manager.migrateLegacySelection(.bundled)
        let managed = try await manager.install()
        let first = try await manager.registerExternal(fixture.executable())
        let secondPath = fixture.root.appendingPathComponent("second-pi")
        try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("external pi"), to: secondPath)
        let second = try await manager.registerExternal(secondPath)
        let home = fixture.root.appendingPathComponent("home")
        // A second manager/environment models an independently resolved Existing profile.
        let otherRuntime = PiRuntimeService(resources: manager.runtime.resources, environmentOverrides: ["HOME": home.path, "PI_CODING_AGENT_DIR": home.appendingPathComponent("other-profile").path])
        let other = PiInstallationManager(store: .init(root: fixture.root.appendingPathComponent("other-agent-root")), lifecycle: .init(), runtime: otherRuntime,
            probe: { _, _, _ in PiCompatibilityPolicy.verified(version: "1.4.0") })
        try other.migrateLegacySelection(.bundled)
        let third = try await other.registerExternal(secondPath); try await other.select(third)
        let adapter = PiAdapter(runtime: manager.runtime, installations: manager, defaults: fixture.defaults)
        let otherAdapter = PiAdapter(runtime: otherRuntime, installations: other, defaults: fixture.defaults)
        let endpoint = URL(string: "http://127.0.0.1:8000/"+UUID().uuidString)!
        var identities: [String] = []
        defer { for identity in identities { try? AgentProviderCredentials.save("", agent: .pi, provider: "local", endpoint: endpoint, profile: identity) } }
        try await manager.select(managed)
        let managedIdentity = try adapter.providerProfileIdentity.rawValue; identities.append(managedIdentity)
        try await manager.select(first)
        let existingIdentity = try adapter.providerProfileIdentity.rawValue; identities.append(existingIdentity)
        let otherIdentity = try otherAdapter.providerProfileIdentity.rawValue; identities.append(otherIdentity)
        XCTAssertEqual(Set(identities).count, 3)
        var config = PiProviderConfiguration(); config.provider = .local; config.local.endpoint = endpoint
        config.local.selectedModel = "same-profile-model"; config.local.models = [.init(id: "same-profile-model", contextOverride: 65536)]
        try config.save(fixture.defaults, key: manager.providerSettingsKey)
        try AgentProviderCredentials.save("shared-key", agent: .pi, provider: "local", endpoint: endpoint, profile: existingIdentity)
        let sharedKey = manager.providerSettingsKey
        try await manager.select(second)
        XCTAssertEqual(try adapter.providerProfileIdentity.rawValue, existingIdentity)
        XCTAssertEqual(manager.providerSettingsKey, sharedKey)
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        XCTAssertEqual(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: adapter.providerProfileIdentity.rawValue), "shared-key")
        config.local.models[0].outputOverride = 4000; try config.save(fixture.defaults, key: manager.providerSettingsKey)
        try await manager.select(first); XCTAssertEqual(try adapter.providerConfiguration(), config)
        XCTAssertEqual(try otherAdapter.providerConfiguration(), PiProviderConfiguration())
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: otherIdentity))
        var otherConfig = PiProviderConfiguration(); otherConfig.local.endpoint = URL(string: "http://127.0.0.1:9001/v1")!
        try otherConfig.save(fixture.defaults, key: other.providerSettingsKey)
        try AgentProviderCredentials.save("other-key", agent: .pi, provider: "local", endpoint: endpoint, profile: otherIdentity)
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        XCTAssertEqual(try otherAdapter.providerConfiguration(), otherConfig)
        try await manager.select(managed)
        XCTAssertEqual(try adapter.providerProfileIdentity.rawValue, managedIdentity)
        XCTAssertEqual(try adapter.providerConfiguration(), PiProviderConfiguration())
        XCTAssertNil(try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: endpoint, profile: managedIdentity))
        // Canonical aliases identify the same actual directory.
        let directory = fixture.root.appendingPathComponent("canonical-profile"), alias = fixture.root.appendingPathComponent("alias-profile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(PiProviderProfileIdentity(directory: directory), PiProviderProfileIdentity(directory: alias))
        let legacyManagedParts = ["pi-profile-v1", manager.store.root.appendingPathComponent("profile").standardizedFileURL.resolvingSymlinksInPath().path, "managed"]
        XCTAssertEqual(managedIdentity, Phase6Fixture.hash(try JSONEncoder().encode(legacyManagedParts)))
    }
    @MainActor func testManagedSelectionSettingsRemovalAndReinstallPreserveProfile() async throws {
        let fixture = try Phase6Fixture(self), manager = fixture.manager
        try manager.migrateLegacySelection(.bundled)
        let id = try await manager.install()
        let profile = try manager.selectedProfile()
        XCTAssertEqual(profile.ownership, .milkManaged)
        XCTAssertEqual(profile.directory, manager.store.root.appendingPathComponent("profile", isDirectory: true))
        XCTAssertFalse(profile.directory.path.contains("/.pi/"))
        let adapter = PiAdapter(runtime: manager.runtime, installations: manager, defaults: fixture.defaults)
        XCTAssertEqual(try adapter.providerDirectory, profile.directory)
        var config = PiProviderConfiguration(); config.provider = .local
        config.local.models = [.init(id: "fixture", contextOverride: 64000, outputOverride: 4000)]
        config.local.selectedModel = "fixture"
        let workspace = try fixture.workspace()
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: false, adapter: adapter)
        try adapter.saveProviderSettings(config, token: nil, agent: agent)
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        XCTAssertNil(fixture.defaults.data(forKey: PiProviderConfiguration.key))
        let file = profile.directory.appendingPathComponent("models.json"), bytes = try Data(contentsOf: file)
        try Data("history".utf8).write(to: profile.directory.appendingPathComponent("retained-history"))
        try await manager.remove(id)
        XCTAssertNil(manager.store.state.selected)
        XCTAssertThrowsError(try manager.selectedInstallation())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        _ = try await manager.install()
        XCTAssertEqual(try manager.selectedProfile(), profile)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try adapter.providerConfiguration(), config)
        agent.shutdown()
    }
    @MainActor func testExistingProfileAndSwitchingOwnership() async throws {
        let fixture = try Phase6Fixture(self), manager = fixture.manager
        try manager.migrateLegacySelection(.bundled)
        let managed = try await manager.install(), own = try manager.selectedProfile()
        let external = try fixture.executable()
        // Registration uses the existing probe stub, not the real user's profile.
        let externalID = try await manager.registerExternal(external)
        try await manager.select(externalID)
        XCTAssertEqual(try manager.selectedProfile().ownership, .sharedExisting)
        XCTAssertNotEqual(try manager.selectedProfile().directory, own.directory)
        try await manager.select(managed)
        XCTAssertEqual(try manager.selectedProfile(), own)
        let home = fixture.root.appendingPathComponent("disposable-home")
        XCTAssertEqual(PiProfile.existing(environment: ["HOME": home.path]).directory, home.appendingPathComponent(".pi/agent"))
        let custom = home.appendingPathComponent("existing-setup")
        XCTAssertEqual(PiProfile.existing(environment: ["HOME": home.path, "PI_CODING_AGENT_DIR": custom.path]).directory, custom)
    }
    @MainActor func testManagedRootAndNestedSymlinksCannotEscape() throws {
        let fixture = try Phase6Fixture(self), store = fixture.manager.store
        let profile = store.root.appendingPathComponent("profile"), outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside)
        XCTAssertThrowsError(try PiProfile.managed(store: store))
        try FileManager.default.removeItem(at: profile)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("settings.json"), withDestinationURL: outside.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try PiProfile.managed(store: store))
    }
    @MainActor func testLaunchEnvironmentSelectsWholeManagedProfileAndExistingSetup() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentInstallationStore(root: root.appendingPathComponent("owned"))
        let home = root.appendingPathComponent("home"), existing = home.appendingPathComponent(".pi/agent")
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["HOME": home.path, "PI_CODING_AGENT_DIR": existing.path])
        let resolver = PiLaunchResolver(runtime: runtime)
        // Use the pinned executable to test the launch translator, without downloading/installing.
        let record = resolver.installation(for: .bundled)
        let owned = try PiProfile.managed(store: store)
        let launch = try await resolver.resolve(record, lifecycle: nil, profile: owned)
        XCTAssertEqual(launch.environment["PI_CODING_AGENT_DIR"], owned.directory.path)
        XCTAssertEqual(launch.dataProfile, owned)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = PiBackend(resolveLaunch: { _, _ in launch })
        var sessionDirectory: URL?
        backend.onEvent = { event in if case .sessionDirectory(let path) = event { sessionDirectory = path } }
        do {
            try await backend.start(workspace: root, session: .init(id: 1, title: "Isolated profile"))
            XCTAssertTrue(try XCTUnwrap(sessionDirectory).path.hasPrefix(owned.directory.path + "/"))
            try await backend.shutdownAndWait()
        } catch { try? await backend.shutdownAndWait(); throw error }
        let external = try await resolver.resolve(record, lifecycle: nil)
        XCTAssertEqual(external.environment["PI_CODING_AGENT_DIR"], existing.path)
        XCTAssertEqual(external.dataProfile.ownership, .sharedExisting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path))
    }
}
