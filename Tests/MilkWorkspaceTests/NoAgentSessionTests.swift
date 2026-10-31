import XCTest
@testable import Milk

final class NoAgentSessionTests: XCTestCase {
    @MainActor func testFreshChatStaysNeutralAcrossWorkspaceRestoreWithoutStartingAnAgent() async throws {
        let fixture = try Phase6Fixture(self)
        try fixture.manager.migrateLegacySelection(.bundled)
        let workspace = try fixture.workspace()
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: true,
            adapter: PiAdapter(runtime: fixture.manager.runtime, installations: fixture.manager), lifecycle: fixture.manager.lifecycle)
        agent.restore(nil)
        let session = try XCTUnwrap(agent.currentSession)
        XCTAssertNil(session.sessionFile)
        XCTAssertTrue(agent.showsNeutralChat)
        XCTAssertNil(agent.currentAgentDisplayName)
        XCTAssertEqual(agent.composerPlaceholder, "Message…")
        XCTAssertEqual(agent.statusLabel, "No agent selected")
        XCTAssertNil(agent.current.error)
        agent.current.draft = "An unsent draft"
        let snapshot = try XCTUnwrap(agent.snapshot())
        agent.restore(snapshot)
        XCTAssertTrue(agent.showsNeutralChat, "Persisting the automatic empty session must not invent an agent context")
        XCTAssertEqual(agent.current.draft, "An unsent draft")
        XCTAssertEqual(agent.currentSession?.metadata.id, session.metadata.id)
        XCTAssertTrue(agent.lifecycle.owned.isEmpty)
        XCTAssertEqual(fixture.probes, 0)
        agent.workspaceClosed(); workspace.sessionData = nil; try workspace.closeWorkspace()
    }
    @MainActor func testSelectedInstallationShowsAgentIdentityWithoutLaunchingIt() throws {
        let fixture = try Phase6Fixture(self)
        try fixture.manager.migrateLegacySelection(.external(fixture.executable()))
        let workspace = try fixture.workspace()
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: true,
            adapter: PiAdapter(runtime: fixture.manager.runtime, installations: fixture.manager), lifecycle: fixture.manager.lifecycle)
        agent.restore(nil)
        XCTAssertFalse(agent.showsNeutralChat)
        XCTAssertEqual(agent.currentAgentDisplayName, "Pi")
        XCTAssertEqual(agent.composerPlaceholder, "Message Pi…")
        XCTAssertTrue(agent.lifecycle.owned.isEmpty)
        XCTAssertEqual(fixture.probes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("launched").path))
        agent.workspaceClosed(); workspace.sessionData = nil; try workspace.closeWorkspace()
    }
    @MainActor func testRestoredNativeSessionKeepsIdentityAndMissingFileDiagnosticWithoutInstallation() throws {
        let fixture = try Phase6Fixture(self)
        try fixture.manager.migrateLegacySelection(.bundled)
        let workspace = try fixture.workspace(), root = try XCTUnwrap(workspace.workspace?.url)
        let session = AgentSession(id: 7, title: "Actual retained session", sessionFile: root.appendingPathComponent("missing-session.jsonl").path,
            metadata: .init(agentID: .pi, workspace: SessionWorkspace(root)))
        let payload = AgentWorkspaceState(sessions: [session], conversations: [7: .init()], nextID: 8, archived: [], selectedAgentID: .pi)
        let agent = AgentService(workspace: workspace, defaults: fixture.defaults, enabled: true,
            adapter: PiAdapter(runtime: fixture.manager.runtime, installations: fixture.manager), lifecycle: fixture.manager.lifecycle)
        agent.restore(try JSONEncoder().encode(payload))
        XCTAssertFalse(agent.showsNeutralChat)
        XCTAssertEqual(agent.currentAgentDisplayName, "Pi")
        XCTAssertEqual(agent.composerPlaceholder, "Message Pi…")
        XCTAssertEqual(agent.availability(try XCTUnwrap(agent.currentSession)).state, .missingData)
        XCTAssertEqual(agent.unavailableReason, "The saved Pi session file is missing.")
        XCTAssertEqual(agent.currentSession?.metadata.id, session.metadata.id)
        XCTAssertEqual(agent.currentSession?.sessionFile, session.sessionFile)
        XCTAssertTrue(agent.lifecycle.owned.isEmpty)
        agent.workspaceClosed(); workspace.sessionData = nil; try workspace.closeWorkspace()
    }
    @MainActor func testShellLayoutRestoreCannotStartAReadyAdapterThroughSessionBinding() async throws {
        let fixture = try Phase6Fixture(self)
        var factories = 0
        let state = ShellState(persist: false, preferences: fixture.defaults, backendFactory: {
            factories += 1; return Phase6IdleBackend()
        })
        try state.workspace.openWorkspace(fixture.root)
        state.selectedSession = state.agent.selectedSession
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(factories, 0)
        XCTAssertTrue(state.agent.lifecycle.owned.isEmpty)
        XCTAssertFalse(state.agentInstallations.store.state.useLegacyRuntime)
        state.presentComposerPopup(.model)
        let deadline = Date().addingTimeInterval(3)
        while factories == 0 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(factories, 1, "An explicit model query must still connect before the first prompt")
        let stopped = await state.agent.shutdownAndWait()
        XCTAssertTrue(stopped)
        try state.workspace.closeWorkspace()
        _ = await state.preview.shutdown()
    }
    @MainActor func testRestoreAndCachedSelectionNeverLaunchPiOrProviderTelemetry() async throws {
        let fixture = try Phase6Fixture(self), executable = try fixture.executable()
        try fixture.manager.migrateLegacySelection(.external(executable))
        try await fixture.manager.verifyExternal(try XCTUnwrap(fixture.manager.store.state.selected))
        var configuration = PiProviderConfiguration();configuration.provider = .local;configuration.local.selectedModel="retained-provider-model"
        configuration.local.endpoint=URL(string:"http://127.0.0.1:1")!;try configuration.save(fixture.defaults)
        let workspace = try fixture.workspace(), root = try XCTUnwrap(workspace.workspace?.url)
        let first = AgentSession(id:7,title:"Retained",metadata:.init(agentID:.pi,workspace:SessionWorkspace(root)))
        let second = AgentSession(id:8,title:"Closed",metadata:.init(agentID:.pi,workspace:SessionWorkspace(root)))
        let conversation=SessionConversation(messages:[.init(id:"cached",role:"assistant",text:"cached content")],draft:"draft",queued:.init(text:"queued",attachments:[]))
        let payload=AgentWorkspaceState(sessions:[first],conversations:[7:conversation,8:.init(draft:"other draft")],nextID:9,archived:[second],selectedAgentID:.pi)
        let agent=AgentService(workspace:workspace,defaults:fixture.defaults,enabled:true,
            adapter:PiAdapter(runtime:fixture.manager.runtime,installations:fixture.manager,configuration:{ .load(fixture.defaults) },providerConfiguration:{configuration}),lifecycle:fixture.manager.lifecycle)
        agent.restore(try JSONEncoder().encode(payload))
        let closed=try XCTUnwrap(agent.retainedSessions().first { $0.id == second.metadata.id })
        agent.openRetainedForBrowsing(closed);agent.selectForBrowsing(7)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.manager.lifecycle.owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("launched").path))
        XCTAssertEqual(fixture.probes,1,"Only the explicitly requested verification runs")
        XCTAssertTrue(agent.runtimeStatuses.isEmpty)
        XCTAssertEqual(agent.current.messages.first?.text,"cached content")
        XCTAssertTrue(agent.current.draft.contains("draft"));XCTAssertTrue(agent.current.draft.contains("queued"))
        XCTAssertEqual(agent.currentSession?.metadata.id,first.metadata.id);XCTAssertEqual(agent.currentSession?.id,7)
        agent.shutdown();workspace.sessionData=nil;try workspace.closeWorkspace()
    }
    @MainActor func testCurrentAndAllProjectsBrowseOfflineCacheWithoutReassigningSessions() async throws {
        let fixture=try Phase6Fixture(self);try fixture.manager.migrateLegacySelection(.bundled)
        let workspace=try fixture.workspace(), currentRoot=try XCTUnwrap(workspace.workspace?.url)
        let other=fixture.root.appendingPathComponent("Other Project")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let a=AgentSession(id:2,title:"Current retained",metadata:.init(agentID:.pi,workspace:SessionWorkspace(currentRoot)))
        let b=AgentSession(id:2,title:"Other retained",metadata:.init(agentID:.pi,workspace:SessionWorkspace(other)))
        let otherState=AgentWorkspaceState(sessions:[b],conversations:[2:.init(messages:[.init(id:"m",role:"assistant",text:"other cached history")])],nextID:3,archived:[],selectedAgentID:.pi)
        try workspace.persistence.save(.init(selectedSession:2,shellSessions:JSONEncoder().encode(otherState)),root:other)
        let agent=AgentService(workspace:workspace,defaults:fixture.defaults,enabled:true,
            adapter:PiAdapter(runtime:fixture.manager.runtime,installations:fixture.manager),lifecycle:fixture.manager.lifecycle)
        let state=AgentWorkspaceState(sessions:[a],conversations:[2:.init(draft:"retained current draft")],nextID:3,archived:[],selectedAgentID:.pi)
        agent.restore(try JSONEncoder().encode(state))
        let otherRecord=IndexedAgentSession(session:b,workspace:SessionWorkspace(other),isOpen:false)
        try agent.sessionIndex.upsert([otherRecord])
        XCTAssertEqual(agent.sessionsForBrowsing(.currentProject).map(\.id),[a.metadata.id])
        XCTAssertEqual(Set(agent.sessionsForBrowsing(.allProjects).map(\.id)),[a.metadata.id,b.metadata.id])
        XCTAssertEqual(agent.retainedConversation(otherRecord)?.messages.first?.text,"other cached history")
        XCTAssertEqual(agent.retainedAvailability(otherRecord).state,.runtimeUnavailable)
        agent.openRetainedForBrowsing(otherRecord)
        XCTAssertEqual(agent.currentSession?.metadata.id,a.metadata.id,"Browsing another project's metadata must not rebind its session")
        XCTAssertEqual(agent.globalDefaultAgentID,.pi);XCTAssertEqual(agent.projectAgentID,.pi)
        XCTAssertNotNil(agent.unavailableReason)
        agent.workspaceClosed()
        workspace.sessionData=nil;try workspace.closeWorkspace()
        XCTAssertTrue(agent.sessionsForBrowsing(.currentProject).isEmpty)
        XCTAssertEqual(agent.sessionsForBrowsing(.allProjects).count,2)
        XCTAssertTrue(fixture.manager.lifecycle.owned.isEmpty);XCTAssertEqual(fixture.probes,0)
    }
    @MainActor func testProductionResolutionCannotAdoptBundledRuntimeEvenWhenOldFilesExist() async throws {
        let fixture=try Phase6Fixture(self), executable=try fixture.executable()
        let bundled=fixture.root.appendingPathComponent("resources/PiRuntime")
        try FileManager.default.createDirectory(at:bundled,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:executable,to:bundled.appendingPathComponent("pi"))
        let manifest=PiRuntimeManifest(version:"1.4.0",archiveSHA256:String(repeating:"0",count:64),executableSHA256:try PiInstallationFiles.digest(executable),source:"fixture",tools:[],runtimeFiles:[:])
        try JSONEncoder().encode(manifest).write(to:bundled.appendingPathComponent("runtime-manifest.json"))
        let production=PiRuntimeService(resources:fixture.root.appendingPathComponent("resources"),allowBundledFixture:false)
        XCTAssertThrowsError(try production.locate(.bundled))
        do { _ = try await PiLaunchResolver(runtime:production).resolve(.bundled,lifecycle:fixture.manager.lifecycle);XCTFail("Production used bundled Pi") } catch { }
        try fixture.manager.migrateLegacySelection(.bundled)
        do { _ = try await fixture.manager.resolve(legacy:.bundled,owner:fixture.manager.lifecycle);XCTFail("Manager fell back to bundle") } catch { }
        XCTAssertTrue(fixture.manager.lifecycle.owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("launched").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:bundled.appendingPathComponent("pi").path),"Migration does not delete old app resources")
    }
}

@MainActor private final class Phase6IdleBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    func start(workspace: URL, session: AgentSession) async throws {}
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws {}
    func stop() async throws {}
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws {}
    func shutdown() {}
    func shutdownAndWait() async throws {}
}
