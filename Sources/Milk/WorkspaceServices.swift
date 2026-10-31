import Foundation
import CoreServices
import CryptoKit

/// Enumerates only visible expanded branches. Symlink directories are never followed.
struct FileTreeService {
    static let generated: Set<String> = [".git", ".build", "node_modules", "vendor", "Pods", "DerivedData", ".next", "dist", "build", ".venv", "__pycache__"]
    struct IgnoreRule {
        let base: String
        let pattern: String
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool
        func matches(_ relative:String, directory:Bool) -> Bool {
            guard base.isEmpty || relative.hasPrefix(base+"/") else { return false }
            let local=base.isEmpty ? relative:String(relative.dropFirst(base.count+1))
            let parts=local.split(separator:"/").map(String.init)
            let candidates=anchored || pattern.contains("/") ? [local]:parts
            let expression=Self.glob(pattern)
            return candidates.enumerated().contains { index,candidate in
                if directoryOnly && !directory && (candidates.count == 1 || index == candidates.count-1) { return false }
                return candidate.range(of:expression,options:.regularExpression) != nil
            }
        }
        static func glob(_ glob:String) -> String {
            var result="^"; var i=glob.startIndex
            while i<glob.endIndex {
                let c=glob[i]; let next=glob.index(after:i)
                if c == "*" {
                    if next<glob.endIndex && glob[next] == "*" {
                        let end=glob.index(after:next)
                        if end<glob.endIndex && glob[end] == "/" { result += "(?:.*/)?"; i=glob.index(after:end); continue }
                        result += ".*"; i=end; continue
                    }
                    result += "[^/]*"
                } else if c == "?" { result += "[^/]" }
                else { result += NSRegularExpression.escapedPattern(for:String(c)) }
                i=next
            }
            return result+"$"
        }
    }
    static func rules(at folder:URL, base:String) -> [IgnoreRule] {
        guard let text=try? String(contentsOf:folder.appendingPathComponent(".gitignore"),encoding:.utf8) else { return [] }
        return text.components(separatedBy:.newlines).compactMap { line in
            var p=line.trimmingCharacters(in:.whitespaces)
            guard !p.isEmpty, !p.hasPrefix("#") else { return nil }
            let negated=p.hasPrefix("!"); if negated { p.removeFirst() }
            let directory=p.hasSuffix("/"); if directory { p.removeLast() }
            let anchored=p.hasPrefix("/"); if anchored { p.removeFirst() }
            if p.hasPrefix("\\#") || p.hasPrefix("\\!") { p.removeFirst() }
            guard !p.isEmpty else { return nil }
            return IgnoreRule(base:base,pattern:p,negated:negated,directoryOnly:directory,anchored:anchored)
        }
    }
    func children(root:URL, folder:URL, depth:Int, inherited:[IgnoreRule], hidden:Bool, ignored:Bool, parentIgnored:Bool = false) throws -> [FileNode] {
        let base=folder.path == root.path ? "":String(folder.path.dropFirst(root.path.count+1))
        let rules=inherited+Self.rules(at:folder,base:base)
        let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isHiddenKey],options:[])
        var children:[FileNode]=[]
        for rawURL in urls {
            let v=try rawURL.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isHiddenKey])
            let url=folder.appendingPathComponent(rawURL.lastPathComponent,isDirectory:v.isDirectory == true && v.isSymbolicLink != true)
            if !hidden && (v.isHidden == true || url.lastPathComponent.hasPrefix(".")) { continue }
            let dir=v.isDirectory == true && v.isSymbolicLink != true
            let rel=String(url.path.dropFirst(root.path.count+1))
            var excluded=parentIgnored || Self.generated.contains(url.lastPathComponent)
            for rule in rules where rule.matches(rel,directory:dir) { excluded = !rule.negated }
            if excluded && !ignored { continue }
            children.append(.init(url:url,isDirectory:dir,isSymbolicLink:v.isSymbolicLink == true,depth:depth,isIgnored:excluded))
        }
        children.sort { a,b in a.isDirectory != b.isDirectory ? a.isDirectory:a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return children
    }
    func scan(root:URL, expanded:Set<String>, hidden:Bool, ignored:Bool) throws -> [FileNode] {
        var rows:[FileNode]=[]
        func visit(_ folder:URL, depth:Int, inherited:[IgnoreRule], parentIgnored:Bool) throws {
            let base=String(folder.path.dropFirst(root.path.count)).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            let rules=inherited+Self.rules(at:folder,base:base)
            let children=try self.children(root:root,folder:folder,depth:depth,inherited:inherited,hidden:hidden,ignored:ignored,parentIgnored:parentIgnored)
            for node in children {
                rows.append(node)
                if node.isDirectory && expanded.contains(node.id) {
                    // Even generated directories are read only on explicit expansion.
                    do { try visit(node.url,depth:depth+1,inherited:rules,parentIgnored:node.isIgnored) }
                    catch { /* An unreadable child must not hide the rest of the workspace. */ }
                }
            }
        }
        try visit(root,depth:0,inherited:[],parentIgnored:false)
        return rows
    }
}

