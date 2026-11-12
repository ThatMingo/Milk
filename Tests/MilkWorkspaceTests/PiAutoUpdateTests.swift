import XCTest
import CryptoKit
@testable import Milk

// Automatic Pi runtime updates: upstream discovery, integrity verification,
// compatibility probing, staged activation, rollback and offline behaviour.
// Every fixture is local; no test downloads a real Pi artifact.
final class PiAutoUpdateTests: XCTestCase {
    @MainActor private final class Gate {
        var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
        func release() { open = true; let old = waiters; waiters = []; old.forEach { $0.resume() } }
    }
    @MainActor private final class HeldRuntime: AgentOwnedResource {
        let exit = Gate()
        var stopping = false
        func shutdown() { stopping = true }
        func shutdownAndWait() async throws { stopping = true; await exit.wait() }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func machO(_ tag: String) -> Data {
        let cpu: [UInt8] = PiInstallationCatalog.architecture == "arm64" ? [12, 0, 0, 1] : [7, 0, 0, 1]
        return Data([207, 250, 237, 254] + cpu + [0, 0, 0, 0]) + Data("fixture code \(tag), never run".utf8)
    }
    /// Minimal POSIX tar fixture exercised by the production libarchive extractor.
    private func tar(_ entries: [(String, Data, UInt8)]) -> Data {
        var result = Data()
        for (name, data, type) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ text: String, _ offset: Int, _ length: Int) {
                for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
            }
            field(name, 0, 100); field("0000700", 100, 8); field("0000000", 108, 8); field("0000000", 116, 8)
            field(String(format: "%011o", data.count), 124, 12); field("00000000000", 136, 12)
            for i in 148..<156 { header[i] = 32 }
            header[156] = type; field("ustar", 257, 6); field("00", 263, 2)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
            result.append(contentsOf: header); result.append(data)
            if data.count % 512 != 0 { result.append(Data(repeating: 0, count: 512 - data.count % 512)) }
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    private func piArchive(_ version: String) -> Data {
        tar([("pi/pi", machO(version), 48),
             ("pi/photon_rs_bg.wasm", Data("runtime dependency \(version)".utf8), 48),
             ("pi/native/darwin/prebuilds/darwin-\(PiInstallationCatalog.architecture)/darwin-platform.node", Data("native support \(version)".utf8), 48)])
    }
    private func sumsFor(_ version: String) -> Data {
        Data("\(hash(piArchive(version)))  pi-darwin-\(PiInstallationCatalog.architecture).tar.gz\n  0000000000000000000000000000000000000000000000000000000000000000  pi-linux-x64.tar.gz\n".utf8)
    }

    struct FakeRelease {
        let tag: String, version: String
        let archive: Data, sums: Data
        let prerelease: Bool, draft: Bool
        let assetHost: String, missingDigest: Bool
    }
    private func archiveURL(_ tag: String) -> URL {
        URL(string: "https://github.com/earendil-works/pi/releases/download/\(tag)/\(PiUpstreamRelease.archiveAsset)")!
    }
    private func assetJSON(_ name: String, _ tag: String, _ digest: String?, host: String = "github.com") -> String {
        let digestField = digest.map { ", \"digest\": \"sha256:\($0)\"" } ?? ""
        return "{\"name\": \"\(name)\", \"browser_download_url\": \"https://\(host)/earendil-works/pi/releases/download/\(tag)/\(name)\"\(digestField)}"
    }
    private func releaseJSON(_ release: FakeRelease) -> String {
        let assets = [assetJSON(PiUpstreamRelease.archiveAsset, release.tag, release.missingDigest ? nil : hash(release.archive), host: release.assetHost),
                      assetJSON(PiUpstreamRelease.sumsAsset, release.tag, hash(release.sums))]
        return "{\"tag_name\": \"\(release.tag)\", \"prerelease\": \(release.prerelease), \"draft\": \(release.draft), " +
            "\"html_url\": \"https://github.com/earendil-works/pi/releases/tag/\(release.tag)\", " +
            "\"published_at\": \"2026-11-10T12:25:43Z\", \"assets\": [\(assets.joined(separator: ","))]}"
    }
    private func apiJSON(_ releases: [FakeRelease]) -> Data { Data(("[" + releases.map(releaseJSON).joined(separator: ",") + "]").utf8) }

    @MainActor private final class Feed {
        var releases: [FakeRelease] = []
        var bytes: [URL: Data] = [:]
        var offline = false
        var tamper: String?
        var downloads = 0
        var fetches = 0
        var probes = 0
        var gate: Gate?
        var downloading = false
        var failingProbeVersions = Set<String>()
    }

