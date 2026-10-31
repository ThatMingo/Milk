import AppKit

/// Explicit native verification mode. Only isolated temporary repositories are changed.
@MainActor enum GitVerification {
    static func run(state: ShellState, window: NSWindow) async {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/verification-phase4")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Git-UI-" + UUID().uuidString).resolvingSymlinksInPath()
        var results: [String] = []
        func check(_ value: Bool, _ label: String) { results.append("\(value ? "PASS" : "FAIL") \(label)") }
        func settle() async { try? await Task.sleep(nanoseconds: 500_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(12)
            while !condition() {
                guard Date() < end else { throw GitFailure.validation("Timed out: " + label) }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            check(true, label)
        }
        func capture(_ name: String) {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        @discardableResult func command(_ args: [String], accepted: Set<Int32> = [0]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args; process.currentDirectoryURL = root
            let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment; env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"; process.environment = env
            try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard accepted.contains(process.terminationStatus) else { throw GitFailure.validation("Fixture command failed: " + args.joined(separator: " ")) }
            return String(decoding: data, as: UTF8.self)
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { state.workspace.git.setWorkspace(nil); try? FileManager.default.removeItem(at: root) }
            try state.workspace.openWorkspace(root); state.destination = "Git"; state.applyPreset(.coding)
            try await wait("Non-repository detected without initialization") { state.workspace.git.checked && state.workspace.git.repository == nil }
            await settle(); capture("no-repository")
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "Milk never silently initializes a repository")
            try command(["init", "-b", "main"]); try command(["config", "user.name", "Milk Verification"]); try command(["config", "user.email", "milk@example.invalid"]); try command(["config", "commit.gpgsign", "false"])
            let url = root.appendingPathComponent("Example.swift")
            let original = "import Foundation\n\nstruct Example {\n    let title = \"Milk\"\n\n    func greet() {\n        print(title)\n    }\n\n    func count() -> Int {\n        return 1\n    }\n}\n"
            try Data(original.utf8).write(to: url); try command(["add", "."]); try command(["commit", "-m", "Initial"])
            try await wait("External git init/commit detected automatically") { state.workspace.git.repository?.branch == "main" }
            try Data(original.replacingOccurrences(of: "\"Milk\"", with: "\"Milk + Git\"").replacingOccurrences(of: "return 1", with: "return 2").utf8).write(to: url)
            try Data("Notes for this workspace.\n".utf8).write(to: root.appendingPathComponent("Notes.md"))
            try await wait("External edits refresh Git without manual refresh") { state.workspace.git.repository?.files.count == 2 }
            try state.workspace.openFile(url)
            let tab = state.workspace.activePane.activeTab!.id, buffer = state.workspace.activeBuffer!
            state.workspace.openChangedFile(url)
            try await wait("Pi changed-file navigation opens the Git diff") { state.workspace.activePane.activeTab?.diffMode == true }
            check(state.workspace.activePane.activeTab?.id == tab && state.workspace.activeBuffer === buffer, "Diff reuses the editor's existing tab and buffer")
            await settle(); capture("unified-diff")
            var confirmed = false
            let beforeDiscard = try Data(contentsOf:url)
            let cancelTimer = Timer(timeInterval:0.1,repeats:true) { timer in
                guard let dialog = NSApp.modalWindow else { return }
                confirmed = true
                if let view=dialog.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("revert-confirmation.png"))
                }
                timer.invalidate(); NSApp.abortModal()
            }
            RunLoop.main.add(cancelTimer,forMode:.modalPanel)
            state.workspace.git.discard(state.workspace.git.repository!.files.first { $0.path == "Example.swift" }!,store:state.workspace)
            try await wait("Revert requires an explicit native confirmation") { confirmed }
            cancelTimer.invalidate(); await settle()
            check(try Data(contentsOf:url) == beforeDiscard,"Cancelling Revert preserves file contents")
            state.workspace.git.sideBySide = true; await settle(); capture("side-by-side-diff")
            state.workspace.setDiffMode(false, pane: state.workspace.activePane.id); await settle()
            check(state.workspace.activeBuffer === buffer && state.workspace.activePane.activeTab?.diffMode == false, "Returning from Diff preserves the shared editor buffer")
            state.workspace.git.commitMessage = "Verification commit"; state.workspace.git.commit()
            try await wait("Empty-stage commit returns explicit recovery") { state.workspace.git.failure?.kind == .noStagedChanges }
            capture("stage-all-recovery")
            state.workspace.git.commit(stageAll: true)
            try await wait("Explicit Stage All & Commit clears message and refreshes state") { state.workspace.git.commitMessage.isEmpty && state.workspace.git.repository?.dirty == false && state.workspace.git.busy == nil }
            await settle(); capture("commit-success")
            try command(["switch", "-c", "feature"])
            try await wait("External branch switch updates branch automatically") { state.workspace.git.repository?.branch == "feature" }
            try Data("// Feature branch\n".utf8).write(to: url); try command(["commit", "-am", "Feature"])
            try command(["switch", "main"]); try Data("// Main branch\n".utf8).write(to: url); try command(["commit", "-am", "Main"])
            try command(["merge", "feature"], accepted: [1])
            try await wait("External merge conflicts appear automatically") { state.workspace.git.repository?.files.contains(where: \.conflict) == true }
            state.workspace.openGitFile(state.workspace.git.repository!.files.first { $0.conflict }!)
            await settle(); capture("conflict-diff")
            state.workspace.setDiffMode(false, pane: state.workspace.activePane.id); await settle()
            check(state.workspace.activeBuffer?.text.contains("<<<<<<<") == true, "Conflicted file can be opened in the real editor")
            try Data("// Resolved merge\n".utf8).write(to: url)
            try command(["add", "Example.swift"])
            try await wait("Externally staged resolution clears conflict") { state.workspace.git.repository?.files.contains(where: \.conflict) == false && state.workspace.git.repository?.files.first?.staged == true }
            state.workspace.git.commitMessage = "Resolve"; state.workspace.git.commit()
            try await wait("Merge resolution commits successfully") { state.workspace.git.busy == nil && state.workspace.git.commitMessage.isEmpty && state.workspace.git.repository?.merging == false }
        } catch { results.append("FAIL \(error.localizedDescription)") }
        try? results.joined(separator: "\n").write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(results.joined(separator: "\n")); NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}
