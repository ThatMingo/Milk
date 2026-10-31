import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CodePanel: View {
    @ObservedObject var state: ShellState
    var body: some View { VStack(spacing:0) { ExtensionSlot(point:.codeToolbar); RealCodePanel(store:state.workspace) } }
}

private struct RealCodePanel: View {
    @ObservedObject var store:WorkspaceStore
    @State private var showingDiagnostics=false
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:0) {
                ForEach(store.session.panes) { pane in
                    if pane.id != store.session.panes.first?.id { MilkTheme.line.frame(width:1) }
                    EditorPaneView(store:store,pane:pane)
                }
            }
            Hairline()
            HStack(spacing:8) {
                Text("Ln \(store.selectionLine), Col \(store.selectionColumn)")
                Spacer(minLength:0)
                Button { showingDiagnostics.toggle() } label: {
                    Label("\(store.errorCount) · \(store.warningCount)",systemImage:store.errorCount>0 ? "exclamationmark.circle":"exclamationmark.triangle")
                }.buttonStyle(.plain).help("Workspace diagnostics")
                    .popover(isPresented:$showingDiagnostics) { diagnosticList }
                Text(store.activeBuffer?.url.pathExtension.uppercased() ?? "Text")
                Menu {
                    Toggle("Word Wrap",isOn:$store.preferences.wordWrap)
                    Toggle("Indent with Tabs",isOn:$store.preferences.usesTabs)
                    Menu("Indent Width") { ForEach([2,4,8],id:\.self) { width in Button("\(width)") { store.preferences.indentWidth=width } } }
                    Divider()
                    Button("Increase Font Size") { store.preferences.fontSize=min(32,store.preferences.fontSize+1) }
                    Button("Decrease Font Size") { store.preferences.fontSize=max(9,store.preferences.fontSize-1) }
                    Button("Reset Font Size") { store.preferences.fontSize=12.5 }
                } label: { Text("\(store.preferences.usesTabs ? "Tabs":"Spaces"): \(store.preferences.indentWidth)") }.menuStyle(.borderlessButton).fixedSize()
                Text(store.activeBuffer?.encoding == .utf16LittleEndian || store.activeBuffer?.encoding == .utf16BigEndian ? "UTF-16":"UTF-8")
            }.font(.system(size:10.5)).foregroundStyle(MilkTheme.muted).padding(.horizontal,12).frame(height:24)
        }.background(MilkTheme.elevatedSurface)
    }
    private var diagnosticList: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Diagnostics").fontWeight(.semibold)
            if store.diagnostics.isEmpty { Text("No diagnostics. JSON validation is available; compiler and language-server providers can be added later.").foregroundStyle(MilkTheme.muted) }
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(store.diagnostics) { d in
                        Button {
                            store.attempt { try store.jump(to:d) }; showingDiagnostics=false
                        } label: {
                            HStack(alignment:.top,spacing:7) {
                                Image(systemName:d.severity == .error ? "xmark.circle":"exclamationmark.triangle").foregroundStyle(d.severity == .error ? MilkTheme.red:MilkTheme.amber)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(d.message).fixedSize(horizontal:false,vertical:true)
                                    Text("\(d.file.lastPathComponent):\(d.line):\(d.column) · \(d.source)").foregroundStyle(MilkTheme.muted)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight:240)
        }.font(.system(size:12)).padding(14).frame(width:380)
    }
}

