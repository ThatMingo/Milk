import XCTest
@testable import Milk

/// Runs the actual pinned standalone Pi against a loopback fixture, with an isolated Pi agent dir.
final class PiIntegrationTests: XCTestCase {
    @MainActor func testPreviewInspectionUsesRealPiReadOnlyEphemeralAndReturnsConfiguration() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Preview-Pi-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("Workspace"), agentDir = temporary.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(#"{"scripts":{"preview:local":"vite"}}"#.utf8).write(to: root.appendingPathComponent("web/package.json"))
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": agentDir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        var configuration = AgentConfiguration(); var provider = PiProviderConfiguration()
        configuration.defaultPermission = .autonomous // Discovery remains read-only in this mode too.
        provider.provider = .local; provider.local.endpoint = URL(string: "http://127.0.0.1:\(port)")!
        provider.local.models = ["milk-fixture"].map { .init(id: $0, contextWindow: 64000, maxTokens: 4096, reasoning: $0 == "reasoning-fixture", images: false) }; provider.local.selectedModel = "milk-fixture"
        let backend = PiAdapter(runtime: runtime, configuration: { configuration }, providerConfiguration: { provider }).makeBackend(context: .init(permission: configuration.defaultPermission, purpose: .previewInspection))
        let config = try await PreviewPiAssistant.discover(root: root, backend: backend)
        try await backend.shutdownAndWait()
        XCTAssertEqual(config.command, "npm run preview:local"); XCTAssertEqual(config.directory.path, root.appendingPathComponent("web").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preview-discovery-must-not-write.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("web/package.json"), encoding: .utf8), #"{"scripts":{"preview:local":"vite"}}"#)
        let files = FileManager.default.enumerator(at: agentDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertFalse(files.contains { $0.pathExtension == "jsonl" }, "Inspection must not add a user Pi session")
    }
    @MainActor private func wait(_ label: String, timeout: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { throw AgentError.message("Timed out waiting for \(label)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    @MainActor func testVanillaPiStreamingApprovalsQueueSteerAbortHistoryAndLocalModels() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Pi-Integration-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("Workspace"), agentDir = temporary.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let server = Process(), portPipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let portText = String(decoding: portPipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(portText))
        let runtime = PiRuntimeService(resources: ProcessInfo.processInfo.environment["MILK_TEST_RUNTIME_RESOURCES"].map { URL(fileURLWithPath: $0) } ?? project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": agentDir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        var configuration = AgentConfiguration(); var provider = PiProviderConfiguration()
        provider.provider = .local; provider.local.endpoint = URL(string: "http://127.0.0.1:\(port)")!
        provider.local.models = ["milk-fixture", "reasoning-fixture"].map { .init(id: $0, contextWindow: 64000, maxTokens: 4096, reasoning: $0 == "reasoning-fixture", images: false) }; provider.local.selectedModel = "milk-fixture"
        let backend = PiBackend(runtime: runtime, providerConfiguration: provider); defer { backend.shutdown() }
        var events: [AgentEvent] = [], settled = 0, streamed = "", approvals: [AgentApproval] = [], changes: [AgentFileChange] = [], sessionFile: String?, directory: URL?, model: AgentModel?, levels: [String] = []
        var liveMessages: [AgentMessage] = [], liveActivities: [AgentActivity] = []
        var decision = "Deny", failures: [String] = []
        backend.onEvent = { event in
            events.append(event)
            switch event {
            case .settled: settled += 1
            case .contentDelta(let delta):
                if delta.kind == .text { streamed += delta.text }
                if let index = liveMessages.firstIndex(where: { $0.id == delta.messageID }) { liveMessages[index].apply(delta) }
            case .message(let message):
                if let index = liveMessages.firstIndex(where: { $0.id == message.id }) { liveMessages[index] = message } else { liveMessages.append(message) }
            case .activity(let activity):
                if let index = liveActivities.firstIndex(where: { $0.id == activity.id }) { liveActivities[index] = activity } else { liveActivities.append(activity) }
            case .approval(let request):
                XCTAssertEqual(request.origin, .agentPermission)
                approvals.append(request)
                if request.method == .select { try? backend.respond(request, value: decision, confirmed: nil, cancelled: false) }
                else if request.method == .editor { try? backend.respond(request, value: "/usr/bin/printf 'edited command output'", confirmed: nil, cancelled: false) }
                else { try? backend.respond(request, value: nil, confirmed: true, cancelled: false) }
            case .changes(let files): changes = files
            case .state(let state): sessionFile = state.sessionFile; model = state.model
            case .sessionDirectory(let url): directory = url
            case .efforts(let values, _): levels = values
            case .failure(let text): failures.append(text)
            default: break
            }
        }
        try await backend.start(workspace: root, session: .init(id: 0, title: "Integration"), configuration: configuration)
        XCTAssertEqual(model?.provider, PiProviderSupport.providerID); XCTAssertEqual(model?.modelID, "milk-fixture"); XCTAssertEqual(levels, ["off"])
        try await backend.setModel(.init(provider: PiProviderSupport.providerID, modelID: "reasoning-fixture", name: "Reasoning", supportsImages: false))
        XCTAssertGreaterThan(levels.count, 1)
        try await backend.setEffort(try XCTUnwrap(levels.last))
        try await backend.setModel(.init(provider: PiProviderSupport.providerID, modelID: "milk-fixture", name: "Fixture", supportsImages: false))
        XCTAssertEqual(levels, ["off"])
        let external = temporary.appendingPathComponent("attachment.txt")
        try Data("attached external text marker".utf8).write(to: external)
        var previous = settled
        try await backend.send(.init(text: "Read this attached context", attachments: [.init(url: external, projectFile: false)]), intent: .prompt)
        try await wait("attachment completion") { settled > previous }
        XCTAssertTrue(events.contains { if case .message(let message) = $0 { return message.role == "user" && message.text.contains("attached external text marker") }; return false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachment.txt").path))
        let binary = temporary.appendingPathComponent("unsupported.bin")
        try Data([0, 255, 1]).write(to: binary)
        do { try await backend.send(.init(text: "Unsupported", attachments: [.init(url: binary, projectFile: false)]), intent: .prompt); XCTFail("Expected unsupported binary attachment error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("binary")) }

        previous = settled
        try await backend.send(.init(text: "write-fixture"), intent: .prompt)
        try await wait("denied run completion") { settled > previous }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-created.txt").path))
        XCTAssertTrue(approvals.contains { $0.title.contains("Approval required") && $0.message.contains(root.path) })
        XCTAssertTrue(streamed.contains("Fixture"))

        decision = "Allow Once"; previous = settled
        try await backend.send(.init(text: "write-fixture"), intent: .prompt)
        try await wait("allowed write") { settled > previous && FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-created.txt").path) }
        try await wait("real changed files") { changes.contains { $0.path == "agent-created.txt" && $0.kind == "Created" } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("agent-created.txt"), encoding: .utf8), "from fixture\n")
        XCTAssertTrue(events.contains { if case .activity(let activity) = $0 { return activity.kind == "Create" && activity.status == .completed }; return false })

        decision = "Edit Command"; previous = settled
        try await backend.send(.init(text: "pause-fixture"), intent: .prompt)
        try await wait("edited command completion") { settled > previous }
        XCTAssertTrue(events.contains { if case .activity(let activity) = $0 { return activity.output.contains("edited command output") && activity.detail.contains("edited command output") }; return false })

        decision = "Allow for Session"; previous = settled
        try await backend.send(.init(text: "write-fixture"), intent: .prompt)
        try await wait("session allowance") { settled > previous }
        let approvalCount = approvals.count
        previous = settled
        try await backend.send(.init(text: "write-fixture"), intent: .prompt)
        try await wait("reused allowance") { settled > previous }
        XCTAssertEqual(approvals.count, approvalCount)

        try await backend.rename("Named integration session")
        try await backend.setPermission(.autonomous)
        previous = settled
        try await backend.send(.init(text: "pause-fixture"), intent: .prompt)
        try await wait("running command") { events.contains { if case .activity(let activity) = $0 { return activity.kind == "Command" && activity.status == .running }; return false } }
        let queued = AgentPrompt(text: "Follow up now")
        try await backend.send(queued, intent: .followUp)
        try await backend.steerQueued(queued)
        try await wait("steered run completion") { settled > previous }
        XCTAssertTrue(events.contains { if case .queue(_, let steering) = $0 { return !steering.isEmpty }; return false })

        previous = settled; streamed = ""
        try await backend.send(.init(text: "slow-fixture"), intent: .prompt)
        try await wait("streaming before abort") { streamed.contains("streaming fixture") }
        try await backend.send(.init(text: "cancel this queued message"), intent: .followUp)
        try await backend.clearQueue()
        try await backend.stop()
        XCTAssertGreaterThan(settled, previous)
        XCTAssertTrue(events.contains { if case .settled(let aborted) = $0 { return aborted }; return false })
        try Data("Real grouped file context\n".utf8).write(to: root.appendingPathComponent("group-input.txt"))
        try await backend.setPermission(.approval); decision = "Allow Once"; previous = settled
        try await backend.send(.init(text: "grouped-fixture"), intent: .prompt)
        try await wait("grouped thinking/tool continuation") { settled > previous }
        let grouped = try XCTUnwrap(AgentTranscript.items(messages: liveMessages, activities: liveActivities).last?.response)
        XCTAssertEqual(grouped.activityIDs.count, 2)
        XCTAssertEqual(grouped.blocks.filter { $0.visibleThinking }.count, 2)
        XCTAssertEqual(grouped.blocks.map(\.kind), [.thinking, .text, .activity, .thinking, .text, .activity, .text])
        let contentSignature = grouped.blocks.map { $0.kind.rawValue + ":" + $0.text + ":" + ($0.activityID ?? "") }
        try await wait("session file state") { sessionFile != nil && directory != nil }
        let file = try XCTUnwrap(sessionFile), sessionDirectory = try XCTUnwrap(directory)
        let history = try PiSessionService().history(workspace: root, directory: sessionDirectory)
        XCTAssertTrue(history.contains { $0.path == file && $0.title == "Named integration session" }, "file=\(file) history=\(history)")
        try await backend.shutdownAndWait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), "Close preserves real Pi history")

        let restored = PiBackend(runtime: runtime, providerConfiguration: provider); defer { restored.shutdown() }
        var restoredMessages: [AgentMessage] = [], restoredActivities: [AgentActivity] = []
        restored.onEvent = {
            if case .history(let snapshot) = $0 { restoredMessages = snapshot.messages; restoredActivities = snapshot.activities }
        }
        try await restored.start(workspace: root, session: .init(id: 1, title: "Restored", sessionFile: file), configuration: configuration)
        XCTAssertTrue(restoredMessages.contains { $0.role == "assistant" && $0.text.contains("Fixture") })
        XCTAssertEqual(restoredMessages.map(\.id), liveMessages.map(\.id), "Native resume retains live message identities")
        let restoredTurn = try XCTUnwrap(AgentTranscript.items(messages: restoredMessages, activities: restoredActivities).last?.response)
        XCTAssertEqual(restoredTurn.blocks.map { $0.kind.rawValue + ":" + $0.text + ":" + ($0.activityID ?? "") }, contentSignature)
        XCTAssertEqual(restoredTurn.activityIDs.count, 2)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        try await restored.shutdownAndWait()
        try PiSessionService().delete(try XCTUnwrap(history.first { $0.path == file }), workspace: root, directory: sessionDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "Documented deletion removes actual pinned Pi JSONL history")
        XCTAssertFalse(try PiSessionService().history(workspace: root, directory: sessionDirectory).contains { $0.path == file })
    }
}
