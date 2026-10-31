import XCTest
import SwiftUI
import CryptoKit
import MilkExtensionKit
import MilkExtensionHost
@testable import Milk

final class NativeExtensionIntegrationTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func sourceSnapshot() throws -> [String:String] {
        var snapshot: [String:String] = [:]
        let fm=FileManager.default
        for directory in ["Sources","Packages","Examples/Extensions/OMLXStatusExample","scripts"] {
            for case let url as URL in fm.enumerator(at:project.appendingPathComponent(directory),includingPropertiesForKeys:[.isRegularFileKey])! {
                guard ["swift","json","sh","ts"].contains(url.pathExtension), !url.path.contains("/build/"), !url.path.contains("/.build/") else { continue }
                let data=try Data(contentsOf:url); snapshot[url.path]=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            }
        }
        for relative in ["Package.swift","Runtime/MilkPiIntegration.ts","Runtime/PiRuntime/runtime-manifest.json"] {
            let url=project.appendingPathComponent(relative); snapshot[url.path]=SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
        }
        return snapshot
    }
    private func build(_ destination: URL, version: String) throws {
        let process=Process(), output=Pipe()
        process.executableURL=URL(fileURLWithPath:"/bin/zsh"); process.arguments=[project.appendingPathComponent("Examples/Extensions/OMLXStatusExample/build.sh").path,destination.path]
        var env=ProcessInfo.processInfo.environment; env["MILK_EXAMPLE_VERSION"]=version; process.environment=env
        process.standardOutput=output; process.standardError=output
        try process.run(); let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentError.message("Example build failed: "+String(decoding:data,as:UTF8.self)) }
    }
    @MainActor func testRealExampleInstallDisableReenableUpdateRestartAndUninstallWithoutSourcePatching() async throws {
        _ = NSApplication.shared
        let fm=FileManager.default, base=fm.temporaryDirectory.appendingPathComponent("Milk-Real-Extension-"+UUID().uuidString)
        try fm.createDirectory(at:base,withIntermediateDirectories:true); defer { try? fm.removeItem(at:base) }
        let original=try sourceSnapshot()
        let v1=base.appendingPathComponent("v1/OMLXStatusExample.milkext"), v2=base.appendingPathComponent("v2/OMLXStatusExample.milkext")
        try build(v1,version:"1.0.0"); try build(v2,version:"1.1.0")
        let manager=NativeExtensionManager(root:base.appendingPathComponent("support")), id="dev.milk.example.omlx-status"
        // Isolate polling from any user endpoint. Credentials are never written by this test.
        try fm.createDirectory(at:manager.dataURL(id),withIntermediateDirectories:true)
        let settings=manager.dataURL(id).appendingPathComponent("settings.json")
        try Data(#"{"endpoint":"http://127.0.0.1:1","interval":300,"showStatus":false}"#.utf8).write(to:settings)
        let defaults=UserDefaults(suiteName:"Milk.Native.Shell."+UUID().uuidString)!
        let shell=ShellState(persist:false,preferences:defaults,nativeExtensionManager:manager)
        let review=try manager.inspect(v1); XCTAssertEqual(review.manifest.milkApi,"1")
        try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities)
        XCTAssertEqual(shell.sidebarDestinations.map { $0.title ?? $0.id },["Files","Sessions","Git","oMLX"])
        XCTAssertEqual(manager.registry.settings.count,1); XCTAssertEqual(manager.registry.commands.first?.item.name,"omlx"); XCTAssertEqual(manager.registry.status.count,1)
        XCTAssertEqual(manager.registry.panels.count,1); XCTAssertEqual(manager.registry.views[.chatToolbar]?.count,1)
        XCTAssertEqual(manager.registry.tools.count,1); XCTAssertEqual(manager.registry.prompts.count,1)
        let executed=try await manager.executeCommand("omlx",arguments:""); XCTAssertTrue(executed); XCTAssertTrue(shell.destination.hasPrefix("extension:"))
        let panel=try XCTUnwrap(shell.panelElements.first(where:\.isExtension)); shell.change { $0.toggle(panel) }
        XCTAssertTrue(shell.renderedRoot?.elements.contains(panel) == true)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=NSHostingView(rootView:MainWindow(state:shell)); window.contentView?.layoutSubtreeIfNeeded()
        shell.settingsSelection=manager.registry.settings[0].id
        try await manager.setEnabled(id,false)
        XCTAssertEqual(shell.destination,"Files"); XCTAssertEqual(shell.settingsSelection,"General")
        XCTAssertEqual(shell.sidebarDestinations.map(\.id),["Files","Sessions","Git"])
        XCTAssertTrue(manager.registry.commands.isEmpty); XCTAssertTrue(manager.registry.settings.isEmpty); XCTAssertTrue(manager.registry.status.isEmpty)
        XCTAssertTrue(shell.layout.elements.contains(panel)); XCTAssertFalse(shell.renderedRoot?.elements.contains(panel) == true)
        try await manager.setEnabled(id,true); XCTAssertEqual(manager.registry.sidebar.count,1); XCTAssertTrue(shell.renderedRoot?.elements.contains(panel) == true)
        let beforeUpdate=try Data(contentsOf:settings), update=try manager.inspect(v2,updating:id)
        try await manager.update(id,with:update,trusting:update.fingerprint,granting:update.capabilities)
        XCTAssertEqual(manager.records[0].manifest.version,"1.1.0"); XCTAssertTrue(manager.records[0].restartRequired)
        XCTAssertTrue(manager.registry.sidebar.isEmpty); XCTAssertEqual(try Data(contentsOf:settings),beforeUpdate)
        // A fresh process actually loads the staged 1.1.0 binary, avoiding unsafe native reload.
        let probe=Process(), output=Pipe()
        probe.executableURL=project.appendingPathComponent(".build/arm64-apple-macosx/debug/Milk")
        probe.arguments=["--verify-native-extension-start",manager.root.path]; probe.standardOutput=output; probe.standardError=output
        try probe.run(); let result=output.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus,0,String(decoding:result,as:UTF8.self))
        XCTAssertTrue(String(decoding:result,as:UTF8.self).contains("Native extension restart verified: 1.1.0"))
        // Uninstall acts on installed code only; the external author build remains intact.
        try await manager.uninstall(id)
        XCTAssertTrue(manager.registry.sidebar.isEmpty); XCTAssertFalse(fm.fileExists(atPath:manager.root.appendingPathComponent("Extensions/"+id).path)); XCTAssertTrue(fm.fileExists(atPath:settings.path))
        let reinstall=try manager.inspect(v1); try await manager.install(reinstall,trusting:reinstall.fingerprint,granting:reinstall.capabilities)
        try await manager.uninstall(id,removeData:true); XCTAssertFalse(fm.fileExists(atPath:manager.dataURL(id).path))
        XCTAssertEqual(try sourceSnapshot(),original,"Installation/removal must never patch or revert Milk source")
        XCTAssertTrue(fm.fileExists(atPath:v1.path)); await manager.shutdown()
    }
    @MainActor func testActualPiNativeBridgeApprovalAndDynamicWithdrawal() async throws {
        let fm=FileManager.default, base=fm.temporaryDirectory.appendingPathComponent("Milk-Native-Pi-"+UUID().uuidString)
        let root=base.appendingPathComponent("workspace"), agentDir=base.appendingPathComponent("agent")
        try fm.createDirectory(at:root,withIntermediateDirectories:true); try fm.createDirectory(at:agentDir,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        let package=base.appendingPathComponent("Probe.milkext"); try build(package,version:"1.0.0")
        let loader=BridgeProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:loader)
        await manager.setWorkspace(root)
        let review=try manager.inspect(package); try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities)
        let server=Process(), portPipe=Pipe(); server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-u",project.appendingPathComponent("Tests/Fixtures/omlx_fixture.py").path]; server.standardOutput=portPipe; server.standardError=FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let port=try XCTUnwrap(Int(String(decoding:portPipe.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        let runtime=PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["PI_CODING_AGENT_DIR":agentDir.path,"MILK_OMLX_TOKEN":"fixture","PATH":"/usr/bin:/bin:/usr/sbin:/sbin"])
        let backend=PiBackend(runtime:runtime,nativeExtensions:manager); defer { backend.shutdown() }
        var configuration=AgentConfiguration(); configuration.omlx.enabled=true; configuration.omlx.endpoint=URL(string:"http://127.0.0.1:\(port)")!; configuration.omlx.modelIDs=["milk-fixture"]; configuration.omlx.defaultModel="milk-fixture"
        var settled=0, failures:[String]=[], piApprovals=0
        backend.onEvent={ event in
            switch event {
            case .settled: settled += 1
            case .approval(let request): piApprovals += 1; try? backend.respond(request,value:"Allow Once",confirmed:nil,cancelled:false)
            case .failure(let message): failures.append(message)
            case .extensionProblem(let message): failures.append(message)
            default: break
            }
        }
        var hostApprovals=0
        manager.authorize={ _,_,_,session in hostApprovals += 1; XCTAssertEqual(session,0); throw AgentError.message("Denied by host policy") }
        try await backend.start(workspace:root,session:.init(id:0,title:"Native bridge"),configuration:configuration)
        func waitForSettled(_ expected: Int) async throws {
            let deadline=Date().addingTimeInterval(15)
            while settled < expected { guard Date() < deadline else { throw AgentError.message("Native Pi timeout: \(failures)") }; try await Task.sleep(nanoseconds:30_000_000) }
        }
        try await backend.send(.init(text:"native-tool-fixture denied",attachments:[])); try await waitForSettled(1)
        XCTAssertEqual(loader.instance.calls,0); XCTAssertEqual(hostApprovals,1); XCTAssertEqual(piApprovals,1)
        manager.authorize={ _,_,_,_ in hostApprovals += 1 }
        try await backend.send(.init(text:"native-tool-fixture allowed",attachments:[])); try await waitForSettled(2)
        XCTAssertEqual(loader.instance.calls,1); XCTAssertEqual(hostApprovals,2); XCTAssertEqual(piApprovals,2)
        try await manager.setEnabled(review.manifest.id,false)
        try await Task.sleep(nanoseconds:350_000_000)
        try await backend.send(.init(text:"native-tool-fixture removed",attachments:[])); try await waitForSettled(3)
        XCTAssertEqual(loader.instance.calls,1); XCTAssertEqual(hostApprovals,2); XCTAssertTrue(failures.isEmpty,failures.joined(separator:"\n"))
        try await backend.shutdownAndWait(); await manager.shutdown()
    }
    @MainActor func testExtensionApprovalsUseExistingSessionPolicyAndCancelOnShutdown() async throws {
        _ = NSApplication.shared
        let name="Milk.ExtensionApproval."+UUID().uuidString, defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let workspace=WorkspaceStore(persistence:WorkspacePersistence(defaults:defaults,enabled:false)), agent=AgentService(workspace:workspace,defaults:defaults,enabled:false)
        agent.sessions=[.init(id:0,title:"Approval")]; agent.conversations[0] = .init(permission:.approval); agent.selectedSession=0; agent.setPermission(.approval)
        let decision=Task { try await agent.authorizeExtensionAction(owner:"dev.example.native",action:"Write a file",workspace:nil,session:agent.selectedSession) }
        try await Task.sleep(nanoseconds:10_000_000)
        let approval=try XCTUnwrap(agent.presentedApproval)
        XCTAssertTrue(approval.request.title.contains("Extension approval")); XCTAssertEqual(approval.request.options,["Deny","Allow Once"])
        agent.respond(approval.request,session:approval.session,value:"Deny")
        do { try await decision.value; XCTFail("Denied action executed") } catch {}
        let pending=Task { try await agent.authorizeExtensionAction(owner:"dev.example.native",action:"Run command",workspace:nil,session:agent.selectedSession) }
        try await Task.sleep(nanoseconds:10_000_000); agent.shutdown()
        do { try await pending.value; XCTFail("Shutdown left approval alive") } catch {}
    }
}


@MainActor private final class BridgeProbe: MilkExtension {
    var calls=0
    override func activate(context: any ExtensionContext) async throws {
        try context.contributions.piTool(.init(id:"check",description:"Native test probe",parameters:Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)) { [weak self] _,_ in self?.calls += 1; return "Real native bridge result" })
        try context.contributions.piCommand(.init(name:"native-check",summary:"Bridge command") { [weak self] _ in self?.calls += 1 })
    }
}
@MainActor private final class BridgeProbeLoader: NativeExtensionLoading {
    let keepsNativeCodeMapped=false
    let instance=BridgeProbe()
    func load(_ inspection: NativePackageInspection) throws -> MilkExtension { instance }
}
