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
        let runtime = PiRuntimeService(resources: resources, environmentOverrides: ["PI_CODING_AGENT_DIR": ordinary.path,
            "MILK_PARITY_READY": "1", "MILK_COMPAT_LOG": root.appendingPathComponent("peer.jsonl").path, "PATH": "/usr/bin:/bin"])
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
        let launch = try await resolver.resolve(managed, lifecycle: owner)
        XCTAssertEqual(launch.installation.ownership, .milkManaged)
        XCTAssertNotEqual(launch.installation.id, external.id)
        XCTAssertEqual(launch.dataProfile.directory.path, root.appendingPathComponent("ordinary").path)
        XCTAssertEqual(launch.dataProfile.ownership, .sharedExisting)
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
        XCTAssertEqual(launch.environment["PATH"], executable.deletingLastPathComponent().path + ":/usr/bin:/bin")
        var config = AgentConfiguration(); config.runtime = .external(executable)
        let backend = PiAdapter(runtime: runtime, configuration: { config }).makeBackend(context: .init(permission: .approval, lifecycle: owner))
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

    @MainActor func testProbeRejectsVersionOnlyMissingMarkerMalformedRepliesAndUntestedVersion() async throws {
        for overrides in [["MILK_COMPAT_VERSION_ONLY": "1"], ["MILK_PARITY_READY": "0"], ["MILK_COMPAT_BAD_COMMAND": "get_messages"], ["MILK_PARITY_VERSION": "1.5.0"]] {
            let (root, executable, base) = try fixture(), owner = AgentLifecycleCoordinator()
            var env = base.environmentOverrides; env.merge(overrides) { _, new in new }
            let runtime = PiRuntimeService(resources: base.resources, environmentOverrides: env)
            let before = try ordinarySnapshot(root)
            let report = try await PiCompatibilityProbe.inspect(mode: .external(executable), runtime: runtime, lifecycle: owner)
            XCTAssertEqual(report.state, overrides["MILK_PARITY_VERSION"] == nil ? .incompatibleIntegration : .untested)
            XCTAssertFalse(report.usable); XCTAssertTrue(owner.owned.isEmpty)
            XCTAssertEqual(try ordinarySnapshot(root), before)
            if overrides["MILK_PARITY_VERSION"] != nil {
                var config = AgentConfiguration(); config.runtime = .external(executable)
                let backend = PiBackend(runtime: runtime)
                var state: AgentCompatibilityState?
                backend.onEvent = { if case .runtime(let status) = $0 { state = status.compatibility?.state } }
                do { try await backend.start(workspace: root, session: .init(id: 0, title: "Untested"), configuration: config); XCTFail("Untested version launched") } catch {}
                try await backend.shutdownAndWait()
                XCTAssertEqual(state, report.state, "Startup and Settings probe use the same policy")
                XCTAssertTrue(records(root).isEmpty, "An untested version must not enter RPC")
            }
        }
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
        let runtime = PiRuntimeService(resources: base.resources, environmentOverrides: env)
        let before = try ordinarySnapshot(root)
        let operation = Task { try await PiCompatibilityProbe.inspect(mode: .external(executable), runtime: runtime, lifecycle: owner) }
        let deadline = Date().addingTimeInterval(4)
        while !records(root).contains(where: { $0["command"].string == "get_state" }) {
            guard Date() < deadline else { operation.cancel(); _ = await operation.result; throw AgentError.message("Probe did not enter RPC") }
            await Task.yield()
        }
        let launched = try XCTUnwrap(records(root).first { $0["kind"].string == "launch" })
        XCTAssertTrue(owner.owned.values.contains { $0.purpose == .compatibilityProbe })
        XCTAssertTrue(launched["args"].array.compactMap(\.string).contains("--no-session"))
        XCTAssertNotEqual(launched["agentDir"].string, root.appendingPathComponent("ordinary").path)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled probe returned a result") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(launched["cwd"].string)))
        XCTAssertNotEqual(kill(Int32(try XCTUnwrap(launched["pid"].number)), 0), 0)
        XCTAssertEqual(try ordinarySnapshot(root), before)
    }

    @MainActor func testExplicitExtensionPackageActionUsesSelectedExternalRuntime() async throws {
        let (root, executable, runtime) = try fixture(), owner = AgentLifecycleCoordinator()
        let source = root.appendingPathComponent("trusted.ts")
        try Data("export default function() {}".utf8).write(to: source)
        let service = ExtensionService(agentDirectory: root.appendingPathComponent("ordinary"), runtime: runtime)
        service.lifecycle = owner; service.runtimeSelection = { .external(executable) }
        try await service.installLocalRegistration(source)
        let command = try XCTUnwrap(records(root).first { $0["args"].array.first?.string == "install" })
        XCTAssertEqual(command["args"].array.compactMap(\.string), ["install", source.path, "--no-approve"])
        XCTAssertEqual(command["agentDir"].string, root.appendingPathComponent("ordinary").path)
        XCTAssertFalse(command["path"].string?.contains("PiRuntime/bin") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)); XCTAssertTrue(owner.owned.isEmpty)
    }
}
