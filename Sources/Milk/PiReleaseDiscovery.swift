import Foundation

// MARK: - Semantic versions
//
// Upstream Pi releases are ordered as semantic versions. String comparison is
// deliberately not used: "1.10.0" is newer than "1.9.0".
struct PiSemanticVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    static func parse(_ text: String) -> PiSemanticVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        // Build metadata ("+anything") never affects precedence, so it is dropped.
        let third = (parts[2].split(separator: "+", omittingEmptySubsequences: false).first ?? "").split(separator: "-", omittingEmptySubsequences: false)
        guard !third.isEmpty, third.allSatisfy({ !$0.isEmpty }), let patch = Int(third[0]) else { return nil }
        return .init(major: major, minor: minor, patch: patch, prerelease: third.count > 1 ? third.dropFirst().joined(separator: "-") : nil)
    }
    var text: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "") }
    var isStable: Bool { prerelease == nil }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease == rhs.prerelease { return false }
        if lhs.prerelease == nil { return false }   // a pre-release precedes its stable release
        if rhs.prerelease == nil { return true }
        return lhs.prerelease! < rhs.prerelease!
    }
}

// MARK: - Release provenance
//
// Where a `PiCatalogRelease`'s expected bytes came from. It is stored with every
// managed revision so an offline launch can still prove the revision it already
// holds matches the release Milk verified, without asking the network again.
struct PiReleaseOrigin: Codable, Equatable {
    enum Kind: String, Codable { case milkPinned, upstreamRelease }
    let kind: Kind
    let repository: String
    let tag: String
    let releaseURL: URL
    let assetName: String
    let assetSHA256: String
    let sumsURL: URL?
    let sumsSHA256: String?
    let dependencyLockSHA256: String?
    let discoveredAt: Date

    func isValid() -> Bool {
        PiInstallationFiles.isDigest(assetSHA256) && (sumsSHA256 == nil || PiInstallationFiles.isDigest(sumsSHA256!)) &&
        (dependencyLockSHA256 == nil || PiInstallationFiles.isDigest(dependencyLockSHA256!)) &&
        repository == PiUpstreamRelease.repository && !tag.isEmpty && !assetName.isEmpty &&
        releaseURL.scheme == "https" && (sumsURL == nil || sumsURL!.scheme == "https") &&
        tag.hasPrefix("v" + version)
    }
    var detail: String {
        switch kind {
        case .milkPinned:
            return "Milk-pinned runtime metadata for \(tag). Dependency notices are the notices bundled with Milk."
        case .upstreamRelease:
            return "Discovered from official upstream release \(tag) in \(repository). Trust source: the GitHub release API asset digest over HTTPS" +
                (sumsSHA256 != nil ? ", cross-checked against that release's SHA256SUMS manifest" : ", no SHA256SUMS manifest published") +
                ". Release metadata is a trust source, not an independently signed manifest."
        }
    }
    var version: String { String(tag.dropFirst("v".count)) }
}

enum PiUpstreamRelease {
    /// The only repository Milk will ever read Pi release metadata from.
    static let repository = "earendil-works/pi"
    static let apiURL = URL(string: "https://api.github.com/repos/earendil-works/pi/releases?per_page=50")!
    static var archiveAsset: String {
        // Official upstream asset names: pi-darwin-arm64.tar.gz / pi-darwin-x64.tar.gz.
        "pi-darwin-\(PiInstallationCatalog.architecture == "arm64" ? "arm64" : "x64").tar.gz"
    }
    static let sumsAsset = "SHA256SUMS"
    static let dependencyLockAsset = "pi-coding-agent-install-package-lock.json"
}

/// One normalised, already-validated upstream release.
struct PiReleaseCandidate: Codable, Equatable {
    let version: String
    let tag: String
    let releaseURL: URL
    let archiveURL: URL
    let archiveSHA256: String
    let sumsURL: URL?
    let sumsSHA256: String?
    let dependencyLockURL: URL?
    let dependencyLockSHA256: String?
    let publishedAt: Date?
}

