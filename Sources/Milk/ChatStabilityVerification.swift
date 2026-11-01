import AppKit
import SwiftUI
import Combine

/// Explicit opt-in developer mode. All workspace/Pi/defaults state is disposable;
/// the upstream runtime and loopback model fixture are test inputs only.
@MainActor enum ChatStabilityVerification {
    private static let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Chat-Native-" + UUID().uuidString)
    private static let suite = "Milk.ChatNative." + UUID().uuidString
    private static var provider = PiProviderConfiguration()
    static func makeState() -> ShellState {
        let defaults = UserDefaults(suiteName: suite)!
        var configuration = AgentConfiguration(); configuration.defaultPermission = .autonomous
        try? configuration.save(defaults)
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": temporary.appendingPathComponent("agent").path])
        return ShellState(persist: false, preferences: defaults, agentAdapter: PiAdapter(runtime: runtime, configuration: { configuration }, defaults: defaults, providerConfiguration: { provider }))
    }
    static func run(state: ShellState, window: NSWindow) async {
        var results: [String] = []
        func check(_ value: Bool, _ label: String) { results.append("\(value ? "PASS" : "FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds: 250_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(25)
            while !predicate() {
                guard Date() < deadline else { throw AgentError.message("Native chat timeout \(label): \(state.agent.current.error ?? state.taskLabel)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func allScrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(allScrollViews)
        }
        func transcriptScroll() -> NSScrollView? {
            window.contentView.flatMap { allScrollViews($0).filter { $0.frame.width > 400 && $0.identifier?.rawValue != "milk.composer.input" && !($0.documentView is NSTextView) }.max { $0.frame.height < $1.frame.height } }
        }
        func wheel(_ delta: CGFloat, in scroll: NSScrollView) {
            // Deliver genuine AppKit scroll-wheel events through the native view.
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { return }
            let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            event.location = window.convertPoint(toScreen: center)
            if let native = NSEvent(cgEvent: event) { scroll.scrollWheel(with: native) }
        }
        let server = Process()
        var observedEmpty = false
        var restorationObservation: AnyCancellable?
        do {
            let root = temporary.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent("agent"), withIntermediateDirectories: true)
            try Data("Native chat fixture input\n".utf8).write(to: root.appendingPathComponent("group-input.txt"))
            let output = Pipe()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-u", project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
            server.standardOutput = output; server.standardError = FileHandle.nullDevice
            try server.run()
            let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Int(port) != nil else { throw AgentError.message("Loopback fixture did not start") }
            provider.provider = .local; provider.local.endpoint = URL(string: "http://127.0.0.1:\(port)")!
            provider.local.models = [.init(id: "reasoning-fixture", contextWindow: 64000, maxTokens: 4096, reasoning: true, images: false)]
            provider.local.selectedModel = "reasoning-fixture"
            try state.workspace.openWorkspace(root)
            state.applyPreset(.chat)
            window.setContentSize(NSSize(width: 900, height: 650))
            if CommandLine.arguments.contains("--verify-chat-quality") {
                try await ChatQualityVerification.run(state: state, window: window, root: root, project: project)
            } else {
            state.agent.current.draft = "grouped-fixture"; state.submitComposerPrompt()
            try await wait("thinking/tools/output") { !state.agent.busy && !state.agent.pendingActions.contains(state.selectedSession) && state.agent.current.messages.last?.text.contains("complete") == true }
            await settle()
            let first = state.selectedSession
            let turn = AgentTranscript.items(messages: state.agent.current.messages, activities: state.agent.current.activities).last?.response
            check(turn?.blocks.filter(\.visibleThinking).count == 2 && turn?.activities.count == 2, "Native window: new prompt, thinking, read + bash and final output")
            try Data("Second native chat fixture input\n".utf8).write(to: root.appendingPathComponent("group-input.txt"))
            let previousMessages = state.agent.current.messages.count
            state.agent.current.draft = "grouped-fixture repeat"; state.submitComposerPrompt()
            try await wait("reused tool IDs") { !state.agent.busy && !state.agent.pendingActions.contains(first) && state.agent.current.messages.count > previousMessages && state.agent.current.messages.last?.text.contains("complete") == true }
            await settle()
            let before = AgentTranscript.items(messages: state.agent.current.messages, activities: state.agent.current.activities)
            check(state.agent.current.activities.count == 4 && before.compactMap(\.response).map { $0.activities.count } == [2, 2], "Repeated real-Pi toolCallIds retain both operations in their original turns")
            let outputs = state.agent.current.activities.map(\.output)
            check(outputs.count == 4 && outputs[0].contains("Native chat fixture input") && outputs[2].contains("Second native chat fixture input"), "Reused tool IDs keep each operation's distinct output")
            let IDs = state.agent.current.messages.map(\.id)
            let blocks = before.last?.response?.blocks
            restorationObservation = state.agent.$conversations.sink { if $0[first]?.messages.isEmpty == true { observedEmpty = true } }
            state.agent.restart()
            try await wait("native resume") { state.agent.runtimeStatuses[first]?.phase == .ready }
            await settle(); restorationObservation?.cancel()
            check(!observedEmpty && state.agent.current.messages.map(\.id) == IDs, "Native resume keeps visible transcript and all message IDs")
            check(AgentTranscript.items(messages: state.agent.current.messages, activities: state.agent.current.activities).last?.response?.blocks == blocks && state.agent.current.activities.map(\.output) == outputs, "Restored thinking/tool/output order, IDs and repeated-tool outputs are unchanged")
            // Long Markdown/text stream gives the native scroll view room to move.
            state.agent.current.draft = "chat-scroll-fixture"; state.submitComposerPrompt()
            try await wait("long streaming content") { state.agent.busy && (state.agent.current.messages.last?.text.count ?? 0) > 1500 }
            await settle()
            guard var scroll = transcriptScroll() else { throw AgentError.message("Could not locate native transcript scroll view") }
            let bottomBefore = scroll.contentView.bounds.minY
            check(bottomBefore > 100, "Native size-change anchoring follows growing response")
            wheel(420, in: scroll); await settle()
            let up = scroll.contentView.bounds.minY
            results.append("INFO upward offset=\(up) initial=\(bottomBefore) followsTail=\(state.agent.current.followsTail)")
            check(up < bottomBefore - 20, "Native scroll wheel moves upward during generation")
            try await Task.sleep(nanoseconds: 400_000_000)
            check(abs(scroll.contentView.bounds.minY - up) < 5, "Streaming does not pull the reading position back down")
            results.append("INFO before switch savedOffset=\(state.agent.current.scrollOffset ?? -1) followsTail=\(state.agent.current.followsTail)")
            state.newSession(); await settle(); state.selectedSession = first; await settle()
            guard let returned = transcriptScroll() else { throw AgentError.message("Transcript did not return after switching") }
            scroll = returned
            results.append("INFO after switch offset=\(scroll.contentView.bounds.minY) savedOffset=\(state.agent.current.scrollOffset ?? -1) followsTail=\(state.agent.current.followsTail)")
            check(!state.agent.current.followsTail && abs(scroll.contentView.bounds.minY - up) < 5, "Switching away and back preserves the reading position while generation continues")
            // A native lazy transcript may resolve more rows after the first
            // wheel event. Continue the downward gesture until its real tail.
            for _ in 0..<8 {
                wheel(-100_000, in: scroll)
                try await Task.sleep(nanoseconds: 60_000_000)
                let remaining = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
                if remaining < 5 { break }
            }
            await settle()
            let bottom = scroll.contentView.bounds.minY
            let textBeforeGrowth = state.agent.current.messages.last?.text.count ?? 0
            results.append("INFO bottom offset=\(bottom) content=\(scroll.documentView?.frame.height ?? 0) viewport=\(scroll.contentView.bounds.height) followsTail=\(state.agent.current.followsTail)")
            try await Task.sleep(nanoseconds: 400_000_000)
            let bottomGap = abs((scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY)
            let textGrew = (state.agent.current.messages.last?.text.count ?? 0) > textBeforeGrowth
            results.append("INFO after growth offset=\(scroll.contentView.bounds.minY) content=\(scroll.documentView?.frame.height ?? 0) followsTail=\(state.agent.current.followsTail) bottomGap=\(bottomGap) textGrew=\(textGrew)")
            // Estimated heights can shrink while text grows. Following means the
            // real bottom gap stays zero while new text arrives, not a monotonic offset.
            check(state.agent.current.followsTail && textGrew && bottomGap < 2, "Returning near the bottom resumes following growth")
            state.newSession(); let second = state.selectedSession
            await settle(); state.selectedSession = first; await settle()
            check(second != first && state.agent.current.messages.count >= IDs.count && state.agent.busy, "Switch away and back retains the original live conversation")
            state.agent.stop(); try await wait("stop") { !state.agent.busy }
            await settle()
            }
        } catch { results.append("FAIL \(error.localizedDescription)") }
        restorationObservation?.cancel()
        check(await state.agent.shutdownAndWait(), "All disposable Pi processes exited")
        if server.isRunning { server.terminate() }; if server.processIdentifier != 0 { server.waitUntilExit() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
        let report = results.joined(separator: "\n") + "\n"
        try? report.write(to: project.appendingPathComponent("output/chat-stability-native.txt"), atomically: true, encoding: .utf8)
        print(report)
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}
