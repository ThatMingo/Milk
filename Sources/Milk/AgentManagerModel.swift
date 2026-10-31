import Foundation
import Combine

/// UI policy and action routing; installation ownership stays in the Phase 5 backend.
@MainActor final class AgentManagerModel: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case install, useExisting, update, verify, repair, rollback, remove, forget, activate, retry
        var id: String { rawValue }
        var title: String {
            switch self {
            case .install: return "Install"
            case .useExisting: return "Use Existing Installation…"
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
    var latestApprovedVersion: String? {
        manager.catalog.releases.filter { (try? manager.catalog.approved($0.version)) != nil }
            .map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
    }
    var updateVersion: String? {
        guard let current = managed, let next = latestApprovedVersion,
              next.compare(current.release.version, options: .numeric) == .orderedDescending else { return nil }
        return next
    }
    var canRollback: Bool {
        guard managed != nil, let previous = state.managed.first(where: { $0.id == state.previous }), previous.health.usable,
              (try? manager.catalog.approved(previous.release.version)) != nil else { return false }
        return manager.sessionRuntimeVersions().allSatisfy { $0 == previous.release.version }
    }
    var operationFailed: Bool { state.operation.map { [.failed, .interrupted].contains($0.stage) } ?? false }
    var canRetry: Bool {
        if !state.removals.isEmpty { return true }
        guard operationFailed, let operation = state.operation else { return false }
        switch operation.action {
        case "install", "autoUpdate": return operation.version.flatMap { try? manager.catalog.approved($0) } != nil
        case "update", "repair": return managed != nil && operation.version.flatMap { try? manager.catalog.approved($0) } != nil
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
        if managed != nil { return "Managed by Milk" }
        if external != nil { return "Existing installation" }
        return "Not installed"
    }
    var actions: [Action] {
        guard manager.store.loadProblem == nil else { return [] }
        var result: [Action] = []
        if managed != nil {
            if updateVersion != nil && state.pending == nil { result.append(.update) }
            result.append(.verify)
            if let value = managed, (try? manager.catalog.approved(value.release.version)) != nil { result.append(.repair) }
            if canRollback { result.append(.rollback) }
            result += [.remove, .useExisting]
        } else if external != nil { result = [.verify, .useExisting, .forget] }
        else {
            if latestApprovedVersion != nil && state.pending == nil { result.append(.install) }
            result.append(.useExisting)
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
    func setAutoUpdate(_ enabled: Bool) async {
        guard !busy else { return }
        performing = true; defer { performing = false }
        do {
            try manager.setAutoUpdate(enabled)
            if enabled { try await manager.stageAutomaticUpdateIfEnabled() }
            feedback = "Auto Update " + (enabled ? "enabled. Active work will not be interrupted." : "off.")
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
                guard let version = latestApprovedVersion else { throw AgentError.message("No approved Pi artifact for this Mac.") }
                try await manager.install(version: version)
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
            feedback = state.pending == nil ? "Done. User data and session ownership are preserved." : "Update verified and staged. Running work is using its existing installation."
        } catch { feedback = error.localizedDescription }
    }
}