    @MainActor private func updateFixture(versions: [String]) throws -> (PiInstallationManager, Feed, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk AutoUpdate " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notices = root.appendingPathComponent("notices")
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        for name in PiInstallationCatalog.upstreamNotices {
            let target = notices.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture notice \(name)".utf8).write(to: target)
        }
        let feed = Feed()
        for version in versions {
            let release = FakeRelease(tag: "v" + version, version: version, archive: piArchive(version), sums: sumsFor(version),
                                     prerelease: false, draft: false, assetHost: "github.com", missingDigest: false)
            feed.releases.append(release)
            feed.bytes[archiveURL(release.tag)] = release.archive
            feed.bytes[URL(string: "https://github.com/earendil-works/pi/releases/download/\(release.tag)/\(PiUpstreamRelease.sumsAsset)")!] = release.sums
        }
        // Fixture tool pins: Milk-pinned digests must match the bytes served, so the
        // test catalog carries digests computed from the fixture archives.
        let rg = tar([("ripgrep-15.2.0/rg", machO("rg"), 48)]), fd = tar([("fd-10.5.0/fd", machO("fd"), 48)])
        let tools = [PiArtifact(url: PiInstallationCatalog.toolArtifacts[0].url, sha256: hash(rg), binarySuffix: "rg", destination: "bin/rg"),
                     PiArtifact(url: PiInstallationCatalog.toolArtifacts[1].url, sha256: hash(fd), binarySuffix: "fd", destination: "bin/fd")]
        feed.bytes[tools[0].url] = rg; feed.bytes[tools[1].url] = fd
        let ordinary = root.appendingPathComponent("ordinary Pi data")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        for name in ["auth.json", "settings.json", "session.jsonl", "extension.ts"] { try Data(name.utf8).write(to: ordinary.appendingPathComponent(name)) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("fixture integration".utf8).write(to: resources.appendingPathComponent("MilkPiIntegration.ts"))
        let runtime = PiRuntimeService(resources: resources, environmentOverrides: ["PI_CODING_AGENT_DIR": ordinary.path])
        let storeRoot = root.appendingPathComponent("Agents/pi")
        let manager = fixtureManager(feed: feed, tools: tools, runtime: runtime, notices: notices, storeRoot: storeRoot)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (manager, feed, root, notices)
    }
    /// Manager construction shared by the fixture and the restart tests, so a "restart"
    /// re-reads persisted state with a fresh in-memory release cache.
    @MainActor private func fixtureManager(feed: Feed, tools: [PiArtifact], runtime: PiRuntimeService, notices: URL, storeRoot: URL) -> PiInstallationManager {
        let discovery = PiReleaseDiscovery(fetch: { url in
            if feed.offline { throw AgentError.message("the fixture is offline") }
            feed.fetches += 1
            return feed.bytes[url] ?? (url == PiUpstreamRelease.apiURL ? self.apiJSON(feed.releases) : Data())
        })
        return PiInstallationManager(store: .init(root: storeRoot), lifecycle: .init(), runtime: runtime,
            catalog: .init(releases: [], tools: tools), notices: notices, discovery: discovery,
            download: { url, destination in
                feed.downloads += 1; feed.downloading = true
                await feed.gate?.wait()
                try Task.checkCancellation()
                guard let data = feed.bytes[url] else { throw AgentError.message("fixture has no artifact for \(url)") }
                if let marker = feed.tamper { var copy = data; copy.append(Data(marker.utf8)); try copy.write(to: destination) }
                else { try data.write(to: destination) }
            },
            probe: { record, _, _ in
                feed.probes += 1
                XCTAssertEqual(record.ownership, .milkManaged)
                let version = record.expectedVersion ?? ""
                if feed.failingProbeVersions.contains(version) {
                    return PiCompatibilityPolicy.result(.incompatibleIntegration, version: version, detail: "fixture probe rejected Pi \(version)")
                }
                return PiCompatibilityPolicy.verified(version: version)
            })
    }
    /// A manager that never touches the fixture store: assigning it ends the first session
    /// and releases the store's ownership lock.
    @MainActor private func addRelease(to feed: Feed, version: String) {
        let release = FakeRelease(tag: "v" + version, version: version, archive: piArchive(version), sums: sumsFor(version),
                                  prerelease: false, draft: false, assetHost: "github.com", missingDigest: false)
        feed.releases.append(release)
        feed.bytes[archiveURL(release.tag)] = release.archive
        feed.bytes[URL(string: "https://github.com/earendil-works/pi/releases/download/\(release.tag)/\(PiUpstreamRelease.sumsAsset)")!] = release.sums
    }
    @MainActor private func retiredManager(root: URL, notices: URL) -> PiInstallationManager {
        PiInstallationManager(store: .init(root: root.appendingPathComponent("retired-session")), lifecycle: .init(), runtime: PiRuntimeService(),
            catalog: .init(releases: [], tools: []), notices: notices, discovery: PiReleaseDiscovery(fetch: { _ in Data("[]".utf8) }),
            probe: { _, _, _ in PiCompatibilityPolicy.verified(version: "1.0.0") })
    }
    /// A fresh manager over the same persisted store: this models restarting Milk.
    @MainActor private func restartedManager(feed: Feed, root: URL, notices: URL) -> PiInstallationManager {
        let rg = tar([("ripgrep-15.2.0/rg", machO("rg"), 48)]), fd = tar([("fd-10.5.0/fd", machO("fd"), 48)])
        let tools = [PiArtifact(url: PiInstallationCatalog.toolArtifacts[0].url, sha256: hash(rg), binarySuffix: "rg", destination: "bin/rg"),
                     PiArtifact(url: PiInstallationCatalog.toolArtifacts[1].url, sha256: hash(fd), binarySuffix: "fd", destination: "bin/fd")]
        feed.bytes[tools[0].url] = rg; feed.bytes[tools[1].url] = fd
        let runtime = PiRuntimeService(resources: root.appendingPathComponent("resources"),
                                      environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("ordinary Pi data").path])
        return fixtureManager(feed: feed, tools: tools, runtime: runtime, notices: notices, storeRoot: root.appendingPathComponent("Agents/pi"))
    }
    @MainActor private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() { if Date() > deadline { throw AgentError.message("Timed out: " + description) }; await Task.yield() }
    }
    @MainActor private func rejects(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected a rejected operation", file: file, line: line) } catch { }
    }

