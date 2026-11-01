import AppKit
import SwiftUI
import QuartzCore
import MilkLayout
import MilkPTY
import MilkExtensionHost

@main
struct MilkApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-provider-keychain") {
            exit(ProviderCredentialVerification.run())
        }
        if let index = CommandLine.arguments.firstIndex(of: "--milk-static-server"), CommandLine.arguments.count > index + 1 {
            StaticPreviewServer.run(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--milk-terminal-host"), CommandLine.arguments.count > index + 2 {
            milk_terminal_host(CommandLine.arguments[index + 1], CommandLine.arguments[index + 2])
            return
        }
        if let index=CommandLine.arguments.firstIndex(of:"--verify-native-extension-start"), CommandLine.arguments.count > index+1 {
            let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
            Task { @MainActor in
                let manager=NativeExtensionManager(root:root)
                await manager.start()
                let valid=manager.records.count == 1 && manager.records[0].enabled && !manager.records[0].restartRequired && manager.registry.sidebar.count == 1
                if valid { print("Native extension restart verified: "+manager.records[0].manifest.version) }
                else { print("Native extension restart failed: \(manager.records) \(manager.diagnostics)") }
                await manager.shutdown(); exit(valid ? 0:1)
            }
            RunLoop.main.run(); return
        }
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--verify-agent-acceptance") {
            Task { @MainActor in exit(await AgentAcceptanceVerification.run()) }
            RunLoop.main.run(); return
        }
        let delegate = MilkAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class MilkAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = CommandLine.arguments.contains(where: { ["--verify-chat-stability", "--verify-chat-quality"].contains($0) }) ? ChatStabilityVerification.makeState() : CommandLine.arguments.contains("--verify-slash-commands") ? SlashCommandVerification.makeState() : CommandLine.arguments.contains("--verify-extensions") ? ExtensionVerification.makeState() : CommandLine.arguments.contains("--verify-terminal") ? TerminalVerification.makeState() : CommandLine.arguments.contains("--verify-settings") ? SettingsVerification.makeState() : CommandLine.arguments.contains("--verify-agent") ? AgentVerification.makeState() : ShellState()
    private(set) var window: NSWindow!
    private var terminationPending = false
    private var terminationApproved = false
    private var trafficLightOrigins: [NSWindow.ButtonType:NSPoint] = [:]
    private func alignTrafficLights() {
        let types:[NSWindow.ButtonType] = [.closeButton,.miniaturizeButton,.zoomButton]
        guard let parent=window.standardWindowButton(.closeButton)?.superview else { return }
        // Extend the native titlebar container down to the toolbar's full height.
        // Moving buttons inside the default short container can clip their hit/hover regions.
        if parent.frame.height < MilkTheme.topHeight {
            var frame=parent.frame
            let extra=MilkTheme.topHeight-frame.height
            if parent.superview?.isFlipped != true { frame.origin.y -= extra }
            frame.size.height=MilkTheme.topHeight
            parent.frame=frame
        }
        for type in types {
            guard let button=window.standardWindowButton(type),let container=button.superview else { continue }
            let origin=trafficLightOrigins[type] ?? button.frame.origin
            trafficLightOrigins[type]=origin
            let center=container.convert(NSPoint(x:0,y:window.frame.height-MilkTheme.topHeight/2),from:nil)
            button.setFrameOrigin(NSPoint(x:origin.x+9,y:center.y-button.frame.height/2))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        Task { await state.updates.automaticCheckIfNeeded(enabled:state.settings.automaticUpdates) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 675),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Milk"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(MilkTheme.canvas)
        state.settings.applyAppearance()
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") }) {
            if CommandLine.arguments.contains("--verify-dark") { state.settings.appearance = .dark }
            if CommandLine.arguments.contains("--verify-light") { state.settings.appearance = .light }
        }
        let host = NSHostingView(rootView: MainWindow(state: state))
        host.sizingOptions = []
        // A plain AppKit container prevents NSHostingView from resetting the
        // window minimum from its own unconstrained intrinsic size.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 675))
        // Round the entire full-size content surface, including both bottom corners.
        // A transparent window backing lets the continuous silhouette remain visible.
        window.isOpaque = false
        window.backgroundColor = .clear
        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        updateMinimum()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.resizeWindow = { [weak self] grid, animated in self?.updateWindow(grid:grid,animated:animated) }
        windowDidResize(Notification(name:NSWindow.didResizeNotification))
        if CommandLine.arguments.contains("--verify-chat-stability") || CommandLine.arguments.contains("--verify-chat-quality") { Task { await ChatStabilityVerification.run(state: state, window: window) } }
        if CommandLine.arguments.contains("--verify-slash-commands") { Task { await SlashCommandVerification.run(state:state,window:window) } }
        if CommandLine.arguments.contains("--verify-extensions") { Task { await ExtensionVerification.run(state:state,window:window) } }
        if CommandLine.arguments.contains("--verify-terminal") {
            Task { await TerminalVerification.run(state: state, window: window) }
        }
        if CommandLine.arguments.contains("--verify-settings") {
            Task { await SettingsVerification.run(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-agent") {
            Task { await AgentVerification.run(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-preview-quit") || CommandLine.arguments.contains("--verify-preview-window-close") {
            Task { await PreviewVerification.runQuitProbe(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-preview") {
            Task { await PreviewVerification.run(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-git") {
            Task { await GitVerification.run(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-workspace") {
            Task { await WorkspaceVerification.run(state:state,window:window) }
        }
        if CommandLine.arguments.contains("--verify-shell") {
            Task { await ShellVerification.run(state: state, window: window) }
        }
    }

    private func updateMinimum() { updateWindow(grid:nil,animated:false) }
    private func updateWindow(grid: CGSize?, animated: Bool) {
        let minimum=state.minimumWindowSize
        window.minSize=minimum
        let screen=window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var size=window.frame.size
        if let grid {
            size=CGSize(width:grid.width+state.sidebarExtent,height:grid.height+state.shellHeight)
        }
        size.width=max(minimum.width,min(screen.width,size.width))
        size.height=max(minimum.height,min(screen.height,size.height))
        var frame=window.frame
        frame.origin.y += frame.height-size.height
        frame.size=size
        frame.origin.x=max(screen.minX,min(frame.minX,screen.maxX-frame.width))
        frame.origin.y=max(screen.minY,min(frame.minY,screen.maxY-frame.height))
        guard frame != window.frame else { windowDidResize(Notification(name:NSWindow.didResizeNotification)); return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration=0.16
                context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
                window.animator().setFrame(frame,display:true)
            } completionHandler: { [weak self] in
                self?.windowDidResize(Notification(name:NSWindow.didResizeNotification))
            }
        } else { window.setFrame(frame,display:true); windowDidResize(Notification(name:NSWindow.didResizeNotification)) }
    }
    func windowDidResize(_ notification: Notification) {
        alignTrafficLights()
        state.gridSize=CGSize(width:window.frame.width-state.sidebarExtent,height:window.frame.height-state.shellHeight)
    }

    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        if terminationPending { return .terminateLater }
        let verifying = CommandLine.arguments.contains { $0.hasPrefix("--verify-") }
        if !verifying {
            guard state.workspace.resolveUnsaved(state.workspace.modifiedBuffers) else { return .terminateCancel }
            do { try state.workspace.persistNow() }
            catch { state.workspace.report(error); return .terminateCancel }
        }
        terminationPending = true
        DispatchQueue.main.async {
            var remaining = 4
            let stopped: (Bool) -> Void = { success in
                if !success { NSLog("Milk could not confirm all owned workspace processes exited during bounded shutdown.") }
                remaining -= 1
                if remaining == 0 {
                    self.terminationApproved = true
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            Task { stopped(await self.state.agent.shutdownAndWait()) }
            Task { await self.state.nativeExtensions.shutdown(); stopped(self.state.nativeExtensions.processes.cleanupProblems.isEmpty) }
            self.state.terminal.shutdown(completion: stopped)
            self.state.preview.shutdownForTermination(completion: stopped)
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if terminationApproved { return true }
        NSApp.terminate(nil) // The single main window uses the same bounded asynchronous quit path.
        return false
    }
    func applicationDidBecomeActive(_ notification:Notification) { state.workspace.refresh(); state.workspace.checkExternalChanges(); Task { await state.nativeExtensions.checkIntegrity(); state.nativeExtensions.notifyWorkspaceFilesChanged() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Milk")
        appMenu.addItem(withTitle: "About Milk", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Milk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Milk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem=NSMenuItem()
        let fileMenu=NSMenu(title:"File")
        fileMenu.addItem(withTitle:"Open Folder…",action:#selector(openFolder),keyEquivalent:"o").target=self
        fileMenu.addItem(withTitle:"New File…",action:#selector(newFile),keyEquivalent:"n").target=self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle:"Save",action:#selector(saveFile),keyEquivalent:"s").target=self
        let saveAll=fileMenu.addItem(withTitle:"Save All",action:#selector(saveAllFiles),keyEquivalent:"s")
        saveAll.target=self; saveAll.keyEquivalentModifierMask=[.command,.option]
        fileMenu.addItem(withTitle:"Close Tab",action:#selector(closeFileTab),keyEquivalent:"w").target=self
        fileMenu.addItem(withTitle:"Close Workspace",action:#selector(closeWorkspace),keyEquivalent:"").target=self
        fileItem.submenu=fileMenu; menu.addItem(fileItem)
        let agentItem = NSMenuItem()
        let agentMenu = NSMenu(title: "Agent")
        agentMenu.delegate = self
        agentMenu.addItem(withTitle: "Agents…", action: #selector(configureRuntime), keyEquivalent: "").target = self
        agentMenu.addItem(withTitle: "Restart Agent", action: #selector(restartPi), keyEquivalent: "").target = self
        agentMenu.addItem(withTitle: "Reopen Saved Session…", action: #selector(reopenSession), keyEquivalent: "").target = self
        agentItem.submenu = agentMenu; menu.addItem(agentItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo=editMenu.addItem(withTitle:"Redo",action:Selector(("redo:")),keyEquivalent:"z")
        redo.keyEquivalentModifierMask=[.command,.shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle:"Select Next Occurrence",action:#selector(CodeTextView.selectNextOccurrence(_:)),keyEquivalent:"d")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle:"Find in File…",action:#selector(findInFile),keyEquivalent:"f").target=self
        editMenu.addItem(withTitle:"Find Next",action:#selector(findNext),keyEquivalent:"g").target=self
        let previous=editMenu.addItem(withTitle:"Find Previous",action:#selector(findPrevious),keyEquivalent:"g")
        previous.target=self; previous.keyEquivalentModifierMask=[.command,.shift]
        let go=editMenu.addItem(withTitle:"Go to Line…",action:#selector(goToLine),keyEquivalent:"l")
        go.target=self; go.keyEquivalentModifierMask=[.command,.shift]
        edit.submenu = editMenu
        menu.addItem(edit)
        let layout = NSMenuItem()
        let layoutMenu = NSMenu(title: "Layout")
        for (i, preset) in LayoutPreset.allCases.enumerated() {
            let item = layoutMenu.addItem(withTitle: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: String(i + 1))
            item.target = self; item.tag = i; item.keyEquivalentModifierMask = [.command, .option]
        }
        layoutMenu.addItem(.separator())
        layoutMenu.addItem(withTitle: "Edit Layout", action: #selector(editLayout), keyEquivalent: "l").target = self
        layout.submenu = layoutMenu
        menu.addItem(layout)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }
    func application(_ application: NSApplication, open urls: [URL]) { for url in urls where url.pathExtension == "milkext" { state.installExtension(url) } }
    @objc private func showSettings() { state.takeover="Settings" }
    @objc private func checkUpdates() { state.settingsSelection="Updates"; state.takeover="Settings"; Task { await state.updates.check() } }
    @objc private func configureRuntime() {
        state.settingsSelection = "Agents"; state.takeover = "Settings"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let restart = menu.items.first(where: { $0.action == #selector(restartPi) }) else { return }
        let agent = state.agent.currentAgentDisplayName
        restart.isHidden = agent == nil
        restart.title = agent.map { "Restart \($0)" } ?? "Restart Agent"
    }
    @objc private func restartPi() { state.agent.restart() }
    @objc private func reopenSession() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.message = "Choose a saved Pi JSONL session for this project. Recent sessions are also available in the Sessions sidebar."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url, self.state.workspace.workspace != nil else { return }
            do {
                let sessions = try self.state.agent.discoverSavedSessions(directory: url.deletingLastPathComponent(), agentID: .pi)
                guard let saved = sessions.first(where: { $0.path == url.path }) else { throw AgentError.message("This is not a Pi session for the active workspace.") }
                self.state.agent.reopen(saved)
            } catch { self.state.workspace.report(error) }
        }
    }
    @objc private func openFolder() { state.workspace.chooseWorkspace() }
    @objc private func newFile() { state.workspace.newItem(folder:false) }
    @objc private func saveFile() { if let buffer=state.workspace.activeBuffer { state.workspace.saveInteractively(buffer) } }
    @objc private func saveAllFiles() { for buffer in state.workspace.modifiedBuffers { if !state.workspace.saveInteractively(buffer) { break } } }
    @objc private func closeFileTab() {
        let pane=state.workspace.activePane
        if let id=pane.selected { state.workspace.requestCloseTab(id,pane:pane.id) }
        else { window.performClose(nil) }
    }
    @objc private func closeWorkspace() { state.workspace.requestCloseWorkspace() }
    @objc private func findInFile() { if !state.layout.elements.contains(.code) { state.change { $0.toggle(.code) } }; state.workspace.findVisible=true }
    @objc private func findNext() { state.workspace.navigateFind(forward:true) }
    @objc private func findPrevious() { state.workspace.navigateFind(forward:false) }
    @objc private func goToLine() {
        guard let line=state.workspace.promptName(title:"Go to Line",initial:"1",button:"Go"),let number=Int(line),number>0 else { return }
        state.workspace.navigation = .init(paneID:state.workspace.activePane.id,line:number)
    }
    @objc private func selectPreset(_ sender: NSMenuItem) { state.applyPreset(LayoutPreset.allCases[sender.tag]) }
    @objc private func editLayout() { state.isEditingLayout.toggle() }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Milk", .applicationVersion: state.updates.currentVersion, .credits: NSAttributedString(string: "Bundled vanilla Pi, native workspace, editor, Git and Preview. Third-party notices are included in Contents/Resources/ThirdPartyNotices.")])
    }
}
