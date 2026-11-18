import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// Row views the transcript would build for these rows, so measurement and mounting go
/// through the same content the app renders.
private struct ResizeRowView: View {
    let row: ChatTranscriptRow
    var body: some View {
        Group {
            switch row.content {
            case .user(let message): SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
            case .header(let turn): AgentResponseHeader(response: turn)
            case .markdown(let block, _): AgentMarkdownPiece(block: block).font(.system(size: 14)).textSelection(.enabled)
            case .thinking(let block, let label, let expanded, let active):
                AgentThinkingContent(block: block, label: label, expanded: expanded, active: active, toggle: {})
            case .activity(let activities, let expanded, let outputs):
                AgentActivityGroupContent(activities: activities, expanded: expanded, outputs: outputs, toggle: {}, toggleOutput: { _ in })
            case .changes: Text("changed")
            case .empty(let text): SelectableContent(text: text).fixedSize(horizontal: false, vertical: true)
            case .notice(let text): Text(text)
            case .error(let text): Text(text)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Dragging the chat pane hands the transcript a new bounds width on every frame. The
/// layout defers its full remeasure while that is happening; the deferral may only
/// postpone work the frame does not need. Output must keep appearing, and a piece must
/// never be handed a width its retained height does not fit.
@MainActor final class ChatResizeTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?

    /// A hosting view only materialises its NSViewRepresentable content once it is in a
    /// window and has been laid out, so the fixture keeps the transcript in an
    /// offscreen window and reads the real NSTextView layout.
    private func makeFixture(width: CGFloat = 700, height: CGFloat = 600)
        -> (ChatTranscriptSession, NativeChatTranscript.Coordinator, TranscriptScrollView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = ChatTranscriptSession()
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = coordinator.document
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(scroll)
        scroll.changed = { [weak coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator] active in coordinator?.input(active) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        window.orderFrontRegardless()
        windows.append(window)
        window.layoutIfNeeded(); window.display(); window.displayIfNeeded()
        return (session, coordinator, scroll)
    }

    private func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation, paneWidth: Double) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                             narrow: false, sessionID: 0, paneWidth: paneWidth, remember: { _, _, _, _ in },
                             content: { row in AnyView(ResizeRowView(row: row)) })
    }

    private let answerText = String(repeating: "The answer paragraph has to rewrap every time the pane width changes. ", count: 26)

    /// A settled answer plus a streaming Thinking block that keeps growing.
    private func settledAnswer() -> AgentMessage {
        var settled = AgentMessage(id: "turn-1", role: "assistant", text: "")
        settled.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: answerText)]
        return settled
    }
    private func streamingThinking() -> AgentMessage {
        var live = AgentMessage(id: "turn-2", role: "assistant", text: "", streaming: true)
        live.blocks = [.init(id: "turn-2-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        return live
    }

    private func drag(_ scroll: TranscriptScrollView, to width: CGFloat) {
        scroll.frame.size.width = width
        scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: width, height: scroll.contentView.bounds.height)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func auditFailures(_ audit: [String: Double], _ frame: Int) -> [String] {
        var failures: [String] = []
        if (audit["clippedPoints"] ?? 0) > 1 { failures.append("frame \(frame) text clipped by \((audit["clippedPoints"] ?? 0)-8): \(audit)") }
        if (audit["trailingBlank"] ?? 0) > 40 { failures.append("frame \(frame) blank band \((audit["trailingBlank"] ?? 0)): \(audit)") }
        if (audit["unmountedGap"] ?? 0) > 40 { failures.append("frame \(frame) unmounted band \((audit["unmountedGap"] ?? 0)): \(audit)") }
        return failures
    }

    /// While the pane is being dragged the transcript must keep rendering the output it
    /// receives, and every mounted piece must stay as tall as the text it lays out.
    func testDraggedPaneKeepsRenderingOutputAndNeverClipsMeasuredText() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        let settled = settledAnswer()
        var live = streamingThinking()
        var conversation = SessionConversation()
        conversation.messages = [settled, live]
        coordinator.update(parent(session, conversation, paneWidth: 700), root: { AnyView(ResizeRowView(row: $0)) })
        var failures: [String] = []
        let startHeight = coordinator.document.frame.height
        var previousDocumentHeight = startHeight
        var retainedWidth = coordinator.activeContentWidth
        for (frame, width) in stride(from: 690.0, through: 420.0, by: -5).enumerated() {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Streaming while the pane is dragged narrower. \n"))
            conversation.messages = [settled, live]
            drag(scroll, to: width)
            coordinator.update(parent(session, conversation, paneWidth: width), root: { AnyView(ResizeRowView(row: $0)) })
            scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
            let audit = coordinator.visibleCoverageAudit()
            failures += auditFailures(audit, frame)
            // A piece never gets a width its retained measurement does not belong to.
            if abs(coordinator.activeContentWidth - retainedWidth) > 0.5 {
                failures.append("frame \(frame) content width jumped \(retainedWidth) -> \(coordinator.activeContentWidth) mid-drag")
            }
            for (id, host) in coordinator.hosts where host.superview === coordinator.document {
                if abs(host.frame.width - coordinator.activeContentWidth) > 0.5 {
                    failures.append("frame \(frame) \(id) mounted at \(host.frame.width) but measurements are at \(coordinator.activeContentWidth)")
                }
            }
            // Output that arrived has to appear in the document the same frame.
            XCTAssertGreaterThanOrEqual(coordinator.document.frame.height, previousDocumentHeight,
                                        "frame \(frame) the document shrank while output arrived")
            previousDocumentHeight = coordinator.document.frame.height
        }
        XCTAssertGreaterThan(previousDocumentHeight, startHeight + 300, "streamed output was held back during the drag")
        XCTAssertTrue(failures.isEmpty, failures.prefix(8).description)
    }

    /// Once the pane stops moving the deferred measurement runs at the width the
    /// transcript actually has, and the reflowed heights fit the rewrapped text.
    func testRemeasureCommitsWhenThePaneStopsMoving() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var conversation = SessionConversation()
        conversation.messages = [settledAnswer(), streamingThinking()]
        coordinator.update(parent(session, conversation, paneWidth: 700), root: { AnyView(ResizeRowView(row: $0)) })
        let wideWidth = coordinator.activeContentWidth
        let wideHeights = Dictionary(uniqueKeysWithValues: coordinator.layout.rows.map { ($0.id, $0.height) })
        for width in stride(from: 690.0, through: 420.0, by: -5) { drag(scroll, to: width) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let narrowWidth = coordinator.activeContentWidth
        XCTAssertEqual(coordinator.width, 420, accuracy: 0.5)
        XCTAssertLessThan(narrowWidth, wideWidth - 100, "the deferred commit never measured at the new width")
        let narrowHeights = Dictionary(uniqueKeysWithValues: coordinator.layout.rows.map { ($0.id, $0.height) })
        for (id, wide) in wideHeights {
            guard let narrow = narrowHeights[id] else { XCTFail("\(id) disappeared from the layout"); continue }
            XCTAssertGreaterThanOrEqual(narrow, wide - 0.5, "\(id) got shorter while the column got narrower")
        }
        XCTAssertGreaterThanOrEqual(narrowHeights.values.reduce(0, +), wideHeights.values.reduce(0, +))
        // The tail is where the pinned offset says it is.
        scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()
        let audit = coordinator.visibleCoverageAudit()
        XCTAssertEqual(audit["clippedPoints"] ?? 0, 0, accuracy: 1.0, "\(audit)")
        XCTAssertEqual(audit["unmountedGap"] ?? 0, 0, accuracy: 1.0, "\(audit)")
        XCTAssertLessThan(audit["trailingBlank"] ?? 0, 40, "\(audit)")
    }

    /// A reader who scrolled up to a settled piece keeps reading that piece across a
    /// reflow. A resize that pushes the reader onto different output is drift.
    func testParkedReaderStaysOnTheirPieceThroughAReflow() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var conversation = SessionConversation()
        conversation.messages = [settledAnswer(), streamingThinking()]
        coordinator.update(parent(session, conversation, paneWidth: 700), root: { AnyView(ResizeRowView(row: $0)) })
        // Follow the tail for a while first: a wheel gesture is a run of scroll events
        // that starts from a position the transcript was holding.
        var live = streamingThinking()
        for _ in 0..<12 {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Streaming output that keeps the tail moving. \n"))
            conversation.messages = [settledAnswer(), live]
            coordinator.update(parent(session, conversation, paneWidth: 700), root: { AnyView(ResizeRowView(row: $0)) })
            scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
        }
        XCTAssertTrue(coordinator.follow.followsTail, "streaming at the bottom should keep following")
        coordinator.input(true)
        for _ in 0..<8 {
            scroll.contentView.scroll(to: .init(x: 0, y: max(0, scroll.contentView.bounds.minY - 40)))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
        }
        coordinator.input(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(coordinator.follow.followsTail, "scrolling up should release the tail")
        guard let anchorBefore = coordinator.layout.anchor(offset: coordinator.metrics.offset) else { return XCTFail("no anchor before the resize") }
        for width in stride(from: 690.0, through: 420.0, by: -5) { drag(scroll, to: width) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let offsetAfter = coordinator.metrics.offset
        let viewport = scroll.contentView.bounds.height
        XCTAssertFalse(coordinator.follow.followsTail, "a resize must not steal the tail back")
        XCTAssertLessThan(offsetAfter, viewport, "a parked reader should not be thrown down to the tail")
        guard let anchorAfter = coordinator.layout.anchor(offset: offsetAfter) else { return XCTFail("no anchor after the reflow") }
        XCTAssertEqual(anchorAfter.id, anchorBefore.id, "the reader moved from \(anchorBefore.id) to \(anchorAfter.id) during a resize")
        guard let originAfter = coordinator.layout.offset(id: anchorAfter.id) else { return XCTFail("the piece being read disappeared from the layout") }
        XCTAssertLessThan(abs(originAfter - offsetAfter), viewport * 0.5, "the piece being read is no longer near the top of the viewport")
        let audit = coordinator.visibleCoverageAudit()
        XCTAssertEqual(audit["clippedPoints"] ?? 0, 0, accuracy: 1.0, "\(audit)")
        XCTAssertEqual(audit["unmountedGap"] ?? 0, 0, accuracy: 1.0, "\(audit)")
    }


    override func tearDown() {
        observer.map { NotificationCenter.default.removeObserver($0) }
        observer = nil
        // The scroll view keeps the coordinator's document view alive; releasing the
        // window is enough. Closing it mid-suite takes AppKit views out from under a
        // coordinator that is still laid out.
        windows.removeAll()
        super.tearDown()
    }
}
