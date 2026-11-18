import XCTest
import AppKit
import SwiftUI
@testable import Milk

private struct WheelTestRowView: View {
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

/// A mouse wheel near the tail. The reader's own wheel must move the transcript, and a
/// layout commit that pins the bottom must not undo the gesture that is asking to leave.
@MainActor final class ChatWheelTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?

    private func makeFixture(width: CGFloat = 700, height: CGFloat = 420)
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
        scroll.travel = { [weak coordinator] up in coordinator?.travel(up) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        window.orderFrontRegardless()
        windows.append(window)
        window.layoutIfNeeded(); window.display(); window.displayIfNeeded()
        return (session, coordinator, scroll)
    }

    private func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                            narrow: false, sessionID: 0, paneWidth: 700, remember: { _, _, _, _ in },
                            content: { row in AnyView(WheelTestRowView(row: row)) })
    }
    private let root: (ChatTranscriptRow) -> AnyView = { AnyView(WheelTestRowView(row: $0)) }

    /// One genuine AppKit wheel notch in line units, which is what a mouse wheel sends:
    /// the transcript moves `verticalLineScroll` points per notch.
    private func notch(_ scroll: TranscriptScrollView, lines: Int32, precise: Bool = false) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
                                  wheel1: precise ? lines * 10 : lines, wheel2: 0, wheel3: 0),
              let native = NSEvent(cgEvent: event) else { return }
        scroll.scrollWheel(with: native)
    }
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private let answer = String(repeating: "A settled paragraph the reader can scroll through. ", count: 18)
    private func settled() -> AgentMessage {
        var settled = AgentMessage(id: "turn-1", role: "assistant", text: "")
        settled.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .text, text: answer)]
        return settled
    }
    private func live() -> AgentMessage {
        var live = AgentMessage(id: "turn-2", role: "assistant", text: "", streaming: true)
        live.blocks = [.init(id: "turn-2-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        return live
    }
    private func stream(_ live: inout AgentMessage, _ conversation: inout SessionConversation,
                        _ session: ChatTranscriptSession, _ coordinator: NativeChatTranscript.Coordinator, rounds: Int) {
        for _ in 0..<rounds {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text arriving at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation), root: root)
        }
    }

    /// Each notch has to move the reader, and the output arriving in between must not
    /// drag them back down to the new bottom.
    func testWheelNotchesAreNotUndoneByIncomingOutput() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        stream(&live, &conversation, session, coordinator, rounds: 20)
        XCTAssertTrue(coordinator.follow.followsTail)
        XCTAssertGreaterThan(coordinator.maximumOffset, 250, "fixture needs room to scroll")

        var previous = coordinator.metrics.offset
        var stolen = 0.0
        var moved = 0.0
        for _ in 0..<4 {
            notch(scroll, lines: 1)
            let afterNotch = coordinator.metrics.offset
            XCTAssertEqual(afterNotch, previous - scroll.verticalLineScroll, accuracy: 1,
                           "a wheel notch did not move the reader")
            moved += previous - afterNotch
            stream(&live, &conversation, session, coordinator, rounds: 1)
            // The reader keeps the position they asked for; only the tail moved.
            XCTAssertEqual(coordinator.metrics.offset, afterNotch, accuracy: 1,
                           "a layout commit dragged the reader back to the tail")
            stolen += coordinator.metrics.offset - afterNotch
            previous = coordinator.metrics.offset
            XCTAssertTrue(coordinator.follow.followsTail, "four notches are still inside the hysteresis band")
        }
        XCTAssertGreaterThan(moved, 30)
        XCTAssertEqual(stolen, 0, accuracy: 1)
        XCTAssertGreaterThan(coordinator.maximumOffset - coordinator.metrics.offset, 30,
                             "the reader should now be visibly above the tail")
    }

    /// Deliberate upward travel releases the tail, and it stays released while output
    /// keeps arriving.
    func testDeliberateUpwardGestureReleasesTheTailAndStaysReleased() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        stream(&live, &conversation, session, coordinator, rounds: 12)
        XCTAssertTrue(coordinator.follow.followsTail)

        // Notches with a pause between them: each gesture closes, the intent does not.
        var notches = 0
        while coordinator.follow.followsTail && notches < 12 {
            notch(scroll, lines: 1)
            notches += 1
            spin(0.15)
        }
        XCTAssertLessThan(notches, 8, "it took \(notches) wheel notches to leave the tail")
        XCTAssertGreaterThanOrEqual(CGFloat(notches) * scroll.verticalLineScroll, ChatFollowTailState.exitDistance)
        XCTAssertFalse(coordinator.follow.followsTail)

        let parked = coordinator.metrics.offset
        stream(&live, &conversation, session, coordinator, rounds: 6)
        XCTAssertEqual(coordinator.metrics.offset, parked, accuracy: 1, "streaming dragged a released reader to the tail")
        XCTAssertGreaterThan(coordinator.maximumOffset, parked + 100, "output stopped arriving")
        XCTAssertFalse(coordinator.follow.followsTail)
        coordinator.input(false)
        spin(0.3)
        XCTAssertFalse(coordinator.follow.followsTail, "closing the gesture re-adopted the tail")
    }

    /// The hysteresis still exists: a jog the reader abandons is absorbed and the tail
    /// keeps following.
    func testAbandonedJogIsAbsorbedByTheTail() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        stream(&live, &conversation, session, coordinator, rounds: 8)
        XCTAssertTrue(coordinator.follow.followsTail)

        notch(scroll, lines: 1)
        XCTAssertTrue(coordinator.follow.followsTail, "one notch must not stop following")
        XCTAssertLessThan(coordinator.metrics.offset, coordinator.maximumOffset, "the notch was not honored at all")

        spin(NativeChatTranscript.Coordinator.travelHoldWindow + 0.2)   // the reader stops
        stream(&live, &conversation, session, coordinator, rounds: 2)
        XCTAssertTrue(coordinator.follow.followsTail)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1,
                       "an abandoned jog left the reader floating above the tail")
    }

    /// Wheeling back down to the bottom resumes tail following, including its pinning.
    func testWheelingBackToTheBottomResumesFollowing() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        stream(&live, &conversation, session, coordinator, rounds: 12)
        for _ in 0..<8 { notch(scroll, lines: 1); spin(0.15) }
        XCTAssertFalse(coordinator.follow.followsTail)
        let parked = coordinator.metrics.offset
        XCTAssertGreaterThan(parked, 0)

        for _ in 0..<20 { notch(scroll, lines: -4); spin(0.02) }
        spin(0.3)
        XCTAssertTrue(coordinator.follow.followsTail, "returning to the bottom did not resume following")
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1)
        stream(&live, &conversation, session, coordinator, rounds: 3)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1,
                       "the tail stopped pinning after it was resumed")
    }

    /// Keyboard scrolling is the same kind of intent as the wheel.
    func testKeyboardScrollIsNotStolenByTheTail() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation), root: root)
        stream(&live, &conversation, session, coordinator, rounds: 30)
        XCTAssertGreaterThan(coordinator.maximumOffset, 300, "fixture needs room to scroll")
        let bottom = coordinator.metrics.offset

        coordinator.keyboard(delta: -200, end: nil)     // Page Up
        XCTAssertEqual(coordinator.metrics.offset, bottom - 200, accuracy: 1)
        XCTAssertFalse(coordinator.follow.followsTail)
        stream(&live, &conversation, session, coordinator, rounds: 3)
        XCTAssertEqual(coordinator.metrics.offset, bottom - 200, accuracy: 1, "the tail stole a keyboard scroll")

        coordinator.keyboard(delta: 0, end: true)       // End
        XCTAssertTrue(coordinator.follow.followsTail)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1)
        stream(&live, &conversation, session, coordinator, rounds: 3)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1,
                       "End did not put the reader back on the tail")
    }

    override func tearDown() {
        observer.map { NotificationCenter.default.removeObserver($0) }
        observer = nil
        // Releasing the window is enough; closing it mid-suite takes AppKit views out
        // from under a coordinator that is still laid out.
        windows.removeAll()
        super.tearDown()
    }
}
