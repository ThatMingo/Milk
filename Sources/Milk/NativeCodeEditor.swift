import AppKit
import SwiftUI
import MilkExtensionKit
import MilkExtensionHost

struct NativeCodeEditor: NSViewRepresentable {
    @Environment(\.milkExtensionRegistry) private var extensionRegistry
    @ObservedObject var store: WorkspaceStore
    let buffer: FileBuffer
    let pane: EditorPane
    func makeNSView(context:Context) -> CodeScrollView {
        let view=CodeScrollView(buffer:buffer)
        configure(view)
        view.editor.restore(pane.positions[buffer.url.path] ?? EditorPosition())
        return view
    }
    func updateNSView(_ view:CodeScrollView,context:Context) {
        configure(view)
        if let nav=store.navigation,nav.paneID == pane.id,view.editor.lastNavigation != nav.id {
            view.editor.lastNavigation=nav.id
            DispatchQueue.main.async { [weak view] in
                guard let editor=view?.editor else { return }
                if let line=nav.line { editor.goTo(line:line,column:nav.column) }
                else if let range=nav.range {
                    if range.length == NSNotFound { editor.findNext(forward:range.location == 1) }
                    else { editor.selectAndReveal(range) }
                }
                editor.window?.makeFirstResponder(editor)
            }
        }
        let active=store.activePane.id == pane.id
        view.editor.updateFind(store.findVisible ? store.findQuery:FindQuery(),force:active && !view.editor.wasActive)
        view.editor.wasActive=active
        view.editor.updateDiagnostics(store.diagnostics.filter { $0.file.path == buffer.url.path })
        view.editor.synchronizeRevision()
    }
    private func configure(_ view:CodeScrollView) {
        let editor=view.editor
        editor.extensionRegistry=extensionRegistry
        editor.store=store; editor.paneID=pane.id
        editor.onPosition={ [weak store] position in store?.positionChanged(position,path:buffer.url.path,pane:pane.id) }
        editor.applyPreferences(store.preferences)
    }
}

/// Enforce wrapping at the scrolling boundary, including selection autoscroll.
final class CodeClipView: NSClipView {
    var locksHorizontalPosition=false {
        didSet {
            if locksHorizontalPosition { scroll(to:NSPoint(x:0,y:bounds.minY)) }
        }
    }
    override func constrainBoundsRect(_ proposedBounds:NSRect) -> NSRect {
        var result=super.constrainBoundsRect(proposedBounds)
        if locksHorizontalPosition { result.origin.x=0 }
        return result
    }
    override func setBoundsOrigin(_ newOrigin:NSPoint) {
        super.setBoundsOrigin(NSPoint(x:locksHorizontalPosition ? 0:newOrigin.x,y:newOrigin.y))
    }
}

