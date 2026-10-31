import Foundation

@MainActor extension WorkspaceStore {
    func openGitFile(_ file: GitFile, staged: Bool = false, repository:GitRepository? = nil) {
        guard let repo = repository ?? git.repository else { return }
        let url = repo.root.appendingPathComponent(file.path).standardizedFileURL
        guard let root = workspace?.url, WorkspaceFileService.isInside(url, root: root, resolve: false) else {
            git.failure = .validation("This repository file is outside the active workspace. Open the repository root to edit it."); return
        }
        // Reuse the normal buffer and tab whenever text is available. Deleted/binary files still have a diff tab.
        if WorkspaceFileService.isInside(url, root: root, resolve: true),
           (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
           buffers[url.path] == nil, let data = try? Data(contentsOf: url), let buffer = try? FileBuffer(url: url, data: data) { var value = buffers; value[url.path] = buffer; replaceBuffers(value) }
        var value = session; let p = activePaneIndex
        if let t = value.panes[p].tabs.firstIndex(where: { $0.path == url.path }) {
            value.panes[p].tabs[t].diffMode = true; value.panes[p].tabs[t].stagedDiff = staged
            value.panes[p].selected = value.panes[p].tabs[t].id
        } else {
            let tab = EditorTab(path: url.path, pinned: true, diffMode: true, stagedDiff: staged)
            value.panes[p].tabs.append(tab); value.panes[p].selected = tab.id
        }
        session = value; onOpenFile?()
    }
    func setDiffMode(_ enabled: Bool, staged: Bool? = nil, pane: UUID) {
        var value = session
        guard let p = value.panes.firstIndex(where: { $0.id == pane }), let t = value.panes[p].tabs.firstIndex(where: { $0.id == value.panes[p].selected }) else { return }
        value.panes[p].tabs[t].diffMode = enabled
        if let staged { value.panes[p].tabs[t].stagedDiff = staged }
        session = value
    }
    func openChangedFile(_ url: URL) {
        guard let root=workspace?.url else {return}
        Task {
            do {
                // A coalesced store refresh can return before its in-flight status read.
                // Resolve this navigation from a completed real Git query instead.
                let repo=try await git.service.repository(at:root)
                guard workspace?.url == root else {return}
                if let repo,let file=repo.files.first(where:{repo.root.appendingPathComponent($0.path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()}) {
                    openGitFile(file,staged:file.staged && !file.unstaged,repository:repo)
                    git.requestRefresh()
                } else {attempt {try openFile(url,pinned:true)}}
            } catch {guard workspace?.url == root else{return};report(error)}
        }
    }
    func gitFile(for path: String) -> GitFile? {
        guard let repo = git.repository else { return nil }
        return repo.files.first { repo.root.appendingPathComponent($0.path).resolvingSymlinksInPath() == URL(fileURLWithPath:path).resolvingSymlinksInPath() }
    }
}
