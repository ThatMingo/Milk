import XCTest
import CryptoKit
@testable import Milk

@MainActor final class Phase6Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "Milk.Phase6." + UUID().uuidString
    let manager: PiInstallationManager
    var probeCount = 0
    var badProbe = false
    var badDownload = false
    init(_ test: XCTestCase) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Phase6-" + UUID().uuidString).resolvingSymlinksInPath()
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notice = root.appendingPathComponent("notices"); try FileManager.default.createDirectory(at: notice, withIntermediateDirectories: true)
        try Data("notice".utf8).write(to: notice.appendingPathComponent("LICENSE"))
        let cpu: [UInt8] = PiInstallationCatalog.architecture == "arm64" ? [12,0,0,1] : [7,0,0,1]
        let code = Data([207,250,237,254] + cpu + [0,0,0,0])
        let archive = Self.tar(code)
        let release = PiCatalogRelease(version: "1.4.0", platform: "darwin", architecture: PiInstallationCatalog.architecture,
            source: URL(string: "https://fixture.invalid/pi")!, artifacts: [.init(url: URL(string: "https://fixture.invalid/pi.tar")!, sha256: Self.hash(archive), binarySuffix: nil, destination: "pi")],
            files: ["pi": Self.hash(code)], executables: ["pi"], notices: ["LICENSE"], provenance: "Local Phase 6 fixture")
        let box = Phase6ProbeBox()
        manager = PiInstallationManager(store: .init(root: root.appendingPathComponent("Milk/Agents/pi")), lifecycle: .init(),
            runtime: .init(resources: root.appendingPathComponent("resources")), catalog: .init(releases: [release]), notices: notice,
            download: { _, target in try (box.badDownload ? Data("bad".utf8) : archive).write(to: target) },
            probe: { _, _, _ in box.probes += 1; return box.badProbe ? PiCompatibilityPolicy.result(.unsupported, version: "1.3.0", detail: "Unsupported fixture version") : PiCompatibilityPolicy.verified(version: "1.4.0") })
        self.box = box
        try FileManager.default.createDirectory(at: root.appendingPathComponent("resources"), withIntermediateDirectories: true)
        try Data("fixture integration".utf8).write(to: root.appendingPathComponent("resources/MilkPiIntegration.ts"))
        let root = root, suite = suite
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
    private let box: Phase6ProbeBox
    func failingProbe(_ value: Bool) { box.badProbe = value }
    func failingDownload(_ value: Bool) { box.badDownload = value }
    var probes: Int { box.probes }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func tar(_ code: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func field(_ value: String, _ offset: Int) { for (i, byte) in value.utf8.enumerated() { header[offset+i] = byte } }
        field("pi/pi", 0); field("0000700", 100); field("0000000",108);field("0000000",116)
        field(String(format: "%011o", code.count),124);field("00000000000",136)
        for i in 148..<156 { header[i] = 32 };header[156] = 48;field("ustar",257);field("00",263)
        field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ",148)
        var bytes = Data(header);bytes.append(code);bytes.append(Data(repeating:0,count:512-code.count));bytes.append(Data(repeating:0,count:1024));return bytes
    }
    func executable() throws -> URL {
        let file = root.appendingPathComponent("external pi")
        try Data("#!/bin/sh\nprintf launched >> '\(root.appendingPathComponent("launched").path)'\nexit 1\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func workspace() throws -> WorkspaceStore {
        let project = root.appendingPathComponent("Project");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let value = WorkspaceStore(persistence:.init(defaults:defaults,directory:root.appendingPathComponent("Milk/Workspaces"),enabled:true))
        try value.openWorkspace(project);return value
    }
}
@MainActor private final class Phase6ProbeBox { var probes=0;var badProbe=false;var badDownload=false }

final class AgentManagerSettingsTests: XCTestCase {
    private var credentials: CredentialTestStore!
    override func setUp() { super.setUp(); credentials = CredentialTestStore() }
    override func tearDown() { credentials.restore(); credentials = nil; super.tearDown() }

