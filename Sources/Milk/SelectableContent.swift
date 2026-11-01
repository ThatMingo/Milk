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
        view.textContainer?.widthTracksTextView=false
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
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
        let value=NSMutableAttributedString(string:text,attributes:[.font:font,.foregroundColor:MilkTheme.codeText,.paragraphStyle:paragraph])
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
        view.textContainer?.containerSize=CGSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        let bounds=view.attributedString().boundingRect(with:CGSize(width:width,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
        return CGSize(width:width,height:ceil(bounds.height)+4)
    }
}
