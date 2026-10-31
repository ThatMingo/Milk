import Foundation

struct GitFailure: LocalizedError, Equatable {
    enum Kind: String { case command, unavailable, invalidPath, staleDiff, noStagedChanges, validation }
    let kind: Kind
    let operation: String
    let message: String
    var exitCode: Int32? = nil
    var errorDescription: String? { message }
    static func validation(_ message: String) -> GitFailure { .init(kind: .validation, operation: "Git", message: message) }
}

struct GitFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var originalPath: String? = nil
    var index: String
    var worktree: String
    var conflict = false
    var untracked: Bool { index == "?" }
    var staged: Bool { !conflict && !untracked && index != "." }
    var unstaged: Bool { !conflict && !untracked && worktree != "." }
    func code(staged: Bool) -> String { conflict ? "U" : untracked ? "?" : staged ? index : worktree }
    func label(staged: Bool) -> String {
        switch code(staged: staged) {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Conflicted"
        case "?": return "Untracked"
        case "T": return "Type changed"
        default: return "Changed"
        }
    }
}

struct GitRepository: Equatable {
    let root: URL
    var gitDirectory: URL
    var commonDirectory: URL
    var branch = ""
    var oid = ""
    var upstream: String? = nil
    var ahead = 0
    var behind = 0
    var files: [GitFile] = []
    var branches: [String] = []
    var remotes: [String] = []
    var merging = false
    var detached: Bool { branch == "(detached)" }
    var unborn: Bool { oid == "(initial)" }
    var dirty: Bool { !files.isEmpty }
    var branchLabel: String { detached ? "Detached \(oid.prefix(7))" : branch }
    var summary: String {
        branchLabel + (ahead > 0 ? " ↑\(ahead)" : "") + (behind > 0 ? " ↓\(behind)" : "") + (dirty ? " ●" : "")
    }
    static func parseStatus(_ data: Data, root: URL, gitDirectory: URL, commonDirectory: URL) -> GitRepository {
        var result = GitRepository(root: root, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        // NUL records preserve spaces, tabs and newlines in filenames. A rename has an extra original-path record.
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let row = records[i]; i += 1
            if row.hasPrefix("# branch.head ") { result.branch = String(row.dropFirst(14)) }
            else if row.hasPrefix("# branch.oid ") { result.oid = String(row.dropFirst(13)) }
            else if row.hasPrefix("# branch.upstream ") { result.upstream = String(row.dropFirst(18)) }
            else if row.hasPrefix("# branch.ab ") {
                let counts = row.dropFirst(12).split(separator: " ")
                if counts.count == 2 { result.ahead = Int(counts[0].dropFirst()) ?? 0; result.behind = Int(counts[1].dropFirst()) ?? 0 }
            } else if row.hasPrefix("? ") {
                result.files.append(.init(path: String(row.dropFirst(2)), index: "?", worktree: "?"))
            } else if row.hasPrefix("1 ") || row.hasPrefix("2 ") || row.hasPrefix("u ") {
                let rename = row.hasPrefix("2 "), conflict = row.hasPrefix("u ")
                let parts = row.split(separator: " ", maxSplits: conflict ? 10 : rename ? 9 : 8, omittingEmptySubsequences: false)
                guard parts.count == (conflict ? 11 : rename ? 10 : 9), parts[1].count == 2 else { continue }
                var file = GitFile(path: String(parts.last!), index: String(parts[1].prefix(1)), worktree: String(parts[1].suffix(1)), conflict: conflict)
                if rename, i < records.count { file.originalPath = records[i]; i += 1 }
                result.files.append(file)
            }
        }
        result.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }
}

struct GitDiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Character
    let oldLine: Int?
    let newLine: Int?
}
struct GitDiffPair: Identifiable {
    let id: Int
    let old: GitDiffLine?
    let new: GitDiffLine?
}
struct GitHunk: Identifiable {
    let id: Int
    let header: String
    let patch: String
    let lines: [GitDiffLine]
    var pairs: [GitDiffPair] {
        var result: [GitDiffPair] = [], removed: [GitDiffLine] = [], added: [GitDiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) { result.append(.init(id: result.count, old: i < removed.count ? removed[i] : nil, new: i < added.count ? added[i] : nil)) }
            removed = []; added = []
        }
        for line in lines {
            if line.kind == "-" { removed.append(line) }
            else if line.kind == "+" { added.append(line) }
            else { flush(); result.append(.init(id: result.count, old: line, new: line)) }
        }
        flush(); return result
    }
}
struct GitDiff {
    let path: String
    let staged: Bool
    let raw: String
    var fingerprint: String = ""
    var displayMessage: String? = nil
    let hunks: [GitHunk]
    let hunkActionsAvailable: Bool
    let binary: Bool
    static func parse(path: String, staged: Bool, raw: String) -> GitDiff {
        // Keep every byte of patch lines (including CR and no-newline markers) for git apply.
        var header = "", chunk = "", title = "", hunks: [GitHunk] = []
        var lines: [GitDiffLine] = [], old = 0, new = 0
        let expression = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@")
        func flush() {
            if !title.isEmpty { hunks.append(.init(id: hunks.count, header: title, patch: header + chunk, lines: lines)) }
        }
        for slice in raw.components(separatedBy: "\n").dropLast(raw.hasSuffix("\n") ? 1 : 0) {
            let line = String(slice)
            if let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                flush(); title = line; chunk = line + "\n"; lines = []
                old = Int((line as NSString).substring(with: match.range(at: 1))) ?? 0
                new = Int((line as NSString).substring(with: match.range(at: 2))) ?? 0
            } else if title.isEmpty { header += line + "\n" }
            else {
                chunk += line + "\n"
                let kind = line.first ?? " "
                if kind == " " || kind == "+" || kind == "-" {
                    lines.append(.init(id: lines.count, text: String(line.dropFirst()), kind: kind, oldLine: kind == "+" ? nil : old, newLine: kind == "-" ? nil : new))
                    if kind != "+" { old += 1 }; if kind != "-" { new += 1 }
                } else if kind == "\\" { lines.append(.init(id: lines.count, text: line, kind: kind, oldLine: nil, newLine: nil)) }
            }
        }
        flush()
        let binary = raw.contains("Binary files ") || raw.contains("GIT binary patch")
        return .init(path: path, staged: staged, raw: raw, hunks: hunks,
                     hunkActionsAvailable: !binary && !raw.contains("rename from ") && !raw.contains("Subproject commit") && !raw.contains("diff --cc ") && !raw.contains("old mode "), binary: binary)
    }
}

enum GitOperation {
    case stage(GitFile), unstage(GitFile), stageAll
    case commit(String), fetch, pull, push
    case switchBranch(String), createBranch(String), mergeBranch(String), deleteBranch(String)
    case hunk(GitDiff, Int, GitHunkAction)
    case discard(GitFile, GitDiff)
}
enum GitHunkAction { case stage, unstage, revert }
