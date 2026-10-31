import XCTest
import CryptoKit
@testable import Milk

@MainActor private final class InstallGate {
    var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let old = waiters; waiters = []; old.forEach { $0.resume() } }
}
@MainActor private final class InstallRuntime: AgentOwnedResource {
    let exit = InstallGate()
    var stopping = false
    var failExit = false
    func shutdown() { stopping = true }
    func shutdownAndWait() async throws {
        stopping = true; await exit.wait()
        if failExit { throw AgentError.message("fixture exit is unconfirmed") }
    }
}
@MainActor private final class InstallFixture {
    var downloadData = Data()
    var probeFails = false
    var probes = 0
    var altersCandidate = false
    var retainFailedProbe = false
    var retainedProbe: AgentRuntimeLease?
    var retainedResource: InstallRuntime?
    var downloadGate: InstallGate?
    var downloading = false
}

final class PiManagedInstallationTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Local POSIX tar fixture exercises the production libarchive extractor. No downloads.
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
    @MainActor private func fixture(unsafePath: String? = nil, wrongArchitecture: Bool = false) throws -> (PiInstallationManager, InstallFixture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk Managed Pi " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notices = root.appendingPathComponent("notices"); try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try Data("fixture notice".utf8).write(to: notices.appendingPathComponent("LICENSE"))
        var executable = Data([207,250,237,254] + (PiInstallationCatalog.architecture == "arm64" ? [12,0,0,1] : [7,0,0,1]) + [0,0,0,0])
        if wrongArchitecture { executable[4] = 99 }
        executable.append(Data("fixture executable, never run".utf8))
        let archive = tar([(unsafePath ?? "pi/pi", executable, 48), ("pi/runtime.wasm", Data("runtime dependency".utf8), 48)])
        let release = PiCatalogRelease(version: "1.4.0", platform: "darwin", architecture: PiInstallationCatalog.architecture,
            source: URL(string: "https://fixture.invalid/pi/1.4.0")!, artifacts: [
                .init(url: URL(string: "https://fixture.invalid/pi.tar")!, sha256: hash(archive), binarySuffix: nil, destination: "pi")
            ], files: ["pi": hash(executable), "runtime.wasm": hash(Data("runtime dependency".utf8))], executables: ["pi"], notices: ["LICENSE"], provenance: "Controlled fixture only")
        let box = InstallFixture(); box.downloadData = archive
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("ordinary Pi data").path])
        let manager = PiInstallationManager(store: .init(root: root.appendingPathComponent("Agents/pi")), lifecycle: .init(), runtime: runtime,
            catalog: .init(releases: [release]), notices: notices, download: { _, destination in
                box.downloading = true
                await box.downloadGate?.wait()
                try Task.checkCancellation()
                try box.downloadData.write(to: destination)
            }, probe: { record, _, owner in
                box.probes += 1
                XCTAssertEqual(record.ownership, .milkManaged)
                XCTAssertEqual(try PiInstallationFiles.digest(record.executable), record.executableSHA256)
                if box.retainFailedProbe {
                    let resource = InstallRuntime(); resource.exit.release(); resource.failExit = true
                    let lease = owner.begin(activation: .init(agentID: .pi, workspace: root, sessionID: -9), purpose: .compatibilityProbe,
                                            factory: { resource }) { _, lease in lease.associate(record) }
                    box.retainedProbe = lease; box.retainedResource = resource
                    try await lease.work.value
                    try await owner.stopAndWait(lease)
                    XCTFail("The fixture probe must fail to confirm exit")
                }
                if box.probeFails { return PiCompatibilityPolicy.result(.incompatibleIntegration, version: "1.4.0", detail: "fixture handshake failure") }
                if box.altersCandidate { try Data("changed during probe".utf8).write(to: record.executable) }
                return PiCompatibilityPolicy.verified(version: "1.4.0")
            })
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (manager, box, root)
    }
    @MainActor private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() { if Date() > deadline { throw AgentError.message("Timed out: " + description) }; await Task.yield() }
    }
    @MainActor private func rejects(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected a rejected operation", file: file, line: line) } catch { }
    }

    @MainActor func testTransactionalInstallPersistsAndFailuresRetainKnownGoodCode() async throws {
        let (manager, box, _) = try fixture()
        XCTAssertFalse(manager.store.state.autoUpdate)
        let first = try await manager.install()
        let record = try XCTUnwrap(manager.selectedInstallation())
        XCTAssertEqual(record.id, first); XCTAssertEqual(box.probes, 1)
        let code = try Data(contentsOf: record.executable)
        let reloaded = AgentInstallationStore(root: manager.store.root)
        XCTAssertNil(reloaded.loadProblem); XCTAssertEqual(reloaded.state, manager.store.state)
        XCTAssertEqual(reloaded.state.managed.first?.release.provenance, "Controlled fixture only")
        let secondManager = PiInstallationManager(store: reloaded, lifecycle: .init())
        await rejects { try secondManager.setAutoUpdate(true) }
        let archive = box.downloadData; box.downloadData.append(42)
        await rejects { _ = try await manager.update(first, version: "1.4.0") }
        XCTAssertEqual(box.probes, 1, "Hash failure must precede execution")
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.managed.count, 1)
        box.downloadData = archive; box.probeFails = true
        await rejects { _ = try await manager.update(first, version: "1.4.0") }
        XCTAssertEqual(manager.store.state.operation?.stage, .failed)
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertEqual(try Data(contentsOf: record.executable), code)
        box.probeFails = false; box.altersCandidate = true
        await rejects { _ = try await manager.update(first, version: "1.4.0") }
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertTrue(manager.store.state.operation?.detail.contains("changed during") == true)
        box.altersCandidate = false
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.staging.path).isEmpty)
        await rejects { _ = try await manager.install(version: "999.0.0") }
        XCTAssertEqual(manager.store.state.selected, first)
        try manager.setAutoUpdate(true)
        try await manager.stageAutomaticUpdateIfEnabled() // no approved newer version
        XCTAssertTrue(AgentInstallationStore(root: manager.store.root).state.autoUpdate)
    }

    @MainActor func testArchiveBoundariesPlatformAndMissingNoticesFailBeforeProbe() async throws {
        for path in ["../escape", "/absolute-escape"] {
            let (manager, box, _) = try fixture(unsafePath: path)
            await rejects { _ = try await manager.install() }
            XCTAssertTrue(manager.store.state.operation?.detail.contains("archive") == true)
            XCTAssertEqual(box.probes, 0); XCTAssertNil(manager.store.state.selected)
            XCTAssertTrue(manager.store.state.managed.isEmpty)
        }
        let (wrong, box, _) = try fixture(wrongArchitecture: true)
        await rejects { _ = try await wrong.install() }
        XCTAssertTrue(wrong.store.state.operation?.detail.contains("architecture") == true)
        XCTAssertEqual(box.probes, 0)
        let (missing, missingBox, root) = try fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("notices/LICENSE"))
        await rejects { _ = try await missing.install() }
        XCTAssertTrue(missing.store.state.operation?.detail.contains("notice material") == true)
        XCTAssertEqual(missingBox.probes, 0)
        // Symlink/hard-link/special-file entries are rejected independently of hash checks.
        for type in [UInt8(49), 50, 54] {
            let archive = tar([("pi/link", Data(), type)])
            let source = root.appendingPathComponent("unsafe-\(type).tar"); try archive.write(to: source)
            XCTAssertThrowsError(try PiInstallationFiles.extract(source, to: root.appendingPathComponent("unsafe-\(type)")))
        }
    }

    @MainActor func testUpdateStagesAcrossConcurrentAndAuxiliaryWorkThenDrainsBeforeActivationAndRollback() async throws {
        let (manager, _, root) = try fixture()
        let first = try await manager.install(), old = try XCTUnwrap(manager.selectedInstallation())
        manager.lifecycle.onQuiescent = nil // assert the explicit activation boundary under gates
        var leases: [AgentRuntimeLease] = [], resources: [InstallRuntime] = []
        let purposes: [(Int, AgentBackendPurpose)] = [(1,.conversation),(2,.conversation),(-1,.previewInspection),(-2,.versionProbe)]
        for (id, purpose) in purposes {
            let resource = InstallRuntime(); resources.append(resource)
            let lease = manager.lifecycle.begin(activation: .init(agentID: .pi, workspace: root, sessionID: id), purpose: purpose,
                                                factory: { resource }) { _, lease in lease.associate(old) }
            leases.append(lease); try await lease.work.value
        }
        let next = try await manager.update(first, version: "1.4.0")
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.pending, next)
        XCTAssertEqual(Set(manager.runningInstallations.map(\.id)), [first])
        XCTAssertTrue(resources.allSatisfy { !$0.stopping })
        await rejects { try await manager.activatePending() }
        XCTAssertEqual(manager.store.state.selected, first)
        let activation = Task { try await manager.activatePending(stopRunning: true) }
        try await until("shutdown requested") { resources.allSatisfy(\.stopping) }
        var constructed = false
        let late = manager.lifecycle.begin(activation: .init(agentID: .pi, workspace: root, sessionID: 3), purpose: .conversation,
                                          factory: { constructed = true; return AgentOperationResource() }) { _, _ in }
        await rejects { try await late.work.value }
        XCTAssertFalse(constructed); XCTAssertEqual(manager.store.state.selected, first)
        for resource in resources.dropLast() { resource.exit.release() }
        await Task.yield(); XCTAssertEqual(manager.store.state.selected, first)
        resources.last?.exit.release(); try await activation.value
        XCTAssertEqual(manager.store.state.selected, next); XCTAssertEqual(manager.store.state.previous, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.executable.path))
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        manager.sessionRuntimeVersions = { ["unknown-future-session-version"] }
        await rejects { try await manager.rollback() }
        XCTAssertEqual(manager.store.state.selected, next)
        manager.sessionRuntimeVersions = { ["1.4.0"] }
        try await manager.rollback()
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.previous, next)
        let failedExit = InstallRuntime(); failedExit.exit.release(); failedExit.failExit = true
        let failing = manager.lifecycle.begin(activation: .init(agentID: .pi, workspace: root, sessionID: 4), purpose: .conversation,
                                              factory: { failedExit }) { _, lease in lease.associate(old) }
        try await failing.work.value
        await rejects { try await manager.remove(first) }
        XCTAssertEqual(manager.store.state.selected, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.executable.path))
        XCTAssertTrue(manager.lifecycle.hasWork(for: .pi), "Failed exit remains owned and blocks deletion")
        failedExit.failExit = false
        try await manager.remove(first)
        XCTAssertNil(manager.store.state.selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.executable.path))
        XCTAssertTrue(manager.store.state.managed.contains { $0.id == next })
    }

    @MainActor func testQuiescentActivationAndRepairUseNewImmutableCodeAndPreserveSharedData() async throws {
        let (manager, _, root) = try fixture()
        let ordinary = root.appendingPathComponent("ordinary Pi data")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        for name in ["auth.json", "settings.json", "session.jsonl", "extension.ts"] { try Data(name.utf8).write(to: ordinary.appendingPathComponent(name)) }
        let before = try PiInstallationFiles.inventory(ordinary)
        let first = try await manager.install(), record = try XCTUnwrap(manager.selectedInstallation())
        let resource = InstallRuntime(); resource.exit.release()
        let lease = manager.lifecycle.begin(activation: .init(agentID: .pi, workspace: root, sessionID: 1), purpose: .conversation,
                                            factory: { resource }) { _, lease in lease.associate(record) }
        try await lease.work.value
        let next = try await manager.update(first, version: "1.4.0")
        XCTAssertEqual(manager.store.state.selected, first)
        try await manager.lifecycle.stopAndWait(lease)
        try await until("staged update activated on natural quiescence") { manager.store.state.selected == next && !manager.busy }
        let current = try XCTUnwrap(manager.selectedInstallation())
        try Data("corrupt runtime".utf8).write(to: current.executable)
        await rejects { _ = try await manager.verify(next) }
        let repaired = try await manager.repair(next)
        XCTAssertNotEqual(repaired, next); XCTAssertEqual(manager.store.state.selected, repaired)
        XCTAssertNotEqual(try manager.selectedInstallation()?.executable, current.executable)
        XCTAssertEqual(manager.store.state.previous, first, "Corrupt selected code must not replace the retained known-good rollback")
        XCTAssertEqual(try PiInstallationFiles.inventory(ordinary), before)
        let health = try await manager.verify(repaired)
        XCTAssertTrue(health.usable)
    }

    @MainActor func testRemovalAndReinstallPreserveSessionIdentityDraftCacheAndUserFiles() async throws {
        let (manager, _, root) = try fixture()
        _ = try await manager.install()
        let suite = "Milk.ManagedRemoval." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePersistence(defaults: defaults, directory: root.appendingPathComponent("Milk/Workspaces"), enabled: true)
        let workspace = WorkspaceStore(persistence: persistence); try workspace.openWorkspace(root)
        let adapter = PiAdapter(runtime: manager.runtime, installations: manager)
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, adapter: adapter, lifecycle: manager.lifecycle)
        workspace.sessionData = { agent.snapshot() }; agent.restore(nil)
        manager.prepareForShutdown = { try agent.prepareForInstallationChange() }
        agent.current.draft = "retain draft"; agent.current.queued = .init(text: "recover queue", attachments: [])
        let identity = try XCTUnwrap(agent.currentSession?.metadata.id), owner = try XCTUnwrap(agent.currentSession?.agentID)
        let userDirectory = root.appendingPathComponent("ordinary Pi data")
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        for name in ["auth.json", "settings.json", "session.jsonl", "extension.ts"] { try Data(name.utf8).write(to: userDirectory.appendingPathComponent(name)) }
        let before = try PiInstallationFiles.inventory(userDirectory)
        try await manager.removeManagedPi()
        XCTAssertFalse(manager.store.state.useLegacyRuntime); XCTAssertNil(manager.store.state.selected)
        XCTAssertTrue(manager.store.state.managed.isEmpty); XCTAssertTrue(manager.store.state.removals.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.versions.path).isEmpty)
        XCTAssertEqual(agent.currentSession?.metadata.id, identity); XCTAssertEqual(agent.currentSession?.agentID, owner)
        XCTAssertTrue(agent.current.draft.contains("retain draft")); XCTAssertTrue(agent.current.draft.contains("recover queue"))
        XCTAssertEqual(agent.availability(agent.currentSession!).state, .runtimeUnavailable)
        XCTAssertTrue(agent.retainedSessions().contains { $0.metadata.id == identity })
        XCTAssertEqual(try PiInstallationFiles.inventory(userDirectory), before)
        _ = try await manager.install()
        XCTAssertEqual(agent.currentSession?.metadata.id, identity)
        XCTAssertEqual(agent.currentSession?.agentID, owner)
        XCTAssertTrue(agent.availability(agent.currentSession!).canAttemptResume)
        XCTAssertEqual(try PiInstallationFiles.inventory(userDirectory), before)
        workspace.sessionData = nil; try workspace.closeWorkspace()
        let exited = await agent.shutdownAndWait()
        XCTAssertTrue(exited)
    }

    @MainActor func testExternalRegistrationIsNeverManagedMutationOrFileOwnership() async throws {
        let (base, _, root) = try fixture()
        let executable = root.appendingPathComponent("external")
        try Data("external user code".utf8).write(to: executable)
        let manager = PiInstallationManager(store: base.store, lifecycle: base.lifecycle, runtime: base.runtime,
            probe: { _, _, _ in PiCompatibilityPolicy.verified(version: "1.4.0") })
        let id = try await manager.registerExternal(executable)
        try await manager.select(id)
        let before = try Data(contentsOf: executable)
        await rejects { _ = try await manager.update(id, version: "1.4.0") }
        await rejects { _ = try await manager.repair(id) }
        await rejects { try await manager.remove(id) }
        await rejects { _ = try await manager.verify(id) }
        await rejects { try await manager.rollback() }
        try manager.setAutoUpdate(true); try await manager.stageAutomaticUpdateIfEnabled()
        XCTAssertEqual(try Data(contentsOf: executable), before)
        XCTAssertEqual(manager.store.state.selected, id)
        try await manager.forgetExternal(id)
        XCTAssertTrue(manager.store.state.external.isEmpty); XCTAssertNil(manager.store.state.selected)
        XCTAssertEqual(try Data(contentsOf: executable), before)
    }

    @MainActor func testCancellationCrashRecoveryAndCorruptStoreCannotActivatePartialCode() async throws {
        let (manager, box, _) = try fixture()
        let first = try await manager.install()
        box.downloading = false; let gate = InstallGate(); box.downloadGate = gate
        let task = Task { try await manager.update(first, version: "1.4.0") }
        try await until("download held") { box.downloading }
        task.cancel(); gate.release()
        await rejects { _ = try await task.value }
        XCTAssertEqual(manager.store.state.selected, first); XCTAssertEqual(manager.store.state.managed.count, 1)
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        let operationID = UUID(), path = manager.store.staging.appendingPathComponent(operationID.uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: path.appendingPathComponent("download"))
        try manager.store.commit { $0.operation = .init(id: operationID, action: "install", version: "1.4.0", stage: .extracting, detail: "crash fixture") }
        try manager.recoverInterruptedTransactions()
        XCTAssertEqual(manager.store.state.operation?.stage, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)); XCTAssertEqual(manager.store.state.selected, first)
        let badRoot = manager.store.root.deletingLastPathComponent().appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: badRoot, withIntermediateDirectories: true)
        let bytes = Data("{broken state".utf8); try bytes.write(to: badRoot.appendingPathComponent("state.json"))
        let bad = AgentInstallationStore(root: badRoot)
        XCTAssertNotNil(bad.loadProblem); XCTAssertThrowsError(try bad.commit { $0.autoUpdate = true })
        XCTAssertEqual(try Data(contentsOf: bad.file), bytes)
        // Persisted removal intent is retryable after a crash and never reselects code.
        let value = try XCTUnwrap(manager.store.state.managed.first)
        try manager.store.commit { $0.removals.append(value); $0.managed = []; $0.selected = nil; $0.useLegacyRuntime = false }
        try manager.recoverInterruptedTransactions()
        XCTAssertTrue(manager.store.state.removals.isEmpty); XCTAssertThrowsError(try manager.selectedInstallation())
    }

    @MainActor func testManagedRecordProbeUsesNativeHandshakeAndIntegrityPins() async throws {
        let (manager, _, root) = try fixture()
        let executable = root.appendingPathComponent("probe peer")
        try FileManager.default.copyItem(at: project.appendingPathComponent("Tests/Fixtures/pi_parity_peer.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = PiRuntimeService(resources: manager.runtime.resources, environmentOverrides: ["MILK_PARITY_READY": "1"])
        var record = AgentInstallationRecord(id: .init(rawValue: "fixture-managed-probe"), agentID: .pi, ownership: .milkManaged,
            source: .milkApproved, executable: executable, expectedVersion: "1.4.0", executableSHA256: try PiInstallationFiles.digest(executable))
        let report = try await PiCompatibilityProbe.inspect(installation: record, runtime: runtime, lifecycle: manager.lifecycle)
        XCTAssertTrue(report.usable); XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        record.executableSHA256 = String(repeating: "0", count: 64)
        let rejected = try await PiCompatibilityProbe.inspect(installation: record, runtime: runtime, lifecycle: manager.lifecycle)
        XCTAssertEqual(rejected.state, .invalidRuntime); XCTAssertFalse(rejected.usable)
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
    }

    @MainActor func testFailedProbeExitRetainsStagingUntilOwnedShutdownIsConfirmed() async throws {
        let (manager, box, _) = try fixture()
        box.retainFailedProbe = true
        await rejects { _ = try await manager.install() }
        let lease = try XCTUnwrap(box.retainedProbe), resource = try XCTUnwrap(box.retainedResource)
        let executable = try XCTUnwrap(lease.installation?.executable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path))
        XCTAssertTrue(manager.store.state.managed.isEmpty)
        XCTAssertThrowsError(try manager.recoverInterruptedTransactions())
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path))
        resource.failExit = false
        try await manager.lifecycle.stopAndWait(lease)
        try manager.recoverInterruptedTransactions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path))
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.store.staging.path).isEmpty)
    }
}
