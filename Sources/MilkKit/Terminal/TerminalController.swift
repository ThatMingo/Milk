import SwiftUI
import SwiftTerm
import Observation

@MainActor @Observable public final class TerminalController {
    public private(set) var running = false
    public private(set) var title = "Terminal"
    @ObservationIgnored private var terminal: LocalProcessTerminalView?
    @ObservationIgnored private var delegate: Delegate?
    public init() {}
    public func view(in folder: URL) -> LocalProcessTerminalView {
        if let terminal { return terminal }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        view.setAccessibilityElement(true); view.setAccessibilityRole(.textArea); view.setAccessibilityLabel("Integrated terminal")
        let delegate = Delegate(owner: self); self.delegate = delegate; view.processDelegate = delegate
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment; environment["TERM"] = "xterm-256color"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        view.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: folder.path)
        terminal = view; running = true; return view
    }
    public func shutdown() { terminal?.terminate(); terminal = nil; delegate = nil; running = false }
    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: TerminalController?
        init(owner: TerminalController) { self.owner = owner }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) { Task { @MainActor [weak owner] in owner?.title = title } }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { Task { @MainActor [weak owner] in owner?.running = false } }
    }
}
public struct TerminalPane: NSViewRepresentable {
    public let controller: TerminalController
    public let folder: URL
    public init(controller: TerminalController, folder: URL) { self.controller = controller; self.folder = folder }
    public func makeNSView(context: Context) -> LocalProcessTerminalView { controller.view(in: folder) }
    public func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
