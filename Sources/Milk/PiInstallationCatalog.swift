import Foundation
import CryptoKit
import MilkArchive

struct PiArtifact: Codable, Equatable {
    let url: URL
    let sha256: String
    /// nil copies the complete archive root; a suffix selects one tool binary.
    let binarySuffix: String?
    let destination: String
}
struct PiCatalogRelease: Codable, Equatable {
    let version: String
    let platform: String
    let architecture: String
    let source: URL
    let artifacts: [PiArtifact]
    let files: [String: String]
    let executables: [String]
    let notices: [String]
    let provenance: String
}

/// Milk-owned approval, not an upstream latest feed. Pins come from the repository's
/// runtime-manifest.json and bootstrap-runtime.py, not inferred release URLs.
struct PiInstallationCatalog {
    let releases: [PiCatalogRelease]
    static let standard = Self(releases: [.init(version: "1.4.0", platform: "darwin", architecture: "arm64",
        source: URL(string: "https://github.com/earendil-works/pi/releases/tag/v1.4.0")!, artifacts: [
            .init(url: URL(string: "https://github.com/earendil-works/pi/releases/download/v1.4.0/pi-darwin-arm64.tar.gz")!, sha256: "79d9979d76a2a5adb7c28e27e9b44629928ccd0dc9fbb6ae7217860bd5e8be5d", binarySuffix: nil, destination: "pi"),
            .init(url: URL(string: "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz")!, sha256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4", binarySuffix: "rg", destination: "bin/rg"),
            .init(url: URL(string: "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz")!, sha256: "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12", binarySuffix: "fd", destination: "bin/fd")
        ], files: [
            "pi": "b4d93b78e542ca8d1792242cf6c1a875ef4e6fb644141fb4cf67ec7c81ef9b14",
            "bin/rg": "a326a1fb48074202e9ad41e4cd1e389eeea372c8c6f7d7e80da81176d5d9430e",
            "bin/fd": "cf3bde435da174f41cf9589a2efeaf03804df7c250fc15e8b8a1e9bfc66ebc9a",
            "photon_rs_bg.wasm": "10468181565c56004c867f3a4af96f89a0ef5a63a72f2b5fb12c1f1992a3615c",
            "native/darwin/prebuilds/darwin-arm64/darwin-platform.node": "36e909adf35c2734a2a52b3d65b7dbfb83f2278f306d51b7e32c5045516dfb7f"
        ], executables: ["pi", "bin/rg", "bin/fd"], notices: ["Pi-LICENSE", "Pi-Dependencies.txt", "Bun-LICENSE.md", "Runtime-Libraries.txt", "modelcontextprotocol-typescript-sdk.txt", "pi-install-package-lock.json", "ripgrep/LICENSE-MIT", "ripgrep/UNLICENSE", "ripgrep/COPYING", "fd/LICENSE-MIT", "fd/LICENSE-APACHE"],
        provenance: "Repository-verified upstream artifact pins. Bun/native corresponding-source and relink closure remains unresolved; this is not distribution clearance.")])
    func approved(_ version: String) throws -> PiCatalogRelease {
        guard let value = releases.first(where: { $0.version == version }) else { throw AgentError.message("No Milk-approved Pi artifact metadata for \(version).") }
        try PiCompatibilityPolicy.requireSupportedVersion(PiCompatibilityPolicy.evaluate(version: version))
        guard value.platform == "darwin", value.architecture == Self.architecture,
              !value.artifacts.isEmpty, value.files["pi"] != nil, !value.notices.isEmpty,
              value.files.values.allSatisfy(Self.isDigest), value.artifacts.allSatisfy({ Self.isDigest($0.sha256) && $0.url.scheme == "https" }),
              value.files.keys.allSatisfy(PiInstallationFiles.safePath), value.executables.allSatisfy(PiInstallationFiles.safePath),
              value.notices.allSatisfy(PiInstallationFiles.safePath), value.artifacts.allSatisfy({ PiInstallationFiles.safePath($0.destination) }) else {
            throw AgentError.message("Approved artifact metadata is missing, invalid, or unavailable for this platform/architecture.")
        }
        return value
    }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}

enum PiInstallationFiles {
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func extract(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var error = [CChar](repeating: 0, count: 1024)
        guard milk_extract_archive(archive.path, directory.path, &error, error.count) == 0 else { throw AgentError.message(String(cString: error)) }
    }
    static func inventory(_ root: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        let prefix = root.standardizedFileURL.path + "/"
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw AgentError.message("Cannot inspect managed runtime files.") }
        for case let file as URL in entries {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard info.isSymbolicLink != true else { throw AgentError.message("Managed runtimes cannot contain symbolic links.") }
            if info.isRegularFile == true {
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { throw AgentError.message("Runtime inventory escaped its installation root.") }
                values[String(path.dropFirst(prefix.count))] = try digest(file)
            }
            else if info.isDirectory != true { throw AgentError.message("Managed runtime contains a special file.") }
        }
        return values
    }
    static func validate(_ root: URL, release: PiCatalogRelease) throws -> [String: String] {
        let inventory = try inventory(root)
        for (path, hash) in release.files {
            guard inventory[path] == hash else { throw AgentError.message("Managed Pi integrity check failed: \(path).") }
        }
        for path in release.executables {
            let file = root.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: file.path) else { throw AgentError.message("Missing executable runtime dependency: \(path).") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            // Require a native thin 64-bit Mach-O matching the catalog; reject scripts/fat/ELF.
            let cpu: [UInt8] = release.architecture == "arm64" ? [12,0,0,1] : [7,0,0,1]
            guard header.count >= 12, Array(header.prefix(4)) == [207,250,237,254], Array(header[4..<8]) == cpu else {
                throw AgentError.message("Wrong platform or architecture for \(path).")
            }
        }
        // Native Pi support modules are also Mach-O; their content is pinned above.
        return inventory
    }
    static func download(_ source: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https" else { throw AgentError.message("Pi artifact download failed.") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