    // MARK: - Discovery and trust rules

    func testDiscoveryKeepsOnlyStableOfficialPlatformReleasesInSemanticOrder() throws {
        let releases = [
            FakeRelease(tag: "v1.5.2", version: "1.5.2", archive: piArchive("1.5.2"), sums: sumsFor("1.5.2"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: false),
            FakeRelease(tag: "v1.10.0", version: "1.10.0", archive: piArchive("1.10.0"), sums: sumsFor("1.10.0"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: false),
            FakeRelease(tag: "v1.9.0", version: "1.9.0", archive: piArchive("1.9.0"), sums: sumsFor("1.9.0"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: false),
            FakeRelease(tag: "v2.0.0-beta", version: "2.0.0-beta", archive: piArchive("beta"), sums: sumsFor("beta"), prerelease: true, draft: false, assetHost: "github.com", missingDigest: false),
            FakeRelease(tag: "v1.6.0", version: "1.6.0", archive: piArchive("1.6.0"), sums: sumsFor("1.6.0"), prerelease: false, draft: true, assetHost: "github.com", missingDigest: false),
            FakeRelease(tag: "v1.7.0", version: "1.7.0", archive: piArchive("1.7.0"), sums: sumsFor("1.7.0"), prerelease: false, draft: false, assetHost: "mirror.invalid", missingDigest: false),
            FakeRelease(tag: "v1.8.0", version: "1.8.0", archive: piArchive("1.8.0"), sums: sumsFor("1.8.0"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: true),
            FakeRelease(tag: "v1.3.0", version: "1.3.0", archive: piArchive("1.3.0"), sums: sumsFor("1.3.0"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: false)
        ]
        let found = try PiReleaseDiscovery.releases(from: apiJSON(releases), architecture: PiInstallationCatalog.architecture)
        XCTAssertEqual(found.map(\.version), ["1.10.0", "1.9.0", "1.5.2"])
        XCTAssertTrue(found.allSatisfy { (try? $0.validate()) != nil })
        XCTAssertEqual(found.first?.origin?.kind, .upstreamRelease)
        XCTAssertEqual(found.first?.origin?.repository, PiUpstreamRelease.repository)
        XCTAssertEqual(found.first?.artifacts.first?.url.path, "/earendil-works/pi/releases/download/v1.10.0/\(PiUpstreamRelease.archiveAsset)")
        XCTAssertTrue(found.allSatisfy { $0.provenance.contains("Release metadata is a trust source, not an independently signed manifest") })
    }
    func testSemanticOrderingAndPrereleaseRules() {
        func version(_ text: String) -> PiSemanticVersion { PiSemanticVersion.parse(text)! }
        XCTAssertTrue(version("1.10.0") > version("1.9.0"))
        XCTAssertTrue(version("1.5.2") > version("1.5.1"))
        XCTAssertTrue(version("1.5.2") > version("1.5.2-beta"))
        XCTAssertFalse(version("1.5.2-beta") > version("1.5.2"))
        XCTAssertNil(PiSemanticVersion.parse("1.4"))
        XCTAssertNil(PiSemanticVersion.parse("nightly"))
        XCTAssertEqual(version("1.5.2+build3"), version("1.5.2"), "build metadata never changes precedence")
        XCTAssertFalse(version("1.5.0-beta").isStable)
        XCTAssertTrue(version("1.4.0") >= PiCompatibilityPolicy.minimumEligibleVersion)
        XCTAssertFalse(version("1.3.9") >= PiCompatibilityPolicy.minimumEligibleVersion)
    }
    func testUpstreamMetadataMustBeCompleteAndConsistent() throws {
        let noDigest = FakeRelease(tag: "v1.6.0", version: "1.6.0", archive: piArchive("1.6.0"), sums: sumsFor("1.6.0"), prerelease: false, draft: false, assetHost: "github.com", missingDigest: true)
        XCTAssertTrue(try PiReleaseDiscovery.releases(from: apiJSON([noDigest]), architecture: PiInstallationCatalog.architecture).isEmpty)
        XCTAssertThrowsError(try PiReleaseDiscovery.releases(from: Data("not json".utf8), architecture: PiInstallationCatalog.architecture))
        let archive = piArchive("1.5.2")
        try PiReleaseDiscovery.verifySums(candidateDigest: hash(archive), sumsSHA256: hash(sumsFor("1.5.2")), sumsBytes: sumsFor("1.5.2"))
        XCTAssertThrowsError(try PiReleaseDiscovery.verifySums(candidateDigest: hash(archive), sumsSHA256: hash(sumsFor("1.5.2")),
                                                              sumsBytes: Data("\(hash(piArchive("other")))  pi-darwin-\(PiInstallationCatalog.architecture).tar.gz\n".utf8)))
        XCTAssertThrowsError(try PiReleaseDiscovery.verifySums(candidateDigest: hash(archive), sumsSHA256: nil,
                                                              sumsBytes: Data("baddigest  pi-linux-x64.tar.gz\n".utf8)))
        // The manifest is only trusted after its own published digest matches.
        XCTAssertThrowsError(try PiReleaseDiscovery.verifySums(candidateDigest: hash(archive), sumsSHA256: String(repeating: "0", count: 64), sumsBytes: sumsFor("1.5.2")))
        // A candidate's own metadata must be self-consistent.
        let candidate = PiReleaseDiscovery.release(for: PiReleaseCandidate(version: "1.5.2", tag: "v1.5.2",
            releaseURL: URL(string: "https://github.com/earendil-works/pi/releases/tag/v1.5.2")!,
            archiveURL: archiveURL("v1.5.2"), archiveSHA256: hash(archive), sumsURL: nil, sumsSHA256: nil,
            dependencyLockURL: nil, dependencyLockSHA256: nil, publishedAt: .now), architecture: "arm64")
        try candidate.validate()
    }
    @MainActor func testReleaseMetadataFetchRejectsNonHTTPSUpstreamSources() async {
        let discovery = PiReleaseDiscovery(apiURL: URL(string: "http://api.github.com/repos/earendil-works/pi/releases")!)
        do { _ = try await discovery.fetch(discovery.apiURL); XCTFail("non-HTTPS release metadata must be rejected") } catch { }
    }
    // A discovered stable release is eligible for the isolated probe, but is never
    // trusted for an ordinary session until the probe on this machine succeeds.
    func testProbeEligibilityAndSessionVerificationGateAreDistinct() throws {
        let candidate = PiCompatibilityPolicy.evaluate(version: "1.5.2")
        XCTAssertEqual(candidate.state, .untested)
        XCTAssertFalse(candidate.usable)
        try PiCompatibilityPolicy.requireProbeEligible(candidate)
        XCTAssertThrowsError(try PiCompatibilityPolicy.requireSupportedVersion(candidate))
        let verified = PiCompatibilityPolicy.evaluate(version: "1.5.2", verified: ["1.5.2"])
        XCTAssertTrue(verified.usable)
        try PiCompatibilityPolicy.requireSupportedVersion(verified)
        let older = PiCompatibilityPolicy.evaluate(version: "1.3.9", verified: ["1.3.9"])
        XCTAssertEqual(older.state, .unsupported)
        XCTAssertThrowsError(try PiCompatibilityPolicy.requireProbeEligible(older), "the probe never inspects a version below the baseline")
    }

    // MARK: - Discovery-driven installation

    @MainActor func testDiscoveryDrivenInstallRegistersVerifiedReleaseAndPreservesUserData() async throws {
        let (manager, feed, root, _) = try updateFixture(versions: ["1.5.2"])
        let ordinary = root.appendingPathComponent("ordinary Pi data")
        let before = try PiInstallationFiles.inventory(ordinary)
        let id = try await manager.installLatest()
        let selected = try XCTUnwrap(manager.selectedInstallation())
        XCTAssertEqual(selected.expectedVersion, "1.5.2")
        XCTAssertEqual(manager.store.state.selected, id)
        let stored = try XCTUnwrap(manager.store.state.managed.first)
        XCTAssertEqual(stored.release.origin?.kind, .upstreamRelease)
        XCTAssertEqual(stored.release.origin?.assetSHA256, hash(feed.releases.first!.archive))
        XCTAssertTrue(stored.health.usable, "registration requires a successful isolated RPC handshake")
        XCTAssertFalse(stored.release.files.isEmpty, "the verified layout is pinned with real digests")
        XCTAssertEqual(feed.probes, 1, "every discovered runtime is probed before registration")
        XCTAssertEqual(try PiInstallationFiles.inventory(ordinary), before, "automatic update never touches Pi user data")
        let provenance = try Data(contentsOf: selected.executable.deletingLastPathComponent().appendingPathComponent("MilkNotices/Release-Provenance.txt"))
        XCTAssertTrue(String(decoding: provenance, as: UTF8.self).contains("earendil-works/pi"))
    }

    @MainActor func testAutoUpdateStagesWhileRunningAndActivatesOnlyOnQuiescence() async throws {
        let (manager, _, root, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        try manager.setAutoUpdate(false)
        let first = try await manager.install(version: "1.4.0")
        // Auto Update off: nothing is staged even though a newer release exists.
        try await manager.stageAutomaticUpdateIfEnabled(force: true)
        XCTAssertNil(manager.store.state.pending)
        XCTAssertEqual(manager.store.state.selected, first)
        try manager.setAutoUpdate(true)
        let record = try XCTUnwrap(manager.selectedInstallation())
        let held = HeldRuntime()
        let lease = manager.lifecycle.begin(activation: .init(agentID: .pi, workspace: root, sessionID: 1), purpose: .conversation,
                                           factory: { held }) { _, lease in lease.associate(record) }
        try await lease.work.value
        try await manager.stageAutomaticUpdateIfEnabled(force: true)
        XCTAssertEqual(manager.store.state.selected, first, "an active session keeps its current runtime")
        let staged = try XCTUnwrap(manager.store.state.managed.first { $0.id != first })
        XCTAssertEqual(staged.release.version, "1.5.2")
        XCTAssertEqual(manager.store.state.pending, staged.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.executable.path), "the previous working runtime is retained")
        XCTAssertEqual(manager.runningInstallations.map(\.id), [first])
        held.exit.release()
        try await manager.lifecycle.stopAndWait(lease)
        try await until("automatic update activated on quiescence") { manager.store.state.selected == staged.id }
        XCTAssertEqual(manager.store.state.previous, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.executable.path))
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
    }

    @MainActor func testTamperedArtifactIsRejectedAndNeverRetried() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let installed = try await manager.install(version: "1.4.0")
        let executable = try XCTUnwrap(manager.selectedInstallation()?.executable)
        let code = try Data(contentsOf: executable)
        try manager.setAutoUpdate(true)
        feed.tamper = "tampered bytes"
        await rejects { try await manager.stageAutomaticUpdateIfEnabled(force: true) }
        XCTAssertEqual(manager.store.state.selected, installed)
        XCTAssertEqual(try Data(contentsOf: executable), code)
        XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertNil(manager.store.state.pending)
        let rejection = try XCTUnwrap(manager.store.state.rejected?.first)
        XCTAssertEqual(rejection.version, "1.5.2")
        let remaining = await manager.automaticCandidates()
        XCTAssertTrue(remaining.isEmpty, "a rejected release is not retried automatically")
        let model = AgentManagerModel(manager: manager)
        XCTAssertNil(model.updateVersion)
        XCTAssertNotNil(model.rejectedRelease)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.staging.path).isEmpty)
    }

    @MainActor func testCandidateThatFailsTheIsolatedProbeIsNeverRegistered() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let installed = try await manager.install(version: "1.4.0")
        let executable = try XCTUnwrap(manager.selectedInstallation()?.executable)
        let code = try Data(contentsOf: executable)
        try manager.setAutoUpdate(true)
        feed.failingProbeVersions.insert("1.5.2")
        await rejects { try await manager.stageAutomaticUpdateIfEnabled(force: true) }
        XCTAssertEqual(manager.store.state.selected, installed)
        XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertNil(manager.store.state.pending)
        XCTAssertEqual(manager.store.state.rejected?.first?.version, "1.5.2")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.staging.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: executable), code)
    }

    @MainActor func testVerifiedInstallationsRemainUsableOfflineAndRollbackNeedsNoNetwork() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let first = try await manager.install(version: "1.4.0")
        let second = try await manager.install(version: "1.5.2")
        let stored = try XCTUnwrap(manager.store.state.managed.first { $0.id == second })
        try stored.release.validate()   // stored metadata is self-sufficient, no network
        // The next launch has no cached upstream feed at all.
        feed.offline = true
        let reloaded = AgentInstallationStore(root: manager.store.root)
        XCTAssertNil(reloaded.loadProblem)
        XCTAssertEqual(reloaded.state, manager.store.state, "verified revisions survive a restart without metadata")
        XCTAssertEqual(try manager.selectedInstallation()?.expectedVersion, "1.5.2")
        XCTAssertEqual(manager.verifiedVersions(), ["1.4.0", "1.5.2"])
        XCTAssertTrue(PiCompatibilityPolicy.evaluate(version: "1.5.2", verified: manager.verifiedVersions()).usable,
                     "a verified revision passes the session launch gate offline")
        XCTAssertFalse(PiCompatibilityPolicy.evaluate(version: "1.5.3", verified: manager.verifiedVersions()).usable,
                       "an unseen revision is never trusted without a probe")
        await rejects { _ = try await manager.repair(second) }      // repair needs the upstream artifact
        XCTAssertEqual(manager.store.state.selected, second)
        try await manager.rollbackToRetained(first)                 // rollback does not
        XCTAssertEqual(manager.store.state.selected, first)
        XCTAssertEqual(try manager.selectedInstallation()?.expectedVersion, "1.4.0")
        _ = await manager.checkForUpdates()
        XCTAssertNotNil(manager.releaseCheckProblem, "a failed release check is reported, not fatal")
        XCTAssertTrue(manager.store.state.managed.contains { $0.id == second }, "the newer revision stays available for a later offline choice")
        try stored.release.validate()
    }

    @MainActor func testInterruptedAutomaticUpdateKeepsPreviousRuntimeAndCleansStaging() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let installed = try await manager.install(version: "1.4.0")
        try manager.setAutoUpdate(true)
        let gate = Gate(); feed.gate = gate
        let task = Task { try await manager.stageAutomaticUpdateIfEnabled(force: true) }
        try await until("download started") { feed.downloading }
        task.cancel(); gate.release()
        await rejects { try await task.value }
        XCTAssertEqual(manager.store.state.selected, installed)
        XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertNil(manager.store.state.pending)
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.staging.path).isEmpty)
        try manager.recoverInterruptedTransactions()
        XCTAssertEqual(manager.store.state.selected, installed)
        XCTAssertTrue(manager.store.state.operation?.detail.contains("interrupted") == true)
    }

    @MainActor func testScheduledChecksRunOnlyWhenAutoUpdateIsEnabled() async throws {
        let (manager, _, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let installed = try await manager.install(version: "1.4.0")   // explicit install, Auto Update still off
        manager.scheduleReleaseChecks(interval: 60)
        try? await Task.sleep(nanoseconds: 300_000_000)
        manager.stopReleaseSchedule()
        XCTAssertEqual(manager.store.state.selected, installed, "disabled Auto Update never changes the selected runtime")
        XCTAssertEqual(manager.store.state.managed.count, 1)
        try manager.setAutoUpdate(true)
        manager.scheduleReleaseChecks(interval: 60)
        try await until("scheduled check installed the eligible release") { manager.store.state.selected != installed }
        manager.stopReleaseSchedule()
        XCTAssertEqual(manager.store.state.managed.first(where: { $0.id != installed })?.release.version, "1.5.2")
        XCTAssertEqual(manager.store.state.previous, installed)
        // A second scheduled pass finds nothing newer.
        await manager.checkForAutomaticUpdate(force: true)
        XCTAssertEqual(manager.store.state.managed.count, 2)
    }

    // MARK: - Check scheduling regressions

    @MainActor func testManualCheckForUpdatesRunsThroughTheModelAction() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let model = AgentManagerModel(manager: manager)
        let installed = try await manager.install(version: "1.4.0")
        XCTAssertTrue(model.actions.contains(.check))
        let before = feed.fetches
        await model.perform(.check)                       // the action used to be blocked by its own busy flag
        XCTAssertEqual(feed.fetches, before + 1, "the manual check read the upstream feed")
        XCTAssertNil(manager.releaseCheckProblem)
        XCTAssertEqual(model.updateVersion, "1.5.2")
        XCTAssertEqual(model.feedback, "Pi 1.5.2 is available and eligible for this adapter. Enable Auto Update or choose Update.")
        XCTAssertEqual(model.status, "Update available")
        XCTAssertNil(model.state.pending)
        XCTAssertEqual(model.state.selected, installed, "checking for updates does not change the selected runtime")
        // A manual check ignores the automatic interval and always re-reads the feed.
        await model.refreshReleases()
        XCTAssertEqual(feed.fetches, before + 2)
    }
    @MainActor func testManualCheckReportsAnUnavailableFeedWithoutBreakingTheRuntime() async throws {
        let (manager, feed, root, _) = try updateFixture(versions: ["1.4.0"])
        let model = AgentManagerModel(manager: manager)
        _ = try await manager.install(version: "1.4.0")
        feed.offline = true
        await model.perform(.check)
        XCTAssertNotNil(manager.releaseCheckProblem)
        XCTAssertEqual(model.feedback, manager.releaseCheckProblem)
        XCTAssertEqual(model.status, "Managed by Milk · update check unavailable")
        XCTAssertTrue(manager.verifiedVersions().contains("1.4.0"), "a feed outage never invalidates a verified runtime")
        XCTAssertFalse(model.needsVerification)
    }
    @MainActor func testRestartAfterASuccessfulCheckKeepsReleaseMetadataWithoutRefetching() async throws {
        var (manager, feed, root, notices) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        _ = try await manager.install(version: "1.4.0")           // explicit install, Auto Update still off
        await manager.checkForAutomaticUpdate(force: true)         // scheduled pass discovers releases, stages nothing
        XCTAssertNil(manager.store.state.pending)
        XCTAssertNotNil(manager.store.state.lastReleaseCheck, "a successful check stamps the interval")
        XCTAssertEqual(manager.store.state.discoveredReleases?.map(\.version), ["1.5.2", "1.4.0"], "discovered releases are persisted for restart")
        manager.stopReleaseSchedule()
        // Replacing the manager releases the store's ownership lock: this is the restart.
        manager = retiredManager(root: root, notices: notices)
        let fetchesAfterFirstSession = feed.fetches
        let restarted = restartedManager(feed: feed, root: root, notices: notices)
        let refreshed = await restarted.refreshReleases()
        XCTAssertEqual(refreshed.map(\.version), ["1.5.2", "1.4.0"], "a restarted Milk still knows the eligible releases")
        XCTAssertEqual(feed.fetches, fetchesAfterFirstSession, "the 24 hour window is respected after a restart")
        // An older stamp makes the next scheduled pass read the feed again.
        try restarted.store.commit { $0.lastReleaseCheck = Date(timeIntervalSinceNow: -25 * 3600) }
        _ = await restarted.refreshReleases()
        XCTAssertEqual(feed.fetches, fetchesAfterFirstSession + 1)
        // The stored runtime still self-verifies with no network metadata.
        let retained = try XCTUnwrap(restarted.store.state.managed.first)
        XCTAssertTrue((try? retained.release.validate()) != nil, "the stored release validates offline")
        let inventory = try PiInstallationFiles.inventory(restarted.store.directory(for: retained))
        XCTAssertEqual(retained.release.files["pi"], inventory["pi"], "the pinned launcher digest still matches the installed bytes")
        XCTAssertTrue(restarted.verifiedVersions().contains("1.4.0"))
        // The update path survives the restart.
        let model = AgentManagerModel(manager: restarted)
        XCTAssertEqual(model.updateVersion, "1.5.2")
        XCTAssertEqual(model.status, "Update available")
        await model.perform(.check)
        XCTAssertEqual(model.feedback, "Pi 1.5.2 is available and eligible for this adapter. Enable Auto Update or choose Update.")
        await model.perform(.update)
        // Nothing Pi-related is running, so the verified release activates immediately
        // while the previous revision stays retained for rollback.
        XCTAssertEqual(model.managed?.release.version, "1.5.2", "the restarted manager can still install the discovered release")
        XCTAssertEqual(model.state.managed.count, 2)
        XCTAssertEqual(model.state.previous, retained.id)
        XCTAssertNil(model.state.pending)
        restarted.stopReleaseSchedule()
    }
    @MainActor func testFailedReleaseCheckIsRetriedInsteadOfBlockingTheInterval() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        feed.offline = true
        _ = await manager.refreshReleases()               // a scheduled pass with no network
        XCTAssertNotNil(manager.releaseCheckProblem)
        XCTAssertNil(manager.store.state.lastReleaseCheck, "a failed read is never recorded as a completed check")
        XCTAssertTrue(manager.availableReleases.isEmpty)
        feed.offline = false
        let recovered = await manager.refreshReleases()    // retried on the next pass, not 24 hours later
        XCTAssertNil(manager.releaseCheckProblem)
        XCTAssertEqual(recovered.map(\.version), ["1.5.2", "1.4.0"])
        XCTAssertNotNil(manager.store.state.lastReleaseCheck)
        // Inside the interval a non-forced pass reuses the cache instead of re-reading the feed.
        let before = feed.fetches
        _ = await manager.refreshReleases()
        XCTAssertEqual(feed.fetches, before, "no unnecessary upstream requests")
        // And the recovered feed still drives a real automatic update.
        _ = try await manager.install(version: "1.4.0")
        try manager.setAutoUpdate(true)
        await manager.checkForAutomaticUpdate(force: true)
        let selected = try XCTUnwrap(manager.selectedInstallation())
        XCTAssertEqual(selected.expectedVersion, "1.5.2", "the retry after a failed check completes the update")
        XCTAssertEqual(manager.store.state.managed.count, 2)
    }
    @MainActor func testConcurrentReleaseChecksShareOneUpstreamRead() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.5.2"])
        _ = await manager.refreshReleases()               // warm the cache
        let before = feed.fetches
        async let first = manager.refreshReleases(force: true)
        async let second = manager.refreshReleases(force: true)
        let (a, b) = await (first, second)
        XCTAssertEqual(a.map(\.version), ["1.5.2"])
        XCTAssertEqual(b.map(\.version), ["1.5.2"])
        XCTAssertEqual(feed.fetches, before + 1, "overlapping checks do not duplicate the upstream request")
    }
    @MainActor func testConcurrentChecksReturnTheFreshResultNotTheStaleCache() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        let cached = await manager.refreshReleases()                       // cache holds 1.5.2, 1.4.0
        XCTAssertEqual(cached.map(\.version), ["1.5.2", "1.4.0"])
        addRelease(to: feed, version: "1.6.0")                             // upstream publishes a new release
        let before = feed.fetches
        async let first = manager.refreshReleases(force: true)
        async let second = manager.refreshReleases()                        // scheduled pass joins the same read
        let (a, b) = await (first, second)
        XCTAssertEqual(a.map(\.version), ["1.6.0", "1.5.2", "1.4.0"], "the manual check returns the freshly read feed")
        XCTAssertEqual(b.map(\.version), ["1.6.0", "1.5.2", "1.4.0"], "the joined caller gets the same fresh result, not the stale cache")
        XCTAssertEqual(feed.fetches, before + 1, "the joined caller does not start a second request")
    }
    @MainActor func testFailedSharedCheckIsRetriedRatherThanCachedAsCompleted() async throws {
        let (manager, feed, _, _) = try updateFixture(versions: ["1.4.0", "1.5.2"])
        feed.offline = true
        async let first = manager.refreshReleases(force: true)
        async let second = manager.refreshReleases(force: true)
        let (a, b) = await (first, second)
        XCTAssertTrue(a.isEmpty && b.isEmpty, "both callers see the failure, not a stale list")
        XCTAssertNotNil(manager.releaseCheckProblem)
        XCTAssertNil(manager.store.state.lastReleaseCheck, "a failed shared check is not recorded as a completed check")
        feed.offline = false
        let retry = await manager.refreshReleases(force: true)
        XCTAssertEqual(retry.map(\.version), ["1.5.2", "1.4.0"], "the shared failure does not block a retry")
        XCTAssertNil(manager.releaseCheckProblem)
        // Inside the interval the next scheduled pass reuses the recovered cache.
        let before = feed.fetches
        _ = await manager.refreshReleases()
        XCTAssertEqual(feed.fetches, before)
    }
}
