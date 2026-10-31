import AppKit
import SwiftUI
import MilkLayout
import SwiftTerm

/// Explicit, disposable native-app checks. No terminal commands run in normal use.
@MainActor enum TerminalVerification {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Terminal-UI-" + UUID().uuidString).resolvingSymlinksInPath()
    static func makeState() -> ShellState {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wrapper = root.appendingPathComponent("test-shell")
        try? Data("#!/bin/sh\nexport HISTFILE=/dev/null PS1='' PS2=''\nexec /bin/bash --noprofile --norc -i\n".utf8).write(to: wrapper)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return ShellState(persist: false, preferences: UserDefaults(suiteName: "Milk.TerminalVerification." + UUID().uuidString)!, terminalService: TerminalService(shell: wrapper.path))
    }
    static func run(state: ShellState, window: NSWindow) async {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-terminal")
        var results: [String] = []
        func check(_ value: Bool, _ label: String) { results.append("\(value ? "PASS" : "FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds: 350_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() {
                guard Date() < deadline else { throw AgentError.message("Timed out: " + label + " · " + (state.terminal.error ?? "")) }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            check(true, label)
        }
        func find(_ id: String, _ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find(id, $0) }.first
        }
        func frame(_ element: String) -> CGRect {
            guard let view = find("milk.geometry." + element, window.contentView!) else { return .zero }
            return view.convert(view.bounds, to: window.contentView!)
        }
        func text() -> String { state.terminal.session?.view.visibleRowsText(0..<500).joined(separator: "\n") ?? "" }
        func hasLine(_ value: String) -> Bool { state.terminal.session?.view.visibleRowsText(0..<500).contains { $0.trimmingCharacters(in: .whitespaces) == value } == true }
        func send(_ command: String) { state.terminal.session?.view.send(txt: command + "\r") }
        func capture(_ name: String) {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
            try? capture.run(); capture.waitUntilExit()
        }
        func key(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            state.terminal.session?.view.keyDown(with: event)
        }
        func drag(to edge: Placement) -> Bool {
            guard let source = find("milk.drag.terminal", window.contentView!), let target = find("milk.drag.chat", window.contentView!) else { return false }
            let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let point: NSPoint
            switch edge {
            case .left: point = NSPoint(x: 4, y: target.bounds.midY)
            case .right: point = NSPoint(x: target.bounds.maxX - 4, y: target.bounds.midY)
            case .top: point = NSPoint(x: target.bounds.midX, y: 4)
            case .bottom: point = NSPoint(x: target.bounds.midX, y: target.bounds.maxY - 4)
            case .replace: point = NSPoint(x: target.bounds.midX, y: target.bounds.midY)
            }
            let end = target.convert(point, to: nil)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
            source.mouseDown(with: event(.leftMouseDown, start))
            return true
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("// Integrated Terminal shares the workspace layout.\nlet milk = \"Native macOS\"\n".utf8).write(to: root.appendingPathComponent("Milk.swift"))
            try Data().write(to: root.appendingPathComponent("MilkCompletionTarget"))
            try state.workspace.openWorkspace(root)
            try state.workspace.openFile(root.appendingPathComponent("Milk.swift"))
            state.applyPreset(.coding); await settle()
            let baseline = window.frame.size
            state.change { $0.place(.terminal, at: $0.root!.leaf(for: .code)!, edge: .bottom) }
            await settle()
            try await wait("Panel mounts a live native PTY shell") { state.terminal.session?.process != nil }
            let session = state.terminal.session!, pid = session.process!.pid
            send("stty -echo; printf '\\nTERMINAL_READY\\n'")
            try await wait("Interactive shell accepts input") { hasLine("TERMINAL_READY") }
            send("test \"$PWD\" = '\(root.path)'; printf 'WORKSPACE_CWD_%s\\n' \"$?\"")
            try await wait("Shell starts at workspace root") { hasLine("WORKSPACE_CWD_0") }
            send("printf '\\033[31mRed \\033[32mGreen \\033[33mAmber \\033[34mBlue \\033[35mMagenta \\033[36mCyan\\033[0m\\nUnicode: č ć ž š đ · 🐄\\n'")
            try await wait("ANSI and Unicode reach the emulator") { text().contains("Unicode:") }
            let colors = session.view.terminalContentSnapshot(region: .viewport)?.rows.flatMap(\.cells).map(\.attribute.fg) ?? []
            check(Set(colors).contains(.ansi256(code: 1)) && Set(colors).contains(.ansi256(code: 6)), "ANSI color attributes survive parsing")
            check(frame("terminal").height >= 240 && window.minSize == state.minimumWindowSize, "Terminal participates in recursive minimums")
            check(window.frame.height >= baseline.height, "Vertical Terminal expands window allocation")
            state.settings.appearance = .light; await settle(); capture("terminal-light")
            let light = session.view.nativeBackgroundColor
            state.settings.appearance = .dark; await settle(); capture("terminal-dark")
            check(light != session.view.nativeBackgroundColor, "Effective appearance recolors native Terminal")
            state.settings.appearance = .system; await settle()
            check(NSApp.appearance == nil, "System appearance inherits macOS")
            window.makeFirstResponder(session.view)
            key("printf 'KEYBOARD_OK\\n'"); key("\r", code: 36)
            try await wait("Native keyboard input and Return") { hasLine("KEYBOARD_OK") }
            session.view.send(txt: "printf 'ARROW_OK\\n'")
            key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            key("\r", code: 36)
            try await wait("Native arrow keys edit shell input") { hasLine("ARROW_OK") }
            session.view.send(txt: "test -f MilkCompletionTarg")
            key("\t", code: 48); session.view.send(txt: "; printf 'TAB_STATUS_%s\\n' \"$?\"\r")
            try await wait("Tab completion uses the live shell") { hasLine("TAB_STATUS_0") }
            key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126); key("\r", code: 36)
            await settle(); check(text().components(separatedBy: "TAB_STATUS_0").count >= 3, "Up arrow recalls shell history")
            let pasteboard = NSPasteboard.general
            let savedClipboard = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
            defer {
                pasteboard.clearContents()
                let items = savedClipboard.map { data -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, value) in data { item.setData(value, forType: type) }; return item }
                pasteboard.writeObjects(items)
            }
            session.view.selectAll()
            let container = session.view.superview as! TerminalContainer
            let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            check(container.performKeyEquivalent(with: copy) && pasteboard.string(forType: .string)?.contains("Unicode:") == true, "Cmd+C copies selected terminal text")
            session.view.selectNone(); pasteboard.clearContents(); pasteboard.setString("printf 'PASTE_OK\\n'", forType: .string)
            let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            check(container.performKeyEquivalent(with: paste), "Cmd+V follows native terminal paste")
            await settle() // Native paste snapshots the clipboard asynchronously.
            key("\r", code: 36); try await wait("Pasted input executes in shell") { hasLine("PASTE_OK") }
            send("sleep 30")
            await settle(); key("\u{3}", code: 8, modifiers: .control)
            send("printf 'NATIVE_INTERRUPT_OK\\n'")
            try await wait("Native Ctrl+C interrupts foreground job") { hasLine("NATIVE_INTERRUPT_OK") }
            send("cd /; sleep 1; printf 'HIDDEN_JOB_DONE\\n'")
            state.change { $0.toggle(.terminal) }; await settle()
            check(kill(pid, 0) == 0 && state.terminal.session === session, "Hiding retains shell and emulator")
            state.newSession(); state.selectedSession = state.sessions.first!.id
            state.takeover = "Settings"; await settle(); state.takeover = nil
            try await wait("Hidden foreground command finishes normally") { hasLine("HIDDEN_JOB_DONE") }
            state.change { $0.toggle(.terminal) }; await settle()
            check(state.terminal.session === session && state.terminal.session?.process?.pid == pid, "Show, Pi sessions and Settings preserve terminal identity")
            session.view.clearDisplay(); send("pwd; printf 'CLEAR_OK\\n'")
            try await wait("Clear preserves shell and cwd") { hasLine("/") && hasLine("CLEAR_OK") }
            state.isEditingLayout = true; await settle()
            for edge in Placement.allCases {
                state.applyPreset(.coding)
                state.change { $0.place(.terminal, at: $0.root!.leaf(for: .code)!, edge: .bottom) }; await settle()
                check(drag(to: edge), "Native drag surface accepts \(edge.rawValue)"); await settle()
                let terminal = frame("terminal"), chat = frame("chat")
                switch edge {
                case .left: check(terminal.maxX <= chat.minX + 1, "Drag left repositions Terminal")
                case .right: check(terminal.minX >= chat.maxX - 1, "Drag right repositions Terminal")
                case .top: check(terminal.minY >= chat.maxY - 1, "Drag top repositions Terminal")
                case .bottom: check(terminal.maxY <= chat.minY + 1, "Drag bottom repositions Terminal")
                case .replace: check(!state.layout.elements.contains(.chat), "Drag Replace exchanges the leaf")
                }
                check(state.terminal.session === session, "\(edge.rawValue) drag keeps the live PTY")
            }
            capture("terminal-layout-edit")
            state.isEditingLayout = false
            state.applyPreset(.coding); state.change { $0.place(.terminal, at: $0.root!.leaf(for: .code)!, edge: .bottom) }; await settle()
            if let root = state.layout.root, case let .split(_, _, _, left, _) = root, case let .split(id, _, _, _, _) = left {
                let before = frame("terminal").height
                state.layout.resize(id, ratio: 0.45); await settle()
                check(abs(frame("terminal").height - before) > 5, "Divider resizing changes native Terminal frame")
            }
            let size = session.view.terminalDimensions
            send("stty size")
            try await wait("PTY follows native panel resize") { hasLine("\(size.rows) \(size.cols)") }
            state.change { $0.save(name: "Terminal below Code") }
            let encoded = try JSONEncoder().encode(state.layout)
            let restored = try JSONDecoder().decode(WorkspaceLayout.self, from: encoded)
            state.applyPreset(.chat); state.change({ $0.restore(restored.saved.last!) }, preserve: false); await settle()
            check(state.layout.root == restored.root && state.terminal.session === session, "Saved tree restores Terminal and split proportions")
            let other = root.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try state.workspace.openWorkspace(other); await settle()
            try await wait("Workspace switch terminates previous shell") { kill(pid, 0) == -1 }
            try await wait("Visible Terminal starts for new workspace") { state.terminal.session?.process != nil }
            let next = state.terminal.session!, nextPID = next.process!.pid
            send("stty -echo; printf '\\nNEW_WORKSPACE\\n'")
            try await wait("New workspace shell interactive") { hasLine("NEW_WORKSPACE") }
            window.makeFirstResponder(next.view)
            key("\u{4}", code: 2, modifiers: .control)
            try await wait("Ctrl+D exits and displays concise status") { if case .exited = next.state { return true }; return false }
            await settle(); capture("terminal-exited")
            check(kill(nextPID, 0) == -1, "Exited shell reaped")
            state.terminal.restart(); await settle()
            try await wait("Explicit Restart creates a fresh shell") { state.terminal.session?.id != next.id }
            let restartedPID = state.terminal.session!.process!.pid
            try state.workspace.closeWorkspace(); await settle()
            try await wait("Workspace close terminates owned shell") { kill(restartedPID, 0) == -1 }
            // End with an active process tree for the external real-quit probe.
            try state.workspace.openWorkspace(root); await settle()
            state.terminal.ensureStarted()
            send("stty -echo; sleep 60 & echo $! > background.pid; /bin/sh -c 'echo $$ > foreground.pid; trap \"\" HUP TERM; exec sleep 60'")
            try await wait("Quit probe foreground and background jobs ready") { FileManager.default.fileExists(atPath: root.appendingPathComponent("foreground.pid").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("background.pid").path) }
            let metadata = ["shell": String(state.terminal.session!.process!.pid), "foreground": try String(contentsOf: root.appendingPathComponent("foreground.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "background": try String(contentsOf: root.appendingPathComponent("background.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "project": root.path]
            try JSONEncoder().encode(metadata).write(to: output.appendingPathComponent("quit-owned.json"), options: .atomic)
        } catch { results.append("FAIL \(error.localizedDescription)") }
        try? results.joined(separator: "\n").write(to: output.appendingPathComponent("native-results.txt"), atomically: true, encoding: .utf8)
        print(results.joined(separator: "\n")); fflush(stdout)
        DispatchQueue.main.async {
            if CommandLine.arguments.contains("--verify-terminal-window-close") { window.perform(#selector(NSWindow.performClose(_:)), with: nil, afterDelay: 0.05) }
            else { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05) }
        }
    }
}
