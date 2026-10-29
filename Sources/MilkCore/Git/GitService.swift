import Foundation

public struct GitChange: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var originalPath: String?
    public var index: Character
    public var worktree: Character
    public var staged: Bool { index != " " && index != "?" }
    public var unstaged: Bool { worktree != " " || index == "?" }
}
public struct GitSnapshot: Sendable {
    public var root: URL
    public var branch: String
    public var changes: [GitChange]
}
public protocol GitServing: Sendable {
    func snapshot(in folder: URL) async throws -> GitSnapshot
    func diff(in folder: URL, path: String?, staged: Bool) async throws -> String
}
public actor GitService: GitServing {
    public let executable: URL
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) { self.executable = executable }
    public func run(_ args: [String], in directory: URL) async throws -> Data {
        var env = ProcessInfo.processInfo.environment; env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await CommandRunner.run(.init(executable: executable, arguments: ["--no-pager"] + args, directory: directory, environment: env))
        guard result.status == 0 else { throw MilkError.message("Git operation failed (\(result.status)). Check repository access and authentication.") }
        return result.output
    }
    public func snapshot(in folder: URL) async throws -> GitSnapshot {
        let rootData = try await run(["rev-parse", "--show-toplevel"], in: folder)
        let root = URL(fileURLWithPath: String(decoding: rootData, as: UTF8.self).trimmingCharacters(in: .newlines))
        let branch = try? await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        let status = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: root)
        return GitSnapshot(root: root, branch: branch.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) } ?? "HEAD (detached)", changes: try Self.parseStatus(status))
    }
    public nonisolated static func parseStatus(_ data: Data) throws -> [GitChange] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var result: [GitChange] = []; var i = 0
        while i < fields.count && !fields[i].isEmpty {
            let bytes = Array(fields[i]); guard bytes.count >= 4, bytes[2] == 32 else { throw MilkError.message("Invalid Git status record") }
            let x = Character(UnicodeScalar(bytes[0])), y = Character(UnicodeScalar(bytes[1]))
            let path = String(decoding: bytes.dropFirst(3), as: UTF8.self); var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                i += 1; guard i < fields.count, !fields[i].isEmpty else { throw MilkError.message("Missing Git rename source") }
                original = String(decoding: fields[i], as: UTF8.self)
            }
            result.append(GitChange(path: path, originalPath: original, index: x, worktree: y)); i += 1
        }
        return result
    }
    public func diff(in folder: URL, path: String? = nil, staged: Bool = false) async throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--"); if let path { args.append(path) }
        return String(decoding: try await run(args, in: folder), as: UTF8.self)
    }
    public func stage(path: String, in folder: URL) async throws { _ = try await run(["add", "--", path], in: folder) }
    public func unstage(path: String, in folder: URL) async throws { _ = try await run(["restore", "--staged", "--", path], in: folder) }
    public func remotes(in folder: URL) async throws -> [String] {
        String(decoding: try await run(["remote", "-v"], in: folder), as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}

public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public enum Kind: Sendable { case context, addition, deletion, header }
    public var kind: Kind { text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("@@") ? .header : text.hasPrefix("+") ? .addition : text.hasPrefix("-") ? .deletion : .context }
    public static func parse(_ patch: String) -> [DiffLine] { patch.components(separatedBy: "\n").enumerated().map { .init(id: $0.offset, text: $0.element) } }
}
