import SwiftUI
import AppKit

// Capabilities are supplied by the active backend and queried again after each model change.
struct ComposerEffort: Identifiable, Equatable {
    let id:String
    let title:String
}
struct ComposerModel: Identifiable, Equatable {
    let id:String
    let name:String
    let efforts:[ComposerEffort]
    let defaultEffortID:String?

}
enum ComposerPermissionMode: String, CaseIterable, Identifiable, Codable {
    case approval, autonomous
    var id:String { rawValue }
    var title:String { self == .approval ? "Ask for approval":"Autonomous" }
    var symbol:String { self == .approval ? "hand.raised":"shield.lefthalf.filled" }
    var detail:String {
        self == .approval ? "Ask before actions that require permission":"Allow Pi tools to execute without Milk approval prompts"
    }
}
struct ComposerPermissionControl: View {
    @ObservedObject var state:ShellState
    private var showing: Bool {
        get { state.slashCommands.popup == .permissions }
        nonmutating set { if newValue { state.presentComposerPopup(.permissions) } else if showing { state.presentComposerPopup(nil) } }
    }
    var body: some View {
        Button { if state.agent.presentedApproval == nil { showing.toggle() } } label: {
            Image(systemName:state.permissionMode.symbol).font(.system(size:12))
        }.buttonStyle(MilkButtonStyle()).help(state.permissionMode.title)
            .accessibilityLabel("Permissions").accessibilityValue(state.permissionMode.title).accessibilityIdentifier("milk.composer.permissions")
            .onChange(of:state.agent.presentedApproval?.id) { _, value in if value != nil { state.slashCommands.dismiss() } }
            .popover(isPresented:Binding(get:{ showing && state.agent.presentedApproval == nil },set:{ showing=$0 }),arrowEdge:.top) {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(ComposerPermissionMode.allCases) { mode in
                        Button {
                            state.permissionMode=mode
                            showing=false
                        } label: {
                            HStack(alignment:.top,spacing:10) {
                                Image(systemName:mode.symbol).frame(width:16).padding(.top,2)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(mode.title).fontWeight(.medium)
                                    Text(mode.detail).font(.system(size:11)).foregroundStyle(MilkTheme.muted).fixedSize(horizontal:false,vertical:true)
                                }
                                Spacer(minLength:0)
                                Image(systemName:"checkmark").opacity(state.permissionMode == mode ? 1:0)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(state.permissionMode == mode ? MilkTheme.surface:Color.clear,in:RoundedRectangle(cornerRadius:7))
                            .accessibilityAddTraits(state.permissionMode == mode ? .isSelected:[])
                    }
                }.padding(8).frame(width:310).foregroundStyle(MilkTheme.ink)
            }
    }
}

