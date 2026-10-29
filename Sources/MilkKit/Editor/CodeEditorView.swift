import SwiftUI
import AppKit
import MilkCore

@MainActor final class CodeTextView: NSTextView {
    weak var document: DocumentBuffer?
    override var undoManager: UndoManager? { document?.undo }
    override func insertTab(_ sender: Any?) {
        let width = UserDefaults.standard.integer(forKey: "editor.tabWidth")
        if UserDefaults.standard.bool(forKey: "editor.useTabs") { super.insertTab(sender) }
        else { insertText(String(repeating: " ", count: width > 0 ? width : 4), replacementRange: selectedRange()) }
    }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString; let offset = selectedRange().location
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender); if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

@MainActor private final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: max(text.frame.height, contentSize.height)))
            text.textContainer?.containerSize = NSSize(width: max(1, width - 2 * text.textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
            contentView.scroll(to: NSPoint(x: 0, y: max(0, contentView.bounds.origin.y)))
        }
    }
}

@MainActor public struct CodeEditorView: NSViewRepresentable {
    public let document: DocumentBuffer
    public init(document: DocumentBuffer) { self.document = document }
    public func makeCoordinator() -> Coordinator { Coordinator(document: document) }
    public func makeNSView(context: Context) -> NSScrollView {
        let view = CodeTextView(usingTextLayoutManager: true); view.document = document
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.string = document.text
        view.isRichText = false; view.isEditable = true; view.allowsUndo = false // DocumentBuffer owns shared undo transactions.
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.minSize = NSSize(width: 0, height: 0); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 64, height: 12); view.delegate = context.coordinator
        view.setAccessibilityLabel("Code editor: " + document.url.lastPathComponent)
        let scroll = EditorScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(textView: view)
        context.coordinator.view = view; context.coordinator.highlight()
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = document.revision
        if let view = scroll.documentView as? NSTextView, view.string != document.text {
            let selection = view.selectedRange()
            context.coordinator.synchronizing = true; view.string = document.text
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            context.coordinator.synchronizing = false; context.coordinator.highlight()
        }
        scroll.verticalRulerView?.needsDisplay = true
    }
    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }
    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        let document: DocumentBuffer
        weak var view: CodeTextView?
        var task: Task<Void, Never>?
        var synchronizing = false
        let highlighter = HighlightingService()
        init(document: DocumentBuffer) { self.document = document }
        public func textDidChange(_ notification: Notification) {
            guard !synchronizing, let view else { return }
            document.replaceFromEditor(view.string); highlight()
        }
        public func textViewDidChangeSelection(_ notification: Notification) { if let view { document.selection = view.selectedRange() } }
        func highlight() {
            task?.cancel()
            let text = document.text, revision = document.revision, suffix = document.url.pathExtension
            task = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(80)); guard !Task.isCancelled else { return }
                let tokens = await highlighter.tokens(text: text, extension: suffix)
                guard !Task.isCancelled, revision == document.revision, let storage = view?.textStorage else { return }
                storage.beginEditing()
                storage.addAttributes([.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)], range: NSRange(location: 0, length: storage.length))
                for token in tokens where NSMaxRange(token.range) <= storage.length {
                    let color: NSColor = switch token.kind { case .keyword: .systemPurple; case .string: .systemRed; case .number: .systemBlue; case .comment: .secondaryLabelColor }
                    storage.addAttribute(.foregroundColor, value: color, range: token.range)
                }
                storage.endEditing()
            }
        }
    }
}

@MainActor final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView) { self.textView = textView; super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler); clientView = textView; ruleThickness = 48 }
    required init(coder: NSCoder) { fatalError("Not used") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.textLayoutManager else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rulerBounds = NSRect(x: bounds.minX, y: bounds.minY, width: ruleThickness, height: bounds.height)
        NSBezierPath(rect: rulerBounds).addClip()
        NSColor.windowBackgroundColor.setFill(); rulerBounds.fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        layout.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            if frame.maxY >= visible.minY {
                let location = layout.textContentManager?.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location) ?? 0
                let prefix = text.substring(to: min(max(location, 0), text.length))
                let number = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                ("\(number)" as NSString).draw(at: NSPoint(x: 8, y: frame.minY + textView.textContainerInset.height - visible.minY + 2), withAttributes: attributes)
            }
            return true
        }
    }
}

@MainActor public struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    public init(text: Binding<String>) { _text = text }
    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    public func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false; view.allowsUndo = true; view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 10, height: 10); view.delegate = context.coordinator
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Prompt")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = view; return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
        context.coordinator.text = $text
    }
    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        public func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { text.wrappedValue = view.string } }
    }
}
