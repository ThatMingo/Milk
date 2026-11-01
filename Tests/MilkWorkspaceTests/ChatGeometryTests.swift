import XCTest
import AppKit
import SwiftUI
@testable import Milk

final class ChatGeometryTests: XCTestCase {
    @MainActor func testProvisionalNativeWidthDoesNotConsumeSavedReadingOffset() {
        let session = ChatTranscriptSession()
        let row = ChatTranscriptRow(id: "row", owner: "turn", order: [0], gap: 22, content: .markdown(.paragraph("Fixture")))
        session.heights[row.id] = (row.content, 586, 2000)
        var conversation = SessionConversation()
        conversation.followsTail = false; conversation.scrollOffset = 77
        conversation.scrollWidth = 650; conversation.scrollAnchor = row.id
        let parent = NativeChatTranscript(rows: [row], session: session, conversation: conversation,
            narrow: false, sessionID: 0, paneWidth: 650, remember: { _, _, _, _ in }, content: { _ in AnyView(Text("Fixture")) })
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.documentView = coordinator.document; coordinator.scroll = scroll
        coordinator.update(parent, root: parent.content)
        XCTAssertFalse(coordinator.initialized)
        XCTAssertTrue(coordinator.layout.rows.isEmpty)
        scroll.frame.size.width = 650
        coordinator.update(parent, root: parent.content)
        XCTAssertTrue(coordinator.initialized)
        XCTAssertEqual(scroll.contentView.bounds.minY, 77, accuracy: 0.5)
        XCTAssertFalse(coordinator.follow.followsTail)
    }
    func testWheelQueriesNeverChangeDocumentExtentAndCoverViewport() {
        var layout = ChatTranscriptLayout()
        layout.replace((0..<16000).map { .init(id: "row-\($0)", owner: "turn-\($0 / 20)", height: Double(20 + ($0 % 7) * 13), gap: 10) })
        let extent = layout.height
        for offset in stride(from: 0.0, through: extent - 623, by: 25) {
            let range = layout.range(offset: offset, viewport: 623, overscan: 623)
            XCTAssertFalse(range.isEmpty)
            XCTAssertLessThan(range.count, 100)
            XCTAssertEqual(layout.height, extent)
            XCTAssertLessThanOrEqual(layout.origins[range.lowerBound], offset + 28)
            let last = range.upperBound - 1
            XCTAssertGreaterThanOrEqual(layout.origins[last] + layout.rows[last].height + 39, min(extent, offset + 623))
        }
    }
    func testAnchorSurvivesReflowByStablePieceIdentity() {
        var layout = ChatTranscriptLayout()
        layout.replace([.init(id: "a", owner: "turn", height: 100, gap: 22), .init(id: "b", owner: "turn", height: 200, gap: 10)])
        let anchor = layout.anchor(offset: 188)!
        XCTAssertEqual(anchor.id, "b")
        XCTAssertEqual(anchor.fraction, 0.25)
        layout.replace([.init(id: "a", owner: "turn", height: 200, gap: 22), .init(id: "b", owner: "turn", height: 400, gap: 10)])
        XCTAssertEqual(layout.offset(id: anchor.id, fraction: anchor.fraction), 338)
    }
    func testTailGrowthDoesNotMoveEarlierRows() {
        var layout = ChatTranscriptLayout()
        let prefix = ChatTranscriptLayout.Row(id: "old", owner: "old", height: 100, gap: 22)
        layout.replace([prefix, .init(id: "tail", owner: "tail", height: 50, gap: 22)])
        let y = layout.offset(id: "old", fraction: 0.5)
        layout.replace([prefix, .init(id: "tail", owner: "tail", height: 5000, gap: 22)])
        XCTAssertEqual(layout.offset(id: "old", fraction: 0.5), y)
        XCTAssertEqual(layout.height, 5189)
    }
    @MainActor func testProjectionPiecesKeepStableIDsOrderAndDisclosureAfterUnmount() {
        let session = ChatTranscriptSession()
        let message = AgentMessage(id: "assistant", role: "assistant", text: "# Title\n\nParagraph", blocks: [.init(id: "thought", index: 0, kind: .thinking, text: "Reasoning"), .init(id: "answer", index: 1, kind: .text, text: "# Title\n\nParagraph")])
        var conversation = SessionConversation(); conversation.messages = [message]
        let initial = session.rows(conversation, empty: "")
        XCTAssertEqual(initial.map(\.id), ["assistant", "thought", "answer-markdown-0", "answer-markdown-1"])
        session.choices["assistant"] = true
        _ = session.rows(.init(), empty: "")
        let restored = session.rows(conversation, empty: "")
        XCTAssertEqual(restored.map(\.id), initial.map(\.id))
        if case .thinking(_, _, let expanded, _) = restored[1].content { XCTAssertTrue(expanded) } else { XCTFail() }
        XCTAssertEqual(Set(restored.map(\.id)).count, restored.count)
        XCTAssertTrue(restored.allSatisfy { $0.owner == "assistant" })
    }
}
