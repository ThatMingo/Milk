import XCTest
import AppKit
@testable import Milk

final class WorkspaceTests: XCTestCase {
    private func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("MilkTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    @MainActor private func fixture() throws -> (WorkspaceStore,URL,UserDefaults) {
        let root=try directory(),suite="MilkTests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName:suite) }
        let persistence=WorkspacePersistence(defaults:defaults,directory:root.appendingPathComponent(".recovery"))
        let store=WorkspaceStore(persistence:persistence)
        try store.openWorkspace(root)
        return (store,root,defaults)
    }
    private func file(_ name:String,root:URL,text:String = "let value = 1\n") throws -> URL {
        let url=root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url)
        return url
    }
    @MainActor func testPreviewPinEditingCloseAndSplitSemantics() throws {
        let (store,root,_)=try fixture()
        let a=try file("a.swift",root:root),b=try file("b.swift",root:root),c=try file("c.swift",root:root)
        try store.openFile(a); let preview=store.activePane.activeTab!
        try store.openFile(b)
        XCTAssertEqual(store.activePane.tabs.count,1)
        XCTAssertEqual(store.activePane.activeTab?.path,b.path)
        XCTAssertNotEqual(store.activePane.activeTab?.id,preview.id)
        try store.openFile(b,pinned:true); try store.openFile(a)
        XCTAssertEqual(store.activePane.tabs.count,2)
        let buffer=store.activeBuffer!
        buffer.storage.append(NSAttributedString(string:"// edit")); store.bufferChanged(buffer)
        XCTAssertTrue(store.activePane.activeTab!.pinned); XCTAssertTrue(buffer.isModified)
        try store.openFile(c)
        XCTAssertEqual(store.activePane.tabs.count,3)
        let pane=store.activePane
        store.reorderTab(pane.tabs.last!.id,to:pane.tabs.first!.id,pane:pane.id)
        XCTAssertEqual(store.activePane.tabs.first?.path,c.path)
        store.toggleSplit(); try store.openFile(b,pinned:true,pane:1)
        XCTAssertEqual(store.session.panes.count,2)
        XCTAssertEqual(store.session.panes[0].activeTab?.path,c.path)
        XCTAssertEqual(store.session.panes[1].activeTab?.path,b.path)
        store.toggleSplit()
        XCTAssertEqual(store.session.panes.count,1)
        XCTAssertEqual(store.activePane.tabs.count,3)
        for tab in store.activePane.tabs { store.closeTab(tab.id,pane:store.activePane.id) }
        XCTAssertNil(store.activePane.activeTab)
    }
    @MainActor func testSafeSaveExternalChangesAndDeletion() throws {
        let (store,root,_)=try fixture(); let url=try file("source.swift",root:root)
        try store.openFile(url); let buffer=store.activeBuffer!
        buffer.storage.append(NSAttributedString(string:"// local\n")); store.bufferChanged(buffer)
        try store.save(buffer); XCTAssertFalse(buffer.isModified)
        XCTAssertTrue(try String(contentsOf:url,encoding:.utf8).contains("local"))
        buffer.storage.append(NSAttributedString(string:"// dirty\n")); store.bufferChanged(buffer)
        let external=Data("// external\n".utf8); try external.write(to:url,options:.atomic)
        store.checkExternalChanges(); XCTAssertTrue(buffer.externallyChanged)
        XCTAssertTrue(buffer.text.contains("dirty"))
        XCTAssertThrowsError(try store.save(buffer))
        XCTAssertEqual(try Data(contentsOf:url),external)
        try store.reload(buffer); XCTAssertEqual(buffer.text,"// external\n"); XCTAssertFalse(buffer.isModified)
        try Data("// clean change\n".utf8).write(to:url,options:.atomic); store.checkExternalChanges()
        XCTAssertEqual(buffer.text,"// clean change\n")
        try FileManager.default.removeItem(at:url); store.checkExternalChanges()
        XCTAssertTrue(buffer.missing); XCTAssertThrowsError(try store.save(buffer))
    }
    func testTreeLazyExpansionIgnoreRulesAndSymlinkSafety() throws {
        let root=try directory()
        _ = try file("Sources/main.swift",root:root)
        _ = try file("node_modules/package/index.js",root:root)
        _ = try file(".hidden",root:root)
        _ = try file("cache.tmp",root:root)
        _ = try file("keep.tmp",root:root)
        _ = try file("Sources/keep.tmp",root:root)
        _ = try file("Sources/ignore.log",root:root)
        _ = try file(".gitignore",root:root,text:"*.tmp\n!keep.tmp\n*.log\n")
        _ = try file("Sources/.gitignore",root:root,text:"keep.tmp\n")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("loop"),withDestinationURL:root)
        let service=FileTreeService()
        var rows=try service.scan(root:root,expanded:[],hidden:false,ignored:false)
        XCTAssertTrue(rows.contains(where:{$0.name == "Sources"})); XCTAssertFalse(rows.contains(where:{$0.name == "main.swift"}))
        XCTAssertFalse(rows.contains(where:{$0.name == "node_modules" || $0.name == ".hidden" || $0.name == "cache.tmp"}))
        XCTAssertTrue(rows.contains(where:{$0.name == "keep.tmp"}))
        rows=try service.scan(root:root,expanded:[root.appendingPathComponent("Sources").path],hidden:false,ignored:false)
        XCTAssertTrue(rows.contains(where:{$0.name == "main.swift"}))
        XCTAssertFalse(rows.contains(where:{$0.name == "ignore.log" || $0.url.path == root.appendingPathComponent("Sources/keep.tmp").path}))
        rows=try service.scan(root:root,expanded:[root.appendingPathComponent("loop").path],hidden:true,ignored:true)
        XCTAssertTrue(rows.contains(where:{$0.name == ".hidden"})); XCTAssertTrue(rows.contains(where:{$0.name == "node_modules"}))
        XCTAssertFalse(rows.contains(where:{$0.name == "index.js"}))
        XCTAssertEqual(rows.first(where:{$0.name == "loop"})?.isDirectory,false)
    }
    @MainActor func testRenameFolderRemapsOpenDirtyBuffersAndRejectsEscapes() throws {
        let (store,root,_)=try fixture(); let url=try file("Sources/a.swift",root:root)
        try store.openFile(url,pinned:true); let buffer=store.activeBuffer!
        buffer.storage.append(NSAttributedString(string:"// unsaved")); store.bufferChanged(buffer)
        store.expanded.insert(root.appendingPathComponent("Sources").path)
        try store.move(root.appendingPathComponent("Sources"),to:root.appendingPathComponent("Code"))
        let moved=root.appendingPathComponent("Code/a.swift")
        XCTAssertEqual(store.activePane.activeTab?.path,moved.path); XCTAssertTrue(buffer.isModified)
        XCTAssertEqual(buffer.url,moved); XCTAssertTrue(store.expanded.contains(root.appendingPathComponent("Code").path))
        XCTAssertThrowsError(try store.move(root.appendingPathComponent("Code"),to:root.appendingPathComponent("Code/nested")))
        XCTAssertThrowsError(try store.move(moved,to:root.deletingLastPathComponent().appendingPathComponent("escape.swift")))
        try store.save(buffer); XCTAssertTrue(try String(contentsOf:moved,encoding:.utf8).contains("unsaved"))
        let capitalized=root.appendingPathComponent("Code/A.swift")
        try store.move(moved,to:capitalized)
        XCTAssertEqual(store.activeBuffer?.url.path,capitalized.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath:capitalized.path))
    }
    @MainActor func testPersistenceRecoverySessionsSplitPositionsAndRecent() throws {
        let (store,root,defaults)=try fixture(); let a=try file("a.swift",root:root), b=try file("b.swift",root:root)
        try store.openFile(a); let buffer=store.activeBuffer!
        buffer.storage.append(NSAttributedString(string:"// recovery")); store.bufferChanged(buffer)
        store.toggleSplit(); try store.openFile(b,pinned:false)
        store.positionChanged(.init(selection:4,selectionLength:2,scrollY:125),path:b.path,pane:store.activePane.id)
        store.expanded.insert(root.appendingPathComponent("Sources").path)
        store.showHidden=true; store.showIgnored=true
        store.layoutData={ Data("layout fixture".utf8) }
        store.selectedSession=3; try store.openFile(b,pinned:true); store.selectedSession=0
        try store.persistNow()
        try Data("// external after recovery snapshot\n".utf8).write(to:a,options:.atomic)
        let restored=WorkspaceStore(persistence:WorkspacePersistence(defaults:defaults,directory:store.persistence.directory))
        restored.restoreLastWorkspace()
        XCTAssertEqual(restored.workspace?.url.path,root.path); XCTAssertEqual(restored.recent.first?.path,root.path)
        XCTAssertEqual(restored.session.panes.count,2); XCTAssertEqual(restored.session.activePane,1)
        XCTAssertEqual(restored.activePane.positions[b.path]?.scrollY,125)
        XCTAssertEqual(restored.activePane.activeTab?.pinned,false)
        XCTAssertTrue(restored.buffers[a.path]!.text.contains("recovery")); XCTAssertTrue(restored.buffers[a.path]!.isModified)
        XCTAssertTrue(restored.buffers[a.path]!.externallyChanged)
        XCTAssertEqual(restored.sessions["3"]?.panes.first?.activeTab?.path,b.path)
        XCTAssertEqual(restored.persistence.load(root)?.layout,Data("layout fixture".utf8))
        XCTAssertTrue(restored.showHidden && restored.showIgnored)
        try restored.closeWorkspace(); XCTAssertNil(restored.persistence.active); XCTAssertEqual(restored.persistence.last?.path,root.path)
    }
    @MainActor func testWorkspaceLayoutsRemainSeparateAndPreservePhase1Fallback() throws {
        let root=try directory(), first=root.appendingPathComponent("First"),second=root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        let suite="MilkLayoutPersistence."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName:suite) }
        let shell=ShellState(persist:true,preferences:defaults)
        shell.layout.apply(.coding)
        try shell.workspace.openWorkspace(first); shell.layout.apply(.full)
        try shell.workspace.persistNow()
        try shell.workspace.openWorkspace(second); shell.layout.apply(.preview)
        try shell.workspace.persistNow()
        try shell.workspace.openWorkspace(first)
        XCTAssertEqual(shell.layout.selectedName,"Full")
        try shell.workspace.openWorkspace(second)
        XCTAssertEqual(shell.layout.selectedName,"Preview")
        try shell.workspace.closeWorkspace()
        let fresh=ShellState(persist:true,preferences:defaults)
        XCTAssertNil(fresh.workspace.workspace)
        XCTAssertEqual(fresh.layout.selectedName,"Coding")
        // Clean the two test snapshots written using the app's default location.
        try? FileManager.default.removeItem(at:shell.workspace.persistence.snapshotURL(first))
        try? FileManager.default.removeItem(at:shell.workspace.persistence.snapshotURL(second))
    }
    func testFindFlagsUnicodeAndInvalidRegex() throws {
        var query=FindQuery(text:"milk")
        XCTAssertEqual(try query.matches(in:"Milk milkshake milk").count,3)
        query.wholeWord=true; XCTAssertEqual(try query.matches(in:"Milk milkshake milk").count,2)
        query.caseSensitive=true; XCTAssertEqual(try query.matches(in:"Milk milkshake milk").count,1)
        query=FindQuery(text:"m.lk",caseSensitive:false,wholeWord:true,regex:true)
        XCTAssertEqual(try query.matches(in:"🥛 Milk milkshake").first,NSRange(location:3,length:4))
        query.text="["; XCTAssertThrowsError(try query.matches(in:"text"))
    }
    func testEncodingAndDiagnostics() throws {
        let source="let milk = \"🥛\"\r\n"
        let data=Data([0xFF,0xFE])+source.data(using:.utf16LittleEndian)!
        let value=try FileTextCodec.decode(data)
        XCTAssertEqual(value.text,source); XCTAssertEqual(value.bom,Data([0xFF,0xFE]))
        XCTAssertThrowsError(try FileTextCodec.decode(Data([0,1,2])))
        let provider=JSONDiagnosticProvider(),url=URL(fileURLWithPath:"/tmp/config.json")
        XCTAssertEqual(provider.diagnostics(for:url,text:"{ broken }").first?.severity,.error)
        XCTAssertTrue(provider.diagnostics(for:url,text:"{\"valid\":true}").isEmpty)
        let pairs=EditorLanguage.bracePairs("struct X {\n let s = \"}\" // }\n}\n")
        XCTAssertEqual(pairs.count,1)
    }
}
