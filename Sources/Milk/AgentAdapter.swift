import Foundation

struct AgentID: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// Only functionality implemented by Milk belongs here. Model-specific availability
/// (images and reasoning choices) continues to come from the live model catalog.
enum AgentCapability: String, Hashable {
    case streaming, thinking, tools, permissions, dialogs, sessions, sessionResume
    case models, reasoningLevels, slashCommands, steering, followUpQueue
    case textAttachments, imageAttachments, fileChanges, nativeExtensionTools
    case compactionNotifications, retryNotifications, previewInspection
}
struct AgentDescriptor: Equatable {
    let id: AgentID
    let name: String
    let adapterVersion: String
    let capabilities: Set<AgentCapability>
}
enum AgentBackendPurpose { case conversation, previewInspection, versionProbe, packageCommand, compatibilityProbe, installationTransaction }
struct AgentBackendContext {
    var permission: ComposerPermissionMode
    var purpose: AgentBackendPurpose = .conversation
    var lifecycle: AgentLifecycleCoordinator? = nil
}

/// Optional facet for today's file-backed history. SDK/server adapters need not
/// implement it; generic session metadata and indexing remain later work.
protocol AgentFileSessionHistory: Sendable {
    func history(workspace: URL, directory: URL) throws -> [SavedAgentSession]
    func validateDeletion(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws
    func delete(_ saved: SavedAgentSession, workspace: URL, directory: URL) throws
}

@MainActor protocol AgentAdapter {
    var descriptor: AgentDescriptor { get }
    /// Metadata-only selection state for presentation; must not launch or probe code.
    var hasSelectedInstallation: Bool { get }
    var fileSessionHistory: (any AgentFileSessionHistory)? { get }
    func sessionAvailability(_ session: AgentSession, workspace: SessionWorkspace) -> SessionAvailability
    func sessionDeletionUnavailableReason(_ saved: SavedAgentSession) -> String?
    func makeBackend(context: AgentBackendContext) -> any AgentBackend
    func discoverPreview(root: URL, model: AgentModel?, lifecycle: AgentLifecycleCoordinator) async throws -> PreviewConfiguration
}
extension AgentAdapter {
    var hasSelectedInstallation: Bool { true }
    func sessionDeletionUnavailableReason(_ saved: SavedAgentSession) -> String? { nil }
    func sessionAvailability(_ session: AgentSession, workspace: SessionWorkspace) -> SessionAvailability { .init() }
    var fileSessionHistory: (any AgentFileSessionHistory)? { nil }
    func discoverPreview(root: URL, model: AgentModel?, lifecycle: AgentLifecycleCoordinator) async throws -> PreviewConfiguration {
        throw AgentError.message("This agent does not support Preview inspection.")
    }
}

/// Internal compiled registrations only; this is not a downloadable adapter API.
@MainActor struct AgentRegistry {
    let adapters: [any AgentAdapter]
    let defaultAgentID: AgentID
    init(adapters: [any AgentAdapter], defaultAgentID: AgentID) {
        precondition(Set(adapters.map { $0.descriptor.id }).count == adapters.count)
        precondition(adapters.contains { $0.descriptor.id == defaultAgentID })
        self.adapters = adapters; self.defaultAgentID = defaultAgentID
    }
    func adapter(for id: AgentID) -> (any AgentAdapter)? { adapters.first { $0.descriptor.id == id } }
    var defaultAdapter: any AgentAdapter { adapter(for: defaultAgentID)! }
}

/// Existing deterministic test factories still pass through the adapter seam.
@MainActor struct BackendOverrideAdapter: AgentAdapter {
    let base: any AgentAdapter
    let factory: @MainActor () -> any AgentBackend
    var descriptor: AgentDescriptor { base.descriptor }
    var hasSelectedInstallation: Bool { base.hasSelectedInstallation }
    var fileSessionHistory: (any AgentFileSessionHistory)? { base.fileSessionHistory }
    func sessionDeletionUnavailableReason(_ saved: SavedAgentSession) -> String? { base.sessionDeletionUnavailableReason(saved) }
    // Test overrides intentionally bypass real executable/format inspection.
    func sessionAvailability(_ session: AgentSession, workspace: SessionWorkspace) -> SessionAvailability { .init() }
    func makeBackend(context: AgentBackendContext) -> any AgentBackend { factory() }
    func discoverPreview(root: URL, model: AgentModel?, lifecycle: AgentLifecycleCoordinator) async throws -> PreviewConfiguration {
        try await base.discoverPreview(root: root, model: model, lifecycle: lifecycle)
    }
}

/// In-memory activation identity; session persistence and hot switching are later work.
struct AgentActivation: Equatable {
    let agentID: AgentID
    let workspace: URL
    let sessionID: Int
    let token = UUID()
}

enum AgentSubmissionIntent: Equatable { case prompt, followUp }
enum AgentDialogMethod: String { case select, confirm, input, editor }
enum AgentDialogOrigin: Equatable {
    case agentExtension, agentPermission, milkPreview, milkExtension
}
enum AgentDialogResponse: Equatable { case value(String), confirmed(Bool), cancelled }

/// Connection is independent of code location, credentials and shared data.
enum AgentConnectionPhase: String { case stopped, starting, ready, failed }
struct AgentRuntimeIdentity: Equatable {
    let executable: URL
    let version: String?
    let ownership: Ownership
    enum Ownership { case applicationBundle, external, milkManaged }
    var installation: AgentInstallationRecord? = nil
}
