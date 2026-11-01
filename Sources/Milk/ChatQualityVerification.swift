import AppKit
import SwiftUI
import Combine
import Darwin

/// Developer-only, disposable native audit driver. Commands never run outside the
/// explicit verification mode and the owning Pi/workspace are temporary fixtures.
@MainActor enum ChatQualityVerification {
    static func run(state: ShellState, window: NSWindow, root: URL, project: URL) async throws {
        let output = project.appendingPathComponent("output/chat-phase2")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let commandFile = output.appendingPathComponent("command.json")
        try? FileManager.default.removeItem(at: commandFile)
        state.agent.connectForDiscovery()
        let deadline = Date().addingTimeInterval(30)
        while state.agent.runtimeStatuses[state.selectedSession]?.phase != .ready {
            if Date() > deadline { throw AgentError.message(state.agent.current.error ?? "Quality fixture startup timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.title = "Milk · Disposable Chat Audit"
        window.setContentSize(.init(width: 1060, height: 800))
        var lastTick = ProcessInfo.processInfo.systemUptime
        let heartbeat = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            ChatRenderMetrics.shared.record("main.loop.delay", milliseconds: max(0, now - lastTick - 1.0 / 60) * 1000)
            lastTick = now
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        var publications = 0
        var clipboardBackup: [NSPasteboardItem] = []
        var clipboardCount: Int?
        var lastCopyMatched = false
        var appearanceReference: NSHostingView<AnyView>?
        let observation = state.agent.$conversations.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func transcriptScroll() -> NSScrollView? {
            window.contentView.flatMap { view in
                scrollViews(view).filter { $0.identifier?.rawValue != "milk.composer.input" && !($0.documentView is NSTextView) && $0.frame.width > 300 }
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            }
        }
        func snapshot() -> [String: Any] {
            let scroll = transcriptScroll()
            var basic = mach_task_basic_info(), size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &basic) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size) }
            }
            return ["pid": ProcessInfo.processInfo.processIdentifier, "root": root.path, "session": state.selectedSession,
                    "busy": state.agent.busy, "pending": state.agent.pendingActions.contains(state.selectedSession), "messages": state.agent.current.messages.count,
                    "characters": state.agent.current.messages.reduce(0) { $0 + $1.text.count }, "lastText": String((state.agent.current.messages.last?.text ?? "").suffix(500)),
                    "activities": state.agent.current.activities.count, "changes": state.agent.current.changes.count, "error": state.agent.current.error ?? "",
                    "render": ChatScrollAudit.snapshot?() ?? [:],
                    "activeResponse": state.agent.current.messages.last(where: { $0.role == "assistant" })?.id ?? "",
                    "scroller": scroll?.verticalScroller?.doubleValue ?? -1,
                    "knob": scroll?.verticalScroller?.knobProportion ?? -1,
                    "nativeScrollIdentity": scroll.map { String(describing: ObjectIdentifier($0)) } ?? "",
                    "publications": publications, "followsTail": state.agent.current.followsTail, "savedOffset": state.agent.current.scrollOffset ?? -1,
                    "scrollAnchor": state.agent.current.scrollAnchor ?? "", "scrollAnchorOwner": state.agent.current.scrollAnchorOwner ?? "", "scrollWidth": state.agent.current.scrollWidth ?? -1,
                    "lastCopyMatched": lastCopyMatched,
                    "windowWidth": window.frame.width, "windowHeight": window.frame.height,
                    "offset": scroll?.contentView.bounds.minY ?? -1, "contentHeight": scroll?.documentView?.frame.height ?? -1, "viewportHeight": scroll?.contentView.bounds.height ?? -1,
                    "rssBytes": result == KERN_SUCCESS ? basic.resident_size : 0, "metrics": ChatRenderMetrics.shared.snapshot()]
        }
        func save(_ value: [String: Any], name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic)
        }
        try save(snapshot(), name: "ready.json")
        let end = Date().addingTimeInterval(3600)
        while Date() < end {
            if let data = try? Data(contentsOf: commandFile), let command = try? JSONDecoder().decode(JSONValue.self, from: data) {
                try? FileManager.default.removeItem(at: commandFile)
                let id = command["id"].string ?? UUID().uuidString
                let action = command["action"].string ?? "state"
                if action == "finish" { try save(snapshot(), name: "result-" + id + ".json"); return }
                switch action {
                case "prompt": state.updateComposerDraft(command["text"].string ?? ""); state.submitComposerPrompt()
                case "draft": state.updateComposerDraft(command["text"].string ?? "")
                case "type":
                    if let content = window.contentView,
                       let input = scrollViews(content).first(where: { $0.identifier?.rawValue == "milk.composer.input" })?.documentView as? NSTextView {
                        window.makeFirstResponder(input)
                        input.insertText(command["text"].string ?? "", replacementRange: input.selectedRange())
                    }
                case "replay":
                    let source = project.appendingPathComponent("output/chat-manual-fixes/repro.jsonl")
                    let file = root.appendingPathComponent("repro.jsonl")
                    try? FileManager.default.removeItem(at: file)
                    var lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
                    if var header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any] {
                        header["cwd"] = root.path
                        lines[0] = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
                    }
                    try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                    state.newSession()
                    if let index = state.agent.sessions.firstIndex(where: { $0.id == state.selectedSession }) {
                        state.agent.sessions[index].sessionFile = file.path
                    }
                    state.agent.restart()
                case "stop": state.agent.stop()
                case "new": state.newSession()
                case "switch": state.selectedSession = Int(command["session"].number ?? 0)
                case "resize": window.setContentSize(.init(width: command["width"].number ?? 1000, height: command["height"].number ?? 800))
                case "sidebar": state.toggleSidebar()
                case "coding": state.applyPreset(.coding)
                case "chat": state.applyPreset(.chat)
                case "presentation":
                    state.agent.current.notice = command["notice"].string
                    state.agent.current.error = command["error"].string
                case "restart": state.agent.restart()
                case "referenceOn":
                    if let scroll = transcriptScroll() {
                        appearanceReference?.removeFromSuperview()
                        let host = NSHostingView(rootView: AnyView(ChatAppearanceReference.view(state.agent.current, narrow: scroll.frame.width < 560)
                            .environment(\.colorScheme, .dark)
                            .environment(\.milkExtensionRegistry, state.nativeExtensions.registry)
                            .environment(\.milkExtensionActionContext, .init(workspaceURL: root))))
                        host.frame = scroll.frame; host.autoresizingMask = [.width, .height]
                        scroll.superview?.addSubview(host, positioned: .above, relativeTo: scroll)
                        appearanceReference = host
                    }
                case "referenceOff": appearanceReference?.removeFromSuperview(); appearanceReference = nil
                case "keyboard":
                    if let scroll = transcriptScroll(), let document = scroll.documentView,
                       let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(command["keyCode"].number ?? 116)) {
                        window.makeFirstResponder(document); document.keyDown(with: event)
                    }
                case "wheel", "wheelBurst":
                    for _ in 0..<(action == "wheelBurst" ? max(1, min(100, Int(command["count"].number ?? 20))) : 1) {
                    if let scroll = transcriptScroll(),
                       let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(command["delta"].number ?? 100), wheel2: 0, wheel3: 0) {
                        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                        event.location = window.convertPoint(toScreen: center)
                        if let native = NSEvent(cgEvent: event) { scroll.scrollWheel(with: native) }
                    }
                    }
                case "beginCopyProbe":
                    clipboardBackup = (NSPasteboard.general.pasteboardItems ?? []).map { original in
                        let copy = NSPasteboardItem()
                        for type in original.types { if let data = original.data(forType: type) { copy.setData(data, forType: type) } }
                        return copy
                    }
                    clipboardCount = NSPasteboard.general.changeCount
                case "endCopyProbe":
                    let expected = command["expected"].string ?? ""
                    lastCopyMatched = NSPasteboard.general.string(forType: .string) == expected && NSPasteboard.general.changeCount != clipboardCount
                    if lastCopyMatched { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(clipboardBackup) }
                    clipboardBackup = []; clipboardCount = nil
                case "resetMetrics": ChatRenderMetrics.shared.reset(); publications = 0
                case "longAnswer":
                    state.newSession()
                    state.agent.current.messages = [.init(id: "quality-long-answer", role: "assistant", text: ChatQualityFixture.markdown(sections: Int(command["sections"].number ?? 160)))]
                case "profile":
                    let measurement = ChatQualityBenchmark.run()
                    try save(measurement, name: "profile-" + id + ".json")
                case "seed", "nativeHistory":
                    let count = Int(command["turns"].number ?? 300)
                    let varied = command["varied"].bool
                    let fixture = await Task.detached(priority: .userInitiated) { ChatQualityFixture.history(turns: count, workspace: root, varied: varied) }.value
                    let cache = await Task.detached(priority: .userInitiated) { fixture.history.reconcile(with: .init()) }.value
                    state.newSession()
                    state.agent.current = cache
                    if action == "nativeHistory" {
                        let file = root.appendingPathComponent("quality-history-" + UUID().uuidString + ".jsonl")
                        try await Task.detached { try fixture.data.write(to: file) }.value
                        if let index = state.agent.sessions.firstIndex(where: { $0.id == state.selectedSession }) {
                            state.agent.sessions[index].sessionFile = file.path; state.agent.sessions[index].backendID = fixture.id
                        }
                        state.agent.restart()
                    }
                default: break
                }
                try save(snapshot(), name: "result-" + id + ".json")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

