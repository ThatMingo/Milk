import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// Transcript memory and reading-position regressions: what a long live session
/// retains, and what the transcript does when layout changes underneath a reader.
private struct ChatMemoryRowView: View {
    let row: ChatTranscriptRow
    var body: some View {
        Group {
            switch row.content {
            case .user(let message): SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
            case .header(let turn): AgentResponseHeader(response: turn)
            case .markdown(let block, _): AgentMarkdownPiece(block: block).font(.system(size: 14)).textSelection(.enabled)
            case .thinking(let block, let label, let expanded, let active):
                AgentThinkingContent(block: block, label: label, expanded: expanded, active: active, toggle: {})
            case .activity(let steps, let expanded, let outputs, let thoughts):
                AgentActivityGroupContent(steps: steps, expanded: expanded, outputs: outputs, thoughts: thoughts,
                    toggle: {}, toggleOutput: { _ in }, toggleThinking: { _ in })
            case .changes: Text("changed")
            case .empty(let text): SelectableContent(text: text).fixedSize(horizontal: false, vertical: true)
            case .notice(let text): Text(text)
            case .error(let text): Text(text)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private func memoryCoordinator(width: CGFloat = 700, height: CGFloat = 600) -> (NativeChatTranscript.Coordinator, TranscriptScrollView) {
    let coordinator = NativeChatTranscript.Coordinator()
    let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    scroll.documentView = coordinator.document
    coordinator.scroll = scroll
    return (coordinator, scroll)
}

@MainActor private func memoryParent(_ session: ChatTranscriptSession, _ conversation: SessionConversation) -> NativeChatTranscript {
    NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                         narrow: false, sessionID: 0, paneWidth: 700, remember: { _, _, _, _ in },
                         content: { row in AnyView(ChatMemoryRowView(row: row)) })
}

private func settledMemoryConversation(_ message: AgentMessage) -> SessionConversation {
    var conversation = SessionConversation()
    var done = message
    done.streaming = false
    done.blocks = done.blocks?.map { var block = $0; block.streaming = false; return block }
    conversation.messages = [done]
    return conversation
}

private func memoryThinking(_ count: Int) -> String {
    String(repeating: "Reasoning about the fixture with a long sentence. \n", count: count)
}

final class ChatMemoryTests: XCTestCase {
    @MainActor private func streamText(kind: AgentContentBlock.Kind, frames: Int) -> (session: ChatTranscriptSession, coordinator: NativeChatTranscript.Coordinator, markdownCacheEntries: Int, cacheBytes: Int, documentHeight: Double) {
        let session = ChatTranscriptSession()
        let (coordinator, scroll) = memoryCoordinator()
        var conversation = SessionConversation()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: kind, text: "", streaming: true)]
        conversation.messages = [message]
        if kind == .thinking { session.choices["turn-1"] = true }
        var peakEntries = 0, peakBytes = 0
        let chunk = "The quick brown fox jumps over the lazy dog and keeps going. "
        for frame in 0..<frames {
            for _ in 0..<8 {
                let index = message.blocks?.firstIndex(where: \.streaming) ?? 0
                message.apply(.init(messageID: message.id, index: index, kind: kind, text: chunk + String(frame) + " "))
            }
            conversation.messages = [message]
            coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
            peakEntries = max(peakEntries, session.markdownHeights.count)
            peakBytes = max(peakBytes, session.markdownHeights.retainedBytes)
            scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
        }
        return (session, coordinator, peakEntries, peakBytes, coordinator.document.frame.height)
    }

    /// A live Markdown stream used to retain a cache entry for every intermediate
    /// prefix of the response; it must retain none of them.
    @MainActor func testStreamingMarkdownRetainsNoHeightCacheEntries() {
        let result = streamText(kind: .text, frames: 200)
        XCTAssertGreaterThan(result.documentHeight, 5_000)
        XCTAssertEqual(result.markdownCacheEntries, 0)
        XCTAssertEqual(result.cacheBytes, 0)
        XCTAssertEqual(result.session.markdownHeights.count, 0)
        XCTAssertEqual(result.session.heights.count, 2, "measurements exist only for rows that still exist")
    }

    /// Streaming Thinking is one growing piece: measurement must not accumulate
    /// per-frame views, hosts, or cache keys.
    @MainActor func testStreamingThinkingKeepsRenderStateBounded() {
        let result = streamText(kind: .thinking, frames: 120)
        XCTAssertGreaterThan(result.documentHeight, 5_000)
        XCTAssertLessThanOrEqual(result.markdownCacheEntries, ChatMarkdownHeightCache.entryLimit)
        XCTAssertLessThanOrEqual(result.cacheBytes, ChatMarkdownHeightCache.characterLimit)
        XCTAssertLessThanOrEqual(result.coordinator.measuring.count, 10, "measurement hosts must be reused per content kind")
        XCTAssertLessThan(result.coordinator.hosts.count, 20, "only the viewport plus overscan is mounted")
    }

    /// Settled pieces are shared, but within an explicit budget.
    @MainActor func testSettledMarkdownHeightCacheIsBounded() {
        let session = ChatTranscriptSession()
        let (coordinator, _) = memoryCoordinator()
        var conversation = SessionConversation()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "")
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: AgentMarkdownMemory.answer)]
        conversation.messages = [message]
        coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        XCTAssertGreaterThan(session.markdownHeights.count, 0, "settled pieces share measurements")
        XCTAssertLessThanOrEqual(session.markdownHeights.count, ChatMarkdownHeightCache.entryLimit)
        XCTAssertLessThanOrEqual(session.markdownHeights.retainedBytes, ChatMarkdownHeightCache.characterLimit)
    }

    @MainActor func testMarkdownHeightCacheEvictsOldestAndIgnoresOversizedPieces() {
        var cache = ChatMarkdownHeightCache()
        for index in 0..<(ChatMarkdownHeightCache.entryLimit + 20) {
            cache.setHeight(Double(10 + index), at: 600, for: .paragraph("Piece \(index)"))
        }
        XCTAssertEqual(cache.count, ChatMarkdownHeightCache.entryLimit)
        XCTAssertNotNil(cache.height(at: 600, for: .paragraph("Piece \(ChatMarkdownHeightCache.entryLimit + 19)")))
        XCTAssertNil(cache.height(at: 600, for: .paragraph("Piece 0")), "the oldest piece is evicted first")
        let oversized = String(repeating: "x", count: ChatMarkdownHeightCache.characterLimit + 1)
        cache.setHeight(4000, at: 600, for: .paragraph(oversized))
        XCTAssertNil(cache.height(at: 600, for: .paragraph(oversized)), "one oversized piece is measured on demand")
        XCTAssertEqual(cache.count, ChatMarkdownHeightCache.entryLimit)

        // Retained-text budget wins over the entry budget.
        var heavy = ChatMarkdownHeightCache()
        let big = String(repeating: "y", count: 4_096)
        for index in 0..<60 { heavy.setHeight(Double(index), at: 600, for: .paragraph(big + " \(index)")) }
        XCTAssertLessThanOrEqual(heavy.retainedBytes, ChatMarkdownHeightCache.characterLimit)
        XCTAssertLessThan(heavy.count, ChatMarkdownHeightCache.entryLimit)

        // Only the newest widths survive.
        var multi = ChatMarkdownHeightCache()
        for width in stride(from: 300.0, through: 900.0, by: 50) { multi.setHeight(12, at: width, for: .paragraph("Shared")) }
        XCTAssertLessThanOrEqual(multi.widths.count, ChatMarkdownHeightCache.widthLimit)
        XCTAssertNotNil(multi.height(at: 900, for: .paragraph("Shared")))
        XCTAssertNil(multi.height(at: 300, for: .paragraph("Shared")))
    }

    /// A render session must be able to forget geometry without forgetting what
    /// the reader opened.
    @MainActor func testReleaseGeometryForgetsMeasurementsButKeepsDisclosures() {
        let session = ChatTranscriptSession()
        var conversation = SessionConversation()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "")
        message.blocks = [
            .init(id: "turn-1-block-0", index: 0, kind: .thinking, text: memoryThinking(60)),
            .init(id: "turn-1-block-1", index: 1, kind: .text, text: AgentMarkdownMemory.answer),
        ]
        conversation.messages = [message]
        session.choices["turn-1"] = true
        let rows = session.rows(conversation, empty: "")
        XCTAssertGreaterThan(session.retainedBytes, 0)
        session.heights = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, ($0.content, 636, 120)) })
        XCTAssertFalse(session.heights.isEmpty)
        XCTAssertGreaterThan(session.projection.retainedBytes, 0)
        session.releaseGeometry()
        XCTAssertTrue(session.heights.isEmpty)
        XCTAssertTrue(session.markdownHeights.isEmpty)
        XCTAssertEqual(session.projection.retainedBytes, 0, "the projection must not keep its own transcript copy")
        XCTAssertEqual(session.choices["turn-1"], true, "disclosure choices outlive geometry eviction")
        // And the session still rebuilds the identical transcript afterwards.
        XCTAssertEqual(session.rows(conversation, empty: "").map(\.id), rows.map(\.id))
    }

    @MainActor func testStoreForgetsClosedSessionsAndEvictsUnrecentGeometry() {
        let store = ChatTranscriptStore()
        var conversation = SessionConversation()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: AgentMarkdownMemory.answer)
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: AgentMarkdownMemory.answer)]
        conversation.messages = [message]
        var measured: [Int: ChatTranscriptSession] = [:]
        for id in 1...6 {
            let session = store.session(id)
            session.rows(conversation, empty: "").forEach { session.heights[$0.id] = ($0.content, 636, 100) }
            measured[id] = session
        }
        XCTAssertEqual(store.retainedSessions, Set(1...6))
        XCTAssertFalse(measured[6]!.heights.isEmpty)
        XCTAssertTrue(measured[1]!.heights.isEmpty, "a session pushed out of recent use keeps no geometry")
        XCTAssertEqual(measured[1]!.markdownHeights.count, 0)
        XCTAssertEqual(measured[1]!.projection.retainedBytes, 0)
        XCTAssertFalse(measured[3]!.heights.isEmpty)

        store.retain(open: [5, 6])
        XCTAssertEqual(store.retainedSessions, Set([5, 6]))
        // A re-opened closed session starts from empty state, not stale geometry.
        let reopened = store.session(7)
        XCTAssertTrue(reopened.heights.isEmpty)
        XCTAssertTrue(reopened.choices.isEmpty)
    }

    /// The document position under the viewport's top edge, by stable piece identity.
    @MainActor private func readingPoint(_ coordinator: NativeChatTranscript.Coordinator, offset: Double) -> (id: String, held: Double) {
        guard let anchor = coordinator.layout.anchor(offset: offset) else { return ("", 0) }
        return (anchor.id, offset - (coordinator.layout.offset(id: anchor.id) ?? 0))
    }
    @MainActor private func heldPoint(_ coordinator: NativeChatTranscript.Coordinator, _ reading: (id: String, held: Double)) -> Double {
        (coordinator.layout.offset(id: reading.id) ?? -1) + reading.held
    }

    @MainActor private func disclosureFixture() -> (ChatTranscriptSession, NativeChatTranscript.Coordinator, TranscriptScrollView, SessionConversation) {
        let session = ChatTranscriptSession()
        let (coordinator, scroll) = memoryCoordinator()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "")
        message.blocks = [
            .init(id: "turn-1-block-0", index: 0, kind: .thinking, text: memoryThinking(160)),
            .init(id: "turn-1-block-1", index: 1, kind: .text, text: AgentMarkdownMemory.answer),
        ]
        let conversation = settledMemoryConversation(message)
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        return (session, coordinator, scroll, conversation)
    }

    /// Expanding Thinking changes layout without moving the tail, so the reader
    /// keeps the text they were looking at instead of being pulled to the bottom.
    @MainActor func testDisclosureKeepsTheVisiblePiecePut() {
        let (session, coordinator, scroll, conversation) = disclosureFixture()
        XCTAssertTrue(coordinator.follow.followsTail)
        let offset = scroll.contentView.bounds.minY
        let height = coordinator.document.frame.height
        XCTAssertGreaterThan(height, scroll.contentView.bounds.height * 2, "fixture needs room to scroll")
        let reading = readingPoint(coordinator, offset: offset)
        session.choices["turn-1"] = true
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        let grew = coordinator.document.frame.height - height
        XCTAssertGreaterThan(grew, 1_000, "expanding Thinking grows the document")
        XCTAssertEqual(heldPoint(coordinator, reading), scroll.contentView.bounds.minY, accuracy: 1, "the visible text did not move")
        // Follow survives exactly when the kept position still is the bottom.
        let distance = coordinator.maximumOffset - scroll.contentView.bounds.minY
        XCTAssertEqual(coordinator.follow.followsTail, distance < 24)

        // Collapse again: the same piece is still under the reader's eye.
        session.choices["turn-1"] = false
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        XCTAssertEqual(heldPoint(coordinator, reading), scroll.contentView.bounds.minY, accuracy: 1)
        XCTAssertEqual(coordinator.document.frame.height, height, accuracy: 1)
    }

    /// Reading above the tail, a disclosure must not steal the viewport, and a
    /// collapse must not leave the reader floating in blank space.
    @MainActor func testDisclosureAboveTheReaderPreservesReadingPosition() {
        let (session, coordinator, scroll, conversation) = disclosureFixture()
        session.choices["turn-1"] = true
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        // Move up deliberately, ending in the middle of the answer.
        coordinator.input(true)
        scroll.contentView.scroll(to: .init(x: 0, y: max(0, scroll.contentView.bounds.minY - 1_200)))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()
        coordinator.input(false)
        XCTAssertFalse(coordinator.follow.followsTail)
        let reading = readingPoint(coordinator, offset: scroll.contentView.bounds.minY)
        session.choices["turn-1"] = false
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        XCTAssertEqual(heldPoint(coordinator, reading), scroll.contentView.bounds.minY, accuracy: 1, "collapse moved the reader with the layout, not to the tail")
        XCTAssertFalse(coordinator.follow.followsTail)
        XCTAssertGreaterThan(coordinator.maximumOffset - scroll.contentView.bounds.minY, 100)

        // Growth that is genuinely the tail still follows while the reader is below it.
        var live = conversation
        live.messages[0].blocks?[1].streaming = true
        live.messages[0].apply(.init(messageID: "turn-1", index: 1, kind: .text, text: String(repeating: "Appended stream text. ", count: 60)))
        _ = coordinator.update(memoryParent(session, live), root: { AnyView(ChatMemoryRowView(row: $0)) })
        XCTAssertFalse(coordinator.follow.followsTail, "tail growth must not drag a reader above it")
        XCTAssertEqual(heldPoint(coordinator, reading), scroll.contentView.bounds.minY, accuracy: 1)
    }

    @MainActor func testTailGrowthPinsTheBottomOnlyWhileFollowing() {
        let session = ChatTranscriptSession()
        let (coordinator, scroll) = memoryCoordinator()
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: String(repeating: "First paragraph. ", count: 80), streaming: true)]
        var conversation = SessionConversation()
        conversation.messages = [message]
        conversation.followsTail = true
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()

        for round in 0..<6 {
            message.apply(.init(messageID: message.id, index: 0, kind: .text, text: String(repeating: "Growing \(round). ", count: 40)))
            conversation.messages = [message]
            _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
            scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
            XCTAssertEqual(scroll.contentView.bounds.minY, coordinator.maximumOffset, accuracy: 1)
            XCTAssertTrue(coordinator.follow.followsTail)
        }

        coordinator.input(true)
        scroll.contentView.scroll(to: .init(x: 0, y: scroll.contentView.bounds.minY - 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()
        coordinator.input(false)
        XCTAssertFalse(coordinator.follow.followsTail)
        let held = scroll.contentView.bounds.minY
        message.apply(.init(messageID: message.id, index: 0, kind: .text, text: String(repeating: "More stream text. ", count: 200)))
        conversation.messages = [message]
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        XCTAssertEqual(scroll.contentView.bounds.minY, held, accuracy: 1, "streaming did not pull the reader back down")
    }

    /// A trailing newline lays out no line fragment; reserving one leaves a blank
    /// band under every thinking block and tool output.
    @MainActor func testTrailingNewlineDoesNotReserveBlankLineHeight() {
        func height(_ text: String) -> CGFloat {
            let host = NSHostingController(rootView: AnyView(SelectableContent(text: text, size: 12).fixedSize(horizontal: false, vertical: true)))
            host.sizingOptions = []
            return host.sizeThatFits(in: .init(width: 400, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let body = String(repeating: "Reasoning sentence about the fixture. ", count: 40)
        XCTAssertEqual(height(body + "\n"), height(body), accuracy: 1)
        XCTAssertEqual(height(body + "\n\n"), height(body), accuracy: 1)
        XCTAssertGreaterThan(height(body), 100)
    }

    @MainActor func testVisibleCoverageAuditFindsHolesClippingAndBlankBands() {
        let (session, coordinator, scroll, conversation) = disclosureFixture()
        session.choices["turn-1"] = true
        _ = coordinator.update(memoryParent(session, conversation), root: { AnyView(ChatMemoryRowView(row: $0)) })
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()
        var audit = coordinator.visibleCoverageAudit()
        func value(_ key: String) -> Double { audit[key] as? Double ?? 0 }
        XCTAssertLessThanOrEqual(value("unmountedGap"), 40, "the viewport is covered by mounted pieces")
        XCTAssertLessThanOrEqual(value("clippedPoints"), 1, "native text fits the frame its height measured")
        XCTAssertLessThanOrEqual(value("trailingBlank"), 40, "measured height does not over-reserve blank space")
        XCTAssertGreaterThan(value("mounted"), 0)

        guard let host = coordinator.hosts["turn-1-block-0"] else { return XCTFail("expanded Thinking is not mounted") }
        let real = host.frame.height
        host.frame.size.height = real + 900
        audit = coordinator.visibleCoverageAudit()
        XCTAssertGreaterThan(value("trailingBlank"), 150, "a blank band inside a piece is reported")
        host.frame.size.height = real - 400
        audit = coordinator.visibleCoverageAudit()
        XCTAssertGreaterThan(value("clippedPoints"), 150, "text running past its frame is reported")
        host.frame.size.height = real
        host.removeFromSuperview()
        audit = coordinator.visibleCoverageAudit()
        XCTAssertGreaterThan(value("unmountedGap"), 400, "a hole in mounted coverage is reported")
    }
}

enum AgentMarkdownMemory {
    static var answer: String {
        (1...40).map { index in
            """
            ## Step \(index): inspect the request lifecycle

            The coordinator keeps **one stable response** while `request_\(index)` grows. This paragraph describes the real implementation tradeoff and includes enough ordinary text to wrap across multiple lines.

            - Keep the completed prefix intact.
            - Update only the active response tail.

            ```swift
            func handleRequest(input: String) async throws -> String { input }
            ```

            > Verify selection, scrolling, and readable code before moving on.
            """
        }.joined(separator: "\n")
    }
}
