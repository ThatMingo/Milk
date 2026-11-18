import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// Regressions found while auditing the chat screen.
@MainActor final class ChatFollowTailTests: XCTestCase {
    /// A wheel gesture that overlaps a sidebar/divider animation must still count:
    /// live resize notifications jitter the viewport by sub-pixel amounts every frame.
    func testWheelIntentIsRecordedWhileViewportJittersSubPixel() {
        var follow = ChatFollowTailState()
        follow.userScrolling = true
        follow.update(.init(offset: 600, contentHeight: 1600, viewportHeight: 400))
        XCTAssertTrue(follow.followsTail)
        let jitters: [Double] = [400.4, 400.2, 400.6, 400.3, 400.1, 400.5]
        for (i, viewport) in jitters.enumerated() {
            follow.update(.init(offset: 600 - Double(i + 1) * 10, contentHeight: 1600, viewportHeight: viewport))
        }
        XCTAssertFalse(follow.followsTail, "five 10 pt wheel notches must release the tail even while the pane animates")
    }

    /// A genuine pane resize repositions the offset; that movement is still not the reader.
    func testRealPaneResizeIsStillNotReaderIntent() {
        var follow = ChatFollowTailState()
        follow.userScrolling = true
        follow.update(.init(offset: 1000, contentHeight: 1600, viewportHeight: 400))
        follow.update(.init(offset: 900, contentHeight: 1650, viewportHeight: 470))
        follow.update(.init(offset: 800, contentHeight: 1700, viewportHeight: 540))
        XCTAssertTrue(follow.followsTail, "a 70 pt viewport change is a resize, not a wheel gesture")
    }

    /// A duplicate row id must degrade to a layout quirk, not crash the transcript.
    func testDuplicateRowIDsDoNotCrashTheLayoutCommit() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = ChatTranscriptSession()
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        scroll.hasVerticalScroller = true; scroll.documentView = coordinator.document
        // Pin the scroller regime: an earlier suite can leave AppKit resolving the
        // legacy style, which reserves 17 pt and would trip the pane-width guard.
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        window.layoutIfNeeded(); window.displayIfNeeded()
        let row = ChatTranscriptRow(id: "duplicate", owner: "owner", order: [0], gap: 12, content: .notice("notice"))
        let parent = NativeChatTranscript(rows: [row, row], session: session, conversation: .init(),
                                          narrow: false, sessionID: 0, paneWidth: 700,
                                          remember: { _, _, _, _ in }, content: { AnyView(Text($0.id)) })
        let root: (ChatTranscriptRow) -> AnyView = { AnyView(Text($0.id)) }
        coordinator.update(parent, root: root)   // first commit
        coordinator.update(parent, root: root)   // second commit builds the old-row index from duplicates
        XCTAssertEqual(coordinator.lastRows.count, 2)
    }

    /// The turn header names the session's agent; Milk core must not hardcode a provider.
    func testHeaderTitleUsesTheSessionAgentNotAProviderConstant() {
        XCTAssertEqual(AgentResponseHeader.title(for: "Codex"), "Codex")
        XCTAssertEqual(AgentResponseHeader.title(for: nil), "Assistant", "no agent context must not claim a provider name")
        let turn = AgentResponseTurn(id: "turn-1")
        let host = NSHostingView(rootView: AnyView(AgentResponseHeader(response: turn, agentName: "Codex")))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        windowAppend(host)  // the view must lay out with a supplied name
    }

    private var windows: [NSWindow] = []
    private func windowAppend(_ view: NSView) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        window.layoutIfNeeded(); window.displayIfNeeded()
        windows.append(window)
    }

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }
}
