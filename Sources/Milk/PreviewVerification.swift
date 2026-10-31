import AppKit
import WebKit

/// Explicit verification mode using disposable project files and the real embedded WKWebView.
@MainActor enum PreviewVerification {
    /// Leaves a live server for the real application delegate to stop on Quit/window close.
    static func runQuitProbe(state: ShellState, window: NSWindow) async {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-phase5")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Preview-Quit-" + UUID().uuidString).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("<h1>Quit cleanup fixture</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
            try state.workspace.openWorkspace(root)
            state.agent.current.permission = .autonomous
            state.applyPreset(.preview); state.preview.start()
            let deadline = Date().addingTimeInterval(12)
            while state.preview.state != .running {
                guard Date() < deadline, state.preview.state != .failed else { throw AgentError.message(state.preview.error ?? "Quit probe startup timed out") }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            guard let server = state.preview.server else { throw AgentError.message("Quit probe has no owned server") }
            let metadata = ["pid": String(server.pid), "group": String(server.group), "temporary": server.temporaryDirectory.path, "project": root.path]
            try JSONEncoder().encode(metadata).write(to: output.appendingPathComponent("quit-probe.json"), options: .atomic)
            DispatchQueue.main.async {
                if CommandLine.arguments.contains("--verify-preview-window-close") { window.perform(#selector(NSWindow.performClose(_:)), with: nil, afterDelay: 0.05) }
                else { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05) }
            }
        } catch {
            FileHandle.standardError.write(Data("Quit probe failed: \(error.localizedDescription)\n".utf8))
            _ = await state.preview.shutdown()
            try? FileManager.default.removeItem(at: root)
            DispatchQueue.main.async { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05) }
        }
    }
    static func run(state: ShellState, window: NSWindow) async {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-phase5")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Preview-UI-" + UUID().uuidString).resolvingSymlinksInPath()
        var results: [String] = []
        func check(_ condition: Bool, _ label: String) { results.append("\(condition ? "PASS" : "FAIL") \(label)") }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() {
                guard Date() < deadline else { throw AgentError.message("Timed out: " + label + " · " + (state.preview.error ?? "")) }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            check(true, label)
        }
        func settle() async { try? await Task.sleep(nanoseconds: 400_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func capture(_ name: String) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("""
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="./style.css"><script type="module" src="./app.js"></script></head>
            <body><header><strong>Fieldnotes</strong><span>PROJECT PREVIEW</span></header><main><p class="eyebrow">A SMALL PLACE FOR BIG IDEAS</p><h1>Make room<br>for a new thought.</h1><p class="intro">An independent journal about making things, paying attention, and the work in between.</p><section><article><b>01</b><h2>Observe</h2><p>Start with what is already here.</p></article><article><b>02</b><h2>Experiment</h2><p>Follow an idea somewhere new.</p></article><article><b>03</b><h2>Make</h2><p>Bring the useful parts together.</p></article></section><footer>Rendered by Milk Preview <span id="ready">Loading…</span></footer></main></body></html>
            """.utf8).write(to: root.appendingPathComponent("index.html"))
            try Data("""
            *{box-sizing:border-box}body{margin:0;background:#f7f6ef;color:#2d3b30;font:14px -apple-system,sans-serif}header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #d5d9cb;padding:22px 28px}header strong{font:25px Georgia}header span,.eyebrow{font-size:9px;letter-spacing:1.8px}main{padding:45px 28px 24px}.eyebrow{color:#6d7a5c}h1{font:52px/1.08 Georgia;margin:18px 0}.intro{max-width:390px;line-height:1.7;color:#737c6b}section{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-top:35px}article{border:1px solid #d5d9cb;border-radius:9px;padding:18px 12px;background:#eef0e3}article b{font-size:10px;color:#7e8b6e}h2{font:22px Georgia}article p{font-size:12px;line-height:1.6}footer{margin-top:34px;font-size:10px;color:#818a78;display:flex;justify-content:space-between}@media(max-width:500px){h1{font-size:40px}section{grid-template-columns:1fr}article{padding:12px}h2{display:inline;margin-left:15px}article p{margin-left:32px}main{padding-top:25px}header span{display:none}}
            """.utf8).write(to: root.appendingPathComponent("style.css"))
            try Data("document.body.dataset.ready='yes';document.getElementById('ready').textContent='Live · connected';".utf8).write(to: root.appendingPathComponent("app.js"))
            try state.workspace.openWorkspace(root)
            state.agent.current.permission = .approval
            state.applyPreset(.preview)
            state.preview.ensureStarted()
            try await wait("Preview startup uses the existing approval popup") { state.agent.presentedApproval != nil }
            await settle(); capture("startup-approval")
            if let approval = state.agent.presentedApproval { state.agent.respond(approval.request, session: approval.session, value: "Allow Once") }
            try await wait("Static Preview reaches Running in real WebKit") { state.preview.state == .running }
            let server = state.preview.server!, url = state.preview.currentURL!
            let web = state.preview.renderer.webView
            var ready: String?
            for _ in 0..<40 {
                ready = try await web.evaluateJavaScript("document.body.dataset.ready") as? String
                if ready == "yes" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            check(ready == "yes", "Relative JavaScript module loads and executes")
            let color = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
            check(color == "rgb(247, 246, 239)", "Relative stylesheet loads")
            await settle(); capture("desktop")
            state.preview.selectDevice(.phone); await settle()
            let phone = try await web.evaluateJavaScript("window.innerWidth") as? NSNumber
            check(phone?.intValue == 390, "Phone mode renders a real 390 CSS-pixel viewport")
            capture("phone")
            state.preview.selectDevice(.tablet); await settle()
            let tablet = try await web.evaluateJavaScript("window.innerWidth") as? NSNumber
            check(tablet?.intValue == 768, "Tablet mode renders a real 768 CSS-pixel viewport")
            capture("tablet")
            state.preview.selectDevice(.phone)
            state.change { $0.toggle(.preview) }; state.destination = "Sessions"
            state.newSession(); state.selectedSession = state.sessions.first!.id
            state.takeover = "Settings"; await settle(); state.takeover = nil
            state.change { $0.toggle(.preview) }
            await settle()
            check(state.preview.server === server && state.preview.currentURL == url && state.preview.device == .phone, "Hide, sessions, destinations and takeover preserve the workspace Preview")
            state.preview.reload(); try await wait("Reload reconnects WebKit") { state.preview.state == .running }
            check(state.preview.server === server, "Reload preserves the managed process")
            state.preview.address = "not a URL"; state.preview.navigate(); await settle(); capture("local-error")
            check(state.preview.state == .failed && state.preview.server === server, "Invalid URL is a local error and preserves the server")
            state.preview.address = "http://127.0.0.1:1/"; state.preview.navigate()
            try await wait("Unreachable URL produces a local failure") { state.preview.state == .failed }
            check(state.preview.server === server, "Loading errors preserve the managed server")
            state.preview.address = url.absoluteString; state.preview.navigate()
            try await wait("Edited address loads on submit") { state.preview.state == .running }
            state.preview.stop(); try await wait("Explicit Stop removes the owned process group and temporary directory") { server.groupGone && state.preview.server == nil }
            check(!FileManager.default.fileExists(atPath: server.temporaryDirectory.path), "Only Milk-owned server temporary files are removed")
            await settle(); capture("stopped")
            state.preview.start()
            try await wait("Restart requests approval again") { state.agent.presentedApproval != nil }
            if let approval = state.agent.presentedApproval { state.agent.respond(approval.request, session: approval.session, value: "Allow Once") }
            try await wait("Restart loads the project again") { state.preview.state == .running }
            let shutdownServer = state.preview.server!
            let stopped = await state.preview.shutdown()
            check(stopped && shutdownServer.groupGone, "Bounded app-shutdown cleanup stops the managed group")
            check(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path), "Project files survive all cleanup")
        } catch { results.append("FAIL \(error.localizedDescription)") }
        _ = await state.preview.shutdown()
        state.agent.shutdown()
        try? state.workspace.closeWorkspace()
        try? FileManager.default.removeItem(at: root)
        try? results.joined(separator: "\n").write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(results.joined(separator: "\n")); fflush(stdout)
        DispatchQueue.main.async { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05) }
    }
}
