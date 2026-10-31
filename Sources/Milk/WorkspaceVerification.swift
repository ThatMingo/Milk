import AppKit
import SwiftUI

@MainActor enum WorkspaceVerification {
    static func run(state:ShellState,window:NSWindow) async {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-phase2")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Verification-"+UUID().uuidString)
        var results:[String]=[]
        func check(_ value:Bool,_ name:String) { results.append("\(value ? "PASS":"FAIL") \(name)") }
        func settle() async { try? await Task.sleep(nanoseconds:500_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func editors(_ view:NSView) -> [CodeTextView] { (view as? CodeTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        func capture(_ name:String) {
            guard let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name+".png"))
        }
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("Sources"),withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let first=root.appendingPathComponent("Sources/Example.swift"), second=root.appendingPathComponent("config.json")
            try Data("import Foundation\n\nstruct Example {\n    let title = \"Milk\"\n    func greet() {\n        print(title)\n    }\n}\n".utf8).write(to:first)
            try Data("{\n  \"name\": \"Milk\",\n  \"enabled\": true\n}\n".utf8).write(to:second)
            try state.workspace.openWorkspace(root)
            state.workspace.expanded.insert(root.appendingPathComponent("Sources").path)
            state.applyPreset(.coding)
            try state.workspace.openFile(first)
            await settle()
            check(state.workspace.rows.contains(where:{$0.url == first}),"Real explorer enumerates expanded nested folder")
            var views=editors(window.contentView!)
            check(views.count == 1 && views[0].string.contains("struct Example"),"Code renders the real native editable buffer")
            guard let editor=views.first else { throw WorkspaceError.message("Native editor was not mounted") }
            check(editor.font?.fontName.contains("Mono") == true,"Editor uses the approved monospaced font")
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location:(editor.string as NSString).length,length:0))
            editor.insertText("// Local edit\n",replacementRange:editor.selectedRange())
            await settle()
            check(state.workspace.activeBuffer?.isModified == true && state.workspace.activePane.activeTab?.pinned == true,"Typing modifies and pins preview")
            editor.undoManager?.undo(); await settle()
            check(state.workspace.activeBuffer?.isModified == false,"Native undo returns to saved content")
            editor.undoManager?.redo(); await settle()
            check(state.workspace.activeBuffer?.text.contains("Local edit") == true,"Native redo restores edit")
            let single=editor.string
            let firstMatch=(single as NSString).range(of:"title")
            let secondMatch=(single as NSString).range(of:"title",options:[],range:NSRange(location:NSMaxRange(firstMatch),length:(single as NSString).length-NSMaxRange(firstMatch)))
            editor.setSelectedRanges([NSValue(range:firstMatch),NSValue(range:secondMatch)],affinity:.downstream,stillSelecting:false)
            check(editor.selectedRanges.count == 2,"Native editor supports discontiguous selections")
            editor.insertText("name",replacementRange:NSRange(location:NSNotFound,length:0)); await settle()
            check(!editor.string.contains("title") && editor.string.contains("let name"),"Typing replaces both selected occurrences")
            editor.undoManager?.undo(); await settle()
            check(editor.string == single,"Multiple selection edit undoes as one operation")
            editor.setSelectedRange(NSRange(location:0,length:0))
            try state.workspace.save(state.workspace.activeBuffer!)
            check((try String(contentsOf:first,encoding:.utf8)).contains("Local edit"),"Native edit saves to disk")
            state.workspace.findVisible=true; state.workspace.findQuery.text="title"; await settle()
            check(state.workspace.findCount == 2,"Find counts actual document matches")
            state.workspace.navigateFind(forward:true); await settle()
            check(editor.selectedRange().length == 5,"Find navigates and selects the actual match")
            state.workspace.findVisible=false
            let original=editor.string
            let originalHeight=editor.layoutManager!.usedRect(for:editor.textContainer!).height
            editor.toggleFold(onLine:2); await settle()
            editor.layoutManager?.ensureLayout(for:editor.textContainer!)
            check(editor.string == original && editor.layoutManager!.usedRect(for:editor.textContainer!).height<originalHeight,"Folding reduces layout height and preserves source")
            check(editor.folds.count == 1,"Native folding hides a brace block without modifying source")
            editor.unfoldAll()
            try state.workspace.openFile(second,pinned:true)
            state.workspace.toggleSplit(); await settle()
            try state.workspace.openFile(first,pinned:true,pane:1)
            await settle(); views=editors(window.contentView!)
            check(views.count == 2 && Set(views.map { $0.buffer.url }).count == 2,"Internal split displays two distinct real documents")
            check(views.allSatisfy { $0.enclosingScrollView!.contentView.frame.minX>=58 && $0.visibleRect.minX>=0 },"Narrow panes reserve gutter space without clipping source")
            capture("split-editor")
            state.workspace.toggleSplit(); await settle()
            try state.workspace.openFile(first,pinned:true)
            let buffer=state.workspace.activeBuffer!
            buffer.storage.append(NSAttributedString(string:"// pending\n")); state.workspace.bufferChanged(buffer)
            let external=Data("// external update\n".utf8); try external.write(to:first,options:.atomic)
            await settle(); state.workspace.checkExternalChanges()
            check(buffer.externallyChanged && buffer.text.contains("pending"),"Watcher preserves dirty buffer and flags external conflict")
            do { try state.workspace.save(buffer); check(false,"Conflict blocks silent overwrite") }
            catch { check((try Data(contentsOf:first)) == external,"Conflict blocks silent overwrite") }
            await settle(); capture("external-conflict")
            try state.workspace.reload(buffer)
            let oldCount=state.workspace.rows.count
            try Data("new".utf8).write(to:root.appendingPathComponent("watched.txt"))
            await settle(); await settle()
            check(state.workspace.rows.count>oldCount && state.workspace.rows.contains(where:{$0.name == "watched.txt"}),"FSEvents refreshes the real explorer automatically")
            try Data("// clean external\n".utf8).write(to:first,options:.atomic)
            await settle(); await settle()
            check(buffer.text == "// clean external\n" && !buffer.externallyChanged,"Clean buffer reloads automatically after external change")
            let externalFile=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Import-"+UUID().uuidString+".txt")
            defer { try? FileManager.default.removeItem(at:externalFile) }
            try Data("Finder import".utf8).write(to:externalFile)
            let provider=NSItemProvider(item:externalFile as NSURL,typeIdentifier:"public.file-url")
            _ = state.workspace.receiveDrop([provider],into:root)
            await settle()
            let copied=root.appendingPathComponent(externalFile.lastPathComponent)
            check(FileManager.default.fileExists(atPath:copied.path) && FileManager.default.fileExists(atPath:externalFile.path),"Finder-style file URL drop copies and preserves the source")
            let destination=root.appendingPathComponent("Imported")
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
            let node=FileNode(url:copied,isDirectory:false,isSymbolicLink:false,depth:0,isIgnored:false)
            _ = state.workspace.receiveDrop([state.workspace.dragProvider(node)],into:destination)
            await settle()
            check(!FileManager.default.fileExists(atPath:copied.path) && FileManager.default.fileExists(atPath:destination.appendingPathComponent(copied.lastPathComponent).path),"Milk drag provider moves files between explorer folders")
            capture("workspace")
        } catch { results.append("FAIL \(error.localizedDescription)") }
        try? results.joined(separator:"\n").write(to:output.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        print(results.joined(separator:"\n")); NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}
