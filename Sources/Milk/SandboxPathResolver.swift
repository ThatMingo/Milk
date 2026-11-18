import Foundation
import Darwin

struct SandboxFileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let kind: UInt16
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino; kind = value.st_mode & S_IFMT }
}
struct SandboxPathObservation: Equatable {
    let path: String
    let identity: SandboxFileIdentity
}
struct SandboxResolvedPath {
    let requestedURL: URL
    let canonicalURL: URL
    let existingAncestor: URL
    let missingComponents: [String]
    let observations: [SandboxPathObservation]
    var exists: Bool { missingComponents.isEmpty }
    var isDirectory: Bool { exists && observations.last?.identity.kind == S_IFDIR }
    var finalIdentity: SandboxFileIdentity? { exists ? observations.last?.identity : nil }

    func contains(_ target: SandboxResolvedPath) -> Bool {
        let root = canonicalURL.path, candidate = target.canonicalURL.path
        if root == candidate || (isDirectory || !exists) && (root == "/" || candidate.hasPrefix(root + "/")) { return true }
        // A hard-linked file is the same protected object even under a different spelling.
        return !isDirectory && finalIdentity != nil && finalIdentity == target.finalIdentity
    }
    /// Detects observed replacement/alias changes. Not an atomic execution authorization.
    /// Later executors must revalidate at admission and enforce/open targets safely under Seatbelt.
    func revalidated(using resolver: SandboxPathResolver = .init()) -> Bool {
        guard let current = try? resolver.resolve(requestedURL), current.canonicalURL == canonicalURL else { return false }
        return observations.allSatisfy { old in current.observations.contains(old) }
    }
}
enum SandboxPathError: Error { case invalidPath, inaccessible, notDirectory, tooManyLinks, changedDuringResolution }
struct SandboxPathResolver {
    func resolve(_ url: URL) throws -> SandboxResolvedPath {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw SandboxPathError.invalidPath }
        var pending = url.path.split(separator: "/").map(String.init)
        var current = "/", links = 0, observations: [SandboxPathObservation] = []
        var missing: [String] = []
        var last = try inspect(current); observations.append(last)
        while !pending.isEmpty {
            let component = pending.removeFirst()
            guard last.identity.kind == S_IFDIR || !missing.isEmpty else { throw SandboxPathError.notDirectory }
            if component == "." { continue }
            if component == ".." {
                // A nonexistent/../ path is not a safe kernel traversal or a grant root.
                guard missing.isEmpty else { throw SandboxPathError.invalidPath }
                current = (current as NSString).deletingLastPathComponent
                if current.isEmpty { current = "/" }
                last = try inspect(current); observations.append(last); continue
            }
            if !missing.isEmpty { missing.append(component); continue }
            let candidate = current == "/" ? "/" + component : current + "/" + component
            var value = stat()
            guard lstat(candidate, &value) == 0 else {
                guard errno == ENOENT else { throw SandboxPathError.inaccessible }
                missing.append(component); continue
            }
            let identity = SandboxFileIdentity(value)
            if identity.kind == S_IFLNK {
                links += 1; guard links <= 40 else { throw SandboxPathError.tooManyLinks }
                observations.append(.init(path: candidate, identity: identity))
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: candidate)
                // Preserve symlink/.. semantics; never lexically standardize before walking links.
                if destination.hasPrefix("/") { current = "/"; last = try inspect(current); observations.append(last) }
                pending = destination.split(separator: "/").map(String.init) + pending
            } else {
                let observed = try inspect(candidate)
                guard observed.identity == identity else { throw SandboxPathError.changedDuringResolution }
                current = observed.path; last = observed; observations.append(observed)
            }
        }
        if observations.last != last { observations.append(last) }
        let ancestor = URL(fileURLWithPath: current)
        let target = missing.reduce(ancestor) { $0.appendingPathComponent($1) }
        return .init(requestedURL: url, canonicalURL: target, existingAncestor: ancestor,
                     missingComponents: missing, observations: observations)
    }
    private func inspect(_ path: String) throws -> SandboxPathObservation {
        // F_GETPATH obtains the volume's actual path spelling (including case). Opening
        // O_EVTONLY avoids reading file contents; NOFOLLOW + fstat pins this observation.
        let fd = open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SandboxPathError.inaccessible }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw SandboxPathError.inaccessible }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard buffer.withUnsafeMutableBufferPointer({ fcntl(fd, F_GETPATH, $0.baseAddress!) }) == 0 else { throw SandboxPathError.inaccessible }
        return .init(path: String(cString: buffer), identity: SandboxFileIdentity(value))
    }
}
