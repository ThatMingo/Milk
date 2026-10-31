import XCTest
import AppKit
import SwiftTerm
import MilkLayout
import Darwin
@testable import Milk

final class TerminalTests: XCTestCase {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/Milk")
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Terminal-Test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor private func fixture() throws -> (TerminalService, URL) {
        _ = NSApplication.shared
        let root = try directory()
        let wrapper = root.appendingPathComponent("test-shell")
        try Data("#!/bin/sh\nexport HISTFILE=/dev/null PS1='' PS2=''\nexec /bin/bash --noprofile --norc -i\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let service = TerminalService(host: executable, shell: wrapper.path)
        service.setWorkspace(root); service.ensureStarted()
        addTeardownBlock { _ = await service.shutdown() }
        return (service, root)
    }
    @MainActor private func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            if Date() >= deadline { XCTFail("Timed out: " + label); throw AgentError.message(label) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor private func line(_ service: TerminalService, _ text: String) -> Bool {
        service.session?.view.visibleRowsText(0..<500).contains { $0.trimmingCharacters(in: .whitespaces) == text } == true
    }
    @MainActor private func command(_ service: TerminalService, _ text: String) { service.session?.process?.send(Data((text + "\r").utf8)) }
    @MainActor private func ready(_ service: TerminalService) async throws {
        command(service, "stty -echo; printf '\\nMILK_READY\\n'")
        try await wait("interactive shell ready") { self.line(service, "MILK_READY") }
    }
    func testLoginShellAndEnvironment() {
        let shell = TerminalProcess.loginShell(environment: ["SHELL": "/missing-shell"])
        XCTAssertTrue(shell.hasPrefix("/")); XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell { XCTAssertEqual(shell, String(cString: path)) }
        let root = URL(fileURLWithPath: "/tmp")
        let environment = TerminalProcess.environment(shell: shell, directory: root)
        XCTAssertEqual(environment["PWD"], root.path); XCTAssertEqual(environment["SHELL"], shell)
        XCTAssertEqual(environment["TERM"], "xterm-256color"); XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertNotNil(environment["PATH"])
    }
    @MainActor func testPTYCwdInputUnicodeANSIResizeInterruptAndExit() async throws {
        let (service, root) = try fixture(); try await ready(service)
        let session = try XCTUnwrap(service.session), process = try XCTUnwrap(session.process)
        try await wait("new controlling session") { getsid(process.pid) == process.pid }
        XCTAssertEqual(getpgid(process.pid), process.pid)
        command(service, "test \"$PWD\" = '\(root.path)'; printf 'CWD_STATUS_%s\\n' \"$?\""); try await wait("workspace cwd") { self.line(service, "CWD_STATUS_0") }
        command(service, "printf '\\033[31mANSI_č_🐄\\033[0m\\n'")
        try await wait("ANSI parsed with Unicode") { self.line(service, "ANSI_č_🐄") }
        session.view.resize(cols: 93, rows: 31)
        try await wait("resize delegate") { process.lastSize.cols == 93 && process.lastSize.rows == 31 }
        command(service, "stty size"); try await wait("kernel PTY resized") { self.line(service, "31 93") }
        command(service, "sleep 30; printf 'AFTER_INTERRUPT\\n'")
        try await Task.sleep(nanoseconds: 150_000_000)
        process.send(Data([3]))
        command(service, "printf 'CTRL_C_OK\\n'")
        try await wait("Ctrl+C returns interactive prompt") { self.line(service, "CTRL_C_OK") }
        command(service, "exit 7")
        try await wait("natural shell exit") { session.state == .exited(7 << 8) }
        XCTAssertEqual(service.status, "Process exited (7)"); XCTAssertTrue(service.session === session)
        service.ensureStarted(); XCTAssertTrue(service.session === session) // No automatic restart loop.
        XCTAssertEqual(kill(process.pid, 0), -1)
        service.restart(); try await wait("explicit fresh shell") { service.session?.id != session.id }
        XCTAssertEqual(service.session?.process?.startupDirectory, root)
    }
    @MainActor func testHideSessionsTakeoverClearAndWorkspaceSwitch() async throws {
        let (service, root) = try fixture(); try await ready(service)
        let state = ShellState(persist: false, terminalService: service)
        defer { state.agent.shutdown() }
        try state.workspace.openWorkspace(root)
        let session = try XCTUnwrap(service.session), pid = try XCTUnwrap(session.process).pid
        command(service, "cd /; printf 'BUFFER_PRESERVED\\n'")
        try await wait("output") { self.line(service, "BUFFER_PRESERVED") }
        state.change { $0.toggle(.terminal) }; state.change { $0.toggle(.terminal) }
        state.newSession(); state.selectedSession = state.sessions.first!.id; state.takeover = "Settings"; state.takeover = nil
        service.ensureStarted()
        XCTAssertTrue(service.session === session); XCTAssertEqual(service.session?.process?.pid, pid)
        XCTAssertTrue(line(service, "BUFFER_PRESERVED")); XCTAssertEqual(kill(pid, 0), 0)
        session.view.clearDisplay(); command(service, "pwd; printf 'AFTER_CLEAR\\n'")
        try await wait("clear preserves cwd and shell") { self.line(service, "/") && self.line(service, "AFTER_CLEAR") }
        XCTAssertEqual(service.session?.process?.pid, pid)
        let other = try directory(); try state.workspace.openWorkspace(other)
        try await wait("switch cleans old shell") { kill(pid, 0) == -1 }
        service.ensureStarted(); let next = try XCTUnwrap(service.session?.process)
        XCTAssertEqual(next.workspace?.path, other.path); XCTAssertEqual(next.startupDirectory.path, other.path)
        try state.workspace.closeWorkspace()
        try await wait("close cleans shell") { kill(next.pid, 0) == -1 }
        XCTAssertNil(service.workspace)
        service.ensureStarted(); try await ready(service)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        command(service, "test \"$PWD\" = '\(home)'; printf 'HOME_STATUS_%s\\n' \"$?\"")
        try await wait("no-workspace terminal starts at home") { self.line(service, "HOME_STATUS_0") }
    }
    @MainActor func testSessionCleanupIncludesSeparateForegroundAndBackgroundGroups() async throws {
        let (service, root) = try fixture(); try await ready(service)
        let session = try XCTUnwrap(service.session), process = try XCTUnwrap(session.process)
        let foreground = root.appendingPathComponent("foreground.pid"), background = root.appendingPathComponent("background.pid")
        command(service, "sleep 60 & echo $! > '\(background.path)'; /bin/sh -c 'echo $$ > \"\(foreground.path)\"; trap \"\" HUP TERM; exec sleep 60'")
        try await wait("both jobs launched") { FileManager.default.fileExists(atPath: foreground.path) && FileManager.default.fileExists(atPath: background.path) }
        let fg = try XCTUnwrap(Int32(String(contentsOf: foreground, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let bg = try XCTUnwrap(Int32(String(contentsOf: background, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getsid(fg), process.pid); XCTAssertEqual(getsid(bg), process.pid)
        XCTAssertNotEqual(getpgid(fg), process.pid); XCTAssertNotEqual(getpgid(bg), process.pid)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["60"]; try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let result = await withCheckedContinuation { continuation in service.shutdown { continuation.resume(returning: $0) } }
        XCTAssertTrue(result)
        try await wait("all owned processes gone") { kill(process.pid, 0) == -1 && kill(fg, 0) == -1 && kill(bg, 0) == -1 }
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertTrue(service.owned.isEmpty)
    }
    @MainActor func testInteractiveFullScreenProgramReturnsToSameShell() async throws {
        let (service, root) = try fixture(); try await ready(service)
        let session = try XCTUnwrap(service.session), process = try XCTUnwrap(session.process)
        let file = root.appendingPathComponent("interactive.txt")
        try Data("Milk interactive full-screen terminal\n".utf8).write(to: file)
        command(service, "vi -u NONE -i NONE -n interactive.txt")
        try await wait("vi enters alternate screen") { session.view.terminalContentSnapshot(region: .viewport)?.inputState.isAlternateBuffer == true }
        try await wait("vi paints file contents") { session.view.visibleRowsText(0..<500).joined().contains("Milk interactive") }
        process.send(Data("\u{1B}:q!\r".utf8))
        try await wait("vi returns normal buffer") { session.view.terminalContentSnapshot(region: .viewport)?.inputState.isAlternateBuffer == false }
        command(service, "printf 'AFTER_VI\\n'")
        try await wait("shell usable after full-screen application") { self.line(service, "AFTER_VI") }
        XCTAssertEqual(session.process?.pid, process.pid)
    }
    @MainActor func testNativeRendererSelectionPaletteAndBoundedScrollback() throws {
        _ = NSApplication.shared
        let view = MilkTerminalView(fontSize: 13)
        view.feed(text: "\u{1B}[31mRED\u{1B}[0m\r\nUnicode č 🐄\r\n")
        XCTAssertTrue(view.visibleRowsText(0..<10).contains("RED"))
        let colored = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport)?.rows.first?.cells.first)
        XCTAssertEqual(colored.attribute.fg, .ansi256(code: 1))
        view.selectAll(); XCTAssertTrue(view.getSelection()?.contains("Unicode č 🐄") == true)
        XCTAssertEqual(MilkTerminalView.palette(dark: false).count, 16)
        XCTAssertEqual(Set(MilkTerminalView.palette(dark: false)).count, 16)
        XCTAssertNotEqual(MilkTerminalView.palette(dark: false), MilkTerminalView.palette(dark: true))
        XCTAssertEqual(MilkTerminalView.scrollbackLines, 10_000)
        let before = view.terminalDimensions
        view.clearDisplay(); XCTAssertEqual(view.terminalDimensions, before)
        view.feed(text: String(repeating: "bounded\r\n", count: MilkTerminalView.scrollbackLines + 100))
        let history = view.getBufferAsData(kind: .normal)
        XCTAssertLessThanOrEqual(history.filter { $0 == 10 }.count, MilkTerminalView.scrollbackLines + view.terminalDimensions.rows)
    }
}
