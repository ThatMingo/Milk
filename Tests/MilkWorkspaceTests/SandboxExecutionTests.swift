import XCTest
import Darwin
@testable import Milk

final class SandboxExecutionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Execution-" + UUID().uuidString)
        for path in ["project", "outside", "profile", "cache"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SandboxPathResolver().resolve(root).canonicalURL
    }
    private func run(_ arguments: [String], executable: URL = URL(fileURLWithPath: "/bin/sh"), root: URL, profile: String?, stopAfter: Double? = nil) async throws -> (String, Int32) {
        let command = SandboxProfileBuilder.command(executable: executable, arguments: arguments, profile: profile)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let child = try SandboxProcess(executable: command.0, arguments: command.1, directory: root.appendingPathComponent("project"), environment: ["PATH":"/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin","HOME":root.appendingPathComponent("cache").path,"TMPDIR":root.appendingPathComponent("cache").path], input: input, output: output, errors: errors)
        try input.fileHandleForWriting.close()
        let err = Task.detached { var data = Data(); while true { let next = child.read(errors.fileHandleForReading); if next.isEmpty { break }; data.append(next) }; return data }
        let out = Task.detached { var data = Data(); while true { let next = child.read(output.fileHandleForReading); if next.isEmpty { break }; data.append(next) }; child.waitUntilExit(); return data }
        if let stopAfter { try await Task.sleep(nanoseconds: UInt64(stopAfter * 1_000_000_000)); child.terminate() }
        let data = await out.value + err.value
        return (String(decoding: data, as: UTF8.self), child.terminationStatus)
    }
    private func context(_ root: URL, mode: ComposerPermissionMode = .approval) -> SandboxPolicyContext {
        var configuration = SandboxConfiguration(home: root); configuration.protectedLocations = []
        return .init(configuration: configuration, projectConfiguration: .init(), roots: .init(project: root.appendingPathComponent("project"), writableBuildRoots: [root.appendingPathComponent("cache")]), interaction: mode)
    }
    func testProductionProfileReadWriteReadOnlyOutsideAndMalformedFailClosed() async throws {
        let root = try fixture(); var c = context(root)
        let builder = SandboxProfileBuilder(), dependencies = SandboxProfileBuilder.systemReadRoots
        var profile = try builder.make(context: c, dependencies: dependencies)
        var result = try await run(["-c", "printf allowed > inside; cat inside"], root: root, profile: profile)
        XCTAssertEqual(result.1, 0, result.0); XCTAssertEqual(result.0, "allowed")
        result = try await run(["-c", "printf forbidden > \"$1\"", "sh", root.appendingPathComponent("outside/new").path], root: root, profile: profile)
        XCTAssertNotEqual(result.1, 0, result.0)
        c.projectConfiguration.access = .readOnly; profile = try builder.make(context: c, dependencies: dependencies)
        result = try await run(["-c", "printf forbidden > inside"], root: root, profile: profile)
        XCTAssertNotEqual(result.1, 0, result.0)
        result = try await run(["-c", "printf forbidden > malformed"], root: root, profile: "(invalid-sandbox-policy)")
        XCTAssertNotEqual(result.1, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/malformed").path))
        c.configuration.enabled = false
        XCTAssertNil(try builder.make(context: c, dependencies: dependencies))
    }
    func testOwnedOrdinaryAndTermResistantCleanupDoesNotKillUnrelatedWork() async throws {
        let root = try fixture(), unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["5"]; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let profile = try SandboxProfileBuilder().make(context: context(root), dependencies: SandboxProfileBuilder.systemReadRoots)
        for command in ["(sleep 2; echo leak > late) & wait", "trap '' TERM; (sleep 2; echo leak > late) & wait"] {
            let result = try await run(["-c", command], root: root, profile: profile, stopAfter: 0.2)
            XCTAssertLessThan(result.1, 0, result.0); XCTAssertTrue(unrelated.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/late").path))
        }
    }
    @MainActor private func execution(_ root: URL, mode: ComposerPermissionMode = .approval, timeout: Double = 30) async throws -> (PiSandboxExecution, SandboxGrantStore, SandboxSettingsStore) {
        let suite = "Milk.Execution." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        var configuration = SandboxConfiguration(home: root); configuration.protectedLocations = []; configuration.autonomousTimeoutSeconds = timeout
        defaults.set(try JSONEncoder().encode(configuration), forKey: SandboxSettingsStore.key)
        let settings = SandboxSettingsStore(defaults: defaults, home: root), grants = SandboxGrantStore()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let activation = AgentActivation(agentID: .pi, workspace: root.appendingPathComponent("project"), sessionID: 1)
        grants.register(activation)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("profile").path])
        let location = try await PiLaunchResolver(runtime: runtime).resolve(.bundled, lifecycle: nil)
        let executor = try PiSandboxExecution(location: location, settings: settings, grants: grants, activation: activation, mode: mode, purpose: .conversation, inactiveProfiles: [])
        addTeardownBlock { await executor.shutdownAndWait() }
        return (executor, grants, settings)
    }
    @MainActor private func execute(_ executor: PiSandboxExecution, tool: String, args: JSONValue) async throws -> JSONValue {
        let opened = try await executor.handle(.object(["kind":.string("begin"),"tool":.string(tool),"args":args]))
        let next: JSONValue = .object(["kind":.string("next"),"operation":opened["operation"],"capability":opened["capability"]])
        while true {
            let result = try await executor.handle(next)
            if let error = result["error"].string { executor.control(opened,cancel:false); throw AgentError.message(error) }
            if result["done"].bool { executor.control(opened,cancel:false); return result["result"] }
        }
    }
    @MainActor func testRealStockWorkerResultsAndSanitizedShellDescendants() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous)
        let written = try await execute(executor, tool: "write", args: .object(["path":.string("file.txt"),"content":.string("stock-worker")]))
        XCTAssertTrue(written["content"].text.contains("Successfully"), written.encodedString)
        let read = try await execute(executor, tool: "read", args: .object(["path":.string("file.txt")]))
        XCTAssertTrue(read["content"].text.contains("stock-worker"), read.encodedString)
        let result = try await execute(executor, tool: "bash", args: .object(["command":.string("test -z \"$MILK_PI_LOCAL_KEY\" && /usr/bin/python3 -c 'import os; assert not os.environ.get(\"MILK_PI_LOCAL_KEY\"); print(\"clean\")'")]))
        XCTAssertTrue(result["content"].text.contains("clean"), result.encodedString)
    }
    @MainActor func testRealOnceApprovalThenFutureOperationDeniedAndStaleCapabilityRejected() async throws {
        let root = try fixture(); let (executor, grants, _) = try await execution(root)
        let file = root.appendingPathComponent("outside/data"); try Data("once-real".utf8).write(to: file)
        var allow = true
        executor.event = { event in if case .approval(let request) = event { try? executor.respond(request, response: allow ? .value("Allow Once") : .cancelled) } }
        let args: JSONValue = .object(["path":.string(file.path)])
        let read = try await execute(executor, tool: "read", args: args)
        XCTAssertTrue(read["content"].text.contains("once-real"), read.encodedString); XCTAssertTrue(grants.grants.isEmpty)
        allow = false
        do { _ = try await execute(executor, tool: "read", args: args); XCTFail("Expired Once reused") } catch {}
        do { _ = try await executor.handle(.object(["kind":.string("next"),"operation":.string(UUID().uuidString),"capability":.string("forged")])); XCTFail("Stale capability accepted") } catch {}
    }
    @MainActor func testAutonomousTimeoutAndDuplicateSuppression() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous, timeout: 0.05)
        var prompts = 0
        executor.event = { if case .approval = $0 { prompts += 1 } }
        let args: JSONValue = .object(["path":.string(root.appendingPathComponent("outside/new").path),"content":.string("denied")])
        for _ in 0..<2 { do { _ = try await execute(executor, tool: "write", args: args); XCTFail("Timeout allowed") } catch { XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable"), error.localizedDescription) } }
        XCTAssertEqual(prompts,1)
    }
}
