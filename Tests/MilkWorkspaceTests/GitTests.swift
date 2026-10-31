import XCTest
import AppKit
@testable import Milk

final class GitTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MilkGitTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @discardableResult func git(_ args: [String], _ root: URL, code: Int32 = 0) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, code, args.joined(separator: " "))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func write(_ text: String, _ path: String = "file.txt", _ root: URL) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    func fixture(initial: String = "one\ntwo\nthree\n") throws -> URL {
        let root = try directory(); try git(["init", "-b", "main"], root)
        try git(["config", "user.name", "Milk Test"], root); try git(["config", "user.email", "milk@example.invalid"], root)
        try git(["config", "commit.gpgsign", "false"], root)
        try write(initial, "file.txt", root); try git(["add", "."], root); try git(["commit", "-m", "Initial"], root)
        return root
    }
    func testDetectionUnbornUnstageAndNulPaths() async throws {
        let root = try directory(), service = GitService()
        let absent = try await service.repository(at: root); XCTAssertNil(absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        try git(["init", "-b", "main"], root)
        let name = " space\t🥛\nfile.txt"; try write("hello\n", name, root)
        var repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.unborn); XCTAssertEqual(repo.branch, "main"); XCTAssertEqual(repo.files.first?.path, name)
        try await service.perform(.stage(repo.files[0]), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.files[0].staged)
        try write("newer disk edits\n", name, root)
        try await service.perform(.unstage(repo.files[0]), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.files[0].untracked)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(name),encoding:.utf8),"newer disk edits\n")
        let stagedEmpty = try await service.diff(repo.files[0], staged:true,in:repo)
        XCTAssertTrue(stagedEmpty.raw.isEmpty)
        let diff = try await service.diff(repo.files[0], staged: false, in: repo)
        XCTAssertEqual(diff.hunks.count, 1)
        try await service.perform(.hunk(diff, 0, .stage), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.files[0].staged)
    }
    func testHunksStageUnstageRevertAndStaleProtection() async throws {
        let original = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let root = try fixture(initial: original), service = GitService()
        let changed = original.replacingOccurrences(of: "line 2\n", with: "changed 2\n").replacingOccurrences(of: "line 25\n", with: "changed 25\n")
        try write(changed, "file.txt", root)
        var repo = try await service.repository(at: root)!
        var diff = try await service.diff(repo.files[0], staged: false, in: repo)
        XCTAssertEqual(diff.hunks.count, 2)
        try await service.perform(.hunk(diff, 0, .stage), in: repo)
        let staged = try git(["show", ":file.txt"], root)
        XCTAssertTrue(staged.contains("changed 2")); XCTAssertFalse(staged.contains("changed 25"))
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.files[0].staged && repo.files[0].unstaged)
        let stagedDiff = try await service.diff(repo.files[0], staged: true, in: repo)
        try await service.perform(.hunk(stagedDiff, 0, .unstage), in: repo)
        XCTAssertEqual(try git(["show", ":file.txt"], root), original.trimmingCharacters(in: .newlines))
        repo = try await service.repository(at: root)!
        diff = try await service.diff(repo.files[0], staged: false, in: repo)
        try await service.perform(.hunk(diff, 1, .revert), in: repo)
        let disk = try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertTrue(disk.contains("changed 2")); XCTAssertFalse(disk.contains("changed 25"))
        do { try await service.perform(.hunk(diff, 0, .stage), in: repo); XCTFail("Stale hunk accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind, .staleDiff) }
        repo = try await service.repository(at: root)!
        diff = try await service.diff(repo.files[0], staged: false, in: repo)
        try await service.perform(.discard(repo.files[0], diff), in: repo)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), original)
    }
    func testCRLFNoNewlineAddedAndDeletedHunks() async throws {
        let root = try fixture(initial: "first\r\nsecond\r\nlast"), service = GitService()
        try write("FIRST\r\nsecond\r\nlast", "file.txt", root)
        var repo = try await service.repository(at: root)!
        var diff = try await service.diff(repo.files[0], staged: false, in: repo)
        XCTAssertEqual(diff.hunks.count, 1)
        try await service.perform(.hunk(diff, 0, .stage), in: repo)
        XCTAssertEqual(try git(["show", ":file.txt"], root), "FIRST\r\nsecond\r\nlast")
        try git(["reset", "--hard", "HEAD"], root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file.txt"))
        repo = try await service.repository(at: root)!
        diff = try await service.diff(repo.files[0], staged: false, in: repo)
        try await service.perform(.hunk(diff, 0, .stage), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertEqual(repo.files[0].index, "D")
        diff = try await service.diff(repo.files[0], staged: true, in: repo)
        try await service.perform(.hunk(diff, 0, .unstage), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertEqual(repo.files[0].worktree, "D")
        diff = try await service.diff(repo.files[0], staged: false, in: repo)
        try await service.perform(.hunk(diff, 0, .revert), in: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }
    func testRenameUnstageCommitAndNoImplicitStaging() async throws {
        let root = try fixture(), service = GitService()
        try git(["mv", "file.txt", "renamed.txt"], root)
        var repo = try await service.repository(at: root)!
        XCTAssertEqual(repo.files.first?.index, "R"); XCTAssertEqual(repo.files.first?.originalPath, "file.txt")
        try await service.perform(.unstage(repo.files[0]), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.files.contains { $0.worktree == "D" }); XCTAssertTrue(repo.files.contains(where: \.untracked))
        do { try await service.perform(.commit("No staging"), in: repo); XCTFail("Empty stage accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind, .noStagedChanges) }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], root), "1")
        try await service.perform(.stageAll, in: repo)
        repo = try await service.repository(at: root)!
        try await service.perform(.commit("Rename"), in: repo)
        repo = try await service.repository(at: root)!
        XCTAssertFalse(repo.dirty); XCTAssertEqual(try git(["log", "-1", "--format=%s"], root), "Rename")
    }
    func testBinaryDiscardRejectsNewChangesAndPreservesIndex() async throws {
        let root = try fixture(), service = GitService(), url = root.appendingPathComponent("binary.dat")
        try Data([0,1,2]).write(to: url); try git(["add", "."], root); try git(["commit", "-m", "Binary"], root)
        try Data([0,3,4]).write(to: url)
        var repo = try await service.repository(at: root)!, file = try XCTUnwrap(repo.files.first)
        let old = try await service.diff(file, staged: false, in: repo)
        XCTAssertTrue(old.binary)
        try Data([0,5,6]).write(to: url)
        do { try await service.perform(.discard(file, old), in: repo); XCTFail("Changed binary discarded") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind, .staleDiff) }
        try await service.perform(.stage(file), in: repo)
        try Data([0,7,8]).write(to: url)
        repo = try await service.repository(at: root)!; file = try XCTUnwrap(repo.files.first)
        let current = try await service.diff(file, staged: false, in: repo)
        try await service.perform(.discard(file, current), in: repo)
        XCTAssertEqual(try Data(contentsOf: url), Data([0,5,6]))
        repo = try await service.repository(at: root)!; XCTAssertTrue(repo.files[0].staged); XCTAssertFalse(repo.files[0].unstaged)
        try write("untracked", "new.txt", root)
        repo = try await service.repository(at: root)!; file = try XCTUnwrap(repo.files.first { $0.untracked })
        let untracked = try await service.diff(file, staged: false, in: repo)
        try await service.perform(.discard(file, untracked), in: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        // A formerly untracked row must never delete a file that was staged externally before confirmation.
        try write("keep staged", "new.txt", root)
        repo = try await service.repository(at: root)!; file = try XCTUnwrap(repo.files.first { $0.untracked })
        try git(["add","new.txt"],root)
        let staleRowSnapshot = try await service.diff(file,staged:false,in:repo)
        let latest = try await service.repository(at:root)!
        do { try await service.perform(.discard(file,staleRowSnapshot),in:latest); XCTFail("Stale untracked row deleted staged file") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind,.staleDiff) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("new.txt").path))
    }
    func testBranchesBlockingSwitchAndConflictResolution() async throws {
        let root = try fixture(), service = GitService()
        var repo = try await service.repository(at: root)!
        try await service.perform(.createBranch("feature"), in: repo)
        try write("feature\n", "file.txt", root); try git(["commit", "-am", "Feature"], root)
        repo = try await service.repository(at: root)!
        try await service.perform(.switchBranch("main"), in: repo)
        try write("local\n", "file.txt", root)
        repo = try await service.repository(at: root)!
        do { try await service.perform(.switchBranch("feature"), in: repo); XCTFail("Blocking switch succeeded") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind, .command); XCTAssertTrue(failure.message.contains("overwritten")) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "local\n")
        try git(["commit", "-am", "Local"], root)
        repo = try await service.repository(at: root)!
        do { try await service.perform(.deleteBranch("feature"),in:repo); XCTFail("Unmerged branch was deleted") }
        catch { XCTAssertTrue(try git(["branch","--list","feature"],root).contains("feature")) }
        do { try await service.perform(.mergeBranch("feature"), in: repo); XCTFail("Expected conflict") } catch {}
        repo = try await service.repository(at: root)!
        XCTAssertTrue(repo.merging); XCTAssertTrue(repo.files[0].conflict)
        let conflict = try await service.diff(repo.files[0], staged: false, in: repo)
        XCTAssertFalse(conflict.raw.isEmpty)
        try write("resolved\n", "file.txt", root)
        try await service.perform(.stage(repo.files[0]), in: repo)
        repo = try await service.repository(at: root)!; XCTAssertFalse(repo.files.contains(where: \.conflict))
        try await service.perform(.commit("Resolve merge"), in: repo)
        repo = try await service.repository(at: root)!
        try await service.perform(.deleteBranch("feature"), in: repo)
        repo = try await service.repository(at: root)!; XCTAssertFalse(repo.branches.contains("feature"))
        let head = try git(["rev-parse", "HEAD"], root); try git(["switch", "--detach", head], root)
        repo = try await service.repository(at: root)!; XCTAssertTrue(repo.detached)
    }
    func testLocalRemoteFetchPullPushAheadBehind() async throws {
        let root = try fixture(), bare = try directory(), peer = try directory(), service = GitService()
        try git(["init", "--bare", "-b", "main"], bare)
        try git(["remote", "add", "origin", bare.path], root)
        var repo = try await service.repository(at: root)!
        try await service.perform(.push, in: repo)
        try git(["clone", bare.path, peer.path], bare)
        try git(["config", "user.name", "Peer"], peer); try git(["config", "user.email", "peer@example.invalid"], peer)
        try git(["config", "commit.gpgsign", "false"], peer)
        try write("peer\n", "peer.txt", peer); try git(["add", "."], peer); try git(["commit", "-m", "Peer"], peer); try git(["push"], peer)
        repo = try await service.repository(at: root)!
        try await service.perform(.fetch, in: repo)
        repo = try await service.repository(at: root)!; XCTAssertEqual(repo.behind, 1)
        try await service.perform(.pull, in: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("peer.txt").path))
        try write("local\n", "local.txt", root)
        repo = try await service.repository(at: root)!
        try await service.perform(.stageAll, in: repo)
        try await service.perform(.commit("Local"), in: repo)
        repo = try await service.repository(at: root)!; XCTAssertEqual(repo.ahead, 1)
        try await service.perform(.push, in: repo)
        repo = try await service.repository(at: root)!; XCTAssertEqual(repo.ahead, 0)
    }
    @MainActor func testChangedFileAliasRoutesToActualDiffAndNormalOpenStaysEditor() async throws {
        let root=try fixture(),aliasRoot=try directory()
        let link=aliasRoot.appendingPathComponent("workspace")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        let store=WorkspaceStore(persistence:WorkspacePersistence(enabled:false))
        try store.openWorkspace(root)
        try store.openFile(root.appendingPathComponent("file.txt"))
        let buffer=store.activeBuffer,tab=store.activePane.activeTab?.id
        try write("one\nchanged\nthree\n", "file.txt",root)
        try git(["add","file.txt"],root)
        store.openChangedFile(link.appendingPathComponent("file.txt"))
        try await wait {store.activePane.activeTab?.diffMode == true}
        XCTAssertEqual(store.activePane.activeTab?.id,tab);XCTAssertTrue(store.activeBuffer === buffer)
        XCTAssertEqual(store.activePane.activeTab?.stagedDiff,true)
        await store.git.refreshNow()
        try await wait {store.git.repository != nil}
        let diff=try await store.git.diff(path:"file.txt",staged:true)
        XCTAssertTrue(diff.hunks.flatMap(\.lines).contains(where:{$0.kind == "+" && $0.text == "changed"}))
        XCTAssertTrue(diff.hunks.flatMap(\.lines).contains(where:{$0.kind == "-" && $0.text == "two"}))
        try store.openFile(root.appendingPathComponent("file.txt"))
        XCTAssertEqual(store.activePane.activeTab?.diffMode,false)
        try store.closeWorkspace()
    }
    @MainActor func testDiffUsesSameTabAndBufferAndDeletedFilesOpen() async throws {
        let root = try fixture(), store = WorkspaceStore(persistence: WorkspacePersistence(enabled: false))
        try store.openWorkspace(root); await store.git.refreshNow()
        try store.openFile(root.appendingPathComponent("file.txt")); let buffer = store.activeBuffer, tab = store.activePane.activeTab?.id
        try write("changed\n", "file.txt", root); await store.git.refreshNow()
        store.openGitFile(store.git.repository!.files[0])
        XCTAssertTrue(store.activeBuffer === buffer); XCTAssertEqual(store.activePane.activeTab?.id, tab)
        XCTAssertEqual(store.activePane.tabs.count, 1); XCTAssertEqual(store.activePane.activeTab?.diffMode, true)
        store.setDiffMode(false, pane: store.activePane.id); XCTAssertEqual(store.activePane.activeTab?.diffMode, false)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file.txt"))
        await store.git.refreshNow(); store.openGitFile(store.git.repository!.files[0])
        XCTAssertEqual(store.activePane.tabs.count, 1); XCTAssertEqual(store.activePane.activeTab?.diffMode, true)
        try store.closeWorkspace()
    }
    @MainActor func testCommitAndPushFailureKeepsLocalCommitAndMessageRecovery() async throws {
        let root = try fixture(), store = GitStore()
        store.setWorkspace(root); await store.refreshNow()
        try write("change\n", "file.txt", root); await store.refreshNow()
        store.commitMessage = "Commit locally"; store.commit(push: true)
        try await wait { store.failure?.kind == .noStagedChanges }
        XCTAssertEqual(store.commitMessage, "Commit locally")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], root), "1")
        store.commit(stageAll: true)
        try await wait { store.commitMessage.isEmpty && store.busy == nil }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], root), "2")
        try write("another\n", "file.txt", root)
        _ = await store.perform("Stage", .stageAll)
        store.commitMessage = "Push will fail"; store.commit(push: true)
        try await wait { store.failure?.operation == "Push" }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], root), "3")
        XCTAssertTrue(store.commitMessage.isEmpty); XCTAssertTrue(store.failure!.message.contains("local commit succeeded"))
        // A failing pre-commit hook prevents the push entirely.
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("blocked\n", "file.txt", root); _ = await store.perform("Stage", .stageAll)
        store.commitMessage = "Blocked"; store.commit(push: true)
        try await wait { store.failure != nil && store.busy == nil }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], root), "3")
        XCTAssertEqual(store.commitMessage, "Blocked"); XCTAssertNotEqual(store.failure?.operation, "Push")
        store.setWorkspace(nil)
    }
    @MainActor func testLinkedWorktreeAndSymlinkDiscardSafety() async throws {
        let root=try fixture(),linked=try directory(),outside=try directory(),service=GitService()
        try git(["worktree","add","-b","linked",linked.path],root)
        defer { _ = try? git(["worktree","remove","--force",linked.path],root) }
        let repo=try await service.repository(at:linked)!
        XCTAssertEqual(repo.branch,"linked"); XCTAssertEqual(repo.root.path,linked.path)
        XCTAssertNotEqual(repo.gitDirectory,repo.commonDirectory)
        let destination=outside.appendingPathComponent("precious.txt")
        try Data("preserve me".utf8).write(to:destination)
        let link=linked.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:destination)
        let updated=try await service.repository(at:linked)!,file=try XCTUnwrap(updated.files.first)
        let diff=try await service.diff(file,staged:false,in:updated)
        XCTAssertTrue(diff.raw.contains(destination.path))
        let store=WorkspaceStore(persistence:WorkspacePersistence(enabled:false))
        try store.openWorkspace(linked); await store.git.refreshNow(); store.openGitFile(file)
        XCTAssertEqual(store.activePane.activeTab?.diffMode,true)
        XCTAssertNil(store.buffers[link.path],"External symlink target must not be loaded into an editable buffer")
        try await service.perform(.discard(file,diff),in:updated)
        XCTAssertEqual(try String(contentsOf:destination,encoding:.utf8),"preserve me")
        XCTAssertFalse(FileManager.default.fileExists(atPath:link.path))
        try store.closeWorkspace()
    }
    func testInvalidPathsCannotStageOutsideRepository() async throws {
        let root=try fixture(),service=GitService(),repo=try await service.repository(at:root)!
        for path in ["../outside.txt","/tmp/outside.txt",".git/config"] {
            do { try await service.perform(.stage(.init(path:path,index:".",worktree:"M")),in:repo); XCTFail("Invalid path accepted") }
            catch let failure as GitFailure { XCTAssertEqual(failure.kind,.invalidPath) }
        }
    }
    func testLargeDiffRetainsSafeFileActions() async throws {
        let root=try fixture(),service=GitService(),url=root.appendingPathComponent("large.txt")
        try Data(repeating:65,count:FileTextCodec.maximumSize+1).write(to:url)
        var repo=try await service.repository(at:root)!,file=try XCTUnwrap(repo.files.first)
        let snapshot=try await service.diff(file,staged:false,in:repo)
        XCTAssertNotNil(snapshot.displayMessage); XCTAssertTrue(snapshot.hunks.isEmpty)
        try Data(repeating:66,count:FileTextCodec.maximumSize+1).write(to:url)
        do { try await service.perform(.discard(file,snapshot),in:repo); XCTFail("Stale large diff discarded") }
        catch let failure as GitFailure { XCTAssertEqual(failure.kind,.staleDiff) }
        repo=try await service.repository(at:root)!; file=try XCTUnwrap(repo.files.first)
        let current=try await service.diff(file,staged:false,in:repo)
        try await service.perform(.discard(file,current),in:repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for Git workflow"); return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
