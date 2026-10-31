import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileExplorerView: View {
    @ObservedObject var store:WorkspaceStore
    let sidebarWidth:CGFloat
    @State private var dropTarget=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dropTypes=["dev.milk.workspace-path",UTType.fileURL.identifier]
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:0) {
                Text("FILES").font(.system(size:11,weight:.semibold)).foregroundStyle(MilkTheme.muted)
                Spacer()
                action("doc.badge.plus","New File") { store.newItem(folder:false) }
                if sidebarWidth>=240 {
                    action("folder.badge.plus","New Folder") { store.newItem(folder:true) }
                    action("arrow.clockwise","Refresh") { store.refresh(); store.checkExternalChanges() }
                    action("arrow.up.left.and.arrow.down.right","Collapse All") { store.expanded=[] }
                }
                Menu {
                    Toggle("Show Hidden Files",isOn:$store.showHidden)
                    Toggle("Show Ignored Files",isOn:$store.showIgnored)
                    Divider()
                    Button("New File…") { store.newItem(folder:false) }.disabled(store.workspace == nil)
                    Button("New Folder…") { store.newItem(folder:true) }.disabled(store.workspace == nil)
                    Button("Refresh") { store.refresh(); store.checkExternalChanges() }
                    Button("Collapse All") { store.expanded=[] }
                } label: { Image(systemName:"ellipsis").font(.system(size:12)).frame(width:14) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:30).accessibilityLabel("More file actions")
            }.padding(.leading,16).padding(.trailing,8).frame(height:26)
            ScrollView {
                LazyVStack(spacing:1) {
                    if let error=store.treeError {
                        Text(error).font(.system(size:11)).foregroundStyle(MilkTheme.red).padding(8)
                    }
                    if store.workspace == nil {
                        Button("Open Folder…") { store.chooseWorkspace() }.buttonStyle(MilkButtonStyle()).padding(.top,20)
                    } else if store.rows.isEmpty && store.treeError == nil {
                        Text("No visible files").font(.system(size:11)).foregroundStyle(MilkTheme.muted).padding(.top,20)
                    }
                    ForEach(store.rows) { node in row(node) }
                }.padding(.horizontal,8).frame(maxWidth:.infinity,alignment:.topLeading)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(dropTarget ? MilkTheme.selected.opacity(0.5):Color.clear)
                .onDrop(of:dropTypes,isTargeted:$dropTarget) { providers in
                    guard let root=store.workspace?.url else { return false }
                    return store.receiveDrop(providers,into:root)
                }
                .contextMenu {
                    Button("New File…") { store.newItem(folder:false,at:store.workspace?.url) }.disabled(store.workspace == nil)
                    Button("New Folder…") { store.newItem(folder:true,at:store.workspace?.url) }.disabled(store.workspace == nil)
                    Button("Reveal Workspace in Finder") { store.reveal() }.disabled(store.workspace == nil)
                }
        }
    }
    private func action(_ symbol:String,_ label:String,_ run:@escaping ()->Void) -> some View {
        Button(action:run) { Image(systemName:symbol).font(.system(size:12)).frame(width:14) }
            .buttonStyle(MilkButtonStyle()).disabled(store.workspace == nil).accessibilityLabel(label).help(label)
    }
    private func row(_ node:FileNode) -> some View {
        let selected=store.activeBuffer?.url == node.url.resolvingSymlinksInPath()
        return HStack(spacing:6) {
            if node.isDirectory {
                Image(systemName:"chevron.right").font(.system(size:8)).frame(width:12)
                    .rotationEffect(.degrees(store.expanded.contains(node.id) ? 90:0))
                    .animation(reduceMotion || store.rows.count>=300 ? nil:.easeInOut(duration:0.14),value:store.expanded.contains(node.id))
            } else { Color.clear.frame(width:12) }
            Image(systemName:node.icon).font(.system(size:13)).foregroundStyle(MilkTheme.muted)
            Text(node.name).fontWeight(selected ? .medium:.regular).lineLimit(1).opacity(node.isIgnored ? 0.55:1)
            Spacer(minLength:0)
            if let file=store.gitFile(for:node.url.path) {
                Text(file.code(staged:file.staged && !file.unstaged)).font(.system(size:10,weight:.medium,design:.monospaced))
                    .foregroundStyle(file.conflict ? MilkTheme.red : MilkTheme.amber)
                    .help(file.label(staged:file.staged && !file.unstaged))
            }
            if let buffer=store.buffers[node.url.resolvingSymlinksInPath().path],buffer.isModified {
                Circle().fill(MilkTheme.amber).frame(width:5,height:5)
            } else if store.openPaths.contains(node.url.resolvingSymlinksInPath().path) {
                Circle().stroke(MilkTheme.muted,lineWidth:1).frame(width:5,height:5)
            }
        }.font(.system(size:13)).padding(.leading,CGFloat(node.depth*14+6)).padding(.trailing,8).frame(height:24)
            .background(selected ? MilkTheme.selected:Color.clear,in:RoundedRectangle(cornerRadius:6))
            .contentShape(Rectangle())
            .modifier(ExplorerClickHandling(isFolder:node.isDirectory,
                toggle:{ store.toggleFolder(node) },
                preview:{ store.attempt { try store.openFile(node.url) } },
                pin:{ store.attempt { try store.openFile(node.url,pinned:true) } }))
            .transition(.opacity)
            .accessibilityElement(children:.ignore).accessibilityLabel(node.name)
            .accessibilityValue(node.isDirectory ? (store.expanded.contains(node.id) ? "Expanded":"Collapsed"):(selected ? "Selected":""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if node.isDirectory { store.toggleFolder(node) } else { store.attempt { try store.openFile(node.url) } } }
            .help(node.url.path)
            .contextMenu {
                ExtensionMenuActions(point:.fileContextMenu,fileURL:node.url)
                if node.isDirectory {
                    Button("New File…") { store.newItem(folder:false,at:node.url) }
                    Button("New Folder…") { store.newItem(folder:true,at:node.url) }
                    Divider()
                } else {
                    Button("Open and Pin") { store.attempt { try store.openFile(node.url,pinned:true) } }
                    if store.split {
                        Button("Open in Other Pane") { store.attempt { try store.openFile(node.url,pinned:true,pane:store.activePaneIndex == 0 ? 1:0) } }
                    }
                }
                Button("Rename…") { store.rename(node) }
                Button("Duplicate") { store.duplicate(node) }
                Button("Move to Trash…",role:.destructive) { store.delete(node) }
                Divider()
                Button("Reveal in Finder") { store.reveal(node.url) }
                Button("Copy Path") { store.copyPath(node.url) }
            }
            .onDrag { store.dragProvider(node) }
            .onDrop(of:dropTypes,isTargeted:nil) { store.receiveDrop($0,into:node.isDirectory ? node.url:node.url.deletingLastPathComponent()) }
    }
}

/// Folder taps react on the first click without waiting for a double-click timeout.
private struct ExplorerClickHandling: ViewModifier {
    let isFolder:Bool
    let toggle:()->Void
    let preview:()->Void
    let pin:()->Void
    @ViewBuilder func body(content:Content) -> some View {
        if isFolder {
            content.onTapGesture {
                // Ignore subsequent clicks in the same native click sequence.
                guard (NSApp.currentEvent?.clickCount ?? 1)<=1 else { return }
                toggle()
            }
        } else {
            content.onTapGesture(count:2,perform:pin).onTapGesture(count:1,perform:preview)
        }
    }
}
