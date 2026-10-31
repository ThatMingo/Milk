import XCTest
@testable import Milk

final class SessionNavigationTests: XCTestCase {
    func testDeletionRejectsUnrelatedFilesSymlinksDirectoriesAndForeignWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PiSessionService()
        func saved(_ url: URL) -> SavedAgentSession { .init(path: url.path, title: "Test", modified: .now) }
        let arbitrary = storage.appendingPathComponent("not-a-session.jsonl")
        try Data("{\"private\":true}\n".utf8).write(to: arbitrary)
        XCTAssertThrowsError(try service.delete(saved(arbitrary), workspace: root, directory: storage))
        let malformedVersion = storage.appendingPathComponent("invalid-version.jsonl")
        let malformed = JSONValue.object(["type": .string("session"), "version": .number(1e300), "id": .string("invalid"), "cwd": .string(root.path)])
        try Data((malformed.encodedString + "\n").utf8).write(to: malformedVersion)
        XCTAssertThrowsError(try service.delete(saved(malformedVersion), workspace: root, directory: storage))
        let valid = storage.appendingPathComponent("valid.jsonl")
        let header = JSONValue.object(["type": .string("session"), "version": .number(3), "id": .string("test-session"), "cwd": .string(root.path)])
        try Data((header.encodedString + "\n").utf8).write(to: valid)
        let symlink = storage.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)
        XCTAssertThrowsError(try service.delete(saved(symlink), workspace: root, directory: storage))
        let directory = storage.appendingPathComponent("folder.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try service.delete(saved(directory), workspace: root, directory: storage))
        XCTAssertThrowsError(try service.delete(saved(valid), workspace: storage, directory: storage))
        XCTAssertThrowsError(try service.delete(saved(valid), workspace: root, directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arbitrary.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        try service.delete(saved(valid), workspace: root, directory: storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
    }
    @MainActor func testSidebarNavigationTakeoversAndReorderPreserveSessionState() throws {
        let state = ShellState(persist: false)
        defer { state.agent.shutdown() }
        XCTAssertEqual(state.sidebarDestinations.map(\.id), ["Files", "Sessions", "Git"])
        state.sessions = [.init(id: 1, title: "Running", state: .running), .init(id: 2, title: "Unread", state: .unread), .init(id: 3, title: "Approval", state: .approval), .init(id: 4, title: "Error", state: .error)]
        state.selectedSession = 1; state.agent.current.draft = "Keep this draft"
        let layout = state.layout
        XCTAssertEqual(state.sessionAttention, .error)
        state.sessions.removeLast(); XCTAssertEqual(state.sessionAttention, .approval)
        state.sessions.removeLast(); XCTAssertEqual(state.sessionAttention, .unread)
        state.sessions.removeLast(); XCTAssertEqual(state.sessionAttention, .running)
        for destination in ["Sessions", "Files", "Git"] {
            state.destination = destination
            state.takeover = "Settings"; state.takeover = nil
            state.takeover = "Extensions"; state.takeover = nil
            XCTAssertEqual(state.destination, destination); XCTAssertEqual(state.selectedSession, 1)
            XCTAssertEqual(state.currentSession?.state, .running); XCTAssertEqual(state.agent.current.draft, "Keep this draft")
            XCTAssertEqual(state.layout, layout)
        }
        state.setSidebarWidth(333); state.toggleSidebar(); state.toggleSidebar()
        XCTAssertEqual(state.sidebarWidth, 333); XCTAssertEqual(state.selectedSession, 1)
        state.sessions.append(.init(id: 8, title: "Second"))
        state.agent.reorderSession(8, to: 1)
        XCTAssertEqual(state.sessions.map(\.id), [8, 1]); XCTAssertEqual(state.selectedSession, 1)
        let snapshot = try JSONDecoder().decode(AgentWorkspaceState.self, from: XCTUnwrap(state.agent.snapshot()))
        XCTAssertEqual(snapshot.sessions.map(\.id), [8, 1])
        state.destination = "Files"
        state.workspace.restoreLayout?(nil, "Sessions")
        XCTAssertEqual(state.destination, "Sessions")
        state.workspace.restoreLayout?(nil, "Search")
        XCTAssertEqual(state.destination, "Files")
    }
}
