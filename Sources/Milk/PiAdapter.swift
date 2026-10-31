import Foundation
import MilkExtensionHost

extension AgentID { static let pi = AgentID(rawValue: "pi") }

/// Pi keeps its native RPC, provider configuration, runtime and integration bridge.
/// Configuration is bound here, rather than required by every future backend.
@MainActor struct PiAdapter: AgentAdapter {
    static let descriptor = AgentDescriptor(id: .pi, name: "Pi", adapterVersion: PiCompatibilityPolicy.adapterVersion, capabilities: [
        .streaming, .thinking, .tools, .permissions, .dialogs, .sessions, .sessionResume,
        .models, .reasoningLevels, .slashCommands, .steering, .followUpQueue,
        .textAttachments, .imageAttachments, .fileChanges, .nativeExtensionTools,
        .compactionNotifications, .retryNotifications, .previewInspection
    ])
    var descriptor: AgentDescriptor { Self.descriptor }
    var settingsProvider: (any AgentSettingsProviding)? { self }
    var hasSelectedInstallation: Bool {
        if let installations { return installations.store.state.selected != nil }
        return !configuration().runtime.isBundled || runtime.allowsBundledFixture
    }
    var fileSessionHistory: (any AgentFileSessionHistory)? { PiSessionService() }
    let defaults: UserDefaults
    let providerConfiguration: @MainActor () throws -> PiProviderConfiguration
    let runtime: PiRuntimeService
    let nativeExtensions: NativeExtensionManager?
    let installations: PiInstallationManager?
    let configuration: @MainActor () -> AgentConfiguration
    init(runtime: PiRuntimeService = PiRuntimeService(), nativeExtensions: NativeExtensionManager? = nil, installations: PiInstallationManager? = nil,
         configuration: @escaping @MainActor () -> AgentConfiguration = { .load(.standard) },
         defaults: UserDefaults = .standard, providerConfiguration: (@MainActor () throws -> PiProviderConfiguration)? = nil) {
        self.defaults = defaults
        self.providerConfiguration = providerConfiguration ?? { try PiProviderConfiguration.load(defaults, key: installations?.providerSettingsKey ?? PiProfileIdentitySupport.identity(runtime: runtime, installations: nil, mode: configuration().runtime).settingsKey) }
        self.runtime = runtime; self.nativeExtensions = nativeExtensions; self.configuration = configuration
        self.installations = installations
    }
    func sessionDeletionUnavailableReason(_ saved: SavedAgentSession) -> String? {
        if let installations, !installations.store.state.useLegacyRuntime {
            guard let record = try? installations.selectedInstallation(verifyIntegrity: false) else { return "Select a Pi runtime before deleting native history." }
            return record.ownership == .external ? "Deletion is unverified for external Pi." : nil
        }
        return configuration().runtime.isBundled ? nil : "Deletion is unverified for external Pi."
    }
    func sessionAvailability(_ session: AgentSession, workspace: SessionWorkspace) -> SessionAvailability {
        let data = PiSessionService().availability(session, workspace: workspace.url)
        guard data.canAttemptResume else { return data }
        let installation: AgentInstallationRecord
        do { installation = try installations?.selectedInstallation(verifyIntegrity: false) ?? PiLaunchResolver(runtime: runtime).installation(for: configuration().runtime) }
        catch let error as AgentCompatibilityError {
            return .init(state: error.result.state == .invalidRuntime ? .runtimeUnavailable : .incompatibleRuntime, detail: error.localizedDescription)
        }
        catch { return .init(state: .runtimeUnavailable, detail: error.localizedDescription) }
        if installation.ownership == .applicationBundle && !runtime.allowsBundledFixture {
            return .init(state: .runtimeUnavailable, detail: "Pi is not installed. Open Settings → Agents to install Pi or use an existing installation.")
        }
        guard FileManager.default.isExecutableFile(atPath: installation.executable.path) else {
            return .init(state: .runtimeUnavailable, detail: "Pi's selected runtime is unavailable; retained history is still available.")
        }
        guard FileManager.default.fileExists(atPath: runtime.resources.appendingPathComponent("MilkPiIntegration.ts").path) else {
            return .init(state: .incompatibleRuntime, detail: "Milk's Pi integration is unavailable.")
        }
        return .init() // Version/credentials are not inferred from a cached session or --version.
    }
    func makeBackend(context: AgentBackendContext) -> any AgentBackend {
        var config = configuration(); config.defaultPermission = context.permission
        return PiBackend(runtime: runtime, discoveryOnly: context.purpose == .previewInspection,
                         nativeExtensions: nativeExtensions, configuration: config, providerConfigurationLoader: providerConfiguration, providerProfileIdentityLoader: { try PiProfileIdentitySupport.identity(runtime: runtime, installations: installations, mode: configuration().runtime).rawValue }, lifecycle: context.lifecycle,
                         resolveLaunch: { mode, owner in
                            if let installations { return try await installations.resolve(legacy: mode, owner: owner) }
                            return try await PiLaunchResolver(runtime: runtime).resolve(mode, lifecycle: owner)
                         })
    }
    func discoverPreview(root: URL, model: AgentModel?, lifecycle: AgentLifecycleCoordinator) async throws -> PreviewConfiguration {
        let context = AgentBackendContext(permission: configuration().defaultPermission, purpose: .previewInspection, lifecycle: lifecycle)
        var result: PreviewConfiguration?
        let lease = lifecycle.beginBackend(activation: .init(agentID: descriptor.id, workspace: root, sessionID: -1),
                                    purpose: .previewInspection, factory: { self.makeBackend(context: context) }) { backend, lease in
            result = try await PreviewPiAssistant.discover(root: root, model: model, backend: backend)
            try lease.check()
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await lease.work.value
                try Task.checkCancellation()
                try await lifecycle.stopAndWait(lease)
                return result!
            } catch {
                // Await cleanup even when the caller or workspace cancelled inspection.
                try await lifecycle.stopAndWait(lease)
                throw error
            }
        }, onCancel: { Task { @MainActor in lifecycle.stop(lease) } })
    }
}

extension AgentRegistry {
    static func standard(defaults: UserDefaults = .standard, nativeExtensions: NativeExtensionManager? = nil, installations: PiInstallationManager? = nil) -> Self {
        .init(adapters: [PiAdapter(nativeExtensions: nativeExtensions, installations: installations, configuration: { .load(defaults) }, defaults: defaults)], defaultAgentID: .pi)
    }
}

/// RPC command decoding is deliberately confined to Pi integration code.
enum PiCommandDecoder {
    static func decode(_ value: JSONValue) -> AgentCommand? {
        guard let name = value["name"].string, SlashCommandCatalog.validName(name),
              let rawSource = value["source"].string, let source = AgentCommand.Source(rawValue: rawSource) else { return nil }
        let info = value["sourceInfo"]
        return .init(name: name, description: value["description"].string, source: source,
                     sourceInfo: .init(path: info["path"].string, source: info["source"].string,
                                       scope: info["scope"].string, origin: info["origin"].string, baseDir: info["baseDir"].string))
    }
}
