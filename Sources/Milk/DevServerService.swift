import Foundation
import Darwin

/// Only these directories are eligible for cleanup. No project paths are accepted by cleanup.
final class PreviewTemporaryFiles {
    struct Marker: Codable { var owner = "dev.milk.preview.v1"; var uid = getuid(); var pid = getpid() }
    let base: URL
    let run: URL
    init(base: URL = FileManager.default.temporaryDirectory.appendingPathComponent("dev.milk/Preview-v1", isDirectory: true)) throws {
        self.base = base
        run = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try base.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              (try FileManager.default.attributesOfItem(atPath: base.path)[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw AgentError.message("Preview temporary location is not owned by this user.") }
        Self.cleanStale(in: base)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Marker()).write(to: run.appendingPathComponent("milk-owner.json"), options: .atomic)
    }
    static func cleanStale(in base: URL) {
        let fm = FileManager.default
        guard (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        for child in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: child.appendingPathComponent("milk-owner.json")),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.owner == "dev.milk.preview.v1", marker.uid == getuid(), marker.pid > 1,
                  kill(marker.pid, 0) == -1, errno == ESRCH else { continue }
            try? fm.removeItem(at: child) // Never signal recorded PIDs from an earlier launch.
        }
    }
    func makeServerDirectory() throws -> URL {
        let directory = run.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func removeServerDirectory(_ directory: URL) {
        guard directory.deletingLastPathComponent() == run, UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    func cleanup() { try? FileManager.default.removeItem(at: run) }
}

@MainActor final class ManagedPreviewServer {
    enum State: String { case running, stopping, stopped, failed }
    let id = UUID()
    let pid: pid_t
    let group: pid_t
    let workspace: URL
    let configuration: PreviewConfiguration
    let startupCommand: String
    let started = Date()
    let temporaryDirectory: URL
    var state: State = .running
    var stdout = ""
    var stderr = ""
    var detectedURL: URL?
    var detectedPort: Int? { detectedURL?.port }
    var exitStatus: Int32?
    var groupGone = false
    var stopInProgress = false
    var stopCallbacks: [(Bool) -> Void] = []
    init(pid: pid_t, workspace: URL, configuration: PreviewConfiguration, command: String, temporaryDirectory: URL) {
        self.pid = pid; group = pid; self.workspace = workspace; self.configuration = configuration; startupCommand = command; self.temporaryDirectory = temporaryDirectory
    }
}

/// Uses posix_spawn's atomic process-group creation, never port/name/cwd-based process discovery.
/// Foreground dev scripts and their descendants inherit this group. Daemonizing scripts are unsupported.
@MainActor final class DevServerService {
    private(set) var servers: [UUID: ManagedPreviewServer] = [:]
    private(set) var lastServer: ManagedPreviewServer?
    private var temporary: PreviewTemporaryFiles?
    private var temporaryError: Error?
    var onOutput: ((ManagedPreviewServer) -> Void)?
    var onExit: ((ManagedPreviewServer) -> Void)?
    let helperExecutable: URL
    init(helperExecutable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]), temporaryBase: URL? = nil) {
        self.helperExecutable = helperExecutable
        do { temporary = try temporaryBase.map { try PreviewTemporaryFiles(base: $0) } ?? PreviewTemporaryFiles() }
        catch { temporaryError = error }
    }
    func launch(_ configuration: PreviewConfiguration, workspace: URL) throws -> ManagedPreviewServer {
        guard WorkspaceFileService.isInside(configuration.directory, root: workspace, resolve: true),
              (try? configuration.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AgentError.message("Preview working directory must remain inside this workspace.") }
        guard let temporary else { throw temporaryError ?? AgentError.message("Preview temporary storage is unavailable.") }
        guard !servers.values.contains(where: { $0.workspace == workspace && !$0.groupGone }) else { throw AgentError.message("This workspace already has a managed Preview server.") }
        let directory = try temporary.makeServerDirectory()
        let command = configuration.kind == .staticFiles
            ? "exec " + PreviewDetector.shellQuote(helperExecutable.path) + " --milk-static-server " + PreviewDetector.shellQuote(configuration.directory.path)
            : configuration.command
        let output = Pipe(), errors = Pipe()
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir(&actions, configuration.directory.path)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var env = ProcessInfo.processInfo.environment
        // GUI launches don't inherit a user's interactive PATH. Login zsh resolves version-manager setup.
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        env["NO_COLOR"] = "1"; env["BROWSER"] = "none"; env["MILK_PREVIEW_ID"] = directory.lastPathComponent
        let arguments: [String] = ["/bin/zsh", "-l", "-c", "cd -- " + PreviewDetector.shellQuote(configuration.directory.path) + " && " + command]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { value in value.withCString { strdup($0) } } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { pair in (pair.key + "=" + pair.value).withCString { strdup($0) } } + [nil]
        defer { for p in argv + envp { if let p { free(p) } } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            posix_spawn(&pid, "/bin/zsh", &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        guard code == 0 else { temporary.removeServerDirectory(directory); throw AgentError.message("Preview launch failed: \(String(cString: strerror(code))).") }
        let server = ManagedPreviewServer(pid: pid, workspace: workspace, configuration: configuration, command: command, temporaryDirectory: directory)
        servers[server.id] = server; lastServer = server
        try? JSONEncoder().encode(["pid": String(pid), "group": String(pid), "workspace": workspace.path, "cwd": configuration.directory.path, "command": command, "started": server.started.description]).write(to: directory.appendingPathComponent("server.json"), options: .atomic)
        read(output.fileHandleForReading, server: server, stderr: false)
        read(errors.fileHandleForReading, server: server, stderr: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
            Task { @MainActor in
                guard let self else { return }
                server.exitStatus = status
                if server.state == .running {
                    server.state = .failed
                    // A launcher may exit leaving children. They remain ours and must be stopped.
                    _ = await self.stop(server)
                    self.onExit?(server)
                }
            }
        }
        return server
    }
    private func read(_ handle: FileHandle, server: ManagedPreviewServer, stderr: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? handle.close() }
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                Task { @MainActor in
                    guard let self else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    if stderr { server.stderr = String((server.stderr + text).suffix(131072)) }
                    else { server.stdout = String((server.stdout + text).suffix(131072)) }
                    self.onOutput?(server)
                }
            }
        }
    }
    @discardableResult func stop(_ server: ManagedPreviewServer) async -> Bool {
        await withCheckedContinuation { continuation in stop(server) { continuation.resume(returning: $0) } }
    }
    private func stop(_ server: ManagedPreviewServer, completion: @escaping (Bool) -> Void) {
        if server.groupGone { completion(true); return }
        server.stopCallbacks.append(completion)
        guard !server.stopInProgress else { return }
        server.stopInProgress = true
        let failed = server.state == .failed, group = server.group
        server.state = .stopping
        // The OS work also runs during AppKit's termination negotiation. It never blocks the UI
        // or relies on a Swift task resuming inside AppKit's termination/modal run loop.
        DispatchQueue.global(qos: .userInitiated).async {
            func alive() -> Bool { kill(-group, 0) == 0 || errno == EPERM }
            if alive() { kill(-group, SIGTERM) }
            for _ in 0..<25 {
                if !alive() { break }
                usleep(40_000)
            }
            if alive() { kill(-group, SIGKILL) }
            for _ in 0..<50 {
                if !alive() { break }
                usleep(20_000)
            }
            let gone = !alive()
            DispatchQueue.main.async {
                server.groupGone = gone
                server.state = failed || !gone ? .failed : .stopped
                if gone {
                    self.servers[server.id] = nil
                    self.temporary?.removeServerDirectory(server.temporaryDirectory)
                }
                server.stopInProgress = false
                let callbacks = server.stopCallbacks; server.stopCallbacks = []
                for callback in callbacks { callback(gone) }
            }
        }
    }
    func shutdown() async -> Bool {
        await withCheckedContinuation { continuation in shutdown { continuation.resume(returning: $0) } }
    }
    /// Callback form is used by NSApplication's terminateLater handshake.
    func shutdown(completion: @escaping (Bool) -> Void) {
        let owned = Array(servers.values)
        guard !owned.isEmpty else { temporary?.cleanup(); completion(true); return }
        var remaining = owned.count, allGone = true
        for server in owned {
            stop(server) { gone in
                allGone = allGone && gone; remaining -= 1
                if remaining == 0 {
                    if allGone { self.temporary?.cleanup() }
                    completion(allGone)
                }
            }
        }
    }
}
