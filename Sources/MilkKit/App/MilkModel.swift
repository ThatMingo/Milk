import AppKit
import Observation
import MilkCore

@MainActor @Observable public final class MilkModel {
    public private(set) var workspaces: [WorkspaceRecord] = []
    public private(set) var workspaceID: UUID?
    public private(set) var folder: URL?
    public private(set) var sessions: [PiSessionController] = []
    public var selectedSession: UUID?
    public var files: [FileEntry] = []
    public var gitSnapshot: GitSnapshot?
    public var patch = ""
    public var selectedChange: String?
    public var inspectorVisible = true
    public var terminalVisible = false
    public var panel = "Chat"
    public var searchQuery = ""
    public var searchResults: [SearchMatch] = []
    public var error: String?
    public var previewURL: URL?
    public var previewAddress = "http://localhost:3000"
    public var githubState: GitHubAuthState = .registrationRequired
    public var githubRepository: GitHubRepository?
    public var githubSummary = ""
    public let editor: EditorController
    public let git = GitService()
    public let github: GitHubService
    public let extensions = ExtensionRegistry(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Milk/Extensions"))
    public let extensionHost = ExtensionHostClient()
    public let updates = UpdateService()
    public let terminal = TerminalController()
    public let fileService: FileService
    public let searchService = SearchService()
    @ObservationIgnored private var store: WorkspaceStore?
    @ObservationIgnored private var watcher: WorkspaceWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    public var currentSession: PiSessionController? { sessions.first { $0.id == selectedSession } }
    public var workspaceName: String { folder?.lastPathComponent ?? "Open a workspace" }
    public init() {
        let files = FileService(); fileService = files
        editor = EditorController(files: files)
        github = GitHubService(configuration: .init(clientID: Bundle.main.object(forInfoDictionaryKey: "MilkGitHubClientID") as? String ?? ""))
        do { store = try WorkspaceStore() } catch { self.error = error.localizedDescription }
    }
    public func restore() async {
        do {
            try await extensions.restore()
            workspaces = try await store?.load() ?? []
            if let index = CommandLine.arguments.firstIndex(of: "--workspace"), CommandLine.arguments.count > index + 1 { try await open(URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            else if let recent = workspaces.max(by: { $0.lastOpened < $1.lastOpened }) { try await open(recent.resolve()) }
        } catch { self.error = error.localizedDescription }
    }
    public func chooseFolder() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Open Workspace"
        if picker.runModal() == .OK, let url = picker.url { Task { do { try await open(url) } catch { self.error = error.localizedDescription } } }
    }
    public func open(_ url: URL) async throws {
        guard await allowWorkspaceChange() else { return }
        await closeRuntime()
        editor.reset()
        let canonical = url.resolvingSymlinksInPath()
        let record = try workspaces.first(where: { $0.path == canonical.path }) ?? WorkspaceRecord(folder: canonical)
        if !workspaces.contains(where: { $0.id == record.id }) { workspaces.append(record) }
        workspaceID = record.id; folder = canonical
        sessions = record.sessions.map { makeSession($0, folder: canonical) }
        selectedSession = record.selectedSession ?? sessions.first?.id
        inspectorVisible = record.inspectorVisible; terminalVisible = record.terminalVisible; editor.split = record.editor.split
        if sessions.isEmpty { newSession() }
        for path in record.editor.paths { try? await editor.open(URL(fileURLWithPath: path)) }
        if let selected = record.editor.selectedPath { editor.selected = editor.documents.first { $0.url.path == selected }?.id }
        watcher = WorkspaceWatcher(folder: canonical) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
        await refresh(); persist()
    }
    private func makeSession(_ record: SessionRecord, folder: URL) -> PiSessionController {
        let session = PiSessionController(record: record, folder: folder)
        session.changed = { [weak self] in self?.persist() }
        return session
    }
    public func newSession() {
        guard let folder else { return }
        let session = makeSession(.init(name: "Session \(sessions.count + 1)"), folder: folder)
        sessions.append(session); selectedSession = session.id; panel = "Chat"; persist()
    }
    public func closeSession(_ session: PiSessionController) async {
        await session.shutdown(); sessions.removeAll { $0.id == session.id }
        if selectedSession == session.id { selectedSession = sessions.last?.id }; persist()
    }
    public func openFile(_ url: URL) async {
        do { try await editor.open(url); panel = "Editor"; previewURL = url; persist() } catch { self.error = error.localizedDescription }
    }
    public func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }; await refresh() }
    }
    public func refresh() async {
        guard let folder else { return }
        files = (try? await fileService.children(of: folder)) ?? []
        gitSnapshot = try? await git.snapshot(in: folder)
        await editor.synchronize()
    }
    public func showDiff(_ change: GitChange, staged: Bool = false) async {
        guard let folder else { return }
        selectedChange = change.path
        do { patch = try await git.diff(in: folder, path: change.path, staged: staged) } catch { self.error = error.localizedDescription }
    }
    public func search() async {
        guard let folder else { return }
        do { searchResults = try await searchService.search(searchQuery, in: folder) } catch { self.error = error.localizedDescription }
    }
    public func inspectGitHub() async {
        guard let folder else { return }
        githubState = await github.authState()
        if let remotes = try? await git.remotes(in: folder) {
            githubRepository = remotes.compactMap { line in line.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap { GitHubRepository.parse(remote: String($0)) } }.first
        }
        guard let githubRepository else { githubSummary = "No GitHub remote detected"; return }
        do {
            let repo = try await github.repository(githubRepository)
            githubSummary = repo["description"].string ?? githubRepository.slug
        } catch { githubSummary = error.localizedDescription }
    }
    public func persist() {
        guard let id = workspaceID, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].sessions = sessions.map(\.record); workspaces[index].selectedSession = selectedSession
        workspaces[index].lastOpened = Date(); workspaces[index].inspectorVisible = inspectorVisible; workspaces[index].terminalVisible = terminalVisible
        workspaces[index].editor.paths = editor.documents.map { $0.url.path }; workspaces[index].editor.selectedPath = editor.current?.url.path
        workspaces[index].editor.split = editor.split
        let records = workspaces
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(100)); guard !Task.isCancelled else { return }
            do { try await store?.save(records) } catch { self.error = error.localizedDescription }
        }
    }
    public func allowWorkspaceChange() async -> Bool {
        guard editor.documents.contains(where: \.dirty) else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes before leaving this workspace?"
        alert.addButton(withTitle: "Save All"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do { try await editor.saveAll(); return true } catch { self.error = error.localizedDescription; return false }
    }
    public func closeRuntime() async {
        watcher?.stop(); watcher = nil; refreshTask?.cancel(); persist()
        for session in sessions { await session.shutdown() }
        await editor.languages.shutdown()
        terminal.shutdown()
    }
    public func shutdown() async {
        await closeRuntime(); persist(); await persistTask?.value; extensionHost.disconnect()
    }
}
