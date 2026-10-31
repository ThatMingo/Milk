import AppKit
import Combine

/// Observable Git state and user workflows; all repository work is delegated to GitService.
@MainActor final class GitStore: ObservableObject {
    let service = GitService()
    @Published private(set) var repository: GitRepository?
    @Published private(set) var checked = false
    @Published private(set) var busy: String?
    @Published var failure: GitFailure?
    @Published var commitMessage = ""
    @Published var sideBySide = false
    @Published private(set) var notice: String?
    @Published private(set) var revision = 0
    private var workspace: URL?
    private var epoch = UUID()
    private var watchers: [WorkspaceWatcher] = []
    private var watched: Set<URL> = []
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false
    var onRepositoryChange: (() -> Void)?

    func setWorkspace(_ url: URL?) {
        epoch = UUID(); refreshTask?.cancel(); pollTask?.cancel(); toastTask?.cancel()
        watchers.forEach { $0.stop() }; watchers = []; watched = []
        workspace = url; repository = nil; checked = false; failure = nil; notice = nil; commitMessage = ""; busy = nil
        refreshing = false; refreshAgain = false; revision += 1
        guard url != nil else { return }
        requestRefresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.requestRefresh()
            }
        }
    }
    func requestRefresh() {
        guard workspace != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }
    func refreshNow() async {
        guard let workspace else { return }
        if busy != nil || refreshing { refreshAgain = true; return }
        let token = epoch; refreshing = true
        do {
            let value = try await service.repository(at: workspace)
            guard token == epoch else { return }
            let changed = value != repository
            repository = value; checked = true
            // Diff content may change while the porcelain status remains identical.
            revision += 1
            if changed { onRepositoryChange?() }
            installWatchers(value)
        } catch { if token == epoch { failure = structured(error); checked = true } }
        guard token == epoch else { return }
        refreshing = false
        if refreshAgain { refreshAgain = false; requestRefresh() }
    }
    private func installWatchers(_ repo: GitRepository?) {
        let locations = Set(([workspace] + [repo?.root, repo?.gitDirectory, repo?.commonDirectory]).compactMap { $0 })
        guard locations != watched else { return }
        watchers.forEach { $0.stop() }; watched = locations
        watchers = locations.map { url in WorkspaceWatcher(url: url) { [weak self] _ in self?.requestRefresh() } }
    }
    func diff(path: String, staged: Bool) async throws -> GitDiff {
        guard let repo = repository, let file = repo.files.first(where: { $0.path == path }) else {
            return .parse(path: path, staged: staged, raw: "")
        }
        return try await service.diff(file, staged: staged, in: repo)
    }
    func run(_ label: String, _ operation: GitOperation) {
        Task { await perform(label, operation) }
    }
    @discardableResult func perform(_ label: String, _ operation: GitOperation) async -> Bool {
        guard busy == nil, let workspace else { return false }
        let token = epoch; busy = label; failure = nil
        var success = false
        do {
            guard let repo = try await service.repository(at: workspace) else { throw GitFailure.validation("This workspace is no longer a Git repository.") }
            guard token == epoch else { return false }
            try await service.perform(operation, in: repo); success = true
        } catch { if token == epoch { failure = structured(error) } }
        guard token == epoch else { return success }
        busy = nil
        await refreshNow() // Also after a failed merge/pull: conflicts are real state.
        onRepositoryChange?()
        return success
    }
    func commit(push: Bool = false, stageAll: Bool = false) {
        guard busy == nil, let workspace else { return }
        let message = commitMessage, token = epoch
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { failure = .validation("Enter a commit message."); return }
        busy = stageAll ? "Staging all…" : "Committing…"; failure = nil
        Task {
            var committed = false
            do {
                guard var repo = try await service.repository(at: workspace) else { throw GitFailure.validation("This workspace is no longer a Git repository.") }
                guard token == epoch else { return }
                if stageAll {
                    try await service.perform(.stageAll, in: repo)
                    guard let updated = try await service.repository(at: workspace) else { throw GitFailure.validation("Repository is unavailable.") }
                    repo = updated
                }
                guard token == epoch else { return }
                busy = "Committing…"
                try await service.perform(.commit(message), in: repo)
                committed = true
                guard token == epoch else { return }
                if commitMessage == message { commitMessage = "" }
                showNotice("Committed locally")
                if push {
                    busy = "Pushing…"
                    guard let updated = try await service.repository(at: workspace) else { throw GitFailure.validation("Repository is unavailable.") }
                    guard token == epoch else { return }
                    try await service.perform(.push, in: updated)
                    guard token == epoch else { return }
                    showNotice("Committed and pushed")
                }
            } catch {
                if token == epoch {
                    let error = structured(error)
                    failure = committed ? GitFailure(kind: error.kind, operation: "Push", message: "The local commit succeeded. Push failed: \(error.message)", exitCode: error.exitCode) : error
                }
            }
            guard token == epoch else { return }
            busy = nil; await refreshNow(); onRepositoryChange?()
        }
    }
    func showNotice(_ message: String) {
        notice = message; toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }
    func confirmDeleteBranch(_ branch: String) {
        guard confirm(title: "Delete local branch \(branch)?", detail: "Git will refuse to delete an unmerged branch. This removes the local branch reference.", action: "Delete Branch") else { return }
        run("Deleting branch…", .deleteBranch(branch))
    }
    func createBranch(using store: WorkspaceStore) {
        if let name = store.promptName(title: "Create and switch to branch", initial: "", button: "Create") { run("Creating branch…", .createBranch(name)) }
    }
    func discard(_ file: GitFile, store: WorkspaceStore, snapshot: GitDiff? = nil, hunk: Int? = nil) {
        guard busy == nil, let repo = repository else { return }
        // Never discard disk changes while an unsaved editor buffer could later resurrect them.
        if store.buffers[repo.root.appendingPathComponent(file.path).path]?.isModified == true {
            failure = .validation("Save or resolve the unsaved editor changes before reverting this file."); return
        }
        let token = epoch
        Task {
            do {
                let diff: GitDiff
                if let snapshot { diff = snapshot } else { diff = try await service.diff(file, staged: false, in: repo) }
                guard token == epoch, busy == nil else { return }
                guard store.buffers[repo.root.appendingPathComponent(file.path).path]?.isModified != true else {
                    failure = .validation("Save or resolve the unsaved editor changes before reverting this file."); return
                }
                let action = file.untracked ? "Delete File" : hunk == nil ? "Revert File" : "Revert Hunk"
                let detail = file.untracked ? "Permanently delete the untracked file \(file.path)? This cannot be undone." : "Discard \(hunk == nil ? "working-tree changes" : "this hunk") in \(file.path)? Staged changes are preserved. This cannot be undone."
                guard confirm(title: action + "?", detail: detail, action: action) else { return }
                if let hunk { _ = await perform("Reverting hunk…", .hunk(diff, hunk, .revert)) }
                else { _ = await perform("Reverting file…", .discard(file, diff)) }
            } catch { if token == epoch { failure = structured(error) } }
        }
    }
    private func confirm(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func structured(_ error: Error) -> GitFailure { error as? GitFailure ?? .init(kind: .command, operation: "Git", message: error.localizedDescription) }
}
