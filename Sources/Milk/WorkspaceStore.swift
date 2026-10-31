import AppKit
import Combine
import SwiftUI

@MainActor final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspace: Workspace?
    @Published private(set) var recent: [URL] = []
    @Published private(set) var rows: [FileNode] = []
    @Published private(set) var treeError: String?
    @Published var expanded: Set<String> = [] { didSet { showCachedTree(animate:animatingFolderToggle); refresh(animate:animatingFolderToggle); schedulePersistence() } }
    @Published var showHidden = false { didSet { refresh(); schedulePersistence() } }
    @Published var showIgnored = false { didSet { refresh(); schedulePersistence() } }
    @Published var sessions: [String:EditorSession] = ["0":EditorSession()] { didSet { schedulePersistence() } }
    @Published var selectedSession = 0 { didSet { if sessions[String(selectedSession)] == nil { sessions[String(selectedSession)]=EditorSession() }; schedulePersistence() } }
    @Published var preferences = EditorPreferences() { didSet { savePreferences() } }
    @Published var diagnostics: [EditorDiagnostic] = []
    @Published var findVisible = false
    @Published var findQuery = FindQuery()
    @Published var findCount = 0
    @Published var findIndex = 0
    @Published var findError: String?
    @Published var selectionLine = 1
    @Published var selectionColumn = 1
    @Published var navigation: EditorNavigation?
    var layoutData: (() -> Data?)?
    var sessionData: (() -> Data?)?
    var restoreSessionData: ((Data?) -> Void)?
    var restoreLayout: ((Data?, String)->Void)?
    var onCloseWorkspace: (() -> Void)?
    var onChangeWorkspace: ((URL?) -> Void)?
    var onFilesChanged: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var sidebarDestination: (() -> String)?
    private(set) var buffers: [String:FileBuffer] = [:]
    let git = GitStore()
    let persistence: WorkspacePersistence
    private var watcher: WorkspaceWatcher?
    private var persistTask: Task<Void,Never>?
    private var diagnosticsTask: Task<Void,Never>?
    private var scanVersion = 0
    private var animatingFolderToggle=false
    private var cachedChildren:[String:[FileNode]] = [:]
    private var restoring = false
    private(set) var restoredExistingSnapshot = false
    private let providers: [DiagnosticProvider] = [JSONDiagnosticProvider()]

    struct EditorNavigation: Equatable {
        var id = UUID()
        var paneID: UUID
        var range: NSRange?
        var line: Int?
        var column: Int = 1
    }
    init(persistence:WorkspacePersistence = WorkspacePersistence()) {
        self.persistence=persistence; recent=persistence.recent
        if let data=persistence.defaults.data(forKey:"Milk.editor.preferences.v1"),let value=try? JSONDecoder().decode(EditorPreferences.self,from:data) {
            preferences=SettingsService.validatedEditor(value)
        }
    }
    var session: EditorSession {
        get { sessions[String(selectedSession)] ?? EditorSession() }
        set { sessions[String(selectedSession)]=newValue }
    }
    var activePaneIndex: Int { min(max(0,session.activePane),session.panes.count-1) }
    var activePane: EditorPane { session.panes[activePaneIndex] }
    var activeBuffer: FileBuffer? { activePane.activeTab.flatMap { buffers[$0.path] } }
    var split: Bool { session.panes.count == 2 }
    var modifiedBuffers: [FileBuffer] { buffers.values.filter(\.isModified).sorted { $0.url.path < $1.url.path } }
    var openPaths: Set<String> { Set(session.panes.flatMap(\.tabs).map(\.path)) }
    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    func restoreActiveWorkspace() {
        guard persistence.enabled,let active=persistence.active else { return }
        do { try openWorkspace(active) } catch { treeError="Could not restore \(active.path): \(error.localizedDescription)" }
    }
    func restoreLastWorkspace() {
        guard persistence.enabled, let last=persistence.last else { return }
        do { try openWorkspace(last) } catch { treeError="Could not restore \(last.path): \(error.localizedDescription)" }
    }
    func openWorkspace(_ url:URL) throws {
        let root=url.standardizedFileURL.resolvingSymlinksInPath()
        let values=try root.resourceValues(forKeys:[.isDirectoryKey,.isReadableKey])
        guard values.isDirectory == true, values.isReadable != false else { throw WorkspaceError.message("Choose a readable folder.") }
        if workspace?.url == root { return }
        try persistNow()
        onChangeWorkspace?(root)
        watcher?.stop(); persistTask?.cancel(); diagnosticsTask?.cancel()
        restoring=true
        workspace=Workspace(url:root); cachedChildren=[:]; rows=[]; buffers=[:]; diagnostics=[]; treeError=nil
        let saved=persistence.load(root)
        restoredExistingSnapshot = saved != nil
        sessions=saved?.sessions ?? [:]; selectedSession=saved?.selectedSession ?? 0
        expanded=saved?.expanded ?? []; showHidden=saved?.showHidden ?? false; showIgnored=saved?.showIgnored ?? false
        for item in saved?.recoveries ?? [] where WorkspaceFileService.isInside(URL(fileURLWithPath:item.path),root:root,resolve:true) {
            buffers[item.path]=FileBuffer(recovery:item)
        }
        // Validate restored URLs. A missing file survives only if it has recovered edits.
        for key in Array(sessions.keys) {
            guard var value=sessions[key] else { continue }
            if value.panes.isEmpty { value.panes=[EditorPane()] }
            value.panes=Array(value.panes.prefix(2)); value.activePane=min(max(0,value.activePane),value.panes.count-1)
            for i in value.panes.indices {
                value.panes[i].tabs.removeAll { tab in
                    let file=URL(fileURLWithPath:tab.path)
                    guard WorkspaceFileService.isInside(file,root:root,resolve:true) else { return true }
                    if tab.diffMode == true { if let buffer = try? loadBuffer(file) { buffers[tab.path] = buffer }; return false }
                    if buffers[tab.path] != nil { return false }
                    if let buffer=try? loadBuffer(file) { buffers[tab.path]=buffer; return false }
                    return true
                }
                if !value.panes[i].tabs.contains(where:{$0.id == value.panes[i].selected}) { value.panes[i].selected=value.panes[i].tabs.first?.id }
            }
            sessions[key]=value
        }
        if sessions[String(selectedSession)] == nil { sessions[String(selectedSession)]=EditorSession() }
        recent=([root]+recent.filter { $0 != root }).prefix(15).map { $0 }
        persistence.recent=recent; persistence.last=root; persistence.active=root
        restoring=false
        restoreSessionData?(saved?.shellSessions)
        restoreLayout?(saved?.layout,saved?.sidebarDestination ?? "Files")
        watcher=WorkspaceWatcher(url:root) { [weak self] _ in
            self?.onFilesChanged?()
            Task { @MainActor in self?.refresh(); self?.checkExternalChanges() }
        }
        git.setWorkspace(root)
        git.onRepositoryChange = { [weak self] in self?.checkExternalChanges(); self?.objectWillChange.send() }
        refresh(); checkExternalChanges(); updateDiagnostics(); schedulePersistence()
    }
    func closeWorkspace() throws {
        try persistNow(); onChangeWorkspace?(nil); watcher?.stop(); watcher=nil; persistTask?.cancel()
        restoring=true
        git.setWorkspace(nil)
        restoredExistingSnapshot = false
        workspace=nil; cachedChildren=[:]; rows=[]; buffers=[:]; sessions=[String(selectedSession):EditorSession()]; diagnostics=[]; expanded=[]; treeError=nil
        persistence.active=nil; restoring=false; onCloseWorkspace?()
    }
    func replaceBuffers(_ value:[String:FileBuffer]) { buffers=value; objectWillChange.send() }
    private func loadBuffer(_ url:URL) throws -> FileBuffer {
        let resolved=url.resolvingSymlinksInPath()
        guard let root=workspace?.url, WorkspaceFileService.isInside(resolved,root:root,resolve:true) else {
            throw WorkspaceError.message("This link points outside the workspace. Open its containing folder as a workspace to edit it.")
        }
        let size=try resolved.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=FileTextCodec.maximumSize else { throw WorkspaceError.message("This file exceeds the 8 MB text editor limit.") }
        return try FileBuffer(url:resolved,data:Data(contentsOf:resolved))
    }
    func refresh(animate:Bool = false) {
        guard !restoring, let root=workspace?.url else { return }
        git.requestRefresh()
        scanVersion += 1
        let version=scanVersion, expansion=expanded, hidden=showHidden, ignored=showIgnored
        Task {
            let result=await Task.detached(priority:.userInitiated) {
                Result { try FileTreeService().scan(root:root,expanded:expansion,hidden:hidden,ignored:ignored) }
            }.value
            guard version == scanVersion, self.workspace?.url == root else { return }
            switch result { case let .success(value):
                let grouped=Dictionary(grouping:value,by: { $0.url.deletingLastPathComponent().path })
                // Retain collapsed branches for instant reopening; refresh only the
                // branches included in this lazy scan, including newly empty ones.
                let scanned=[root.path]+value.filter { $0.isDirectory && expansion.contains($0.id) }.map(\.id)
                for path in scanned { self.cachedChildren[path]=grouped[path] ?? [] }
                self.showCachedTree(animate:animate)
                self.treeError=nil
            case let .failure(error): self.treeError=error.localizedDescription }
        }
    }
    private func showCachedTree(animate:Bool) {
        guard !restoring,let root=workspace?.url else { return }
        var visible:[FileNode]=[]
        func appendChildren(_ path:String) {
            for node in cachedChildren[path] ?? [] {
                visible.append(node)
                if node.isDirectory && expanded.contains(node.id) { appendChildren(node.id) }
            }
        }
        appendChildren(root.path)
        guard visible != rows else { return }
        let smallChange=max(rows.count,visible.count)<300 && abs(rows.count-visible.count)<=80
        if animate && smallChange && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeInOut(duration:0.14)) { rows=visible }
        } else { rows=visible }
    }
    func toggleFolder(_ node:FileNode) {
        animatingFolderToggle=true
        defer { animatingFolderToggle=false }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }
    func openFile(_ url:URL, pinned:Bool = false, pane:Int? = nil) throws {
        let resolved=url.resolvingSymlinksInPath(), path=resolved.path
        if buffers[path] == nil { buffers[path]=try loadBuffer(url) }
        var value=session
        let index=min(max(0,pane ?? value.activePane),value.panes.count-1)
        value.activePane=index
        if let existing=value.panes[index].tabs.firstIndex(where:{$0.path == path}) {
            if pinned { value.panes[index].tabs[existing].pinned=true }
            value.panes[index].tabs[existing].diffMode = false
            value.panes[index].selected=value.panes[index].tabs[existing].id
        } else {
            let tab=EditorTab(path:path,pinned:pinned)
            if !pinned, let preview=value.panes[index].tabs.firstIndex(where:{ !$0.pinned && buffers[$0.path]?.isModified != true }) {
                value.panes[index].tabs[preview]=tab
            } else { value.panes[index].tabs.append(tab) }
            value.panes[index].selected=tab.id
        }
        session=value; pruneBuffers(); onOpenFile?(); updateDiagnostics()
        navigation = .init(paneID:value.panes[index].id)
    }
    func activatePane(_ id:UUID) {
        guard let index=session.panes.firstIndex(where:{$0.id == id}), session.activePane != index else { return }
        var value=session; value.activePane=index; session=value
    }
    func selectTab(_ id:UUID, pane:UUID) {
        guard let index=session.panes.firstIndex(where:{$0.id == pane}) else { return }
        var value=session; value.activePane=index; value.panes[index].selected=id; session=value
        navigation = .init(paneID:pane)
    }
    func pin(_ id:UUID, pane:UUID) {
        var value=session
        guard let p=value.panes.firstIndex(where:{$0.id == pane}),let t=value.panes[p].tabs.firstIndex(where:{$0.id == id}) else { return }
        value.panes[p].tabs[t].pinned=true; session=value
    }
    func closeTab(_ id:UUID, pane:UUID) {
        var value=session
        guard let p=value.panes.firstIndex(where:{$0.id == pane}),let t=value.panes[p].tabs.firstIndex(where:{$0.id == id}) else { return }
        value.panes[p].tabs.remove(at:t)
        if value.panes[p].selected == id { value.panes[p].selected=value.panes[p].tabs.isEmpty ? nil:value.panes[p].tabs[min(t,value.panes[p].tabs.count-1)].id }
        session=value; pruneBuffers(); updateDiagnostics()
    }
    func referenceCount(_ path:String) -> Int { sessions.values.flatMap(\.panes).flatMap(\.tabs).filter { $0.path == path }.count }
    func reorderTab(_ id:UUID, to target:UUID?, pane:UUID) {
        var value=session
        guard let destination=value.panes.firstIndex(where:{$0.id == pane}), let source=value.panes.firstIndex(where:{$0.tabs.contains(where:{$0.id == id})}),
              let old=value.panes[source].tabs.firstIndex(where:{$0.id == id}), id != target else { return }
        var tab=value.panes[source].tabs.remove(at:old); tab.pinned=true
        if source != destination, value.panes[source].selected == id { value.panes[source].selected=value.panes[source].tabs.first?.id }
        if let existing=value.panes[destination].tabs.firstIndex(where:{$0.path == tab.path}) {
            value.panes[destination].tabs[existing].pinned=true; value.panes[destination].selected=value.panes[destination].tabs[existing].id
        } else {
            let index=target.flatMap { target in value.panes[destination].tabs.firstIndex(where:{$0.id == target}) } ?? value.panes[destination].tabs.count
            value.panes[destination].tabs.insert(tab,at:index); value.panes[destination].selected=tab.id
        }
        value.activePane=destination; session=value
    }
    func toggleSplit() {
        var value=session
        if value.panes.count == 1 {
            var pane=EditorPane()
            if let tab=activePane.activeTab { let copy=EditorTab(path:tab.path,pinned:true,diffMode:tab.diffMode,stagedDiff:tab.stagedDiff); pane.tabs=[copy]; pane.selected=copy.id }
            value.panes.append(pane); value.activePane=1
        } else {
            // Preserve every tab, including edits, when collapsing the second pane.
            for var tab in value.panes[1].tabs where !value.panes[0].tabs.contains(where:{$0.path == tab.path}) {
                tab.pinned=true; value.panes[0].tabs.append(tab)
            }
            if value.activePane == 1, let path=value.panes[1].activeTab?.path { value.panes[0].selected=value.panes[0].tabs.first(where:{$0.path == path})?.id }
            value.panes.removeLast(); value.activePane=0
        }
        session=value
    }
    func bufferChanged(_ buffer:FileBuffer) {
        buffer.text=buffer.storage.string; buffer.revision += 1
        for key in Array(sessions.keys) {
            var value=sessions[key]!
            for p in value.panes.indices {
                for t in value.panes[p].tabs.indices where value.panes[p].tabs[t].path == buffer.url.path { value.panes[p].tabs[t].pinned=true }
            }
            sessions[key]=value
        }
        objectWillChange.send(); schedulePersistence(); updateDiagnostics()
    }
    func positionChanged(_ position:EditorPosition, path:String, pane:UUID) {
        guard !restoring,let index=session.panes.firstIndex(where:{$0.id == pane}) else { return }
        var value=session
        guard value.panes[index].positions[path] != position else { return }
        value.panes[index].positions[path]=position; session=value
    }
    func save(_ buffer:FileBuffer) throws {
        guard let root=workspace?.url, WorkspaceFileService.isInside(buffer.url,root:root,resolve:true) else {
            throw WorkspaceError.message("The file now points outside the active workspace. Save a copy to preserve your edits.")
        }
        guard let data=buffer.encoded else { throw WorkspaceError.message("This text cannot be represented using the file's original encoding.") }
        do { try WorkspaceFileService.safeSave(data,to:buffer.url,baseline:buffer.baseline) }
        catch { checkExternalChanges(); throw error }
        buffer.baseline=data; buffer.externallyChanged=false; buffer.missing=false
        objectWillChange.send(); schedulePersistence(); git.requestRefresh()
    }
    func reload(_ buffer:FileBuffer) throws {
        try buffer.reload(Data(contentsOf:buffer.url)); objectWillChange.send(); updateDiagnostics(); schedulePersistence()
    }
    func checkExternalChanges() {
        var changed=false
        for buffer in buffers.values {
            guard let data=try? Data(contentsOf:buffer.url) else {
                if !buffer.missing { buffer.missing=true; buffer.externallyChanged=true; changed=true }; continue
            }
            if data == buffer.baseline {
                if buffer.externallyChanged || buffer.missing { buffer.externallyChanged=false; buffer.missing=false; changed=true }
                continue
            }
            if buffer.isModified { buffer.externallyChanged=true; buffer.missing=false; changed=true }
            else { do { try buffer.reload(data) } catch { buffer.externallyChanged=true }; changed=true }
        }
        if changed { objectWillChange.send(); updateDiagnostics(); schedulePersistence() }
    }
    func publishDiagnostics(_ values:[EditorDiagnostic], source:String) {
        diagnostics.removeAll { $0.source == source }; diagnostics += values
    }
    private func updateDiagnostics() {
        diagnosticsTask?.cancel()
        diagnosticsTask=Task {
            try? await Task.sleep(nanoseconds:200_000_000)
            guard !Task.isCancelled else { return }
            let local=buffers.values.flatMap { b in providers.flatMap { $0.diagnostics(for:b.url,text:b.text) } }
            publishDiagnostics(local,source:"JSON parser")
        }
    }
    func jump(to diagnostic:EditorDiagnostic) throws {
        try openFile(diagnostic.file,pinned:true)
        navigation = .init(paneID:activePane.id,line:diagnostic.line,column:diagnostic.column)
    }
    func navigateFind(forward:Bool) { if !findQuery.text.isEmpty { findVisible=true }; navigation = .init(paneID:activePane.id,range:NSRange(location:forward ? 1:0,length:NSNotFound)) }
    private func pruneBuffers() {
        let paths=Set(sessions.values.flatMap(\.panes).flatMap(\.tabs).map(\.path))
        buffers=buffers.filter { paths.contains($0.key) || $0.value.isModified }
    }
    func schedulePersistence() {
        guard !restoring else { return }
        persistTask?.cancel()
        persistTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:500_000_000)
            guard !Task.isCancelled else { return }
            do { try self?.persistNow() } catch { self?.treeError="Workspace recovery could not be saved: \(error.localizedDescription)" }
        }
    }
    func persistNow() throws {
        guard let root=workspace?.url, !restoring else { return }
        let value=WorkspaceSnapshot(sessions:sessions,selectedSession:selectedSession,expanded:expanded,showHidden:showHidden,showIgnored:showIgnored,
                                    recoveries:modifiedBuffers.map(\.recovery),layout:layoutData?(),shellSessions:sessionData?(),sidebarDestination:sidebarDestination?() ?? "Files")
        try persistence.save(value,root:root)
    }
    private func savePreferences() {
        if persistence.enabled,let data=try? JSONEncoder().encode(preferences) { persistence.defaults.set(data,forKey:"Milk.editor.preferences.v1") }
    }
}

extension WorkspaceStore {
    func projectFiles(matching query: String) async -> [URL] {
        guard let root = workspace?.url else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? FileTreeService().projectFiles(root: root, matching: query)) ?? [] }.value
    }
}
