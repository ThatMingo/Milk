import AppKit
import SwiftUI

/// Disposable Phase 6 UI probe. No user workspace/settings/extension configuration is mutated.
@MainActor enum SettingsVerification {
    static let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Settings-UI-"+UUID().uuidString)
    static let suite="Milk.SettingsUI."+UUID().uuidString
    static func makeState() -> ShellState {
        ShellState(persist:false,preferences:UserDefaults(suiteName:suite)!,extensionService:ExtensionService(agentDirectory:root.appendingPathComponent("agent")))
    }
    static func run(state:ShellState,window:NSWindow) async {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-phase6")
        var results:[String]=[]
        func check(_ condition:Bool,_ label:String) { results.append("\(condition ? "PASS":"FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds:300_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func capture(_ name:String) {
            guard let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name+".png"))
        }
        func editors(_ view:NSView) -> [CodeTextView] { (view as? CodeTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("agent/extensions"),withIntermediateDirectories:true)
            try Data("export default function(pi) {}".utf8).write(to:root.appendingPathComponent("agent/extensions/local-demo.ts"))
            try Data(#"{"extensions":["missing.ts"]}"#.utf8).write(to:root.appendingPathComponent("agent/settings.json"))
            let file=root.appendingPathComponent("MilkTheme.swift")
            try Data("// Milk appearance verification\nimport SwiftUI\n\nstruct WarmTheme {\n    let name = \"Milk\"\n    let version = 6\n    func welcome() -> String {\n        return name\n    }\n}\n".utf8).write(to:file)
            try state.workspace.openWorkspace(root)
            try state.workspace.openFile(file,pinned:true)
            let original=state.layout
            for element in Array(state.layout.elements) { state.change { $0.toggle(element) } }
            await settle()
            check(window.frame.width >= state.sidebarExtent+578,"Empty workspace keeps usable shell minimum")
            capture("empty-shell")
            state.change { $0=original }
            state.applyPreset(.coding)
            state.agent.current.messages=[.init(id:"u",role:"user",text:"Keep Milk warm in both appearances."),.init(id:"a",role:"assistant",text:"The shared theme now updates Settings, Chat and the open editor immediately.\n\n```swift\nlet appearance = MilkAppearance.system\n```",blocks:[.init(id:"think",index:0,kind:.thinking,text:"Inspecting the semantic palette.",streaming:false),.init(id:"text",index:1,kind:.text,text:"The shared theme now updates Settings, Chat and the open editor immediately.",streaming:false)])]
            state.agent.current.activities=[.init(id:"activity",kind:"read",detail:"MilkTheme.swift",afterMessageID:"a",output:"Read semantic palette",status:.completed)]
            state.agent.current.changes=[.init(path:"MilkTheme.swift",kind:"Edited",added:12,removed:4)]
            let session=state.selectedSession,layout=state.layout
            for appearance in [MilkAppearance.light,.dark] {
                state.settings.appearance=appearance; state.takeover=nil
                await settle()
                capture(appearance.rawValue.lowercased()+"-workspace")
                let native=window.contentView.map(editors) ?? []
                check(!native.isEmpty,"\(appearance.rawValue): native editor mounted")
                check(native.allSatisfy { $0.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (appearance == .dark ? .darkAqua:.aqua) },"\(appearance.rawValue): native editor inherits appearance")
                state.workspace.preferences.fontSize=15
                await settle()
                check(native.allSatisfy { $0.preferences.fontSize == 15 },"\(appearance.rawValue): editor preferences apply live")
                state.takeover="Settings"
                for category in ["General","Pi","Editor","Agent","Git","Extensions","Preview","Updates","Advanced"] {
                    state.settingsSelection=category; await settle(); capture(appearance.rawValue.lowercased()+"-settings-"+category.lowercased())
                }
                state.takeover="Extensions"
                for category in ["Installed","Enabled","Updates","Problems"] {
                    state.extensionsSelection=category; await settle(); capture(appearance.rawValue.lowercased()+"-extensions-"+category.lowercased())
                }
                state.takeover=nil; await settle()
                check(state.selectedSession == session && state.layout == layout,"\(appearance.rawValue): takeover restores layout/session")
            }
            state.settings.appearance = .system; await settle()
            check(NSApp.appearance == nil,"System appearance removes the override")
            capture("system-workspace")
            check(state.extensions.records.contains(where:{$0.name == "local-demo"}),"Real local extension discovery")
            check(state.extensions.problems.contains(where:{$0.contains("missing")}),"Problems reflects missing configured path")
            check(state.updates.state == .unconfigured,"No production update source is reported honestly")
        } catch { check(false,error.localizedDescription) }
        _ = await state.preview.shutdown(); state.agent.shutdown()
        NSApp.appearance=nil
        try? results.joined(separator:"\n").write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        try? FileManager.default.removeItem(at:root)
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        print(results.joined(separator:"\n"))
        DispatchQueue.main.async { NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0.05) }
    }
}
