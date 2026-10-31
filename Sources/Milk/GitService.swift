import Foundation
import CryptoKit

/// Serial repository boundary. Process never runs on the main actor or in a SwiftUI view.
actor GitService {
    struct Output { let data: Data; let error: String; let code: Int32
        var text: String { String(decoding: data, as: UTF8.self) }
    }
    private func run(_ arguments: [String], at root: URL, input: Data? = nil, accepted: Set<Int32> = [0]) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MilkGit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout"), errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"; environment["GIT_MERGE_AUTOEDIT"] = "no"; environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment; process.standardOutput = out; process.standardError = err
        var stdin: FileHandle?
        if let input {
            let url = directory.appendingPathComponent("stdin"); try input.write(to: url)
            stdin = try FileHandle(forReadingFrom: url); process.standardInput = stdin
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? stdin?.close() }
        do { try process.run() }
        catch { throw GitFailure(kind: .unavailable, operation: arguments.first ?? "Git", message: "System Git could not start: \(error.localizedDescription)") }
        // Credential helpers/SSH use the user's normal configuration; prevent an unattended process hanging forever.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        let output = Output(data: try Data(contentsOf: outURL), error: String(decoding: try Data(contentsOf: errURL), as: UTF8.self), code: process.terminationStatus)
        guard accepted.contains(output.code) else {
            throw GitFailure(kind: .command, operation: arguments.first ?? "Git", message: (output.error + output.text).trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Git failed (\(output.code)).", exitCode: output.code)
        }
        return output
    }
    func repository(at workspace: URL) throws -> GitRepository? {
        let detection = try run(["rev-parse", "--show-toplevel"], at: workspace, accepted: [0,128])
        if detection.code != 0 {
            if detection.error.contains("not a git repository") { return nil }
            throw GitFailure(kind: .command, operation: "Repository detection", message: detection.error, exitCode: detection.code)
        }
        let root = URL(fileURLWithPath: detection.text.trimmingCharacters(in: .newlines)).standardizedFileURL
        let git = try run(["rev-parse", "--absolute-git-dir"], at: root).text.trimmingCharacters(in: .newlines)
        let common = try run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root).text.trimmingCharacters(in: .newlines)
        var repo = GitRepository.parseStatus(try run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], at: root).data,
                                              root: root, gitDirectory: URL(fileURLWithPath: git), commonDirectory: URL(fileURLWithPath: common))
        repo.branches = try run(["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"], at: root).text.split(separator: "\n").map(String.init)
        repo.remotes = try run(["remote"], at: root).text.split(separator: "\n").map(String.init)
        repo.merging = FileManager.default.fileExists(atPath: repo.gitDirectory.appendingPathComponent("MERGE_HEAD").path)
        return repo
    }
    private func validate(_ path: String, root: URL, disk: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/"), !path.split(separator: "/").contains(".git") else {
            throw GitFailure(kind: .invalidPath, operation: "Git", message: "Invalid repository path.")
        }
        if disk {
            // Never discard through a parent symlink pointing outside the repository. A symlink itself is safe to unlink.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            guard parent == root || parent.path.hasPrefix(root.path + "/") else { throw GitFailure.validation("This file's parent points outside the repository.") }
        }
        return url
    }
    func diff(_ file: GitFile, staged: Bool, in repo: GitRepository) throws -> GitDiff {
        _ = try validate(file.path, root: repo.root)
        if file.untracked && staged { return .parse(path:file.path,staged:true,raw:"") }
        let raw: String
        if file.untracked {
            raw = try run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--", "/dev/null", file.path], at: repo.root, accepted: [0,1]).text
        } else {
            raw = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--unified=3"] + (staged ? ["--cached"] : []) + ["--", file.path] + (file.originalPath.map { [$0] } ?? []), at: repo.root).text
        }
        let large = raw.utf8.count > FileTextCodec.maximumSize
        var value = GitDiff.parse(path: file.path, staged: staged, raw: large ? "" : raw)
        if large { value.displayMessage = "This diff exceeds the 8 MB display limit. File actions remain available; inspect the contents externally." }
        let patchHash = SHA256.hash(data:Data(raw.utf8)).map { String(format:"%02x",$0) }.joined()
        value.fingerprint = try fingerprint(file, root: repo.root) + patchHash
        return value
    }
    func perform(_ operation: GitOperation, in repo: GitRepository) throws {
        let root = repo.root
        switch operation {
        case .stage(let file):
            _ = try validate(file.path, root: root); _ = try run(["add", "--", file.path], at: root)
        case .unstage(let file):
            let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
            for path in paths { _ = try validate(path, root: root) }
            // With no HEAD, --force removes only the index entry, preserving any newer disk edits.
            _ = try run((repo.unborn ? ["rm", "--cached", "--force", "--ignore-unmatch"] : ["restore", "--staged"]) + ["--"] + paths, at: root)
        case .stageAll: _ = try run(["add", "--all", "--", "."], at: root)
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure.validation("Enter a commit message.") }
            let staged = try run(["diff", "--cached", "--quiet", "--exit-code"], at: root, accepted: [0,1])
            guard staged.code == 1 || repo.merging else { throw GitFailure(kind: .noStagedChanges, operation: "Commit", message: "Nothing is staged. Stage files explicitly, or choose Stage All & Commit.") }
            _ = try run(["commit", "--file=-"], at: root, input: Data(message.utf8))
        case .fetch: _ = try run(["fetch"], at: root)
        case .pull: _ = try run(["-c", "merge.autoStash=false", "-c", "rebase.autoStash=false", "pull", "--no-rebase", "--no-edit"], at: root)
        case .push:
            guard !repo.detached else { throw GitFailure.validation("Create or switch to a local branch before pushing.") }
            if repo.upstream == nil {
                guard repo.remotes.count == 1, let remote = repo.remotes.first else { throw GitFailure.validation("No upstream is configured. Configure a tracking branch with Git, or keep one remote to publish this branch from Milk.") }
                _ = try run(["push", "--set-upstream", remote, "HEAD:refs/heads/" + repo.branch], at: root)
            } else { _ = try run(["push"], at: root) }
        case .switchBranch(let name):
            try localBranch(name, in: repo); _ = try run(["-c", "submodule.recurse=false", "switch", "--no-guess", name], at: root)
        case .createBranch(let name):
            guard !name.hasPrefix("-") else { throw GitFailure.validation("Enter a valid local branch name.") }
            _ = try run(["check-ref-format", "--branch", name], at: root)
            _ = try run(["switch", "-c", name], at: root)
        case .mergeBranch(let name):
            try localBranch(name, in: repo); _ = try run(["-c", "merge.autoStash=false", "merge", "--no-edit", "--", name], at: root)
        case .deleteBranch(let name):
            try localBranch(name, in: repo); _ = try run(["branch", "-d", "--", name], at: root)
        case .hunk(let snapshot, let id, let action):
            guard let file = repo.files.first(where: { $0.path == snapshot.path }), snapshot.hunkActionsAvailable, let hunk = snapshot.hunks.first(where: { $0.id == id }) else { throw GitFailure.validation("This hunk cannot be applied. Refresh the diff.") }
            let current = try diff(file, staged: snapshot.staged, in: repo)
            guard current.raw == snapshot.raw, current.fingerprint == snapshot.fingerprint else { throw stale() }
            guard (action == .unstage) == snapshot.staged else { throw GitFailure.validation("Choose the appropriate staged or working-tree diff.") }
            let options = action == .stage ? ["--cached"] : action == .unstage ? ["--cached", "--reverse"] : ["--reverse"]
            let patch = Data(hunk.patch.utf8)
            _ = try run(["apply", "--check", "--whitespace=nowarn"] + options + ["-"], at: root, input: patch)
            _ = try run(["apply", "--whitespace=nowarn"] + options + ["-"], at: root, input: patch)
        case .discard(let file, let snapshot):
            guard repo.files.first(where: { $0.path == file.path }) == file else { throw stale() }
            let url = try validate(file.path, root: root, disk: true)
            let current = try diff(file, staged: false, in: repo)
            guard !snapshot.staged, current.raw == snapshot.raw, current.fingerprint == snapshot.fingerprint else { throw stale() }
            if file.untracked {
                let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory != true || info.isSymbolicLink == true else { throw GitFailure.validation("Milk does not recursively discard directories or submodules.") }
                try FileManager.default.removeItem(at: url)
            } else {
                guard (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true else { throw GitFailure.validation("Discard inside submodules is not supported. Open that repository separately.") }
                // Restore only the working tree from the index; staged changes are preserved.
                _ = try run(["restore", "--worktree", "--", file.path], at: root)
            }
        }
    }
    private func fingerprint(_ file: GitFile, root: URL) throws -> String {
        let index = try run(["ls-files", "--stage", "-z", "--", file.path], at: root).data
        var hash = SHA256(); hash.update(data: index)
        let url = try validate(file.path, root: root, disk: true)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            hash.update(data: Data(destination.utf8))
        } else if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
            hash.update(data: Data("directory".utf8))
        } else if let reader = try? FileHandle(forReadingFrom: url) {
            defer { try? reader.close() }
            while let bytes = try reader.read(upToCount: 64 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        } else { hash.update(data: Data("missing".utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func localBranch(_ name: String, in repo: GitRepository) throws {
        guard !name.hasPrefix("-"), repo.branches.contains(name) else { throw GitFailure.validation("Choose an existing local branch.") }
    }
    private func stale() -> GitFailure { .init(kind: .staleDiff, operation: "Diff", message: "The file or index changed after this diff was shown. Review the refreshed diff and try again.") }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
