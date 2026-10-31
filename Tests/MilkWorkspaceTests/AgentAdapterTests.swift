import XCTest
@testable import Milk

@MainActor private final class BoundaryBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var starts: [(URL, Int)] = []
    var intents: [AgentSubmissionIntent] = []
    var closed = false
    func start(workspace: URL, session: AgentSession) async throws { starts.append((workspace, session.id)) }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws { intents.append(intent); onEvent?(.started) }
    func stop() async throws { onEvent?(.settled(aborted: true)) }
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws {}
    func shutdown() { closed = true }
    func shutdownAndWait() async throws { shutdown() }
}

/// Test double only; deliberately has no Pi configuration or transport.
@MainActor private final class BoundaryAdapter: AgentAdapter {
    let descriptor = AgentDescriptor(id: .init(rawValue: "boundary-test"), name: "Boundary test", adapterVersion: "test", capabilities: [.streaming, .models, .reasoningLevels, .imageAttachments])
    var contexts: [AgentBackendContext] = []
    var backends: [BoundaryBackend] = []
    func makeBackend(context: AgentBackendContext) -> any AgentBackend {
        contexts.append(context)
        let backend = BoundaryBackend(); backends.append(backend); return backend
    }
}

final class AgentAdapterTests: XCTestCase {
    @MainActor func testRegistryAdvertisesOnlyImplementedPiAndDoesNotLaunchIt() {
        let registry = AgentRegistry.standard()
        XCTAssertEqual(registry.adapters.count, 1)
        XCTAssertEqual(registry.defaultAgentID, .pi)
        XCTAssertNil(registry.adapter(for: .init(rawValue: "unregistered")))
        let descriptor = registry.defaultAdapter.descriptor
        XCTAssertEqual(descriptor.name, "Pi")
        XCTAssertEqual(descriptor.adapterVersion, "1")
        XCTAssertEqual(descriptor.capabilities, [
            .streaming, .thinking, .tools, .permissions, .dialogs, .sessions, .sessionResume,
            .models, .reasoningLevels, .slashCommands, .steering, .followUpQueue,
            .textAttachments, .imageAttachments, .fileChanges, .nativeExtensionTools,
            .compactionNotifications, .retryNotifications, .previewInspection
        ])
    }

    @MainActor func testServiceUsesAdapterContextAndRejectsClosedActivationEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Milk.Boundary." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var configuration = AgentConfiguration(); configuration.defaultPermission = .autonomous; try configuration.save(defaults)
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, enabled: false))
        try workspace.openWorkspace(root)
        let adapter = BoundaryAdapter()
        let service = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter)
        addTeardownBlock { let stopped = await service.shutdownAndWait(); XCTAssertTrue(stopped) }
        service.restore(nil)
        XCTAssertEqual(service.agentIdentity, adapter.descriptor.id)
        XCTAssertTrue(adapter.backends.isEmpty, "Registry construction and disabled restoration do not launch a process")
        let id = service.selectedSession
        service.current.draft = "first"; service.submit()
        let deadline = Date().addingTimeInterval(5)
        while service.pendingActions.contains(id) {
            guard Date() < deadline else { throw AgentError.message("Boundary submission timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(adapter.contexts.count, 1)
        XCTAssertEqual(adapter.contexts.first?.permission, .autonomous)
        XCTAssertEqual(adapter.contexts.first?.purpose, .conversation)
        let backend = try XCTUnwrap(adapter.backends.first)
        XCTAssertEqual(backend.starts.first?.0, root.resolvingSymlinksInPath())
        XCTAssertEqual(backend.starts.first?.1, id)
        XCTAssertEqual(backend.intents, [.prompt])
        XCTAssertFalse(service.effectiveCapabilities.contains(.imageAttachments))
        let model = AgentModel(provider: "test", modelID: "test", name: "Test", supportsImages: true)
        backend.onEvent?(.state(.init(model: model, effort: "high", running: true)))
        backend.onEvent?(.models([model])); backend.onEvent?(.efforts(["high"], selected: "high"))
        XCTAssertTrue(service.effectiveCapabilities.contains(.imageAttachments))
        XCTAssertTrue(service.effectiveCapabilities.contains(.reasoningLevels))
        service.current.draft = "unsupported queue"; service.queueOrSteer()
        XCTAssertEqual(service.current.draft, "unsupported queue")
        XCTAssertEqual(backend.intents, [.prompt])

        let late = backend.onEvent
        service.closeSession(id); service.newSession()
        let next = service.selectedSession
        late?(.failure("stale failure")); late?(.slashCommands([.init(name: "stale", description: nil)]))
        XCTAssertTrue(backend.closed)
        XCTAssertNil(service.conversations[id]?.error)
        XCTAssertNil(service.conversations[next]?.error)
        XCTAssertNil(service.slashCommands[id]); XCTAssertNil(service.slashCommands[next])
    }
}
