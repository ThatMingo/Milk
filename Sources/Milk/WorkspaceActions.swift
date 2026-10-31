import AppKit
import UniformTypeIdentifiers

@MainActor extension WorkspaceStore {
    func report(_ error:Error) {
        let alert=NSAlert(); alert.messageText="Workspace"; alert.informativeText=error.localizedDescription
        alert.alertStyle = .warning; alert.addButton(withTitle:"OK"); alert.runModal()
    }
    func attempt(_ work:() throws -> Void) { do { try work() } catch { report(error) } }
    func chooseWorkspace() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false
        panel.prompt="Open Workspace"; panel.directoryURL=workspace?.url
        if panel.runModal() == .OK, let url=panel.url { switchWorkspace(url) }
    }
    func switchWorkspace(_ url:URL) {
        if workspace?.url == url.standardizedFileURL { return }
        guard resolveUnsaved(modifiedBuffers) else { return }
        attempt { try openWorkspace(url) }
    }
    func requestCloseWorkspace() {
        guard resolveUnsaved(modifiedBuffers) else { return }
        attempt { try closeWorkspace() }
    }
    /// Called only at user boundaries that could discard buffers. Cancel leaves everything intact.
    func resolveUnsaved(_ buffers:[FileBuffer]) -> Bool {
        let dirty=buffers.filter(\.isModified)
        guard !dirty.isEmpty else { return true }
        let alert=NSAlert(); alert.messageText="Save changes before continuing?"
        alert.informativeText=dirty.map { $0.url.lastPathComponent }.joined(separator:", ")
        alert.addButton(withTitle:"Save All"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for buffer in dirty { if !saveInteractively(buffer) { return false } }
            return true
        case .alertThirdButtonReturn:
            // Actual removal happens only after the boundary succeeds. Clear the dirty
            // state here so obsolete recoveries cannot resurrect discarded changes.
            for buffer in dirty {
                if let data=try? Data(contentsOf:buffer.url), (try? buffer.reload(data)) != nil { continue }
                buffer.baseline=buffer.encoded ?? Data()
            }
            objectWillChange.send(); return true
        default: return false
        }
    }
    @discardableResult func saveInteractively(_ buffer:FileBuffer) -> Bool {
        do { try save(buffer); return true }
        catch WorkspaceError.conflict {
            buffer.externallyChanged=true; objectWillChange.send()
            return resolveConflict(buffer)
        } catch { report(error); return false }
    }
    @discardableResult func resolveConflict(_ buffer:FileBuffer) -> Bool {
        let alert=NSAlert(); alert.messageText=buffer.missing ? "File removed from disk":"File changed on disk"
        alert.informativeText="Your edits to \(buffer.url.lastPathComponent) are preserved. Reloading discards your local edits. Saving a copy keeps both versions."
        alert.addButton(withTitle:"Keep Editing"); alert.addButton(withTitle:"Save Copy…"); alert.addButton(withTitle:"Reload from Disk")
        switch alert.runModal() {
        case .alertSecondButtonReturn: saveCopy(buffer); return false
        case .alertThirdButtonReturn:
            do { try reload(buffer); return true } catch { report(error); return false }
        default: return false
        }
    }
    func saveCopy(_ buffer:FileBuffer) {
        let panel=NSSavePanel(); panel.nameFieldStringValue=buffer.url.lastPathComponent; panel.directoryURL=buffer.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url=panel.url else { return }
        guard url.resolvingSymlinksInPath() != buffer.url.resolvingSymlinksInPath() else {
            report(WorkspaceError.message("Choose a different path to preserve the external version.")); return
        }
        attempt {
            guard let data=buffer.encoded else { throw WorkspaceError.message("The text cannot be encoded.") }
            try data.write(to:url,options:.atomic); refresh()
        }
    }
    func requestCloseTab(_ id:UUID, pane:UUID) {
        guard let tab=session.panes.first(where:{$0.id == pane})?.tabs.first(where:{$0.id == id}) else { return }
        if referenceCount(tab.path) == 1, let buffer=buffers[tab.path], !resolveUnsaved([buffer]) { return }
        closeTab(id,pane:pane)
    }
    func reveal(_ url:URL? = nil) { if let url=url ?? workspace?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func copyPath(_ url:URL? = nil) {
        if let path=(url ?? workspace?.url)?.path { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path,forType:.string) }
    }
    func promptName(title:String, initial:String, button:String) -> String? {
        let alert=NSAlert(); alert.messageText=title
        let field=NSTextField(string:initial); field.frame=NSRect(x:0,y:0,width:280,height:24)
        alert.accessoryView=field; alert.addButton(withTitle:button); alert.addButton(withTitle:"Cancel")
        alert.window.initialFirstResponder=field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue:nil
    }
    var creationDirectory: URL? {
        activeBuffer?.url.deletingLastPathComponent() ?? workspace?.url
    }
    func newItem(folder:Bool, at directory:URL? = nil) {
        guard let parent=directory ?? creationDirectory, let name=promptName(title:folder ? "New Folder":"New File",initial:folder ? "New Folder":"untitled.txt",button:"Create") else { return }
        attempt {
            let url=try WorkspaceFileService.child(named:name,in:parent)
            try validateMutation(url)
            guard !FileManager.default.fileExists(atPath:url.path) else { throw WorkspaceError.message("A file or folder with this name already exists.") }
            if folder { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false) }
            else { try Data().write(to:url,options:.withoutOverwriting) }
            expanded.insert(parent.path); refresh()
            if !folder { try openFile(url,pinned:true) }
        }
    }
    func rename(_ node:FileNode) {
        guard let name=promptName(title:"Rename \(node.name)",initial:node.name,button:"Rename"),name != node.name else { return }
        attempt { try move(node.url,to:WorkspaceFileService.child(named:name,in:node.url.deletingLastPathComponent())) }
    }
    func duplicate(_ node:FileNode) {
        attempt {
            try validateMutation(node.url)
            let target=WorkspaceFileService.availableCopy(of:node.url,in:node.url.deletingLastPathComponent())
            try FileManager.default.copyItem(at:node.url,to:target); refresh()
            if !node.isDirectory { try openFile(target,pinned:true) }
        }
    }
    func delete(_ node:FileNode) {
        let affected=buffers.values.filter { WorkspaceFileService.isInside($0.url,root:node.url) }
        let alert=NSAlert(); alert.messageText="Move \(node.name) to Trash?"
        alert.informativeText=node.isDirectory ? "This folder and its contents will be moved to Trash.":"You can restore it from Finder's Trash."
        alert.addButton(withTitle:"Move to Trash"); alert.addButton(withTitle:"Cancel"); alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn, resolveUnsaved(affected) else { return }
        attempt {
            try validateMutation(node.url)
            try FileManager.default.trashItem(at:node.url,resultingItemURL:nil)
            removeReferences(beneath:node.url); refresh()
        }
    }
    private func validateMutation(_ url:URL) throws {
        guard let root=workspace?.url, url.standardizedFileURL != root,
              WorkspaceFileService.isInside(url,root:root),
              WorkspaceFileService.isInside(url.deletingLastPathComponent(),root:root,resolve:true) else {
            throw WorkspaceError.message("File operations must stay inside the active workspace.")
        }
    }
    func move(_ source:URL, to target:URL) throws {
        try validateMutation(source); try validateMutation(target)
        if source == target { return }
        guard !WorkspaceFileService.isInside(target,root:source) else { throw WorkspaceError.message("A folder cannot be moved into itself.") }
        let manager=FileManager.default
        if manager.fileExists(atPath:target.path) {
            let a=try manager.attributesOfItem(atPath:source.path), b=try manager.attributesOfItem(atPath:target.path)
            let sameFile=(a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber) && (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber)
            guard sameFile, source.deletingLastPathComponent() == target.deletingLastPathComponent(), source.lastPathComponent.caseInsensitiveCompare(target.lastPathComponent) == .orderedSame else {
                throw WorkspaceError.message("A file or folder with this name already exists.")
            }
            // A temporary sibling makes case-only renames reliable on APFS.
            let temporary=source.deletingLastPathComponent().appendingPathComponent(".milk-rename-"+UUID().uuidString)
            try manager.moveItem(at:source,to:temporary)
            do { try manager.moveItem(at:temporary,to:target) }
            catch { try? manager.moveItem(at:temporary,to:source); throw error }
        } else { try manager.moveItem(at:source,to:target) }
        remapReferences(from:source,to:target); refresh(); schedulePersistence()
    }
    private func remapReferences(from source:URL,to target:URL) {
        func remap(_ path:String) -> String {
            if path == source.path { return target.path }
            if path.hasPrefix(source.path+"/") { return target.path+String(path.dropFirst(source.path.count)) }
            return path
        }
        var remapped:[String:FileBuffer]=[:]
        for (path,buffer) in buffers {
            let next=remap(path); buffer.url=URL(fileURLWithPath:next); remapped[next]=buffer
        }
        // Buffer dictionary has a private setter; this operation lives in the store.
        replaceBuffers(remapped)
        for key in Array(sessions.keys) {
            var value=sessions[key]!
            for p in value.panes.indices {
                for t in value.panes[p].tabs.indices { value.panes[p].tabs[t].path=remap(value.panes[p].tabs[t].path) }
                value.panes[p].positions=Dictionary(value.panes[p].positions.map { (remap($0.key),$0.value) },uniquingKeysWith: { _,b in b })
            }
            sessions[key]=value
        }
        expanded=Set(expanded.map(remap))
        diagnostics=diagnostics.map { d in var d=d; d = .init(id:d.id,file:URL(fileURLWithPath:remap(d.file.path)),line:d.line,column:d.column,message:d.message,severity:d.severity,source:d.source); return d }
    }
    private func removeReferences(beneath url:URL) {
        for key in Array(sessions.keys) {
            var value=sessions[key]!
            for p in value.panes.indices {
                value.panes[p].tabs.removeAll { WorkspaceFileService.isInside(URL(fileURLWithPath:$0.path),root:url) }
                if !value.panes[p].tabs.contains(where:{$0.id == value.panes[p].selected}) { value.panes[p].selected=value.panes[p].tabs.first?.id }
            }
            sessions[key]=value
        }
        replaceBuffers(buffers.filter { !WorkspaceFileService.isInside($0.value.url,root:url) })
        expanded=expanded.filter { !WorkspaceFileService.isInside(URL(fileURLWithPath:$0),root:url) }
        diagnostics.removeAll { WorkspaceFileService.isInside($0.file,root:url) }; schedulePersistence()
    }
    func receiveDrop(_ providers:[NSItemProvider], into directory:URL) -> Bool {
        guard workspace != nil else { return false }
        // Milk drags use a custom type so Finder file URLs always copy.
        let internalType="dev.milk.workspace-path"
        let internalItems=providers.filter { $0.hasItemConformingToTypeIdentifier(internalType) }
        if !internalItems.isEmpty {
            for item in internalItems {
                item.loadDataRepresentation(forTypeIdentifier:internalType) { [weak self] data,_ in
                    guard let data,let path=String(data:data,encoding:.utf8) else { return }
                    Task { @MainActor in
                        self?.attempt { try self?.move(URL(fileURLWithPath:path),to:directory.appendingPathComponent((path as NSString).lastPathComponent)) }
                    }
                }
            }
            return true
        }
        let items=providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for item in items {
            item.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { [weak self] value,_ in
                let source:URL?
                if let data=value as? Data { source=URL(dataRepresentation:data,relativeTo:nil) }
                else if let url=value as? URL { source=url }
                else { source=(value as? String).flatMap(URL.init(string:)) }
                guard let source else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.attempt {
                        let target=directory.appendingPathComponent(source.lastPathComponent)
                        try self.validateMutation(target)
                        guard !WorkspaceFileService.isInside(directory.resolvingSymlinksInPath(),root:source.resolvingSymlinksInPath()) else {
                            throw WorkspaceError.message("A folder cannot be copied into itself.")
                        }
                        let destination=FileManager.default.fileExists(atPath:target.path) ? WorkspaceFileService.availableCopy(of:source,in:directory):target
                        try FileManager.default.copyItem(at:source,to:destination)
                        self.expanded.insert(directory.path); self.refresh()
                    }
                }
            }
        }
        return !items.isEmpty
    }
    func dragProvider(_ node:FileNode) -> NSItemProvider {
        let provider=NSItemProvider(contentsOf:node.url) ?? NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier:"dev.milk.workspace-path",visibility:.ownProcess) { completion in
            completion(Data(node.url.path.utf8),nil); return nil
        }
        return provider
    }
}
