import XCTest
@testable import Milk

@MainActor private final class LifecycleGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let values = waiters; waiters = []; for waiter in values { waiter.resume() } }
}

@MainActor private final class LifecycleBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var captured: ((AgentEvent) -> Void)?
    let startGate = LifecycleGate(), exitGate = LifecycleGate()
    var enteredStart = false, enteredExit = false, exited = false, stopped = false
    var failExit = false
    var responses = 0
    func start(workspace: URL, session: AgentSession) async throws {
        enteredStart = true; captured = onEvent
        // Deliberately ignore cancellation, as an SDK or detached launch may do.
        await startGate.wait()
        captured?(.runtime(.init(phase: .ready, bundled: true, detail: "ready")))
    }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws { onEvent?(.started) }
    func stop() async throws { onEvent?(.settled(aborted: true)) }
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws { responses += 1 }
    func shutdown() { stopped = true; onEvent = nil }
    func shutdownAndWait() async throws {
        shutdown(); enteredExit = true
        await exitGate.wait()
        if failExit { throw AgentError.message("fixture exit unconfirmed") }
        exited = true
    }
}

@MainActor private final class LifecycleAdapter: AgentAdapter {
    let descriptor = PiAdapter.descriptor
    var backends: [LifecycleBackend] = []
    var holdNextStart = false, holdNextExit = false
    func makeBackend(context: AgentBackendContext) -> any AgentBackend {
        let backend = LifecycleBackend()
        if !holdNextStart { backend.startGate.release() }
        if !holdNextExit { backend.exitGate.release() }
        holdNextStart = false; holdNextExit = false
        backends.append(backend); return backend
    }
    func discoverPreview(root: URL, model: AgentModel?, lifecycle: AgentLifecycleCoordinator) async throws -> PreviewConfiguration {
        let lease = lifecycle.beginBackend(activation: .init(agentID: .pi, workspace: root, sessionID: -1), purpose: .previewInspection,
                                           factory: { self.makeBackend(context: .init(permission: .approval, purpose: .previewInspection)) }) { backend, lease in
            try await backend.start(workspace: root, session: .init(id: -1, title: "inspection"))
            try lease.check()
        }
        do {
            try await lease.work.value
            try await lifecycle.stopAndWait(lease)
            return .init(command: "fixture", directory: root)
        } catch { try await lifecycle.stopAndWait(lease); throw error }
    }
}