final class CodeScrollView: NSScrollView {
    let editor: CodeTextView
    init(buffer:FileBuffer) {
        let manager=NSLayoutManager(), container=NSTextContainer(containerSize:NSSize(width:1000,height:CGFloat.greatestFiniteMagnitude))
        buffer.storage.addLayoutManager(manager); manager.addTextContainer(container)
        editor=CodeTextView(frame:.zero,textContainer:container,buffer:buffer)
        super.init(frame:.zero)
        focusRingType = .none
        // Native ruler drawing must never bleed into SwiftUI's tab/footer rows.
        wantsLayer=true
        layer?.masksToBounds=true
        contentView=CodeClipView()
        contentView.focusRingType = .none
        drawsBackground=true; backgroundColor = MilkTheme.codeBackground
        hasVerticalScroller=true; hasHorizontalScroller=true; autohidesScrollers=true
        documentView=editor
        editor.minSize=NSSize(width:0,height:0); editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable=true; editor.isHorizontallyResizable=true; editor.autoresizingMask=[.width]
        verticalRulerView=CodeRuler(scrollView:self,editor:editor)
        hasVerticalRuler=true; rulersVisible=true
        contentView.postsBoundsChangedNotifications=true
        NotificationCenter.default.addObserver(self,selector:#selector(scrolled),name:NSView.boundsDidChangeNotification,object:contentView)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func scrolled() { verticalRulerView?.needsDisplay=true; editor.recordPosition() }
    override func layout() { super.layout(); editor.updateContainerWidth() }
    override func tile() {
        super.tile()
        // Plain-text NSTextView can tile the native ruler over its clip view.
        // Reserve the gutter explicitly so source glyphs never sit underneath it.
        if let ruler=verticalRulerView, rulersVisible {
            var clip=contentView.frame
            let right=clip.maxX
            clip.origin.x=max(clip.minX,ruler.ruleThickness)
            clip.size.width=max(1,right-clip.minX)
            contentView.frame=clip
            if let scroller=horizontalScroller {
                var frame=scroller.frame; let end=frame.maxX
                frame.origin.x=max(frame.minX,ruler.ruleThickness); frame.size.width=max(1,end-frame.minX)
                scroller.frame=frame
            }
        }
        editor.updateContainerWidth()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

final class CodeTextView: NSTextView, NSTextViewDelegate, NSLayoutManagerDelegate {
    weak var extensionRegistry: ExtensionContributionRegistry?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu=super.menu(for:event) ?? NSMenu()
        if let registry=extensionRegistry {
            let actions=registry.actions.filter { $0.point == .codeContextMenu }
            if !actions.isEmpty { menu.addItem(.separator()) }
            for record in actions {
                let selection=(string as NSString).substring(with:selectedRange())
                let context=ExtensionActionContext(workspaceURL:store?.workspace?.url,fileURL:buffer.url,text:selection)
                let handler=NativeEditorExtensionAction(registry:registry,id:record.id,context:context)
                let item=NSMenuItem(title:record.item.title,action:#selector(NativeEditorExtensionAction.runContribution(_:)),keyEquivalent:"")
                item.target=handler; item.representedObject=handler; menu.addItem(item)
            }
        }
        return menu
    }
    let buffer: FileBuffer
    weak var store:WorkspaceStore?
    var paneID=UUID()
    var onPosition: ((EditorPosition)->Void)?
    var lastNavigation:UUID?
    var wasActive=false
    var appliedRevision = -1
    var preferences=EditorPreferences()
    var lineStarts=[0]
    var pairs:[(Int,Int)]=[]
    var folds:[NSRange]=[]
    var diagnostics:[EditorDiagnostic]=[]
    private var findQuery=FindQuery()
    private var matches:[NSRange]=[]
    private var stylingTask:Task<Void,Never>?
    private var restoring=false
    private var changing=false
    private var didApplyPreferences=false
    override var undoManager: UndoManager? { buffer.undoManager }
    init(frame:NSRect,textContainer:NSTextContainer,buffer:FileBuffer) {
        self.buffer=buffer
        super.init(frame:frame,textContainer:textContainer)
        focusRingType = .none
        delegate=self; layoutManager?.delegate=self
        isRichText=false; importsGraphics=false; allowsUndo=true; isEditable=true; isSelectable=true
        usesFindBar=false; isAutomaticQuoteSubstitutionEnabled=false; isAutomaticDashSubstitutionEnabled=false
        isAutomaticTextReplacementEnabled=false; isAutomaticSpellingCorrectionEnabled=false; isContinuousSpellCheckingEnabled=false
        isGrammarCheckingEnabled=false; isAutomaticLinkDetectionEnabled=false; isAutomaticDataDetectionEnabled=false
        textContainerInset=NSSize(width:12,height:8)
        textContainer.lineFragmentPadding=0
        backgroundColor = MilkTheme.codeBackground; insertionPointColor=NSColor(MilkTheme.accent)
        setAccessibilityLabel("Code editor, \(buffer.url.lastPathComponent)")
        rebuildLines(); scheduleStyling()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }
    func applyTheme() {
        backgroundColor=MilkTheme.codeBackground
        insertionPointColor=NSColor(MilkTheme.accent)
        selectedTextAttributes=[.backgroundColor:MilkTheme.selection, .foregroundColor:MilkTheme.codeText]
        enclosingScrollView?.backgroundColor=MilkTheme.codeBackground
        enclosingScrollView?.verticalRulerView?.needsDisplay=true
        scheduleStyling(); needsDisplay=true
    }
    func applyPreferences(_ next:EditorPreferences) {
        guard !didApplyPreferences || preferences != next else { return }
        applyTheme()
        didApplyPreferences=true
        preferences=next
        let font=NSFont.monospacedSystemFont(ofSize:next.fontSize,weight:.regular)
        self.font=font
        let paragraph=NSMutableParagraphStyle()
        paragraph.tabStops=[]; paragraph.defaultTabInterval=CGFloat(next.indentWidth)*font.maximumAdvancement.width
        paragraph.lineBreakMode=next.wordWrap ? .byWordWrapping:.byClipping
        defaultParagraphStyle=paragraph
        typingAttributes=[.font:font,.foregroundColor:MilkTheme.codeText,.paragraphStyle:paragraph]
        if let storage=textStorage {
            storage.addAttributes([.font:font,.paragraphStyle:paragraph],range:NSRange(location:0,length:storage.length))
        }
        isHorizontallyResizable = !next.wordWrap
        // NSScrollView owns the ruler offset; an NSTextView must fill its clip view.
        setFrameOrigin(.zero)
        (enclosingScrollView?.contentView as? CodeClipView)?.locksHorizontalPosition=next.wordWrap
        enclosingScrollView?.hasHorizontalScroller = !next.wordWrap
        textContainer?.widthTracksTextView=next.wordWrap
        updateContainerWidth(); enclosingScrollView?.verticalRulerView?.needsDisplay=true
    }
    func updateContainerWidth() {
        guard let scroll=enclosingScrollView else { return }
        let width=max(1,scroll.contentView.bounds.width)
        minSize=NSSize(width:width,height:scroll.contentSize.height)
        autoresizingMask=preferences.wordWrap ? [.width]:[]
        if preferences.wordWrap {
            if frame.width != width { setFrameSize(NSSize(width:width,height:max(frame.height,scroll.contentSize.height))) }
            textContainer?.containerSize=NSSize(width:max(1,width-textContainerInset.width*2),height:CGFloat.greatestFiniteMagnitude)
        } else {
            textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            if frame.width < width { setFrameSize(NSSize(width:width,height:max(frame.height,scroll.contentSize.height))) }
        }
    }
    func synchronizeRevision() {
        guard appliedRevision != buffer.revision else { return }
        appliedRevision=buffer.revision
        rebuildLines(); scheduleStyling(); updateFind(findQuery,force:true)
        enclosingScrollView?.verticalRulerView?.needsDisplay=true
    }
    func restore(_ position:EditorPosition) {
        restoring=true
        let range=clamped(NSRange(location:position.selection,length:position.selectionLength))
        setSelectedRange(range)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enclosingScrollView?.contentView.scroll(to:NSPoint(x:0,y:position.scrollY))
            self.enclosingScrollView?.reflectScrolledClipView(self.enclosingScrollView!.contentView)
            self.restoring=false
        }
    }
    func recordPosition() {
        guard !restoring else { return }
        let range=selectedRange()
        onPosition?(.init(selection:range.location,selectionLength:range.length,scrollY:Double(enclosingScrollView?.contentView.bounds.minY ?? 0)))
    }
    private func clamped(_ range:NSRange) -> NSRange {
        let length=(string as NSString).length, start=min(max(0,range.location),length)
        return NSRange(location:start,length:min(max(0,range.length),length-start))
    }
    func selectAndReveal(_ range:NSRange) {
        unfoldAll(); let r=clamped(range); setSelectedRange(r); scrollRangeToVisible(r)
    }
    func goTo(line:Int,column:Int = 1) {
        let index=min(max(0,line-1),lineStarts.count-1), start=lineStarts[index]
        let end=index+1<lineStarts.count ? lineStarts[index+1]-1:(string as NSString).length
        selectAndReveal(NSRange(location:min(end,start+max(0,column-1)),length:0))
    }
    func rebuildLines() {
        let text=string as NSString
        lineStarts=[0]
        text.enumerateSubstrings(in:NSRange(location:0,length:text.length),options:[.byLines,.substringNotRequired]) { _,range,enclosing,_ in
            let end=NSMaxRange(enclosing)
            if end<text.length || (end == text.length && enclosing.length>range.length) { self.lineStarts.append(end) }
        }
        pairs=EditorLanguage.bracePairs(string)
    }
    func lineIndex(at offset:Int) -> Int {
        var lo=0, hi=lineStarts.count
        while lo<hi { let mid=(lo+hi)/2; if lineStarts[mid]<=offset { lo=mid+1 } else { hi=mid } }
        return max(0,lo-1)
    }
    func textDidBeginEditing(_ notification:Notification) { store?.activatePane(paneID) }
    override func becomeFirstResponder() -> Bool {
        let result=super.becomeFirstResponder(); if result { store?.activatePane(paneID) }; return result
    }
    func textDidChange(_ notification:Notification) {
        guard !changing else { return }
        unfoldAll(); store?.bufferChanged(buffer); synchronizeRevision(); recordPosition()
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        guard !changing else { return }
        let location=selectedRange().location, index=lineIndex(at:location)
        if let store,store.activePane.id == paneID {
            // Avoid publishing synchronously during representable updates.
            DispatchQueue.main.async { [weak self,weak store] in
                guard let self,let store,store.activePane.id == self.paneID else { return }
                if store.selectionLine != index+1 { store.selectionLine=index+1 }
                let col=location-self.lineStarts[min(index,self.lineStarts.count-1)]+1
                if store.selectionColumn != col { store.selectionColumn=col }
            }
        }
        paintDecorations(); recordPosition()
    }
    func textView(_ textView:NSTextView,shouldChangeTextInRanges affectedRanges:[NSValue],replacementStrings:[String]?) -> Bool {
        unfoldAll(); return true
    }
    override func insertNewline(_ sender:Any?) {
        let ns=string as NSString, range=selectedRange(), line=ns.lineRange(for:NSRange(location:range.location,length:0))
        let before=ns.substring(with:NSRange(location:line.location,length:range.location-line.location))
        let indent=String(before.prefix { $0 == " " || $0 == "\t" })
        let unit=preferences.usesTabs ? "\t":String(repeating:" ",count:preferences.indentWidth)
        let extra=before.trimmingCharacters(in:.whitespaces).last.map { "{[(".contains($0) } ?? false
        let newline=string.contains("\r\n") ? "\r\n":"\n"
        insertText(newline+indent+(extra ? unit:""),replacementRange:range)
    }
    override func insertTab(_ sender:Any?) {
        if selectedRange().length>0 { indentSelection(outdent:false); return }
        let column=selectedRange().location-lineStarts[lineIndex(at:selectedRange().location)]
        let text=preferences.usesTabs ? "\t":String(repeating:" ",count:preferences.indentWidth-column%preferences.indentWidth)
        insertText(text,replacementRange:selectedRange())
    }
    override func insertBacktab(_ sender:Any?) { indentSelection(outdent:true) }
    func indentSelection(outdent:Bool) {
        let ns=string as NSString, selection=selectedRange()
        let range=ns.lineRange(for:selection)
        let chunk=ns.substring(with:range)
        let unit=preferences.usesTabs ? "\t":String(repeating:" ",count:preferences.indentWidth)
        var offset=0
        let lines=chunk.components(separatedBy:"\n").enumerated().map { index,line -> String in
            if index>0 && line.isEmpty && chunk.hasSuffix("\n") { return line }
            if outdent {
                let count=line.hasPrefix("\t") ? 1:min(preferences.indentWidth,line.prefix(while:{$0 == " "}).count)
                if index == 0 { offset = -count }
                return String(line.dropFirst(count))
            }
            if index == 0 { offset=unit.count }; return unit+line
        }
        let replacement=lines.joined(separator:"\n")
        insertText(replacement,replacementRange:range)
        if selection.length>0 { setSelectedRange(NSRange(location:range.location,length:(replacement as NSString).length)) }
        else { setSelectedRange(NSRange(location:max(range.location,selection.location+offset),length:0)) }
    }
    @objc func selectNextOccurrence(_ sender:Any?) {
        let existing=selectedRanges.map(\.rangeValue)
        let primary=existing.first ?? selectedRange()
        guard primary.length>0 else { return }
        let text=string as NSString, needle=text.substring(with:primary)
        let start=existing.map(NSMaxRange).max() ?? 0
        let range=text.range(of:needle,options:[],range:NSRange(location:start,length:text.length-start))
        guard range.location != NSNotFound else { return }
        setSelectedRanges((existing+[range]).map { NSValue(range:$0) },affinity:.downstream,stillSelecting:false)
        scrollRangeToVisible(range)
    }
    override func insertText(_ insertString:Any,replacementRange:NSRange) {
        guard selectedRanges.count>1, replacementRange.location == NSNotFound || replacementRange == selectedRange(),let text=insertString as? String else {
            super.insertText(insertString,replacementRange:replacementRange); return
        }
        replaceMultiple(selectedRanges.map(\.rangeValue),with:text)
    }
    private func replaceMultiple(_ ranges:[NSRange],with text:String) {
        let ranges=ranges.sorted { $0.location<$1.location }
        guard shouldChangeText(inRanges:ranges.map { NSValue(range:$0) },replacementStrings:Array(repeating:text,count:ranges.count)) else { return }
        undoManager?.beginUndoGrouping()
        textStorage?.beginEditing()
        for range in ranges.reversed() { textStorage?.replaceCharacters(in:range,with:text) }
        textStorage?.endEditing(); didChangeText()
        var delta=0
        let selections=ranges.map { range -> NSValue in
            let location=range.location+delta+(text as NSString).length
            delta += (text as NSString).length-range.length
            return NSValue(range:NSRange(location:location,length:0))
        }
        setSelectedRanges(selections,affinity:.downstream,stillSelecting:false)
        undoManager?.endUndoGrouping()
    }
    override func deleteBackward(_ sender:Any?) {
        guard selectedRanges.count>1 else { super.deleteBackward(sender); return }
        let ns=string as NSString
        let ranges=selectedRanges.map(\.rangeValue).map { range -> NSRange in
            range.length>0 ? range:(range.location>0 ? ns.rangeOfComposedCharacterSequence(at:range.location-1):range)
        }
        replaceMultiple(ranges,with:"")
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 && store?.findVisible == true { store?.findVisible=false; return }
        super.keyDown(with:event)
    }
    func textView(_ textView:NSTextView,completions words:[String],forPartialWordRange charRange:NSRange,indexOfSelectedItem index:UnsafeMutablePointer<Int>?) -> [String] {
        WordCompletionProvider().completions(for:(string as NSString).substring(with:charRange),in:string)
    }
    private func scheduleStyling() {
        stylingTask?.cancel()
        let snapshot=string, revision=buffer.revision, ext=buffer.url.pathExtension.lowercased()
        stylingTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:120_000_000)
            guard !Task.isCancelled else { return }
            let tokens=await Task.detached(priority:.userInitiated) { EditorLanguage.tokens(snapshot,fileExtension:ext) }.value
            guard !Task.isCancelled,let self,self.buffer.revision == revision,self.string == snapshot else { return }
            self.changing=true
            if let storage=self.textStorage {
                storage.beginEditing()
                storage.addAttribute(.foregroundColor,value:MilkTheme.codeText,range:NSRange(location:0,length:storage.length))
                for token in tokens { storage.addAttribute(.foregroundColor,value:token.color,range:token.range) }
                storage.endEditing()
            }
            self.changing=false; self.paintDecorations()
        }
    }
    func updateFind(_ query:FindQuery,force:Bool = false) {
        guard force || findQuery != query else { return }
        findQuery=query
        do {
            matches=try query.matches(in:string)
            if store?.activePane.id == paneID {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.store?.activePane.id == self.paneID else { return }
                    self.store?.findCount=self.matches.count; self.store?.findError=nil
                }
            }
        } catch {
            matches=[]
            DispatchQueue.main.async { [weak store] in store?.findCount=0; store?.findError="Invalid regular expression" }
        }
        paintDecorations()
    }
    func findNext(forward:Bool) {
        guard !matches.isEmpty else { return }
        let range=selectedRange(), start=range.location
        let index:Int
        if let current=matches.firstIndex(of:range) {
            index=(current+(forward ? 1:matches.count-1))%matches.count
        } else if forward { index=matches.firstIndex(where:{$0.location>=NSMaxRange(range)}) ?? 0 }
        else { index=matches.lastIndex(where:{$0.location<start}) ?? matches.count-1 }
        store?.findIndex=index+1; selectAndReveal(matches[index])
    }
    func updateDiagnostics(_ next:[EditorDiagnostic]) {
        guard diagnostics != next else { return }
        diagnostics=next; paintDecorations(); enclosingScrollView?.verticalRulerView?.needsDisplay=true
    }
    private func paintDecorations() {
        guard let manager=layoutManager else { return }
        let full=NSRange(location:0,length:(string as NSString).length)
        manager.removeTemporaryAttribute(.backgroundColor,forCharacterRange:full)
        manager.removeTemporaryAttribute(.underlineStyle,forCharacterRange:full)
        manager.removeTemporaryAttribute(.underlineColor,forCharacterRange:full)
        for match in matches.prefix(5000) where match.length>0 {
            manager.addTemporaryAttribute(.backgroundColor,value:NSColor.systemYellow.withAlphaComponent(0.28),forCharacterRange:match)
        }
        let caret=selectedRange().location
        if selectedRange().length == 0,let pair=pairs.first(where:{$0.0 == caret || $0.1 == caret || $0.0 == caret-1 || $0.1 == caret-1}) {
            for offset in [pair.0,pair.1] { manager.addTemporaryAttribute(.backgroundColor,value:NSColor.systemOrange.withAlphaComponent(0.22),forCharacterRange:NSRange(location:offset,length:1)) }
        }
        for d in diagnostics {
            let row=min(max(0,d.line-1),lineStarts.count-1), start=lineStarts[row]+max(0,d.column-1)
            guard start<full.length else { continue }
            let end=row+1<lineStarts.count ? lineStarts[row+1]-1:full.length
            let range=NSRange(location:min(start,end),length:max(0,end-min(start,end)))
            manager.addTemporaryAttributes([.underlineStyle:NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,.underlineColor:d.severity == .error ? NSColor.systemRed:NSColor.systemOrange],forCharacterRange:range)
        }
    }
    func foldRange(onLine line:Int) -> NSRange? {
        guard line>=0,line<lineStarts.count else { return nil }
        let start=lineStarts[line], end=line+1<lineStarts.count ? lineStarts[line+1]:(string as NSString).length
        return pairs.filter { $0.0>=start && $0.0<end && lineIndex(at:$0.1)>line }
            .sorted { $0.0<$1.0 }.first.map { NSRange(location:$0.0+1,length:$0.1-$0.0-1) }
    }
    func toggleFold(onLine line:Int) {
        guard let range=foldRange(onLine:line) else { return }
        if let index=folds.firstIndex(of:range) { folds.remove(at:index) }
        else {
            folds.removeAll { NSIntersectionRange($0,range).length>0 }; folds.append(range)
            setSelectedRange(NSRange(location:range.location-1,length:0))
        }
        invalidateFolds()
    }
    func unfoldAll() { guard !folds.isEmpty else { return }; folds=[]; invalidateFolds() }
    private func invalidateFolds() {
        let full=NSRange(location:0,length:(string as NSString).length)
        layoutManager?.invalidateGlyphs(forCharacterRange:full,changeInLength:0,actualCharacterRange:nil)
        layoutManager?.invalidateLayout(forCharacterRange:full,actualCharacterRange:nil)
        enclosingScrollView?.verticalRulerView?.needsDisplay=true; needsDisplay=true
    }
    func layoutManager(_ manager:NSLayoutManager,shouldGenerateGlyphs glyphs:UnsafePointer<CGGlyph>,properties props:UnsafePointer<NSLayoutManager.GlyphProperty>,characterIndexes indexes:UnsafePointer<Int>,font:NSFont,forGlyphRange range:NSRange) -> Int {
        guard !folds.isEmpty else { return 0 }
        var properties=Array(UnsafeBufferPointer(start:props,count:range.length))
        var modified=false
        for i in 0..<range.length where folds.contains(where:{NSLocationInRange(indexes[i],$0)}) { properties[i] = .controlCharacter; modified=true }
        guard modified else { return 0 }
        manager.setGlyphs(glyphs,properties:properties,characterIndexes:indexes,font:font,forGlyphRange:range)
        return range.length
    }
    func layoutManager(_ manager:NSLayoutManager,shouldUse action:NSLayoutManager.ControlCharacterAction,forControlCharacterAt index:Int) -> NSLayoutManager.ControlCharacterAction {
        folds.contains(where:{NSLocationInRange(index,$0)}) ? .zeroAdvancement:action
    }
    deinit { stylingTask?.cancel() }
}

