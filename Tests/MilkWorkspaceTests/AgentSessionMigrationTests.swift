import XCTest
@testable import Milk

private final class SessionHistoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = false, deletes = 0
    var failDeletion: Bool { get { lock.lock(); defer { lock.unlock() }; return failures } set { lock.lock(); failures = newValue; lock.unlock() } }
    var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return deletes }
    func deleted() { lock.lock(); deletes += 1; lock.unlock() }
}
private struct SessionTestHistory: AgentFileSessionHistory {
    let probe: SessionHistoryProbe
    func history(workspace: URL, directory: URL) throws -> [SavedAgentSession] { try PiSessionService().history(workspace: workspace, directory: directory) }
    func validateDeletion(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws { try PiSessionService().validateDeletion(saved, workspace: workspace, directory: directory) }
    func delete(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws {
        probe.deleted()
        if probe.failDeletion { throw AgentError.message("fixture deletion refused") }
        try PiSessionService().delete(saved, workspace: workspace, directory: directory)
    }
}
@MainActor private final class SessionRoutingBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var sends = 0
    func start(workspace: URL, session: AgentSession) async throws {
        onEvent?(.state(.init(sessionFile: session.sessionFile, sessionID: session.backendID, name: session.title, running: false)))
        if let path = session.sessionFile { onEvent?(.sessionDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())) }
        onEvent?(.runtime(.init(phase: .ready, version: "fixture", bundled: true, detail: "ready")))
    }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws { sends += 1; onEvent?(.started) }
    func stop() async throws { onEvent?(.settled(aborted: true)) }
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws { onEvent?(.sessionName(title)) }
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws {}
    func shutdown() { onEvent = nil }
    func shutdownAndWait() async throws { shutdown() }
}
/// Routing test doubles only; no second production harness or SDK is implemented.
@MainActor private final class SessionRoutingAdapter: AgentAdapter {
    let descriptor: AgentDescriptor
    let probe = SessionHistoryProbe()
    var backends: [SessionRoutingBackend] = []
    var fileSessionHistory: (any AgentFileSessionHistory)? { SessionTestHistory(probe: probe) }
    init(_ id: AgentID) { descriptor = .init(id: id, name: id.rawValue, adapterVersion: "fixture-adapter", capabilities: [.streaming, .sessions, .sessionResume]) }
    func makeBackend(context: AgentBackendContext) -> any AgentBackend { let backend = SessionRoutingBackend(); backends.append(backend); return backend }
}

