import XCTest
import AppKit
import SwiftUI
@testable import Milk

@MainActor private final class SandboxPopupBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    let center = SandboxApprovalCenter()
    func start(workspace: URL, session: AgentSession) async throws { center.event = { [weak self] in self?.onEvent?($0) } }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws {}
    func stop() async throws {}
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws { try center.respond(approval,response:response) }
    func shutdown() { center.cancelAll() }
    func shutdownAndWait() async throws { shutdown() }
}
final class SandboxPopupTests: XCTestCase {
    @MainActor func testActualAnchoredSandboxPopupLightDarkAndSettingsHandoff() async throws {
        _ = NSApplication.shared
        let priorAppearance = NSApp.appearance; defer { NSApp.appearance = priorAppearance }
        let suite = "Milk.SandboxPopup." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults,enabled:false)); try workspace.openWorkspace(root)
        let backend = SandboxPopupBackend(), agent = AgentService(workspace: workspace,defaults: defaults,enabled:false,makeBackend:{backend})
        agent.restore(nil); agent.current.draft = "Synthetic popup proof"; agent.submit()
        let end = Date().addingTimeInterval(3)
        while agent.lifecycle.owned.values.first?.phase != .running && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        let lease = try XCTUnwrap(agent.lifecycle.owned.values.first), operation = try agent.lifecycle.sandboxGrants.beginOperation(in:lease.activation)
        let host = NSHostingView(rootView: ComposerApprovalAnchor(agent:agent,maximumHeight:380).frame(width:620,height:80))
        let window = NSWindow(contentRect:NSRect(x:100,y:300,width:620,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; agent.shutdown() }
        let path = try SandboxPathResolver().resolve(root.appendingPathComponent("protected"))
        let decision = SandboxPolicyDecision(outcome:.requireProtectedLocationApproval,rule:.protectedLocation,action:.write,path:path)
        let result = Task { try await backend.center.request(decision,operation:operation,tool:"bash",command:"printf synthetic",mode:.approval,timeout:30) }
        while agent.presentedApproval == nil && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        let presented = try XCTUnwrap(agent.presentedApproval)
        XCTAssertEqual(presented.request.origin,.milkSandbox); XCTAssertNil(presented.request.sandboxDeadline)
        XCTAssertEqual(presented.request.options,["Deny","Sandbox Settings","Allow Once"])
        for (name, appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            NSApp.appearance = NSAppearance(named:appearance); window.appearance = nil; host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let panel = try XCTUnwrap(window.childWindows?.first { $0.identifier?.rawValue == "milk.approval.popup" })
            XCTAssertTrue(panel.isVisible); XCTAssertEqual(panel.frame.width,620,accuracy:1)
            let view = try XCTUnwrap(panel.contentView), bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/milk-phase3-popup-\(name).png"))
        }
        var settingsOpened = false; agent.onSandboxSettings = { settingsOpened = true }
        agent.respond(presented.request,session:presented.session,value:"Sandbox Settings")
        do { _ = try await result.value; XCTFail("Settings must not grant permission") } catch {}
        XCTAssertTrue(settingsOpened); XCTAssertNil(agent.presentedApproval)
        agent.lifecycle.sandboxGrants.end(operation,reason:.finished)
        let exited = await agent.shutdownAndWait(); XCTAssertTrue(exited)
    }
}