/// Reads upstream Pi release metadata over HTTPS.
///
/// Trust model (explicit): GitHub's release API for the official
/// `earendil-works/pi` repository is Milk's trust source for release identity and
/// for the official per-asset SHA-256 digest. That is a metadata trust boundary,
/// not an independently signed or notarised manifest: if the official repository
/// or GitHub itself were compromised, Milk would accept the compromised asset.
/// Digests are always taken from upstream metadata and compared with the
/// downloaded bytes before anything is extracted or executed. A digest computed
/// from an unverified download is never treated as proof of authenticity; it only
/// becomes integrity metadata for a revision Milk already installed.
struct PiReleaseDiscovery {
    typealias Fetch = (URL) async throws -> Data
    let fetch: Fetch
    let apiURL: URL

    init(fetch: Fetch? = nil, apiURL: URL = PiUpstreamRelease.apiURL) {
        self.fetch = fetch ?? PiReleaseDiscovery.defaultFetch
        self.apiURL = apiURL
    }

    static func defaultFetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host != nil else { throw AgentError.message("Pi release metadata must be fetched over HTTPS.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw AgentError.message("Pi release metadata returned an unknown response.") }
        guard http.statusCode == 200 else { throw AgentError.message("Pi release metadata request failed with status \(http.statusCode).") }
        return data
    }

    func eligibleReleases(for architecture: String = PiInstallationCatalog.architecture, tools: [PiArtifact]? = nil) async throws -> [PiCatalogRelease] {
        let data = try await fetch(apiURL)
        return try Self.releases(from: data, architecture: architecture, tools: tools ?? PiInstallationCatalog.toolArtifacts(for: architecture))
    }
    func latestEligibleRelease() async throws -> PiCatalogRelease? { (try await eligibleReleases()).first }

    /// Pure validation of the GitHub release document, separated from the network
    /// so the trust rules are testable with fixtures.
    static func releases(from data: Data, architecture: String, tools: [PiArtifact]? = nil) throws -> [PiCatalogRelease] {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data), case .array(let releases) = decoded else {
            throw AgentError.message("Pi release metadata is not a JSON array.")
        }
        let pins = tools ?? PiInstallationCatalog.toolArtifacts(for: architecture)
        return releases.compactMap { candidate(from: $0, architecture: architecture) }.map { release(for: $0, architecture: architecture, tools: pins) }
            .sorted { PiSemanticVersion.parse($0.version)! > PiSemanticVersion.parse($1.version)! }
    }

    struct Asset {
        let name: String
        let downloadURL: URL
        let digest: String?
    }

    static func asset(_ assets: [JSONValue], named name: String, tag: String) -> Asset? {
        for value in assets {
            guard value["name"].string == name, let raw = value["browser_download_url"].string, let url = URL(string: raw) else { continue }
            // Exact official download path for this repository and tag.
            guard url.scheme == "https", url.host == "github.com",
                  url.path == "/\(PiUpstreamRelease.repository)/releases/download/\(tag)/\(name)" else { continue }
            let digest = value["digest"].string.flatMap { text -> String? in
                guard text.hasPrefix("sha256:") else { return nil }
                let hex = String(text.dropFirst("sha256:".count))
                return PiInstallationFiles.isDigest(hex) ? hex : nil
            }
            return Asset(name: name, downloadURL: url, digest: digest)
        }
        return nil
    }