private struct EditorPaneView: View {
    @ObservedObject var store:WorkspaceStore
    let pane:EditorPane
    private var buffer:FileBuffer? { pane.activeTab.flatMap { store.buffers[$0.path] } }
    private var active:Bool { store.activePane.id == pane.id }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:0) { ForEach(pane.tabs) { tab in fileTab(tab).id(tab.id) } }
                    }.onChange(of:pane.selected) { _,id in if let id { proxy.scrollTo(id,anchor:.trailing) } }
                        .onAppear { if let id=pane.selected { proxy.scrollTo(id,anchor:.trailing) } }
                }
                Button { store.activatePane(pane.id); if let buffer { store.saveInteractively(buffer) } } label: { Image(systemName:"square.and.arrow.down") }
                    .buttonStyle(MilkButtonStyle()).disabled(buffer == nil).accessibilityLabel("Save file").help("Save (⌘S)")
                Button { store.activatePane(pane.id); store.findVisible.toggle() } label: { Image(systemName:"magnifyingglass") }
                    .buttonStyle(MilkButtonStyle()).disabled(buffer == nil).accessibilityLabel("Find in file").help("Find in file (⌘F)")
                Button { store.activatePane(pane.id); store.toggleSplit() } label: { Image(systemName:store.split ? "rectangle":"rectangle.split.2x1") }
                    .buttonStyle(MilkButtonStyle(selected:store.split)).accessibilityLabel(store.split ? "Close split editor":"Split editor")
                    .help(store.split ? "Close split; retain tabs":"Open a second editor pane")
            }.frame(height:34).background(MilkTheme.surface)
                .onDrop(of:[UTType.utf8PlainText.identifier],isTargeted:nil) { receiveTab($0,target:nil) }
            Hairline()
            if let tab = pane.activeTab {
                HStack(spacing:6) {
                    let components=relativePath(URL(fileURLWithPath:tab.path)).components(separatedBy:"/")
                    ForEach(Array(components.enumerated()),id:\.offset) { index,segment in
                        if index>0 { Image(systemName:"chevron.right").font(.system(size:8)) }
                        Text(segment).foregroundStyle(index == components.count-1 ? MilkTheme.ink:MilkTheme.muted).lineLimit(1)
                    }
                    Spacer(minLength:0)
                    if tab.diffMode != true, let file = store.gitFile(for:tab.path) {
                        Button("Diff") { store.setDiffMode(true,staged:file.staged && !file.unstaged,pane:pane.id) }.buttonStyle(.plain)
                    }
                }.font(.system(size:11)).padding(.horizontal,14).frame(height:28).help(tab.path)
                Hairline()
                if tab.diffMode == true {
                    GitDiffView(store:store,git:store.git,pane:pane,path:tab.path,staged:tab.stagedDiff == true)
                } else if let buffer {
                if store.findVisible && active { FindInFileBar(store:store); Hairline() }
                if buffer.externallyChanged {
                    HStack(spacing:6) {
                        Image(systemName:"exclamationmark.triangle")
                        Text(buffer.missing ? "File removed on disk. Your buffer is preserved.":"File changed on disk. Your edits are preserved.").lineLimit(2)
                        Spacer(minLength:0)
                        Button("Resolve…") { store.resolveConflict(buffer) }.buttonStyle(.plain)
                    }.font(.system(size:11)).foregroundStyle(MilkTheme.amber).padding(8).background(MilkTheme.surface)
                }
                NativeCodeEditor(store:store,buffer:buffer,pane:pane).id(pane.id.uuidString+buffer.url.path)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    VStack(spacing:10) {
                        Text("This file is deleted or cannot be opened as editable text.").foregroundStyle(MilkTheme.muted)
                        Button("Return to Diff") { store.setDiffMode(true,pane:pane.id) }.buttonStyle(MilkButtonStyle(bordered:true))
                    }.font(.system(size:12)).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            } else {
                VStack(spacing:10) {
                    Text("No open files").font(.system(size:13)).foregroundStyle(MilkTheme.muted)
                    if store.workspace == nil { Button("Open Folder…") { store.chooseWorkspace() }.buttonStyle(MilkButtonStyle(bordered:true)) }
                    else { Text("Select a file in the explorer").font(.system(size:11)).foregroundStyle(MilkTheme.muted) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle()).onTapGesture { store.activatePane(pane.id) }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func relativePath(_ url:URL) -> String {
        guard let root=store.workspace?.url, url.path.hasPrefix(root.path+"/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count+1))
    }
    private func fileTab(_ tab:EditorTab) -> some View {
        let selected=pane.selected == tab.id
        return HStack(spacing:6) {
            Button { store.selectTab(tab.id,pane:pane.id) } label: {
                HStack(spacing:6) {
                    Image(systemName:"doc").font(.system(size:10)).foregroundStyle(MilkTheme.muted)
                    Text((tab.path as NSString).lastPathComponent).italicIf(!tab.pinned).lineLimit(1)
                    if store.buffers[tab.path]?.isModified == true { Circle().fill(MilkTheme.amber).frame(width:5,height:5) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).simultaneousGesture(TapGesture(count:2).onEnded { store.pin(tab.id,pane:pane.id) })
            Button { store.requestCloseTab(tab.id,pane:pane.id) } label: { Image(systemName:"xmark").font(.system(size:8)) }
                .buttonStyle(.plain).accessibilityLabel("Close \((tab.path as NSString).lastPathComponent)")
        }.font(.system(size:11.5)).padding(.horizontal,10).frame(height:34)
            .background(selected ? MilkTheme.selectionSurface:Color.clear)
            .focusEffectDisabled()
            .help(tab.path+(tab.pinned ? "":" · Preview"))
            .contextMenu {
                ExtensionMenuActions(point:.codeContextMenu,fileURL:URL(fileURLWithPath:tab.path))
                Button("Pin Tab") { store.pin(tab.id,pane:pane.id) }
                Button("Reveal in Finder") { store.reveal(URL(fileURLWithPath:tab.path)) }
                Button("Copy Path") { store.copyPath(URL(fileURLWithPath:tab.path)) }
                Button("Close") { store.requestCloseTab(tab.id,pane:pane.id) }
            }
            .onDrag { NSItemProvider(object:("milk-tab:"+tab.id.uuidString) as NSString) }
            .onDrop(of:[UTType.utf8PlainText.identifier],isTargeted:nil) { receiveTab($0,target:tab.id) }
    }
    private func receiveTab(_ providers:[NSItemProvider],target:UUID?) -> Bool {
        guard let provider=providers.first else { return false }
        provider.loadObject(ofClass:NSString.self) { value,_ in
            guard let raw=value as? String,raw.hasPrefix("milk-tab:"),let id=UUID(uuidString:String(raw.dropFirst(9))) else { return }
            Task { @MainActor in store.reorderTab(id,to:target,pane:pane.id) }
        }
        return true
    }
}
private extension View {
    @ViewBuilder func italicIf(_ value:Bool) -> some View { if value { self.italic() } else { self } }
}

private struct FindInFileBar: View {
    @ObservedObject var store:WorkspaceStore
    @FocusState private var focused:Bool
    var body: some View {
        HStack(spacing:5) {
            TextField("Find",text:$store.findQuery.text).textFieldStyle(.plain).focused($focused)
                .onSubmit { store.navigateFind(forward:true) }.frame(minWidth:45)
            Text(store.findError == nil ? "\(min(store.findIndex,store.findCount))/\(store.findCount)":"Invalid regex")
                .foregroundStyle(store.findError == nil ? MilkTheme.muted:MilkTheme.red).fixedSize()
            option("Aa",binding:$store.findQuery.caseSensitive,help:"Match case")
            option("W",binding:$store.findQuery.wholeWord,help:"Whole word")
            option(".*",binding:$store.findQuery.regex,help:"Regular expression")
            Button { store.navigateFind(forward:false) } label: { Image(systemName:"chevron.up") }.buttonStyle(.plain).help("Previous match (⇧⌘G)")
            Button { store.navigateFind(forward:true) } label: { Image(systemName:"chevron.down") }.buttonStyle(.plain).help("Next match (⌘G)")
            Button { store.findVisible=false } label: { Image(systemName:"xmark") }.buttonStyle(.plain).help("Close find (Escape)")
        }.font(.system(size:11)).padding(.horizontal,10).frame(height:30).background(MilkTheme.surface)
            .onAppear { focused=true }.onExitCommand { store.findVisible=false }
    }
    private func option(_ title:String,binding:Binding<Bool>,help:String) -> some View {
        Button { binding.wrappedValue.toggle() } label: { Text(title).padding(3).background(binding.wrappedValue ? MilkTheme.selected:Color.clear,in:RoundedRectangle(cornerRadius:3)) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help).accessibilityValue(binding.wrappedValue ? "On":"Off")
    }
}
