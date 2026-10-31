import Foundation
import Combine
import AppKit

/// The workspace owns Preview; SwiftUI visibility and Pi session selection are not lifecycle events.
@MainActor final class PreviewService: ObservableObject {
    @Published private(set) var state: PreviewState = .idle
    @Published var address = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var error: String?
    @Published private(set) var workspace: URL?
    @Published private(set) var device: PreviewDevice = .desktop
    @Published private(set) var server: ManagedPreviewServer?
    private(set) var renderer = PreviewWebRenderer()
    let devServers: DevServerService
    var authorize: ((PreviewConfiguration) async throws -> PreviewConfiguration)?
    var assist: ((URL) async throws -> PreviewConfiguration)?
    var onActivity: ((String, String, AgentActivity.Status) -> Void)?
    var defaultDevice: PreviewDevice = .desktop
    var selectedHTML: (() -> URL?)?
    private let defaults: UserDefaults
    private let persist: Bool
    private var memories: [String: PreviewMemory]
    private var operation: Task<Void, Never>?
    private var transition: Task<Bool, Never>?
    private var generation = UUID()
    private var shuttingDown = false
    private var usesEnteredURL = false
    init(defaults: UserDefaults = .standard, persist: Bool = true, devServers: DevServerService? = nil) {
        self.defaults = defaults; self.persist = persist; self.devServers = devServers ?? DevServerService()
        memories = persist ? defaults.data(forKey: "Milk.preview.v1").flatMap { try? JSONDecoder().decode([String: PreviewMemory].self, from: $0) } ?? [:] : [:]
        self.devServers.onOutput = { [weak self] server in
            guard let self, self.server === server else { return }
            self.publishOutput(server)
        }
        self.devServers.onExit = { [weak self] server in
            guard let self, self.server === server else { return }
            self.renderer.stop()
            if [.starting, .waiting].contains(self.state), let root = self.workspace {
                self.memories[root.path]?.configuration = nil
                self.saveMemories()
            }
            self.fail("Preview server exited unexpectedly. Start Preview to try again.")
            self.publishOutput(server, status: .error)
            if server.groupGone { self.server = nil }
        }
        configureRenderer()
    }
    enum Ownership { case managed, external }
    var displayedOwnership: Ownership {
        guard let owned = server, !owned.groupGone, let detected = owned.detectedURL, let currentURL,
              detected.host == currentURL.host, detected.port == currentURL.port else { return .external }
        return .managed
    }
    var managed: Bool { server != nil && server?.groupGone == false }
    var busy: Bool { [.starting, .waiting].contains(state) }
    var statusLabel: String? {
        switch state {
        case .idle, .stopped: return nil
        case .starting: return "Preview starting…"
        case .waiting: return "Preview waiting…"
        case .loading: return "Preview loading…"
        case .failed: return "Preview failed"
        case .running: return currentURL?.port.map { "Preview · :\($0)" } ?? "Preview"
        }
    }
    func setWorkspace(_ root: URL?) {
        let root = root?.standardizedFileURL.resolvingSymlinksInPath()
        guard workspace != root else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        let old = server, previous = transition
        server = nil; renderer.stop(); renderer = PreviewWebRenderer()
        workspace = root; currentURL = nil; error = nil; state = .idle
        let memory = root.flatMap { memories[$0.path] }
        address = memory?.url?.absoluteString ?? ""; device = memory?.device ?? defaultDevice
        usesEnteredURL = memory?.usesEnteredURL ?? false
        configureRenderer()
        transition = Task {
            let earlier = await previous?.value ?? true
            if let old { let stopped = await self.devServers.stop(old); return earlier && stopped }
            return earlier
        }
    }
    func ensureStarted() { if state == .idle { start() } }
    func start() {
        guard let root = workspace, !shuttingDown, !busy else { return }
        let token = UUID(); generation = token
        operation?.cancel(); error = nil; state = .starting
        operation = Task { [weak self] in
            guard let self else { return }
            var attemptedLaunch = false
            do {
                guard await self.transition?.value ?? true else { throw AgentError.message("An owned Preview server could not stop. Try Stop again before starting.") }
                try self.check(token)
                if let existing = self.server, !existing.groupGone {
                    guard existing.state == .running, let url = existing.detectedURL, await PreviewURL.reachable(url) else {
                        throw AgentError.message("The managed server is not reachable. Stop it before restarting.")
                    }
                    try self.check(token); self.load(url); return
                }
                let memory = self.memories[root.path]
                if self.usesEnteredURL, let url = memory?.url ?? self.currentURL {
                    self.load(url); return
                }
                // A remembered live endpoint is external unless we still own its current-run group.
                if let url = memory?.url, !url.isFileURL, PreviewURL.local(url), await PreviewURL.reachable(url) {
                    try self.check(token); self.load(url); return
                }
                let selected = self.selectedHTML?()
                var config = memory?.configuration
                if config == nil {
                    config = try await Task.detached(priority: .userInitiated) { try PreviewDetector.detect(root: root, selectedHTML: selected) }.value
                }
                try self.check(token)
                if config == nil {
                    guard let assist = self.assist else { throw AgentError.message("No Preview command found. Enter a running project URL or configure Pi to inspect this project.") }
                    config = try await assist(root)
                }
                try self.check(token)
                guard var config, WorkspaceFileService.isInside(config.directory, root: root, resolve: true), !config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.message("Preview needs a command with a working directory inside this workspace.") }
                guard let authorize = self.authorize else { throw AgentError.message("Preview permission service is unavailable.") }
                config = try await authorize(config)
                try self.check(token)
                // A suggested port already occupied before launch cannot prove this new server is ready.
                let hintWasFree: Bool
                if let hint = config.suggestedURL { hintWasFree = !(await PreviewURL.reachable(hint)) }
                else { hintWasFree = false }
                try self.check(token)
                attemptedLaunch = true
                let owned = try self.devServers.launch(config, workspace: root)
                self.server = owned
                self.state = .waiting; self.publishOutput(owned)
                // Prefer log output, including an alternate port, over any Pi-suggested endpoint.
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline {
                    try self.check(token)
                    guard owned.state == .running else { throw AgentError.message("Preview server exited before becoming ready.") }
                    let reported = PreviewURL.detected(in: owned.stdout + "\n" + owned.stderr).reversed()
                    var candidates = Array(reported)
                    if hintWasFree, let hint = config.suggestedURL, PreviewURL.local(hint), candidates.isEmpty { candidates.append(hint) }
                    for url in candidates.prefix(8) {
                        if await PreviewURL.reachable(url) {
                            try self.check(token)
                            owned.detectedURL = url
                            var target = url
                            if config.kind == .staticFiles { target = url.appendingPathComponent(config.entryPath) }
                            else if let remembered = memory?.url, remembered.host == target.host, remembered.port == target.port { target = remembered }
                            self.usesEnteredURL = false
                            self.remember(configuration: config)
                            self.publishOutput(owned, status: .completed); self.load(target); return
                        }
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                throw AgentError.message("Preview server did not report a reachable local URL within 45 seconds. Check its output in Chat, then restart.")
            } catch is CancellationError {
                if self.generation == token { self.state = .stopped }
            }
            catch {
                guard self.generation == token else { return }
                if let owned = self.server { self.publishOutput(owned, status: .error); if await self.devServers.stop(owned) { self.server = nil } }
                guard self.generation == token else { return }
                if attemptedLaunch {
                    self.memories[root.path]?.configuration = nil
                    self.saveMemories()
                }
                self.fail(error.localizedDescription)
            }
        }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); if generation != token || shuttingDown { throw CancellationError() } }
    func navigate() {
        guard workspace != nil else { fail("Open a project before loading Preview."); return }
        do {
            let url = try PreviewURL.parse(address, workspace: workspace)
            if url.isFileURL, let root = workspace {
                guard !managed else { throw AgentError.message("Stop the current server before previewing another HTML file.") }
                usesEnteredURL = false
                remember(configuration: PreviewDetector.staticConfiguration(root: root, entry: url))
                start(); return
            }
            generation = UUID(); operation?.cancel(); error = nil
            usesEnteredURL = !(server?.detectedURL.map { $0.host == url.host && $0.port == url.port } ?? false)
            requestPage(url) // Entered endpoints do not grant process ownership.
        } catch { fail(error.localizedDescription) }
    }
    private func load(_ url: URL) { currentURL = url; address = url.absoluteString; state = .loading; error = nil; renderer.load(url) }
    private func requestPage(_ url: URL, reload: Bool = false) {
        generation = UUID(); let token = generation
        operation?.cancel(); error = nil; state = .loading
        operation = Task { [weak self] in
            guard let self else { return }
            if PreviewURL.local(url), !(await PreviewURL.reachable(url)) {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail("Preview URL is not reachable. Check the address or start its server."); return
            }
            guard self.generation == token, !Task.isCancelled else { return }
            if reload { self.renderer.reload() } else { self.load(url) }
        }
    }
    func reload() { guard let currentURL, !busy else { return }; requestPage(currentURL, reload: true) }
    func openExternally() { if let currentURL { NSWorkspace.shared.open(currentURL) } }
    func selectDevice(_ value: PreviewDevice) { device = value; remember() }
    func stop() {
        generation = UUID(); let token = generation
        operation?.cancel(); renderer.stop(); state = .stopped; error = nil
        let owned = server
        let previous = transition
        transition = Task {
            let earlier = await previous?.value ?? true
            let gone = if let owned { await self.devServers.stop(owned) } else { true }
            guard self.generation == token else { return earlier && gone }
            if gone { self.server = nil; if let owned { self.publishOutput(owned, status: .cancelled) } }
            else { self.fail("Preview could not confirm that its process group stopped. Try Stop again.") }
            return gone
        }
    }
    func shutdown() async -> Bool {
        await withCheckedContinuation { continuation in shutdownForTermination { continuation.resume(returning: $0) } }
    }
    func shutdownForTermination(completion: @escaping (Bool) -> Void) {
        shuttingDown = true; generation = UUID(); operation?.cancel(); renderer.stop()
        devServers.shutdown { gone in
            if gone { self.server = nil; self.state = .stopped }
            completion(gone)
        }
    }
    private func configureRenderer() {
        renderer.workspace = workspace
        renderer.onLoading = { [weak self] in guard let self, self.state != .stopped, self.state != .failed else { return }; self.state = .loading }
        renderer.onFinished = { [weak self] url in
            guard let self, self.state != .stopped, self.state != .failed else { return }
            self.currentURL = url; self.address = url.absoluteString; self.state = .running; self.error = nil; self.remember(url: url)
        }
        renderer.onFailure = { [weak self] in self?.fail($0) }
    }
    private func remember(url: URL? = nil, configuration: PreviewConfiguration? = nil) {
        guard let workspace else { return }
        var value = memories[workspace.path] ?? PreviewMemory()
        if let url { value.url = url }
        value.device = device
        value.usesEnteredURL = usesEnteredURL
        if let configuration { value.configuration = configuration }
        memories[workspace.path] = value
        saveMemories()
    }
    private func saveMemories() {
        if persist, let data = try? JSONEncoder().encode(memories) { defaults.set(data, forKey: "Milk.preview.v1") }
    }
    private func publishOutput(_ owned: ManagedPreviewServer, status: AgentActivity.Status? = nil) {
        onActivity?("preview-" + owned.id.uuidString, owned.startupCommand + "\nIn: " + owned.configuration.directory.path + "\n\n" + owned.stdout + (owned.stderr.isEmpty ? "" : "\n[stderr]\n" + owned.stderr), status ?? (owned.state == .running ? .running : .error))
    }
    private func fail(_ message: String) { error = message; state = .failed }
}
