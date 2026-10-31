import XCTest
import Darwin
@testable import Milk

final class PreviewTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Preview-Test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/Milk")
    }
    @MainActor private func track(_ service: DevServerService) {
        addTeardownBlock { _ = await service.shutdown() }
    }
    @MainActor private func wait(_ predicate: () -> Bool, timeout: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw AgentError.message("Preview test timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func testDetectionPrefersExistingScriptsAndPackageManager() throws {
        let root = try directory()
        try Data(#"{"scripts":{"start":"next start","dev":"next dev"},"packageManager":"pnpm@10.0.0"}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        let dev = try XCTUnwrap(PreviewDetector.detect(root: root))
        XCTAssertEqual(dev.command, "pnpm run 'dev'"); XCTAssertEqual(dev.directory, root)
        try Data(#"{"scripts":{"start":"react-scripts start"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertEqual(try PreviewDetector.detect(root: root)?.command, "npm run 'start'")
        try Data(#"{"scripts":{"preview-local":"astro dev"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertEqual(try PreviewDetector.detect(root: root)?.command, "npm run 'preview-local'")
        try Data(#"{"scripts":{"build":"vite build"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        // A build script alone isn't a reliable foreground server command.
        XCTAssertNil(try PreviewDetector.detect(root: root))
        try Data(#"{"scripts":{"format":"prettier ."}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("<h1>Static npm project</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        XCTAssertEqual(try PreviewDetector.detect(root: root)?.kind, .staticFiles)
    }
    func testLocalURLDetectionANSIIPv6AlternatePortsAndRejection() throws {
        let output = "port 5173 busy\n\u{001B}[32mLocal: http://localhost:5174/\u{001B}[0m\nhttp://127.0.0.1:3001\nhttp://[::1]:4000/\nhttp://0.0.0.0:8080/\nhttp://[::]:9000/"
        let urls = PreviewURL.detected(in: output)
        XCTAssertEqual(urls.map(\.port), [5174, 3001, 4000, 8080, 9000])
        XCTAssertEqual(urls[3].host, "127.0.0.1")
        XCTAssertTrue(PreviewURL.detected(in: "https://example.com:4000 http://localhost:123456 http://localhost:3000.evil.test http://localhost:0 ftp://localhost:3000").isEmpty)
        XCTAssertEqual(try PreviewURL.parse("localhost:3001/a", workspace: nil).port, 3001)
        for invalid in ["", "not a url", "javascript:alert(1)", "http://user:pass@localhost:3000", "http://localhost:99999"] { XCTAssertThrowsError(try PreviewURL.parse(invalid, workspace: nil)) }
    }
    func testStaticMappingRejectsTraversalHiddenFilesAndSymlinks() throws {
        let root = try directory(), outside = try directory()
        try Data("HTML".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.html"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertEqual(StaticPreviewServer.resource(for: "/?q=1", root: root)?.lastPathComponent, "index.html")
        for path in ["/%2e%2e/secret.html", "/.git/config", "/escape/secret.html", "/%00"] { XCTAssertNil(StaticPreviewServer.resource(for: path, root: root)) }
    }
    func testStaleCleanupOnlyRemovesMarkedDeadRunDirectories() throws {
        let base = try directory(), project = try directory()
        let stale = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        var marker = PreviewTemporaryFiles.Marker(); marker.pid = 2_000_000_000
        try JSONEncoder().encode(marker).write(to: stale.appendingPathComponent("milk-owner.json"))
        let unknown = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let link = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        for name in ["node_modules", ".next", ".vite", "dist", "build", "package.json", "package-lock.json", "source.html"] { try Data("keep".utf8).write(to: project.appendingPathComponent(name)) }
        let live = try PreviewTemporaryFiles(base: base)
        PreviewTemporaryFiles.cleanStale(in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: live.run.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).count, 8)
        live.cleanup(); XCTAssertFalse(FileManager.default.fileExists(atPath: live.run.path))
    }
    @MainActor func testOwnedProcessTreeGracefulThenForceAndTempCleanup() async throws {
        let root = try directory(), temp = try directory()
        let service = DevServerService(helperExecutable: executable, temporaryBase: temp)
        track(service)
        let code = "import signal,subprocess,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); child=subprocess.Popen(['/bin/sleep','90']); print('CHILD:'+str(child.pid),flush=True); time.sleep(90)"
        let child = try service.launch(.init(command: "/usr/bin/python3 -u -c " + PreviewDetector.shellQuote(code), directory: root), workspace: root)
        XCTAssertEqual(getpgid(child.pid), child.group)
        try await wait { child.stdout.contains("CHILD:") }
        let childPID = try XCTUnwrap(Int32(child.stdout.components(separatedBy: "CHILD:").last!.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getpgid(childPID), child.group)
        XCTAssertThrowsError(try service.launch(.init(command: "sleep 90", directory: root), workspace: root))
        let stopping = Date()
        let gone = await service.stop(child)
        XCTAssertGreaterThan(Date().timeIntervalSince(stopping), 0.8, "TERM-ignoring processes must exercise bounded SIGKILL escalation")
        XCTAssertTrue(gone); XCTAssertTrue(child.groupGone); XCTAssertTrue(service.servers.isEmpty)
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.temporaryDirectory.path))
        _ = await service.shutdown()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }
    @MainActor func testStaticServerRealHTTPResourcesAndShutdown() async throws {
        let root = try directory(), temp = try directory()
        try Data("<script type=module src='./app.js'></script><h1>Milk</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("document.body.dataset.ready='yes'".utf8).write(to: root.appendingPathComponent("app.js"))
        let service = DevServerService(helperExecutable: executable, temporaryBase: temp)
        track(service)
        let server = try service.launch(PreviewDetector.staticConfiguration(root: root, entry: root.appendingPathComponent("index.html")), workspace: root)
        try await wait { !PreviewURL.detected(in: server.stdout).isEmpty || server.exitStatus != nil }
        let url = try XCTUnwrap(PreviewURL.detected(in: server.stdout).first, server.stderr)
        let reachable = await PreviewURL.reachable(url); XCTAssertTrue(reachable)
        let (html, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200); XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("Milk"))
        let (js, jsResponse) = try await URLSession.shared.data(from: url.appendingPathComponent("app.js"))
        XCTAssertTrue(String(decoding: js, as: UTF8.self).contains("dataset")); XCTAssertEqual((jsResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/javascript")
        let stopped = await service.shutdown(); XCTAssertTrue(stopped)
        let reachableAfter = await PreviewURL.reachable(url); XCTAssertFalse(reachableAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
    }
    @MainActor func testUnexpectedLauncherExitCleansRemainingChildren() async throws {
        let root = try directory(), service = DevServerService(helperExecutable: executable, temporaryBase: try directory())
        track(service)
        var exited = false
        service.onExit = { _ in exited = true }
        let server = try service.launch(.init(command: "/bin/sleep 90 & echo CHILD:$!; exit 9", directory: root), workspace: root)
        try await wait { exited }
        XCTAssertEqual(server.state, .failed); XCTAssertTrue(server.groupGone); XCTAssertNotNil(server.exitStatus)
        _ = await service.shutdown()
    }
    @MainActor func testServiceReuseExternalNeverKilledAndWorkspaceLifecycle() async throws {
        let root = try directory(), other = try directory()
        try Data("<h1>Project</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory())
        track(processes)
        let preview = PreviewService(persist: false, devServers: processes)
        preview.authorize = { $0 }; preview.setWorkspace(root); preview.start()
        try await wait { preview.currentURL != nil || preview.state == .failed }
        XCTAssertNil(preview.error)
        let server = try XCTUnwrap(preview.server), url = try XCTUnwrap(preview.currentURL)
        preview.start(); try await wait { !preview.busy }
        XCTAssertTrue(preview.server === server); XCTAssertEqual(processes.servers.count, 1)
        preview.selectDevice(.phone)
        preview.ensureStarted() // Showing/hiding doesn't drive process lifecycle.
        XCTAssertEqual(preview.device, .phone); XCTAssertTrue(preview.server === server)
        // A different Preview instance displaying this URL never owns it and cannot terminate it.
        let external = PreviewService(persist: false, devServers: DevServerService(helperExecutable: executable, temporaryBase: try directory()))
        external.setWorkspace(other); external.address = url.absoluteString; external.navigate()
        XCTAssertFalse(external.managed); external.stop()
        _ = await external.shutdown()
        let reachable = await PreviewURL.reachable(url); XCTAssertTrue(reachable)
        preview.setWorkspace(other)
        try await wait { server.groupGone }
        XCTAssertTrue(processes.servers.isEmpty); XCTAssertNil(preview.currentURL)
        preview.setWorkspace(root); preview.start(); try await wait { preview.currentURL != nil || preview.state == .failed }
        let next = try XCTUnwrap(preview.server)
        preview.setWorkspace(nil); try await wait { next.groupGone }
        XCTAssertTrue(processes.servers.isEmpty)
        let stopped = await preview.shutdown(); XCTAssertTrue(stopped)
    }
    @MainActor func testPiConfigurationValidationRejectsOutsideDirectory() throws {
        let root = try directory()
        let config = try PreviewPiAssistant.parse(#"{"command":"npm run dev","directory":".","url":"http://localhost:3005"}"#, root: root)
        XCTAssertEqual(config.directory.path, root.path); XCTAssertEqual(config.suggestedURL?.port, 3005)
        XCTAssertThrowsError(try PreviewPiAssistant.parse(#"{"command":"npm start","directory":"/"}"#, root: root))
    }
    @MainActor func testApprovalDenyEditSessionAllowanceAndCancellation() async throws {
        let root = try directory()
        let workspace = WorkspaceStore(persistence: .init(enabled: false)); try workspace.openWorkspace(root)
        let agent = AgentService(workspace: workspace, defaults: .standard, enabled: false); agent.restore(nil)
        defer { agent.shutdown() }
        let config = PreviewConfiguration(command: "npm run dev", directory: root)
        let first = Task { try await agent.authorizePreview(config) }
        try await wait { agent.presentedApproval != nil }
        let denied = try XCTUnwrap(agent.presentedApproval)
        XCTAssertEqual(denied.request.command, config.command)
        agent.respond(denied.request, session: denied.session, cancelled: true)
        do { _ = try await first.value; XCTFail("Denied command should not proceed") } catch { }
        let second = Task { try await agent.authorizePreview(config) }
        try await wait { agent.presentedApproval != nil }
        let editing = try XCTUnwrap(agent.presentedApproval)
        agent.respond(editing.request, session: editing.session, value: "Edit Command")
        let editor = try XCTUnwrap(agent.presentedApproval)
        XCTAssertEqual(editor.request.method, .editor)
        agent.respond(editor.request, session: editor.session, value: "npm run serve")
        let edited = try await second.value; XCTAssertEqual(edited.command, "npm run serve")
        let third = Task { try await agent.authorizePreview(config) }
        try await wait { agent.presentedApproval != nil }
        let allowed = try XCTUnwrap(agent.presentedApproval)
        agent.respond(allowed.request, session: allowed.session, value: "Allow for Session")
        _ = try await third.value
        let reused = try await agent.authorizePreview(config); XCTAssertEqual(reused, config); XCTAssertNil(agent.presentedApproval)
        let other = Task { try await agent.authorizePreview(.init(command: "npm start", directory: root)) }
        try await wait { agent.presentedApproval != nil }
        other.cancel()
        do { _ = try await other.value; XCTFail("Cancelled approval should not proceed") } catch { }
        XCTAssertNil(agent.presentedApproval)
        agent.current.permission = .autonomous
        let automatic = try await agent.authorizePreview(.init(command: "npm start", directory: root)); XCTAssertEqual(automatic.command, "npm start")
    }
    @MainActor func testShellVisibilitySessionTakeoverAndCloseKeepWorkspaceOwnership() async throws {
        let root = try directory(), other = try directory()
        try Data("<h1>Milk</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(processes)
        let shell = ShellState(persist: false, previewServers: processes)
        defer { shell.agent.shutdown() }
        try shell.workspace.openWorkspace(root); shell.agent.current.permission = .autonomous
        shell.preview.start(); try await wait { shell.preview.currentURL != nil || shell.preview.state == .failed }
        XCTAssertNil(shell.preview.error)
        let server = try XCTUnwrap(shell.preview.server), url = shell.preview.currentURL
        shell.applyPreset(.preview)
        shell.change { $0.toggle(.preview) }
        shell.destination = "Git"; shell.takeover = "Settings"; shell.newSession(); shell.selectedSession = shell.sessions.first!.id
        XCTAssertTrue(shell.preview.server === server); XCTAssertEqual(shell.preview.currentURL, url)
        shell.takeover = nil; shell.change { $0.toggle(.preview) }; shell.preview.ensureStarted()
        XCTAssertTrue(shell.preview.server === server); XCTAssertEqual(processes.servers.count, 1)
        try shell.workspace.openWorkspace(other); try await wait { server.groupGone }
        XCTAssertNil(shell.preview.currentURL)
        try shell.workspace.openWorkspace(root); shell.agent.current.permission = .autonomous
        shell.preview.start(); try await wait { shell.preview.currentURL != nil || shell.preview.state == .failed }
        let next = try XCTUnwrap(shell.preview.server)
        try shell.workspace.closeWorkspace(); try await wait { next.groupGone }
        XCTAssertTrue(processes.servers.isEmpty)
        _ = await shell.preview.shutdown()
    }
    @MainActor func testNpmScriptActualStartupSelectsAlternatePortAndReloadPreservesProcess() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/npm") else { throw XCTSkip("npm isn't installed on this host") }
        let root = try directory()
        try Data("<h1>External</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let externalService = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(externalService)
        let external = try externalService.launch(PreviewDetector.staticConfiguration(root: root, entry: root.appendingPathComponent("index.html")), workspace: root)
        try await wait { !PreviewURL.detected(in: external.stdout).isEmpty }
        let occupied = try XCTUnwrap(PreviewURL.detected(in: external.stdout).first?.port)
        let js = """
        const http = require('http');
        const server = http.createServer((req,res) => { res.writeHead(200,{'Content-Type':'text/html'}); res.end('<h1>npm Preview</h1>'); });
        server.once('error', e => { if (e.code === 'EADDRINUSE') { console.log('Default port occupied; selecting another'); server.listen(0, '127.0.0.1'); } else process.exit(1); });
        server.on('listening', () => console.log('Local: http://127.0.0.1:' + server.address().port));
        server.listen(\(occupied), '127.0.0.1');
        """
        try Data(js.utf8).write(to: root.appendingPathComponent("server.cjs"))
        try Data(#"{"scripts":{"start":"node server.cjs"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(processes)
        let preview = PreviewService(persist: false, devServers: processes); preview.authorize = { $0 }; preview.setWorkspace(root)
        preview.start(); try await wait({ preview.currentURL != nil || preview.state == .failed }, timeout: 15)
        XCTAssertNil(preview.error)
        let owned = try XCTUnwrap(preview.server), url = try XCTUnwrap(preview.currentURL)
        XCTAssertNotEqual(url.port, occupied); XCTAssertEqual(owned.configuration.command, "npm run 'start'")
        XCTAssertEqual(preview.displayedOwnership, .managed)
        preview.reload(); XCTAssertTrue(preview.server === owned)
        preview.start(); try await wait { !preview.busy }; XCTAssertTrue(preview.server === owned)
        preview.stop(); try await wait { owned.groupGone && preview.server == nil }; XCTAssertNil(preview.server)
        let reachable = await PreviewURL.reachable(URL(string: "http://127.0.0.1:\(occupied)")!); XCTAssertTrue(reachable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path))
        try Data(#"{"scripts":{"dev":"node server.cjs"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        preview.start(); try await wait({ preview.state == .failed && preview.server == nil }, timeout: 15)
        XCTAssertTrue(processes.servers.isEmpty)
        preview.start(); try await wait({ preview.currentURL != nil && !preview.busy && preview.state != .failed }, timeout: 15)
        XCTAssertEqual(preview.server?.configuration.command, "npm run 'dev'", "A failed cached command must be detected again on explicit retry")
        _ = await preview.shutdown()
    }
    @MainActor func testPendingStartStopAndWorkspaceCloseCannotLaunchAfterApproval() async throws {
        let root = try directory()
        try Data("<h1>Milk</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(processes)
        let shell = ShellState(persist: false, previewServers: processes)
        defer { shell.agent.shutdown() }
        try shell.workspace.openWorkspace(root)
        shell.preview.start(); try await wait { shell.agent.presentedApproval != nil }
        let request = try XCTUnwrap(shell.agent.presentedApproval)
        shell.preview.start()
        XCTAssertEqual(shell.agent.approvals[request.session]?.count, 1)
        shell.agent.respond(request.request, session: request.session, value: "Allow Once")
        shell.preview.stop() // Cancel before the allowed continuation can resume and spawn.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(processes.servers.isEmpty); XCTAssertNil(shell.agent.presentedApproval)
        shell.preview.start(); try await wait { shell.agent.presentedApproval != nil }
        try shell.workspace.closeWorkspace()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(processes.servers.isEmpty); XCTAssertNil(shell.agent.presentedApproval); XCTAssertEqual(shell.preview.state, .idle)
        _ = await shell.preview.shutdown()
    }
    @MainActor func testEnteredURLAndDevicePersistAndReuseWithoutClaimingExternalOwnership() async throws {
        let root = try directory()
        try Data("<h1>External</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let externalService = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(externalService)
        let external = try externalService.launch(PreviewDetector.staticConfiguration(root: root, entry: root.appendingPathComponent("index.html")), workspace: root)
        try await wait { !PreviewURL.detected(in: external.stdout).isEmpty }
        let url = try XCTUnwrap(PreviewURL.detected(in: external.stdout).first)
        let suite = "MilkPreviewPersistence." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(processes)
        let first = PreviewService(defaults: defaults, devServers: processes)
        first.setWorkspace(root); first.address = url.absoluteString; first.navigate()
        first.renderer.onFinished?(url); first.selectDevice(.tablet)
        _ = await first.shutdown()
        let nextProcesses = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(nextProcesses)
        let restored = PreviewService(defaults: defaults, devServers: nextProcesses)
        restored.authorize = { _ in XCTFail("A remembered external URL must not spawn a server"); throw CancellationError() }
        restored.setWorkspace(root); restored.start(); try await wait { !restored.busy }
        XCTAssertEqual(restored.currentURL, url); XCTAssertEqual(restored.device, .tablet)
        XCTAssertEqual(restored.displayedOwnership, .external); XCTAssertNil(restored.server); XCTAssertTrue(nextProcesses.servers.isEmpty)
        restored.stop(); _ = await restored.shutdown()
        // A helper left from another Milk instance/run is reused as external, never adopted.
        let memory = PreviewMemory(url: url, device: .phone, configuration: PreviewDetector.staticConfiguration(root: root, entry: root.appendingPathComponent("index.html")), usesEnteredURL: false)
        defaults.set(try JSONEncoder().encode([root.path: memory]), forKey: "Milk.preview.v1")
        let recoveredProcesses = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(recoveredProcesses)
        let recovered = PreviewService(defaults: defaults, devServers: recoveredProcesses)
        recovered.authorize = { _ in XCTFail("A reachable remembered helper must be reused without spawning"); throw CancellationError() }
        recovered.setWorkspace(root); recovered.start(); try await wait { !recovered.busy }
        XCTAssertEqual(recovered.currentURL, url); XCTAssertEqual(recovered.displayedOwnership, .external); XCTAssertNil(recovered.server)
        _ = await recovered.shutdown()
        let alive = await PreviewURL.reachable(url); XCTAssertTrue(alive)
    }
    @MainActor func testUnexpectedManagedExitUpdatesPreviewWithoutRestartLoop() async throws {
        let root = try directory()
        try Data("<h1>Project</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        let processes = DevServerService(helperExecutable: executable, temporaryBase: try directory()); track(processes)
        let preview = PreviewService(persist: false, devServers: processes); preview.authorize = { $0 }; preview.setWorkspace(root)
        preview.start(); try await wait { preview.currentURL != nil || preview.state == .failed }
        let owned = try XCTUnwrap(preview.server)
        kill(owned.pid, SIGTERM) // Simulate an unexpected exit of this test's known owned launcher.
        try await wait { preview.state == .failed && owned.groupGone }
        XCTAssertNotNil(preview.error)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(processes.servers.isEmpty); XCTAssertNil(preview.server)
        _ = await preview.shutdown()
    }
}