/// A recursive FSEvents stream observes the workspace without crawling its contents.
final class WorkspaceWatcher {
    private var stream: FSEventStreamRef?
    var onChange: (([String])->Void)?
    init(url:URL, onChange:@escaping ([String])->Void) {
        self.onChange=onChange
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback:FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let owner=Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            let values=unsafeBitCast(paths,to:NSArray.self) as? [String] ?? []
            owner.onChange?(Array(values.prefix(count)))
        }
        stream=FSEventStreamCreate(nil,callback,&context,[url.path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.25,FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream,.main); FSEventStreamStart(stream) }
    }
    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream=nil; onChange=nil
    }
    deinit { stop() }
}

final class WorkspacePersistence {
    let defaults: UserDefaults
    let directory: URL
    let enabled: Bool
    init(defaults:UserDefaults = .standard, directory:URL? = nil, enabled:Bool = true) {
        self.defaults=defaults; self.enabled=enabled
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Milk/Workspaces",isDirectory:true)
    }
    var recent: [URL] {
        get { (defaults.stringArray(forKey:"Milk.workspaces.recent.v1") ?? []).map { URL(fileURLWithPath:$0) } }
        set { if enabled { defaults.set(newValue.map(\.path),forKey:"Milk.workspaces.recent.v1") } }
    }
    var last: URL? {
        get { defaults.string(forKey:"Milk.workspaces.last.v1").map { URL(fileURLWithPath:$0) } }
        set { if enabled { defaults.set(newValue?.path,forKey:"Milk.workspaces.last.v1") } }
    }
    var active: URL? {
        get { defaults.string(forKey:"Milk.workspaces.active.v1").map { URL(fileURLWithPath:$0) } }
        set { if enabled { defaults.set(newValue?.path,forKey:"Milk.workspaces.active.v1") } }
    }
    func snapshotURL(_ root:URL) -> URL {
        let key=SHA256.hash(data:Data(root.path.utf8)).map { String(format:"%02x",$0) }.joined()
        return directory.appendingPathComponent(key+".json")
    }
    func load(_ root:URL) -> WorkspaceSnapshot? {
        guard enabled, let data=try? Data(contentsOf:snapshotURL(root)),let value=try? JSONDecoder().decode(WorkspaceSnapshot.self,from:data),value.version == 1 else { return nil }
        return value
    }
    func save(_ snapshot:WorkspaceSnapshot, root:URL) throws {
        guard enabled else { return }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=snapshotURL(root)
        // Preserve the complete old Milk recovery file before the first agent v4 write.
        if let payload = snapshot.shellSessions,
           let header = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], header["version"] as? Int == 4,
           let oldData = try? Data(contentsOf: file),
           let old = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: oldData),
           old.shellSessions.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["version"] as? Int != 4 {
            let backup = file.appendingPathExtension("before-agent-v4")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try oldData.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try JSONEncoder().encode(snapshot).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}

enum WorkspaceFileService {
    static func isInside(_ url:URL, root:URL, resolve:Bool = false) -> Bool {
        let path=(resolve ? url.resolvingSymlinksInPath():url.standardizedFileURL).path
        let base=(resolve ? root.resolvingSymlinksInPath():root.standardizedFileURL).path
        return path == base || path.hasPrefix(base == "/" ? "/":base+"/")
    }
    static func child(named name:String, in folder:URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw WorkspaceError.message("Enter a file or folder name without / or :.")
        }
        return folder.appendingPathComponent(name)
    }
    static func availableCopy(of source:URL, in folder:URL) -> URL {
        let ext=source.pathExtension, stem=source.deletingPathExtension().lastPathComponent
        var index=1
        while true {
            let suffix=index == 1 ? " copy":" copy \(index)"
            let candidate=folder.appendingPathComponent(stem+suffix+(ext.isEmpty ? "":"."+ext))
            if !FileManager.default.fileExists(atPath:candidate.path) { return candidate }
            index += 1
        }
    }
    static func safeSave(_ data:Data, to url:URL, baseline:Data) throws {
        var coordinationError:NSError?
        var result:Result<Void,Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt:url,options:.forReplacing,error:&coordinationError) { coordinated in
            result=Result {
                guard let current=try? Data(contentsOf:coordinated), current == baseline else { throw WorkspaceError.conflict(url.lastPathComponent) }
                // Foundation's atomic write places a sibling temporary file then renames it.
                let attributes=try FileManager.default.attributesOfItem(atPath:coordinated.path)
                try data.write(to:coordinated,options:.atomic)
                if let permissions=attributes[.posixPermissions] { try? FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:coordinated.path) }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}

extension FileTreeService {
    /// Shared ignore-aware traversal for project references; this is a query, not another index.
    func projectFiles(root: URL, matching query: String, limit: Int = 80) throws -> [URL] {
        var result: [URL] = [], visited = 0
        func visit(_ folder: URL, inherited: [IgnoreRule], depth: Int) throws {
            guard depth <= 40, visited < 10000, result.count < limit else { return }
            let base = folder.path == root.path ? "" : String(folder.path.dropFirst(root.path.count + 1))
            let rules = inherited + Self.rules(at: folder, base: base)
            for node in try children(root: root, folder: folder, depth: depth, inherited: inherited, hidden: false, ignored: false) {
                visited += 1
                if visited >= 10000 || result.count >= limit { return }
                if node.isDirectory { try? visit(node.url, inherited: rules, depth: depth + 1) }
                else if !node.isSymbolicLink {
                    let path = String(node.url.path.dropFirst(root.path.count + 1))
                    if query.isEmpty || path.localizedCaseInsensitiveContains(query) { result.append(node.url) }
                }
            }
        }
        try visit(root, inherited: [], depth: 0)
        return result
    }
}
