import XCTest
import SwiftUI
import CryptoKit
import AppKit
import Security
import MilkExtensionKit
import MilkLayout
@testable import MilkExtensionHost

@MainActor private final class ProbeExtension: MilkExtension {
    var context: (any ExtensionContext)?
    var deactivated=false
    var serviceStopped=false
    var serviceStarts: [URL?] = []
    var throwOnActivate=false
    override func activate(context: any ExtensionContext) async throws {
        self.context=context
        func view(_ id: String) -> ExtensionViewContribution { .init(id:id,title:"oMLX",systemImage:"server.rack") { _ in AnyView(Text("Native")) } }
        try context.contributions.sidebar(view("status"))
        try context.contributions.panel(view("notes"))
        try context.contributions.settings(view("preferences"))
        try context.contributions.status(view("connection"))
        try context.contributions.command(.init(name:"omlx",summary:"Open status") { _ in try context.focusSidebar("status") })
        try context.contributions.view(at:.chatToolbar,view("toolbar"))
        try context.contributions.action(at:.fileContextMenu,.init(id:"inspect",title:"Inspect") { _ in })
        if context.capabilities.contains(.pi) {
            try context.contributions.piTool(.init(id:"probe",description:"Probe",parameters:Data(#"{"type":"object","properties":{}}"#.utf8)) { _,_ in "Observed" })
            try context.contributions.prompt(id:"prompt",text:"Native prompt")
        }
        try context.contributions.service(.init(id:"poll",workspaceScoped:true) { [weak self] workspace in
            self?.serviceStarts.append(workspace)
            do { while !Task.isCancelled { try await Task.sleep(nanoseconds:100_000_000) } }
            catch { self?.serviceStopped=true; throw error }
        })
        if throwOnActivate { throw NativeExtensionError.invalid("Deliberate activation failure") }
    }
    override func deactivate() async { deactivated=true }
}
@MainActor private final class ProbeLoader: NativeExtensionLoading {
    let keepsNativeCodeMapped: Bool
    var count=0
    var instances: [ProbeExtension] = []
    var failVersion: String?
    init(resident: Bool = false) { keepsNativeCodeMapped=resident }
    func load(_ inspection: NativePackageInspection) throws -> MilkExtension {
        count += 1; let instance=ProbeExtension(); instance.throwOnActivate=inspection.manifest.version == failVersion
        instances.append(instance); return instance
    }
}

final class NativeExtensionTests: XCTestCase {
    let fm=FileManager.default
    func temporary() throws -> URL {
        let url=fm.temporaryDirectory.appendingPathComponent("Milk-Native-"+UUID().uuidString)
        try fm.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    func manifest(version: String = "1.0.0", capabilities: [ExtensionCapability] = [.network,.pi]) -> ExtensionManifest {
        .init(id:"dev.example.native",name:"Example",version:version,principalClass:"ExamplePrincipal",executable:"Example",capabilities:capabilities)
    }
    func fixture(_ base: URL, manifest: ExtensionManifest) throws -> URL {
        let package=base.appendingPathComponent(UUID().uuidString+".milkext")
        try fm.createDirectory(at:package.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try fm.createDirectory(at:package.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        try JSONEncoder().encode(manifest).write(to:package.appendingPathComponent("Contents/Resources/manifest.json"))
        let header: [UInt8] = [0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,8,0,0,0]
        let executable=package.appendingPathComponent("Contents/MacOS/"+manifest.executable)
        try Data(header).write(to:executable); try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":manifest.id,"CFBundlePackageType":"BNDL","CFBundleExecutable":manifest.executable,"NSPrincipalClass":manifest.principalClass],format:.xml,options:0).write(to:package.appendingPathComponent("Contents/Info.plist"))
        return package
    }
    @MainActor func install(_ manager: NativeExtensionManager, url: URL) async throws {
        let review=try manager.inspect(url); try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities)
    }
    func testSemanticVersions() throws {
        XCTAssertLessThan(try ExtensionVersion("1.0.0-alpha.2"),try ExtensionVersion("1.0.0-alpha.10"))
        XCTAssertLessThan(try ExtensionVersion("1.0.0-rc.1"),try ExtensionVersion("1.0.0"))
        XCTAssertEqual(try ExtensionVersion("1.0.0+one"),try ExtensionVersion("1.0.0+two"))
        for text in ["1","1.0","01.0.0","1.0.0-01","nope","999999999999999999999.0.0"] { XCTAssertThrowsError(try ExtensionVersion(text)) }
    }
    func testPackageSchemaCompatibilityStructureAndFingerprint() throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let inspector=NativePackageInspector(), package=try fixture(base,manifest:manifest())
        let review=try inspector.inspect(package)
        let canonicalCopy=base.resolvingSymlinksInPath().appendingPathComponent("canonical-copy.milkext")
        try fm.copyItem(at:package,to:canonicalCopy)
        XCTAssertEqual(try inspector.inspect(canonicalCopy).fingerprint,review.fingerprint,"Fingerprint must survive /var vs /private/var and package relocation")
        XCTAssertEqual(review.manifest.id,"dev.example.native"); XCTAssertEqual(review.fingerprint.count,64)
        XCTAssertTrue(review.signature.contains("Unsigned")); XCTAssertEqual(review.capabilities,[.network,.pi])
        var bad=manifest(); bad.milkApi="2"
        XCTAssertThrowsError(try inspector.inspect(fixture(base,manifest:bad)))
        bad=manifest(); bad.minimumMilkVersion="99.0.0"
        XCTAssertThrowsError(try inspector.inspect(fixture(base,manifest:bad)))
        bad=manifest(); bad.id="not-a-reverse-dns-id"
        XCTAssertThrowsError(try inspector.inspect(fixture(base,manifest:bad)))
        bad=manifest(); bad.version="v1"
        XCTAssertThrowsError(try inspector.inspect(fixture(base,manifest:bad)))
        let malformed=try fixture(base,manifest:manifest()); try Data("{".utf8).write(to:malformed.appendingPathComponent("Contents/Resources/manifest.json"))
        XCTAssertThrowsError(try inspector.inspect(malformed))
        let missing=try fixture(base,manifest:manifest()); try fm.removeItem(at:missing.appendingPathComponent("Contents/MacOS/Example"))
        XCTAssertThrowsError(try inspector.inspect(missing))
        try Data("resource".utf8).write(to:package.appendingPathComponent("Contents/Resources/test"))
        XCTAssertNotEqual(try inspector.inspect(package).fingerprint,review.fingerprint)
        try fm.createSymbolicLink(at:package.appendingPathComponent("Contents/Resources/link"),withDestinationURL:base)
        XCTAssertThrowsError(try inspector.inspect(package))
    }
    @MainActor func testNoExecutionBeforeTrustOrCapabilityApprovalAndTOCTOU() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), host=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader())
        let manager=NativeExtensionManager(root:base.appendingPathComponent("owned"),loader:loader)
        let package=try fixture(base,manifest:manifest()), review=try manager.inspect(package)
        XCTAssertEqual(loader.count,0)
        do { try await manager.install(review,trusting:"wrong",granting:review.capabilities); XCTFail("Untrusted package installed") } catch {}
        do { try await manager.install(review,trusting:review.fingerprint,granting:[]); XCTFail("Missing grants accepted") } catch {}
        XCTAssertTrue(manager.records.isEmpty); XCTAssertEqual(loader.count,0)
        try Data("changed".utf8).write(to:package.appendingPathComponent("Contents/Resources/file"))
        do { try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities); XCTFail("Changed package accepted") } catch {}
        XCTAssertEqual(loader.count,0)
        try await install(host,url:package)
        XCTAssertThrowsError(try host.inspect(package),"Duplicate install ID must be rejected")
        await host.shutdown()
    }
    @MainActor func testRemovalOwnershipServicesStorageAndReenable() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader())
        _ = loader
        let root=base.appendingPathComponent("workspace"); try fm.createDirectory(at:root,withIntermediateDirectories:true); await manager.setWorkspace(root)
        try await install(manager,url:fixture(base,manifest:manifest()))
        let registry=manager.registry
        XCTAssertEqual(["Files","Sessions","Git"]+registry.sidebar.map { $0.item.title },["Files","Sessions","Git","oMLX"])
        XCTAssertEqual(registry.panels.count,1); XCTAssertEqual(registry.settings.count,1); XCTAssertEqual(registry.status.count,1); XCTAssertEqual(registry.commands.count,1)
        XCTAssertEqual(registry.views[.chatToolbar]?.count,1); XCTAssertEqual(registry.actions.count,1); XCTAssertEqual(registry.tools.count,1); XCTAssertEqual(registry.prompts.count,1)
        let data=manager.dataURL("dev.example.native").appendingPathComponent("settings.json"); try Data("keep".utf8).write(to:data)
        let code=manager.packageURL(manager.records[0]); XCTAssertTrue(fm.fileExists(atPath:code.path))
        try await manager.setEnabled("dev.example.native",false)
        XCTAssertEqual(registry.contributionCount(owner:"dev.example.native"),0); XCTAssertTrue(registry.sidebar.isEmpty); XCTAssertTrue(registry.views.values.allSatisfy(\.isEmpty)); XCTAssertTrue(registry.tools.isEmpty)
        XCTAssertEqual(try String(contentsOf:data,encoding:.utf8),"keep")
        try await manager.setEnabled("dev.example.native",true); XCTAssertEqual(registry.sidebar.count,1)
        try await manager.uninstall("dev.example.native")
        XCTAssertTrue(registry.sidebar.isEmpty); XCTAssertFalse(fm.fileExists(atPath:code.path)); XCTAssertTrue(fm.fileExists(atPath:data.path))
        try await install(manager,url:fixture(base,manifest:manifest()))
        try await manager.uninstall("dev.example.native",removeData:true)
        XCTAssertFalse(fm.fileExists(atPath:manager.dataURL("dev.example.native").path))
        await manager.shutdown()
    }
    @MainActor func testRevokedContextCapabilityGatesNamespacingCollisionsAndWorkspaceServices() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:loader)
        let a=base.appendingPathComponent("a"), b=base.appendingPathComponent("b")
        try fm.createDirectory(at:a,withIntermediateDirectories:true); try fm.createDirectory(at:b,withIntermediateDirectories:true)
        await manager.setWorkspace(a); try await install(manager,url:fixture(base,manifest:manifest(capabilities:[])))
        let probe=try XCTUnwrap(loader.instances.first), context=try XCTUnwrap(probe.context)
        XCTAssertNil(context.network); XCTAssertNil(context.processes); XCTAssertNil(context.secrets); XCTAssertNil(context.git)
        XCTAssertThrowsError(try context.storage.write(Data(),to:"../outside"))
        XCTAssertThrowsError(try context.contributions.command(.init(name:"omlx",summary:"collision") { _ in }))
        XCTAssertThrowsError(try context.contributions.command(.init(name:"help",summary:"core collision") { _ in }))
        XCTAssertThrowsError(try context.contributions.piTool(.init(id:"no",description:"No grant",parameters:Data("{}".utf8)) { _,_ in "" }))
        try context.storage.write(Data("retained".utf8),to:"preferences")
        let firstDeadline=Date().addingTimeInterval(2)
        while !probe.serviceStarts.contains(where:{ $0 == a }) && Date() < firstDeadline { try await Task.sleep(nanoseconds:5_000_000) }
        await manager.setWorkspace(b)
        let secondDeadline=Date().addingTimeInterval(2)
        while (!probe.serviceStarts.contains(where:{ $0 == b }) || !probe.serviceStopped) && Date() < secondDeadline { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertTrue(probe.serviceStarts.contains { $0 == a }); XCTAssertTrue(probe.serviceStarts.contains { $0 == b }); XCTAssertTrue(probe.serviceStopped)
        try await manager.setEnabled("dev.example.native",false)
        XCTAssertTrue(probe.deactivated)
        XCTAssertThrowsError(try context.storage.read("preferences")); XCTAssertThrowsError(try context.focusSidebar("status"))
        XCTAssertThrowsError(try context.contributions.command(.init(name:"late",summary:"Late registration") { _ in }))
        await manager.shutdown()
    }
    @MainActor func testUpdatesCapabilityDeltaRollbackAndData() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader())
        _ = loader
        try await install(manager,url:fixture(base,manifest:manifest()))
        let data=manager.dataURL("dev.example.native").appendingPathComponent("preferences"); try Data("saved".utf8).write(to:data)
        let incoming=try fixture(base,manifest:manifest(version:"1.1.0",capabilities:[.network,.pi,.shell]))
        let review=try manager.inspect(incoming,updating:"dev.example.native")
        XCTAssertEqual(manager.capabilityDelta(review),[.shell])
        do { try await manager.update("dev.example.native",with:review,trusting:review.fingerprint,granting:[.network,.pi]); XCTFail("Capability delta was not approved") } catch {}
        XCTAssertEqual(manager.records[0].manifest.version,"1.0.0"); XCTAssertEqual(manager.registry.sidebar.count,1)
        try await manager.update("dev.example.native",with:review,trusting:review.fingerprint,granting:review.capabilities)
        XCTAssertEqual(manager.records[0].manifest.version,"1.1.0"); XCTAssertEqual(manager.registry.sidebar.count,1)
        XCTAssertEqual(try String(contentsOf:data,encoding:.utf8),"saved")
        XCTAssertEqual(manager.records[0].previous?.manifest.version,"1.0.0")
        XCTAssertThrowsError(try manager.inspect(incoming,updating:"dev.example.native"))
        var wrong=manifest(version:"1.2.0"); wrong.id="dev.example.different"
        XCTAssertThrowsError(try manager.inspect(fixture(base,manifest:wrong),updating:"dev.example.native"))
        await manager.shutdown()
        let failedLoader=ProbeLoader(); failedLoader.failVersion="1.2.0"
        let restarted=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:failedLoader); await restarted.start()
        let broken=try restarted.inspect(fixture(base,manifest:manifest(version:"1.2.0")),updating:"dev.example.native")
        do { try await restarted.update("dev.example.native",with:broken,trusting:broken.fingerprint,granting:broken.capabilities); XCTFail("Activation should fail") } catch {}
        XCTAssertEqual(restarted.records[0].manifest.version,"1.1.0"); XCTAssertEqual(restarted.registry.sidebar.count,1)
        XCTAssertEqual(try String(contentsOf:data,encoding:.utf8),"saved")
        await restarted.shutdown()
    }
    @MainActor func testResidentUpdateStagesForRestartAndFailedNextLaunchRollsBack() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(resident:true), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader(resident:true))
        _ = loader
        try await install(manager,url:fixture(base,manifest:manifest()))
        let review=try manager.inspect(fixture(base,manifest:manifest(version:"1.1.0")),updating:"dev.example.native")
        try await manager.update("dev.example.native",with:review,trusting:review.fingerprint,granting:review.capabilities)
        XCTAssertTrue(manager.records[0].restartRequired); XCTAssertTrue(manager.registry.sidebar.isEmpty)
        try await manager.setEnabled("dev.example.native",true); XCTAssertTrue(manager.registry.sidebar.isEmpty)
        await manager.shutdown()
        let nextLoader=ProbeLoader(resident:true); nextLoader.failVersion="1.1.0"
        let next=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:nextLoader); await next.start()
        XCTAssertEqual(next.records[0].manifest.version,"1.0.0"); XCTAssertFalse(next.records[0].enabled); XCTAssertTrue(next.records[0].restartRequired)
        XCTAssertTrue(next.registry.sidebar.isEmpty); XCTAssertNotNil(next.records[0].problem)
        await next.shutdown()
    }
    @MainActor func testModifiedInstalledPackageNeverLoadsOnNextLaunch() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:loader)
        try await install(manager,url:fixture(base,manifest:manifest())); let path=manager.packageURL(manager.records[0])
        try Data("outside mutation".utf8).write(to:path.appendingPathComponent("Contents/Resources/changed"))
        await manager.checkIntegrity(); XCTAssertFalse(manager.records[0].enabled); XCTAssertTrue(manager.registry.sidebar.isEmpty)
        await manager.shutdown()
        let nextLoader=ProbeLoader(), next=NativeExtensionManager(root:manager.root,loader:nextLoader); await next.start()
        XCTAssertEqual(nextLoader.count,0); XCTAssertNotNil(next.records[0].problem)
        do { try await next.setEnabled("dev.example.native",true); XCTFail("Modified package loaded") } catch {}
        XCTAssertEqual(nextLoader.count,0); await next.shutdown()
    }
    @MainActor func testIntegrityWatcherRevokesModifiedActivePackage() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader())
        try await install(manager,url:fixture(base,manifest:manifest()))
        let package=manager.packageURL(manager.records[0])
        try Data("unexpected edit".utf8).write(to:package.appendingPathComponent("Contents/Resources/modified"))
        let deadline=Date().addingTimeInterval(5)
        while manager.records[0].enabled && Date() < deadline { try await Task.sleep(nanoseconds:30_000_000) }
        XCTAssertFalse(manager.records[0].enabled); XCTAssertTrue(manager.registry.sidebar.isEmpty); XCTAssertNotNil(manager.records[0].problem)
        await manager.shutdown()
    }
    @MainActor func testNamespacedSecretsUseOnlyExtensionService() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:loader)
        var identity=manifest(capabilities:[.keychain]); identity.id="dev.milk.test-"+UUID().uuidString.lowercased()
        try await install(manager,url:fixture(base,manifest:identity))
        let secrets=try XCTUnwrap(loader.instances[0].context?.secrets)
        try secrets.write("temporary-test-value",for:"isolated-test")
        XCTAssertEqual(try secrets.read("isolated-test"),"temporary-test-value")
        XCTAssertEqual(ScopedSecrets.service(identity.id),"dev.milk.extension."+identity.id)
        try await manager.setEnabled(identity.id,false)
        XCTAssertThrowsError(try secrets.read("isolated-test"))
        try await manager.uninstall(identity.id,removeData:true)
        await manager.shutdown()
    }
    @MainActor func testRemoveDataClearsSecretsWithOrWithoutMarkerAndWithoutEntries() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        for mode in ["marker", "missing-marker", "no-entries"] {
            let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent(mode),loader:loader)
            var identity=manifest(capabilities:[.keychain]); identity.id="dev.milk.test-"+UUID().uuidString.lowercased()
            defer { try? ScopedSecrets.removeAll(identity.id) }
            try await install(manager,url:fixture(base,manifest:identity))
            let secrets=try XCTUnwrap(loader.instances[0].context?.secrets)
            let query=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:ScopedSecrets.service(identity.id),kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitAll] as [String:Any]
            var matches: CFTypeRef?
            if mode != "no-entries" {
                try secrets.write("first",for:"one"); try secrets.write("second",for:"two")
                if mode == "missing-marker" { try loader.instances[0].context?.storage.remove(".milk-keychain-used") }
                try await manager.uninstall(identity.id)
                XCTAssertEqual(SecItemCopyMatching(query as CFDictionary,&matches),errSecSuccess,"Default uninstall preserves secrets")
                try await install(manager,url:fixture(base,manifest:identity))
            }
            try await manager.uninstall(identity.id,removeData:true)
            let status=SecItemCopyMatching(query as CFDictionary,&matches)
            XCTAssertEqual(status,errSecItemNotFound,mode)
            XCTAssertFalse(fm.fileExists(atPath:manager.dataURL(identity.id).path))
            XCTAssertTrue(manager.records.isEmpty)
            await manager.shutdown()
        }
    }
    @MainActor func testPublicAccentIsMilkOrangeAcrossAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, NSAppearance.currentDrawing().name] {
            let appearance=try XCTUnwrap(NSAppearance(named:name))
            appearance.performAsCurrentDrawingAppearance {
                let color=NSColor(ExtensionTheme.accent).usingColorSpace(.sRGB)!
                XCTAssertEqual(color.redComponent,1,accuracy:0.001)
                XCTAssertEqual(color.greenComponent,77.0/255.0,accuracy:0.001)
                XCTAssertEqual(color.blueComponent,0,accuracy:0.001)
                XCTAssertEqual(color.alphaComponent,1,accuracy:0.001)
            }
        }
    }
    func testLayoutUnknownPanelRoundtripAndSafeOmission() throws {
        let panel=try XCTUnwrap(WorkspaceElement(rawValue:"extension:dev.example.native/panel:notes"))
        var layout=WorkspaceLayout(); layout.toggle(panel)
        let data=try JSONEncoder().encode(layout), restored=try JSONDecoder().decode(WorkspaceLayout.self,from:data)
        XCTAssertEqual(restored.elements,[.chat,panel])
        XCTAssertEqual(restored.root?.available { !$0.isExtension }?.elements,[.chat])
        XCTAssertEqual(restored.root?.available { _ in true }?.elements,[.chat,panel])
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceElement.self,from:Data("\"chat\"".utf8)),.chat)
    }
    @MainActor func testOwnedProcessesStopOnDisableWorkspaceChangeAndQuit() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let loader=ProbeLoader(), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:loader)
        manager.authorize={ _,_,_,_ in }
        let workspace=base.appendingPathComponent("workspace"); try fm.createDirectory(at:workspace,withIntermediateDirectories:true); await manager.setWorkspace(workspace)
        try await install(manager,url:fixture(base,manifest:manifest(capabilities:[.shell])))
        let service=try XCTUnwrap(loader.instances[0].context?.processes)
        let unrelated=Process(); unrelated.executableURL=URL(fileURLWithPath:"/bin/sleep"); unrelated.arguments=["120"]; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        let child=try await service.launch(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","/bin/sleep 120 & wait"],workspaceScoped:true)
        XCTAssertEqual(manager.processes.count,1); XCTAssertEqual(kill(child.pid,0),0)
        await manager.setWorkspace(nil); XCTAssertEqual(manager.processes.count,0); XCTAssertNotEqual(kill(child.pid,0),0); XCTAssertTrue(unrelated.isRunning); XCTAssertTrue(manager.processes.cleanupProblems.isEmpty)
        _ = try await service.launch(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["120"],workspaceScoped:false)
        try await manager.setEnabled("dev.example.native",false); XCTAssertEqual(manager.processes.count,0)
        try await manager.setEnabled("dev.example.native",true)
        let next=try XCTUnwrap(loader.instances.last?.context?.processes)
        _ = try await next.launch(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["120"],workspaceScoped:false)
        await manager.shutdown(); XCTAssertEqual(manager.processes.count,0)
    }
    @MainActor func testPiBridgeRequiresHostApprovalAndDisappears() async throws {
        let base=try temporary(); defer { try? fm.removeItem(at:base) }
        let manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:ProbeLoader()), workspace=base.appendingPathComponent("workspace")
        await manager.setWorkspace(workspace); try await install(manager,url:fixture(base,manifest:manifest()))
        let tool=try XCTUnwrap(manager.registry.tools.first)
        var asked=false
        manager.authorize={ _,_,_,session in asked=true; XCTAssertEqual(session,7); throw NativeExtensionError.invalid("Denied") }
        do { _ = try await manager.invokePiTool(id:tool.id,arguments:Data("{}".utf8),workspace:workspace,session:7); XCTFail("Approval bypass") } catch {}
        XCTAssertTrue(asked)
        manager.authorize={ _,_,_,_ in }
        let result=try await manager.invokePiTool(id:tool.id,arguments:Data("{}".utf8),workspace:workspace,session:7)
        XCTAssertEqual(result,"Observed")
        XCTAssertEqual(try manager.piPrompt(manager.registry.prompts.keys.first!,workspace:workspace),"Native prompt")
        try await manager.setEnabled("dev.example.native",false)
        do { _ = try await manager.invokePiTool(id:tool.id,arguments:Data("{}".utf8),workspace:workspace,session:7); XCTFail("Disabled tool executed") } catch {}
        let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:manager.catalogURL)) as? [String:Any]
        XCTAssertTrue((catalog?["tools"] as? [Any])?.isEmpty == true); await manager.shutdown()
    }
}