final class AgentLifecycleTests: XCTestCase {
    @MainActor private func until(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            guard Date() < deadline else { throw AgentError.message("Timed out: " + description) }
            await Task.yield()
        }
    }
    @MainActor private func fixture() throws -> (AgentService, LifecycleAdapter, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Milk.Lifecycle." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, enabled: false))
        try workspace.openWorkspace(root)
        let adapter = LifecycleAdapter(), agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter)
        agent.restore(nil)
        addTeardownBlock {
            await MainActor.run {
                for backend in adapter.backends { backend.startGate.release(); backend.exitGate.release(); backend.failExit = false }
            }
            let gone = await agent.shutdownAndWait(); XCTAssertTrue(gone)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        return (agent, adapter, root.resolvingSymlinksInPath())
    }

    @MainActor func testRestartWaitsForWriterAndKeepsOtherConversationAndRecoveredDraft() async throws {
        let (agent, adapter, _) = try fixture()
        adapter.holdNextExit = true
        let first = agent.selectedSession
        agent.current.draft = "first"; agent.submit()
        try await until("first running") { agent.runningSessions.contains(first) && !agent.pendingActions.contains(first) }
        let old = adapter.backends[0]
        agent.newSession(); let second = agent.selectedSession
        agent.current.draft = "second"; agent.submit()
        try await until("second running") { agent.runningSessions.contains(second) }
        agent.selectedSession = first
        agent.current.draft = "draft"; agent.current.queued = .init(text: "queued", attachments: [])
        agent.restart()
        try await until("old exit requested") { old.enteredExit }
        XCTAssertEqual(adapter.backends.count, 2, "No replacement factory until the old writer exits")
        XCTAssertTrue(agent.runningSessions.contains(second)); XCTAssertFalse(adapter.backends[1].stopped)
        XCTAssertTrue(agent.current.draft.contains("draft")); XCTAssertTrue(agent.current.draft.contains("queued"))
        old.captured?(.failure("stale failure")); old.captured?(.approval(.init(id: "stale", method: .select, title: "stale", message: "")))
        XCTAssertNil(agent.current.error); XCTAssertTrue(agent.approvals[first]?.isEmpty != false)
        old.exitGate.release()
        try await until("replacement ready") { adapter.backends.count == 3 && agent.runtimeStatuses[first]?.phase == .ready }
        XCTAssertTrue(old.exited); XCTAssertEqual(agent.selectedSession, first)
    }

    @MainActor func testCancelledParentCannotRegisterChildBehindItsOwnHandoffBarrier() async throws {
        let owner = AgentLifecycleCoordinator(), gate = LifecycleGate()
        let resource = LifecycleBackend(); resource.exitGate.release()
        var entered = false
        let activation = AgentActivation(agentID: .pi, workspace: URL(fileURLWithPath: "/tmp"), sessionID: 1)
        let parent = owner.begin(activation: activation, purpose: .conversation, factory: { resource }) { _, _ in
            entered = true; await gate.wait() // Simulate a detached operation ignoring cancellation.
            let child = owner.begin(activation: .init(agentID: .pi, workspace: activation.workspace, sessionID: -1), purpose: .versionProbe,
                                    factory: { XCTFail("Cancelled work created a child resource"); return resource }) { _, _ in }
            XCTAssertEqual(owner.owned.count, 1, "A cancelled parent cannot add a child waiting for that parent's exit")
            try await child.work.value
        }
        try await until("parent entered") { entered }
        owner.invalidateAll(); gate.release()
        try await owner.stopAndWait(parent)
        XCTAssertTrue(owner.owned.isEmpty)
    }

    @MainActor func testConfigurationInvalidatesPendingStartBeforeReplacementReady() async throws {
        let (agent, adapter, _) = try fixture()
        adapter.holdNextStart = true; adapter.holdNextExit = true
        agent.current.draft = "retain unsent"; agent.submit()
        try await until("pending start") { adapter.backends.first?.enteredStart == true }
        let old = adapter.backends[0]
        var config = agent.configuration; config.runtime = .external(URL(fileURLWithPath: "/tmp/lifecycle-config-fixture"))
        try agent.updateConfiguration(config, token: nil)
        XCTAssertTrue(old.stopped)
        old.startGate.release()
        try await until("pending startup cleanup") { old.enteredExit }
        XCTAssertNotEqual(agent.runtimeStatuses[agent.selectedSession]?.phase, .ready)
        XCTAssertEqual(adapter.backends.count, 1)
        old.exitGate.release()
        try await until("new ready") { adapter.backends.count == 2 && agent.runtimeStatuses[agent.selectedSession]?.phase == .ready }
        XCTAssertTrue(old.exited); XCTAssertEqual(agent.current.draft, "retain unsent")
        XCTAssertEqual(agent.configuration.runtime, config.runtime)
    }

    @MainActor func testQuitWaitsForClosedPendingStartWithoutHistoryAndAuxiliaryInspection() async throws {
        let (agent, adapter, root) = try fixture()
        adapter.holdNextStart = true; adapter.holdNextExit = true
        agent.current.draft = "pending"; agent.submit()
        try await until("conversation entered") { adapter.backends.first?.enteredStart == true }
        let conversation = adapter.backends[0]
        XCTAssertNil(agent.currentSession?.sessionFile)
        agent.closeSession(agent.selectedSession)
        adapter.holdNextStart = true; adapter.holdNextExit = true
        let preview = Task { try await agent.discoverPreview(root: root) }
        try await until("inspection entered") { adapter.backends.count == 2 && adapter.backends[1].enteredStart }
        let auxiliary = adapter.backends[1]
        var completed = false
        let quit = Task { let result = await agent.shutdownAndWait(); completed = true; return result }
        try await until("both invalidated") { conversation.stopped && auxiliary.stopped }
        XCTAssertFalse(completed)
        conversation.startGate.release(); auxiliary.startGate.release()
        try await until("both exit checks") { conversation.enteredExit && auxiliary.enteredExit }
        conversation.exitGate.release()
        try await until("conversation gone") { conversation.exited }
        XCTAssertFalse(completed, "Quit must still await auxiliary cleanup")
        auxiliary.exitGate.release()
        let gone = await quit.value; XCTAssertTrue(gone)
        do { _ = try await preview.value; XCTFail("Invalidated inspection returned a result") } catch {}
        XCTAssertTrue(agent.lifecycle.owned.isEmpty)
    }

    @MainActor func testFailedExitBlocksReplacementAndRetainsOwnerForRetry() async throws {
        let (agent, adapter, _) = try fixture()
        agent.current.draft = "connect"; agent.submit()
        try await until("running") { agent.busy && !agent.pendingActions.contains(agent.selectedSession) }
        let old = adapter.backends[0]; old.failExit = true
        agent.restart()
        try await until("replacement failure") { agent.current.error?.contains("exit unconfirmed") == true }
        XCTAssertEqual(adapter.backends.count, 1)
        XCTAssertFalse(agent.lifecycle.owned.isEmpty)
        old.failExit = false; agent.restart()
        try await until("retry ready") { adapter.backends.count == 2 && agent.runtimeStatuses[agent.selectedSession]?.phase == .ready }
        XCTAssertTrue(old.exited)
    }

    @MainActor func testRestartDismissesRuntimeDialogButRetainsHostPreviewDecision() async throws {
        let (agent, adapter, root) = try fixture()
        agent.current.draft = "connect"; agent.submit()
        try await until("connected") { agent.busy && !agent.pendingActions.contains(agent.selectedSession) }
        adapter.backends[0].onEvent?(.approval(.init(id: "runtime", method: .select, title: "Runtime request", message: "", options: ["Allow Once"], origin: .agentPermission)))
        let runtimeRequest = try XCTUnwrap(agent.approvals[agent.selectedSession]?.first)
        let host = Task { try await agent.authorizePreview(.init(command: "fixture", directory: root)) }
        try await until("host decision") { agent.approvals[agent.selectedSession]?.count == 2 }
        agent.restart()
        try await until("replacement") { adapter.backends.count == 2 && agent.runtimeStatuses[agent.selectedSession]?.phase == .ready }
        XCTAssertFalse(agent.approvals[agent.selectedSession]?.contains { $0.id == "runtime" } == true)
        agent.respond(runtimeRequest, session: agent.selectedSession, value: "Allow Once")
        XCTAssertEqual(adapter.backends[1].responses, 0)
        let request = try XCTUnwrap(agent.approvals[agent.selectedSession]?.first)
        XCTAssertEqual(request.origin, .milkPreview)
        agent.respond(request, session: agent.selectedSession, value: "Allow Once")
        let result = try await host.value; XCTAssertEqual(result.command, "fixture")
    }

    @MainActor func testUtilityProcessQuitWaitsForOwnedChildAndLeavesUnrelatedProcessAlive() async throws {
        let (_, _, root) = try fixture()
        let owner = AgentLifecycleCoordinator()
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["60"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let pidFile = root.appendingPathComponent("utility.pid")
        let script = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open('utility.pid','w').write(str(os.getpid())); time.sleep(60)"
        let operation = Task { try await PiUtilityProcess.execute(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], directory: root, timeout: 8, purpose: .versionProbe, lifecycle: owner) }
        try await until("utility launched") { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(owner.owned.values.first?.purpose, .versionProbe)
        let gone = await owner.shutdownAndWait(); XCTAssertTrue(gone)
        do { _ = try await operation.value; XCTFail("Cancelled utility returned a result") } catch {}
        XCTAssertNotEqual(kill(pid, 0), 0); XCTAssertTrue(unrelated.isRunning)
        XCTAssertTrue(owner.owned.isEmpty)
        do {
            _ = try await PiUtilityProcess.execute(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 8, purpose: .packageCommand, lifecycle: owner)
            XCTFail("Terminated owner accepted new work")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.owned.isEmpty)
    }
}
