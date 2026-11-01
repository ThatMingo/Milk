import Foundation

/// Filesystem policy compiler. Other macOS service/network closure is later purpose hardening.
struct SandboxProfileBuilder {
    struct Root { let url: URL; var subtree = true }
    static func quote(_ value: String) throws -> String {
        guard !value.utf8.contains(0), let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { throw SandboxPathError.invalidPath }
        return string.replacingOccurrences(of: "\\/", with: "/")
    }
    func make(context: SandboxPolicyContext, dependencies: [Root], grants: [SandboxTemporaryGrant] = [],
              admitting: (SandboxPolicyDecision) -> SandboxPolicyDecision = { $0 }) throws -> String? {
        guard context.configurationIsValid else { throw SandboxPathError.invalidPath }
        if !context.configuration.enabled { return nil }
        var roots = [Root(url: URL(fileURLWithPath: "/")), Root(url: context.roots.project)]
        roots += context.configuration.protectedLocations.map { Root(url: $0.url) }
        roots += context.roots.inactiveProfiles.map { Root(url: $0.url) }
        if let active = context.roots.activeProfile { roots.append(Root(url: active.url)) }
        roots += (context.configuration.globalAllowedFolders + context.projectConfiguration.allowedFolders).map { Root(url: $0.url) }
        roots += context.roots.writableBuildRoots.map { Root(url: $0) }
        roots += dependencies
        if context.subject != .agentRuntime { roots += grants.map { Root(url: $0.path.canonicalURL, subtree: $0.includesDescendants) } }
        let resolver = SandboxPathResolver()
        var entries: [String: (Root, SandboxResolvedPath)] = [:]
        for root in roots {
            let resolved = try resolver.resolve(root.url)
            guard resolved.revalidated() else { throw SandboxPathError.changedDuringResolution }
            let key = resolved.canonicalURL.path
            if let old = entries[key] { entries[key] = (Root(url: old.0.url, subtree: old.0.subtree || root.subtree), resolved) }
            else { entries[key] = (root, resolved) }
        }
        let ordered = entries.values.sorted { $0.1.canonicalURL.path < $1.1.canonicalURL.path }
        func filter(_ entry: (Root, SandboxResolvedPath)) throws -> String {
            "(\(entry.0.subtree ? "subpath" : "literal") \(try Self.quote(entry.1.canonicalURL.path)))"
        }
        func allowed(_ action: SandboxFileAction) throws -> String {
            var branches: [String] = []
            for entry in ordered {
                let raw = SandboxPolicy().evaluate(entry.1.canonicalURL, action: action, context: context)
                if [.unresolvedPath, .invalidConfiguration, .ambiguousRoots].contains(raw.rule) { throw SandboxPathError.invalidPath }
                let decision = admitting(raw)
                let dependency = action == .read && raw.rule == .outsideProject && dependencies.contains { dependency in
                    guard let path = try? resolver.resolve(dependency.url) else { return false }
                    return dependency.subtree ? path.contains(entry.1) : path.canonicalURL.path == entry.1.canonicalURL.path
                }
                guard decision.outcome == .allow || dependency else { continue }
                let nested = ordered.filter { candidate in
                    candidate.1.canonicalURL.path != entry.1.canonicalURL.path && entry.1.contains(candidate.1)
                }
                var selected = entry
                if decision.rule == .temporaryGrant {
                    selected.0 = Root(url: entry.0.url, subtree: entry.0.subtree && grants.contains { $0.includesDescendants && $0.path.contains(entry.1) })
                } else if decision.outcome != .allow && dependency {
                    selected.0 = Root(url: entry.0.url, subtree: entry.0.subtree && dependencies.contains { root in root.subtree && ((try? resolver.resolve(root.url).contains(entry.1)) == true) })
                }
                let base = try filter(selected)
                branches.append(nested.isEmpty ? base : "(require-all \(base) (require-not (require-any \(try nested.map(filter).joined(separator: " ")))))")
            }
            return branches.isEmpty ? "(literal \(try Self.quote("/Milk-no-permitted-path-" + UUID().uuidString)))" : "(require-any \(branches.joined(separator: " ")))"
        }
        let read = try allowed(.read), write = try allowed(.write)
        var ancestors: Set<String> = ["/"]
        for entry in ordered where entry.1.canonicalURL.path != "/" {
            var parent = entry.1.canonicalURL.deletingLastPathComponent().path
            while !parent.isEmpty && parent != "/" { ancestors.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        let metadata = try ancestors.sorted().map { "(literal \(try Self.quote($0)))" }.joined(separator: " ")
        var sbpl = "(version 1)\n(allow default)\n(deny file-read-data file-read-xattr (require-not \(read)))\n(deny file-read-metadata (require-not (require-any \(read) \(metadata))))\n(deny file-write* (require-not \(write)))\n"
        // No general operation may mutate Git metadata, even inside a broad grant.
        sbpl += "(deny file-write* (regex #\"(^|/)\\.git(/|$)\"))\n"
        let git = context.roots.project.appendingPathComponent(".git")
        if let data = try? Data(contentsOf: git), data.count < 8192, let line = String(data: data, encoding: .utf8), line.hasPrefix("gitdir:") {
            let raw = line.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : context.roots.project.appendingPathComponent(raw)
            let resolved = try resolver.resolve(url)
            sbpl += "(deny file-write* (subpath \(try Self.quote(resolved.canonicalURL.path))))\n"
            let common = resolved.canonicalURL.appendingPathComponent("commondir")
            if let value = try? String(contentsOf: common, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                let target = value.hasPrefix("/") ? URL(fileURLWithPath: value) : resolved.canonicalURL.appendingPathComponent(value)
                sbpl += "(deny file-write* (subpath \(try Self.quote(try resolver.resolve(target).canonicalURL.path))))\n"
            }
        }
        return sbpl
    }
    static var systemReadRoots: [Root] {
        ["/System", "/usr", "/bin", "/sbin", "/Library", "/private/etc", "/dev", "/opt/homebrew", "/Applications/Xcode.app", "/private/preboot", "/private/var/select"].filter { FileManager.default.fileExists(atPath: $0) }.map { Root(url: URL(fileURLWithPath: $0)) } + [Root(url: URL(fileURLWithPath: "/"), subtree: false)]
    }
    static func command(executable: URL, arguments: [String], profile: String?) -> (URL, [String]) {
        guard let profile else { return (executable, arguments) }
        return (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile, executable.path] + arguments)
    }
}
