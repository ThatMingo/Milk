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

/// One runtime revision Milk is willing to build, with everything needed to
/// verify it without a network round trip.
struct PiCatalogRelease: Codable, Equatable {
    let version: String
    let platform: String
    let architecture: String
    let source: URL
    let artifacts: [PiArtifact]
    /// Pinned digests for `requiredPaths`. Empty for a freshly discovered
    /// upstream candidate; pinned from the verified inventory during staging.
    let files: [String: String]
    let executables: [String]
    let notices: [String]
    let provenance: String
    /// Paths the extracted runtime must contain. Defaults to the pinned files.
    var requiredPaths: [String]?
    var origin: PiReleaseOrigin?

    var paths: [String] { requiredPaths ?? Array(files.keys) }

    /// Self-consistency of metadata already held locally. This is deliberately
    /// network-free: an offline machine can still launch a verified revision.
    func validate() throws {
        guard let version = PiSemanticVersion.parse(self.version), version.isStable else {
            throw AgentError.message("Runtime release metadata has an invalid version: \(self.version).")
        }
        guard version >= PiCompatibilityPolicy.minimumEligibleVersion else {
            throw AgentError.message("Runtime release \(self.version) is older than the Pi baseline this adapter supports.")
        }
        guard platform == "darwin", architecture == PiInstallationCatalog.architecture else {
            throw AgentError.message("Runtime release metadata is not for this platform or architecture.")
        }
        guard !artifacts.isEmpty, artifacts.allSatisfy({ PiInstallationFiles.isDigest($0.sha256) && $0.url.scheme == "https" && PiInstallationFiles.safePath($0.destination) }),
              executables.allSatisfy(PiInstallationFiles.safePath), !executables.isEmpty,
              notices.allSatisfy(PiInstallationFiles.safePath), !notices.isEmpty,
              paths.allSatisfy(PiInstallationFiles.safePath), paths.contains("pi"),
              files.keys.allSatisfy(PiInstallationFiles.safePath), files.values.allSatisfy(PiInstallationFiles.isDigest),
              // A discovered candidate has no pinned file digests yet; they are pinned
              // from the verified inventory during staging. Once pinned, the launcher
              // executable must be one of the pinned files.
              (files.isEmpty || files["pi"] != nil) else {
            throw AgentError.message("Runtime release metadata is missing, invalid, or unusable for this platform/architecture.")
        }
        for path in executables where !paths.contains(path) { throw AgentError.message("Runtime release metadata does not require its executable \(path).") }
        if let origin {
            guard origin.isValid() else { throw AgentError.message("Runtime release provenance metadata is invalid.") }
            guard origin.assetName == PiUpstreamRelease.archiveAsset else { throw AgentError.message("Runtime release provenance names an asset for another platform/architecture.") }
            guard artifacts.contains(where: { $0.url.path.hasSuffix("/" + origin.assetName) && $0.sha256 == origin.assetSHA256 }) else {
                throw AgentError.message("Runtime release provenance does not match its artifact pins.")
            }
        }
    }

    /// Pin the discovered runtime layout with the digests of the bytes that were
    /// actually verified, so later launches can detect local modification.
    func pinning(_ inventory: [String: String]) throws -> PiCatalogRelease {
        let required = paths
        let pinned = required.compactMap { path -> (String, String)? in inventory[path].map { (path, $0) } }
        guard pinned.count == required.count, pinned.allSatisfy({ PiInstallationFiles.isDigest($0.1) } ) else {
            throw AgentError.message("Verified runtime layout is missing required files; it was not registered.")
        }
        return PiCatalogRelease(version: version, platform: platform, architecture: architecture, source: source, artifacts: artifacts,
                               files: Dictionary(uniqueKeysWithValues: pinned), executables: executables, notices: notices,
                               provenance: provenance, requiredPaths: required, origin: origin)
    }
}

/// Milk-pinned runtime material. Production releases are discovered from the
/// official upstream repository by `PiReleaseDiscovery`; nothing here is a list
/// of approved Pi versions.
struct PiInstallationCatalog {
    /// Fixture/test and baseline metadata only.
    let releases: [PiCatalogRelease]
    /// Milk-pinned auxiliary runtime artifacts (search tools). Their digests are
    /// Milk trust anchors, not inferred from the Pi archive.
    let tools: [PiArtifact]

    init(releases: [PiCatalogRelease], tools: [PiArtifact]? = nil) {
        self.releases = releases
        self.tools = tools ?? Self.toolArtifacts(for: Self.architecture)
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static let standard = Self(releases: [])

    /// Search tools Milk supplies alongside the upstream Pi runtime. Only the
    /// Apple Silicon (arm64) tool pins are Milk-verified: Milk ships for Apple
    /// Silicon only, and an unverified tool pin is never downloaded on another
    /// architecture.
    static let arm64ToolArtifacts: [PiArtifact] = [
        .init(url: URL(string: "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz")!,
            sha256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4", binarySuffix: "rg", destination: "bin/rg"),
        .init(url: URL(string: "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz")!,
            sha256: "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12", binarySuffix: "fd", destination: "bin/fd")
    ]
    static func toolArtifacts(for architecture: String) -> [PiArtifact] { architecture == "arm64" ? arm64ToolArtifacts : [] }
    static var toolArtifacts: [PiArtifact] { toolArtifacts(for: architecture) }
    func runtimeExecutables(architecture: String) -> [String] { ["pi"] + tools.map(\.destination) }
    func runtimeRequiredPaths(architecture: String) -> [String] {
        ["pi", "photon_rs_bg.wasm", "native/darwin/prebuilds/darwin-\(architecture)/darwin-platform.node"] + tools.map(\.destination)
    }
    /// Notices bundled with Milk that are not tied to one Pi release.
    static let upstreamNotices: [String] = ["Pi-LICENSE", "Bun-LICENSE.md", "Runtime-Libraries.txt",
        "modelcontextprotocol-typescript-sdk.txt", "ripgrep/LICENSE-MIT", "ripgrep/UNLICENSE", "ripgrep/COPYING",
        "fd/LICENSE-MIT", "fd/LICENSE-APACHE"]

    func release(for version: String) throws -> PiCatalogRelease {
        guard let value = releases.first(where: { $0.version == version }) else {
            throw AgentError.message("No verified Pi release metadata for \(version). Check for updates or install the latest stable Pi.")
        }
        try value.validate()
        return value
    }
    static func isDigest(_ value: String) -> Bool { PiInstallationFiles.isDigest(value) }
}

enum PiInstallationFiles {
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), chunk = 1024 * 1024
        while let bytes = try handle.read(upToCount: chunk), !bytes.isEmpty { hash.update(data: bytes) }
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
    /// Layout + architecture validation, plus pinned digests when they exist.
    static func validate(_ root: URL, release: PiCatalogRelease) throws -> [String: String] {
        let inventory = try inventory(root)
        for path in release.paths {
            guard inventory[path] != nil else { throw AgentError.message("Managed Pi runtime is missing a required file: \(path).") }
        }
        for (path, hash) in release.files {
            guard inventory[path] == hash else { throw AgentError.message("Managed Pi integrity check failed: \(path).") }
        }
        for path in release.executables {
            let file = root.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: file.path) else { throw AgentError.message("Missing executable runtime dependency: \(path).") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            // Require a native thin 64-bit Mach-O matching the release; reject scripts/fat/ELF.
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
