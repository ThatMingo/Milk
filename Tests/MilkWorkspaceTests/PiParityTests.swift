import XCTest
@testable import Milk

/// Phase 0: characterize existing behavior without changing the production boundary.
final class PiParityTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @MainActor private func wait(_ label: String, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw AgentError.message("Parity timeout: " + label) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor private func fixture() throws -> (URL, PiRuntimeService, AgentConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Pi-Parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        try Data(#"{"scripts":{"preview:local":"vite"}}"#.utf8).write(to: root.appendingPathComponent("web/package.json"))
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/omlx_fixture.py").path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run()
        addTeardownBlock {
            if server.isRunning { server.terminate() }; server.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "MILK_OMLX_TOKEN": "fixture", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        var configuration = AgentConfiguration()
        configuration.omlx.enabled = true; configuration.omlx.endpoint = URL(string: "http://127.0.0.1:\(port)")!
        configuration.omlx.modelIDs = ["milk-fixture"]; configuration.omlx.defaultModel = "milk-fixture"
        return (root, runtime, configuration)
    }

    @MainActor func testConcurrentSessionsAndAuxiliaryPreviewRemainIndependent() async throws {
        let (root, runtime, configuration) = try fixture()
        let suite = "Milk.PiParity." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try configuration.save(defaults)
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, enabled: false))
        try workspace.openWorkspace(root)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: PiAdapter(runtime: runtime, configuration: { .load(defaults) }))
        addTeardownBlock { let exited = await agent.shutdownAndWait(); XCTAssertTrue(exited) }
        agent.restore(nil)
        let first = agent.selectedSession
        agent.current.draft = "slow-fixture first"; agent.submit()
        try await wait("first stream") { agent.current.messages.contains { $0.role == "assistant" && !$0.text.isEmpty } }
        agent.newSession(); let second = agent.selectedSession
        agent.current.draft = "slow-fixture second"; agent.submit()
        try await wait("second stream") { agent.current.messages.contains { $0.role == "assistant" && !$0.text.isEmpty } }
        XCTAssertEqual(agent.runningSessions, Set([first, second]))
        let before = agent.conversations[first]?.messages.last?.text.count ?? 0
        try await wait("background stream progresses") { (agent.conversations[first]?.messages.last?.text.count ?? 0) > before }
        let firstPath = try XCTUnwrap(agent.sessions.first { $0.id == first }?.sessionFile)
        let secondPath = try XCTUnwrap(agent.currentSession?.sessionFile)
        XCTAssertNotEqual(firstPath, secondPath)

        let inspection = PiAdapter(runtime: runtime, configuration: { configuration }).makeBackend(context: .init(permission: configuration.defaultPermission, purpose: .previewInspection))
        addTeardownBlock { try await inspection.shutdownAndWait() }
        let preview = try await PreviewPiAssistant.discover(root: root, backend: inspection)
        try await inspection.shutdownAndWait()
        XCTAssertEqual(preview.command, "npm run preview:local")
        XCTAssertEqual(agent.selectedSession, second)
        XCTAssertEqual(agent.runningSessions, Set([first, second]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preview-discovery-must-not-write.txt").path))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("agent"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertEqual(files.filter { $0.pathExtension == "jsonl" }.count, 2, "Preview must not create a third conversation")

        agent.selectedSession = first; agent.stop()
        try await wait("first stopped") { !agent.runningSessions.contains(first) }
        XCTAssertTrue(agent.runningSessions.contains(second))
        agent.closeSession(first)
        XCTAssertEqual(agent.selectedSession, second)
        XCTAssertTrue(agent.busy)
        agent.stop(); try await wait("second stopped") { !agent.busy }
        let exited = await agent.shutdownAndWait()
        XCTAssertTrue(exited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))
    }

    @MainActor func testRealPiSelectConfirmInputAndEditorRoundTrip() async throws {
        let (root, runtime, configuration) = try fixture()
        let extensions = root.appendingPathComponent("agent/extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        let source = """
        export default function(pi: any) {
          pi.registerCommand("parity-dialogs", { handler: async (_args: string, ctx: any) => {
            const selected = await ctx.ui.select("Choose", ["One", "Two"]);
            const confirmed = await ctx.ui.confirm("Confirm", "Continue?");
            const input = await ctx.ui.input("Input", "Placeholder");
            const edited = await ctx.ui.editor("Editor", "Original");
            const cancelled = await ctx.ui.input("Cancel");
            ctx.ui.notify(JSON.stringify({selected, confirmed, input, edited, cancelled: cancelled === undefined}), "info");
          }});
        }
        """
        try Data(source.utf8).write(to: extensions.appendingPathComponent("dialogs.ts"))
        let backend = PiBackend(runtime: runtime)
        addTeardownBlock { try await backend.shutdownAndWait() }
        var methods: [String] = [], dismissed: [String] = [], reply: JSONValue?, failures: [String] = []
        backend.onEvent = { event in
            switch event {
            case .approval(let request):
                XCTAssertEqual(request.origin, .agentExtension)
                methods.append(request.method.rawValue)
                do {
                    switch request.method {
                    case .select:
                        XCTAssertEqual(request.options, ["One", "Two"])
                        try backend.respond(request, value: "Two", confirmed: nil, cancelled: false)
                    case .confirm: try backend.respond(request, value: nil, confirmed: true, cancelled: false)
                    case .editor:
                        XCTAssertEqual(request.prefill, "Original")
                        try backend.respond(request, value: "Edited\n🥛", confirmed: nil, cancelled: false)
                    default:
                        if request.title == "Cancel" { try backend.respond(request, value: nil, confirmed: nil, cancelled: true) }
                        else {
                            XCTAssertEqual(request.prefill, "Placeholder")
                            try backend.respond(request, value: "Input 🥛", confirmed: nil, cancelled: false)
                        }
                    }
                } catch { failures.append(error.localizedDescription) }
            case .dismissApproval(let id): dismissed.append(id)
            case .notice(let text): reply = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            case .failure(let text), .extensionProblem(let text): failures.append(text)
            default: break
            }
        }
        try await backend.start(workspace: root, session: .init(id: 0, title: "Dialogs"), configuration: configuration)
        try await backend.send(.init(text: "/parity-dialogs"))
        try await wait("dialog replies") { reply != nil }
        XCTAssertEqual(methods, ["select", "confirm", "input", "editor", "input"])
        XCTAssertEqual(Set(dismissed).count, 5)
        XCTAssertEqual(reply?["selected"].string, "Two"); XCTAssertEqual(reply?["confirmed"].bool, true)
        XCTAssertEqual(reply?["input"].string, "Input 🥛"); XCTAssertEqual(reply?["edited"].string, "Edited\n🥛")
        XCTAssertEqual(reply?["cancelled"].bool, true); XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        try await backend.shutdownAndWait()
    }

    /// A controlled RPC peer covers failure/notification events without provider retry delays.
    @MainActor private func peer(ready: Bool) throws -> (URL, PiBackend, AgentConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Pi-Peer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("external pi")
        try FileManager.default.copyItem(at: project.appendingPathComponent("Tests/Fixtures/pi_parity_peer.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["MILK_PARITY_READY": ready ? "1" : "0"])
        var configuration = AgentConfiguration(); configuration.runtime = .external(executable)
        return (root, PiBackend(runtime: runtime), configuration)
    }

    @MainActor func testMissingIntegrationHandshakeFailsBeforeReadyOrHistory() async throws {
        let (root, backend, configuration) = try peer(ready: false)
        addTeardownBlock { try await backend.shutdownAndWait() }
        var phases: [RuntimeStatus.Phase] = [], history = false
        backend.onEvent = { event in
            if case .runtime(let status) = event { phases.append(status.phase) }
            if case .historyBegin = event { history = true }
        }
        do {
            try await backend.start(workspace: root, session: .init(id: 0, title: "Missing bridge"), configuration: configuration)
            XCTFail("A responsive RPC process without the Milk integration must not be ready")
        } catch { XCTAssertTrue(error.localizedDescription.contains("integration extension")) }
        XCTAssertEqual(phases, [.starting, .failed]); XCTAssertFalse(history)
        try await backend.shutdownAndWait()
    }

    @MainActor func testExternalPeerCompactionRetryAndSettledBoundary() async throws {
        let (root, backend, configuration) = try peer(ready: true)
        addTeardownBlock { try await backend.shutdownAndWait() }
        var notices: [String] = [], failures: [String] = [], settled = 0, ready = false
        backend.onEvent = { event in
            switch event {
            case .runtime(let status): if status.phase == .ready { ready = true; XCTAssertFalse(status.bundled); XCTAssertEqual(status.version, "1.4.0"); XCTAssertEqual(status.runtimeIdentity?.ownership, .external); XCTAssertEqual(status.runtimeIdentity?.version, "1.4.0") }
            case .notice(let text): notices.append(text)
            case .failure(let text): failures.append(text)
            case .settled: settled += 1
            default: break
            }
        }
        try await backend.start(workspace: root, session: .init(id: 0, title: "Notifications"), configuration: configuration)
        XCTAssertTrue(ready)
        try await backend.send(.init(text: "notifications"))
        try await wait("notifications") { failures.count == 1 }
        XCTAssertEqual(notices, ["Pi is compacting the session context.", "Provider retry 2: fixture overload"])
        XCTAssertEqual(failures, ["fixture retry exhausted"])
        XCTAssertEqual(settled, 0, "agent_end and retry notifications must not settle the run")
        try await backend.send(.init(text: "settle"))
        try await wait("settled") { settled == 1 }
        try await backend.shutdownAndWait()
    }
}
