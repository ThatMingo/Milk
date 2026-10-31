import Foundation

/// Candidate RPC inspection only: no prompt, user extensions, user cwd or saved session.
@MainActor final class PiCompatibilityProbe: AgentOwnedResource {
    private let client = PiRPCClient()
    private var temporary: URL?
    private var integrationReady = false

    private func run(installation: AgentInstallationRecord, runtime: PiRuntimeService, owner: AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult {
        var version: String?
        do {
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Pi-Compatibility-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            temporary = directory
            var overrides = runtime.environmentOverrides
            overrides["PI_CODING_AGENT_DIR"] = directory.appendingPathComponent("agent").path
            let isolated = PiRuntimeService(resources: runtime.resources, environmentOverrides: overrides, allowBundledFixture: runtime.allowsBundledFixture)
            let launch = try await PiLaunchResolver(runtime: isolated).resolve(installation, lifecycle: owner, probeDirectory: directory)
            version = launch.version
            try Task.checkCancellation()
            var environment = launch.environment
            environment["MILK_PERMISSION_MODE"] = "approval"
            environment["MILK_PREVIEW_DISCOVERY"] = "1"
            for key in ["MILK_NATIVE_CATALOG", "MILK_PI_LOCAL_KEY"] { environment.removeValue(forKey: key) }
            client.onRecord = { [weak self] record in
                if record["type"].string == "extension_ui_request", record["method"].string == "setStatus",
                   record["statusKey"].string == "milk-integration-ready" { self?.integrationReady = record["statusText"].string == "1" }
                // Fail closed on any interactive request; candidate inspection is noninteractive.
                if record["type"].string == "extension_ui_request", ["select", "confirm", "input", "editor"].contains(record["method"].string ?? ""), let id = record["id"].string {
                    try? self?.client.write(["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)])
                }
            }
            try client.launch(executable: launch.executable, arguments: ["--mode", "rpc", "--offline", "-e", launch.integration.path,
                "--no-session", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--tools", "read,grep,find,ls"],
                workspace: directory, environment: environment)
            for command in ["get_state", "get_commands", "get_available_models", "get_available_thinking_levels", "get_messages"] {
                let reply = try await client.request(command, timeout: 5)
                try Task.checkCancellation()
                try PiCompatibilityPolicy.validate(command, reply: reply, version: version)
            }
            guard integrationReady else { throw PiCompatibilityPolicy.incompatible(version: version, "Pi did not load Milk's integration extension. This Pi version may be incompatible.") }
            return PiCompatibilityPolicy.verified(version: launch.version)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? AgentCompatibilityError { return error.result }
            return PiCompatibilityPolicy.result(.incompatibleIntegration, version: version, detail: error.localizedDescription)
        }
    }
    func shutdown() { client.onRecord = nil; client.shutdown() }
    func shutdownAndWait() async throws {
        shutdown(); try await client.shutdownAndWait()
        if let temporary { try FileManager.default.removeItem(at: temporary); self.temporary = nil }
    }
    static func inspect(mode: PiRuntimeMode, runtime: PiRuntimeService, lifecycle: AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult {
        try await inspect(installation: PiLaunchResolver(runtime: runtime).installation(for: mode), runtime: runtime, lifecycle: lifecycle)
    }
    static func inspect(installation: AgentInstallationRecord, runtime: PiRuntimeService, lifecycle: AgentLifecycleCoordinator) async throws -> AgentCompatibilityResult {
        var result: AgentCompatibilityResult?
        let lease = lifecycle.begin(activation: .init(agentID: .pi, workspace: runtime.resources, sessionID: -1), purpose: .compatibilityProbe,
                                    factory: { PiCompatibilityProbe() }) { resource, lease in
            result = try await (resource as! PiCompatibilityProbe).run(installation: installation, runtime: runtime, owner: lifecycle)
            try lease.check()
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await lease.work.value; try Task.checkCancellation()
                try await lifecycle.stopAndWait(lease)
                return result!
            } catch {
                try await lifecycle.stopAndWait(lease)
                throw error
            }
        }, onCancel: { Task { @MainActor in lifecycle.stop(lease) } })
    }
}