    @MainActor func testBundledMigrationIsMetadataOnlyIdempotentAndPreservesProviderConfiguration() throws {
        let fixture = try Phase6Fixture(self)
        let config = AgentConfiguration()
        try config.save(fixture.defaults); let bytes = fixture.defaults.data(forKey:AgentConfiguration.key)
        try fixture.manager.migrateLegacySelection(config.runtime)
        XCTAssertFalse(fixture.manager.store.state.useLegacyRuntime);XCTAssertNil(fixture.manager.store.state.selected)
        XCTAssertEqual(AgentManagerModel(manager:fixture.manager).status,"Not installed")
        XCTAssertEqual(fixture.probes,0);XCTAssertTrue(fixture.manager.store.state.managed.isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey:AgentConfiguration.key),bytes)
        let state = fixture.manager.store.state
        try fixture.manager.migrateLegacySelection(.external(URL(fileURLWithPath:"/unrelated")))
        XCTAssertEqual(fixture.manager.store.state,state)
        XCTAssertThrowsError(try fixture.manager.selectedInstallation())
    }
    @MainActor func testExternalMigrationRequiresExplicitVerificationAndOffersOnlyExternalActions() async throws {
        let fixture = try Phase6Fixture(self), executable = try fixture.executable()
        let before = try Data(contentsOf:executable)
        try fixture.manager.migrateLegacySelection(.external(executable))
        let model = AgentManagerModel(manager:fixture.manager)
        XCTAssertEqual(fixture.probes,0);XCTAssertEqual(model.external?.installation.executable,executable)
        XCTAssertTrue(model.needsVerification);XCTAssertThrowsError(try fixture.manager.selectedInstallation())
        XCTAssertEqual(Set(model.actions),[.verify,.useExisting,.forget])
        await model.perform(.verify)
        XCTAssertFalse(model.needsVerification);XCTAssertEqual(fixture.probes,1)
        XCTAssertEqual(try fixture.manager.selectedInstallation()?.executable,executable)
        fixture.failingProbe(true);await model.perform(.verify)
        XCTAssertEqual(model.status,"Unsupported installation");XCTAssertTrue(model.actions.contains(.retry))
        fixture.failingProbe(false);await model.perform(.retry)
        XCTAssertFalse(model.needsVerification)
        await model.perform(.remove) // guarded: never a valid external action
        XCTAssertEqual(try Data(contentsOf:executable),before)
        await model.perform(.forget)
        XCTAssertEqual(model.status,"Not installed");XCTAssertTrue(fixture.manager.store.state.external.isEmpty)
        XCTAssertEqual(try Data(contentsOf:executable),before)
    }
    @MainActor func testManagedActionsUseTransactionsAndStagedSelectionTracksRunningRevision() async throws {
        let fixture = try Phase6Fixture(self);try fixture.manager.migrateLegacySelection(.bundled)
        let model = AgentManagerModel(manager:fixture.manager)
        XCTAssertEqual(model.actions,[.install,.useExisting])
        await model.perform(.install)
        let first = try XCTUnwrap(model.managed)
        XCTAssertEqual(model.status,"Managed by Milk");XCTAssertFalse(model.actions.contains(.update));XCTAssertFalse(model.canRollback)
        await model.setAutoUpdate(true);XCTAssertTrue(fixture.manager.store.state.autoUpdate)
        await model.perform(.verify);XCTAssertEqual(fixture.probes,2)
        let lease = fixture.manager.lifecycle.begin(activation:.init(agentID:.pi,workspace:fixture.root,sessionID:1),purpose:.conversation,
            factory:{AgentOperationResource()}) { _, lease in lease.associate(first.installation) }
        try await lease.work.value
        await model.perform(.repair)
        XCTAssertEqual(model.state.selected,first.id);XCTAssertNotNil(model.state.pending)
        XCTAssertTrue(model.status.contains("staged"));XCTAssertTrue(model.actions.contains(.activate));XCTAssertNotNil(model.runningDescription)
        await model.perform(.activate)
        XCTAssertNil(model.state.pending);XCTAssertNotEqual(model.state.selected,first.id);XCTAssertTrue(model.canRollback)
        await model.perform(.rollback);XCTAssertEqual(model.state.selected,first.id)
        await model.perform(.remove)
        XCTAssertTrue(model.state.managed.isEmpty);XCTAssertNil(model.state.selected);XCTAssertEqual(model.status,"Not installed")
    }
    @MainActor func testInstallFailureOffersRetryAndPickerSelectionRequiresValidProbe() async throws {
        let fixture = try Phase6Fixture(self);try fixture.manager.migrateLegacySelection(.bundled)
        let model = AgentManagerModel(manager:fixture.manager)
        fixture.failingDownload(true);await model.perform(.install)
        XCTAssertTrue(model.actions.contains(.retry));XCTAssertNil(model.state.selected)
        fixture.failingDownload(false);await model.perform(.retry)
        let selected = model.state.selected;XCTAssertNotNil(selected)
        let executable = try fixture.executable();fixture.failingProbe(true)
        await model.useExisting(executable)
        XCTAssertEqual(model.state.selected,selected);XCTAssertTrue(model.state.external.isEmpty)
        fixture.failingProbe(false);await model.useExisting(executable)
        XCTAssertEqual(model.external?.installation.executable,executable);XCTAssertEqual(model.status,"Existing installation")
    }
    @MainActor func testProviderSaveDoesNotProbeOrChangeInstallationAndKeepsUnchangedKeychainSecret() async throws {
        let fixture = try Phase6Fixture(self);try fixture.manager.migrateLegacySelection(.bundled)
        let workspace = try fixture.workspace(), agent = AgentService(workspace:workspace,defaults:fixture.defaults,enabled:false,
            adapter:PiAdapter(runtime:fixture.manager.runtime,installations:fixture.manager),lifecycle:fixture.manager.lifecycle)
        agent.restore(nil)
        let endpoint = URL(string:"http://127.0.0.1:9999/phase6-"+UUID().uuidString)!
        let adapter = PiAdapter(runtime:fixture.manager.runtime,installations:fixture.manager,defaults:fixture.defaults)
        let profile = try adapter.providerProfileIdentity.rawValue
        defer { try? AgentProviderCredentials.save("",agent:.pi,provider:"local",endpoint:endpoint,profile:profile) }
        try AgentProviderCredentials.save("retain-phase6-secret",agent:.pi,provider:"local",endpoint:endpoint,profile:profile)
        var config = PiProviderConfiguration();config.local.endpoint=endpoint;try config.save(fixture.defaults,key:fixture.manager.providerSettingsKey)
        let state = fixture.manager.store.state
        let model = PiSettingsModel(agent:agent,adapter:adapter);model.configuration.provider = .local;model.model="new-provider-model";model.context="64000";model.output="4096";model.save()
        let deadline=Date().addingTimeInterval(3)
        while model.busy && Date()<deadline { await Task.yield() }
        XCTAssertFalse(model.busy);XCTAssertTrue(model.result.hasPrefix("Saved."),model.result)
        XCTAssertEqual(fixture.manager.store.state,state);XCTAssertEqual(fixture.probes,0)
        XCTAssertEqual(try adapter.providerConfiguration().local.selectedModel,"new-provider-model")
        XCTAssertEqual(try AgentProviderCredentials.token(agent:.pi,provider:"local",endpoint:endpoint,profile:profile),"retain-phase6-secret")
        XCTAssertTrue(fixture.manager.lifecycle.owned.isEmpty)
        agent.shutdown();workspace.sessionData=nil;try workspace.closeWorkspace()
    }
}
