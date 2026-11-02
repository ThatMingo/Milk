import Foundation
import Darwin

/// Descriptor-checked executable data, never a probe subprocess or ambient PATH search.
struct SandboxExecutableClosure {
    let executable: URL
    let roots: [SandboxProfileBuilder.Root]
    let searchDirectories: [URL]
    let snapshots: [SandboxResolvedPath]
    func revalidated() -> Bool { snapshots.allSatisfy { $0.revalidated() } }

    static func inspect(_ selected: URL, support: [URL] = [], codeRoot: URL? = nil, toolchain: SandboxToolchainEnvironment? = nil) throws -> Self {
        let resolver=SandboxPathResolver(), fm=FileManager.default
        let original=try resolver.resolve(selected)
        let home=try resolver.resolve(fm.homeDirectoryForCurrentUser).canonicalURL.path
        func narrow(_ url: URL) throws -> URL {
            let p=try resolver.resolve(url)
            guard p.isDirectory, p.canonicalURL.path != "/", p.canonicalURL.path != home else { throw failure("A runtime dependency cannot grant the whole home or filesystem.") }
            return p.canonicalURL
        }
        var search: [URL]=[]
        for path in [selected.deletingLastPathComponent()]+support+[URL(fileURLWithPath:"/usr/bin"),URL(fileURLWithPath:"/bin")] {
            guard let url=try? narrow(path), !search.contains(url) else { continue }; search.append(url)
        }
        var roots: [SandboxProfileBuilder.Root]=[], snapshots: [SandboxResolvedPath]=[], seen:Set<String>=[]
        if let codeRoot { roots.append(.init(url:try narrow(codeRoot))) }
        func bytes(_ path: SandboxResolvedPath, offset: UInt64 = 0) throws -> Data {
            guard path.exists, path.finalIdentity?.kind == S_IFREG else { throw failure("Executable dependencies must be regular local files.") }
            let fd=open(path.canonicalURL.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
            guard fd >= 0 else { throw failure("A selected executable dependency is unreadable.") }
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? file.close() }
            var info=stat(); guard fstat(fd,&info)==0, SandboxFileIdentity(info)==path.finalIdentity else { throw SandboxPathError.changedDuringResolution }
            try file.seek(toOffset:offset)
            return try file.read(upToCount:1_048_576) ?? Data()
        }
        func system(_ path: String) -> Bool { path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") }
        func visit(_ url: URL, executable: Bool, depth: Int = 0, image: URL? = nil, inheritedRpaths: [URL] = []) throws {
            guard depth < 16, seen.count < 128 else { throw failure("Executable dependency chain exceeds the supported bound.") }
            let path=try resolver.resolve(url)
            guard path.revalidated(), !executable || fm.isExecutableFile(atPath:path.canonicalURL.path) else { throw failure("The selected executable/interpreter is unavailable.") }
            guard seen.insert(path.canonicalURL.path).inserted else { return }
            snapshots.append(path); roots.append(.init(url:path.canonicalURL,subtree:false))
            let imageDirectory=executable ? path.canonicalURL.deletingLastPathComponent() : (image ?? original.canonicalURL.deletingLastPathComponent())
            if executable, ["/usr/bin/python3","/usr/bin/swift","/usr/bin/xcodebuild","/usr/bin/xcrun"].contains(path.canonicalURL.path) {
                let selector=URL(fileURLWithPath:"/var/db/xcode_select_link")
                let developer=try toolchain?.developerDirectory ?? resolver.resolve(selector).canonicalURL
                roots.append(.init(url:try narrow(developer)))
                roots.append(.init(url:selector,subtree:false))
                for name in ["Info.plist","version.plist"] { roots.append(.init(url:developer.deletingLastPathComponent().appendingPathComponent(name),subtree:false)) }
                let actual=developer.appendingPathComponent("usr/bin/"+path.canonicalURL.lastPathComponent)
                if fm.isExecutableFile(atPath:actual.path), (try resolver.resolve(actual)).canonicalURL != path.canonicalURL { try visit(actual,executable:true,depth:depth+1) }
            }
            var data=try bytes(path)
            if data.starts(with:[35,33]) {
                guard executable, let end=data.firstIndex(of:10), end <= 4096,
                      let line=String(data:data[2..<end],encoding:.utf8) else { throw failure("Malformed or oversized shebang.") }
                let words=line.trimmingCharacters(in:.whitespacesAndNewlines).split(whereSeparator:{ $0 == " " || $0 == "\t" }).map(String.init)
                guard let name=words.first, name.hasPrefix("/"), !name.utf8.contains(0) else { throw failure("Shebang interpreters must be absolute.") }
                if name == "/usr/bin/env" {
                    guard words.count == 2, !words[1].contains("/"), !words[1].hasPrefix("-"), !words[1].contains("=") else { throw failure("Only env <interpreter> shebangs are supported; env -S/assignments need an explicit launcher.") }
                    guard let interpreter=search.map({ $0.appendingPathComponent(words[1]) }).first(where:{ fm.isExecutableFile(atPath:$0.path) }) else { throw failure("Shebang interpreter is absent from the selected installation/system search roots. Ambient PATH is not used.") }
                    // The launch PATH must select this same interpreter, never a different ambient runtime.
                    try visit(URL(fileURLWithPath:name),executable:true,depth:depth+1)
                    try visit(interpreter,executable:true,depth:depth+1)
                } else {
                    guard words.count <= 2 else { throw failure("Unsupported multi-argument shebang.") }
                    try visit(URL(fileURLWithPath:name),executable:true,depth:depth+1)
                }
                // A selected npm-installed CLI needs its real module graph, not all of HOME/bin.
                var ancestor=path.canonicalURL.deletingLastPathComponent()
                for _ in 0..<16 {
                    if ancestor.lastPathComponent == "node_modules" { roots.append(.init(url:try narrow(ancestor))); break }
                    if ancestor.path == "/" || ancestor.path == home { break }; ancestor.deleteLastPathComponent()
                }
                return
            }
            // Parse load commands directly. No otool/lipo/which child executes untrusted candidates.
            func u32(_ offset: Int, big: Bool = false) throws -> UInt32 {
                guard offset >= 0, offset+4 <= data.count else { throw failure("Truncated Mach-O header/load command.") }
                let value=data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:offset,as:UInt32.self) }
                return big ? UInt32(bigEndian:value) : UInt32(littleEndian:value)
            }
            let magic=try u32(0); var base=0
            if magic == 0xbebafeca || magic == 0xbfbafeca {
                let count=Int(try u32(4,big:true)), wide=magic == 0xbfbafeca
                guard (1...32).contains(count) else { throw failure("Malformed universal executable.") }
                var found: Int?
                for n in 0..<count {
                    let entry=8+n*(wide ? 32:20)
                    if try u32(entry,big:true) == 0x0100000c {
                        if wide {
                            let high=try u32(entry+8,big:true), low=try u32(entry+12,big:true)
                            guard high == 0 else { throw failure("Unsupported universal slice offset.") }; found=Int(low)
                        } else { found=Int(try u32(entry+8,big:true)) }
                        break
                    }
                }
                guard let offset=found else { throw failure("Executable has no Apple Silicon slice.") }; data=try bytes(path,offset:UInt64(offset)); base=0
            }
            guard try u32(base) == 0xfeedfacf, try u32(base+4) == 0x0100000c,
                  [2,6,7].contains(try u32(base+12)) else { throw failure("Expected an arm64 Mach-O executable/library or supported shebang script.") }
            let count=Int(try u32(base+16)), size=Int(try u32(base+20)), start=base+32
            guard count <= 4096, size <= 1_000_000, start+size <= data.count else { throw failure("Unsupported Mach-O command range/slice placement.") }
            var cursor=start, libraries:[String]=[], rpaths:[String]=[]
            func string(_ offset: Int, limit: Int) throws -> String {
                guard offset < limit, limit <= data.count, let end=data[offset..<limit].firstIndex(of:0),
                      let text=String(data:data[offset..<end],encoding:.utf8), !text.isEmpty else { throw failure("Invalid Mach-O dependency path.") }; return text
            }
            for _ in 0..<count {
                let command=try u32(cursor), length=Int(try u32(cursor+4))
                guard length >= 8, cursor+length <= start+size else { throw failure("Malformed Mach-O load command.") }
                if [UInt32(0xc),0x80000018,0x8000001f,0x80000023].contains(command) {
                    let offset=Int(try u32(cursor+8)); guard offset >= 12 else { throw failure("Malformed library reference.") }; libraries.append(try string(cursor+offset,limit:cursor+length))
                }
                if command == 0x8000001c { let offset=Int(try u32(cursor+8)); guard offset >= 12 else { throw failure("Malformed runtime path.") }; rpaths.append(try string(cursor+offset,limit:cursor+length)) }
                if command == 0x27 { throw failure("Embedded dynamic-loader environment commands are unsupported.") }
                cursor += length
            }
            guard cursor == start+size else { throw failure("Inconsistent Mach-O command table.") }
            func expand(_ value: String) throws -> URL {
                if value == "@loader_path" { return path.canonicalURL.deletingLastPathComponent() }
                if value == "@executable_path" { return imageDirectory }
                if value.hasPrefix("@loader_path/") { return path.canonicalURL.deletingLastPathComponent().appendingPathComponent(String(value.dropFirst(13))) }
                if value.hasPrefix("@executable_path/") { return imageDirectory.appendingPathComponent(String(value.dropFirst(17))) }
                if value.hasPrefix("/") { return URL(fileURLWithPath:value) }
                throw failure("Relative/unresolved dynamic-loader paths are unsupported.")
            }
            for library in libraries {
                if system(library) { continue } // macOS shared-cache images need not exist as disk files.
                let dependency: URL
                if library.hasPrefix("@rpath/") {
                    let suffix=String(library.dropFirst(7))
                    let candidates=(try rpaths.map { try expand($0) } + inheritedRpaths).map { $0.appendingPathComponent(suffix) }
                    if let found=candidates.first(where:{ fm.fileExists(atPath:$0.path) }) { dependency=found }
                    else if candidates.contains(where:{ system($0.path) }) { continue }
                    else { throw failure("A dynamic runtime dependency cannot be resolved from declared rpaths.") }
                } else { dependency=try expand(library) }
                try visit(dependency,executable:false,depth:depth+1,image:imageDirectory,inheritedRpaths:try rpaths.map { try expand($0) }+inheritedRpaths)
            }
        }
        try visit(selected,executable:true)
        return .init(executable:original.canonicalURL,roots:roots,searchDirectories:search,snapshots:snapshots)
    }
    static func failure(_ message: String) -> AgentError { .message("Sandbox executable closure: "+message+" No unrestricted retry was used.") }
}
