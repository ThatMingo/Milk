import Foundation
import Darwin

/// A package input and writable target cannot assign contradictory rights to one object.
/// New aliases created by the child remain constrained by Seatbelt; this is admission validation.
enum SandboxInputBoundary {
    static func check(input: SandboxResolvedPath, writable: [SandboxResolvedPath]) throws {
        let fm=FileManager.default, resolver=SandboxPathResolver()
        var shared: [String:Set<String>]=[:]
        func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
        func visit(_ root: SandboxResolvedPath, _ block: (URL,stat) throws -> Void) throws {
            func inspect(_ file: URL) throws {
                var value=stat(); guard lstat(file.path,&value) == 0 else { throw SandboxPathError.inaccessible }
                try block(file,value)
            }
            try inspect(root.canonicalURL)
            guard root.isDirectory else { return }
            var failure: Error?
            guard let entries=fm.enumerator(at:root.canonicalURL,includingPropertiesForKeys:nil,errorHandler:{ _,error in failure=error; return false }) else { throw SandboxPathError.inaccessible }
            var count=0
            for case let file as URL in entries {
                count += 1; guard count <= 100_000 else { throw AgentError.message("Package source/target alias inventory exceeds its safe bound.") }
                try inspect(file)
            }
            if let failure { throw failure }
        }
        try visit(input) { file,info in
            if info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 {
                let path=try resolver.resolve(file).canonicalURL.path
                shared[identity(info),default:[]].insert(path)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                let target=try resolver.resolve(file)
                if !input.contains(target), writable.contains(where:{ $0.contains(target) }) {
                    throw AgentError.message("Package source symlink overlaps a writable target. Separate the read-only source and target before retrying.")
                }
            }
        }
        guard !shared.isEmpty else { return }
        for root in writable {
            try visit(root) { file,info in
                if info.st_mode & S_IFMT == S_IFREG, let names=shared[identity(info)], !names.contains(try resolver.resolve(file).canonicalURL.path) {
                    throw AgentError.message("Package source and writable target share a hard-linked file. Separate the read-only source and target before retrying.")
                }
            }
        }
    }
}