final class AgentSessionMigrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, UserDefaults, WorkspacePersistence, WorkspaceStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Session-Migration-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Milk.SessionMigration." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let persistence = WorkspacePersistence(defaults: defaults, directory: root.appendingPathComponent("support/Workspaces"), enabled: true)
        let workspace = WorkspaceStore(persistence: persistence); try workspace.openWorkspace(root)
        addTeardownBlock {
            await MainActor.run { workspace.sessionData = nil; try? workspace.closeWorkspace() }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        return (root, defaults, persistence, workspace)
    }
    private func nativeFile(_ root: URL, name: String = "saved", version: Int = 3) throws -> URL {
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name + ".jsonl")
        let header: [String: Any] = ["type": "session", "version": version, "id": name, "cwd": root.path]
        var data = try JSONSerialization.data(withJSONObject: header); data.append(10); try data.write(to: file)
        return file
    }
    private func legacy(_ state: AgentWorkspaceState) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        object["version"] = 3; object.removeValue(forKey: "selectedAgentID")
        for key in ["sessions", "archived"] {
            object[key] = (object[key] as! [[String: Any]]).map { item in var item = item; item.removeValue(forKey: "metadata"); return item }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
    @MainActor private func until(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() { guard Date() < deadline else { throw AgentError.message("Timed out: " + label) }; await Task.yield() }
    }

    @MainActor func testV3MigrationPreservesEditorNativeReferencesDraftsArchivesAndBackupIdempotently() async throws {
        let (root, defaults, persistence, workspace) = try fixture()
        let file = try nativeFile(root), bytes = try Data(contentsOf: file)
        let source = root.appendingPathComponent("file.swift"); try Data("let preserved = true".utf8).write(to: source)
        workspace.selectedSession = 7; try workspace.openFile(source, pinned: true)
        workspace.sessions["18"] = EditorSession()
        let tab = workspace.activePane.activeTab?.id
        let attachment = PromptAttachment(url: source, projectFile: true)
        let conversation = SessionConversation(messages: [.init(id: "saved", role: "assistant", text: "retained transcript")], draft: "unsent", attachments: [attachment], queued: .init(text: "queued", attachments: [attachment]))
        let payload = try legacy(.init(sessions: [.init(id: 7, title: "Open", backendID: "native-open", sessionFile: file.path)], conversations: [7: conversation], nextID: 8,
                                       archived: [.init(id: 2, title: "Archived", backendID: "native-archive", sessionFile: root.appendingPathComponent("archive.jsonl").path)]))
        workspace.sessionData = { payload }; try workspace.persistNow()
        let oldSnapshot = try Data(contentsOf: persistence.snapshotURL(root))
        let owner = SessionRoutingAdapter(.pi)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: owner)
        agent.restore(payload)
        let state = try JSONDecoder().decode(AgentWorkspaceState.self, from: XCTUnwrap(agent.snapshot()))
        XCTAssertEqual(state.version, 4); XCTAssertEqual(state.sessions.first?.id, 7)
        XCTAssertEqual(state.archived.first?.id, 2); XCTAssertEqual(state.sessions.first?.agentID, .pi)
        XCTAssertEqual(state.sessions.first?.backendID, "native-open"); XCTAssertEqual(state.sessions.first?.sessionFile, file.path)
        XCTAssertEqual(state.sessions.first?.metadata.workspace, SessionWorkspace(root))
        XCTAssertEqual(agent.current.messages.first?.text, "retained transcript")
        XCTAssertEqual(agent.current.draft, "unsent\n\nqueued"); XCTAssertEqual(agent.current.attachments, [attachment]); XCTAssertNil(agent.current.queued)
        XCTAssertEqual(workspace.activePane.activeTab?.id, tab)
        let again = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: owner)
        again.restore(payload)
        let repeated = try JSONDecoder().decode(AgentWorkspaceState.self, from: XCTUnwrap(again.snapshot()))
        XCTAssertEqual(state.sessions.first?.metadata.id, repeated.sessions.first?.metadata.id)
        XCTAssertEqual(state.archived.first?.metadata.id, repeated.archived.first?.metadata.id)
        again.restore(again.snapshot()); XCTAssertEqual(again.current.draft, agent.current.draft)
        workspace.sessionData = { agent.snapshot() }; try workspace.persistNow(); try workspace.persistNow()
        XCTAssertEqual(try Data(contentsOf: persistence.snapshotURL(root).appendingPathExtension("before-agent-v4")), oldSnapshot)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        agent.newSession(); XCTAssertGreaterThan(agent.selectedSession, 18)
        XCTAssertTrue(owner.backends.isEmpty)
        _ = await agent.shutdownAndWait(); _ = await again.shutdownAndWait()
    }

    @MainActor func testProjectChoiceAndGlobalDefaultDoNotReassignExistingOwners() async throws {
        let (root, defaults, _, workspace) = try fixture()
        let pi = SessionRoutingAdapter(.pi), alternate = SessionRoutingAdapter(.init(rawValue: "routing-test"))
        let registry = AgentRegistry(adapters: [pi, alternate], defaultAgentID: .pi)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, registry: registry)
        try agent.setGlobalDefaultAgent(alternate.descriptor.id)
        agent.restore(nil)
        let original = try XCTUnwrap(agent.currentSession)
        XCTAssertEqual(original.agentID, alternate.descriptor.id)
        try agent.selectProjectAgent(.pi); agent.newSession()
        XCTAssertEqual(agent.currentSession?.agentID, .pi)
        XCTAssertEqual(agent.sessions.first?.agentID, alternate.descriptor.id)
        let snapshot = agent.snapshot()
        let restored = AgentService(workspace: workspace, defaults: defaults, enabled: false, registry: registry)
        restored.restore(snapshot)
        XCTAssertEqual(restored.projectAgentID, .pi); XCTAssertEqual(restored.globalDefaultAgentID, alternate.descriptor.id)
        XCTAssertEqual(restored.sessions.first?.metadata.id, original.metadata.id)
        XCTAssertThrowsError(try restored.selectProjectAgent(.init(rawValue: "unregistered")))
        let old = try legacy(.init(sessions: [.init(id: 8, title: "Existing")], conversations: [:], nextID: 9, archived: []))
        restored.restore(old); XCTAssertEqual(restored.projectAgentID, .pi); XCTAssertEqual(restored.currentSession?.agentID, .pi)
        XCTAssertTrue(pi.backends.isEmpty); XCTAssertTrue(alternate.backends.isEmpty)
        XCTAssertEqual(restored.currentSession?.metadata.workspace, SessionWorkspace(root))
        _ = await restored.shutdownAndWait(); _ = await agent.shutdownAndWait()
    }

    @MainActor func testResumeUsesImmutableOwnerInsteadOfProjectSelection() async throws {
        let (root, defaults, _, workspace) = try fixture()
        let pi = SessionRoutingAdapter(.pi), owner = SessionRoutingAdapter(.init(rawValue: "routing-test"))
        let registry = AgentRegistry(adapters: [pi, owner], defaultAgentID: .pi)
        let file = try nativeFile(root)
        let metadata = AgentSessionMetadata(agentID: owner.descriptor.id, workspace: SessionWorkspace(root))
        let session = AgentSession(id: 7, title: "Owned", backendID: "saved", sessionFile: file.path, metadata: metadata)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, registry: registry)
        agent.restore(try JSONEncoder().encode(AgentWorkspaceState(sessions: [session], conversations: [7: .init(draft: "send")], nextID: 8, archived: [], selectedAgentID: .pi)))
        agent.submit(); try await until("owner send") { owner.backends.first?.sends == 1 && !agent.pendingActions.contains(7) }
        XCTAssertTrue(pi.backends.isEmpty)
        XCTAssertEqual(agent.currentSession?.metadata.lastAdapterVersion, "fixture-adapter")
        let saved = try XCTUnwrap(agent.savedReference(try XCTUnwrap(agent.currentSession)))
        agent.closeSession(7); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        agent.newSession(); agent.reopen(saved)
        XCTAssertEqual(agent.selectedSession, 7); XCTAssertEqual(agent.currentSession?.metadata.id, metadata.id)
        agent.current.draft = "resume"; agent.submit()
        try await until("owner resume") { owner.backends.count == 2 && owner.backends.last?.sends == 1 }
        XCTAssertTrue(pi.backends.isEmpty)
        _ = await agent.shutdownAndWait()
    }

    @MainActor func testOfflineIndexListsProjectsAndRetainsCacheWhenAgentOrRuntimeIsMissing() async throws {
        let (root, defaults, persistence, workspace) = try fixture()
        let file = try nativeFile(root)
        let owner = AgentID(rawValue: "uninstalled-owner")
        let session = AgentSession(id: 4, title: "Offline", backendID: "saved", sessionFile: file.path,
                                   metadata: .init(agentID: owner, workspace: SessionWorkspace(root)))
        let conversation = SessionConversation(messages: [.init(id: "cached", role: "assistant", text: "offline content")], draft: "retained draft")
        let state = AgentWorkspaceState(sessions: [session], conversations: [4: conversation], nextID: 5, archived: [], selectedAgentID: .pi)
        try persistence.save(.init(selectedSession: 4, shellSessions: JSONEncoder().encode(state)), root: root)
        let indexFile = root.appendingPathComponent("index.json")
        let index = AgentSessionIndex(file: indexFile, enabled: true)
        let record = IndexedAgentSession(session: session, workspace: SessionWorkspace(root), isOpen: true)
        let other = root.appendingPathComponent("other-project")
        let otherSession = AgentSession(id: 4, title: "Other", metadata: .init(agentID: .pi, workspace: SessionWorkspace(other)))
        try index.upsert([record, .init(session: otherSession, workspace: SessionWorkspace(other), isOpen: false)])
        let offline = AgentSessionIndex(file: indexFile, enabled: true)
        XCTAssertEqual(offline.records().count, 2); XCTAssertEqual(offline.records(workspace: SessionWorkspace(root)).count, 1)
        XCTAssertEqual(offline.cachedConversation(record, persistence: persistence)?.messages.first?.text, "offline content")
        let pi = SessionRoutingAdapter(.pi)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: pi, sessionIndex: offline)
        agent.restore(try JSONEncoder().encode(state)); agent.submit()
        try await until("missing owner reported") { agent.current.error != nil }
        XCTAssertEqual(agent.availability(try XCTUnwrap(agent.currentSession)).state, .agentUnavailable)
        XCTAssertEqual(agent.current.messages.first?.text, "offline content"); XCTAssertTrue(pi.backends.isEmpty)
        var config = AgentConfiguration(); config.runtime = .external(root.appendingPathComponent("missing-pi"))
        let runtime = PiRuntimeService(resources: root.appendingPathComponent("no-resources"))
        let piSession = AgentSession(id: 4, title: "Pi retained", backendID: "saved", sessionFile: file.path, metadata: .init(agentID: .pi, workspace: SessionWorkspace(root)))
        let adapter = PiAdapter(runtime: runtime, configuration: { config })
        XCTAssertEqual(adapter.sessionAvailability(piSession, workspace: SessionWorkspace(root)).state, .runtimeUnavailable)
        let newer = try nativeFile(root, name: "newer", version: 99)
        let unsupported = AgentSession(id: 5, title: "Future format", sessionFile: newer.path)
        XCTAssertEqual(adapter.sessionAvailability(unsupported, workspace: SessionWorkspace(root)).state, .unsupportedFormat)
        XCTAssertTrue(agent.lifecycle.owned.isEmpty)
        _ = await agent.shutdownAndWait()
    }

    @MainActor func testDeletionRoutesToOwnerAndIndexSurvivesUnderlyingFailure() async throws {
        let (root, defaults, _, workspace) = try fixture()
        let file = try nativeFile(root), pi = SessionRoutingAdapter(.pi), owner = SessionRoutingAdapter(.init(rawValue: "routing-test"))
        let session = AgentSession(id: 6, title: "Delete", backendID: "saved", sessionFile: file.path, metadata: .init(agentID: owner.descriptor.id, workspace: SessionWorkspace(root)))
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, registry: .init(adapters: [pi, owner], defaultAgentID: .pi))
        agent.restore(try JSONEncoder().encode(AgentWorkspaceState(sessions: [session], conversations: [6: .init(draft: "connect")], nextID: 7, archived: [], selectedAgentID: .pi)))
        agent.submit(); try await until("connected") { owner.backends.first?.sends == 1 && !agent.pendingActions.contains(6) }
        owner.backends[0].onEvent?(.settled(aborted: false))
        let saved = try XCTUnwrap(agent.savedReference(try XCTUnwrap(agent.currentSession)))
        owner.probe.failDeletion = true
        do { try await agent.deleteSavedSession(saved); XCTFail("Underlying failure should propagate") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(agent.retainedSessions().contains { $0.id == session.metadata.id })
        XCTAssertEqual(pi.probe.deleteCount, 0)
        owner.probe.failDeletion = false
        try await agent.deleteSavedSession(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(agent.retainedSessions().contains { $0.id == session.metadata.id })
        XCTAssertEqual(owner.probe.deleteCount, 2); XCTAssertEqual(pi.probe.deleteCount, 0)
        _ = await agent.shutdownAndWait()
    }

    @MainActor func testFuturePayloadAndUnreadableIndexAreRetainedWithoutOverwrite() async throws {
        let (root, defaults, _, workspace) = try fixture()
        workspace.selectedSession = 12
        let pi = SessionRoutingAdapter(.pi), agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: pi)
        let future = Data(#"{"version":99,"opaque":{"keep":[1,2,3]}}"#.utf8)
        agent.restore(future); agent.newSession()
        XCTAssertEqual(agent.snapshot(), future); XCTAssertNotNil(agent.restorationIssue)
        XCTAssertEqual(workspace.selectedSession, 12); XCTAssertTrue(agent.sessions.isEmpty); XCTAssertTrue(pi.backends.isEmpty)
        // Missing ownership is legacy only in v3; v4 must never guess an owner.
        var corrupt = try JSONSerialization.jsonObject(with: legacy(.init(sessions: [.init(id: 12, title: "No owner")], conversations: [:], nextID: 13, archived: []))) as! [String: Any]
        corrupt["version"] = 4
        let corruptPayload = try JSONSerialization.data(withJSONObject: corrupt)
        agent.restore(corruptPayload)
        XCTAssertEqual(agent.snapshot(), corruptPayload); XCTAssertTrue(agent.sessions.isEmpty)
        let indexFile = root.appendingPathComponent("unreadable-index.json"), bytes = Data("do not overwrite".utf8)
        try bytes.write(to: indexFile)
        let index = AgentSessionIndex(file: indexFile, enabled: true)
        XCTAssertThrowsError(try index.upsert([.init(session: .init(id: 1, title: "New"), workspace: SessionWorkspace(root), isOpen: true)]))
        XCTAssertEqual(try Data(contentsOf: indexFile), bytes)
        _ = await agent.shutdownAndWait()
    }
}
