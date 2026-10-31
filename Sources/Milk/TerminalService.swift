import AppKit
import Combine
import SwiftTerm

@MainActor final class TerminalSession: NSObject, TerminalViewDelegate {
    enum State: Equatable { case running, stopping, exited(Int32) }
    let id = UUID()
    let workspace: URL?
    let shell: String
    let view: MilkTerminalView
    var process: TerminalProcess?
    var state: State = .running
    init(workspace: URL?, shell: String, fontSize: Double) {
        self.workspace = workspace; self.shell = shell
        view = MilkTerminalView(fontSize: fontSize)
        super.init(); view.terminalDelegate = self
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { process?.resize(cols: newCols, rows: newRows) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process?.send(Data(data)) }
    func setTerminalTitle(source: TerminalView, title: String) {} // Compact stable identity, no polling.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {} // Shell owns cwd.
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {} // OSC 52 is not a user Copy gesture.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Retains the emulator and shell while its layout leaf is absent. Pi session
/// selection has no reference to this service and cannot replace its shell.
@MainActor final class TerminalService: ObservableObject {
    @Published private(set) var workspace: URL?
    @Published private(set) var session: TerminalSession?
    @Published private(set) var error: String?
    @Published private(set) var restarting = false
    private(set) var owned: [UUID: TerminalProcess] = [:]
    @Published private(set) var focusRequest=UUID()
    private var focusPending=false
    func requestFocus() { focusPending=true; focusRequest=UUID(); focusIfRequested() }
    func focusIfRequested() {
        guard focusPending, let view=session?.view, let window=view.window else { return }
        if window.makeFirstResponder(view) { focusPending=false }
    }
    private var generation = UUID()
    private var shuttingDown = false
    private var fontSize = 12.0
    let host: URL
    let shellOverride: String?
    init(host: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]), shell: String? = nil) {
        self.host = host; shellOverride = shell
    }
    var status: String? {
        guard let session else { return nil }
        switch session.state {
        case .running: return nil
        case .stopping: return "Stopping…"
        case .exited(let status):
            return status & 0x7f == 0 ? "Process exited (\((status >> 8) & 255))" : "Process exited"
        }
    }
    func setWorkspace(_ root: URL?) {
        guard root?.standardizedFileURL.path != workspace?.standardizedFileURL.path else { return }
        generation = UUID(); restarting = false; error = nil
        let previous = session
        session = nil; workspace = root
        if let previous { previous.state = .stopping; previous.process?.stop() }
    }
    func ensureStarted(fontSize: Double? = nil) {
        if let fontSize { self.fontSize = fontSize }
        guard session == nil, error == nil, !restarting, !shuttingDown else { return }
        let created = TerminalSession(workspace: workspace, shell: shellOverride ?? TerminalProcess.loginShell(), fontSize: self.fontSize)
        do {
            let view = created.view
            let dimensions = view.terminalDimensions
            let process = try TerminalProcess(workspace: workspace, shell: created.shell, host: host, cols: dimensions.cols, rows: dimensions.rows, output: { [view] data in
                // SwiftTerm's thread-safe feed coalesces rendering and applies
                // backpressure on this serial PTY read path, even while hidden.
                view.feed(byteArray: Array(data)[...])
            }, onExit: { [weak self, created] status, gone in
                guard let self else { return }
                created.state = .exited(status)
                if let id = created.process?.id { self.owned[id] = nil }
                if !gone, self.session === created { self.error = "Terminal could not confirm process cleanup." }
                self.objectWillChange.send()
            })
            created.process = process; session = created; owned[process.id] = process
        } catch { self.error = error.localizedDescription }
    }
    func restart() {
        guard !restarting, !shuttingDown else { return }
        let token = generation
        restarting = true; error = nil
        let launch: (Bool) -> Void = { [weak self] gone in
            guard let self, self.generation == token, !self.shuttingDown else { return }
            self.restarting = false
            guard gone else { self.error = "Terminal could not stop the previous shell."; return }
            self.session = nil; self.ensureStarted()
        }
        if let previous = session, let process = previous.process {
            previous.state = .stopping; objectWillChange.send(); process.stop(completion: launch)
        } else { launch(true) }
    }
    func shutdown() async -> Bool {
        await withCheckedContinuation { continuation in shutdown { continuation.resume(returning: $0) } }
    }
    /// Callback form also runs during AppKit's terminateLater negotiation.
    func shutdown(completion: @escaping (Bool) -> Void) {
        shuttingDown = true; generation = UUID()
        let processes = Array(owned.values)
        guard !processes.isEmpty else { completion(true); return }
        var pending = processes.count, allGone = true, replied = false
        func reply(_ result: Bool) { guard !replied else { return }; replied = true; completion(result) }
        // A pathological kernel wait cannot hold normal app termination forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply(false) }
        for process in processes {
            process.stop { gone in
                allGone = allGone && gone; pending -= 1
                if pending == 0 { reply(allGone) }
            }
        }
    }
}
