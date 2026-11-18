import XCTest
import AppKit
import SwiftUI
@testable import Milk

private struct CodeRowView: View {
    let row: ChatTranscriptRow
    var body: some View {
        Group {
            switch row.content {
            case .user(let message): SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
            case .header(let turn): AgentResponseHeader(response: turn)
            case .markdown(let block, _): AgentMarkdownPiece(block: block).font(.system(size: 14)).textSelection(.enabled)
            case .thinking: EmptyView()
            case .activity: EmptyView()
            case .changes: Text("changed")
            case .empty(let text): SelectableContent(text: text).fixedSize(horizontal: false, vertical: true)
            case .notice(let text): Text(text)
            case .error(let text): Text(text)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Code blocks in the transcript are wrapped native text, not a nested horizontal
/// scroll view: a nested NSScrollView drew its own visible horizontal bar inside
/// the chat and consumed wheel events, so the transcript could not be scrolled
/// while the pointer was over the block.
@MainActor final class ChatCodeBlockTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let longLine = String(repeating: "let transport = MilkAgentRPCChannel(configuration: .init(session: .live, telemetry: .disabled)) // one long unwrappable token stream for this assertion ", count: 4)
    private let prose = String(repeating: "A settled paragraph above the code block. ", count: 60)

    private func codeMessage() -> AgentMessage {
        var settled = AgentMessage(id: "turn-1", role: "assistant", text: "")
        settled.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text,
                                text: prose + "\n```swift\n" + longLine + "\n```")]
        return settled
    }

    private static func scrollViews(under view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { [$0 as? NSScrollView].compactMap { $0 } + scrollViews(under: $0) }
    }

    /// The rendered code piece hosts no nested scroll view of its own.
    func testCodePieceMountsNoNestedScrollView() {
        let host = NSHostingView(rootView: AnyView(AgentMarkdownPiece(block: .code(longLine))))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(Self.scrollViews(under: host).count, 0,
                       "a code block mounted a nested NSScrollView (its bar is visible in the chat and it eats wheel events)")
    }

    /// A code line wider than the row wraps into more lines instead of extending
    /// sideways: the measured height at a narrow width is several times the height
    /// at a wide width.
    func testLongCodeLineWrapsAtNarrowWidth() {
        let controller = NSHostingController(rootView: AnyView(AgentMarkdownPiece(block: .code(longLine))))
        controller.sizingOptions = []
        let wide = controller.sizeThatFits(in: .init(width: 640, height: CGFloat.greatestFiniteMagnitude)).height
        let narrow = controller.sizeThatFits(in: .init(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(wide, 20, "the code piece has no content")
        XCTAssertGreaterThan(narrow, wide * 1.8, "the same code did not grow when the width halved: it is scrolling sideways, not wrapping")
    }

    private func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                            narrow: false, sessionID: 0, paneWidth: 700, remember: { _, _, _, _ in },
                            content: { row in AnyView(CodeRowView(row: row)) })
    }
    private let root: (ChatTranscriptRow) -> AnyView = { AnyView(CodeRowView(row: $0)) }

    /// A real wheel gesture whose pointer lands on the code block still moves the
    /// transcript: the hit-test target is text, and the event reaches the transcript's
    /// own scroller through the responder chain.
    func testWheelOverTheCodeBlockScrollsTheTranscript() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = ChatTranscriptSession()
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.documentView = coordinator.document
        coordinator.scroll = scroll
        scroll.changed = { [weak coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator] in coordinator?.input($0) }
        scroll.travel = { [weak coordinator] in coordinator?.travel($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        window.contentView?.addSubview(scroll)
        windows.append(window)

        var conversation = SessionConversation()
        conversation.messages = [codeMessage()]
        let parent = self.parent(session, conversation)
        coordinator.update(parent, root: root)
        window.layoutIfNeeded(); window.displayIfNeeded()
        coordinator.update(parent, root: root)

        guard let codeRow = coordinator.lastRows.first(where: { row in
            if case .markdown(let block, _) = row.content { return block == .code(longLine) }
            return false
        }), case .markdown = codeRow.content else {
            return XCTFail("the transcript has no code piece")
        }
        guard let host = coordinator.hosts[codeRow.id] else { return XCTFail("the code piece is not mounted") }
        // The fixture needs a scrollable transcript with the code block inside the viewport.
        XCTAssertGreaterThan(coordinator.maximumOffset, 100, "fixture needs a scrollable transcript")
        XCTAssertTrue(host.frame.intersects(scroll.contentView.bounds), "the code block must be visible for this gesture test")

        let nested = Self.scrollViews(under: host)
        XCTAssertEqual(nested.count, 0, "the mounted code block still contains a nested NSScrollView")

        // The clip view is flipped and the scroll view is not: measure the block's
        // middle from the viewport top, then convert to the scroll view's own space.
        let fromTop = host.frame.midY - scroll.contentView.bounds.minY
        let point = NSPoint(x: host.frame.midX, y: scroll.bounds.height - fromTop)
        guard let hit = scroll.hitTest(point) else { return XCTFail("no hit target over the code block") }
        XCTAssertTrue(host == hit || hit.isDescendant(of: host), "hit test over the code block left the code piece")
        XCTAssertFalse(hit is NSScrollView, "the pointer over the code block is inside a scroll view: it would swallow the wheel")

        let before = coordinator.metrics.offset
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0),
              let native = NSEvent(cgEvent: event) else { return XCTFail("wheel event") }
        hit.scrollWheel(with: native)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThan(coordinator.metrics.offset, before - 20,
                          "a wheel gesture over the code block did not move the transcript")
    }

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }
}
