import Foundation
import Combine

/// Backend for the future Settings → Agents. No scheduler and no user-data actions.
@MainActor final class PiInstallationManager: ObservableObject {
    typealias Download = (URL, URL) async throws -> Void
    typealias Probe = (AgentInstallationRecord, PiRuntimeService, AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult
    let store: AgentInstallationStore
    let lifecycle: AgentLifecycleCoordinator
    let runtime: PiRuntimeService
    let catalog: PiInstallationCatalog
    private let download: Download
    private let probe: Probe
    private let notices: URL
    @Published private(set) var busy = false
    var prepareForShutdown: () throws -> Void = {}
    var sessionRuntimeVersions: () -> Set<String> = { [] }
    var onSelectionChanged: () -> Void = {}
    var runningInstallations: [AgentInstallationRecord] { lifecycle.runningInstallations(for: .pi) }

    init(store: AgentInstallationStore? = nil, lifecycle: AgentLifecycleCoordinator,
         runtime: PiRuntimeService = PiRuntimeService(), catalog: PiInstallationCatalog = .standard,
         notices: URL? = nil, download: @escaping Download = PiInstallationFiles.download,
         probe: @escaping Probe = { try await PiCompatibilityProbe.inspect(installation: $0, runtime: $1, lifecycle: $2) }) {
        self.store = store ?? AgentInstallationStore(); self.lifecycle = lifecycle; self.runtime = runtime; self.catalog = catalog
        self.notices = notices ?? runtime.resources.appendingPathComponent("ThirdPartyNotices")
        self.download = download; self.probe = probe
        lifecycle.onQuiescent = { [weak self] agent in
            guard agent == .pi, let self, !self.busy, self.store.state.pending != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.busy else { return }
                do { try await self.activatePending() } catch { self.recordFailure(error) }
            }
        }
    }
    private func enter() throws {
        guard !busy else { throw AgentError.message("Another installation operation is in progress.") }
        try store.acquire(); busy = true
    }
    private func stage(_ stage: AgentInstallationOperation.Stage, _ detail: String) throws {
        try store.commit { $0.operation?.stage = stage; $0.operation?.detail = detail; $0.operation?.updatedAt = .now }
    }
    private func beginOperation(_ action: String, version: String? = nil) throws {
        try store.commit { $0.operation = .init(id: UUID(), action: action, version: version, stage: .verifying, detail: "Preparing \(action).") }
    }
    private func recordFailure(_ error: Error) {
        try? store.commit { state in
            if state.operation == nil { state.operation = .init(id: UUID(), action: "maintenance", version: nil, stage: .failed, detail: error.localizedDescription) }
            else { state.operation?.stage = .failed; state.operation?.detail = error.localizedDescription; state.operation?.updatedAt = .now }
        }
    }
    private func managed(_ id: AgentInstallationID) throws -> ManagedPiVersion {
        guard let version = store.state.managed.first(where: { $0.id == id }), version.installation.ownership == .milkManaged else {
            throw AgentError.message("This action requires a Milk-managed Pi installation. External executables cannot be updated, replaced, repaired, rolled back or deleted.")
        }
        return version
    }
    /// One-time preference migration, metadata only: no launch, copying or download.
    func migrateLegacySelection(_ mode: PiRuntimeMode) throws {
        guard store.state.useLegacyRuntime else { return }
        try enter(); defer { busy = false }
        try store.commit { state in
            guard state.useLegacyRuntime else { return }
            state.useLegacyRuntime = false; state.selected = nil
            if case .external(let executable) = mode {
                let record = PiLaunchResolver(runtime: runtime).installation(for: .external(executable))
                if !state.external.contains(where: { $0.installation.id == record.id }) {
                    state.external.append(.init(installation: record,
                        health: PiCompatibilityPolicy.result(.untested, version: nil, detail: "Existing selection retained. Verify compatibility before using Pi."), checkedAt: .distantPast))
                }
                state.selected = record.id
            }
        }
    }
    func verifyExternal(_ id: AgentInstallationID) async throws {
        try enter(); defer { busy = false }
        do {
            guard let value = store.state.external.first(where: { $0.installation.id == id }) else { throw AgentError.message("Unknown existing installation.") }
            try beginOperation("verifyExternal")
            let report = try await probe(value.installation, runtime, lifecycle)
            try store.commit { state in
                if let index = state.external.firstIndex(where: { $0.installation.id == id }) { state.external[index].health = report; state.external[index].checkedAt = .now }
            }
            try report.requireUsable(); try stage(.completed, "Existing Pi compatibility verified. Its files were preserved.")
        } catch { recordFailure(error); throw error }
    }
    func retryRemoval() async throws {
        try enter(); defer { busy = false }
        do {
            try await lifecycle.withMaintenance(agent: .pi, stopRunning: true, prepare: prepareForShutdown) {
                try finishRemovals(); try stage(.completed, "Managed runtime removal completed; user data retained.")
            }
        } catch { recordFailure(error); throw error }
    }
    private func validate(_ value: ManagedPiVersion, requireHealth: Bool = true) throws {
        guard try catalog.approved(value.release.version) == value.release else { throw AgentError.message("Retained runtime is no longer approved by this Milk adapter.") }
        let directory = try store.directory(for: value)
        try store.rejectLinks(directory)
        let actual = try PiInstallationFiles.validate(directory, release: value.release)
        guard actual == value.inventory else { throw AgentError.message("Managed runtime inventory has changed. Repair this installation.") }
        if requireHealth {
            guard value.health.usable, value.health.adapterVersion == PiCompatibilityPolicy.adapterVersion else { throw AgentError.message("Managed Pi needs compatibility verification with this adapter.") }
        }
    }
    /// nil means honor the unchanged bundled/external preference during transition.
    func selectedInstallation(verifyIntegrity: Bool = true) throws -> AgentInstallationRecord? {
        if let problem = store.loadProblem { throw AgentError.message(problem) }
        if store.state.useLegacyRuntime {
            // Explicit fixture adapters can still resolve legacy runtimes. The app
            // migrates preferences before workspace restoration and never falls back.
            guard runtime.allowsBundledFixture else { throw AgentError.message("Pi is not installed. Open Settings → Agents to install Pi or use an existing installation.") }
            return nil
        }
        guard let id = store.state.selected else { throw AgentError.message("Pi has no selected runtime. Install Pi or select an existing installation. Retained sessions are preserved.") }
        try store.acquire()
        if let value = store.state.managed.first(where: { $0.id == id }) {
            if verifyIntegrity { try validate(value) }
            return value.installation
        }
        guard let value = store.state.external.first(where: { $0.installation.id == id }) else { throw AgentError.message("The selected Pi registration is unavailable.") }
        try value.health.requireUsable()
        return value.installation
    }
    func resolve(legacy: PiRuntimeMode, owner: AgentLifecycleCoordinator?) async throws -> PiLaunchContext {
        let selected = try selectedInstallation() ?? PiLaunchResolver(runtime: runtime).installation(for: legacy)
        return try await PiLaunchResolver(runtime: runtime).resolve(selected, lifecycle: owner)
    }
    func setAutoUpdate(_ enabled: Bool) throws {
        try enter(); defer { busy = false }
        try store.commit { $0.autoUpdate = enabled }
    }
    func stageAutomaticUpdateIfEnabled() async throws {
        guard store.state.autoUpdate, store.state.pending == nil, !store.state.useLegacyRuntime, let id = store.state.selected,
              let current = store.state.managed.first(where: { $0.id == id }) else { return }
        // No upstream-latest adoption. Semantic comparison only among approved releases.
        let versions = catalog.releases.map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        guard let next = versions.last, next.compare(current.release.version, options: .numeric) == .orderedDescending else { return }
        _ = try await install(version: next, action: "autoUpdate")
    }
    func update(_ id: AgentInstallationID, version: String) async throws -> AgentInstallationID {
        _ = try managed(id)
        return try await install(version: version, action: "update")
    }
    @discardableResult func install(version: String = "1.4.0", action: String = "install") async throws -> AgentInstallationID {
        try enter(); defer { busy = false }
        var transaction: AgentRuntimeLease?
        do {
            let release = try catalog.approved(version), transactionID = UUID()
            try store.commit { $0.operation = .init(id: transactionID, action: action, version: version, stage: .downloading, detail: "Preparing approved Pi artifacts.") }
            var result: AgentInstallationID?
            let lease = lifecycle.begin(activation: .init(agentID: .pi, workspace: store.root, sessionID: -1), purpose: .installationTransaction,
                                        factory: { AgentOperationResource() }) { _, lease in
                result = try await self.prepare(release, transactionID: transactionID, lease: lease)
            }
            transaction = lease
            try await withTaskCancellationHandler(operation: { try await lease.work.value }, onCancel: { Task { @MainActor in self.lifecycle.stop(lease) } })
            try await lifecycle.stopAndWait(lease)
            try Task.checkCancellation()
            guard let result else { throw CancellationError() }
            if !lifecycle.hasWork(for: .pi) { try await activatePendingImpl(stopRunning: false) }
            return result
        } catch {
            if let transaction { try await lifecycle.stopAndWait(transaction) }
            recordFailure(error); throw error
        }
    }
    private func prepare(_ release: PiCatalogRelease, transactionID: UUID, lease: AgentRuntimeLease) async throws -> AgentInstallationID {
        let fm = FileManager.default
        let folder = store.staging.appendingPathComponent(transactionID.uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            let prefix = folder.standardizedFileURL.path + "/"
            let stillOwned = lifecycle.owned.values.contains { lease in
                lease.installation?.executable.standardizedFileURL.path.hasPrefix(prefix) == true
            }
            // A failed probe exit remains lifecycle-owned. Keep its code until an
            // explicit recovery can confirm no process still uses this staging root.
            if !stillOwned { try? fm.removeItem(at: folder) }
        }
        let candidate = folder.appendingPathComponent("runtime")
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (index, artifact) in release.artifacts.enumerated() {
            try lease.check(); try stage(.downloading, "Downloading artifact \(index + 1) of \(release.artifacts.count).")
            let archive = folder.appendingPathComponent("artifact-\(index)")
            try await download(artifact.url, archive); try lease.check()
            let expected = artifact.sha256
            let valid = try await Task.detached { try PiInstallationFiles.digest(archive) == expected }.value
            guard valid else { throw AgentError.message("Downloaded Pi artifact integrity verification failed.") }
            try stage(.extracting, "Validating archive boundaries.")
            let extracted = folder.appendingPathComponent("extract-\(index)")
            try await Task.detached { try PiInstallationFiles.extract(archive, to: extracted) }.value
            try lease.check()
            if let suffix = artifact.binarySuffix {
                let files = try PiInstallationFiles.inventory(extracted).keys.filter { $0.split(separator: "/").last.map(String.init) == suffix }
                guard files.count == 1, let name = files.first else { throw AgentError.message("Expected exactly one \(suffix) executable in approved artifact.") }
                let destination = candidate.appendingPathComponent(artifact.destination)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: extracted.appendingPathComponent(name), to: destination)
            } else {
                let source = extracted.appendingPathComponent(artifact.destination)
                guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AgentError.message("Approved Pi archive has an unexpected runtime layout.") }
                for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) { try fm.copyItem(at: entry, to: candidate.appendingPathComponent(entry.lastPathComponent)) }
            }
        }
        try stage(.verifying, "Verifying platform, architecture, runtime closure and notices.")
        let noticeDirectory = candidate.appendingPathComponent("MilkNotices")
        for name in release.notices {
            let source = notices.appendingPathComponent(name), destination = noticeDirectory.appendingPathComponent(name)
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true else { throw AgentError.message("Required provenance/notice material is missing: \(name).") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
        let inventory = try await Task.detached { try PiInstallationFiles.validate(candidate, release: release) }.value
        try lease.check()
        let id = AgentInstallationID(rawValue: "pi:managed:" + transactionID.uuidString)
        let candidateRecord = AgentInstallationRecord(id: id, agentID: .pi, ownership: .milkManaged, source: .milkApproved,
            executable: candidate.appendingPathComponent("pi"), expectedVersion: release.version, executableSHA256: release.files["pi"])
        try stage(.probing, "Checking Pi native RPC and Milk integration.")
        let health = try await probe(candidateRecord, runtime, lifecycle)
        try health.requireUsable(); try lease.check()
        guard health.version == release.version, health.adapterVersion == PiCompatibilityPolicy.adapterVersion else { throw AgentError.message("Candidate probe did not verify the pinned version/adapter.") }
        guard try PiInstallationFiles.inventory(candidate) == inventory else { throw AgentError.message("Candidate code changed during compatibility verification; it was not registered.") }
        // No await between rename and atomic registration. A crash in this window leaves
        // an unreferenced complete directory, never a selected partial installation.
        let final = store.versions.appendingPathComponent(transactionID.uuidString)
        try fm.createDirectory(at: final, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.moveItem(at: candidate, to: final.appendingPathComponent("runtime"))
        let record = AgentInstallationRecord(id: id, agentID: .pi, ownership: .milkManaged, source: .milkApproved,
            executable: final.appendingPathComponent("runtime/pi"), expectedVersion: release.version, executableSHA256: release.files["pi"])
        let value = ManagedPiVersion(installation: record, directoryName: transactionID.uuidString, release: release,
                                     installedAt: .now, inventory: inventory, health: health, checkedAt: .now)
        do { try store.commit { $0.managed.append(value); $0.pending = id; $0.operation?.stage = .staged; $0.operation?.detail = "Verified runtime awaiting activation." } }
        catch { try? fm.removeItem(at: final); throw error }
        return id
    }
    func activatePending(stopRunning: Bool = false) async throws {
        try enter(); defer { busy = false }
        do { try await activatePendingImpl(stopRunning: stopRunning) } catch { recordFailure(error); throw error }
    }
    private func activatePendingImpl(stopRunning: Bool) async throws {
        guard let id = store.state.pending else { return }
        try await selectImpl(id, stopRunning: stopRunning)
    }
    func select(_ id: AgentInstallationID, stopRunning: Bool = false) async throws {
        try enter(); defer { busy = false }
        do { try beginOperation("select"); try await selectImpl(id, stopRunning: stopRunning) } catch { recordFailure(error); throw error }
    }
    private func selectImpl(_ id: AgentInstallationID, stopRunning: Bool) async throws {
        if let value = store.state.managed.first(where: { $0.id == id }) { try validate(value) }
        else if let value = store.state.external.first(where: { $0.installation.id == id }) { try value.health.requireUsable() }
        else { throw AgentError.message("Unknown Pi installation registration.") }
        try await lifecycle.withMaintenance(agent: .pi, stopRunning: stopRunning, prepare: prepareForShutdown) {
            if let value = store.state.managed.first(where: { $0.id == id }) { try validate(value) }
            try store.commit { state in
                if let old = state.selected, old != id, let previous = state.managed.first(where: { $0.id == old }), (try? validate(previous)) != nil { state.previous = old }
                state.selected = id; state.useLegacyRuntime = false
                if state.pending == id { state.pending = nil }
                state.operation?.stage = .completed; state.operation?.detail = "Runtime selected; sessions retain their original ownership and data."
            }
            onSelectionChanged()
        }
    }
    func rollback(stopRunning: Bool = true) async throws {
        try enter(); defer { busy = false }
        do {
            try beginOperation("rollback")
            guard let selected = store.state.selected else { throw AgentError.message("No managed runtime is selected for rollback.") }
            _ = try managed(selected)
            guard let id = store.state.previous else { throw AgentError.message("No retained known-good managed Pi runtime is available.") }
            let value = try managed(id); try validate(value)
            guard sessionRuntimeVersions().allSatisfy({ $0 == value.release.version }) else { throw AgentError.message("Rollback compatibility with retained session runtime versions is unverified. No runtime or data was changed.") }
            try await selectImpl(id, stopRunning: stopRunning)
        } catch { recordFailure(error); throw error }
    }
    @discardableResult func verify(_ id: AgentInstallationID) async throws -> AgentCompatibilityResult {
        try enter(); defer { busy = false }
        do {
            try beginOperation("verify")
            let value = try managed(id); try validate(value, requireHealth: false)
            let report = try await probe(value.installation, runtime, lifecycle)
            try store.commit { state in
                if let i = state.managed.firstIndex(where: { $0.id == id }) { state.managed[i].health = report; state.managed[i].checkedAt = .now }
            }
            try report.requireUsable(); try stage(.completed, "Managed Pi files and integration verified."); return report
        } catch {
            try? store.commit { state in
                if let i = state.managed.firstIndex(where: { $0.id == id }) {
                    state.managed[i].health = PiCompatibilityPolicy.result(.invalidRuntime, version: state.managed[i].release.version, detail: error.localizedDescription)
                    state.managed[i].checkedAt = .now
                }
            }
            recordFailure(error); throw error
        }
    }
    @discardableResult func repair(_ id: AgentInstallationID) async throws -> AgentInstallationID {
        let value = try managed(id)
        // Reconstruct into a NEW immutable directory, including same-version repair.
        return try await install(version: value.release.version, action: "repair")
    }
    func remove(_ id: AgentInstallationID, stopRunning: Bool = true) async throws {
        try enter(); defer { busy = false }
        do {
            let value = try managed(id)
            try beginOperation("remove", version: value.release.version)
            try await lifecycle.withMaintenance(agent: .pi, stopRunning: stopRunning, prepare: prepareForShutdown) {
                try store.commit { state in
                    state.removals.append(value); state.managed.removeAll { $0.id == id }
                    if state.selected == id { state.selected = nil; state.useLegacyRuntime = false }
                    if state.pending == id { state.pending = nil }
                    if state.previous == id { state.previous = nil }
                }
                onSelectionChanged()
                try finishRemovals()
                try stage(.completed, "Managed runtime code removed; Pi and Milk user data retained.")
            }
        } catch { recordFailure(error); throw error }
    }
    func removeManagedPi(stopRunning: Bool = true) async throws {
        try enter(); defer { busy = false }
        do {
            try beginOperation("removeManagedPi")
            try await lifecycle.withMaintenance(agent: .pi, stopRunning: stopRunning, prepare: prepareForShutdown) {
                try store.commit { state in
                    let ids = Set(state.managed.map(\.id))
                    state.removals.append(contentsOf: state.managed); state.managed = []
                    if let selected = state.selected, ids.contains(selected) { state.selected = nil; state.useLegacyRuntime = false }
                    state.pending = nil; state.previous = nil
                }
                onSelectionChanged(); try finishRemovals()
                try stage(.completed, "Managed Pi code removed; Pi and Milk user data retained.")
            }
        } catch { recordFailure(error); throw error }
    }
    private func finishRemovals() throws {
        for value in store.state.removals {
            let directory = try store.directory(for: value).deletingLastPathComponent()
            try store.rejectLinks(directory)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try store.commit { $0.removals.removeAll { $0.id == value.id } }
        }
    }
    func recoverInterruptedTransactions() throws {
        try enter(); defer { busy = false }
        guard !lifecycle.hasWork(for: .pi) else { throw AgentError.message("Stop Pi before recovering installation maintenance.") }
        try finishRemovals()
        if let operation = store.state.operation, ["install", "update", "repair", "autoUpdate"].contains(operation.action),
           [.downloading, .extracting, .verifying, .probing, .failed, .interrupted].contains(operation.stage) {
            let path = store.staging.appendingPathComponent(operation.id.uuidString)
            try store.rejectLinks(path)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            try stage(.interrupted, "Installation interrupted before activation. Retry; the prior selected runtime was retained.")
        }
        // Unknown/orphan version directories are deliberately not adopted or deleted.
    }
    @discardableResult func registerExternal(_ executable: URL) async throws -> AgentInstallationID {
        try enter(); defer { busy = false }
        do {
            try beginOperation("registerExternal")
            guard executable.isFileURL, executable.path.hasPrefix("/") else { throw AgentError.message("Choose an absolute external executable path.") }
            let record = PiLaunchResolver(runtime: runtime).installation(for: .external(executable))
            let report = try await probe(record, runtime, lifecycle)
            try report.requireUsable()
            try store.commit { state in
                state.external.removeAll { $0.installation.id == record.id }
                state.external.append(.init(installation: record, health: report, checkedAt: .now))
            }
            try stage(.completed, "Existing installation validated and registered; its files remain externally owned.")
            return record.id
        } catch { recordFailure(error); throw error }
    }
    func forgetExternal(_ id: AgentInstallationID, stopRunning: Bool = true) async throws {
        try enter(); defer { busy = false }
        do {
        guard store.state.external.contains(where: { $0.installation.id == id }) else { throw AgentError.message("Not an external Pi registration.") }
        try beginOperation("forgetExternal")
        try await lifecycle.withMaintenance(agent: .pi, stopRunning: stopRunning, prepare: prepareForShutdown) {
            try store.commit { state in
                state.external.removeAll { $0.installation.id == id }
                if state.selected == id { state.selected = nil; state.useLegacyRuntime = false }
            }
            onSelectionChanged()
            try stage(.completed, "External registration forgotten; its files were preserved.")
        }
        } catch { recordFailure(error); throw error }
    }
}
