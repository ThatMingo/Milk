import Foundation
import Combine

/// UI policy and action routing; installation ownership stays in the Phase 5 backend.
@MainActor final class AgentManagerModel: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case install, useExisting, check, update, verify, repair, rollback, remove, forget, activate, retry
        var id: String { rawValue }
        var title: String {
            switch self {
            case .install: return "Install"
            case .useExisting: return "Use Existing Installation…"
            case .check: return "Check for Updates"
            case .update: return "Update"
            case .verify: return "Verify"
            case .repair: return "Repair"
            case .rollback: return "Roll Back…"
            case .remove: return "Remove…"
            case .forget: return "Forget…"
            case .activate: return "Activate Update…"
            case .retry: return "Retry"
            }
        }
    }
    let manager: PiInstallationManager
    @Published private(set) var performing = false
    @Published private(set) var feedback = ""
    private var subscriptions: Set<AnyCancellable> = []
    init(manager: PiInstallationManager) {
        self.manager = manager
        manager.store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        manager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    var state: PiInstallationState { manager.store.state }
    var busy: Bool { performing || manager.busy }
    var managed: ManagedPiVersion? { state.managed.first { $0.id == state.selected } }
    var external: ExternalAgentInstallation? { state.external.first { $0.installation.id == state.selected } }
    var selectedRecord: AgentInstallationRecord? { managed?.installation ?? external?.installation }
    var health: AgentCompatibilityResult? { managed?.health ?? external?.health }
    var selectedVersion: String { health?.version ?? selectedRecord?.expectedVersion ?? "Not verified" }
    /// Eligible releases discovered from the official upstream repository, plus
    /// any Milk-pinned metadata, newest first.
    var availableReleases: [PiCatalogRelease] { manager.availableReleases }
    var latestAvailableRelease: PiCatalogRelease? { availableReleases.first }
    var latestAvailableVersion: String? { latestAvailableRelease?.version }
    func eligible(_ release: PiCatalogRelease, laterThan version: String) -> Bool {
        guard let current = PiSemanticVersion.parse(version), let next = PiSemanticVersion.parse(release.version) else { return false }
        return next > current
    }
    var updateVersion: String? {
        guard let current = managed else { return nil }
        return availableReleases.filter { eligible($0, laterThan: current.release.version) && !manager.isRejected($0) }.first?.version
    }
    /// A discovered release this machine already rejected, if it is the newest one.
    var rejectedRelease: PiRejectedRelease? {
        guard let candidate = availableReleases.first(where: { managed == nil || eligible($0, laterThan: managed!.release.version) }) else { return nil }
        return manager.rejection(for: candidate)
    }
    var canRollback: Bool {
        guard managed != nil, let previous = state.managed.first(where: { $0.id == state.previous }), previous.health.usable,
              (try? previous.release.validate()) != nil else { return false }
        return manager.sessionRuntimeVersions().allSatisfy { $0 == previous.release.version }
    }
    var operationFailed: Bool { state.operation.map { [.failed, .interrupted].contains($0.stage) } ?? false }
    var canRetry: Bool {
        if !state.removals.isEmpty { return true }
        guard operationFailed, let operation = state.operation else { return false }
        let known = availableReleases.contains(where: { $0.version == operation.version }) || state.managed.contains(where: { $0.release.version == operation.version })
        switch operation.action {
        case "install", "autoUpdate": return known
        case "update", "repair": return managed != nil && known
        case "verify": return managed != nil
        case "verifyExternal": return external != nil
        default: return false
        }
    }
    var status: String {
        if manager.store.loadProblem != nil { return "Agent unavailable" }
        if state.pending != nil { return "Update staged · pending activation" }
        if let record = selectedRecord, !FileManager.default.isExecutableFile(atPath: record.executable.path) { return "Agent unavailable" }
        if let health, !health.usable {
            switch health.state {
            case .unsupported: return "Unsupported installation"
            case .untested: return "Compatibility verification required"
            case .incompatibleIntegration: return "Incompatible installation"
            default: return "Verification failed"
            }
        }
        if operationFailed { return "Verification or maintenance failed" }
        if updateVersion != nil { return "Update available" }
        if manager.releaseCheckProblem != nil { return "Managed by Milk · update check unavailable" }
        if managed != nil { return "Managed by Milk" }
        if external != nil { return "Existing installation" }
        return "Not installed"
    }
    var actions: [Action] {
        guard manager.store.loadProblem == nil else { return [] }
        var result: [Action] = []
        if managed != nil {
            if updateVersion != nil && state.pending == nil { result.append(.update) }
            result.append(.check)
            result.append(.verify)
            if let value = managed, (try? value.release.validate()) != nil { result.append(.repair) }
            if canRollback { result.append(.rollback) }
            result += [.remove, .useExisting]
        } else if external != nil { result = [.check, .verify, .useExisting, .forget] }
        else {
            if state.pending == nil { result.append(.install) }
            result.append(.check); result.append(.useExisting)
        }
        if state.pending != nil { result.append(.activate) }
        if canRetry { result.append(.retry) }
        return result
    }
    var runningDescription: String? {
        let running = manager.runningInstallations
        guard !running.isEmpty else { return nil }
        let versions = Set(running.compactMap(\.expectedVersion)).sorted().joined(separator: ", ")
        let previous = running.contains { $0.id != state.selected }
        return (versions.isEmpty ? "Pi is running" : "Pi \(versions)") + (previous ? " · previous installation still running" : "")
    }
    var needsVerification: Bool { selectedRecord != nil && health?.usable != true }
    /// Always refreshes the upstream release feed, even when Auto Update is off.
    func refreshReleases() async {
        guard !busy else { return }
        performing = true; defer { performing = false }
        await checkReleases()
    }
    /// Release read without the busy guard: perform(...) already holds the busy state,
    /// so a manual "Check for Updates" must not be blocked by its own flag.
    private func checkReleases() async {
        let releases = await manager.checkForUpdates()
        if let problem = manager.releaseCheckProblem { feedback = problem }
        else if managed != nil, let next = updateVersion { feedback = "Pi \(next) is available and eligible for this adapter. Enable Auto Update or choose Update." }
        else if let next = releases.first?.version { feedback = "Pi \(next) is available. Install it from this panel." }
        else { feedback = "No eligible upstream Pi release was found." }
    }
    func setAutoUpdate(_ enabled: Bool) async {
        guard !busy else { return }
        performing = true; defer { performing = false }
        do {
            try manager.setAutoUpdate(enabled)
            if enabled { try await manager.stageAutomaticUpdateIfEnabled(force: true) }
            feedback = "Auto Update " + (enabled ? "enabled. New stable Pi releases are discovered from the official upstream repository; active work is never interrupted." : "off. No Pi release will be installed automatically.")
        } catch { feedback = error.localizedDescription }
    }
    func checkAutomaticUpdate() async {
        guard !busy, state.autoUpdate, managed != nil else { return }
        performing = true; defer { performing = false }
        do { try await manager.stageAutomaticUpdateIfEnabled() } catch { feedback = error.localizedDescription }
    }
    func useExisting(_ executable: URL) async {
        guard !busy else { return }
        performing = true; defer { performing = false }
        do {
            let id = try await manager.registerExternal(executable)
            try await manager.select(id, stopRunning: true)
            feedback = "Existing Pi verified and selected. Milk does not own its executable."
        } catch { feedback = error.localizedDescription }
    }
    func selectRetained(_ id: AgentInstallationID) async {
        guard !busy else { return }
        performing = true; defer { performing = false }
        do { try await manager.select(id, stopRunning: true); feedback = "Retained Pi runtime selected. User data was preserved." }
        catch { feedback = error.localizedDescription }
    }
    func perform(_ action: Action) async {
        guard !busy, actions.contains(action) else { return }
        performing = true; defer { performing = false }
        do {
            switch action {
            case .install:
                try await manager.installLatest()
            case .check:
                await checkReleases()
            case .update:
                guard let value = managed, let version = updateVersion else { return }
                _ = try await manager.update(value.id, version: version)
            case .verify:
                if let value = managed { _ = try await manager.verify(value.id) }
                else if let value = external { try await manager.verifyExternal(value.installation.id) }
            case .repair:
                if let value = managed { try await manager.repair(value.id) }
            case .rollback: try await manager.rollback()
            case .remove: try await manager.removeManagedPi()
            case .forget:
                if let value = external { try await manager.forgetExternal(value.installation.id) }
            case .activate: try await manager.activatePending(stopRunning: true)
            case .retry:
                if !state.removals.isEmpty { try await manager.retryRemoval() }
                else if let operation = state.operation {
                    switch operation.action {
                    case "verify": if let value = managed { _ = try await manager.verify(value.id) }
                    case "verifyExternal": if let value = external { try await manager.verifyExternal(value.installation.id) }
                    case "repair": if let value = managed { try await manager.repair(value.id) }
                    case "update": if let value = managed, let version = operation.version { _ = try await manager.update(value.id, version: version) }
                    default: if let version = operation.version { try await manager.install(version: version) }
                    }
                }
            case .useExisting: return // NSOpenPanel is owned by the view, not the model.
            }
            // A release check already reported its own result; do not overwrite it with the generic completion text.
            if action != .check {
                feedback = state.pending == nil ? "Done. User data and session ownership are preserved." : "Update verified and staged. Running work is using its existing installation."
            }
        } catch { feedback = error.localizedDescription }
    }
}
