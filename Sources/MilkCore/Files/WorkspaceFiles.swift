import Foundation
import CoreServices

public struct FileEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileEntry]?
}
public actor FileService {
    public init() {}
    public func children(of directory: URL, depth: Int = 0) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values.isDirectory == true
            let descend = isDirectory && values.isSymbolicLink != true && depth < 2 && !["node_modules", ".build", "DerivedData"].contains(url.lastPathComponent)
            return FileEntry(url: url, isDirectory: isDirectory, children: descend ? try? children(of: url, depth: depth + 1) : nil)
        }.sorted { if $0.isDirectory != $1.isDirectory { return $0.isDirectory }; return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func save(_ data: Data, at url: URL, expected: Data?) throws {
        let disk = try? Data(contentsOf: url)
        guard disk == expected else { throw MilkError.message("File changed on disk. Compare versions before saving.") }
        try data.write(to: url, options: .atomic)
    }
    public func createFile(at url: URL) throws { guard !FileManager.default.fileExists(atPath: url.path) else { throw MilkError.message("File already exists") }; try Data().write(to: url, options: .withoutOverwriting) }
    public func move(_ source: URL, to target: URL) throws { try FileManager.default.moveItem(at: source, to: target) }
    public func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
}

public final class WorkspaceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable () -> Void
    public init(folder: URL, changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "Milk.filesystem.events")); FSEventStreamStart(stream) }
    }
    public func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
    deinit { stop() }
}

public struct SearchMatch: Identifiable, Sendable {
    public var id: String { "\(path):\(line):\(text)" }
    public let path: String
    public let line: Int
    public let text: String
}
public actor SearchService {
    public init() {}
    public func search(_ query: String, in directory: URL, regex: Bool = false, caseSensitive: Bool = false) async throws -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let locations = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        guard let rg = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MilkError.message("ripgrep not found; configure a search executable") }
        var args = ["--json", "--max-count", "200", "--glob", "!.git", "--glob", "!node_modules", "--glob", "!.build"]
        if !regex { args.append("--fixed-strings") }; if !caseSensitive { args.append("--ignore-case") }
        args += ["--", query, "."]
        let result = try await CommandRunner.run(.init(executable: URL(fileURLWithPath: rg), arguments: args, directory: directory))
        guard result.status <= 1 else { throw MilkError.message("Search failed; check the regular expression") }
        var framer = JSONLFramer()
        return try framer.append(result.output).compactMap { record in
            guard record["type"].string == "match", let path = record["data"]["path"]["text"].string else { return nil }
            let value = record["data"]["line_number"]
            guard case .number(let line) = value else { return nil }
            return SearchMatch(path: path, line: Int(line), text: record["data"]["lines"]["text"].string?.trimmingCharacters(in: .newlines) ?? "")
        }
    }
}
