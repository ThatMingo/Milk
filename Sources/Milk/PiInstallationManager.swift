import Foundation
import Combine

/// Periodic upstream release discovery. Only runs when Auto Update is enabled.
enum PiUpdateSchedule {
    static let interval: TimeInterval = 24 * 3600
}

/// Backend for Settings → Agents. No scheduler and no user-data actions beyond
/// the explicit lifecycle boundary it is given.
@MainActor final class PiInstallationManager: ObservableObject {
    typealias Download = (URL, URL) async throws -> Void
    typealias Probe = (AgentInstallationRecord, PiRuntimeService, AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult
    let store: AgentInstallationStore
    let lifecycle: AgentLifecycleCoordinator
    let runtime: PiRuntimeService
    let sandboxSettings: SandboxSettingsStore
    let catalog: PiInstallationCatalog
    let discovery: PiReleaseDiscovery
    private let download: Download
    private let probe: Probe
    private let notices: URL
    @Published private(set) var busy = false
    @Published private(set) var availableReleases: [PiCatalogRelease] = []
    @Published private(set) var lastReleaseCheck: Date?
    @Published private(set) var releaseCheckProblem: String?
    private var scheduleTask: Task<Void, Never>?
    /// A release read that has started but not finished. Concurrent callers await it
    /// rather than reading a stale cache.
    private struct PendingReleaseCheck { let id: UUID; let task: Task<[PiCatalogRelease], Never> }
    private var inFlight: PendingReleaseCheck?
    private var checkedThisSession = false
    var prepareForShutdown: () throws -> Void = {}
    var sessionRuntimeVersions: () -> Set<String> = { [] }
    var onSelectionChanged: () -> Void = {}
    var runningInstallations: [AgentInstallationRecord] { lifecycle.runningInstallations(for: .pi) }

    init(store: AgentInstallationStore? = nil, lifecycle: AgentLifecycleCoordinator,
         runtime: PiRuntimeService = PiRuntimeService(), catalog: PiInstallationCatalog = .standard,
         notices: URL? = nil, sandboxSettings: SandboxSettingsStore? = nil,
         discovery: PiReleaseDiscovery = PiReleaseDiscovery(), download: @escaping Download = PiInstallationFiles.download,
         probe: @escaping Probe = { try await PiCompatibilityProbe.inspect(installation: $0, runtime: $1, lifecycle: $2) }) {
        self.sandboxSettings=sandboxSettings ?? SandboxSettingsStore()
        self.store = store ?? AgentInstallationStore(); self.lifecycle = lifecycle; self.runtime = runtime; self.catalog = catalog
        self.discovery = discovery
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
    var sandboxProfiles: [SandboxProfileRoot] {
        var environment=ProcessInfo.processInfo.environment; environment.merge(runtime.environmentOverrides) { _, value in value }
        return [.init(id:"purpose-managed-store",agentID:.pi,url:store.root.appendingPathComponent("profile"),ownership:.managed),
                .init(id:"purpose-existing-store",agentID:.pi,url:PiProfile.existing(environment:environment).directory,ownership:.existing)]
    }
    private func inspect(_ record: AgentInstallationRecord, _ runtime: PiRuntimeService, _ owner: AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult {
        let authority=SandboxLaunchAuthority.capture(settings:sandboxSettings,profiles:sandboxProfiles)
        return try await SandboxLaunchAuthority.$current.withValue(authority) {
            let result=try await probe(record,runtime,owner); try authority.check(); return result
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
    /// Versions whose isolated Milk RPC handshake succeeded on this machine.
    /// Held in the installation store, never a compiled allow-list.
    func verifiedVersions() -> Set<String> {
        var result = Set<String>()
        for value in store.state.managed where value.health.usable && value.health.adapterVersion == PiCompatibilityPolicy.adapterVersion { result.insert(value.release.version) }
        for value in store.state.external {
            if value.health.usable, let version = value.health.version { result.insert(version) }
        }
        return result
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
            let report = try await inspect(value.installation, runtime, lifecycle)
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
    /// Validate a revision Milk already holds and verified. Deliberately offline:
    /// it checks the stored metadata against itself and the code on disk.
    private func validate(_ value: ManagedPiVersion, requireHealth: Bool = true) throws {
        try value.release.validate()
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
        let authority=SandboxLaunchAuthority.capture(settings:sandboxSettings,profiles:sandboxProfiles)
        return try await SandboxLaunchAuthority.$current.withValue(authority) {
            try await PiLaunchResolver(runtime:runtime).resolve(selected,lifecycle:owner,profile:profile(for:selected),verified:verifiedVersions())
        }
    }
    func setAutoUpdate(_ enabled: Bool) throws {
        try enter(); defer { busy = false }
        try store.commit { $0.autoUpdate = enabled }
    }

    // MARK: - Upstream release discovery

    /// Eligible upstream releases plus any Milk-pinned metadata, newest first.
    /// Discovery failures are recorded, never thrown: an unavailable feed must not
    /// break Settings or an already installed runtime.
    func refreshReleases(force: Bool = false) async -> [PiCatalogRelease] {
        let pinned = catalog.releases.filter { (try? $0.validate()) != nil }
        // A freshly started manager has no in-memory feed. Seed it from the metadata the
        // last successful check persisted, otherwise a restart inside the check window
        // would report "no releases available" even though the runtime is installable.
        if availableReleases.isEmpty { availableReleases = ordered(pinned + persistedReleases()) }
        // Concurrent callers join the check already running and receive its completed
        // result instead of a stale cache; no duplicate upstream read is started.
        if let running = inFlight { return await running.task.value }
        let cachedUpstream = availableReleases.filter { $0.origin?.kind == .upstreamRelease }
        // Only a successful read stamps lastReleaseCheck, so a failed check never blocks
        // a retry for the length of the interval.
        let last = lastReleaseCheck ?? store.state.lastReleaseCheck
        let recent = last.map { Date().timeIntervalSince($0) < PiUpdateSchedule.interval } ?? false
        // Reuse the cache when a successful check happened inside the interval and there is
        // a discovered list to reuse (in memory or persisted from a previous session).
        if !force, recent, checkedThisSession || !cachedUpstream.isEmpty { return availableReleases }
        let check = PendingReleaseCheck(id: UUID(), task: Task { () -> [PiCatalogRelease] in
            let discovered: [PiCatalogRelease]
            do {
                discovered = try await self.discovery.eligibleReleases(tools: self.catalog.tools)
            } catch {
                // A cancelled pass is not a reported failure, and a failed read is not a
                // completed check: previously verified releases are kept and the next
                // scheduled pass retries instead of waiting 24 hours.
                if error is CancellationError { return self.availableReleases }
                self.releaseCheckProblem = error.localizedDescription
                return self.availableReleases
            }
            self.releaseCheckProblem = nil
            self.lastReleaseCheck = .now
            self.checkedThisSession = true
            self.availableReleases = ordered(pinned + discovered)
            try? self.store.commit { state in
                state.lastReleaseCheck = self.lastReleaseCheck
                state.discoveredReleases = Array(self.availableReleases.filter { $0.origin?.kind == .upstreamRelease }.prefix(20))
            }
            return self.availableReleases
        })
        inFlight = check
        let result = await check.task.value
        // The pass has finished: clear the handle so a later check starts a fresh read.
        if inFlight?.id == check.id { inFlight = nil }
        return result
    }
    /// Release metadata persisted from the last successful upstream read. Only
    /// metadata that still self-validates and names the official repository is reused.
    private func persistedReleases() -> [PiCatalogRelease] {
        (store.state.discoveredReleases ?? []).filter {
            (try? $0.validate()) != nil && $0.origin?.kind == .upstreamRelease && $0.origin?.repository == PiUpstreamRelease.repository
        }
    }
    private func ordered(_ releases: [PiCatalogRelease]) -> [PiCatalogRelease] {
        var seen = Set<String>()
        return releases.filter { release in
            let key = "\(release.version):\(release.origin?.assetSHA256 ?? release.artifacts.first?.sha256 ?? "")"
            return seen.insert(key).inserted
        }.sorted { PiSemanticVersion.parse($0.version)! > PiSemanticVersion.parse($1.version)! }
    }
    func rejection(for release: PiCatalogRelease) -> PiRejectedRelease? {
        let digest = release.origin?.assetSHA256 ?? release.artifacts.first?.sha256 ?? ""
        return (store.state.rejected ?? []).first { $0.version == release.version && $0.archiveSHA256 == digest }
    }
    func isRejected(_ release: PiCatalogRelease) -> Bool { rejection(for: release) != nil }
    private func recordRejection(_ release: PiCatalogRelease, reason: String) {
        let digest = release.origin?.assetSHA256 ?? release.artifacts.first?.sha256 ?? ""
        try? store.commit { state in
            if state.rejected == nil { state.rejected = [] }
            if !state.rejected!.contains(where: { $0.version == release.version && $0.archiveSHA256 == digest }) {
                state.rejected!.append(PiRejectedRelease(version: release.version, archiveSHA256: digest, reason: reason, rejectedAt: .now))
            }
        }
    }
    /// Candidates that automatic updating may still try.
    func automaticCandidates(force: Bool = false) async -> [PiCatalogRelease] {
        guard store.state.autoUpdate, store.state.pending == nil, !store.state.useLegacyRuntime, let id = store.state.selected,
              let current = store.state.managed.first(where: { $0.id == id }),
              let installed = PiSemanticVersion.parse(current.release.version) else { return [] }
        return await refreshReleases(force: force).filter {
            (PiSemanticVersion.parse($0.version) ?? PiSemanticVersion(major: 0, minor: 0, patch: 0, prerelease: nil)) > installed && rejection(for: $0) == nil
        }
    }
    func scheduleReleaseChecks(interval: TimeInterval = PiUpdateSchedule.interval) {
        stopReleaseSchedule()
        scheduleTask = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                await self.checkForAutomaticUpdate()
                try? await Task.sleep(nanoseconds: UInt64(max(60, interval) * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
    }
    func stopReleaseSchedule() { scheduleTask?.cancel(); scheduleTask = nil }
    func checkForAutomaticUpdate(force: Bool = false) async {
        guard store.state.autoUpdate, !busy, store.state.pending == nil else { return }
        do { try await stageAutomaticUpdateIfEnabled(force: force) } catch { releaseCheckProblem = error.localizedDescription }
    }
    func stageAutomaticUpdateIfEnabled(force: Bool = false) async throws {
        for candidate in await automaticCandidates(force: force) {
            _ = try await install(release: candidate, action: "autoUpdate")
            return
        }
    }
    /// Explicit manual check, used when Auto Update is off.
    func checkForUpdates() async -> [PiCatalogRelease] { await refreshReleases(force: true) }

    func release(for version: String) async throws -> PiCatalogRelease {
        let upstream = await refreshReleases()
        let candidates = catalog.releases + upstream
        guard let value = candidates.first(where: { $0.version == version }) else {
            throw AgentError.message("No verified Pi release metadata for \(version). Check for updates first.")
        }
        try value.validate()
        return value
    }
    func update(_ id: AgentInstallationID, version: String) async throws -> AgentInstallationID {
        _ = try managed(id)
        return try await install(release: release(for: version), action: "update")
    }
    @discardableResult func install(version: String? = nil, action: String = "install") async throws -> AgentInstallationID {
        if let version { return try await install(release: release(for: version), action: action) }
        guard let release = (await refreshReleases()).first else {
            throw AgentError.message("No Pi release is available. Check the connection, or choose an existing installation.")
        }
        return try await install(release: release, action: action)
    }
    /// Install the newest eligible upstream release (or the pinned baseline when
    /// no upstream feed is available).
    @discardableResult func installLatest(action: String = "install") async throws -> AgentInstallationID { try await install(action: action) }
    @discardableResult func install(release: PiCatalogRelease, action: String = "install") async throws -> AgentInstallationID {
        try enter(); defer { busy = false }
        var transaction: AgentRuntimeLease?
        do {
            try release.validate()
            let transactionID = UUID()
            try store.commit { $0.operation = .init(id: transactionID, action: action, version: release.version, stage: .downloading, detail: "Preparing Pi artifacts from the verified release source.") }
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
        // The official release digest is cross-checked against the release's own
        // SHA256SUMS manifest before any byte is downloaded.
        if let origin = release.origin, origin.kind == .upstreamRelease, let sumsURL = origin.sumsURL {
            try lease.check(); try stage(.verifying, "Cross-checking the official release integrity manifest.")
            let sums = try await discovery.fetch(sumsURL); try lease.check()
            try PiReleaseDiscovery.verifySums(candidateDigest: origin.assetSHA256, sumsSHA256: origin.sumsSHA256, sumsBytes: sums)
        }
        let candidate = folder.appendingPathComponent("runtime")
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (index, artifact) in release.artifacts.enumerated() {
            try lease.check(); try stage(.downloading, "Downloading artifact \(index + 1) of \(release.artifacts.count).")
            let archive = folder.appendingPathComponent("artifact-\(index)")
            try await download(artifact.url, archive); try lease.check()
            let expected = artifact.sha256
            let valid = try await Task.detached { try PiInstallationFiles.digest(archive) == expected }.value
            guard valid else {
                recordRejection(release, reason: "Downloaded Pi artifact did not match the digest published by its release.")
                throw AgentError.message("Downloaded Pi artifact integrity verification failed.")
            }
            try stage(.extracting, "Validating archive boundaries.")
            let extracted = folder.appendingPathComponent("extract-\(index)")
            try await Task.detached { try PiInstallationFiles.extract(archive, to: extracted) }.value
            try lease.check()
            if let suffix = artifact.binarySuffix {
                let files = try PiInstallationFiles.inventory(extracted).keys.filter { $0.split(separator: "/").last.map(String.init) == suffix }
                guard files.count == 1, let name = files.first else { throw AgentError.message("Expected exactly one \(suffix) executable in the release artifact.") }
                let destination = candidate.appendingPathComponent(artifact.destination)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: extracted.appendingPathComponent(name), to: destination)
            } else {
                let source = extracted.appendingPathComponent(artifact.destination)
                guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AgentError.message("The Pi release archive has an unexpected runtime layout.") }
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
        // Release-specific provenance travels with the revision it describes.
        try fm.createDirectory(at: noticeDirectory, withIntermediateDirectories: true)
        try Data(release.provenance.utf8).write(to: noticeDirectory.appendingPathComponent("Release-Provenance.txt"))
        let inventory = try await Task.detached { try PiInstallationFiles.validate(candidate, release: release) }.value
        try lease.check()
        let pinned = try release.pinning(inventory)
        let id = AgentInstallationID(rawValue: "pi:managed:" + transactionID.uuidString)
        let candidateRecord = AgentInstallationRecord(id: id, agentID: .pi, ownership: .milkManaged, source: .milkApproved,
            executable: candidate.appendingPathComponent("pi"), expectedVersion: pinned.version, executableSHA256: pinned.files["pi"])
        try stage(.probing, "Checking Pi native RPC and Milk integration.")
        let health = try await inspect(candidateRecord, runtime, lifecycle)
        if !health.usable { recordRejection(pinned, reason: health.detail) }
        try health.requireUsable(); try lease.check()
        guard health.version == pinned.version, health.adapterVersion == PiCompatibilityPolicy.adapterVersion else {
            recordRejection(pinned, reason: "The candidate probe did not verify the release version/adapter.")
            throw AgentError.message("Candidate probe did not verify the pinned version/adapter.")
        }
        guard try PiInstallationFiles.inventory(candidate) == inventory else {
            recordRejection(pinned, reason: "Candidate code changed during compatibility verification.")
            throw AgentError.message("Candidate code changed during compatibility verification; it was not registered.")
        }
        // No await between rename and atomic registration. A crash in this window leaves
        // an unreferenced complete directory, never a selected partial installation.
        let final = store.versions.appendingPathComponent(transactionID.uuidString)
        try fm.createDirectory(at: final, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.moveItem(at: candidate, to: final.appendingPathComponent("runtime"))
        let record = AgentInstallationRecord(id: id, agentID: .pi, ownership: .milkManaged, source: .milkApproved,
            executable: final.appendingPathComponent("runtime/pi"), expectedVersion: pinned.version, executableSHA256: pinned.files["pi"])
        let value = ManagedPiVersion(installation: record, directoryName: transactionID.uuidString, release: pinned,
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
    /// Roll back to the retained known-good revision without requiring the network.
    @discardableResult func rollbackToRetained(_ id: AgentInstallationID, stopRunning: Bool = true) async throws -> AgentInstallationID {
        try enter(); defer { busy = false }
        do {
            try beginOperation("rollback", version: store.state.managed.first(where: { $0.id == id })?.release.version)
            let value = try managed(id); try validate(value)
            guard sessionRuntimeVersions().allSatisfy({ $0 == value.release.version }) else {
                throw AgentError.message("Rollback compatibility with retained session runtime versions is unverified. No runtime or data was changed.")
            }
            try await selectImpl(id, stopRunning: stopRunning)
            return id
        } catch { recordFailure(error); throw error }
    }
    @discardableResult func verify(_ id: AgentInstallationID) async throws -> AgentCompatibilityResult {
        try enter(); defer { busy = false }
        do {
            try beginOperation("verify")
            let value = try managed(id); try validate(value, requireHealth: false)
            let report = try await inspect(value.installation, runtime, lifecycle)
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
        return try await install(release: value.release, action: "repair")
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
            let report = try await inspect(record, runtime, lifecycle)
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
