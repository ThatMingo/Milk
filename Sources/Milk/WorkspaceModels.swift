import Foundation
import AppKit

struct Workspace: Codable, Equatable {
    let url: URL
    var name: String { url.lastPathComponent }
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

struct FileNode: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let depth: Int
    let isIgnored: Bool
    var name: String { url.lastPathComponent }
    var icon: String {
        if isSymbolicLink { return "link" }
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "c", "h", "cpp", "java", "sh": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "plist": return "curlybraces"
        case "md", "txt", "rst": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return "photo"
        default: return "doc"
        }
    }
}

enum DiagnosticSeverity: String, Codable { case error, warning, information }
struct EditorDiagnostic: Identifiable, Codable, Equatable {
    var id = UUID()
    let file: URL
    let line: Int
    let column: Int
    let message: String
    let severity: DiagnosticSeverity
    var source: String = "Milk"
}

struct EditorPreferences: Codable, Equatable {
    var fontSize: Double = 12.5
    var wordWrap = false
    var usesTabs = false
    var indentWidth = 4
}

struct EditorTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var pinned: Bool
    var diffMode: Bool? = nil
    var stagedDiff: Bool? = nil
}
struct EditorPosition: Codable, Equatable {
    var selection = 0
    var selectionLength = 0
    var scrollY: Double = 0
}
struct EditorPane: Identifiable, Codable, Equatable {
    var id = UUID()
    var tabs: [EditorTab] = []
    var selected: UUID?
    var positions: [String:EditorPosition] = [:]
    var activeTab: EditorTab? { tabs.first { $0.id == selected } }
}
/// Editor state keyed by Milk's local session ID; AgentService links it to Pi history.
struct EditorSession: Codable, Equatable {
    var panes = [EditorPane()]
    var activePane = 0
}
struct BufferRecovery: Codable {
    let path: String
    let text: String
    let baseline: Data
    let encoding: UInt
    let bom: Data
}
struct WorkspaceSnapshot: Codable {
    var version = 1
    var sessions: [String:EditorSession] = [:]
    var selectedSession = 0
    var expanded: Set<String> = []
    var showHidden = false
    var showIgnored = false
    var recoveries: [BufferRecovery] = []
    var layout: Data?
    var shellSessions: Data?
    var sidebarDestination = "Files"
}

@MainActor final class FileBuffer {
    var url: URL
    var text: String
    var baseline: Data
    let encoding: String.Encoding
    let bom: Data
    var externallyChanged = false
    var missing = false
    var revision = 0
    // Shared between native views so undo survives tab switching and split views.
    let storage: NSTextStorage
    let undoManager = UndoManager()
    var isModified: Bool { encoded != baseline }
    var encoded: Data? { text.data(using: encoding).map { bom + $0 } }
    init(url: URL, data: Data) throws {
        let decoded = try FileTextCodec.decode(data)
        self.url=url; text=decoded.text; baseline=data; encoding=decoded.encoding; bom=decoded.bom
        storage=NSTextStorage(string:decoded.text)
    }
    init(recovery: BufferRecovery) {
        url=URL(fileURLWithPath:recovery.path); text=recovery.text; baseline=recovery.baseline
        encoding=String.Encoding(rawValue:recovery.encoding); bom=recovery.bom
        storage=NSTextStorage(string:recovery.text)
    }
    var recovery: BufferRecovery { .init(path:url.path,text:text,baseline:baseline,encoding:encoding.rawValue,bom:bom) }
    func reload(_ data: Data) throws {
        let decoded=try FileTextCodec.decode(data)
        guard decoded.encoding == encoding && decoded.bom == bom else {
            throw WorkspaceError.message("The file encoding changed externally. Close and reopen the file after saving any local edits as a copy.")
        }
        text=decoded.text; baseline=data; externallyChanged=false; missing=false; revision += 1
        storage.replaceCharacters(in:NSRange(location:0,length:storage.length),with:text)
        undoManager.removeAllActions()
    }
}

enum WorkspaceError: LocalizedError {
    case message(String), conflict(String)
    var errorDescription: String? {
        switch self { case let .message(s): return s; case let .conflict(s): return "\(s) changed on disk. Your edits are preserved. Reload the disk version or save your edits as a copy." }
    }
}

enum FileTextCodec {
    static let maximumSize = 8 * 1024 * 1024
    static func decode(_ data: Data) throws -> (text:String, encoding:String.Encoding, bom:Data) {
        guard data.count <= maximumSize else { throw WorkspaceError.message("This file exceeds the 8 MB text editor limit.") }
        let encoding: String.Encoding
        let bom: Data
        if data.starts(with:[0xEF,0xBB,0xBF]) { encoding = .utf8; bom=Data([0xEF,0xBB,0xBF]) }
        else if data.starts(with:[0xFF,0xFE]) { encoding = .utf16LittleEndian; bom=Data([0xFF,0xFE]) }
        else if data.starts(with:[0xFE,0xFF]) { encoding = .utf16BigEndian; bom=Data([0xFE,0xFF]) }
        else { encoding = .utf8; bom=Data() }
        guard let text=String(data:data.dropFirst(bom.count),encoding:encoding), !text.contains("\0") else {
            throw WorkspaceError.message("Milk can edit UTF-8 and BOM-marked UTF-16 text. This appears to be binary or use another encoding. Use Reveal in Finder to open it in another application.")
        }
        return (text,encoding,bom)
    }
}

struct FindQuery: Equatable {
    var text = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    func matches(in text:String) throws -> [NSRange] {
        guard !self.text.isEmpty else { return [] }
        var pattern=regex ? self.text:NSRegularExpression.escapedPattern(for:self.text)
        if wholeWord { pattern="(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
        let expression=try NSRegularExpression(pattern:pattern,options:caseSensitive ? []:[.caseInsensitive])
        return expression.matches(in:text,range:NSRange(location:0,length:(text as NSString).length)).map(\.range)
    }
}

/// Providers can later supply compiler/LSP results without changing the editor UI.
protocol DiagnosticProvider {
    func diagnostics(for url:URL, text:String) -> [EditorDiagnostic]
}
struct JSONDiagnosticProvider: DiagnosticProvider {
    func diagnostics(for url:URL, text:String) -> [EditorDiagnostic] {
        guard url.pathExtension.lowercased() == "json", !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        do { _ = try JSONSerialization.jsonObject(with:Data(text.utf8),options:[.fragmentsAllowed]); return [] }
        catch {
            let e=error as NSError
            let message=e.userInfo[NSDebugDescriptionErrorKey] as? String ?? e.localizedDescription
            let expression=try? NSRegularExpression(pattern:"line (\\d+)(?: column (\\d+))?")
            let ns=message as NSString
            let match=expression?.firstMatch(in:message,range:NSRange(location:0,length:ns.length))
            let line=match.flatMap { Int(ns.substring(with:$0.range(at:1))) } ?? 1
            let column=match.flatMap { $0.range(at:2).location == NSNotFound ? nil:Int(ns.substring(with:$0.range(at:2))) } ?? 1
            return [.init(file:url,line:line,column:column,message:message,severity:.error,source:"JSON parser")]
        }
    }
}
protocol CompletionProvider {
    func completions(for prefix:String, in text:String) -> [String]
}
struct WordCompletionProvider: CompletionProvider {
    func completions(for prefix:String, in text:String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        return Array(Set(text.components(separatedBy:CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_")).inverted)
            .filter { $0.hasPrefix(prefix) && $0 != prefix })).sorted().prefix(40).map { $0 }
    }
}
