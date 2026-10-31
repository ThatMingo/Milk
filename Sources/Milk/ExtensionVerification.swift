import AppKit
import SwiftUI
import MilkExtensionHost
import MilkLayout

/// Disposable UI validation of the separately built external example; never uses user extension storage.
@MainActor enum ExtensionVerification {
    static let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Native-UI-"+UUID().uuidString)
    static let suite="Milk.NativeUI."+UUID().uuidString
    static func makeState() -> ShellState {
        ShellState(persist:false,preferences:UserDefaults(suiteName:suite)!,extensionService:ExtensionService(agentDirectory:root.appendingPathComponent("pi-agent")),nativeExtensionManager:NativeExtensionManager(root:root.appendingPathComponent("support")))
    }
    static func run(state: ShellState, window: NSWindow) async {
        let project=URL(fileURLWithPath:FileManager.default.currentDirectoryPath), output=project.appendingPathComponent("output/verification-phase7")
        var results:[String]=[]
        let fm=FileManager.default, server=Process(), pipe=Pipe()
        func check(_ condition: Bool, _ label: String) { results.append("\(condition ? "PASS":"FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds:300_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func capture(_ name: String) {
            guard let view=window.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap); try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name+".png"))
        }
        do {
            try fm.createDirectory(at:output,withIntermediateDirectories:true)
            let workspace=root.appendingPathComponent("workspace"); try fm.createDirectory(at:workspace,withIntermediateDirectories:true)
            try state.workspace.openWorkspace(workspace)
            await state.nativeExtensions.setWorkspace(workspace)
            let package=project.appendingPathComponent("Examples/Extensions/OMLXStatusExample/build/OMLXStatusExample.milkext")
            let inspection=try state.nativeExtensions.inspect(package), id=inspection.manifest.id
            server.executableURL=URL(fileURLWithPath:"/usr/bin/python3"); server.arguments=["-u",project.appendingPathComponent("Tests/Fixtures/omlx_fixture.py").path]; server.standardOutput=pipe; server.standardError=FileHandle.nullDevice
            try server.run()
            guard let port=Int(String(decoding:pipe.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw AgentError.message("Fixture did not start") }
            let dataRoot=state.nativeExtensions.dataURL(id); try fm.createDirectory(at:dataRoot,withIntermediateDirectories:true)
            try Data("{\"endpoint\":\"http://127.0.0.1:\(port)\",\"interval\":300,\"showStatus\":true}".utf8).write(to:dataRoot.appendingPathComponent("settings.json"))
            try await state.nativeExtensions.install(inspection,trusting:inspection.fingerprint,granting:inspection.capabilities)
            _ = try await state.nativeExtensions.executeCommand("omlx",arguments:"")
            let panel=WorkspaceElement(rawValue:state.nativeExtensions.registry.panels[0].id)!
            state.change { $0=WorkspaceLayout(); $0.toggle(panel) }
            window.setFrame(NSRect(x:window.frame.minX,y:window.frame.minY,width:1250,height:800),display:true)
            await settle()
            check(state.sidebarDestinations.count == 4,"Native sidebar registered beside Files, Sessions, Git")
            check(state.nativeExtensions.registry.settings.count == 1 && state.nativeExtensions.registry.commands.count == 1,"Settings and /omlx registered")
            for appearance in [MilkAppearance.light,.dark] {
                state.settings.appearance=appearance; state.takeover=nil; await settle(); capture(appearance.rawValue.lowercased()+"-native-sidebar-panel-status")
                state.settingsSelection=state.nativeExtensions.registry.settings[0].id; state.takeover="Settings"; await settle(); capture(appearance.rawValue.lowercased()+"-extension-settings")
                state.takeover="Extensions"; state.extensionsSelection="Installed"; await settle(); capture(appearance.rawValue.lowercased()+"-extensions-details")
            }
            state.takeover=nil; state.settings.appearance = .system
            try await state.nativeExtensions.setEnabled(id,false); await settle(); capture("disabled-core-sidebar")
            check(state.destination == "Files" && state.sidebarDestinations.count == 3,"Disable selects Files and removes sidebar contribution")
            check(state.nativeExtensions.registry.contributionCount(owner:id) == 0,"Disable removes all native contributions")
            check(state.layout.elements.contains(panel) && state.renderedRoot?.elements.contains(panel) == false,"Unavailable panel omitted; persisted placement retained")
            try await state.nativeExtensions.setEnabled(id,true); await settle(); capture("reenabled-panel")
            check(state.nativeExtensions.registry.sidebar.count == 1,"Re-enable restores native contributions")
            try await state.nativeExtensions.uninstall(id)
            check(fm.fileExists(atPath:dataRoot.path),"Uninstall preserves extension data by default")
            check(state.nativeExtensions.registry.sidebar.isEmpty,"Uninstall leaves no contributions")
        } catch { check(false,error.localizedDescription) }
        if server.isRunning { server.terminate() }
        await state.nativeExtensions.shutdown(); state.agent.shutdown(); _ = await state.preview.shutdown()
        try? results.joined(separator:"\n").write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        print(results.joined(separator:"\n"))
        try? fm.removeItem(at:root); UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        NSApp.appearance=nil
        DispatchQueue.main.async { NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0.05) }
    }
}
