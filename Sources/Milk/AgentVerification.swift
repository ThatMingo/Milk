import AppKit
import SwiftUI

/// Explicit developer verification mode: real bundled Pi, isolated user data, loopback provider fixture.
@MainActor enum AgentVerification {
    private static let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Agent-UI-" + UUID().uuidString)
    private static let suite = "Milk.AgentUIVerification." + UUID().uuidString
    static func makeState() -> ShellState {
        ShellState(persist: false, preferences: UserDefaults(suiteName: suite)!, agentAdapter: PiAdapter(runtime: PiRuntimeService(environmentOverrides: ["PI_CODING_AGENT_DIR": temporary.appendingPathComponent("agent").path, "MILK_OMLX_TOKEN": "fixture"]), configuration: { .load(UserDefaults(suiteName: suite)!) }))
    }
    static func run(state: ShellState, window: NSWindow) async {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-sessions-agent")
        var results: [String] = []
        func check(_ condition: Bool, _ label: String) { results.append("\(condition ? "PASS" : "FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds: 500_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate() {
                guard Date() < deadline else { throw AgentError.message("Timed out waiting for \(label): \(state.agent.current.error ?? state.taskLabel)") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        func marker(_ identifier: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { marker(identifier, in: $0) }.first
        }
        func popup() -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "milk.approval.popup" && $0.isVisible } }
        func composerRect() -> NSRect {
            guard let view = window.contentView.flatMap({ marker("milk.geometry.composer", in: $0) }) else { return .zero }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        func anchored(_ label: String) {
            guard let panel = popup() else { check(false, label + " popup exists"); return }
            let composer = composerRect()
            check(abs(panel.frame.minX - composer.minX) < 1 && abs(panel.frame.width - composer.width) < 1 && abs(panel.frame.minY - composer.maxY - 14) < 1, label)
        }
        func capture(_ name: String, sheet: Bool = false, includePopup: Bool = false) {
            guard let view = (sheet ? window.attachedSheet : window)?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if includePopup, let panel = popup(), let companion = panel.contentView,
               let companionBitmap = companion.bitmapImageRepForCachingDisplay(in: companion.bounds) {
                companion.cacheDisplay(in: companion.bounds, to: companionBitmap)
                let image = NSImage(size: view.bounds.size)
                image.lockFocus()
                NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(in: view.bounds)
                let rect = view.convert(window.convertFromScreen(panel.frame), from: nil)
                NSImage(cgImage: companionBitmap.cgImage!, size: companion.bounds.size).draw(in: rect)
                image.unlockFocus()
                if let data = image.tiffRepresentation, let rendered = NSBitmapImageRep(data: data) { try? rendered.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png")) }
            } else { try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png")) }
        }
        let server = Process()
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let root = temporary.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent("agent"), withIntermediateDirectories: true)
            let pipe = Pipe()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-u", URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/omlx_fixture.py").path]
            server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
            if CommandLine.arguments.contains("--interactive-chat-check") {
                var environment = ProcessInfo.processInfo.environment; environment["MILK_FIXTURE_APPROVAL_DELAY"] = "12"; server.environment = environment
            }
            try server.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Int(port) != nil else { throw AgentError.message("Could not launch the loopback provider fixture") }
            try state.workspace.openWorkspace(root)
            state.destination = "Sessions"
            var config = AgentConfiguration()
            config.omlx.enabled = true; config.omlx.endpoint = URL(string: "http://127.0.0.1:\(port)")!
            config.omlx.modelIDs = ["milk-fixture"]; config.omlx.defaultModel = "milk-fixture"
            try state.agent.updateConfiguration(config, token: nil)
            try await wait("bundled runtime") { state.agent.runtimeStatuses[state.selectedSession]?.phase == .ready }
            check(state.agent.runtimeStatuses[state.selectedSession]?.version == "1.4.0", "Packaged standalone Pi launches and reports its pinned version")
            check(state.selectedComposerModel?.name == "milk-fixture" && state.selectedComposerModel?.efforts.map(\.id) == ["off"], "Composer receives real provider model and effort capabilities")
            let input = root.appendingPathComponent("group-input.txt")
            try Data("Real grouped context\n".utf8).write(to: input)
            state.agent.current.draft = "grouped-fixture"
            if CommandLine.arguments.contains("--interactive-chat-check") {
                state.applyPreset(.coding); try state.workspace.openFile(input, pinned: true)
                while !FileManager.default.fileExists(atPath: "/tmp/milk-chat-check-finished") { try await Task.sleep(nanoseconds: 250_000_000) }
                state.agent.shutdown(); if server.isRunning { server.terminate() }
                try? FileManager.default.removeItem(at: temporary)
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05); return
            }
            state.agent.submit()
            try await wait("approval") { state.agent.presentedApproval != nil }
            await settle()
            check(window.attachedSheet == nil && popup()?.parent === window, "Approval is a nonmodal child popup; no sheet or dimming")
            anchored("Approval matches composer width/edges and a 14 pt gap")
            let approval = state.agent.presentedApproval!
            check(approval.request.command?.contains("grouped command output") == true, "Real Bash command populates the command surface")
            capture("approval", includePopup: true)
            let compactComposer = composerRect()
            state.agent.current.draft = "One\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight"
            await settle()
            check(composerRect().height > compactComposer.height, "Composer grows upward for multiline prompts")
            anchored("Approval follows composer growth without overlap")
            if let native = window.contentView.flatMap({ marker("milk.composer.input", in: $0) }) as? NSScrollView {
                check(native.frame.height <= ComposerInputMetrics.maximumHeight + 1 && native.hasVerticalScroller, "Composer caps at six rows and enables input scrolling")
            } else { check(false, "Native composer input exists") }
            state.applyPreset(.coding)
            try state.workspace.openFile(input, pinned: true)
            await settle()
            anchored("Approval follows workspace panel/layout changes")
            check(state.agent.presentedApproval?.id == approval.id && state.workspace.activeBuffer?.url == input, "Code remains usable while the tool stays gated")
            window.setContentSize(NSSize(width: 1280, height: 800)); await settle()
            anchored("Approval tracks native window resize")
            capture("approval-grown", includePopup: true)
            let originalPanel = popup()
            state.agent.respond(approval.request, session: approval.session, value: "Edit Command")
            try await wait("anchored command editor") { state.agent.presentedApproval?.request.method == .editor }
            await settle()
            check(popup() === originalPanel && window.attachedSheet == nil, "Edit Command stays in the same anchored panel")
            anchored("Command editor remains aligned to composer")
            await settle(); capture("edit-command", includePopup: true)
            let edit = state.agent.presentedApproval!
            state.agent.respond(edit.request, session: edit.session, value: "/usr/bin/printf 'edited from anchored popup'")
            try await wait("grouped completion") { !state.agent.busy && state.agent.current.messages.last?.text.contains("complete") == true }
            await settle()
            check(popup() == nil, "Resolved approval disappears immediately")
            let response = AgentTranscript.items(messages: state.agent.current.messages, activities: state.agent.current.activities).last?.response
            check(response?.activities.count == 2 && response?.blocks.filter { $0.visibleThinking }.count == 2, "Real Thinking and two tool continuations share one Pi response")
            check(response?.activities.contains(where: { $0.output.contains("edited from anchored popup") }) == true, "Edited command executes through the existing permission gate")
            let signature = response?.blocks.map { $0.kind.rawValue + ":" + $0.text + ":" + ($0.activityID ?? "") }
            state.agent.current.draft = ""; await settle(); capture("grouped-chat")
            state.agent.restart()
            try await wait("restored grouped history") { state.agent.runtimeStatuses[state.selectedSession]?.phase == .ready && !state.agent.current.messages.isEmpty }
            let restored = AgentTranscript.items(messages: state.agent.current.messages, activities: state.agent.current.activities).last?.response
            check(restored?.blocks.map { $0.kind.rawValue + ":" + $0.text + ":" + ($0.activityID ?? "") } == signature, "Reopening history preserves Thinking/text/tool order and grouping")
            await settle(); capture("restored-chat")
            let first = state.selectedSession, tab = state.workspace.activePane.activeTab?.id
            state.agent.current.attachments = [.init(url: input, projectFile: true)]
            state.agent.current.draft = "Follow-up with project context"
            state.newSession(); state.selectedSession = first
            check(state.workspace.activePane.activeTab?.id == tab && state.agent.current.draft.contains("project context"), "Switching sessions restores editor, draft and file-reference state")
            state.agent.current.attachments = []; state.agent.current.draft = "slow-fixture"; state.agent.submit()
            try await wait("streaming") { state.agent.busy && state.agent.current.messages.last?.text.contains("streaming fixture") == true }
            state.destination = "Files"
            await settle(); capture("streaming")
            check(state.agent.busy && state.selectedSession == first && state.sessionAttention == .running, "Files navigation leaves real Pi streaming and its Sessions badge active")
            state.destination = "Git"; await settle()
            check(state.agent.busy && state.selectedSession == first, "Git navigation leaves the selected Pi run active")
            state.destination = "Sessions"
            state.agent.stop()
            try await wait("stop") { !state.agent.busy }
            check(state.agent.current.notice == "Cancelled", "Stop cancels the real streamed request and clears running UI state")
            state.runtimeConfigurationVisible = true; await settle(); capture("runtime-configuration", sheet: true)
            state.runtimeConfigurationVisible = false; await settle()
            let saved = state.agent.savedReference(state.currentSession!)!
            state.closeSession(first)
            try await wait("closed session history") { state.agent.recentHistory.contains { $0.path == saved.path } }
            await settle(); capture("recent-history")
            state.agent.reopen(saved)
            await settle()
            try await wait("reopened session") { state.agent.runtimeStatuses[first]?.phase == .ready && !state.agent.current.messages.isEmpty }
            check(state.selectedSession == first && state.workspace.activePane.activeTab?.id == tab, "RECENT reopens real Pi history with original editor linkage")
            try await state.agent.deleteSavedSession(saved)
            check(!FileManager.default.fileExists(atPath: saved.path) && state.selectedSession != first, "Delete removes real saved Pi history after exit and moves Chat selection")
            await settle(); capture("deleted-session")
            try state.workspace.openFile(input, pinned: true)
            var invalid = config; invalid.runtime = .external(temporary.appendingPathComponent("missing-pi"))
            try state.agent.updateConfiguration(invalid, token: nil)
            try await wait("external launch error") { state.agent.current.error != nil }
            check(state.workspace.activeBuffer?.text == "Real grouped context\n", "Backend failure leaves the native workspace/editor usable")
            await settle(); capture("runtime-error")
        } catch { results.append("FAIL \(error.localizedDescription)") }
        state.agent.shutdown()
        if server.isRunning { server.terminate() }
        try? FileManager.default.removeItem(at: temporary)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? results.joined(separator: "\n").write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(results.joined(separator: "\n")); NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}
