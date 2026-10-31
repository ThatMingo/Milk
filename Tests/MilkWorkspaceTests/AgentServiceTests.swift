import XCTest
@testable import Milk

@MainActor private final class ControlledBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var failSend = false
    var closed = false
    var exitDelay: UInt64 = 0
    var didExit = false
    func start(workspace: URL, session: AgentSession) async throws {
        onEvent?(.state(.init(sessionFile: workspace.appendingPathComponent("saved.jsonl").path, sessionID: session.backendID, name: session.title, running: false)))
    }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws {
        try await Task.sleep(nanoseconds: 60_000_000)
        if failSend { throw AgentError.message("Provider unavailable") }
        onEvent?(.message(.init(id: "real-user", role: "user", text: prompt.text)))
        onEvent?(.started)
    }
    func stop() async throws { onEvent?(.settled(aborted: true)) }
    func clearQueue() async throws { onEvent?(.queue(followUp: [], steering: [])) }
    func steerQueued(_ prompt: AgentPrompt) async throws { }
    func setModel(_ model: AgentModel) async throws { }
    func setEffort(_ effort: String) async throws { }
    func setPermission(_ mode: ComposerPermissionMode) async throws { throw AgentError.message("Permission update rejected") }
    func rename(_ title: String) async throws { onEvent?(.sessionName(title)) }
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws { }
    func shutdown() { closed = true }
    func shutdownAndWait() async throws {
        shutdown()
        if exitDelay > 0 { try await Task.sleep(nanoseconds: exitDelay) }
        didExit = true
    }
}
final class AgentServiceTests: XCTestCase {
    @MainActor func testTerminationWaitsForOwnedBackend() async throws {
        let (_, agent, backend, _, _) = try fixture()
        agent.current.draft = "lifecycle fixture"
        agent.submit()
        try await Task.sleep(nanoseconds:200_000_000)
        backend.exitDelay=100_000_000
        let result=await agent.shutdownAndWait()
        XCTAssertTrue(result); XCTAssertTrue(backend.didExit)
    }
    @MainActor private func fixture() throws -> (WorkspaceStore, AgentService, ControlledBackend, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "MilkAgentTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, directory: root.appendingPathComponent("recovery"), enabled: false))
        try workspace.openWorkspace(root)
        let backend = ControlledBackend()
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, makeBackend: { backend })
        agent.restore(nil)
        return (workspace, agent, backend, root, defaults)
    }
    @MainActor private func settled(_ agent: AgentService, id: Int) async throws {
        for _ in 0..<100 {
            if !agent.pendingActions.contains(id) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Agent action did not finish")
    }
    @MainActor func testCloseReopenAndRelaunchPreserveSessionDraftQueueAndEditorLinkage() async throws {
        let (workspace, agent, backend, root, defaults) = try fixture()
        defer { agent.shutdown() }
        let file = root.appendingPathComponent("file.swift"); try Data("let milk = true".utf8).write(to: file)
        try workspace.openFile(file, pinned: true); let editorTab = workspace.activePane.activeTab?.id
        let id = agent.selectedSession
        agent.current.draft = "First instruction"; agent.submit(); try await settled(agent, id: id)
        XCTAssertEqual(agent.current.messages.last?.text, "First instruction")
        backend.onEvent?(.failure("A tool extension reported an error"))
        XCTAssertTrue(agent.busy, "A nonfatal error must not hide Stop while Pi is still running")
        agent.current.draft = "Unsent draft"
        agent.current.queued = .init(text: "Queued instruction", attachments: [.init(url: file, projectFile: true)])
        let path = try XCTUnwrap(agent.currentSession?.sessionFile)
        agent.closeSession(id)
        XCTAssertTrue(backend.closed); XCTAssertTrue(agent.sessions.isEmpty)
        agent.reopen(.init(path: path, title: "Saved", modified: .now))
        XCTAssertEqual(agent.selectedSession, id)
        XCTAssertEqual(workspace.activePane.activeTab?.id, editorTab)
        XCTAssertTrue(agent.current.draft.contains("Unsent draft")); XCTAssertTrue(agent.current.draft.contains("Queued instruction"))
        XCTAssertNil(agent.current.queued); XCTAssertEqual(agent.current.attachments.first?.url, file)
        let snapshot = try XCTUnwrap(agent.snapshot())
        let restored = AgentService(workspace: workspace, defaults: defaults, enabled: false)
        restored.restore(snapshot); defer { restored.shutdown() }
        XCTAssertEqual(restored.current.draft, agent.current.draft)
        XCTAssertEqual(restored.currentSession?.sessionFile, path)
    }
    @MainActor func testPhase2MigrationKeepsSelectedEditorAndAvoidsReusingOtherEditorIDs() throws {
        let (workspace, agent, _, root, defaults) = try fixture(); defer { agent.shutdown() }
        let file = root.appendingPathComponent("phase2.swift"); try Data("let restored = true".utf8).write(to: file)
        workspace.selectedSession = 3; try workspace.openFile(file, pinned: true)
        let tab = workspace.activePane.activeTab?.id
        workspace.sessions["8"] = EditorSession()
        let migrated = AgentService(workspace: workspace, defaults: defaults, enabled: false)
        migrated.restore(Data("old placeholder agent metadata".utf8)); defer { migrated.shutdown() }
        XCTAssertEqual(migrated.selectedSession, 3); XCTAssertEqual(workspace.activePane.activeTab?.id, tab)
        migrated.newSession(); XCTAssertGreaterThan(migrated.selectedSession, 8)
    }
    @MainActor func testFailedSendKeepsOriginalSessionDraftAfterTabSwitch() async throws {
        let (_, agent, backend, _, _) = try fixture(); defer { agent.shutdown() }
        let first = agent.selectedSession
        backend.failSend = true; agent.current.draft = "Keep this on failure"; agent.submit()
        agent.newSession(); let second = agent.selectedSession
        XCTAssertNotEqual(first, second)
        try await settled(agent, id: first)
        XCTAssertEqual(agent.conversations[first]?.draft, "Keep this on failure")
        XCTAssertEqual(agent.conversations[first]?.error, "Provider unavailable")
        XCTAssertNil(agent.conversations[second]?.error)
        XCTAssertEqual(agent.selectedSession, second)
    }
    @MainActor private func savedFixture(_ agent: AgentService, backend: ControlledBackend, root: URL) async throws -> SavedAgentSession {
        let id = agent.selectedSession
        agent.current.draft = "Persist this session"; agent.submit(); try await settled(agent, id: id)
        backend.onEvent?(.settled(aborted: false))
        backend.onEvent?(.sessionDirectory(root))
        let saved = try XCTUnwrap(agent.savedReference(try XCTUnwrap(agent.currentSession)))
        let header = JSONValue.object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString), "cwd": .string(root.path)])
        try Data((header.encodedString + "\n").utf8).write(to: URL(fileURLWithPath: saved.path))
        return saved
    }
    @MainActor func testDeleteWaitsForExitRemovesHistoryAndSelectsAnotherOpenSession() async throws {
        let (_, agent, backend, root, _) = try fixture(); defer { agent.shutdown() }
        let first = agent.selectedSession
        let saved = try await savedFixture(agent, backend: backend, root: root)
        agent.newSession(); let second = agent.selectedSession
        agent.selectedSession = first
        backend.exitDelay = 100_000_000
        let deletion = Task { try await agent.deleteSavedSession(saved) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "History must remain until runtime exit")
        XCTAssertEqual(agent.selectedSession, second)
        try await deletion.value
        XCTAssertTrue(backend.didExit); XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertNil(agent.conversations[first]); XCTAssertFalse(agent.recentHistory.contains { $0.path == saved.path })
        let snapshot = try JSONDecoder().decode(AgentWorkspaceState.self, from: XCTUnwrap(agent.snapshot()))
        XCTAssertFalse(snapshot.archived.contains { $0.id == first })
    }
    @MainActor func testDeleteFinalSessionLeavesNoSessionAndCanCreateAgain() async throws {
        let (_, agent, backend, root, _) = try fixture(); defer { agent.shutdown() }
        let saved = try await savedFixture(agent, backend: backend, root: root)
        try await agent.deleteSavedSession(saved)
        XCTAssertTrue(agent.sessions.isEmpty); XCTAssertEqual(agent.selectedSession, -1); XCTAssertNil(agent.currentSession)
        XCTAssertTrue(agent.current.messages.isEmpty)
        agent.newSession(); XCTAssertNotNil(agent.currentSession); XCTAssertGreaterThan(agent.selectedSession, 0)
    }
    @MainActor func testRunningDeleteRefusesAndCloseKeepsReopenableHistory() async throws {
        let (_, agent, backend, root, _) = try fixture(); defer { agent.shutdown() }
        let saved = try await savedFixture(agent, backend: backend, root: root), id = agent.selectedSession
        backend.onEvent?(.started)
        XCTAssertNotNil(agent.sessionDeletionUnavailableReason(saved))
        do { try await agent.deleteSavedSession(saved); XCTFail("Running deletion must refuse") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path)); XCTAssertEqual(agent.selectedSession, id)
        agent.closeSession(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        agent.reopen(saved); XCTAssertEqual(agent.selectedSession, id)
        XCTAssertFalse(agent.current.messages.isEmpty)
        agent.closeSession(id)
        // A previously closed saved session can be deleted from RECENT.
        for _ in 0..<100 where !agent.history.contains(where: { $0.path == saved.path }) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(agent.recentHistory.contains { $0.path == saved.path })
        try await agent.deleteSavedSession(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }

    @MainActor func testPiFailurePreservesLocalPreviewApprovalAndServerActivity() async throws {
        let (_, agent, backend, root, _) = try fixture()
        defer { agent.shutdown() }
        agent.current.draft = "Connect"; agent.submit(); try await settled(agent, id: agent.selectedSession)
        let decision = Task { try await agent.authorizePreview(.init(command: "npm run dev", directory: root)) }
        for _ in 0..<100 {
            if agent.presentedApproval != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        agent.recordPreviewActivity(id: "preview-live-server", output: "Server is running", status: .running)
        backend.onEvent?(.runtime(.init(phase: .failed, bundled: true, detail: "Pi disconnected")))
        let presentation = try XCTUnwrap(agent.presentedApproval)
        XCTAssertEqual(agent.current.activities.first(where: { $0.id == "preview-live-server" })?.status, .running)
        agent.respond(presentation.request, session: presentation.session, value: "Allow Once")
        let config = try await decision.value; XCTAssertEqual(config.command, "npm run dev")
    }

}
