import XCTest
import AppKit
import SwiftUI
@testable import Milk

private struct ScrollerRowView: View {
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

/// The transcript scrollbar belongs to the reader. It appears when they scroll and goes
/// away when they stop; streamed output and layout commits never earn it.
@MainActor final class ChatScrollerTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?

    private func makeFixture(width: CGFloat = 700, height: CGFloat = 420)
        -> (ChatTranscriptSession, NativeChatTranscript.Coordinator, TranscriptScrollView, TranscriptScroller) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = ChatTranscriptSession()
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        let scroller = TranscriptScroller()
        scroller.scrollerStyle = .overlay
        scroller.input = { [weak coordinator] active in coordinator?.input(active) }
        scroll.verticalScroller = scroller
        scroller.setMilkHidden(true)
        scroll.documentView = coordinator.document
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(scroll)
        scroll.changed = { [weak coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator] active in coordinator?.input(active) }
        scroll.travel = { [weak coordinator] up in coordinator?.travel(up) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        window.orderFrontRegardless()
        windows.append(window)
        window.layoutIfNeeded(); window.display(); window.displayIfNeeded()
        return (session, coordinator, scroll, scroller)
    }

    private func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                            narrow: false, sessionID: 0, paneWidth: 700, remember: { _, _, _, _ in },
                            content: { row in AnyView(ScrollerRowView(row: row)) })
    }
    private let root: (ChatTranscriptRow) -> AnyView = { AnyView(ScrollerRowView(row: $0)) }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func notch(_ scroll: TranscriptScrollView, lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let native = NSEvent(cgEvent: event) else { return }
        scroll.scrollWheel(with: native)
    }

    private let answer = String(repeating: "A settled paragraph the reader can scroll through. ", count: 18)
    private func settled() -> AgentMessage {
        var settled = AgentMessage(id: "turn-1", role: "assistant", text: "")
        settled.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: answer)]
        return settled
    }
    private func stream(_ session: ChatTranscriptSession, _ coordinator: NativeChatTranscript.Coordinator, rounds: Int,
                        revealSpike: inout CGFloat) {
        var live = AgentMessage(id: "turn-2", role: "assistant", text: "", streaming: true)
        live.blocks = [.init(id: "turn-2-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        for _ in 0..<rounds {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text arriving at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation), root: root)
            if let scroller = coordinator.scroll?.verticalScroller {
                revealSpike = max(revealSpike, CGFloat(scroller.isHidden ? 0 : scroller.alphaValue))
            }
            spin(0.03)
        }
    }

    /// Streamed output must not keep the bar up for the whole answer.
    func testStreamingOutputDoesNotRevealTheScrollbar() {
        let (session, coordinator, _, scroller) = makeFixture()
        session.choices["turn-1"] = true
        var revealSpike: CGFloat = 0
        stream(session, coordinator, rounds: 24, revealSpike: &revealSpike)
        XCTAssertGreaterThan(coordinator.maximumOffset, 200, "fixture needs a scrollable transcript")
        print("DEBUG sameScroller=", coordinator.scroll?.verticalScroller === scroller, "isHidden=", scroller.isHidden, "alpha=", scroller.alphaValue, "type=", String(describing: coordinator.scroll?.verticalScroller.map { type(of: $0) }))
        XCTAssertEqual(revealSpike, 0, accuracy: 0.01, "a layout commit revealed the scrollbar")
        XCTAssertTrue(scroller.isHidden, "the scrollbar stayed visible with no reader gesture")
        XCTAssertEqual(scroller.alphaValue, 0, accuracy: 0.01)
    }

    /// A reader gesture shows it, and it goes back away on its own.
    func testReaderGestureRevealsTheScrollbarAndItFadesBack() {
        let (session, coordinator, scroll, scroller) = makeFixture()
        session.choices["turn-1"] = true
        var revealSpike: CGFloat = 0
        stream(session, coordinator, rounds: 8, revealSpike: &revealSpike)
        XCTAssertTrue(scroller.isHidden)

        notch(scroll, lines: 2)
        spin(0.3)                                  // past the reveal animation
        XCTAssertFalse(scroller.isHidden, "the reader scrolled and the bar never appeared")
        XCTAssertEqual(scroller.alphaValue, 1, accuracy: 0.05)

        spin(ChatScrollerVisibility.visibleFor + ChatScrollerVisibility.fadeDuration + 0.6)
        XCTAssertTrue(scroller.isHidden, "the scrollbar never went back away")
        XCTAssertEqual(scroller.alphaValue, 0, accuracy: 0.02)
    }

    /// While revealed it is a real scroller that tracks the reader's position.
    func testRevealedScrollbarTracksTheReader() {
        let (session, coordinator, scroll, scroller) = makeFixture()
        session.choices["turn-1"] = true
        var revealSpike: CGFloat = 0
        stream(session, coordinator, rounds: 12, revealSpike: &revealSpike)
        notch(scroll, lines: 4)
        spin(0.3)
        XCTAssertFalse(scroller.isHidden)
        XCTAssertGreaterThan(scroller.knobProportion, 0.01, "the knob has no size")
        XCTAssertLessThan(scroller.knobProportion, 0.99)
        let expected = coordinator.metrics.offset / max(1, coordinator.maximumOffset)
        XCTAssertEqual(scroller.doubleValue, expected, accuracy: 0.05, "the knob does not track the reader")

        notch(scroll, lines: 6)
        spin(0.2)
        XCTAssertGreaterThan(coordinator.metrics.offset, 0)
        XCTAssertLessThan(scroller.doubleValue, expected + 0.01, "the knob moved the wrong way")
    }

    /// Auto-hiding must not change the transcript layout: an overlay scroller reserves no
    /// width, so hiding it cannot reflow the content.
    func testHidingTheScrollbarDoesNotMoveTheContent() {
        let (session, coordinator, scroll, scroller) = makeFixture()
        session.choices["turn-1"] = true
        var revealSpike: CGFloat = 0
        stream(session, coordinator, rounds: 10, revealSpike: &revealSpike)
        let hiddenHosts = coordinator.hosts.values.map { ($0.frame.width, $0.frame.minY) }
        let hiddenContentWidth = coordinator.hosts.values.map(\.frame.width).first ?? 0

        notch(scroll, lines: 3)
        spin(0.3)
        XCTAssertFalse(scroller.isHidden)
        let shownHosts = coordinator.hosts.values.map { ($0.frame.width, $0.frame.minY) }
        XCTAssertEqual(Set(shownHosts.map(\.0)), Set(hiddenHosts.map(\.0)), "revealing the bar changed content width")
        XCTAssertEqual(Set(shownHosts.map(\.1)), Set(hiddenHosts.map(\.1)), "revealing the bar moved content")
        XCTAssertGreaterThan(hiddenContentWidth, 300)
        XCTAssertEqual(scroll.contentView.bounds.width, 700, accuracy: 0.5, "an overlay scroller reserved layout width")
    }

    /// The visibility rule itself, independent of AppKit animation.
    func testVisibilityWindowIsBounded() {
        var visibility = ChatScrollerVisibility()
        let now = Date()
        XCTAssertFalse(visibility.isRevealed(at: now), "the bar starts revealed")
        visibility.noteGesture(at: now.addingTimeInterval(-10))
        XCTAssertFalse(visibility.isRevealed(at: now))
        XCTAssertEqual(visibility.fadeDelay, 0, accuracy: 0.001, "an expired gesture must not schedule a hold")
        visibility.noteGesture(at: now)
        XCTAssertTrue(visibility.isRevealed(at: now))
        XCTAssertTrue(visibility.isRevealed(at: now.addingTimeInterval(ChatScrollerVisibility.visibleFor - 0.1)))
        XCTAssertFalse(visibility.isRevealed(at: now.addingTimeInterval(ChatScrollerVisibility.visibleFor + 0.1)))
        visibility.noteGesture()
        XCTAssertEqual(visibility.fadeDelay, ChatScrollerVisibility.visibleFor, accuracy: 0.1)
    }

    override func tearDown() {
        observer.map { NotificationCenter.default.removeObserver($0) }
        observer = nil
        windows.removeAll()
        super.tearDown()
    }
}
