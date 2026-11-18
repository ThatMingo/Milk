import XCTest
import AppKit
@testable import Milk

/// TEMPORARY diagnostic, not a regression test: what actually makes the transcript's
/// overlay scroller visible, and what AppKit does when a *layout commit* scrolls it.
@MainActor final class ChatScrollerProbeTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func snapshot(_ scroller: NSScroller, _ label: String) {
        print("\(label): alpha \(String(format: "%.2f", scroller.alphaValue)) hidden \(scroller.isHidden ? 1 : 0) "
              + "knob \(String(format: "%.0f", scroller.knobProportion)) frame \(String(format: "%.0fx%.0f", scroller.frame.width, scroller.frame.height))")
    }

    func testProbeWhatRevealsTheOverlayScroller() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        let scroller = TranscriptScroller()
        scroller.scrollerStyle = .overlay
        scroll.verticalScroller = scroller
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 4000))
        document.autoresizingMask = [.width]
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        windows.append(window)
        window.layoutIfNeeded(); window.display(); window.displayIfNeeded()
        scroll.layoutSubtreeIfNeeded()

        snapshot(scroller, "mount")

        // A layout commit: exactly what the coordinator does on every stream flush.
        for step in 1...4 {
            scroll.contentView.scroll(to: .init(x: 0, y: Double(step) * 120))
            scroll.reflectScrolledClipView(scroll.contentView)
            spin(0.05); snapshot(scroller, "commit \(step) +0.05s")
        }
        spin(0.5); snapshot(scroller, "commit burst +0.5s")
        spin(1.5); snapshot(scroller, "commit burst +2.0s")
        spin(1.5); snapshot(scroller, "commit burst +3.5s")

        // A genuine wheel gesture.
        for _ in 0..<3 {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0),
                  let native = NSEvent(cgEvent: event) else { continue }
            scroll.scrollWheel(with: native)
            spin(0.02)
        }
        snapshot(scroller, "wheel +0.06s")
        spin(0.6); snapshot(scroller, "wheel +0.7s")
        spin(1.2); snapshot(scroller, "wheel +1.9s")
        spin(1.5); snapshot(scroller, "wheel +3.4s")

        // What a Milk-owned fade does, and whether AppKit reveals it again on the next commit.
        scroll.verticalScroller?.animator().alphaValue = 0
        spin(0.6); snapshot(scroller, "after fade +0.6s")
        scroll.contentView.scroll(to: .init(x: 0, y: 700)); scroll.reflectScrolledClipView(scroll.contentView)
        spin(0.05); snapshot(scroller, "commit after fade +0.05s")
        spin(0.6); snapshot(scroller, "commit after fade +0.65s")
        scroll.contentView.scroll(to: .init(x: 0, y: 900)); scroll.reflectScrolledClipView(scroll.contentView)
        spin(0.05); snapshot(scroller, "second commit after fade +0.05s")
        spin(1.0); snapshot(scroller, "second commit after fade +1.05s")

        XCTAssertTrue(true)
    }

    override func tearDown() { windows.removeAll(); super.tearDown() }
}