final class CodeRuler: NSRulerView {
    weak var editor:CodeTextView?
    private var visibleLines:[(Int,CGFloat)]=[]
    init(scrollView:NSScrollView,editor:CodeTextView) {
        self.editor=editor
        super.init(scrollView:scrollView,orientation:.verticalRuler)
        clientView=editor; ruleThickness=58
        wantsLayer=true
        layer?.masksToBounds=true
    }
    required init(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect:NSRect) {
        // Draw only Milk's gutter. NSRulerView's default rule/baseline can
        // extend past the ruler and appear over the tab bar and status text.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:bounds).addClip()
        drawHashMarksAndLabels(in:dirtyRect.intersection(bounds))
        NSGraphicsContext.restoreGraphicsState()
    }
    override func drawHashMarksAndLabels(in rect:NSRect) {
        MilkTheme.codeBackground.setFill(); bounds.fill()
        guard let editor,let manager=editor.layoutManager,let container=editor.textContainer else { return }
        visibleLines=[]
        let visible=editor.visibleRect, origin=editor.textContainerOrigin
        let glyphs=manager.glyphRange(forBoundingRect:visible.offsetBy(dx:-origin.x,dy:-origin.y),in:container)
        let font=NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:MilkTheme.codeComment]
        var drawn=Set<Int>()
        manager.enumerateLineFragments(forGlyphRange:glyphs) { [weak self] lineRect,_,_,range,_ in
            guard let self else { return }
            let character=manager.characterIndexForGlyph(at:range.location), line=editor.lineIndex(at:character)
            guard drawn.insert(line).inserted else { return }
            let y=lineRect.minY+origin.y-visible.minY
            self.visibleLines.append((line,y))
            let label="\(line+1)" as NSString
            label.draw(at:NSPoint(x:39-label.size(withAttributes:attrs).width,y:y+1),withAttributes:attrs)
            if let fold=editor.foldRange(onLine:line) {
                let folded=editor.folds.contains(fold)
                (folded ? "▸":"▾" as NSString).draw(at:NSPoint(x:44,y:y),withAttributes:attrs)
            }
            if let d=editor.diagnostics.first(where:{$0.line == line+1}) {
                (d.severity == .error ? NSColor.systemRed:NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn:NSRect(x:4,y:y+4,width:6,height:6)).fill()
            }
        }
        if editor.string.isEmpty { ("1" as NSString).draw(at:NSPoint(x:31,y:8),withAttributes:attrs) }
    }
    override func mouseDown(with event:NSEvent) {
        guard let editor else { return }
        let point=convert(event.locationInWindow,from:nil)
        guard let line=visibleLines.last(where:{$0.1<=point.y})?.0 else { return }
        if point.x>=42 { editor.toggleFold(onLine:line) }
        else if let d=editor.diagnostics.first(where:{$0.line == line+1}) { editor.goTo(line:d.line,column:d.column) }
        else { editor.goTo(line:line+1) }
        editor.window?.makeFirstResponder(editor)
    }
}


@MainActor private final class NativeEditorExtensionAction: NSObject {
    weak var registry: ExtensionContributionRegistry?
    let id: String
    let context: ExtensionActionContext
    init(registry: ExtensionContributionRegistry, id: String, context: ExtensionActionContext) { self.registry=registry; self.id=id; self.context=context }
    @objc func runContribution(_ sender: NSMenuItem) { Task {
        guard let action=registry?.actions.first(where:{ $0.id == id }) else { return }
        do { try await action.item.perform(context) }
        catch { let alert=NSAlert(); alert.messageText="Extension action failed"; alert.informativeText=error.localizedDescription; alert.runModal() }
    } }
}
