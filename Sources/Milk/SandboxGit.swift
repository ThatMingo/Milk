import Foundation
import Darwin
import CryptoKit

/// Filesystem inventory only; discovery never invokes hooks, helpers or a shell.
struct SandboxGitRepository {
    let root: SandboxResolvedPath
    let gitDirectory: SandboxResolvedPath
    let commonDirectory: SandboxResolvedPath
    let controls: [SandboxResolvedPath]
    let configurationDigest: String
    let problem: String?
    static func text(_ url: URL) throws -> String? {
        var info = stat(); if lstat(url.path,&info) < 0 { if errno == ENOENT { return nil }; throw SandboxPathError.inaccessible }
        let resolved = try SandboxPathResolver().resolve(url)
        guard resolved.finalIdentity?.kind == S_IFREG else { throw SandboxPathError.invalidPath }
        let fd = open(resolved.canonicalURL.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SandboxPathError.inaccessible }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? file.close() }
        var opened = stat(); guard fstat(fd,&opened) == 0, SandboxFileIdentity(opened) == resolved.finalIdentity else { throw SandboxPathError.changedDuringResolution }
        let data = try file.read(upToCount:1_048_577) ?? Data()
        guard data.count <= 1_048_576, let value = String(data:data,encoding:.utf8) else { throw SandboxPathError.invalidPath }
        return value
    }
    static func discover(at workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self? {
        let resolver = SandboxPathResolver(); var directory = try resolver.resolve(workspace).canonicalURL
        while true {
            let marker = directory.appendingPathComponent(".git")
            var info = stat()
            if lstat(marker.path,&info) == 0 {
                let resolved = try resolver.resolve(marker), git: URL
                if resolved.isDirectory { git = resolved.canonicalURL }
                else {
                    guard let line = try text(marker), line.hasPrefix("gitdir:") else { throw SandboxPathError.invalidPath }
                    let raw = line.dropFirst(7).trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !raw.isEmpty else { throw SandboxPathError.invalidPath }
                    git = raw.hasPrefix("/") ? URL(fileURLWithPath:raw) : directory.appendingPathComponent(raw)
                }
                let gitPath = try resolver.resolve(git); guard gitPath.isDirectory else { throw SandboxPathError.invalidPath }
                let common: URL
                if let raw = try text(gitPath.canonicalURL.appendingPathComponent("commondir"))?.trimmingCharacters(in:.whitespacesAndNewlines) {
                    guard !raw.isEmpty else { throw SandboxPathError.invalidPath }
                    common = raw.hasPrefix("/") ? URL(fileURLWithPath:raw) : gitPath.canonicalURL.appendingPathComponent(raw)
                } else { common = gitPath.canonicalURL }
                let commonPath = try resolver.resolve(common); guard commonPath.isDirectory else { throw SandboxPathError.invalidPath }
                var controls = [resolved,gitPath,commonPath]
                var configurations = [commonPath.canonicalURL.appendingPathComponent("config"),gitPath.canonicalURL.appendingPathComponent("config.worktree"),home.appendingPathComponent(".gitconfig"),home.appendingPathComponent(".config/git/config"),URL(fileURLWithPath:"/etc/gitconfig")]
                var seen: Set<String> = [], digest = Data(), problem: String?
                while !configurations.isEmpty {
                    let file = configurations.removeFirst(), path = try resolver.resolve(file)
                    if !seen.insert(path.canonicalURL.path).inserted { continue }
                    guard seen.count <= 64 else { throw SandboxPathError.invalidPath }
                    controls.append(path)
                    guard let contents = try text(file) else { continue }
                    digest.append(Data(path.canonicalURL.path.utf8)); digest.append(Data(contents.utf8))
                    var section = ""
                    for rawLine in contents.components(separatedBy:.newlines) {
                        let line = rawLine.trimmingCharacters(in:.whitespaces)
                        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                        if line.hasPrefix("[") { section = line.lowercased().replacingOccurrences(of:#"^\[\s*"#,with:"[",options:.regularExpression).replacingOccurrences(of:#"\s*\]"#,with:"]",options:.regularExpression); continue }
                        guard let split = line.firstIndex(of:"=") else { continue }
                        let key = line[..<split].trimmingCharacters(in:.whitespaces).lowercased()
                        let relevant = (section.hasPrefix("[include") && key == "path") ||
                            (section.hasPrefix("[core]") && ["hookspath","attributesfile","excludesfile"].contains(key))
                        guard relevant else { continue }
                        var value = line[line.index(after:split)...].trimmingCharacters(in:.whitespaces)
                        if value.hasPrefix("\"") {
                            guard value.hasSuffix("\""), let data = value.data(using:.utf8), let decoded = try? JSONDecoder().decode(String.self,from:data) else { problem = "Ambiguous Git control path quoting."; continue }
                            value = decoded
                        } else if value.contains("#") || value.contains(";") || value.contains("\\") { problem = "Ambiguous Git control path syntax."; continue }
                        guard !value.isEmpty, !value.contains("%("), (!value.hasPrefix("~") || value.hasPrefix("~/")), !value.utf8.contains(0) else { problem = "Unsupported Git control path interpolation."; continue }
                        let target: URL
                        if value.hasPrefix("~/") { target = home.appendingPathComponent(String(value.dropFirst(2))) }
                        else if value.hasPrefix("/") { target = URL(fileURLWithPath:value) }
                        else { target = (key == "hookspath" ? directory : file.deletingLastPathComponent()).appendingPathComponent(value) }
                        let selected = try resolver.resolve(target); controls.append(selected)
                        if section.hasPrefix("[include") { configurations.append(target) }
                    }
                }
                return .init(root:try resolver.resolve(directory),gitDirectory:gitPath,commonDirectory:commonPath,controls:controls,configurationDigest:SHA256.hash(data:digest).map { String(format:"%02x",$0) }.joined(),problem:problem)
            }
            // A bare repository is entirely metadata, not a writable work tree.
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent("HEAD").path),
               (try? resolver.resolve(directory.appendingPathComponent("objects")).isDirectory) == true {
                let root = try resolver.resolve(directory)
                return .init(root:root,gitDirectory:root,commonDirectory:root,controls:[root],configurationDigest:"bare",problem:"Bare working directories are not supported for agent escalation.")
            }
            if directory.path == "/" { return nil }; directory.deleteLastPathComponent()
        }
    }
    func revalidated() -> Bool { root.revalidated() && gitDirectory.revalidated() && commonDirectory.revalidated() && controls.allSatisfy { $0.revalidated() } }
}

struct SandboxGitCommand {
    let arguments: [String]
    let writes: Bool
    static func recognize(_ argv: [String]) throws -> Self {
        func invalid() -> AgentError { .message("Unsupported or ambiguous Git argv. Use the structured Git tool; shell commands never receive Git escalation.") }
        guard !argv.isEmpty, argv.count <= 128, argv.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count < 65536 }), let command = argv.first else { throw invalid() }
        let reads: Set<String> = ["status","diff","log","show","rev-parse"]
        let writes: Set<String> = ["add","restore","rm","commit","checkout","switch","branch","merge","reset","fetch","pull","push","apply"]
        guard reads.contains(command) || writes.contains(command) else { throw invalid() }
        let options: [String:Set<String>] = [
            "status":["--short","-s","--branch","-b","--porcelain","--porcelain=v1","--porcelain=v2","--untracked-files=all","--untracked-files=no","-z"],
            "diff":["--cached","--staged","--stat","--numstat","--name-only","--name-status","--check","--no-color","--ext-diff","--no-ext-diff","--no-textconv","--quiet","--exit-code"],
            "log":["--oneline","--all","--graph","--decorate"], "show":["--stat","--name-only","--no-color"],
            "rev-parse":["--show-toplevel","--absolute-git-dir","--git-common-dir","--show-prefix","--is-inside-work-tree","--verify"],
            "add":["--all","-A","--update","-u"], "restore":["--staged","--worktree"], "rm":["--cached","--force","-f","--ignore-unmatch","-r"],
            "commit":["--amend","--no-edit","--all","-a","--allow-empty"], "checkout":["--detach","--force","-f"],
            "switch":["--detach","--force","-f","--no-guess"], "branch":["--list","--delete","-d","-D","--force","-f","-m","-M","--show-current"],
            "merge":["--no-ff","--ff-only","--ff","--no-commit","--commit","--no-edit","--abort","--continue","--squash"],
            "reset":["--soft","--mixed","--hard","--keep","--merge"],
            "fetch":["--all","--prune","--tags","--no-tags","--force","-f"],
            "pull":["--rebase","--no-rebase","--ff-only","--ff","--no-ff","--no-edit"],
            "apply":["--cached","--check","--reverse","--recount","--unidiff-zero","--whitespace=nowarn","-"],
            "push":["--force-with-lease","--force","-f","--tags","--delete","--set-upstream","-u"]]
        var pathMode = false, consumes: String?, positionals = 0, values: [String] = []
        for argument in argv.dropFirst() {
            if let kind = consumes {
                guard !argument.isEmpty else { throw invalid() }
                if kind != "message", !safeRef(argument) { throw invalid() }
                consumes = nil; continue
            }
            if argument == "--" { guard !pathMode else { throw invalid() }; pathMode = true; continue }
            if !pathMode && argument.hasPrefix("-") {
                if ["commit","merge"].contains(command), argument == "-m" { consumes = "message"; continue }
                if command == "checkout" && ["-b","-B"].contains(argument) || command == "switch" && ["-c","-C"].contains(argument) { consumes = "ref"; continue }
                guard options[command]?.contains(argument) == true else { throw invalid() }; continue
            }
            if pathMode || ["add","restore","rm"].contains(command) {
                guard !argument.isEmpty, !argument.hasPrefix("/"), !argument.hasPrefix(":"), !argument.split(separator:"/").contains(".."), !argument.split(separator:"/").contains(".git") else { throw invalid() }
            } else {
                let pieces = argument.split(separator:":",omittingEmptySubsequences:false)
                if ["push","fetch"].contains(command), positionals > 0, pieces.count == 2 {
                    guard pieces.allSatisfy({ $0.isEmpty || safeRef(String($0).trimmingCharacters(in:CharacterSet(charactersIn:"+"))) }) else { throw invalid() }
                } else { guard safeRef(argument) else { throw invalid() } }
            }
            positionals += 1; values.append(argument)
        }
        guard consumes == nil else { throw invalid() }
        if command == "apply" { guard argv.contains("--cached"), argv.last == "-", argv.filter({ $0 == "-" }).count == 1, values.isEmpty else { throw invalid() } }
        if ["fetch","pull","push"].contains(command), let remote = values.first {
            guard remote.range(of:#"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#,options:.regularExpression) != nil else { throw invalid() }
        }
        let branchRead = command == "branch" && (argv.count == 1 || argv.contains("--list") || argv.contains("--show-current"))
        if branchRead, argv.dropFirst().contains(where:{ $0.hasPrefix("-") && !["--list","--show-current"].contains($0) }) { throw invalid() }
        return .init(arguments:argv,writes:writes.contains(command) && !branchRead)
    }
    private static func safeRef(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.contains("..") && !value.contains("@{") && !value.hasSuffix(".lock") &&
        value.range(of:#"^[A-Za-z0-9_./@~^+-]+$"#,options:.regularExpression) != nil
    }
}
