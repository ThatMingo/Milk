import SwiftUI
import MilkKit

@main struct MilkApp: App {
    @NSApplicationDelegateAdaptor(MilkAppDelegate.self) private var delegate
    @State private var model = MilkModel()
    var body: some Scene {
        Window("Milk", id: "main") {
            WorkspaceView(model: model)
                .task { delegate.model = model; await model.restore() }
                .background(WindowRestoration())
        }.defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New Pi Session") { model.newSession() }.keyboardShortcut("t", modifiers: .command).disabled(model.folder == nil)
            }
            CommandGroup(after: .appInfo) { Button("Check for Updates…") { model.updates.check() }.disabled(!model.updates.configured) }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if model.panel == "Editor" { model.editor.current?.undo.undo() }
                    else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if model.panel == "Editor" { model.editor.current?.undo.redo() }
                    else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        Settings { MilkSettingsView(updates: model.updates) }
    }
}
@MainActor final class MilkAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MilkModel?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let model else { return .terminateNow }
        terminating = true
        Task {
            guard await model.allowWorkspaceChange() else { terminating = false; sender.reply(toApplicationShouldTerminate: false); return }
            await model.shutdown(); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
private struct WindowRestoration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setFrameAutosaveName("Milk.mainWindow") }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