enum ChatQualityFixture {
    static func markdown(sections: Int) -> String {
        (1...max(1, sections)).map { index in
            """
            ## Step \(index): inspect the request lifecycle

            The coordinator keeps **one stable response** while `request_\(index)` grows. This paragraph describes the real implementation tradeoff and includes enough ordinary text to wrap across multiple lines at narrow and wide chat sizes. [Reference](https://example.com/reference)

            - Keep the completed prefix intact.
            - Update only the active response tail.

            ```swift
            func handleRequest\(index)(_ input: String) async throws -> String {
                let result = try await service.respond(to: input)
                return result
            }
            ```

            > Verify selection, scrolling, and readable code before moving on.

            """
        }.joined(separator: "\n")
    }
    struct HistoryFixture { var id: String; var data: Data; var history: AgentHistory }
    static func history(turns: Int, workspace: URL, varied: Bool = false) -> HistoryFixture {
        let id = UUID().uuidString, encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var rows: [JSONValue] = [.object(["type": .string("session"), "version": .number(3), "id": .string(id), "cwd": .string(workspace.path), "timestamp": .string("2026-11-01T00:00:00.000Z")])]
        var history = AgentHistory(), decoder = PiMessageDecoder(), parent: String?
        let usage: JSONValue = .object(["input": .number(100), "output": .number(100), "cacheRead": .number(0), "cacheWrite": .number(0), "totalTokens": .number(200), "cost": .object(["input": .number(0), "output": .number(0), "cacheRead": .number(0), "cacheWrite": .number(0), "total": .number(0)])])
        for index in 0..<max(1, turns) {
            let answer = varied ? markdown(sections: 2).replacingOccurrences(of: "request", with: "request_\(index)") : markdown(sections: 2)
            let messages: [JSONValue] = [
                .object(["role": .string("user"), "content": .string("Inspect request \(index) and explain the next implementation step."), "timestamp": .number(Double(1_790_000_000_000 + index * 2))]),
                .object(["role": .string("assistant"), "content": .array([.object(["type": .string("thinking"), "thinking": .string("Compare the request boundaries before making the change.")]), .object(["type": .string("text"), "text": .string(answer)])]), "timestamp": .number(Double(1_790_000_000_001 + index * 2)), "api": .string("openai-completions"), "provider": .string("milk-local"), "model": .string("reasoning-fixture"), "stopReason": .string("stop"), "usage": usage])]
            for value in messages {
                let entry = UUID().uuidString
                rows.append(.object(["type": .string("message"), "id": .string(entry), "parentId": parent.map(JSONValue.string) ?? .null, "timestamp": .string("2026-11-01T00:00:00.000Z"), "message": value]))
                history.messages.append(decoder.restore(value)); parent = entry
            }
        }
        let data = rows.reduce(into: Data()) { result, row in result.append((try? encoder.encode(row)) ?? Data()); result.append(10) }
        return .init(id: id, data: data, history: history)
    }
}

