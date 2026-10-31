import SwiftUI
import AppKit
import MilkLayout
import UniformTypeIdentifiers

struct WorkspaceGrid: View {
    @ObservedObject var state: ShellState
    var body: some View {
        GeometryReader { geometry in
            if let root=state.renderedRoot { node(root,size:geometry.size) }
            else {
                MilkCartonOutline()
                    .stroke(MilkTheme.muted.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 96, height: 104)
                    .offset(x: -2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }.accessibilityElement(children:.contain).accessibilityLabel("Workspace grid")
    }
    private func node(_ value: LayoutNode, size: CGSize) -> AnyView {
        switch value {
        case let .leaf(id, element):
            return AnyView(leaf(id,element:element).frame(width:size.width,height:size.height).clipped())
        case let .split(id,axis,_,a,b):
            let first=value.firstLength(size)
            let asize=axis == .horizontal ? CGSize(width:first,height:size.height) : CGSize(width:size.width,height:first)
            let bsize=axis == .horizontal ? CGSize(width:size.width-first-1,height:size.height) : CGSize(width:size.width,height:size.height-first-1)
            let divider=SplitDivider(state:state,node:value,size:size)
            if axis == .horizontal { return AnyView(HStack(spacing:0) { node(a,size:asize); divider.frame(width:1,height:size.height); node(b,size:bsize) }) }
            return AnyView(VStack(spacing:0) { node(a,size:asize); divider.frame(width:size.width,height:1); node(b,size:bsize) }.id(id))
        }
    }
    private func leaf(_ id: UUID, element: WorkspaceElement?) -> some View {
        VStack(spacing:0) {
            if state.isEditingLayout {
                HStack {
                    Text(element?.title ?? "Empty cell").fontWeight(.medium).contentShape(Rectangle()).onDrag { return NSItemProvider(object:(element?.rawValue ?? "") as NSString) }
                    Spacer(minLength:0)
                    Menu {
                        Button("Split horizontally (left/right)") { state.change { $0.split(id,axis:.horizontal) } }
                        Button("Split vertically (above/below)") { state.change { $0.split(id,axis:.vertical) } }
                        Menu("Assign / move component here") {
                            ForEach(state.panelElements) { e in Button(e.title) { state.change { $0.place(e,at:id,edge:.replace) } } }
                        }
                        ForEach(Placement.allCases.filter { $0 != .replace },id:\.self) { edge in
                            Menu("Place at \(edge.rawValue)") {
                                ForEach(state.panelElements.filter { $0 != element }) { e in
                                    Button(e.title) { state.change { $0.place(e,at:id,edge:edge) } }
                                }
                            }
                        }
                        Button("Remove cell") { state.change { $0.remove(id) } }
                    } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Edit \(element?.title ?? "empty") cell")
                }.font(.system(size:12)).padding(.horizontal,10).frame(height:30).background(MilkTheme.surface)
            }
            ZStack {
                Group {
                    switch element {
                    case .chat: ChatPanel(state:state)
                    case .code: CodePanel(state:state)
                    case .preview: PreviewPanel(service:state.preview)
                    case .terminal: TerminalPanel(service:state.terminal,workspace:state.workspace)
                    case let element? where element.isExtension:
                        if let panel=state.nativeExtensions.registry.panels.first(where:{ $0.id == element.rawValue }) { panel.item.content(.init(workspaceURL:state.workspace.workspace?.url)).id(panel.id) }
                    case nil: Text("Assign a component using the cell menu").foregroundStyle(MilkTheme.muted).frame(maxWidth:.infinity,maxHeight:.infinity)
                    default: EmptyView()
                    }
                }.allowsHitTesting(!state.isEditingLayout).disabled(state.isEditingLayout)
                if state.isEditingLayout {
                    VStack(spacing:0) {
                        dropTarget(.top,id:id).frame(height:30)
                        HStack(spacing:0) {
                            dropTarget(.left,id:id).frame(width:42)
                            Spacer(minLength:0)
                            dropTarget(.replace,id:id).frame(width:76,height:36)
                            Spacer(minLength:0)
                            dropTarget(.right,id:id).frame(width:42)
                        }
                        dropTarget(.bottom,id:id).frame(height:30)
                    }.allowsHitTesting(false)
                    PanelInteraction(element:element) { raw,edge in
                        guard let e=WorkspaceElement(rawValue:raw) else { return false }
                        state.change { $0.place(e,at:id,edge:edge) }; return true
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).zIndex(10)
                }
            }
        }.background(ShellGeometryMarker(name:element?.rawValue ?? id.uuidString))
            .overlay { if state.isEditingLayout { Rectangle().strokeBorder(MilkTheme.accent.opacity(0.6),style:StrokeStyle(lineWidth:1,dash:[5,4])).allowsHitTesting(false) } }
    }
    private func dropTarget(_ edge: Placement,id:UUID) -> some View {
        Color.clear
            .frame(maxWidth:.infinity,maxHeight:.infinity).background(MilkTheme.canvas.opacity(0.85))
            .overlay(Rectangle().stroke(MilkTheme.accent.opacity(0.3)))
            .accessibilityLabel("Drop \(edge.rawValue)")
    }
}

private struct SplitDivider: View {
    @ObservedObject var state: ShellState
    let node: LayoutNode
    let size: CGSize
    @State private var start: Double?
    var body: some View {
        let horizontal: Bool = { if case .split(_, .horizontal, _, _, _) = node { return true }; return false }()
        let total=(horizontal ? size.width:size.height)-1
        MilkTheme.line.overlay {
            Color.clear.frame(width:horizontal ? 9:nil,height:horizontal ? nil:9).contentShape(Rectangle())
                .onHover { inside in if inside { (horizontal ? NSCursor.resizeLeftRight:NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { v in
                    if start == nil { start=node.firstLength(size) }
                    let delta=horizontal ? v.translation.width:v.translation.height
                    resize(length:(start ?? 0)+delta,total:total,horizontal:horizontal)
                }.onEnded { _ in start=nil })
                .accessibilityLabel("Resize \(horizontal ? "horizontal":"vertical") divider")
                .accessibilityAdjustableAction { d in resize(length:node.firstLength(size)+(d == .increment ? 20:-20),total:total,horizontal:horizontal) }
        }.zIndex(2)
    }
    private func resize(length:Double,total:Double,horizontal:Bool) {
        guard case let .split(id,_,_,a,b)=node else { return }
        let amin=horizontal ? a.minimum.width:a.minimum.height
        let bmin=horizontal ? b.minimum.width:b.minimum.height
        state.layout.resize(id,ratio:max(amin,min(total-bmin,length))/total)
    }
}

/// One AppKit interaction surface owns both dragging and receiving for the
/// whole panel. Its ghost captures the current panel while live content stays
/// visible and normal content interaction is suspended during Layout Edit.
private struct PanelInteraction: NSViewRepresentable {
    let element:WorkspaceElement?
    let accept:(String,Placement)->Bool
    func makeNSView(context:Context) -> Surface { let v=Surface(); v.registerForDraggedTypes([.string]); updateNSView(v,context:context); return v }
    func updateNSView(_ view:Surface,context:Context) {
        view.element=element; view.accept=accept
        view.identifier=NSUserInterfaceItemIdentifier("milk.drag."+(element?.rawValue ?? "empty"))
        view.setAccessibilityElement(true); view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Drag \(element?.title ?? "empty") panel")
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:Surface,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? 600,height:proposal.height ?? 300)
    }
    final class Surface:NSView {
        var element:WorkspaceElement?
        var accept:((String,Placement)->Bool)?
        private var edge:Placement?
        override var isFlipped:Bool { true }
        override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
        override func mouseDown(with event:NSEvent) {
            guard let element,let content=window?.contentView else { return }
            let origin=event.locationInWindow
            var active=false
            var destination:Surface?
            let ghost=Ghost(frame:.zero)
            let rect=convert(bounds,to:content)
            if let bitmap=content.bitmapImageRepForCachingDisplay(in:rect) {
                content.cacheDisplay(in:rect,to:bitmap)
                let snapshot=NSImage(size:rect.size); snapshot.addRepresentation(bitmap); ghost.image=snapshot
            }
            ghost.imageScaling = .scaleProportionallyUpOrDown
            ghost.alphaValue=0.72; ghost.wantsLayer=true
            ghost.layer?.shadowOpacity=0.2; ghost.layer?.shadowRadius=8
            let scale=min(1,300/max(1,bounds.width))
            let ghostSize=CGSize(width:bounds.width*scale,height:bounds.height*scale)
            func surfaces(_ view:NSView) -> [Surface] {
                if let surface=view as? Surface { return [surface] }
                return view.subviews.flatMap { surfaces($0) }
            }
            while let next=NSApp.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown],until:.distantFuture,inMode:.eventTracking,dequeue:true) {
                let point=next.locationInWindow
                if next.type == .keyDown { break }
                if next.type == .leftMouseUp {
                    if active,let target=destination,let edge=target.edge {
                        _ = target.accept?(element.rawValue,edge)
                    }
                    break
                }
                if !active && hypot(point.x-origin.x,point.y-origin.y) >= 3 {
                    active=true; content.addSubview(ghost,positioned:.above,relativeTo:nil)
                }
                guard active else { continue }
                let rootPoint=content.convert(point,from:nil)
                ghost.frame=NSRect(x:rootPoint.x+12,y:rootPoint.y-ghostSize.height-12,width:ghostSize.width,height:ghostSize.height)
                let target=surfaces(content).first { surface in
                    surface !== self && surface.bounds.contains(surface.convert(point,from:nil))
                }
                if destination !== target { destination?.edge=nil; destination?.needsDisplay=true }
                destination=target
                if let target { target.edge=target.placement(at:target.convert(point,from:nil)); target.needsDisplay=true }
                content.displayIfNeeded()
            }
            destination?.edge=nil; destination?.needsDisplay=true
            ghost.removeFromSuperview()
        }
        private final class Ghost:NSImageView {
            override func hitTest(_ point:NSPoint) -> NSView? { nil }
        }
        private func placement(at p:NSPoint) -> Placement {
            if p.y < 30 { return .top }; if p.y > bounds.height-30 { return .bottom }
            if p.x < 42 { return .left }; if p.x > bounds.width-42 { return .right }
            return .replace
        }
        private func placement(_ sender:NSDraggingInfo) -> Placement {
            placement(at:convert(sender.draggingLocation,from:nil))
        }
        override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { edge=placement(sender); needsDisplay=true; return .copy }
        override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation { edge=placement(sender); needsDisplay=true; return .copy }
        override func draggingExited(_ sender:NSDraggingInfo?) { edge=nil; needsDisplay=true }
        override func prepareForDragOperation(_ sender:NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
            let position=placement(sender); edge=nil; needsDisplay=true
            guard let raw=sender.draggingPasteboard.string(forType:.string) else { return false }
            return accept?(raw,position) ?? false
        }
        override func draw(_ dirtyRect:NSRect) {
            guard let edge else { return }
            let rect:NSRect
            switch edge {
            case .top: rect=NSRect(x:0,y:0,width:bounds.width,height:30)
            case .bottom: rect=NSRect(x:0,y:bounds.height-30,width:bounds.width,height:30)
            case .left: rect=NSRect(x:0,y:0,width:42,height:bounds.height)
            case .right: rect=NSRect(x:bounds.width-42,y:0,width:42,height:bounds.height)
            case .replace: rect=bounds.insetBy(dx:42,dy:30)
            }
            NSColor.systemOrange.withAlphaComponent(0.16).setFill(); rect.fill()
        }
    }
}
