import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// The native acceptance audit (`scripts/verify-chat-geometry.py`) reported a user
/// bubble that reserved 37 pt (one line) while the mounted text view laid out 38 pt
/// (two wrapped lines). `SelectableContent` had `widthTracksTextView = false` and
/// set its container width only during `sizeThatFits`, so the container width could
/// be left at whatever width a discarded layout negotiation last passed, not the
/// width the view actually ends up with. The audit measures `usedRect`, which is
/// what the reader sees.
@MainActor final class SelectableContentWidthTests: XCTestCase {
    private var window: NSWindow?

    private func mounted(_ content: SelectableContent, hostWidth: CGFloat) -> (reserved: Double, laidOut: Double, viewWidth: CGFloat) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.orderFrontRegardless()
            self.window = window
        }
        // Measure the way the transcript coordinator does: a hosting controller at the row width.
        let controller = NSHostingController(rootView: AnyView(content.fixedSize(horizontal: false, vertical: true)))
        controller.sizingOptions = []
        let reserved = Double(controller.sizeThatFits(in: .init(width: hostWidth, height: CGFloat.greatestFiniteMagnitude)).height)

        // Mount the way `materialize` does: a hosting view at exactly the measured height.
        let host = NSHostingView(rootView: AnyView(content.fixedSize(horizontal: false, vertical: true)))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: hostWidth, height: max(1, reserved))
        window!.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        window!.layoutIfNeeded(); window!.displayIfNeeded()
        defer { host.removeFromSuperview() }

        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        guard let text = textViews(host).first, let container = text.textContainer, let manager = text.layoutManager else {
            XCTFail("no text view mounted")
            return (reserved, 0, 0)
        }
        manager.ensureLayout(for: container)
        var laid = Double(manager.usedRect(for: container).height)
        let extra = manager.extraLineFragmentRect
        if text.string.hasSuffix("\n") && !extra.isEmpty { laid -= Double(extra.height) }
        return (reserved, laid, text.frame.width)
    }

    /// Mirror of `AgentUserMessageView` (private in the app): the transcript hosts this
    /// through `content(row).frame(maxWidth: .infinity, alignment: .leading).font(...)`
    /// and `Group { … }.fixedSize(horizontal: false, vertical: true)`.
    private struct UserBubbleMirror: View {
        let text: String
        var body: some View {
            HStack {
                Spacer(minLength: 100)
                SelectableContent(text: text).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 568, alignment: .leading)
                    .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    func testUserBubbleAtHostWidth720LaysOutAsMeasured() {
        // "grouped-fixture" fits one line at the resolved bubble width; a narrow stale
        // container would hyphen-wrap it into two lines taller than the reserved row.
        for text in ["grouped-fixture", "simple answer 8", "chat-scroll-fixture"] {
            let result = mountedMirror(UserBubbleMirror(text: text), hostWidth: 720)
            XCTAssertLessThanOrEqual(result.laidOut, result.reserved + 0.5,
                                     "user bubble '\(text)': reserved \(result.reserved) but laid out \(result.laidOut) at text width \(result.viewWidth)")
        }
    }

    private func mountedMirror(_ view: some View, hostWidth: CGFloat) -> (reserved: Double, laidOut: Double, viewWidth: CGFloat) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.orderFrontRegardless()
            self.window = window
        }
        let rootView = { AnyView(view.frame(maxWidth: .infinity, alignment: .leading).font(.system(size: 13)).foregroundStyle(MilkTheme.ink)) }
        let controller = NSHostingController(rootView: rootView())
        controller.sizingOptions = []
        let reserved = Double(controller.sizeThatFits(in: .init(width: hostWidth, height: CGFloat.greatestFiniteMagnitude)).height)
        let host = NSHostingView(rootView: rootView())
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: hostWidth, height: max(1, reserved))
        window!.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        window!.layoutIfNeeded(); window!.displayIfNeeded()
        defer { host.removeFromSuperview() }
        func textViews(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
        guard let text = textViews(host).first, let container = text.textContainer, let manager = text.layoutManager else {
            XCTFail("no text view mounted"); return (reserved, 0, 0)
        }
        manager.ensureLayout(for: container)
        let laid = Double(manager.usedRect(for: container).height)
        return (reserved, laid, text.frame.width)
    }

    func testMountedTextNeverExceedsTheHostWidthItWasMeasuredAt() {
        // A short line at 720 reserves one line; a stale narrow container would wrap it.
        for text in ["simple answer 8", "grouped-fixture", String(repeating: "a medium length prompt for the user bubble. ", count: 6)] {
            let result = mounted(SelectableContent(text: text), hostWidth: 720)
            XCTAssertLessThanOrEqual(result.laidOut, result.reserved + 0.5,
                                     "'\(text.prefix(28))': reserved \(result.reserved) but mounted text laid out \(result.laidOut) at view width \(result.viewWidth)")
        }
    }

    /// The container must agree with the view at the resolved width even though
    /// layout negotiation proposes other widths (including tiny probes) on the way.
    func testContainerTracksNegotiatedWidths() {
        let controller = NSHostingController(rootView: AnyView(
            SelectableContent(text: String(repeating: "negotiation must leave the container at the resolved width. ", count: 10))
                .fixedSize(horizontal: false, vertical: true)))
        controller.sizingOptions = []
        // Ideal queries probe other widths before the final layout proposes 640.
        _ = controller.sizeThatFits(in: .init(width: 10, height: CGFloat.greatestFiniteMagnitude))
        _ = controller.sizeThatFits(in: .init(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.orderFrontRegardless()
            self.window = window
        }
        window!.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        defer { view.removeFromSuperview() }
        func textViews(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
        guard let text = textViews(view).first, let container = text.textContainer else { return XCTFail("no text view") }
        XCTAssertEqual(container.size.width, text.frame.width, accuracy: 1.0,
                       "container width \(container.size.width) disagrees with the text view width \(text.frame.width)")
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }
}