@MainActor enum ChatQualityBenchmark {
    static func run() -> [String: Any] {
        func timed(_ iterations: Int, _ operation: () -> Void) -> [String: Double] {
            var values: [Double] = []
            for _ in 0..<iterations { let start = DispatchTime.now().uptimeNanoseconds; operation(); values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
            values.sort()
            return ["iterations": Double(iterations), "mean_ms": values.reduce(0, +) / Double(iterations), "p95_ms": values[Int(Double(iterations - 1) * 0.95)], "max_ms": values.last ?? 0]
        }
        var results: [String: Any] = [:]
        for count in [20, 80, 240] {
            let text = ChatQualityFixture.markdown(sections: count)
            results["markdown-\(text.utf8.count)-bytes"] = timed(10) { _ = AgentMarkdownBlock.parse(text) }
        }
        for count in [50, 300, 800] {
            let history = ChatQualityFixture.history(turns: count, workspace: FileManager.default.temporaryDirectory).history
            let projection = AgentTranscriptProjection()
            var messages = history.messages
            _ = projection.items(messages: messages, activities: [])
            results["projection-\(count)-turns"] = timed(30) { messages[messages.count - 1].text += " more"; _ = projection.items(messages: messages, activities: []) }
            let cache = history.reconcile(with: .init())
            results["reconciliation-\(count)-turns"] = timed(5) { _ = history.reconcile(with: cache) }
        }
        return results
    }
}
