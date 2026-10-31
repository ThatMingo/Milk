import AppKit
import SwiftUI

struct ComposerCommandMenu: View {
    @ObservedObject var commands: SlashCommandService
    let maximumHeight: CGFloat
    private var height: CGFloat { min(300,min(max(50,maximumHeight),CGFloat(max(1,commands.results.count))*36+16)) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing:2) {
                    if commands.results.isEmpty {
                        Text("No commands found").font(.system(size:12)).foregroundStyle(MilkTheme.muted).frame(maxWidth:.infinity,alignment:.leading).frame(height:34).padding(.horizontal,10)
                    }
                    ForEach(commands.results) { command in
                        ComposerCommandRow(commands:commands,command:command).id(command.id)
                    }
                }.padding(6)
            }.frame(height:height)
                .onChange(of:commands.selectedID) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
                .onChange(of:commands.results.map(\.id)) { _,_ in if let id=commands.selectedID { proxy.scrollTo(id,anchor:.center) } }
                .onAppear { if let id=commands.selectedID { proxy.scrollTo(id,anchor:.center) } }
        }.foregroundStyle(MilkTheme.ink).background(MilkTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(MilkTheme.line)).clipShape(RoundedRectangle(cornerRadius:12))
            .accessibilityElement(children:.contain).accessibilityLabel("Slash commands").accessibilityIdentifier("milk.composer.slash-surface")
    }
}

private struct ComposerCommandRow: View {
    @ObservedObject var commands: SlashCommandService
    let command: SlashCommand
    private var label: String { "/"+command.name+(command.description.isEmpty ? "":". "+command.description) }
    var body: some View {
        Button { commands.choose(command.id) } label: {
            HStack(spacing:12) {
                Text("/"+command.name).font(.system(size:12.5,weight:.medium,design:.monospaced)).lineLimit(1).layoutPriority(1)
                Spacer(minLength:4)
                Text(command.description).font(.system(size:12)).foregroundStyle(MilkTheme.muted).lineLimit(1)
                if let source=command.source.label { Text(source).font(.system(size:10)).foregroundStyle(MilkTheme.tertiaryText) }
            }.padding(.horizontal,10).frame(height:34).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                .background(commands.selectedID == command.id ? MilkTheme.selected:Color.clear,in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).disabled(command.unavailable != nil)
            .onHover { inside in if inside { commands.highlight(command.id) } }
            .accessibilityLabel(label)
            .accessibilityValue(command.unavailable ?? command.source.label ?? "Milk command")
            .accessibilityAddTraits(commands.selectedID == command.id ? .isSelected:[])
            .accessibilityIdentifier("milk.slash-command."+command.name)
            .help(command.unavailable ?? command.description)
    }
}

/// A nonactivating child panel leaves TextKit/VoiceOver editing in the composer and never takes layout space.
struct ComposerCommandAnchor: NSViewRepresentable {
    @ObservedObject var commands: SlashCommandService
    let maximumHeight: CGFloat
    var visible=true
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let view=Anchor(); view.identifier=NSUserInterfaceItemIdentifier("milk.geometry.slash-composer"); return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        let coordinator=context.coordinator
        coordinator.dismiss={ commands.dismiss() }
        view.reposition={ [weak coordinator,weak view] in if let view { coordinator?.position(view) } }
        if visible && commands.popup == .slash {
            coordinator.content={ width in AnyView(ComposerCommandMenu(commands:commands,maximumHeight:maximumHeight).frame(width:width)) }
            coordinator.show(view)
        } else { coordinator.close() }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.close() }
    final class Anchor: NSView {
        var reposition: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); reposition?() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reposition?() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); reposition?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reposition?() }
    }
    final class Panel: NSPanel { override var canBecomeKey: Bool { false } }
    final class Coordinator {
        private var panel: Panel?
        private var host: NSHostingView<AnyView>?
        private var observers: [NSObjectProtocol] = []
        private var monitor: Any?
        private weak var parent: NSWindow?
        private weak var anchor: Anchor?
        private var positioning=false
        var content: ((CGFloat) -> AnyView)?
        var dismiss: (() -> Void)?
        func show(_ anchor: Anchor) {
            self.anchor=anchor
            if panel == nil {
                let panel=Panel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.identifier=NSUserInterfaceItemIdentifier("milk.composer.slash-menu")
                panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
                panel.isReleasedWhenClosed=false; panel.hidesOnDeactivate=true
                let host=NSHostingView(rootView:AnyView(EmptyView())); panel.contentView=host
                self.panel=panel; self.host=host
                monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.window !== self.panel {
                        if let anchor=self.anchor, event.window === anchor.window, anchor.bounds.contains(anchor.convert(event.locationInWindow,from:nil)) { return event }
                        self.dismiss?()
                    }
                    return event
                }
            }
            position(anchor)
        }
        func position(_ anchor: Anchor) {
            guard !positioning, let window=anchor.window, let panel, let host, anchor.bounds.width > 1 else { return }
            positioning=true; defer { positioning=false }
            if parent !== window {
                observers.forEach(NotificationCenter.default.removeObserver); observers=[]; parent=window
                for name in [NSWindow.didMoveNotification,NSWindow.didResizeNotification,NSWindow.didEndLiveResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self,weak anchor] _ in if let anchor { self?.position(anchor) } })
                }
            }
            panel.appearance=window.effectiveAppearance
            let rect=window.convertToScreen(anchor.convert(anchor.bounds,to:nil))
            host.rootView=content?(rect.width) ?? AnyView(EmptyView())
            let size=host.fittingSize
            let frame=NSRect(x:rect.minX,y:rect.maxY+14,width:rect.width,height:max(1,size.height))
            if panel.frame != frame { panel.setFrame(frame,display:true) }
            if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel,ordered:.above) }
            if !panel.isVisible { panel.orderFront(nil) }
        }
        func close() {
            observers.forEach(NotificationCenter.default.removeObserver); observers=[]
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor=nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel=nil; host=nil; parent=nil
        }
        deinit { close() }
    }
}
