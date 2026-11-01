import XCTest
import Combine
@testable import Milk

@MainActor private final class ChatFixtureBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var captured: ((AgentEvent) -> Void)?
    var holdStart = false
    var enteredStart = false
    var history = AgentHistory()
    var waiter: CheckedContinuation<Void, Never>?
    var commandRefreshes = 0
    func start(workspace: URL, session: AgentSession) async throws {
        captured = onEvent; enteredStart = true
        if holdStart { await withCheckedContinuation { waiter = $0 } }
        onEvent?(.history(history))
        onEvent?(.runtime(.init(phase: .ready, bundled: false, detail: "Fixture ready")))
    }
    func release() { waiter?.resume(); waiter = nil }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws { onEvent?(.started) }
    func stop() async throws { onEvent?(.settled(aborted: true)) }
    func clearQueue() async throws {}
    func steerQueued(_ prompt: AgentPrompt) async throws {}
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws {}
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws {}
    func refreshCommands() async throws { commandRefreshes += 1 }
    func shutdown() { release(); onEvent = nil }
    func shutdownAndWait() async throws { shutdown() }
}

final class ChatStabilityTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    @MainActor private func until(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { throw AgentError.message("Timed out: " + label) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor private func fixture(persist: Bool = false, hold: Bool = false) throws -> (WorkspaceStore, AgentService, ChatFixtureBackend) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Milk.ChatTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let workspace = WorkspaceStore(persistence: .init(defaults: defaults, directory: root.appendingPathComponent("recovery"), enabled: persist))
        try workspace.openWorkspace(root)
        let backend = ChatFixtureBackend(); backend.holdStart = hold
        let agent = AgentService(workspace: workspace, defaults: defaults, enabled: false, makeBackend: { backend })
        workspace.sessionData = { [weak agent] in agent?.snapshot() }
        agent.restore(nil)
        addTeardownBlock {
            let exited = await agent.shutdownAndWait(); XCTAssertTrue(exited)
            try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (workspace, agent, backend)
    }
    @MainActor private func connect(_ agent: AgentService, _ backend: ChatFixtureBackend) async throws {
        agent.connectForDiscovery()
        try await until("connected") { agent.runtimeStatuses[agent.selectedSession]?.phase == .ready }
    }

    @MainActor func testHistoryWaitKeepsCacheThenCommitsOnceAndReconnectKeepsIDs() async throws {
        let (_, agent, backend) = try fixture(hold: true)
        let cached = [AgentMessage(id: "old-user", role: "user", text: "Question"), AgentMessage(id: "old-answer", role: "assistant", text: "Answer")]
        agent.current.messages = cached
        backend.history.messages = [.init(id: "native-user", role: "user", text: "Question", sourceID: "source-user"), .init(id: "native-answer", role: "assistant", text: "Answer", sourceID: "source-answer")]
        var publications: [[String]] = []
        let observation = agent.$conversations.sink { publications.append($0[agent.selectedSession]?.messages.map(\.id) ?? []) }
        defer { observation.cancel() }
        agent.connectForDiscovery(); try await until("held start") { backend.enteredStart }
        XCTAssertEqual(agent.current.messages, cached)
        publications.removeAll(); backend.release()
        try await until("history ready") { agent.runtimeStatuses[agent.selectedSession]?.phase == .ready }
        XCTAssertEqual(publications, [["old-user", "old-answer"]], "No intermediate empty or partial transcript is published")
        XCTAssertEqual(agent.current.messages.map(\.sourceID), ["source-user", "source-answer"])
        backend.onEvent?(.history(backend.history))
        XCTAssertEqual(agent.current.messages.map(\.id), ["old-user", "old-answer"])
        XCTAssertEqual(agent.current.messages.count, 2)
        // Events referring to native history IDs remain linked to retained cache IDs.
        backend.onEvent?(.activity(.init(id: "tool", kind: "Read", detail: "File", afterMessageID: "native-answer")))
        XCTAssertEqual(agent.current.activities.first?.afterMessageID, "old-answer")
    }
    func testNativeAuthorityRemovesObsoleteContentKeepsOrderedThinkingToolsAndRepeatedPrompts() throws {
        var decoder = PiMessageDecoder()
        let user = decoder.restore(try json(#"{"role":"user","content":"Again","timestamp":1}"#))
        let answer = decoder.restore(try json(#"{"role":"assistant","timestamp":2,"content":[{"type":"thinking","thinking":"Plan"},{"type":"toolCall","id":"read","name":"read"},{"type":"text","text":"Result"}]}"#))
        let again = decoder.restore(try json(#"{"role":"user","content":"Again","timestamp":3}"#))
        let history = AgentHistory(messages: [user, answer, again], activities: [.init(id: "read", kind: "Read", detail: "file", afterMessageID: answer.id, output: "Data", status: .completed)])
        var cache = SessionConversation(messages: [.init(id: "legacy-user", role: "user", text: "Again"), .init(id: "obsolete", role: "assistant", text: "Discard")])
        cache.scrollAnchor = "obsolete"
        let result = history.reconcile(with: cache)
        XCTAssertEqual(result.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(result.messages[0].id, "legacy-user"); XCTAssertNotEqual(result.messages[2].id, "legacy-user")
        XCTAssertFalse(result.messages.contains { $0.id == "obsolete" }); XCTAssertNil(result.scrollAnchor)
        XCTAssertEqual(result.messages[1].blocks?.map(\.kind), [.thinking, .activity, .text])
        XCTAssertEqual(AgentTranscript.items(messages: result.messages, activities: result.activities)[1].response?.activityIDs, [AgentActivity.transcriptID("read", messageID: result.messages[1].id)])
    }
    func testTimestampIDsMatchLiveEndAndRestoreIncludingCollisions() throws {
        var live = PiMessageDecoder(), restored = PiMessageDecoder()
        for text in ["First", "Second"] {
            let start = try json(#"{"type":"message_start","message":{"role":"assistant","timestamp":10,"content":[]}}"#)
            guard case .message(let initial) = live.consume(start).first else { return XCTFail("Missing start") }
            let final = try json("{\"role\":\"assistant\",\"timestamp\":10,\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}")
            guard case .message(let ended) = live.consume(.object(["type": .string("message_end"), "message": final])).first else { return XCTFail("Missing end") }
            XCTAssertEqual(initial.id, ended.id); XCTAssertEqual(ended.id, restored.restore(final).id)
            XCTAssertEqual(initial.sourceID, ended.sourceID)
        }
        var missingTimestampA = PiMessageDecoder(), missingTimestampB = PiMessageDecoder()
        XCTAssertEqual(missingTimestampA.restore(try json(#"{"role":"user","content":[{"text":"Same","type":"text"}]}"#)).id,
                       missingTimestampB.restore(try json(#"{"content":[{"type":"text","text":"Same"}],"role":"user"}"#)).id)
    }
    func testCoalescingMatchesSequentialUpdatesAndRedaction() {
        let deltas: [AgentContentDelta] = [
            .init(messageID: "a", index: 0, kind: .text, text: "A"),
            .init(messageID: "a", index: 0, kind: .text, text: "B"),
            .init(messageID: "a", index: 0, kind: .text, text: "Final", replace: true, finished: true),
            .init(messageID: "a", index: 1, kind: .thinking, text: "Secret"),
            .init(messageID: "a", index: 1, kind: .thinking, redacted: true),
            .init(messageID: "a", index: 1, kind: .thinking, text: "Do not resurrect", finished: true)
        ]
        var sequential = SessionConversation(messages: [.init(id: "a", role: "assistant", text: "", streaming: true)])
        var buffered = sequential, buffer = AgentStreamBuffer()
        for delta in deltas { sequential.messages[0].apply(delta); buffer.append(delta) }
        buffer.apply(to: &buffered)
        XCTAssertEqual(buffered.messages, sequential.messages)
        XCTAssertFalse(buffered.messages[0].blocks![1].visibleThinking)
    }
    @MainActor func testTokenBurstPublishesOnceDoesNotRefreshComposerAndEndIsAuthoritative() async throws {
        let (_, agent, backend) = try fixture(); try await connect(agent, backend)
        backend.onEvent?(.message(.init(id: "a", role: "assistant", text: "", streaming: true)))
        var publishes = 0, composer = 0
        let transcript = agent.$conversations.dropFirst().sink { _ in publishes += 1 }
        let commands = agent.composerChanges.sink { composer += 1 }
        defer { transcript.cancel(); commands.cancel() }
        for _ in 0..<500 { backend.onEvent?(.contentDelta(.init(messageID: "a", index: 0, kind: .text, text: "x"))) }
        XCTAssertEqual(publishes, 0)
        try await until("coalesced frame") { agent.current.messages.last?.text.count == 500 }
        XCTAssertEqual(publishes, 1); XCTAssertEqual(composer, 0); XCTAssertEqual(backend.commandRefreshes, 0)
        backend.onEvent?(.contentDelta(.init(messageID: "a", index: 0, kind: .text, text: "pending")))
        backend.onEvent?(.message(.init(id: "a", role: "assistant", text: "Authoritative final", blocks: [.init(id: "a-block-0", index: 0, kind: .text, text: "Authoritative final")])))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(agent.current.messages.count, 1); XCTAssertEqual(agent.current.messages[0].text, "Authoritative final")
    }
    @MainActor func testSnapshotFlushesPendingTextAndInterruptedCacheRemainsReadable() async throws {
        let (workspace, agent, backend) = try fixture(); try await connect(agent, backend)
        backend.onEvent?(.message(.init(id: "partial", role: "assistant", text: "", streaming: true)))
        backend.onEvent?(.contentDelta(.init(messageID: "partial", index: 0, kind: .thinking, text: "Plan")))
        backend.onEvent?(.contentDelta(.init(messageID: "partial", index: 1, kind: .text, text: "Partial answer")))
        let snapshot = try XCTUnwrap(agent.snapshot())
        let suite = "Milk.ChatRestore." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovered = AgentService(workspace: workspace, defaults: defaults, enabled: false)
        defer { recovered.shutdown() }
        recovered.restore(snapshot)
        XCTAssertEqual(recovered.current.messages.last?.id, "partial")
        XCTAssertEqual(recovered.current.messages.last?.text, "Partial answer")
        XCTAssertEqual(recovered.current.messages.last?.blocks?.map(\.kind), [.thinking, .text])
        XCTAssertEqual(recovered.current.messages.last?.streaming, false)
        XCTAssertTrue(recovered.current.messages.last?.blocks?.allSatisfy { !$0.streaming } == true)
    }
    @MainActor func testContinuousStreamCheckpointsBeforeItEndsAndIndexIsUnchanged() async throws {
        let (workspace, agent, backend) = try fixture(persist: true); try await connect(agent, backend)
        backend.onEvent?(.message(.init(id: "a", role: "assistant", text: "", streaming: true)))
        let index = agent.sessionIndex.records()
        for _ in 0..<8 {
            backend.onEvent?(.contentDelta(.init(messageID: "a", index: 0, kind: .text, text: "checkpoint ")))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let data = try XCTUnwrap(workspace.persistence.load(try XCTUnwrap(workspace.workspace?.url))?.shellSessions)
        let saved = try JSONDecoder().decode(AgentWorkspaceState.self, from: data)
        XCTAssertFalse(saved.conversations[agent.selectedSession]?.messages.last?.text.isEmpty ?? true)
        XCTAssertTrue(agent.current.messages.last?.streaming == true)
        XCTAssertEqual(agent.sessionIndex.records(), index)
    }
    @MainActor func testOldSessionStreamAndInvalidatedCallbackCannotContaminateSelection() async throws {
        let (_, agent, backend) = try fixture(); try await connect(agent, backend)
        let first = agent.selectedSession
        backend.onEvent?(.message(.init(id: "first", role: "assistant", text: "", streaming: true)))
        agent.newSession(); let second = agent.selectedSession
        backend.onEvent?(.contentDelta(.init(messageID: "first", index: 0, kind: .text, text: "background")))
        _ = agent.snapshot()
        XCTAssertEqual(agent.conversations[first]?.messages.last?.text, "background")
        XCTAssertTrue(agent.conversations[second]?.messages.isEmpty == true)
        agent.closeSession(first)
        backend.captured?(.history(.init(messages: [.init(id: "stale", role: "assistant", text: "Stale")], activities: [])))
        backend.captured?(.contentDelta(.init(messageID: "first", index: 0, kind: .text, text: "stale")))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(agent.conversations[first]?.messages.last?.text, "background")
        XCTAssertTrue(agent.current.messages.isEmpty)
    }
    func testEmptyLiveThinkingIsVisibleAndRedactedThinkingIsNot() {
        var response = AgentResponseTurn(id: "a", blocks: [.init(id: "thinking", index: 0, kind: .thinking, streaming: true)], streaming: true)
        XCTAssertTrue(response.thinkingActive); XCTAssertEqual(response.presentationGroups.count, 1)
        response.blocks[0].redacted = true
        XCTAssertFalse(response.thinkingActive); XCTAssertTrue(response.presentationGroups.isEmpty)
    }
    func testFollowTailIgnoresGrowthStopsOnUpwardGestureAndResumesNearBottom() {
        var follow = ChatFollowTailState()
        follow.update(.init(offset: 600, contentHeight: 1000, viewportHeight: 400))
        follow.update(.init(offset: 600, contentHeight: 1200, viewportHeight: 400))
        XCTAssertTrue(follow.followsTail, "Content growth is not a user scroll")
        follow.userScrolling = true
        follow.update(.init(offset: 540, contentHeight: 1200, viewportHeight: 400))
        XCTAssertFalse(follow.followsTail)
        follow.userScrolling = false
        follow.update(.init(offset: 540, contentHeight: 1600, viewportHeight: 400))
        XCTAssertFalse(follow.followsTail)
        follow.userScrolling = true
        follow.update(.init(offset: 800, contentHeight: 1600, viewportHeight: 400))
        XCTAssertFalse(follow.followsTail)
        follow.update(.init(offset: 1160, contentHeight: 1600, viewportHeight: 400))
        XCTAssertFalse(follow.followsTail, "Reading the last few lines must not re-arm a snap to the bottom")
        follow.update(.init(offset: 1200, contentHeight: 1600, viewportHeight: 400))
        XCTAssertTrue(follow.followsTail)
        follow.userScrolling = false
        follow.update(.init(offset: 1160, contentHeight: 2000, viewportHeight: 400))
        XCTAssertTrue(follow.followsTail)
        follow.userScrolling = true
        follow.update(.init(offset: 1100, contentHeight: 2000, viewportHeight: 400))
        XCTAssertFalse(follow.followsTail)
        follow.update(.init(offset: 1700, contentHeight: 2100, viewportHeight: 400))
        XCTAssertTrue(follow.followsTail, "A return gesture and layout growth in one frame must resume following")
    }
    func testProjectionRebuildsAffectedTurnAndMatchesFullTranscript() {
        let projection = AgentTranscriptProjection()
        var messages: [AgentMessage] = (0..<100).flatMap { i in
            [.init(id: "u\(i)", role: "user", text: "Question \(i)"), .init(id: "a\(i)", role: "assistant", text: "Answer \(i)")]
        }
        _ = projection.items(messages: messages, activities: [])
        messages[199].text += " streamed"
        XCTAssertEqual(projection.items(messages: messages, activities: []), AgentTranscript.items(messages: messages, activities: []))
        XCTAssertEqual(projection.rebuiltMessageCount, 2)
        _ = projection.items(messages: messages, activities: [])
        XCTAssertEqual(projection.rebuiltMessageCount, 0)
        var activities = [AgentActivity(id: "early", kind: "Read", detail: "early", afterMessageID: "a1")]
        XCTAssertEqual(projection.items(messages: messages, activities: activities), AgentTranscript.items(messages: messages, activities: activities))
        activities[0].output = "new output"
        XCTAssertEqual(projection.items(messages: messages, activities: activities), AgentTranscript.items(messages: messages, activities: activities))
        messages.removeLast(3)
        XCTAssertEqual(projection.items(messages: messages, activities: activities), AgentTranscript.items(messages: messages, activities: activities))
        XCTAssertEqual(projection.items(messages: [], activities: []), [])
    }
    func testLazyLayoutClampAfterReturningToTailDoesNotLookLikeAnUpwardGesture() {
        var follow = ChatFollowTailState()
        follow.followsTail = false; follow.userScrolling = true
        follow.update(.init(offset: 1070, contentHeight: 3103, viewportHeight: 473))
        follow.update(.init(offset: 2630, contentHeight: 3103, viewportHeight: 473))
        XCTAssertTrue(follow.followsTail)
        // Native LazyVStack resolves an estimate, then clamps in a separate callback.
        follow.update(.init(offset: 2630, contentHeight: 2915, viewportHeight: 473))
        follow.update(.init(offset: 2442, contentHeight: 2915, viewportHeight: 473))
        XCTAssertTrue(follow.followsTail)
        follow.update(.init(offset: 2442, contentHeight: 3051, viewportHeight: 473))
        XCTAssertTrue(follow.followsTail)
    }
    func testProjectionMovesUnlinkedActivityWithTheTailWithoutRetainingAnOldCopy() {
        for owner in [nil, "u0", "missing"] as [String?] {
            let projection = AgentTranscriptProjection()
            var messages = [AgentMessage(id: "u0", role: "user", text: "Question"), .init(id: "a0", role: "assistant", text: "Answer")]
            let activities = [AgentActivity(id: "preview-live", kind: "Command", detail: "Preview", afterMessageID: owner)]
            _ = projection.items(messages: messages, activities: activities)
            messages += [.init(id: "u1", role: "user", text: "Next"), .init(id: "a1", role: "assistant", text: "Next answer")]
            XCTAssertEqual(projection.items(messages: messages, activities: activities), AgentTranscript.items(messages: messages, activities: activities))
            messages[3].text += " streamed"
            XCTAssertEqual(projection.items(messages: messages, activities: activities), AgentTranscript.items(messages: messages, activities: activities))
        }
    }
    @MainActor func testSuccessfulRetryResolvesOnlyTheRetriedError() async throws {
        let (_, agent, backend) = try fixture(); try await connect(agent, backend)
        backend.onEvent?(.failure("provider overload"))
        backend.onEvent?(.notice("Provider retry 1: provider overload"))
        backend.onEvent?(.retrySucceeded)
        XCTAssertNil(agent.current.error); XCTAssertNil(agent.current.notice)
        backend.onEvent?(.failure("provider overload"))
        backend.onEvent?(.notice("Provider retry 2: provider overload"))
        backend.onEvent?(.failure("unrelated extension failure"))
        backend.onEvent?(.retrySucceeded)
        XCTAssertEqual(agent.current.error, "unrelated extension failure")
    }
    @MainActor func testImportedNativeFailureIsVisibleWithoutAnExistingCachedError() async throws {
        let (_, agent, backend) = try fixture()
        backend.history = .init(messages: [.init(id: "failed", role: "assistant", text: "Partial answer")], error: "Saved provider failure")
        try await connect(agent, backend)
        XCTAssertEqual(agent.current.messages.last?.text, "Partial answer")
        XCTAssertEqual(agent.current.error, "Saved provider failure")
        XCTAssertEqual(agent.currentSession?.state, .error)
    }
    @MainActor func testRepeatedToolCallIDInDifferentMessagesKeepsBothOperationsAcrossHistory() async throws {
        let (_, agent, backend) = try fixture(); try await connect(agent, backend)
        var nativeMessages: [AgentMessage] = []
        var nativeActivities: [AgentActivity] = []
        for index in 1...2 {
            let user = AgentMessage(id: "u\(index)", role: "user", text: "Task \(index)", sourceID: "user-\(index)")
            let assistant = AgentMessage(id: "a\(index)", role: "assistant", text: "", blocks: [.init(id: "a\(index)-block-0", index: 0, kind: .activity, activityID: "reused-call")], sourceID: "assistant-\(index)")
            let activity = AgentActivity(id: "reused-call", kind: "Read", detail: "File \(index)", afterMessageID: assistant.id, output: "Output \(index)", status: .completed)
            nativeMessages += [user, assistant]; nativeActivities.append(activity)
            backend.onEvent?(.message(user)); backend.onEvent?(.message(assistant)); backend.onEvent?(.activity(activity))
        }
        XCTAssertEqual(agent.current.activities.count, 2)
        XCTAssertEqual(agent.current.activities.map(\.output), ["Output 1", "Output 2"])
        let before = AgentTranscript.items(messages: agent.current.messages, activities: agent.current.activities)
        XCTAssertEqual(before.compactMap(\.response).map { $0.activities.count }, [1, 1])
        backend.onEvent?(.history(.init(messages: nativeMessages, activities: nativeActivities)))
        XCTAssertEqual(AgentTranscript.items(messages: agent.current.messages, activities: agent.current.activities), before)
    }

}
