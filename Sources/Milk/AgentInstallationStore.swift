import Foundation
import Darwin
import Combine

struct ManagedPiVersion: Codable, Equatable, Identifiable {
    var id: AgentInstallationID { installation.id }
    let installation: AgentInstallationRecord
    let directoryName: String
    let release: PiCatalogRelease
    let installedAt: Date
    let inventory: [String: String]
    var health: AgentCompatibilityResult
    var checkedAt: Date
}
struct ExternalAgentInstallation: Codable, Equatable {
    let installation: AgentInstallationRecord
    var health: AgentCompatibilityResult
    var checkedAt: Date
}
struct AgentInstallationOperation: Codable, Equatable {
    enum Stage: String, Codable { case downloading, extracting, verifying, probing, staged, completed, failed, interrupted }
    let id: UUID
    let action: String
    let version: String?
    var stage: Stage
    var detail: String
    var updatedAt = Date()
}
struct PiInstallationState: Codable, Equatable {
    var schemaVersion = 1
    var managed: [ManagedPiVersion] = []
    var external: [ExternalAgentInstallation] = []
    /// nil is deliberate no-runtime when useLegacyRuntime is false.
    var selected: AgentInstallationID?
    var pending: AgentInstallationID?
    var previous: AgentInstallationID?
    var useLegacyRuntime = true
    var autoUpdate = false
    var operation: AgentInstallationOperation?
    var removals: [ManagedPiVersion] = []
}

/// Persistent code metadata only. Never stores environments, tokens or Pi user data.
/// A lifetime advisory lock excludes a second Milk manager/runtime user of this root.
@MainActor final class AgentInstallationStore: ObservableObject {
    let root: URL
    @Published private(set) var state = PiInstallationState()
    private(set) var loadProblem: String?
    private var original: Data?
    private var lockFD: Int32 = -1
    var file: URL { root.appendingPathComponent("state.json") }
    var versions: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    init(root: URL? = nil) {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Milk/Agents/pi", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        do { try reload() } catch { loadProblem = error.localizedDescription }
    }
    private func reload() throws {
        if !FileManager.default.fileExists(atPath: file.path) { return }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AgentError.message("Installation state cannot be a symlink.") }
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode(PiInstallationState.self, from: data)
        guard decoded.schemaVersion == 1 else { throw AgentError.message("Unsupported installation state; original bytes were retained.") }
        for version in decoded.managed + decoded.removals { _ = try directory(for: version) }
        guard (decoded.managed + decoded.removals).allSatisfy({ $0.installation.ownership == .milkManaged && $0.installation.agentID == .pi }),
              decoded.external.allSatisfy({ $0.installation.ownership == .external && $0.installation.agentID == .pi }),
              Set((decoded.managed.map(\.id) + decoded.external.map { $0.installation.id })).count == decoded.managed.count + decoded.external.count else {
            throw AgentError.message("Invalid installation ownership/identity metadata; state was retained.")
        }
        state = decoded; original = data
    }
    func directory(for value: ManagedPiVersion) throws -> URL {
        guard UUID(uuidString: value.directoryName) != nil else { throw AgentError.message("Invalid managed runtime directory identity.") }
        let directory = versions.appendingPathComponent(value.directoryName).appendingPathComponent("runtime")
        guard value.installation.executable.standardizedFileURL == directory.appendingPathComponent("pi").standardizedFileURL else { throw AgentError.message("Managed installation path escapes its owned directory.") }
        return directory
    }
    func acquire() throws {
        if let loadProblem { throw AgentError.message("Installation store is unavailable: " + loadProblem) }
        if lockFD >= 0 { return }
        for path in [root, versions, staging] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try rejectLinks(path)
        }
        let fd = open(root.appendingPathComponent(".lock").path, O_RDWR|O_CREAT|O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentError.message("Cannot open installation ownership lock.") }
        guard flock(fd, LOCK_EX|LOCK_NB) == 0 else { close(fd); throw AgentError.message("Another Milk instance owns this Pi installation. Close it before managing or using managed Pi.") }
        lockFD = fd
        do { try reload() } catch { loadProblem = error.localizedDescription; throw error }
    }
    func rejectLinks(_ url: URL) throws {
        // Validate the owned subtree, including its root. macOS system ancestors
        // (/var, /tmp) have legitimate aliases; they are not archive-controlled.
        var cursor = url.standardizedFileURL.path
        let boundary = root.standardizedFileURL.path
        guard cursor == boundary || cursor.hasPrefix(boundary + "/") else { throw AgentError.message("Path is outside the managed installation root.") }
        while !cursor.isEmpty {
            var info = stat()
            if lstat(cursor, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw AgentError.message("Managed installation paths cannot traverse symbolic links: " + cursor) }
            if cursor == boundary { break }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
    }
    func commit(_ edit: (inout PiInstallationState) throws -> Void) throws {
        try acquire()
        let current = try? Data(contentsOf: file)
        guard current == original else { throw AgentError.message("Installation state changed outside this manager; reopen Milk before retrying.") }
        var next = state; try edit(&next)
        let bytes = try JSONEncoder().encode(next)
        try bytes.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY|O_NOFOLLOW); if fd >= 0 { fsync(fd); close(fd) }
        let parent = open(root.path, O_RDONLY|O_DIRECTORY); if parent >= 0 { fsync(parent); close(parent) }
        original = bytes; state = next
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
}
