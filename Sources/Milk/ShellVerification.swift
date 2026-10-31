import AppKit
import SwiftUI
import MilkLayout

@MainActor enum ShellVerification {
    static func run(state: ShellState, window: NSWindow) async {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-sessions")
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var results:[String]=[]
        func check(_ value:Bool,_ label:String) { results.append("\(value ? "PASS":"FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds:400_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func marker(_ name:String,in v:NSView) -> NSView? {
            if v.identifier?.rawValue == "milk.geometry."+name { return v }
            return v.subviews.lazy.compactMap { marker(name,in:$0) }.first
        }
        func actual(_ name:String) -> CGRect {
            guard let v=marker(name,in:window.contentView!) else { return .zero }
            return v.convert(v.bounds,to:window.contentView)
        }
        func texts(_ v:NSView) -> [String] { (v as? NSTextView).map { [$0.string] } ?? v.subviews.flatMap { texts($0) } }
        func capture(_ name:String) {
            guard let v=window.contentView,let b=v.bitmapImageRepForCachingDisplay(in:v.bounds) else { return }
            v.cacheDisplay(in:v.bounds,to:b); try? b.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name+".png"))
        }
        func close(_ a:CGFloat,_ b:CGFloat) -> Bool { abs(a-b)<1.1 }
        func baseline() async {
            state.isEditingLayout=false
            if !state.sidebarVisible { state.toggleSidebar(); await settle() }
            state.setSidebarWidth(248)
            state.layout.apply(.chat)
            window.setFrame(NSRect(x:30,y:100,width:949,height:428),display:true)
            await settle()
        }
        await baseline()
        for element in [WorkspaceElement.code,.preview,.terminal] {
            let before=window.frame.size, pane=actual("chat").size
            state.change { $0.toggle(element) }; await settle()
            check(close(window.frame.width,before.width+element.minimumWidth+1),"Show \(element.title) expands native width")
            check(close(actual("chat").width,pane.width),"Show \(element.title) preserves rendered Chat width")
            let removed=actual(element.rawValue).width
            let grown=window.frame.width
            state.change { $0.toggle(element) }; await settle()
            check(close(window.frame.width,grown-removed-1),"Hide \(element.title) retracts occupied width")
            check(close(actual("chat").width,pane.width),"Hide \(element.title) preserves rendered Chat width")
        }
        let chatID=state.layout.root!.leaf(for:.chat)!
        let previousHeight=actual("chat").height
        state.change { $0.place(.preview,at:chatID,edge:.top) }; await settle()
        check(close(actual("chat").height,previousHeight),"Vertical insertion preserves rendered Chat height")
        let beforeVertical=window.frame.height, previewHeight=actual("preview").height
        state.change { $0.toggle(.preview) }; await settle()
        check(close(window.frame.height,beforeVertical-previewHeight-1),"Vertical removal retracts occupied height")
        check(close(actual("chat").height,previousHeight),"Vertical removal preserves remaining height")
        state.applyPreset(.coding); await settle()
        let right=state.layout.root!.leaf(for:.chat)!
        state.change { $0.place(.preview,at:right,edge:.top) }; await settle()
        let nestedWidth=window.frame.width, nestedHeight=window.frame.height
        let nestedChat=actual("chat").size
        // Code shares the height: removing it permits the remaining vertical
        // subtree to keep both heights and retract the horizontal allocation.
        let codeWidth=actual("code").width
        state.change { $0.toggle(.code) }; await settle()
        check(close(window.frame.width,nestedWidth-codeWidth-1),"Nested removal retracts horizontal allocation")
        check(close(window.frame.height,nestedHeight) && close(actual("chat").height,nestedChat.height),"Nested removal retains vertical allocations")
        capture("vertical")
        state.applyPreset(.full); await settle()
        let fullChat=actual("chat").size
        state.applyPreset(.chat); await settle()
        check(close(actual("chat").width,fullChat.width) && close(window.frame.width,fullChat.width+state.sidebarExtent),"Full to Chat retracts to actual Chat allocation")
        await baseline()
        for width:CGFloat in [180,320,420,248] {
            state.setSidebarWidth(width); await settle()
            check(close(actual("sidebar").width,width),"Rendered sidebar width \(width)")
        }
        state.setSidebarWidth(5); check(state.sidebarWidth==180,"Sidebar minimum clamp")
        state.setSidebarWidth(1000); check(state.sidebarWidth==420,"Sidebar maximum clamp")
        state.setSidebarWidth(280); await settle()
        let beforeSidebar=window.frame.width, grid=actual("chat").size
        state.toggleSidebar(); await settle()
        check(close(window.frame.width,beforeSidebar-281),"Collapse retracts remembered width plus separator")
        check(actual("sidebar") == .zero && close(actual("chat").width,grid.width),"Collapsed sidebar absent, workspace size retained")
        capture("sidebar-collapsed")
        state.toggleSidebar(); await settle()
        check(close(window.frame.width,beforeSidebar) && close(actual("sidebar").width,280),"Restore expands with remembered sidebar width")
        check(close(actual("chat").width,grid.width),"Restore preserves workspace size")
        let suite="Milk.verification."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        let temporary=ShellState(persist:true,preferences:defaults)
        temporary.setSidebarWidth(333); temporary.toggleSidebar()
        let restored=ShellState(persist:true,preferences:defaults)
        check(restored.sidebarWidth==333 && !restored.sidebarVisible,"Sidebar width and visibility survive reload")
        defaults.removePersistentDomain(forName:suite)
        state.setSidebarWidth(248)
        for preset in LayoutPreset.allCases {
            state.applyPreset(preset); await settle()
            check(window.minSize == state.minimumWindowSize,"\(preset.title) dynamic native minimum")
            for e in preset.elements { let f=actual(e.rawValue); check(f.width+1 >= e.minimumWidth && f.height+1 >= e.minimumHeight,"\(preset.title) rendered \(e.title) minimum") }
            capture(preset.rawValue)
        }
        state.applyPreset(.chat); await settle()
        // Backend-independent fixtures exist only inside this explicit verification mode.
        state.sessions = [AgentSession(id:0,title:"Verification A"), AgentSession(id:1,title:"Verification B")]
        state.agent.conversations[0] = .init(messages:[.init(id:"fixture-a",role:"user",text:"Verification conversation A")])
        state.agent.conversations[1] = .init(messages:[.init(id:"fixture-b",role:"user",text:"Verification conversation B")])
        state.destination = "Sessions"
        for session in state.sessions {
            state.selectedSession=session.id; await settle()
            let content=texts(window.contentView!).joined(separator:"\n")
            check(content.contains(session.id == 0 ? "Verification conversation A":"Verification conversation B"),"Session \(session.title) changes rendered conversation")
            capture("session-\(session.id)")
        }
        state.selectedSession=0
        state.agent.current.draft="Retained verification draft"
        state.selectedSession=1; await settle(); state.selectedSession=0; await settle()
        check(texts(window.contentView!).contains("Retained verification draft"),"Returning restores rendered session draft")
        state.agent.current.draft=""
        let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Shell-"+UUID().uuidString)
        try? FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let source=fixture.appendingPathComponent("SessionStore.swift")
        try? Data("import Foundation\nactor SessionStore { }\n".utf8).write(to:source)
        try? state.workspace.openWorkspace(fixture); try? state.workspace.openFile(source,pinned:true)
        state.applyPreset(.coding); await settle()
        check(texts(window.contentView!).contains(where:{$0.contains("import Foundation") && $0.contains("actor SessionStore")}),"Code source is a native selectable document")
        state.sessions = [
            .init(id: 0, title: "Fix build errors", state: .idle),
            .init(id: 1, title: "Update workspace indexing", state: .running),
            .init(id: 2, title: "Review permissions", state: .approval),
            .init(id: 3, title: "Check provider connection", state: .error),
            .init(id: 4, title: "Completed background task", state: .unread)
        ]
        state.selectedSession = 0
        state.destination = "Sessions"; await settle(); capture("sessions")
        state.setSidebarWidth(180); await settle(); capture("sessions-minimum")
        state.setSidebarWidth(248); state.destination = "Files"; await settle(); capture("files-attention")
        check(state.sessionAttention == .error, "Sessions destination shows highest-priority alert while Files is selected")
        let selected = state.selectedSession, layoutBefore = state.layout
        for destination in ["Sessions", "Files", "Git"] {
            state.destination = destination
            for screen in ["Settings", "Extensions"] {
                state.takeover = screen; await settle()
                state.takeover = nil; await settle()
                check(state.destination == destination && state.selectedSession == selected && state.layout == layoutBefore, "\(screen) restores \(destination), Pi selection and layout")
            }
        }
        check(state.sessions.first(where: { $0.id == 1 })?.state == .running, "Sidebar destinations and takeovers retain running session state")
        state.destination = "Sessions"
        state.closeSession(0); await settle()
        check(state.selectedSession == 1, "Closing current session selects another open session")
        for id in state.sessions.map(\.id) { state.closeSession(id) }
        await settle(); capture("no-session")
        check(state.currentSession == nil && state.selectedSession == -1, "Final close leaves clean no-session Chat")
        state.newSession(); await settle()
        check(state.currentSession != nil, "New Session recovers from empty session list")
        state.isEditingLayout=true; await settle(); capture("layout-edit")
        let data=try! JSONEncoder().encode(state.layout)
        check((try? JSONDecoder().decode(WorkspaceLayout.self,from:data)) == state.layout,"Split tree ratios serialize")
        state.layout.save(name:"Verification layout")
        let saved=state.layout.saved.last!
        state.applyPreset(.chat); state.change({$0.restore(saved)},preserve:false); await settle()
        check(state.layout.root==saved.root,"Named saved layout restores tree and ratios")
        state.isEditingLayout=false
        try? results.joined(separator:"\n").write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        print(results.joined(separator:"\n")); NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}

struct ShellGeometryMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = MarkerView()
        view.identifier = NSUserInterfaceItemIdentifier("milk.geometry." + name)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.identifier=NSUserInterfaceItemIdentifier("milk.geometry."+name) }
    private final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