    static func candidate(from release: JSONValue, architecture: String) -> PiReleaseCandidate? {
        let tag = release["tag_name"].string ?? ""
        guard tag.hasPrefix("v"), let version = PiSemanticVersion.parse(String(tag.dropFirst())), version.isStable else { return nil }
        // Stable releases only: pre-releases and drafts are never eligible.
        if release["prerelease"].bool || release["draft"].bool { return nil }
        // Anything older than the adapter baseline is not offered at all.
        guard version >= PiCompatibilityPolicy.minimumEligibleVersion else { return nil }
        let repositoryURL = URL(string: "https://github.com/\(PiUpstreamRelease.repository)")!
        guard release["html_url"].string == repositoryURL.appendingPathComponent("releases/tag/\(tag)").absoluteString else { return nil }
        let assets = release["assets"].array
        guard !assets.isEmpty else { return nil }
        // Required integrity information: the official archive asset with a
        // SHA-256 digest published by the release API.
        guard let archive = asset(assets, named: PiUpstreamRelease.archiveAsset, tag: tag), let digest = archive.digest else { return nil }
        let sums = asset(assets, named: PiUpstreamRelease.sumsAsset, tag: tag)
        let lock = asset(assets, named: PiUpstreamRelease.dependencyLockAsset, tag: tag)
        return .init(version: version.text, tag: tag,
                    releaseURL: repositoryURL.appendingPathComponent("releases/tag/\(tag)"),
                    archiveURL: archive.downloadURL, archiveSHA256: digest,
                    sumsURL: sums?.downloadURL, sumsSHA256: sums?.digest,
                    dependencyLockURL: lock?.downloadURL, dependencyLockSHA256: lock?.digest,
                    publishedAt: parseDate(release["published_at"].string))
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Build the Milk runtime release for a validated upstream candidate. File
    /// digests are pinned after the archive is verified and extracted.
    static func release(for candidate: PiReleaseCandidate, architecture: String, tools: [PiArtifact] = PiInstallationCatalog.toolArtifacts) -> PiCatalogRelease {
        let assetName = PiUpstreamRelease.archiveAsset
        let origin = PiReleaseOrigin(kind: .upstreamRelease, repository: PiUpstreamRelease.repository, tag: candidate.tag,
            releaseURL: candidate.releaseURL, assetName: assetName, assetSHA256: candidate.archiveSHA256,
            sumsURL: candidate.sumsURL, sumsSHA256: candidate.sumsSHA256, dependencyLockSHA256: candidate.dependencyLockSHA256,
            discoveredAt: candidate.publishedAt ?? .now)
        return PiCatalogRelease(version: candidate.version, platform: "darwin", architecture: architecture, source: candidate.releaseURL,
            artifacts: [PiArtifact(url: candidate.archiveURL, sha256: candidate.archiveSHA256, binarySuffix: nil, destination: "pi")] + tools,
            files: [:], executables: ["pi"] + tools.map(\.destination), notices: PiInstallationCatalog.upstreamNotices,
            provenance: origin.detail,
            requiredPaths: ["pi", "photon_rs_bg.wasm", "native/darwin/prebuilds/darwin-\(architecture)/darwin-platform.node"] + tools.map(\.destination),
            origin: origin)
    }

    /// Cross-check the archive digest against the release's own SHA256SUMS
    /// manifest. The manifest is authenticated by GitHub's asset digest first.
    static func verifySums(candidateDigest: String, sumsSHA256: String?, sumsBytes: Data) throws {
        if let expected = sumsSHA256 {
            guard PiInstallationFiles.digest(sumsBytes) == expected else {
                throw AgentError.message("The Pi release SHA256SUMS manifest did not match the digest published by the official release.")
            }
        }
        var found = false
        for line in String(data: sumsBytes, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let digest = String(fields.first!), name = String(fields.last!)
            guard name == PiUpstreamRelease.archiveAsset else { continue }
            guard PiInstallationFiles.isDigest(digest) else {
                throw AgentError.message("Pi release SHA256SUMS contains an invalid digest for \(name).")
            }
            found = true
            guard digest == candidateDigest else {
                throw AgentError.message("Pi release integrity metadata is inconsistent: SHA256SUMS disagrees with the release asset digest.")
            }
        }
        if !found { throw AgentError.message("The Pi release SHA256SUMS manifest does not list \(PiUpstreamRelease.archiveAsset).") }
    }
}
