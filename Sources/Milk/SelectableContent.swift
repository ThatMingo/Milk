import SwiftUI
import AppKit

/// Read-only content with native selection, copy, and accessibility text ranges.
struct SelectableContent: NSViewRepresentable {
    let text: String
    var size: CGFloat = 14
    var monospaced = false
    var source = false
    struct RenderInput: Equatable {
        var text: String
        var size: CGFloat
        var monospaced: Bool
        var source: Bool
        var colorScheme: ColorScheme
    }
    final class Coordinator { var rendered: RenderInput? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view=NSTextView()
        view.isEditable=false; view.isSelectable=true; view.drawsBackground=false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding=0
        view.isHorizontallyResizable=false; view.isVerticallyResizable=false
        // The container width must follow the view's actual frame. With tracking off,
        // `containerSize` stays at whatever width the last `sizeThatFits` negotiation
        // probe passed in (SwiftUI proposes several widths before placing the view),
        // and the text then wraps narrower than the reader sees: `usedRect` runs past
        // the row height the same content measured at the resolved width.
        view.textContainer?.widthTracksTextView=true
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    /// Trailing newlines draw nothing, so they are not part of the piece. The text view
    /// holds exactly this value and the height the row reserves is the height that value
    /// lays out. Without the trim a trailing newline costs a whole blank line under every
    /// thinking block and tool output.
    static func visibleText(_ text:String)->String {
        var value=text
        while value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    func updateNSView(_ view: NSTextView,context:Context) {
        let metric = ChatRenderMetrics.begin()
        defer { ChatRenderMetrics.end("native.text.update", metric) }
        view.isSelectable=context.environment.isEnabled
        let input = RenderInput(text: text, size: size, monospaced: monospaced, source: source, colorScheme: context.environment.colorScheme)
        guard context.coordinator.rendered != input else { return }
        context.coordinator.rendered = input
        let font=monospaced ? NSFont.monospacedSystemFont(ofSize:size,weight:.regular):NSFont.systemFont(ofSize:size)
        let paragraph=NSMutableParagraphStyle(); paragraph.lineSpacing=source ? 0:4
        if source { paragraph.minimumLineHeight=19; paragraph.maximumLineHeight=19 }
        let value=NSMutableAttributedString(string:Self.visibleText(text),attributes:[.font:font,.foregroundColor:MilkTheme.codeText,.paragraphStyle:paragraph])
        if source {
            for (pattern,color) in [("\\b(import|actor|private|var|let|func|async|throws|try|await|init|final|class)\\b",MilkTheme.codeKeyword),("\\b(Foundation|SessionStore|Session|SessionPersistence|PiClient)\\b",MilkTheme.codeType),("//[^\\n]*",MilkTheme.codeComment)] {
                if let regex=try? NSRegularExpression(pattern:pattern) { for match in regex.matches(in:value.string,range:NSRange(location:0,length:value.length)) { value.addAttribute(.foregroundColor,value:color,range:match.range) } }
            }
        }
        if view.string != value.string { view.textStorage?.setAttributedString(value) }
        else if let storage=view.textStorage {
            // Recolor existing selectable text without replacing characters or selection.
            storage.beginEditing()
            value.enumerateAttributes(in:NSRange(location:0,length:value.length)) { attributes,range,_ in storage.setAttributes(attributes,range:range) }
            storage.endEditing()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view:NSTextView,context:Context) -> CGSize? {
        let width=max(1,proposal.width ?? 300)
        let container=view.textContainer, manager=view.layoutManager
        guard let container, let manager else { return CGSize(width:width,height:1) }
        container.containerSize=CGSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        // The height a piece reserves is the height this text view lays out. Measuring
        // the string with a different typesetter than the renderer is how a row ends up
        // shorter than its own text, so the layout manager answers the question here.
        manager.ensureLayout(for:container)
        var height=manager.usedRect(for:container).height
        // The piece carries no trailing newline, so no empty final fragment is laid out.
        // The guard keeps an empty final line out of the reservation if a future caller
        // ever hands this a value that ends in one.
        let extra=manager.extraLineFragmentRect
        if !extra.isEmpty { height-=extra.height }
        return CGSize(width:width,height:max(1,ceil(height)))
    }
}