struct ComposerModelControl: View {
    @ObservedObject var state:ShellState
    let width:CGFloat
    private var showing: Bool {
        get { state.slashCommands.popup == .model || state.slashCommands.popup == .thinking }
        nonmutating set { if newValue { state.presentComposerPopup(.thinking) } else if showing { state.presentComposerPopup(nil) } }
    }
    private var choosingModel: Bool {
        get { state.slashCommands.popup == .model }
        nonmutating set { state.presentComposerPopup(newValue ? .model:.thinking) }
    }
    private let pickerWidth:CGFloat=290
    private var effortIndex:Double {
        Double(state.selectedComposerModel?.efforts.firstIndex(where:{$0.id == state.selectedComposerEffort?.id}) ?? 0)
    }
    private var controlTitle:String {
        showing ? (choosingModel ? "Select model":"Select effort") : "\(state.selectedComposerModel?.name ?? "No model") · \(state.selectedComposerEffort?.title ?? "Default")"
    }
    var body: some View {
        Button { if state.agent.presentedApproval == nil { state.presentComposerPopup(showing ? nil:.thinking) } } label: {
            HStack(spacing:4) {
                Text(controlTitle).lineLimit(1).truncationMode(.middle)
                Image(systemName:"chevron.down").font(.system(size:8))
            }.font(.system(size:11)).foregroundStyle(showing ? MilkTheme.ink:MilkTheme.muted)
                .frame(width:showing ? min(width,126):width,height:28,alignment:.center)
                .background(showing ? MilkTheme.segment:Color.clear,in:Capsule())
                .overlay(Capsule().stroke(showing ? MilkTheme.line:Color.clear,lineWidth:1))
                .frame(width:width,height:28,alignment:.center)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(controlTitle)
            .accessibilityLabel(controlTitle).accessibilityIdentifier("milk.composer.model")
            .accessibilityValue(state.selectedComposerEffort?.title ?? "Default")
            .onChange(of:state.agent.presentedApproval?.id) { _, value in if value != nil { state.slashCommands.dismiss() } }
            .background {
                FloatingPicker(isPresented:Binding(get:{ showing && state.agent.presentedApproval == nil },set:{ showing=$0 })) { Group {
                    if choosingModel { modelPicker } else { effortPicker }
                }.padding(18).frame(width:pickerWidth).foregroundStyle(MilkTheme.ink) }
            }
    }
    private var effortPicker: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(state.selectedComposerEffort?.title ?? "Default").font(.system(size:20,weight:.semibold))
                .frame(maxWidth:.infinity,alignment:.center)
            Button { choosingModel=true } label: {
                HStack(spacing:6) {
                    Text(state.selectedComposerModel?.name ?? "No model").lineLimit(1).truncationMode(.middle)
                    Image(systemName:"chevron.right").font(.system(size:10))
                }.font(.system(size:12)).foregroundStyle(MilkTheme.muted)
                    .frame(maxWidth:.infinity,alignment:.center).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Select model")
            if let model=state.selectedComposerModel,model.efforts.count>1 {
                VStack(spacing:4) {
                    DiscreteEffortSlider(value:Binding(get:{effortIndex},set:{ index in
                        let step=max(0,min(model.efforts.count-1,Int(index.rounded())))
                        state.selectComposerEffort(model.efforts[step].id)
                    }),steps:model.efforts.count)
                        .frame(height:24)
                        .accessibilityValue(state.selectedComposerEffort?.title ?? "Default")
                    HStack(spacing:0) {
                        ForEach(Array(model.efforts.enumerated()),id:\.element.id) { index,effort in
                            if index>0 { Spacer(minLength:0) }
                            Button(effort.title) {
                                withAnimation(.easeInOut(duration:0.12)) { state.selectComposerEffort(effort.id) }
                            }.buttonStyle(.plain).font(.system(size:10,weight:state.selectedComposerEffort == effort ? .semibold:.regular))
                        }
                    }
                }
            }
        }
    }
    private var modelPicker: some View {
        VStack(alignment:.leading,spacing:12) {
            Button { choosingModel=false } label: {
                HStack {
                    Image(systemName:"chevron.left")
                    Text("Select model").fontWeight(.semibold)
                }.padding(6).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Back to effort")
                .padding(-6)
            ForEach(state.availableComposerModels) { model in
                Button {
                    state.selectComposerModel(model.id)
                    choosingModel=false
                } label: {
                    HStack {
                        Text(model.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength:8)
                        Image(systemName:"checkmark").opacity(state.selectedComposerModel?.id == model.id ? 1:0)
                    }.padding(.vertical,8).background(state.selectedComposerModel?.id == model.id ? MilkTheme.modeSelectionSurface:Color.clear).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.font(.system(size:12))
    }
}

/// Milk owns the track and thumb, so presentation never depends on native-cell rendering.
private struct DiscreteEffortSlider: View {
    @Binding var value:Double
    let steps:Int
    private let diameter:CGFloat=14
    private var last:Double { Double(max(1,steps-1)) }
    var body: some View {
        GeometryReader { geometry in
            let travel=max(1,geometry.size.width-diameter)
            let position=CGFloat(max(0,min(last,value))/last)*travel
            ZStack(alignment:.leading) {
                Capsule().fill(MilkTheme.line).frame(height:3).padding(.horizontal,diameter/2)
                Capsule().fill(MilkTheme.accent).frame(width:position,height:3).offset(x:diameter/2)
                ForEach(0..<max(2,steps),id:\.self) { index in
                    Circle().fill(MilkTheme.muted.opacity(0.5)).frame(width:4,height:4)
                        .offset(x:diameter/2-2+CGFloat(index)/CGFloat(max(1,steps-1))*travel)
                }
                Circle().fill(MilkTheme.elevatedSurface).overlay(Circle().stroke(MilkTheme.muted.opacity(0.4),lineWidth:0.5))
                    .shadow(color:.black.opacity(0.18),radius:2,y:1)
                    .frame(width:diameter,height:diameter).offset(x:position)
            }.frame(height:geometry.size.height).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    let fraction=max(0,min(1,(event.location.x-diameter/2)/travel))
                    withAnimation(.easeOut(duration:0.1)) { value=(Double(fraction)*last).rounded() }
                })
                .animation(.easeOut(duration:0.1),value:value)
        }.accessibilityElement().accessibilityLabel("Reasoning effort")
            .accessibilityAdjustableAction { direction in
                value=max(0,min(last,value+(direction == .increment ? 1:-1)))
            }
    }
}

/// Borderless child panel supplies an arrowless popup without private popover APIs.
private struct FloatingPicker<Content:View>: NSViewRepresentable {
    @Binding var isPresented:Bool
    @ViewBuilder let content:()->Content
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> Anchor { Anchor() }
    func updateNSView(_ view:Anchor,context:Context) {
        let coordinator=context.coordinator
        coordinator.dismiss={ isPresented=false }
        view.reposition={ [weak coordinator,weak view] in
            if let view { coordinator?.position(view) }
        }
        if isPresented {
            let root=AnyView(content().fixedSize(horizontal:false,vertical:true)
                .background(MilkTheme.canvas,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(MilkTheme.line,lineWidth:1))
                .clipShape(RoundedRectangle(cornerRadius:12)))
            coordinator.show(root,anchor:view)
        } else { coordinator.close() }
    }
    static func dismantleNSView(_ view:Anchor,coordinator:Coordinator) { coordinator.close() }
    final class Anchor:NSView {
        var reposition:(()->Void)?
        override func hitTest(_ point:NSPoint)->NSView? { nil }
        override func layout() { super.layout(); reposition?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reposition?() }
    }
    final class Panel:NSPanel {
        override var canBecomeKey:Bool { true }
    }
    final class Coordinator {
        var dismiss:(()->Void)?
        var panel:Panel?
        var host:NSHostingView<AnyView>?
        var local:Any?
        var global:Any?
        weak var anchor:Anchor?
        func show(_ root:AnyView,anchor:Anchor) {
            self.anchor=anchor
            if let host { host.rootView=root }
            else {
                let panel=Panel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.identifier=NSUserInterfaceItemIdentifier("milk.composer.model-picker")
                panel.isOpaque=false; panel.backgroundColor = .clear
                panel.appearance=nil
                panel.hasShadow=true; panel.isReleasedWhenClosed=false
                let host=NSHostingView(rootView:root)
                panel.contentView=host
                self.panel=panel; self.host=host
                local=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .keyDown && event.keyCode == 53 { self.dismiss?(); return nil }
                    if event.type != .keyDown && event.window !== self.panel {
                        if let anchor=self.anchor,let window=anchor.window,event.window === window,
                           anchor.bounds.contains(anchor.convert(event.locationInWindow,from:nil)) { return event }
                        self.dismiss?()
                    }
                    return event
                }
                global=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.dismiss?() }
            }
            position(anchor)
        }
        func position(_ anchor:Anchor) {
            guard let parent=anchor.window,let panel,let host else { return }
            let rect=parent.convertToScreen(anchor.convert(anchor.bounds,to:nil))
            let size=host.fittingSize
            // Both picker pages share a fixed width and the same 12-point gap.
            panel.setFrame(NSRect(x:rect.midX-size.width/2,y:rect.maxY+12,width:size.width,height:size.height),display:true)
            if panel.parent !== parent { parent.addChildWindow(panel,ordered:.above) }
            panel.orderFront(nil)
        }
        func close() {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
            local=nil; global=nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel=nil; host=nil
        }
        deinit { close() }
    }
}
