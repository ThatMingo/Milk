import SwiftUI
import AppKit
import MilkLayout
import MilkExtensionKit
import MilkExtensionHost

struct MainWindow: View {
    @ObservedObject var state: ShellState
    var body: some View {
        ZStack {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                SidebarView(state:state).frame(width:state.sidebarWidth).background(ShellGeometryMarker(name:"sidebar")).transition(.move(edge:.leading).combined(with:.opacity))
                SidebarDivider(state:state).frame(width:1)
            }
            ZStack {
            VStack(spacing: 0) {
                topBar
                Hairline()
                if state.isEditingLayout { layoutToolbar; Hairline() }
                WorkspaceGrid(state: state)
                Hairline()
                statusBar
            }.opacity(state.takeover == nil ? 1 : 0)
                .allowsHitTesting(state.takeover == nil).accessibilityHidden(state.takeover != nil)
            }
        }.opacity(state.takeover == nil ? 1 : 0)
            .allowsHitTesting(state.takeover == nil).accessibilityHidden(state.takeover != nil)
        if let screen=state.takeover {
            TakeoverShell(state:state,screen:screen) { state.takeover=nil }
        }
        }
        .overlay(alignment: .top) {
            if let notice = state.workspace.git.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(MilkTheme.line))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3).padding(.top, 58).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $state.runtimeConfigurationVisible) {
            RuntimeConfigurationDialog(state: state) { state.runtimeConfigurationVisible = false }
        }
        .animation(.easeInOut(duration:0.16),value:state.sidebarVisible)
        .font(.system(size: 13)).foregroundStyle(MilkTheme.ink)
        .background(MilkTheme.canvas)
        
        .environment(\.milkExtensionRegistry,state.nativeExtensions.registry)
        .environment(\.milkExtensionActionContext,.init(workspaceURL:state.workspace.workspace?.url,fileURL:state.workspace.activeBuffer?.url))
        .ignoresSafeArea()
    }

    private var topBar: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal,showsIndicators:false) {
                topBarContents
                    .frame(width:max(state.sidebarVisible ? 360:470,geometry.size.width))
            }
        }.frame(height:MilkTheme.topHeight-1)
    }
    private var topBarContents: some View {
        HStack(spacing: 8) {
            if !state.sidebarVisible {
                SidebarToggle(state:state).padding(.leading,76)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                panelToggle(.chat, icon: "bubble.left")
                panelToggle(.code, icon: "chevron.left.forwardslash.chevron.right")
                panelToggle(.preview, icon: "eye")
                panelToggle(.terminal, icon: "terminal")
            }.padding(2).background(MilkTheme.segment, in: RoundedRectangle(cornerRadius: 8))
            ForEach(state.nativeExtensions.registry.panels.filter { $0.item.topbar }) { panel in
                if let element=WorkspaceElement(rawValue:panel.id) { panelToggle(element,icon:panel.item.systemImage) }
            }
            ExtensionSlot(point:.workspaceToolbar)
            MilkTheme.line.frame(width: 1, height: 18)
            Button { state.isEditingLayout.toggle() } label: {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 14))
            }
            .buttonStyle(MilkButtonStyle(selected: state.isEditingLayout))
            .accessibilityLabel("Layout").help("Edit workspace layout")
        }
        .padding(.horizontal, 12).frame(height: MilkTheme.topHeight - 1)
    }

    private func panelToggle(_ element: WorkspaceElement, icon: String) -> some View {
        Button { state.change { $0.toggle(element) } } label: {
            HStack(alignment:.center,spacing:7) {
                Image(systemName:icon).font(.system(size:11))
                    .frame(width:state.layout.elements.contains(element) ? 14:nil,alignment:.center)
                if state.layout.elements.contains(element) { Text(element.title).font(.system(size:12.5)) }
            }.padding(.horizontal,state.layout.elements.contains(element) ? 4:0)
        }
        .buttonStyle(MilkButtonStyle(selected: state.layout.elements.contains(element)))
        .accessibilityLabel("Toggle \(element.title)")
        .accessibilityValue(state.layout.elements.contains(element) ? "Shown" : "Hidden")
        .help("Show or hide \(element.title)")
    }

    private var layoutToolbar: some View {
        GeometryReader { geometry in ScrollView(.horizontal,showsIndicators:false) { HStack(spacing: 10) {
            Text("Layout Edit").fontWeight(.semibold)
            Menu {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { state.applyPreset(preset) }
                }
            } label: { Label(state.layout.selectedName, systemImage: "rectangle.split.3x1") }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 118)
            Menu("Saved") {
                ForEach(state.layout.saved) { saved in Button(saved.name) { state.change({ $0.restore(saved) },preserve:false) } }
                Button("Save Custom Layout…") { saveLayout() }
            }.fixedSize()
            ForEach(state.panelElements) { e in
                Label(e.title,systemImage:"line.3.horizontal").font(.system(size:11)).padding(4).background(MilkTheme.segment,in:RoundedRectangle(cornerRadius:4)).contentShape(Rectangle()).onDrag { return NSItemProvider(object:e.rawValue as NSString) }
            }
            Spacer(minLength: 8)
            Button("Reset") { state.applyPreset(state.layout.preset ?? .chat) }.buttonStyle(MilkButtonStyle(bordered: true))
            Button("Done") { state.isEditingLayout = false }.buttonStyle(MilkButtonStyle(bordered: true))
        }.padding(.horizontal, 14).frame(minWidth:geometry.size.width).frame(height:43) } }.frame(height:43).background(MilkTheme.surface)
    }

    private func saveLayout() {
        let alert=NSAlert(); alert.messageText="Save Custom Layout"
        let input=NSTextField(string:"Custom \(state.layout.saved.count+1)"); input.frame=NSRect(x:0,y:0,width:230,height:24)
        alert.accessoryView=input; alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.layout.save(name:input.stringValue) }
    }

    private var statusBar: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal,showsIndicators:false) { statusContents(compact:geometry.size.width < 850).frame(minWidth:geometry.size.width).frame(height:MilkTheme.statusHeight-1,alignment:.center) }
        }
        .padding(.horizontal, 14).frame(height: MilkTheme.statusHeight - 1)
        .background(MilkTheme.surface)
        .background(ShellGeometryMarker(name: "status"))
        .accessibilityElement(children: .contain).accessibilityLabel("Global status bar")
    }

    private func statusContents(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            HStack(spacing: 5) {
                StateDot(state:state.activityState)
                Text(state.taskLabel)
            }.help(state.taskLabel)
            HStack(spacing: 5) {
                Circle().fill(MilkTheme.green).frame(width: 6, height: 6)
                Text("\(state.agent.selectedModel?.provider ?? "No provider") · \(state.selectedComposerModel?.name ?? "No model")")
            }.help("Active agent provider and model")
            Button { state.destination = "Git"; if !state.sidebarVisible { state.toggleSidebar() } } label: { Label(state.workspace.git.repository?.summary ?? (state.workspace.git.checked ? "No Git repository" : "Git"), systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(.plain)
            if state.workspace.git.failure != nil { Image(systemName:"exclamationmark.circle").foregroundStyle(MilkTheme.red).help("Git error — open Git to review") }
            if let previewStatus = state.preview.statusLabel { Text(previewStatus) }
            ForEach(Array(state.nativeExtensions.registry.status.prefix(4))) { status in
                status.item.content(.init(workspaceURL:state.workspace.workspace?.url)).id(status.id).frame(maxWidth:200).clipped()
            }
            Spacer(minLength: 0)
            Label(state.approvalMode ? "Approval" : "Autonomous", systemImage: "shield")
            Text(compact ? "\(state.workspace.errorCount) E · \(state.workspace.warningCount) W":"\(state.workspace.errorCount) errors · \(state.workspace.warningCount) warnings")
        }.font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(MilkTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

struct SidebarView: View {
    @State private var workspaceMenu=false
    @ObservedObject var state: ShellState
    var body: some View {
        VStack(spacing: 0) {
            // Native traffic-light buttons occupy the leading portion of this row.
            HStack { Spacer(); SidebarToggle(state:state) }
                .padding(.trailing, 10).frame(height: 52)
            Button { workspaceMenu=true } label: { HStack(spacing: 10) {
                MilkCartonOutline().stroke(MilkTheme.ink,style:StrokeStyle(lineWidth:1.5,lineCap:.round,lineJoin:.round)).frame(width:22,height:24).frame(width:28,height:28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.workspace.workspace?.name ?? "Open Workspace").fontWeight(.semibold).lineLimit(1)
                    Text(state.workspace.workspace?.displayPath ?? "Choose a local folder").font(.system(size: 11)).lineLimit(1).truncationMode(.middle).foregroundStyle(MilkTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(MilkTheme.muted)
            }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
                }.buttonStyle(.plain).accessibilityLabel("Workspace menu")
                .popover(isPresented:$workspaceMenu,arrowEdge:.bottom) {
                    VStack(alignment:.leading,spacing:4) {
                        Button("Open Folder…") { workspaceMenu=false; state.workspace.chooseWorkspace() }
                        Menu("Recent Workspaces") {
                            if state.workspace.recent.isEmpty { Text("No recent workspaces") }
                            ForEach(state.workspace.recent,id:\.path) { url in
                                Button((url.path as NSString).abbreviatingWithTildeInPath) { workspaceMenu=false; state.workspace.switchWorkspace(url) }
                            }
                        }
                        Button("Restore Last Workspace") { workspaceMenu=false; if let last=state.workspace.persistence.last { state.workspace.switchWorkspace(last) } }.disabled(state.workspace.persistence.last == nil)
                        Button("Reveal in Finder") { state.workspace.reveal(); workspaceMenu=false }.disabled(state.workspace.workspace == nil)
                        Button("Copy Path") { state.workspace.copyPath(); workspaceMenu=false }.disabled(state.workspace.workspace == nil)
                        Divider()
                        Button("Close Workspace") { workspaceMenu=false; state.workspace.requestCloseWorkspace() }.disabled(state.workspace.workspace == nil)
                    }.buttonStyle(MilkButtonStyle()).padding(8).frame(width:230)
                }
            HStack(spacing: 2) {
                ForEach(state.sidebarDestinations) { item in
                    destination(item.icon,item.id,title:item.title,count:item.id == "Git" && state.workspace.git.repository?.dirty == true ? String(state.workspace.git.repository!.files.count):(item.badge ?? ""))
                }
            }.padding(2).background(MilkTheme.workspaceTabsSurface, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10).padding(.bottom, 10)
            if state.destination == "Files" {
                FileExplorerView(store:state.workspace,sidebarWidth:state.sidebarWidth)
            } else if state.destination == "Sessions" {
                SessionsSidebarView(state: state)
            } else if state.destination == "Git" {
                GitSidebarView(store:state.workspace,git:state.workspace.git)
            } else if let item=state.nativeExtensions.registry.sidebar.first(where:{ $0.id == state.destination }) {
                item.item.content(.init(workspaceURL:state.workspace.workspace?.url)).id(item.id).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Hairline()
            HStack(spacing:8) {
                bottomControl("Extensions",icon:"square.grid.2x2")
                bottomControl("Settings",icon:"gearshape")
                Spacer()
            }.padding(.horizontal,12).frame(height:46)
        }.background(MilkTheme.sidebar)
    }

    private func bottomControl(_ name:String,icon:String) -> some View {
        Button { state.takeover=name } label: { Image(systemName:icon).font(.system(size:15)).frame(width:13,height:16) }
            .buttonStyle(MilkButtonStyle(selected:state.takeover == name)).help(name).accessibilityLabel(name)
    }
    private func destination(_ icon: String, _ name: String, title: String? = nil, count: String = "") -> some View {
        Button { state.destination=name } label: {
            HStack(spacing:3) {
                Group {
                    if name == "Git" {
                        SettingsReferenceIcon(category:"Git").stroke(style:StrokeStyle(lineWidth:1.1,lineCap:.round,lineJoin:.round)).frame(width:13,height:13)
                    } else { Image(systemName:icon).font(.system(size:13)) }
                }
                    .overlay(alignment: .topTrailing) {
                        if name == "Sessions", let attention = state.sessionAttention {
                            StateDot(state: attention).padding(2).background(MilkTheme.sidebar, in: Circle()).offset(x: 8, y: -7)
                        }
                    }
                if !count.isEmpty { Text(count).font(.system(size:10,weight:.bold)).foregroundStyle(MilkTheme.amber) }
            }.frame(maxWidth:.infinity)
        }.buttonStyle(MilkButtonStyle(selected:state.destination == name))
            .accessibilityLabel(title ?? name).accessibilityValue(name == "Sessions" ? (state.sessionAttention?.rawValue ?? "No session alerts") : count).help(title ?? name)

    }
}


struct SidebarToggle: View {
    @ObservedObject var state: ShellState
    var body: some View {
        Button { state.toggleSidebar() } label: { Image(systemName:"sidebar.left").font(.system(size:12)).frame(width:14) }
            .buttonStyle(MilkButtonStyle()).accessibilityLabel("Toggle sidebar").accessibilityValue(state.sidebarVisible ? "Expanded":"Collapsed")
            .help(state.sidebarVisible ? "Collapse sidebar":"Expand sidebar")
    }
}
private struct SidebarDivider: View {
    @ObservedObject var state: ShellState
    @State private var start:CGFloat?
    var body: some View {
        MilkTheme.line.overlay {
            Color.clear.frame(width:9).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged { value in
                    if start == nil { start=state.sidebarWidth }
                    state.setSidebarWidth((start ?? state.sidebarWidth)+value.translation.width)
                }.onEnded { _ in start=nil })
                .accessibilityLabel("Resize sidebar").accessibilityAdjustableAction { direction in state.setSidebarWidth(state.sidebarWidth+(direction == .increment ? 20:-20)) }
        }.zIndex(5)
    }
}

/// A takeover owns the whole window surface, including its own navigation.
/// The project shell stays mounted underneath so closing restores it verbatim.
private struct TakeoverShell: View {
    @ObservedObject var state:ShellState
    @ObservedObject private var extensions:ExtensionService
    init(state:ShellState,screen:String,close:@escaping ()->Void) {self.state=state;self.screen=screen;self.close=close;extensions=state.extensions}
    let screen:String
    let close:()->Void
    private var isSettings:Bool { screen == "Settings" }
    private var items:[String] {
        isSettings ? (["General","Agents","Editor","Agent","Git","Extensions","Preview","Updates","Advanced"] + state.nativeExtensions.registry.settings.map(\.id)) : ["Installed","Enabled","Updates","Problems"]
    }
    private var selection:String { isSettings ? state.settingsSelection:state.extensionsSelection }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:0) {
                    Color.clear.frame(height:MilkTheme.topHeight)
                    Text(screen.uppercased()).font(.system(size:18,weight:.semibold)).foregroundStyle(MilkTheme.muted)
                        .padding(.horizontal,18).padding(.top,8).padding(.bottom,18)
                    ScrollView {
                        VStack(spacing:isSettings ? 3:2) {
                            ForEach(items,id:\.self) { item in
                                Button {
                                    if isSettings { state.settingsSelection=item } else { state.extensionsSelection=item }
                                } label: { HStack(spacing:isSettings ? 9:6) {
                                    if isSettings {
                                        Group {
                                            if let page=state.nativeExtensions.registry.settings.first(where:{ $0.id == item }) { Image(systemName:page.item.systemImage).foregroundStyle(.white) }
                                            else { SettingsReferenceIcon(category:item).stroke(.white,style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round)) }
                                        }.frame(width:12,height:12).frame(width:20,height:20).background(tileColor(item),in:RoundedRectangle(cornerRadius:5))
                                    }
                                    Text(state.nativeExtensions.registry.settings.first(where:{ $0.id == item })?.item.title ?? item).fontWeight(selection == item ? .semibold:.regular); Spacer(minLength:0)
                                    if !isSettings { Text("\(count(item))").font(.system(size:11.5)).foregroundStyle(item == "Problems" ? MilkTheme.red:MilkTheme.muted) }
                                }.padding(.horizontal,8) }
                                    .buttonStyle(.plain).frame(height:isSettings ? 33:24).background(selection == item ? MilkTheme.selected:Color.clear,in:RoundedRectangle(cornerRadius:isSettings ? 7:6))
                            }
                        }.padding(.horizontal,10)
                        if !isSettings {
                            VStack(spacing:8) {
                                Image(systemName:"square.and.arrow.down").font(.system(size:20)).foregroundStyle(MilkTheme.muted)
                                Text("Drop a .milkext or local Pi extension").font(.system(size:12)).foregroundStyle(MilkTheme.muted).multilineTextAlignment(.center)
                                Button("Install Extension…") { state.chooseExtensionInstall() }
                                Button("Add Development Extension…") { state.chooseExtensionInstall(development:true) }.disabled(state.extensions.busy)
                            }.padding(16).frame(maxWidth:.infinity).overlay(RoundedRectangle(cornerRadius:10).stroke(MilkTheme.line,style:StrokeStyle(lineWidth:1.5,dash:[4,3]))).padding(.horizontal,10).padding(.top,14)
                                .onDrop(of:["public.file-url"],isTargeted:nil) { providers in
                                    guard let provider=providers.first else { return false }
                                    _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in state.installExtension(url) } } }; return true
                                }
                        }
                    }
                }.frame(width:isSettings ? 212:248).background(MilkTheme.sidebar)
                MilkTheme.line.frame(width:1)
                VStack(spacing:0) {
                    HStack {
                        Text(isSettings ? (state.nativeExtensions.registry.settings.first(where:{ $0.id == selection })?.item.title ?? selection):screen).font(.system(size:15,weight:.semibold))
                        Spacer(minLength:8)
                        Button(action:close) { Label("Back to Workspace",systemImage:"arrow.left") }
                            .buttonStyle(MilkButtonStyle()).help("Close \(screen) and restore workspace")
                    }.padding(.horizontal,24).frame(height:MilkTheme.topHeight)
                    Hairline()
                    if isSettings {
                        SettingsContent(state:state,category:selection).id(selection)
                    } else {
                        ExtensionsContent(service:state.extensions,agent:state.agent,native:state.nativeExtensions,category:selection,workspace:state.workspace.workspace?.url,refreshOnOpen:state.settings.refreshExtensionsOnOpen)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity).background(MilkTheme.canvas)
            }
        }.background(MilkTheme.canvas)
    }
    private func count(_ category:String)->Int {
        switch category {case "Installed":return extensions.records.count+state.nativeExtensions.records.count;case "Enabled":return extensions.records.filter(\.enabled).count+state.nativeExtensions.records.filter(\.enabled).count;case "Problems":return extensions.problems.count+state.nativeExtensions.records.filter { $0.problem != nil }.count+state.nativeExtensions.diagnostics.count;case "Updates":return state.nativeExtensions.records.filter(\.restartRequired).count;default:return 0}
    }
    private func tileColor(_ item:String) -> Color { MilkTheme.settingsTile(item) }
}
