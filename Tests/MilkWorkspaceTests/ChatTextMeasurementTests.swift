import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// The transcript reserves exactly the height a piece lays out. A string measured by a
/// different typesetter than the one that renders it is how a row ends up shorter than
/// its own text: nothing looks wrong until the reader scrolls and finds the tail
/// pinned to a document height that no longer matches the pieces inside it.
@MainActor final class ChatTextMeasurementTests: XCTestCase {
    private static let measureWidth: CGFloat = 460

    private static var window: NSWindow?
    private static func sharedWindow() -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let existing = window { return existing }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFrontRegardless()
        Self.window = window
        return window
    }

    /// A hosting controller is how the transcript measures a row, so the comparison is
    /// between that measurement and the text view the same content installs.
    private func measureAndLayOut(_ content: SelectableContent) -> (reserved: Double, laidOut: Double, usedRaw: Double) {
        let host = NSHostingController(rootView: AnyView(content.fixedSize(horizontal: false, vertical: true)))
        host.sizingOptions = []
        let reserved = Double(host.sizeThatFits(in: .init(width: Self.measureWidth, height: .greatestFiniteMagnitude)).height)
        let view = host.view
        view.frame = NSRect(x: 0, y: 0, width: Self.measureWidth, height: reserved)
        let window = Self.sharedWindow()
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded(); window.displayIfNeeded()
        defer { view.removeFromSuperview() }
        guard let text = Self.firstTextView(in: view), let container = text.textContainer, let manager = text.layoutManager else {
            XCTFail("no text view laid out for \(content.text.prefix(24))")
            return (reserved, 0, 0)
        }
        manager.ensureLayout(for: container)
        let usedRaw = Double(manager.usedRect(for: container).height)
        var laidOut = usedRaw
        let extra = manager.extraLineFragmentRect
        if !extra.isEmpty { laidOut -= Double(extra.height) }
        return (reserved, laidOut, usedRaw)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let text = firstTextView(in: sub) { return text } }
        return nil
    }

    private func assertFits(_ label: String, _ content: SelectableContent) {
        let result = measureAndLayOut(content)
        XCTAssertEqual(result.reserved, result.laidOut, accuracy: 1.0,
                       "\(label): reserved \(result.reserved) but the text view laid out \(result.laidOut) (raw \(result.usedRaw))")
        XCTAssertGreaterThanOrEqual(result.reserved, result.laidOut - 0.5, "\(label): text taller than its reserved height")
    }

    func testReservedHeightMatchesLaidOutText() {
        let paragraph = String(repeating: "Measurement has to agree with the renderer at this width. ", count: 9)
        let cases: [(String, SelectableContent)] = [
            ("one line", SelectableContent(text: "Reviewed the render session.")),
            ("wrapped paragraph", SelectableContent(text: paragraph)),
            ("one line + trailing newline", SelectableContent(text: "first line\n")),
            ("wrapped paragraph + trailing newline", SelectableContent(text: paragraph + "\n")),
            ("ends with one blank line", SelectableContent(text: "first line\n\n")),
            ("ends with two blank lines", SelectableContent(text: "first line\n\n\n")),
            ("newline only", SelectableContent(text: "\n")),
            ("interior blank lines", SelectableContent(text: "one\n\n\nfour\n")),
            ("thinking block", SelectableContent(text: String(repeating: "Thinking about the invariant that keeps row heights honest. \n", count: 14), size: 12)),
            ("thinking block ending blank", SelectableContent(text: String(repeating: "Thinking about the invariant that keeps row heights honest. \n", count: 14) + "\n\n", size: 12)),
            ("tab indented", SelectableContent(text: "\tlet value = measure(row)\n\t\treturn value\n")),
            ("unbreakable token", SelectableContent(text: String(repeating: "a", count: 1200))),
            ("cjk", SelectableContent(text: String(repeating: "转录高度必须与排版结果保持一致。\n", count: 8))),
            ("emoji", SelectableContent(text: String(repeating: "✅ measured ✓ passed\n", count: 8))),
            ("monospaced activity output", SelectableContent(text: String(repeating: "let value = measure(row)\n    return value.height\n", count: 24), size: 11.5, monospaced: true)),
            ("monospaced activity output ending blank", SelectableContent(text: String(repeating: "let value = measure(row)\n    return value.height\n", count: 24) + "\n\n", size: 11.5, monospaced: true)),
            ("source listing", SelectableContent(text: String(repeating: "import Foundation\nfunc measure(_ row: Row) -> Double { row.height }\n", count: 10), monospaced: true, source: true)),
        ]
        for (label, content) in cases { assertFits(label, content) }
    }

    /// Blank lines the reader can see are reserved; trailing newlines that draw nothing
    /// are not. Both halves matter: a dropped interior blank line overlaps output, a
    /// reserved trailing one leaves a dead band under every block.
    func testInteriorBlankLinesAreReservedAndTrailingOnesAreNot() {
        func height(_ text: String) -> CGFloat {
            let host = NSHostingController(rootView: AnyView(SelectableContent(text: text, size: 12).fixedSize(horizontal: false, vertical: true)))
            host.sizingOptions = []
            return host.sizeThatFits(in: .init(width: 200, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let oneLine = height("One line")
        let twoLines = height("line.\nline.")
        let lineHeight = twoLines - oneLine
        XCTAssertGreaterThan(lineHeight, 8, "two lines are taller than one")
        XCTAssertEqual(height("line.\n\nline.") - twoLines, lineHeight, accuracy: 1, "the blank line between two lines costs the same as a real line")
        XCTAssertEqual(height("one\n\n\ntwo") - twoLines, lineHeight * 2, accuracy: 1, "interior blank lines are reserved")
        XCTAssertEqual(height("One line\n"), oneLine, accuracy: 1, "a trailing newline must not reserve a blank line")
        XCTAssertEqual(height("One line\n\n\n"), oneLine, accuracy: 1, "trailing blank lines must not reserve height")
    }
}
