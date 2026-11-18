import XCTest
import CryptoKit
@testable import Milk

final class PiInstallationTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture() throws -> (URL, URL, PiRuntimeService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Installation-" + UUID().uuidString)
        let resources = root.appendingPathComponent("resources"), ordinary = root.appendingPathComponent("ordinary")
        for dir in [resources, ordinary] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: project.appendingPathComponent("Runtime/MilkPiIntegration.ts"), to: resources.appendingPathComponent("MilkPiIntegration.ts"))
        let executable = root.appendingPathComponent("external pi")
        try FileManager.default.copyItem(at: project.appendingPathComponent("Tests/Fixtures/pi_parity_peer.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(#"{"fixture":"retain auth"}"#.utf8).write(to: ordinary.appendingPathComponent("auth.json"))
        try Data(#"{"fixture":"retain settings"}"#.utf8).write(to: ordinary.appendingPathComponent("settings.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // A contained compatibility probe may write only inside its own private plan root, so the probe
        // environment carries no external log channel. The log stays available to ordinary launches,
        // which run with the legacy unsandboxed test setting and can be observed by `records(_:)`.
        let probeOverrides = ["MILK_PARITY_READY": "1"]
        let runtime = PiRuntimeService(resources: resources, environmentOverrides: ["PI_CODING_AGENT_DIR": ordinary.path,
            "MILK_PARITY_READY": "1", "MILK_COMPAT_LOG": root.appendingPathComponent("peer.jsonl").path, "PATH": "/usr/bin:/bin"], probeEnvironmentOverrides: probeOverrides)
        return (root, executable, runtime)
    }
    private func records(_ root: URL) -> [JSONValue] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("peer.jsonl")) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    private func ordinarySnapshot(_ root: URL) throws -> [String: Data] {
        let directory = root.appendingPathComponent("ordinary")
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return try Dictionary(uniqueKeysWithValues: files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { ($0.path, try Data(contentsOf: $0)) })
    }

    @MainActor func testPolicyAndInstallationOwnershipAreIndependentOfDataAndConnection() async throws {
        XCTAssertEqual(PiCompatibilityPolicy.evaluate(version: "1.4.0").state, .supported)
        XCTAssertFalse(PiCompatibilityPolicy.evaluate(version: "1.4.0").usable)
        XCTAssertTrue(PiCompatibilityPolicy.verified(version: "1.4.0").usable)
        XCTAssertEqual(PiCompatibilityPolicy.evaluate(version: "1.3.0").state, .unsupported)
        XCTAssertEqual(PiCompatibilityPolicy.evaluate(version: "1.5.0").state, .untested)
        XCTAssertEqual(PiCompatibilityPolicy.evaluate(version: "not-a-version").state, .invalidRuntime)
        let (root, executable, runtime) = try fixture(), owner = AgentLifecycleCoordinator()
        let resolver = PiLaunchResolver(runtime: runtime)
        let external = resolver.installation(for: .external(executable))
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        let managed = AgentInstallationRecord(id: .init(rawValue: "test-managed-candidate"), agentID: .pi, ownership: .milkManaged,
            source: .milkApproved, executable: executable, expectedVersion: "1.4.0", executableSHA256: digest)
        let before = try ordinarySnapshot(root)
        let profile = try PiProfile.managed(store: .init(root: root.appendingPathComponent("owned")))
        let launch = try await resolver.resolve(managed, lifecycle: owner, profile: profile)
        XCTAssertEqual(launch.installation.ownership, .milkManaged)
        XCTAssertNotEqual(launch.installation.id, external.id)
        XCTAssertEqual(launch.dataProfile.directory, profile.directory)
        XCTAssertEqual(launch.dataProfile.ownership, .milkManaged)
        XCTAssertEqual(try ordinarySnapshot(root), before)
        do {
            _ = try await resolver.resolve(.external(root.appendingPathComponent("missing")), lifecycle: owner)
            XCTFail("Missing executable accepted")
        } catch let error as AgentCompatibilityError { XCTAssertEqual(error.result.state, .invalidRuntime) }
        XCTAssertTrue(owner.owned.isEmpty)
    }

    @MainActor func testExternalLaunchWithoutBundledManifestOrToolsUsesResolvedAdapterContext() async throws {
        let (root, executable, runtime) = try fixture(), owner = AgentLifecycleCoordinator()
        let before = try ordinarySnapshot(root), code = try Data(contentsOf: executable)
        let launch = try await PiLaunchResolver(runtime: runtime).resolve(.external(executable), lifecycle: owner)
        XCTAssertEqual(launch.installation.ownership, .external)
        XCTAssertFalse(launch.compatibility.usable, "Version output alone is not an integration handshake")
        XCTAssertFalse(launch.supportPaths.contains { $0.path.contains("PiRuntime") })
        XCTAssertEqual(Array((launch.environment["PATH"] ?? "").components(separatedBy:":").prefix(3)),[executable.deletingLastPathComponent().path,"/usr/bin","/bin"])
        var config = AgentConfiguration(); config.runtime = .external(executable)
        let backend = PiAdapter(runtime: runtime, configuration: { config }).makeBackend(context: .init(permission: .approval, lifecycle: owner, sandboxSettings: sandboxOffForLegacyTests()))
        addTeardownBlock { try await backend.shutdownAndWait() }
        var ready: RuntimeStatus?
        backend.onEvent = { if case .runtime(let status) = $0, status.phase == .ready { ready = status } }
        try await backend.start(workspace: root, session: .init(id: 1, title: "External"))
        XCTAssertEqual(ready?.compatibility?.usable, true)
        XCTAssertEqual(ready?.runtimeIdentity?.installation?.id, launch.installation.id)
        XCTAssertEqual(records(root).first?["agentDir"].string, root.appendingPathComponent("ordinary").path)
        try await backend.shutdownAndWait()
        XCTAssertEqual(try ordinarySnapshot(root), before); XCTAssertEqual(try Data(contentsOf: executable), code)
    }

    // Each rejected candidate must be identifiable from the compatibility result itself.
    // A fixture that dies before doing its work would otherwise satisfy `.incompatibleIntegration` by accident.
    @MainActor func testProbeRejectsVersionOnlyMissingMarkerMalformedRepliesAndUntestedVersion() async throws {
        struct Rejection { let overrides: [String: String]; let reason: String }
        let cases: [Rejection] = [
            Rejection(overrides: ["MILK_COMPAT_VERSION_ONLY": "1"], reason: "Pi exited (3)"),
            Rejection(overrides: ["MILK_PARITY_READY": "0"], reason: "did not load Milk's integration extension"),
            Rejection(overrides: ["MILK_COMPAT_BAD_COMMAND": "get_messages"], reason: "incompatible get_messages reply"),
        ]
        var observed: [String] = []
        for case_ in cases {
            let (root, executable, base) = try fixture(), owner = AgentLifecycleCoordinator()
            let runtime = PiRuntimeService(resources: base.resources,
                environmentOverrides: base.environmentOverrides.merging(case_.overrides) { _, new in new },
                probeEnvironmentOverrides: ["MILK_PARITY_READY": "1"].merging(case_.overrides) { _, new in new })
            let before = try ordinarySnapshot(root)
            let report = try await PiCompatibilityProbe.inspect(mode: .external(executable), runtime: runtime, lifecycle: owner)
            observed.append(report.detail)
            XCTAssertEqual(report.state, .incompatibleIntegration, report.detail)
            XCTAssertEqual(report.evidence, .versionOnly, "A rejected candidate never earns an integration handshake")
            XCTAssertFalse(report.usable)
            XCTAssertEqual(report.version, "1.4.0", "The selected candidate must reach version detection before it is rejected")
            XCTAssertTrue(report.detail.contains(case_.reason), "\(case_.overrides): \(report.detail)")
            XCTAssertFalse(report.detail.contains("Traceback"), "The selected candidate must not be rejected because the fixture itself failed: \(report.detail)")
            XCTAssertTrue(owner.owned.isEmpty)
            XCTAssertTrue(records(root).isEmpty, "A contained probe must not write test state outside its private plan root")
            XCTAssertEqual(try ordinarySnapshot(root), before)
        }
        XCTAssertEqual(Set(observed).count, cases.count, "Each rejection mechanism must be distinguishable: \(observed)")

        // An eligible but unverified revision is probe-eligible and session-refused by the same policy.
        let untested = PiCompatibilityPolicy.evaluate(version: "1.5.0")
        XCTAssertEqual(untested.state, .untested)
        XCTAssertFalse(untested.usable)
        XCTAssertNoThrow(try PiCompatibilityPolicy.requireProbeEligible(untested), "The isolated probe may inspect an eligible, unverified revision")
        do {
            try PiCompatibilityPolicy.requireSupportedVersion(untested)
            XCTFail("An unverified revision became session-eligible")
        } catch let error as AgentCompatibilityError { XCTAssertEqual(error.result.state, .untested) }
    }

    // Documented behavior: the isolated probe is how an eligible, unverified revision is verified.
    @MainActor func testCompletedProbeVerifiesAnUntestedVersion() async throws {
        let (root, executable, base) = try fixture(), owner = AgentLifecycleCoordinator()
        let runtime = PiRuntimeService(resources: base.resources,
            environmentOverrides: base.environmentOverrides.merging(["MILK_PARITY_VERSION": "1.5.0"]) { _, new in new },
            probeEnvironmentOverrides: ["MILK_PARITY_READY": "1", "MILK_PARITY_VERSION": "1.5.0"])
        let before = try ordinarySnapshot(root)
        let report = try await PiCompatibilityProbe.inspect(mode: .external(executable), runtime: runtime, lifecycle: owner)
        XCTAssertEqual(report.state, .supported, report.detail)
        XCTAssertEqual(report.evidence, .integrationHandshake)
        XCTAssertEqual(report.version, "1.5.0")
        XCTAssertTrue(report.usable, "A completed isolated handshake establishes supported compatibility: \(report.detail)")
        XCTAssertTrue(owner.owned.isEmpty)
        XCTAssertTrue(records(root).isEmpty)
        XCTAssertEqual(try ordinarySnapshot(root), before, "A probe must not touch the ordinary profile")
    }

    // Ordinary session startup keeps requiring a verified revision, even when the probe path accepts the candidate.
    @MainActor func testUntestedVersionIsRefusedAtSessionStartBeforeRpc() async throws {
        let (root, executable, base) = try fixture()
        var verified = base.environmentOverrides
        verified["MILK_PARITY_VERSION"] = "1.4.0"
        let verifiedRuntime = PiRuntimeService(resources: base.resources, environmentOverrides: verified,
            probeEnvironmentOverrides: ["MILK_PARITY_READY": "1", "MILK_PARITY_VERSION": "1.4.0"])
        var config = AgentConfiguration(); config.runtime = .external(executable)
        // Control: this fixture does record activity when a session is actually allowed to run.
        let control = PiBackend(sandboxSettings: sandboxOffForLegacyTests(), runtime: verifiedRuntime)
        addTeardownBlock { try await control.shutdownAndWait() }
        try await control.start(workspace: root, session: .init(id: 0, title: "Verified"), configuration: config)
        try await control.shutdownAndWait()
        let controlRecords = records(root)
        XCTAssertFalse(controlRecords.isEmpty, "The fixture log channel must work for a session that is allowed to launch")
        XCTAssertEqual(controlRecords.first?["agentDir"].string, root.appendingPathComponent("ordinary").path)

        let untestedRuntime = PiRuntimeService(resources: base.resources,
            environmentOverrides: verified.merging(["MILK_PARITY_VERSION": "1.5.0"]) { _, new in new },
            probeEnvironmentOverrides: ["MILK_PARITY_READY": "1", "MILK_PARITY_VERSION": "1.5.0"])
        let backend = PiBackend(sandboxSettings: sandboxOffForLegacyTests(), runtime: untestedRuntime)
        addTeardownBlock { try await backend.shutdownAndWait() }
        var state: AgentCompatibilityState?
        backend.onEvent = { if case .runtime(let status) = $0 { state = status.compatibility?.state } }
        do {
            try await backend.start(workspace: root, session: .init(id: 0, title: "Untested"), configuration: config)
            XCTFail("Untested version launched")
        } catch let error as AgentCompatibilityError { XCTAssertEqual(error.result.state, .untested, error.result.detail) }
        catch { XCTFail("Unexpected startup failure: \(error)") }
        try await backend.shutdownAndWait()
        XCTAssertEqual(state, .untested, "Startup and Settings probe classify the same revision identically")
        XCTAssertEqual(records(root).count, controlRecords.count, "An untested version must not enter RPC")
    }

    @MainActor func testRealBundledProbeIsEphemeralAndDoesNotLoadOrdinaryConfiguration() async throws {
        let (root, _, base) = try fixture(), owner = AgentLifecycleCoordinator()
        let ordinary = root.appendingPathComponent("ordinary")
        let extensionFile = ordinary.appendingPathComponent("must-not-load.ts")
        try Data("throw new Error('ordinary extension must not load');".utf8).write(to: extensionFile)
        try Data(JSONSerialization.data(withJSONObject: ["extensions": [extensionFile.path]])).write(to: ordinary.appendingPathComponent("settings.json"))
        let before = try ordinarySnapshot(root)
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: base.environmentOverrides)
        let report = try await PiCompatibilityProbe.inspect(mode: .bundled, runtime: runtime, lifecycle: owner)
        XCTAssertTrue(report.usable, report.detail)
        XCTAssertEqual(report.evidence, .integrationHandshake)
        XCTAssertTrue(owner.owned.isEmpty); XCTAssertEqual(try ordinarySnapshot(root), before)
    }

    @MainActor func testProbeCancellationAwaitsExitAndRemovesItsIsolatedDirectory() async throws {
        let (root, executable, base) = try fixture(), owner = AgentLifecycleCoordinator()
        var env = base.environmentOverrides; env["MILK_COMPAT_HANG"] = "1"
        // Contained probes cannot write a test log into unrelated persistent storage.
        let runtime = PiRuntimeService(resources:base.resources,environmentOverrides:env,probeEnvironmentOverrides:["MILK_COMPAT_HANG":"1","MILK_PARITY_READY":"1"])
        let before = try ordinarySnapshot(root)
        let operation = Task { try await PiCompatibilityProbe.inspect(mode: .external(executable), runtime: runtime, lifecycle: owner) }
        let deadline = Date().addingTimeInterval(4)
        var probe: PiCompatibilityProbe?
        while probe?.handshakeReceived != true {
            probe=owner.owned.values.compactMap { $0.resource as? PiCompatibilityProbe }.first
            guard Date() < deadline else { operation.cancel(); _ = await operation.result; throw AgentError.message("Probe did not enter RPC") }
            await Task.yield()
        }
        let launched=try XCTUnwrap(probe?.execution)
        XCTAssertTrue(owner.owned.values.contains { $0.purpose == .compatibilityProbe })
        XCTAssertTrue(launched.arguments.contains("--no-session"))
        XCTAssertNotEqual(launched.profile.path,root.appendingPathComponent("ordinary").path)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled probe returned a result") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.workspace.path))
        XCTAssertNotEqual(kill(launched.pid, 0), 0)
        XCTAssertEqual(try ordinarySnapshot(root), before)
    }

    @MainActor func testExplicitExtensionPackageActionUsesSelectedExternalRuntime() async throws {
        let (root, executable, original) = try fixture(), owner = AgentLifecycleCoordinator()
        var env=original.environmentOverrides
        let log=root.appendingPathComponent("ordinary/package-proof.jsonl")
        env["MILK_COMPAT_LOG"]=log.path
        let runtime=PiRuntimeService(resources:original.resources,environmentOverrides:env,probeEnvironmentOverrides:["MILK_COMPAT_LOG":log.path,"MILK_PARITY_READY":"1"])
        let source = root.appendingPathComponent("trusted.ts")
        try Data("export default function() {}".utf8).write(to: source)
        let service = ExtensionService(agentDirectory: root.appendingPathComponent("ordinary"), runtime: runtime)
        service.lifecycle = owner; service.runtimeSelection = { .external(executable) }
        try await service.installLocalRegistration(source)
        let entries=try Data(contentsOf:log).split(separator:10).map { try JSONDecoder().decode(JSONValue.self,from:Data($0)) }
        let command = try XCTUnwrap(entries.first { $0["args"].array.first?.string == "install" })
        XCTAssertEqual(command["args"].array.compactMap(\.string), ["install", source.path, "--no-approve"])
        XCTAssertEqual(command["agentDir"].string, try SandboxPathResolver().resolve(root.appendingPathComponent("ordinary")).canonicalURL.path)
        XCTAssertFalse(command["path"].string?.contains("PiRuntime/bin") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)); XCTAssertTrue(owner.owned.isEmpty)
    }
}
