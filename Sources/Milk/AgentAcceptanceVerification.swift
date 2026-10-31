import AppKit

/// Phase 7 mechanical acceptance, isolated from ordinary Milk/Pi preferences and data.
@MainActor enum AgentAcceptanceVerification {
    static func run() async -> Int32 {
        var failures = 0
        func check(_ valid: Bool, _ label: String) { print("\(valid ? "PASS" : "FAIL") \(label)"); if !valid { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Final-Acceptance-" + UUID().uuidString)
        let suite = "Milk.FinalAcceptance." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let state = ShellState(persist: false, preferences: defaults)
            try state.workspace.openWorkspace(root)
            try Data("acceptance editor".utf8).write(to: root.appendingPathComponent("note.txt"))
            try state.workspace.openFile(root.appendingPathComponent("note.txt"), pinned: true)
            for _ in 0..<20 { await Task.yield() }
            check(state.agent.lifecycle.owned.isEmpty, "Fresh app workspace/editor restore starts no Pi runtime")
            check(state.agent.unavailableReason != nil, "No-agent action has install/unavailable state")
            check(state.agent.sessionsForBrowsing(.allProjects).count >= 1, "Retained metadata is visible without Pi")
            check(state.agentInstallations.store.state.managed.isEmpty, "No silent installation")
            let identity = state.agent.currentSession?.metadata.id
            state.agent.current.draft = "retained acceptance draft"
            state.settingsSelection = "Agents"; state.takeover = "Settings"
            state.extensions.refresh(workspace: root)
            check(AgentManagerModel(manager: state.agentInstallations).status == "Not installed", "Agents settings and Extensions available without Pi")
            let resources = Bundle.main.resourceURL!
            let runtime = PiRuntimeService(resources: resources, environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("pi-data").path], allowBundledFixture: false)
            let owner = AgentLifecycleCoordinator()
            if let i = CommandLine.arguments.firstIndex(of: "--acceptance-external"), CommandLine.arguments.count > i + 1 {
                let executable = URL(fileURLWithPath: CommandLine.arguments[i+1])
                let before = try PiInstallationFiles.digest(executable)
                let record = PiLaunchResolver(runtime: runtime).installation(for: .external(executable))
                let report = try await PiCompatibilityProbe.inspect(installation: record, runtime: runtime, lifecycle: owner)
                check(report.usable, "Actual external Pi isolated native handshake")
                let backend = PiBackend(runtime: runtime, resolveLaunch: { _, coordinator in try await PiLaunchResolver(runtime: runtime).resolve(record, lifecycle: coordinator) })
                try await backend.start(workspace: root, session: .init(id: 1, title: "External acceptance"))
                try await backend.shutdownAndWait()
                check(try PiInstallationFiles.digest(executable) == before && owner.owned.isEmpty, "External executable unchanged; owned probe/backend shutdown")
            }
            let manager = PiInstallationManager(store: .init(root: root.appendingPathComponent("managed/pi")), lifecycle: owner, runtime: runtime)
            try manager.migrateLegacySelection(.bundled)
            do {
                let id = try await manager.install()
                check(manager.store.state.selected == id, "Official managed download/hash/extraction/native probe/activation")
                _ = try await manager.verify(id)
                let launch = try XCTlessRecord(manager)
                let backend = PiBackend(runtime: runtime, resolveLaunch: { _, coordinator in try await manager.resolve(legacy: .bundled, owner: coordinator) })
                try await backend.start(workspace: root, session: .init(id: 2, title: "Managed acceptance"))
                try await backend.shutdownAndWait()
                _ = try await manager.repair(id)
                try await manager.removeManagedPi()
                check(manager.store.state.selected == nil && state.agent.currentSession?.metadata.id == identity && state.agent.current.draft == "retained acceptance draft", "Managed removal retains Milk identity/draft; no fallback")
                _ = try await manager.install()
                check(state.agent.currentSession?.metadata.id == identity, "Real reinstall preserves session identity")
                try await manager.removeManagedPi()
            } catch { print("BLOCKED real managed installation/lifecycle: \(error.localizedDescription)"); failures += 1 }
            check(await owner.shutdownAndWait(), "Acceptance runtime owner drained")
            check(await state.agent.shutdownAndWait(), "No-agent app owner drained")
            _ = await state.preview.shutdown(); try state.workspace.closeWorkspace()
        } catch { print("FAIL acceptance: \(error.localizedDescription)"); failures += 1 }
        return failures == 0 ? 0 : 1
    }
    private static func XCTlessRecord(_ manager: PiInstallationManager) throws -> AgentInstallationRecord {
        guard let record = try manager.selectedInstallation() else { throw AgentError.message("No selected managed runtime") }; return record
    }
}
