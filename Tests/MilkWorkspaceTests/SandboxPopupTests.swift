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
    @MainActor private func until(_ message: String, _ condition: () -> Bool) async throws {
        let end=Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < end else { throw AgentError.message("Popup acceptance timeout: "+message) }
            try await Task.sleep(nanoseconds:10_000_000)
        }
    }
    @MainActor func testTimeoutSuppressionExpiresAndAskHasNoCountdown() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-PopupRetry-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let activation=AgentActivation(agentID:.pi,workspace:root,sessionID:1), grants=SandboxGrantStore()
        grants.register(activation); let operation=try grants.beginOperation(in:activation)
        let decision=SandboxPolicyDecision(outcome:.requireSandboxApproval,rule:.outsideProject,action:.write,path:try SandboxPathResolver().resolve(root.appendingPathComponent("target")))
        let center=SandboxApprovalCenter(); var requests:[AgentApproval]=[]
        center.event={ if case .approval(let value)=$0 { requests.append(value) } }
        for _ in 0..<2 {
            do { _=try await center.request(decision,operation:operation,tool:"bash",command:"retry",mode:.autonomous,timeout:0.05); XCTFail("Timeout granted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable")) }
        }
        XCTAssertEqual(requests.count,1)
        try await Task.sleep(nanoseconds:15_100_000_000)
        let retry=Task { try await center.request(decision,operation:operation,tool:"bash",command:"retry",mode:.approval,timeout:0.05) }
        defer { retry.cancel(); center.cancelAll() }
        try await until("suppression expires") { requests.count == 2 }
        let request=try XCTUnwrap(requests.last); XCTAssertNil(request.sandboxDeadline)
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertTrue(center.contains(request.id),"Ask must not inherit the configured Autonomous timer")
        try center.respond(request,response:.value("Allow Once"))
        let result=try await retry.value; XCTAssertEqual(result,.once)
    }
    @MainActor func testConcurrentAnchoredRequestsStayBoundAcrossSessionsRestartAndShutdown() async throws {
        _=NSApplication.shared
        let suite="Milk.PopupAcceptance."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let workspace=WorkspaceStore(persistence:.init(defaults:defaults,enabled:false)); try workspace.openWorkspace(root)
        var backends:[SandboxPopupBackend]=[]
        let agent=AgentService(workspace:workspace,defaults:defaults,enabled:false,makeBackend:{ let value=SandboxPopupBackend(); backends.append(value); return value })
        agent.restore(nil); agent.connectForDiscovery()
        try await until("first runtime") { agent.lifecycle.owned.values.contains { $0.phase == .running } }
        let first=agent.selectedSession, a=try XCTUnwrap(backends.first)
        let activationA=try XCTUnwrap(agent.lifecycle.owned.values.first { $0.activation.sessionID == first }?.activation)
        agent.newSession(); let second=agent.selectedSession; agent.connectForDiscovery()
        try await until("second runtime") { backends.count == 2 && agent.lifecycle.owned.values.filter { $0.phase == .running }.count == 2 }
        let b=backends[1], activationB=try XCTUnwrap(agent.lifecycle.owned.values.first { $0.activation.sessionID == second }?.activation)
        let opA=try agent.lifecycle.sandboxGrants.beginOperation(in:activationA), opB=try agent.lifecycle.sandboxGrants.beginOperation(in:activationB)
        let path=try SandboxPathResolver().resolve(root.appendingPathComponent("outside"))
        let decision=SandboxPolicyDecision(outcome:.requireSandboxApproval,rule:.outsideProject,action:.write,path:path)
        var tasks:[Task<SandboxGrantLifetime,Error>]=[]
        defer { tasks.forEach { $0.cancel() }; agent.shutdown() }
        func request(_ backend: SandboxPopupBackend, _ operation: SandboxOperationScope, _ command: String, mode: ComposerPermissionMode = .approval, timeout: Double = 30) -> Task<SandboxGrantLifetime,Error> {
            let task=Task { try await backend.center.request(decision,operation:operation,tool:"bash",command:command,mode:mode,timeout:timeout) }
            tasks.append(task); return task
        }
        let one=request(a,opA,"first" )
        try await until("first background request") { agent.approvals[first]?.count == 1 }
        let two=request(a,opA,"queued")
        let three=request(b,opB,"selected")
        try await until("concurrent queue") { agent.approvals[first]?.count == 2 && agent.approvals[second]?.count == 1 }
        let firstRequest=try XCTUnwrap(agent.approvals[first]?.first)
        XCTAssertEqual(agent.presentedApproval?.session,second)
        agent.respond(firstRequest,session:second,value:"Allow Once")
        XCTAssertTrue(a.center.contains(firstRequest.id),"A response must not cross session ownership")
        agent.selectForBrowsing(first)
        XCTAssertEqual(agent.presentedApproval?.request.id,firstRequest.id)
        let host=NSHostingView(rootView:ComposerApprovalAnchor(agent:agent,maximumHeight:380).frame(width:620,height:80))
        let window=NSWindow(contentRect:NSRect(x:100,y:300,width:620,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host; window.orderFront(nil)
        let appearance=NSApp.appearance
        defer { NSApp.appearance=appearance; window.orderOut(nil); window.contentView=nil }
        for (name,value) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            NSApp.appearance=NSAppearance(named:value); host.layoutSubtreeIfNeeded()
            try await until("anchored panel") { window.childWindows?.contains { $0.identifier?.rawValue == "milk.approval.popup" && $0.isVisible } == true }
            try await Task.sleep(nanoseconds:150_000_000)
            let panel=try XCTUnwrap(window.childWindows?.first), view=try XCTUnwrap(panel.contentView)
            XCTAssertEqual(panel.frame.width,620,accuracy:1)
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/milk-phase7-popup-\(name).png"))
        }
        agent.respond(firstRequest,session:first,value:"Allow Once")
        let once=try await one.value; XCTAssertEqual(once,.once)
        let queued=try XCTUnwrap(agent.presentedApproval); XCTAssertEqual(queued.request.command,"queued")
        agent.respond(queued.request,session:first,cancelled:true)
        do { _=try await two.value; XCTFail("Deny granted") } catch {}
        agent.selectForBrowsing(second)
        let selected=try XCTUnwrap(agent.presentedApproval)
        XCTAssertEqual(selected.request.command,"selected"); XCTAssertNil(selected.request.sandboxDeadline)
        agent.respond(selected.request,session:second,value:"Allow for Session")
        let session=try await three.value; XCTAssertEqual(session,.session)
        let timed=request(b,opB,"countdown",mode:.autonomous,timeout:0.15)
        try await until("countdown") { agent.presentedApproval?.request.sandboxDeadline != nil }
        do { _=try await timed.value; XCTFail("Timeout granted") } catch { XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable")) }
        let suppressed=request(b,opB,"countdown",mode:.autonomous,timeout:0.15)
        do { _=try await suppressed.value; XCTFail("Duplicate granted") } catch { XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable")) }
        XCTAssertNil(agent.presentedApproval)
        let stale=request(b,opB,"restart pending")
        try await until("restart prompt") { agent.presentedApproval != nil }
        let staleRequest=try XCTUnwrap(agent.presentedApproval?.request)
        agent.restart()
        do { _=try await stale.value; XCTFail("Restart granted") } catch {}
        try await until("fresh runtime") { backends.count == 3 && agent.lifecycle.owned.values.contains { $0.activation.sessionID == second && $0.phase == .running } }
        agent.respond(staleRequest,session:second,value:"Allow for Session")
        XCTAssertNil(agent.presentedApproval); XCTAssertThrowsError(try agent.lifecycle.sandboxGrants.beginOperation(in:activationB))
        let fresh=try XCTUnwrap(agent.lifecycle.owned.values.first { $0.activation.sessionID == second }?.activation)
        let freshOperation=try agent.lifecycle.sandboxGrants.beginOperation(in:fresh)
        let closing=request(backends[2],freshOperation,"shutdown pending")
        try await until("shutdown prompt") { agent.presentedApproval != nil }
        let drained=await agent.shutdownAndWait(); XCTAssertTrue(drained)
        do { _=try await closing.value; XCTFail("Shutdown granted") } catch {}
        window.close()
        XCTAssertTrue(agent.approvals.isEmpty); XCTAssertTrue(agent.lifecycle.sandboxGrants.grants.isEmpty)
        // This is automated rendering and service routing, not a human click or a real app quit.
    }
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
