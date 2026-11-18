import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// Row views the transcript would build for these rows.
private struct WheelRowView: View {
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

/// TEMPORARY DIAGNOSTIC, not a regression test. A real mouse wheel delivers line-unit
/// events; this asks what one notch actually does to a streaming transcript.
@MainActor final class ChatWheelProbeTests: XCTestCase {
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

    private func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation, width: Double) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                            narrow: false, sessionID: 0, paneWidth: width, remember: { _, _, _, _ in },
                            content: { row in AnyView(WheelRowView(row: row)) })
    }

    /// One genuine AppKit wheel notch. `line` units are what a mouse wheel produces;
    /// `pixel` units are what a trackpad produces.
    private func notch(_ scroll: TranscriptScrollView, lines: Int32, precise: Bool) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
                                  wheel1: precise ? lines * 10 : lines, wheel2: 0, wheel3: 0),
              let native = NSEvent(cgEvent: event) else { return }
        print(String(format: "   event scrollingDeltaY %g precise %d lineScroll %g", native.scrollingDeltaY,
                     native.hasPreciseScrollingDeltas ? 1 : 0, scroll.verticalLineScroll))
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

    func testProbeMouseWheelNotchesWhileStreaming() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        // Stream the way the app does: a delta every ~40ms, tail pinned each time.
        for _ in 0..<20 {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text that keeps arriving at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
            spin(0.04)
        }
        print(String(format: "armed: offset %g max %g doc %g followsTail %d", coordinator.metrics.offset,
                     coordinator.maximumOffset, coordinator.document.frame.height, coordinator.follow.followsTail ? 1 : 0))
        XCTAssertTrue(coordinator.follow.followsTail)

        // A reader turning a mouse wheel at an ordinary rate: one notch, a pause long
        // enough for the input gesture to close, then the next notch. Output is still
        // streaming between notches.
        var previous = coordinator.metrics.offset
        for step in 1...10 {
            notch(scroll, lines: 1, precise: false)
            let moved = coordinator.metrics.offset - previous
            print(String(format: "notch %d offset %g (delta %g) max %g followsTail %d userScrolling %d upwardTravel %g",
                         step, coordinator.metrics.offset, moved, coordinator.maximumOffset,
                         coordinator.follow.followsTail ? 1 : 0, coordinator.follow.userScrolling ? 1 : 0,
                         coordinator.upwardTravelForProbe))
            previous = coordinator.metrics.offset
            // Output keeps arriving while the reader is scrolling.
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "More thinking text arriving. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
            spin(0.15)
            print(String(format: "   after commit: offset %g max %g followsTail %d", coordinator.metrics.offset,
                         coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0))
            previous = coordinator.metrics.offset
        }
        XCTAssertEqual(coordinator.follow.followsTail, false, "10 mouse-wheel notches upward should leave the tail")
    }


    /// A small jog the reader abandons must still be tolerated: the tail keeps
    /// following and the reader ends up back at the bottom.
    func testProbeSmallJogIsAbsorbed() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        for _ in 0..<6 {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
            spin(0.04)
        }
        notch(scroll, lines: 1, precise: false)          // 10pt up
        print(String(format: "jog: offset %g max %g followsTail %d", coordinator.metrics.offset, coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0))
        XCTAssertTrue(coordinator.follow.followsTail, "a one-notch jog must not stop following")
        spin(0.8)                                        // the reader stops
        live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "More thinking text. \n"))
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        print(String(format: "after hold: offset %g max %g followsTail %d", coordinator.metrics.offset, coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0))
        XCTAssertTrue(coordinator.follow.followsTail)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1, "an abandoned jog is absorbed by the tail")
    }

    /// Wheeling back down to the bottom must resume following.
    func testProbeWheelBackToBottomResumesFollow() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        for _ in 0..<8 {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
            spin(0.04)
        }
        for _ in 0..<8 { notch(scroll, lines: 1, precise: false); spin(0.15) }
        XCTAssertFalse(coordinator.follow.followsTail)
        let parked = coordinator.metrics.offset
        for _ in 0..<12 { notch(scroll, lines: -4, precise: false); spin(0.02) }
        spin(0.2)
        print(String(format: "back down: parked %g offset %g max %g followsTail %d", parked, coordinator.metrics.offset, coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0))
        XCTAssertTrue(coordinator.follow.followsTail, "wheeling back to the bottom must resume following")
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1)
        live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "More thinking text. \n"))
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1, "the tail did not resume pinning")
    }

    /// Keyboard scrolling is reader intent too: Page Up is honored, End comes back.
    func testProbeKeyboardIntent() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var live = live()
        var conversation = SessionConversation()
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        for _ in 0..<30 {
            live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "Thinking text at the tail. \n"))
            conversation.messages = [settled(), live]
            coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
            spin(0.04)
        }
        XCTAssertGreaterThan(coordinator.maximumOffset, 300, "fixture needs room to scroll")
        let bottom = coordinator.metrics.offset
        coordinator.keyboard(delta: -200, end: nil)      // Page Up equivalent
        print(String(format: "key up: offset %g from %g max %g followsTail %d", coordinator.metrics.offset, bottom, coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0))
        XCTAssertLessThan(coordinator.metrics.offset, bottom - 100)
        live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "More thinking text. \n"))
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        XCTAssertEqual(coordinator.metrics.offset, bottom - 200, accuracy: 1, "a keyboard scroll was stolen by the tail")
        coordinator.keyboard(delta: 0, end: true)        // End
        XCTAssertTrue(coordinator.follow.followsTail)
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1)
        live.apply(.init(messageID: "turn-2", index: 0, kind: .thinking, text: "More thinking text. \n"))
        conversation.messages = [settled(), live]
        coordinator.update(parent(session, conversation, width: 700), root: { AnyView(WheelRowView(row: $0)) })
        XCTAssertEqual(coordinator.metrics.offset, coordinator.maximumOffset, accuracy: 1, "End did not resume the tail")
    }

    override func tearDown() {
        observer.map { NotificationCenter.default.removeObserver($0) }
        observer = nil
        windows.removeAll()
        super.tearDown()
    }
}

extension NativeChatTranscript.Coordinator {
    /// Read-only view of the private travel accumulator for the probe.
    var upwardTravelForProbe: Double { follow.upwardTravelForProbe }
}

extension ChatFollowTailState {
    var upwardTravelForProbe: Double {
        Mirror(reflecting: self).children.first { $0.label == "upwardTravel" }.flatMap { $0.value as? Double } ?? -1
    }
}
