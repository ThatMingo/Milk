import Foundation
import Darwin

struct SavedAgentSession: Identifiable, Equatable {
    var id: String { agentID.rawValue + ":" + path }
    var path: String
    var title: String
    var modified: Date
    var agentID: AgentID = .pi
    var milkID: UUID? = nil
    var nativeID: String? = nil
    var workspace: URL? = nil
}

/// Reads vanilla Pi's saved JSONL headers. Session content is restored through RPC.
struct PiSessionService: AgentFileSessionHistory {
    /// Pi 1.4.0 docs/session-format.md explicitly permits deleting saved JSONL files.
    /// Its session-selector.ts uses unlink as the permanent-delete mechanism.
    /// Accept only a regular, unlinked-to-other-files session in the runtime-reported directory,
    /// with a real Pi header for this workspace; never follow a supplied file symlink.
    func validateDeletion(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws {
        let url = URL(fileURLWithPath: saved.path).standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.pathExtension == "jsonl", attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AgentError.message("Delete is limited to regular saved Pi sessions in the active session directory.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // A header is small. Refuse malformed/oversized headers instead of guessing at ownership.
        let data = try file.read(upToCount: 64 * 1024) ?? Data()
        guard let end = data.firstIndex(of: 10),
              let header = try? JSONDecoder().decode(JSONValue.self, from: Data(data[..<end])),
              header["type"].string == "session", header["id"].string?.isEmpty == false,
              let version = header["version"].number, [1.0, 2.0, 3.0].contains(version),
              let cwd = header["cwd"].string,
              URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AgentError.message("The file is not a supported saved Pi session for this workspace. Its history was not deleted.")
        }
    }
    func delete(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws {
        try validateDeletion(saved, workspace: workspace, directory: directory)
        // unlink cannot recursively remove a directory if the path changes after validation.
        guard unlink(saved.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func history(workspace: URL, directory: URL) throws -> [SavedAgentSession] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            // Session trees can be large; bounded decoding avoids loading their transcript into the UI.
            var cwd: String?, name: String?, firstPrompt: String?, nativeID: String?
            for line in data.split(separator: 10) {
                guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
                if record["type"].string == "session" { cwd = record["cwd"].string; nativeID = record["id"].string }
                if record["type"].string == "session_info", let title = record["name"].string { name = title }
                if firstPrompt == nil, record["message"]["role"].string == "user" { firstPrompt = String(record["message"]["content"].text.prefix(70)) }
            }
            guard cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() }) == true else { return nil }
            return .init(path: url.resolvingSymlinksInPath().path, title: name ?? firstPrompt ?? url.deletingPathExtension().lastPathComponent,
                         modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast, nativeID: nativeID, workspace: workspace)
        }.sorted { $0.modified > $1.modified }
    }
    func availability(_ session: AgentSession, workspace: URL) -> SessionAvailability {
        guard let path = session.sessionFile else { return .init() }
        guard FileManager.default.fileExists(atPath: path) else { return .init(state: .missingData, detail: "The saved Pi session file is missing.") }
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
            let data = try file.read(upToCount: 64 * 1024) ?? Data()
            guard let end = data.firstIndex(of: 10),
                  let header = try? JSONDecoder().decode(JSONValue.self, from: Data(data[..<end])),
                  header["type"].string == "session", let cwd = header["cwd"].string else {
                return .init(state: .invalidData, detail: "The saved Pi session header is invalid.")
            }
            guard let version = header["version"].number, [1.0,2.0,3.0].contains(version) else {
                return .init(state: .unsupportedFormat, detail: "This Pi session format is not supported; its data is retained.")
            }
            guard SessionWorkspace(URL(fileURLWithPath: cwd)) == SessionWorkspace(workspace) else {
                return .init(state: .workspaceUnavailable, detail: "Open the session's owning project to resume it.")
            }
            return .init()
        } catch { return .init(state: .missingData, detail: "The saved Pi session cannot be read: " + error.localizedDescription) }
    }
    static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !path.isEmpty { return URL(fileURLWithPath: path).appendingPathComponent("sessions") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")
    }
}

/// File snapshots feed the inline change summary without introducing Phase 4 Git operations.
struct AgentFileSnapshot {
    var files: [String: Data]
    var limited: Bool
    static func capture(root: URL) throws -> Self {
        let tree = FileTreeService()
        var folders = [root], files: [String: Data] = [:], bytes = 0, visited = 0, limited = false
        while let folder = folders.popLast() {
            let rel = folder.path == root.path ? "" : String(folder.path.dropFirst(root.path.count + 1))
            // Reuse the explorer's traversal and ignore rules, including ancestors.
            var ancestors: [FileTreeService.IgnoreRule] = []; var parent = root
            ancestors += FileTreeService.rules(at: parent, base: "")
            if !rel.isEmpty {
                for part in rel.split(separator: "/").dropLast() {
                    parent.appendPathComponent(String(part))
                    ancestors += FileTreeService.rules(at: parent, base: String(parent.path.dropFirst(root.path.count + 1)))
                }
            }
            let rows = try tree.children(root: root, folder: folder, depth: 0, inherited: ancestors, hidden: false, ignored: false)
            for node in rows {
                visited += 1
                if visited > 20000 { limited = true; return .init(files: files, limited: limited) }
                if node.isDirectory { folders.append(node.url); continue }
                guard !node.isSymbolicLink else { continue }
                if files.count >= 10000 || bytes >= 64 * 1024 * 1024 { limited = true; continue }
                let size = (try? node.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                guard size <= 1024 * 1024, let data = try? Data(contentsOf: node.url), String(data: data, encoding: .utf8) != nil else { limited = true; continue }
                files[String(node.url.path.dropFirst(root.path.count + 1))] = data; bytes += data.count
            }
        }
        return .init(files: files, limited: limited)
    }
    func changes(to after: Self) -> [AgentFileChange] {
        Set(files.keys).union(after.files.keys).sorted().compactMap { path in
            let before = files[path], next = after.files[path]
            guard before != next else { return nil }
            // Partial snapshots must never invent creates/deletes for files outside their coverage.
            if (before == nil && limited) || (next == nil && after.limited) { return nil }
            func lines(_ data: Data?) -> [String] {
                guard let data, !data.isEmpty else { return [] }
                var values = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                if values.last == "" { values.removeLast() }; return values
            }
            let a = lines(before), b = lines(next)
            var added: Int?, removed: Int?
            if a.count + b.count <= 10000 {
                let diff = b.difference(from: a)
                added = diff.insertions.count; removed = diff.removals.count
            }
            return .init(path: path, kind: before == nil ? "Created" : next == nil ? "Deleted" : "Modified", added: added, removed: removed)
        }
    }
}
