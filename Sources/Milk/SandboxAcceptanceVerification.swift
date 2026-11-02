import AppKit

/// Opt-in, disposable acceptance of the real app termination delegate with a pending popup.
/// No provider, personal preferences, agent executable or credential is involved.
@MainActor enum SandboxAcceptanceVerification {
    static let flags=["--verify-sandbox-quit","--verify-sandbox-window-close"]
    static var requested: Bool { CommandLine.arguments.contains { flags.contains($0) } }
    static let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Sandbox-Quit-"+UUID().uuidString)
    static let suite="Milk.SandboxQuit."+UUID().uuidString
    private static let backend=PendingSandboxVerificationBackend()
    static func makeState() -> ShellState {
        ShellState(persist:false,preferences:UserDefaults(suiteName:suite)!,backendFactory:{ backend })
    }
    static func run(state: ShellState, window: NSWindow) async {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-sandbox")
        let metadata=output.appendingPathComponent("shutdown.json")
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try Data("preserved".utf8).write(to:root.appendingPathComponent("project.txt"))
            try state.workspace.openWorkspace(root)
            state.agent.connectForDiscovery()
            func wait(_ condition: () -> Bool) async throws {
                let deadline=Date().addingTimeInterval(8)
                while !condition() {
                    guard Date() < deadline else { throw AgentError.message("Sandbox app-quit fixture did not become ready.") }
                    try await Task.sleep(nanoseconds:20_000_000)
                }
            }
            try await wait { state.agent.lifecycle.owned.values.contains { $0.phase == .running } }
            let lease=state.agent.lifecycle.owned.values.first!, grants=state.agent.lifecycle.sandboxGrants
            let initiallyEmpty=grants.grants.isEmpty
            let scope=try grants.beginOperation(in:lease.activation)
            let decision=SandboxPolicyDecision(outcome:.requireSandboxApproval,rule:.outsideProject,action:.write,path:try SandboxPathResolver().resolve(root.appendingPathComponent("outside")))
            try grants.approve(decision,access:.readWrite,lifetime:.session,operation:scope)
            backend.pending=Task { try await backend.center.request(decision,operation:scope,tool:"acceptance",command:"Synthetic pending permission",mode:.approval,timeout:30) }
            try await wait { state.agent.presentedApproval != nil }
            let request=state.agent.presentedApproval!.request
            try await wait { window.childWindows?.contains { $0.identifier?.rawValue == "milk.approval.popup" && $0.isVisible } == true }
            let panel=window.childWindows!.first { $0.identifier?.rawValue == "milk.approval.popup" }!, view=panel.contentView!
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let mode=CommandLine.arguments.contains(flags[1]) ? "window-close":"quit"
            try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(mode+"-popup.png"))
            backend.beforeShutdown={ grants.grants.isEmpty && !grants.isLive(scope) }
            backend.drained={ cancelled in
                let result:[String:Any]=["project":root.path,"initialGrantsEmpty":initiallyEmpty,
                    "popupWasVisible":true,"grantClosedBeforeDrain":backend.closedBeforeShutdown == true,
                    "staleOperationRejected":!grants.isLive(scope),
                    "pendingCancelled":cancelled,"requestClosed":!backend.center.contains(request.id)]
                do { try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:metadata,options:.atomic) }
                catch { NSLog("Sandbox acceptance metadata could not be written.") }
                UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
            }
            // Return from the verification task before AppKit begins its nested
            // termination callbacks, as the other native acceptance fixtures do.
            if mode == "window-close" { window.perform(#selector(NSWindow.performClose(_:)),with:nil,afterDelay:0.05) }
            else { NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0.05) }
        } catch { print("FAIL sandbox termination acceptance: "+error.localizedDescription); exit(1) }
    }
}

@MainActor private final class PendingSandboxVerificationBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    let center=SandboxApprovalCenter()
    var pending: Task<SandboxGrantLifetime,Error>?
    var drained: ((Bool) -> Void)?
    var beforeShutdown: (() -> Bool)?
    private(set) var closedBeforeShutdown: Bool?
    func start(workspace: URL, session: AgentSession) async throws { center.event={ [weak self] in self?.onEvent?($0) } }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws {}
    func stop() async throws {}
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws { try center.respond(approval,response:response) }
    func shutdown() {
        if closedBeforeShutdown == nil { closedBeforeShutdown=beforeShutdown?() }
        center.cancelAll()
    }
    func shutdownAndWait() async throws {
        shutdown()
        let cancelled: Bool
        if let pending { if case .failure = await pending.result { cancelled=true } else { cancelled=false } }
        else { cancelled=false }
        drained?(cancelled); drained=nil
    }
}
