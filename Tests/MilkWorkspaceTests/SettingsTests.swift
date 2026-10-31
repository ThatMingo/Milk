import XCTest
import AppKit
@testable import Milk

final class SettingsTests:XCTestCase {
    private func preferences() -> (UserDefaults,String) {
        let name="Milk.Phase6.Tests."+UUID().uuidString
        return (UserDefaults(suiteName:name)!,name)
    }
    @MainActor func testNeutralDarkPalettePreservesLightAndSurfaceHierarchy() {
        func rgb(_ color: NSColor, _ mode: NSAppearance.Name) -> NSColor {
            var value = NSColor.clear
            NSAppearance(named: mode)!.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.sRGB)! }
            return value
        }
        let light: [(NSColor, UInt32)] = [
            (NSColor(MilkTheme.canvas), 0xFAF9F5), (NSColor(MilkTheme.sidebar), 0xF0EEE6),
            (NSColor(MilkTheme.surface), 0xF3F1EA), (NSColor(MilkTheme.elevatedSurface), 0xFFFFFF),
            (NSColor(MilkTheme.segment), 0xECE9E0), (NSColor(MilkTheme.selected), 0xE2DED2),
            (NSColor(MilkTheme.selectionSurface), 0xFFFFFF), (NSColor(MilkTheme.hoverSurface), 0xECE9E0),
            (MilkTheme.codeBackground, 0xFFFFFF), (MilkTheme.terminalBackground, 0xFBFAF7),
            (MilkTheme.selection, 0xE8D4BD), (MilkTheme.codeText, 0x27241F)]
        for (color, hex) in light {
            let value = rgb(color, .aqua)
            XCTAssertEqual(value.redComponent, Double((hex >> 16) & 255)/255, accuracy: 0.0001)
            XCTAssertEqual(value.greenComponent, Double((hex >> 8) & 255)/255, accuracy: 0.0001)
            XCTAssertEqual(value.blueComponent, Double(hex & 255)/255, accuracy: 0.0001)
        }
        XCTAssertEqual(rgb(NSColor(MilkTheme.canvas), .darkAqua), rgb(.windowBackgroundColor, .darkAqua))
        XCTAssertEqual(rgb(MilkTheme.codeBackground, .darkAqua), rgb(.textBackgroundColor, .darkAqua))
        XCTAssertEqual(rgb(MilkTheme.terminalBackground, .darkAqua), rgb(.textBackgroundColor, .darkAqua))
        let hover = rgb(NSColor(MilkTheme.hoverSurface), .darkAqua)
        let selected = rgb(NSColor(MilkTheme.selectionSurface), .darkAqua)
        XCTAssertGreaterThan(selected.redComponent, hover.redComponent)
        for color in [hover, selected, rgb(NSColor(MilkTheme.surface), .darkAqua)] {
            XCTAssertEqual(color.redComponent, color.blueComponent, accuracy: 0.015)
        }
        XCTAssertEqual(rgb(NSColor(MilkTheme.primaryAction), .darkAqua).redComponent, 1, accuracy: 0.0001)
    }
    @MainActor func testGlobalPersistenceRecoveryAndTargetedReset() throws {
        _ = NSApplication.shared
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name); NSApp.appearance=nil }
        let settings=SettingsService(defaults:defaults)
        XCTAssertEqual(settings.appearance,.system); XCTAssertTrue(settings.restoreWorkspace)
        settings.appearance = .dark; settings.restoreWorkspace=false; settings.previewDevice = .phone
        settings.automaticUpdates=true; settings.refreshExtensionsOnOpen=false; settings.gitSideBySide=true
        let restored=SettingsService(defaults:defaults)
        XCTAssertEqual(restored.appearance,.dark); XCTAssertFalse(restored.restoreWorkspace)
        XCTAssertTrue(restored.gitSideBySide)
        XCTAssertEqual(restored.previewDevice,.phone); XCTAssertTrue(restored.automaticUpdates); XCTAssertFalse(restored.refreshExtensionsOnOpen)
        defaults.set("invalid",forKey:"Milk.settings.appearance"); defaults.set("invalid",forKey:"Milk.settings.previewDevice")
        XCTAssertEqual(SettingsService(defaults:defaults).appearance,.system)
        XCTAssertEqual(SettingsService(defaults:defaults).previewDevice,.desktop)
        defaults.set("history",forKey:"Milk.workspace.fixture"); defaults.set("provider",forKey:AgentConfiguration.key)
        restored.resetGeneralAndPreview()
        XCTAssertEqual(defaults.string(forKey:"Milk.workspace.fixture"),"history")
        XCTAssertEqual(defaults.string(forKey:AgentConfiguration.key),"provider")
        var editor=EditorPreferences(); editor.fontSize = .infinity; editor.indentWidth = -100
        XCTAssertEqual(SettingsService.validatedEditor(editor).fontSize,12.5); XCTAssertEqual(SettingsService.validatedEditor(editor).indentWidth,1)
    }
    @MainActor func testNativeAppearanceAndEditorLiveSwitchPreservesEditingState() async throws {
        _ = NSApplication.shared
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name); NSApp.appearance=nil }
        let settings=SettingsService(defaults:defaults)
        let buffer=try FileBuffer(url:URL(fileURLWithPath:"/tmp/theme.swift"),data:Data("// warm\nlet value = \"milk\"\n".utf8))
        let scroll=CodeScrollView(buffer:buffer), window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=scroll
        scroll.editor.applyPreferences(EditorPreferences())
        scroll.editor.setSelectedRange(NSRange(location:8,length:3))
        let selection=scroll.editor.selectedRange(), baseline=buffer.baseline
        func color(_ appearance:NSAppearance.Name) -> NSColor {
            var result=NSColor.clear
            NSAppearance(named:appearance)!.performAsCurrentDrawingAppearance { result=MilkTheme.codeBackground.usingColorSpace(.sRGB)! }
            return result
        }
        XCTAssertGreaterThan(color(.aqua).redComponent,0.9); XCTAssertLessThan(color(.darkAqua).redComponent,0.2)
        for mode in [MilkAppearance.light,.dark,.system] {
            settings.appearance=mode; window.appearance=nil
            scroll.editor.applyTheme()
            try await Task.sleep(nanoseconds:180_000_000)
            XCTAssertEqual(scroll.editor.selectedRange(),selection); XCTAssertEqual(buffer.baseline,baseline); XCTAssertFalse(buffer.isModified)
            if mode == .system { XCTAssertNil(NSApp.appearance) }
            else { XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]), mode == .dark ? .darkAqua:.aqua) }
        }
        XCTAssertGreaterThan(EditorLanguage.tokens(buffer.text,fileExtension:"swift").count,1)
    }
    @MainActor func testAgentMigrationDefaultsPersistenceAndSessionIsolation() throws {
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name) }
        var config=AgentConfiguration(); config.runtime = .external(URL(fileURLWithPath:"/tmp/pi-override"))
        try config.save(defaults)
        XCTAssertEqual(AgentConfiguration.load(defaults),config)
        let workspace=WorkspaceStore(persistence:WorkspacePersistence(defaults:defaults,enabled:false))
        let agent=AgentService(workspace:workspace,defaults:defaults,enabled:false)
        agent.sessions=[.init(id:1,title:"Existing")]; agent.conversations[1] = .init(permission:.approval)
        try agent.updateDefaultPermission(.autonomous)
        XCTAssertEqual(agent.conversations[1]?.permission,.approval)
        XCTAssertEqual(AgentConfiguration.load(defaults).defaultPermission,.autonomous)
        defaults.set(Data(#"{"runtime":{"bundled":{}},"omlx":{},"oldField":true}"#.utf8),forKey:AgentConfiguration.key)
        let migrated=AgentConfiguration.load(defaults)
        XCTAssertTrue(migrated.runtime.isBundled); XCTAssertEqual(migrated.defaultPermission,.approval)
    }
    @MainActor func testEditorAndPreviewDefaultsPersistence() async throws {
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name) }
        let store=WorkspaceStore(persistence:WorkspacePersistence(defaults:defaults,enabled:true))
        store.preferences.fontSize=18; store.preferences.usesTabs=true; store.preferences.indentWidth=2; store.preferences.wordWrap=true
        let restored=WorkspaceStore(persistence:WorkspacePersistence(defaults:defaults,enabled:true))
        XCTAssertEqual(restored.preferences,store.preferences)
        let service=PreviewService(defaults:defaults,persist:false)
        service.defaultDevice = .tablet; service.setWorkspace(URL(fileURLWithPath:"/tmp/new-preview-"+UUID().uuidString))
        XCTAssertEqual(service.device,.tablet); _ = await service.shutdown()
    }
    @MainActor func testRuntimeValidationAndExplicitBundledRecovery() async throws {
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources=ProcessInfo.processInfo.environment["MILK_TEST_RUNTIME_RESOURCES"].map { URL(fileURLWithPath:$0) } ?? project.appendingPathComponent("Runtime")
        let runtime=PiRuntimeService(resources:resources)
        XCTAssertThrowsError(try runtime.locate(.external(URL(fileURLWithPath:"/tmp/missing-pi-"+UUID().uuidString))))
        let bundled=try runtime.locate(.bundled)
        XCTAssertTrue(bundled.bundled)
        let version=try await runtime.version(of:bundled.executable)
        XCTAssertEqual(version,try XCTUnwrap(bundled.manifest).version)
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name) }
        var config=AgentConfiguration(); config.runtime = .external(URL(fileURLWithPath:"/tmp/custom-pi")); try config.save(defaults)
        XCTAssertFalse(AgentConfiguration.load(defaults).runtime.isBundled)
        config.runtime = .bundled; try config.save(defaults)
        XCTAssertTrue(AgentConfiguration.load(defaults).runtime.isBundled)
    }
    func testVersionOrderingAndManifestValidation() throws {
        XCTAssertLessThan(try MilkVersion("0.6.9"),try MilkVersion("0.6.10"))
        XCTAssertLessThan(try MilkVersion("1.0.0-beta.2"),try MilkVersion("1.0.0-beta.10"))
        XCTAssertLessThan(try MilkVersion("1.0.0-rc.1"),try MilkVersion("1.0.0"))
        XCTAssertEqual(try MilkVersion("1.0+build9"),try MilkVersion("1.0.0"))
        XCTAssertThrowsError(try MilkVersion("newest")); XCTAssertThrowsError(try MilkVersion("1..0"))
        var manifest=UpdateManifest(schemaVersion:1,bundleIdentifier:"dev.milk.phase1",version:"0.7.0",channel:"stable")
        XCTAssertNoThrow(try manifest.validate(identity:"dev.milk.phase1"))
        XCTAssertThrowsError(try manifest.validate(identity:"other.app"))
        manifest.downloadURL=URL(string:"http://example.com/unsafe.zip")
        XCTAssertThrowsError(try manifest.validate(identity:"dev.milk.phase1"))
    }
    @MainActor func testUpdaterUnconfiguredCurrentAvailableMalformedAndNoInstaller() async throws {
        let (defaults,name)=preferences(); defer { defaults.removePersistentDomain(forName:name) }
        let updater=UpdateService(defaults:defaults,currentVersion:"0.6.0",identity:"dev.milk.phase1")
        XCTAssertEqual(updater.state,.unconfigured); await updater.check(); XCTAssertEqual(updater.state,.unconfigured)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:url) }
        var manifest=UpdateManifest(schemaVersion:1,bundleIdentifier:"dev.milk.phase1",version:"0.6.0",channel:"stable",releaseNotes:"Actual local fixture")
        try JSONEncoder().encode(manifest).write(to:url)
        updater.useLocalManifest(url); await updater.check(); XCTAssertEqual(updater.state,.current)
        manifest.version="0.7.0"; try JSONEncoder().encode(manifest).write(to:url)
        await updater.check(); XCTAssertEqual(updater.state,.available(manifest)); XCTAssertFalse(updater.canInstall)
        do { try await updater.install(); XCTFail("Development updates must not install") } catch { XCTAssertTrue(error.localizedDescription.contains("development build")) }
        XCTAssertEqual(UpdateService(defaults:defaults).source,url)
        try Data("not json".utf8).write(to:url); await updater.check()
        if case .failed=updater.state {} else { XCTFail("Malformed metadata must fail") }
        updater.useLocalManifest(nil); XCTAssertEqual(updater.state,.unconfigured)
    }
    @MainActor func testExtensionDiscoveryFiltersProblemsAndRequiredProtection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Extensions-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let agent=root.appendingPathComponent("agent"), ext=agent.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at:ext,withIntermediateDirectories:true)
        try Data("export default function(pi) {}".utf8).write(to:ext.appendingPathComponent("test.ts"))
        let settings=agent.appendingPathComponent("settings.json")
        try Data(#"{"unrelated":{"keep":true},"extensions":["missing.ts","-builtin:mcp"]}"#.utf8).write(to:settings)
        let service=ExtensionService(agentDirectory:agent)
        service.refresh(workspace:nil)
        let required=try XCTUnwrap(service.records.first(where:{$0.required}))
        XCTAssertThrowsError(try service.setEnabled(required,false))
        let record=try XCTUnwrap(service.records.first(where:{$0.name == "test"}))
        XCTAssertTrue(record.enabled); XCTAssertFalse(record.removable)
        try service.setEnabled(record,false)
        XCTAssertFalse(try XCTUnwrap(service.records.first(where:{$0.name == "test"})).enabled)
        XCTAssertTrue(service.pendingReload)
        XCTAssertTrue(service.problems.contains(where:{$0.contains("missing")}))
        XCTAssertFalse(try XCTUnwrap(service.records.first(where:{$0.path == "builtin:mcp"})).enabled)
        let json=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! [String:Any]
        XCTAssertEqual((json["unrelated"] as? [String:Bool])?["keep"],true)
        let disabled=try XCTUnwrap(service.records.first(where:{$0.name == "test"}))
        try service.setEnabled(disabled,true)
        XCTAssertTrue(try XCTUnwrap(service.records.first(where:{$0.name == "test"})).enabled)
        try FileManager.default.createDirectory(at:URL(fileURLWithPath:settings.path+".lock"),withIntermediateDirectories:false)
        XCTAssertThrowsError(try service.setEnabled(service.records.first(where:{$0.name == "test"})!,false))
        try FileManager.default.removeItem(at:URL(fileURLWithPath:settings.path+".lock"))
        service.reportRuntimeProblem("/trusted/test.ts: actual runtime failure")
        XCTAssertTrue(service.problems.contains(where:{$0.contains("actual runtime failure")}))
    }
    @MainActor func testCanonicalLocalPiInstallDisableUninstallPreservesSource() async throws {
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources=ProcessInfo.processInfo.environment["MILK_TEST_RUNTIME_RESOURCES"].map { URL(fileURLWithPath:$0) } ?? project.appendingPathComponent("Runtime")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Install-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let agent=root.appendingPathComponent("agent"), source=root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("extensions"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:agent,withIntermediateDirectories:true)
        let file=source.appendingPathComponent("extensions/local.ts")
        try Data("export default function(pi) {}".utf8).write(to:file)
        try Data(#"{"name":"local-fixture","version":"1.2.3","pi":{"extensions":["extensions/local.ts"]}}"#.utf8).write(to:source.appendingPathComponent("package.json"))
        let service=ExtensionService(agentDirectory:agent,runtime:PiRuntimeService(resources:resources))
        try await service.installLocalRegistration(source)
        let record=try XCTUnwrap(service.records.first(where:{$0.version == "1.2.3"}))
        XCTAssertTrue(record.enabled); XCTAssertTrue(record.removable)
        try service.setEnabled(record,false)
        XCTAssertFalse(try XCTUnwrap(service.records.first(where:{$0.version == "1.2.3"})).enabled)
        try await service.uninstall(service.records.first(where:{$0.version == "1.2.3"})!)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        XCTAssertFalse(service.records.contains(where:{$0.version == "1.2.3"}))
        let standalone=root.appendingPathComponent("standalone.ts")
        try Data("export default function(pi) { pi.registerCommand('milk-phase6-local', { description: 'local fixture', handler: async () => {} }); }".utf8).write(to:standalone)
        try await service.installLocalRegistration(standalone)
        var standaloneRecord=try XCTUnwrap(service.records.first(where:{$0.path == standalone.path}))
        let location=try PiRuntimeService(resources:resources).locate(.bundled)
        func commands() async throws -> [String] {
            let client=PiRPCClient(); defer { client.shutdown() }
            var env=ProcessInfo.processInfo.environment; env["PI_CODING_AGENT_DIR"]=agent.path; env["PI_OFFLINE"]="1"
            try client.launch(executable:location.executable,arguments:["--mode","rpc","--offline","--no-session","-e",location.integration.path],workspace:root,environment:env)
            let response=try await client.request("get_commands",timeout:15)
            let names=response["commands"].array.compactMap { $0["name"].string }
            try await client.shutdownAndWait()
            return names
        }
        let enabledCommands=try await commands(); XCTAssertTrue(enabledCommands.contains("milk-phase6-local"))
        XCTAssertNotNil(standaloneRecord.toggleUnavailable)
        XCTAssertThrowsError(try service.setEnabled(standaloneRecord,false),"Pi 1.4.0 ignores filters for direct file package sources; never claim disabled")
        XCTAssertTrue(enabledCommands.contains("milk-permission"),"Milk's required integration stays loaded")
        standaloneRecord=try XCTUnwrap(service.records.first(where:{$0.path == standalone.path}))
        try await service.uninstall(standaloneRecord)
        XCTAssertTrue(FileManager.default.fileExists(atPath:standalone.path))
        let removedCommands=try await commands(); XCTAssertFalse(removedCommands.contains("milk-phase6-local"))

    }
}
