import SwiftUI
import MilkCore

public struct WorkspaceView: View {
    @Bindable var model: MilkModel
    @AppStorage("pi.executable") private var piPath = "/opt/homebrew/bin/pi"
    @State private var sidebar: NavigationSplitViewVisibility = .all
    @State private var selectedFile: URL?
    public init(model: MilkModel) { self.model = model }
    public var body: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            sidebarContent.navigationTitle("Workspace").navigationSplitViewColumnWidth(min: 180, ideal: 230)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    sessionTabs
                    Divider()
                    HStack {
                        Picker("Area", selection: $model.panel) { ForEach(["Chat", "Editor", "Preview"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 260)
                        Spacer()
                        if model.panel == "Editor" { Button { model.editor.split.toggle(); model.persist() } label: { Image(systemName: "rectangle.split.2x1") }.help("Split editor") }
                    }.padding(8)
                    mainArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                    statusBar
                }.frame(minHeight: 300)
                if model.terminalVisible, let folder = model.folder { TerminalPane(controller: model.terminal, folder: folder).frame(minHeight: 120, idealHeight: 210).id(folder) }
            }
            .inspector(isPresented: $model.inspectorVisible) { InspectorView(model: model).inspectorColumnWidth(min: 230, ideal: 300, max: 600) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { model.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }.help("Open workspace") }
            ToolbarItem { Menu(model.workspaceName) { ForEach(model.workspaces) { workspace in Button(URL(fileURLWithPath: workspace.path).lastPathComponent) { Task { do { try await model.open(workspace.resolve()) } catch { model.error = error.localizedDescription } } } } } }
            ToolbarItem { Button { model.newSession() } label: { Label("New Session", systemImage: "plus") }.disabled(model.folder == nil) }
            ToolbarItem { Button { model.terminalVisible.toggle(); model.persist() } label: { Label("Terminal", systemImage: "terminal") } }
            ToolbarItem { Button { model.inspectorVisible.toggle(); model.persist() } label: { Label("Inspector", systemImage: "sidebar.right") } }
        }
        .navigationTitle(model.workspaceName)
        .frame(minWidth: 950, minHeight: 620)
        .alert("Milk", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.selectedSession) {
            model.persist()
            if let session = model.currentSession, session.record.file != nil { Task { try? await session.start(piPath: piPath) } }
        }
        .onChange(of: model.inspectorVisible) { model.persist() }
    }
    private var sidebarContent: some View {
        List(selection: $selectedFile) {
            Section("Files") {
                OutlineGroup(model.files, children: \.children) { entry in
                    Label(entry.url.lastPathComponent, systemImage: entry.isDirectory ? "folder" : "doc.text").lineLimit(1).tag(entry.url)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url.path, forType: .string) }
                    }
                }
            }
            Section("Search") {
                TextField("Search workspace", text: $model.searchQuery).onSubmit { Task { await model.search() } }
                ForEach(model.searchResults.prefix(100)) { match in
                    Button { if let folder = model.folder { Task { await model.openFile(folder.appendingPathComponent(match.path)) } } } label: {
                        VStack(alignment: .leading) { Text("\(match.path):\(match.line)").font(.caption).foregroundStyle(.secondary); Text(match.text).lineLimit(2) }
                    }.buttonStyle(.plain)
                }
            }
            Section("Integrations") {
                Button("GitHub", systemImage: "network") { Task { await model.inspectGitHub() } }
                Button("Refresh Files and Git", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        }.onChange(of: selectedFile) {
            if let selectedFile, !selectedFile.hasDirectoryPath { Task { await model.openFile(selectedFile) } }
        }
    }
    private var sessionTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.sessions) { session in
                    Button { model.selectedSession = session.id; model.panel = "Chat" } label: {
                        HStack { Image(systemName: session.running ? "circle.fill" : "bubble.left"); Text(session.record.name).lineLimit(1) }.padding(.horizontal, 8).padding(.vertical, 5)
                    }.buttonStyle(.bordered).tint(model.selectedSession == session.id ? .accentColor : nil)
                    .contextMenu {
                        Button("Rename") { rename(session) }
                        Button("Close Session") { Task { await model.closeSession(session) } }
                    }
                }
            }.padding(8)
        }.frame(height: 48)
    }
    @ViewBuilder private var mainArea: some View {
        if model.folder == nil { ContentUnavailableView("Open a local folder", systemImage: "folder", description: Text("Milk uses your existing Pi installation and configuration.")) }
        else if model.panel == "Chat", let session = model.currentSession { ChatPane(session: session, piPath: piPath) }
        else if model.panel == "Editor" { EditorPane(editor: model.editor) }
        else if model.panel == "Preview" {
            VStack(spacing: 0) {
                HStack { TextField("Preview URL", text: $model.previewAddress).onSubmit { if let url = URL(string: model.previewAddress), ["http", "https"].contains(url.scheme) { model.previewURL = url } }; Button("Open") { model.previewURL = URL(string: model.previewAddress) } }.padding(8)
                if let url = model.previewURL { PreviewPane(url: url).id(url) } else { ContentUnavailableView("Select a file or localhost URL", systemImage: "eye") }
            }
        } else { ContentUnavailableView("Create a session", systemImage: "plus.bubble") }
    }
    private var statusBar: some View {
        HStack {
            Text(model.currentSession?.status ?? "Ready")
            if let session = model.currentSession, !session.model.isEmpty { Text("\(session.provider) / \(session.model)").lineLimit(1) }
            Spacer()
            if let branch = model.gitSnapshot?.branch { Label(branch, systemImage: "arrow.triangle.branch") }
            Text(model.currentSession?.record.mode.rawValue.capitalized ?? "")
        }.font(.caption).foregroundStyle(.secondary).padding(8).background(.bar)
    }
    private func rename(_ session: PiSessionController) {
        let alert = NSAlert(); alert.messageText = "Rename session"; let field = NSTextField(string: session.record.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { session.record.name = field.stringValue; model.persist() }
    }
}

private struct EditorPane: View {
    @Bindable var editor: EditorController
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) { HStack {
                ForEach(editor.documents) { doc in Button { editor.selected = doc.id } label: { Text(doc.url.lastPathComponent + (doc.dirty ? " •" : "")) }.buttonStyle(.bordered) }
                Button("Save") { Task { do { try await editor.current?.save() } catch { self.error = error.localizedDescription } } }.keyboardShortcut("s", modifiers: .command)
                Button("Save All") { Task { do { try await editor.saveAll() } catch { self.error = error.localizedDescription } } }
                Button("Undo") { editor.current?.undo.undo() }.disabled(editor.current?.canUndo != true)
                Button("Redo") { editor.current?.undo.redo() }.disabled(editor.current?.canRedo != true)
                if let folder = editor.current?.url.deletingLastPathComponent() {
                    Menu("Language") {
                        Button("Connect SourceKit-LSP") { Task { do { try await editor.connectSwift(workspace: folder) } catch { self.error = error.localizedDescription } } }
                        Button("Hover at Cursor") { Task { do { try await editor.hover() } catch { self.error = error.localizedDescription } } }
                    }
                }
            }.padding(8) }
            if let doc = editor.current {
                if doc.externalVersion != nil || doc.missingOnDisk {
                    VStack(alignment: .leading) {
                        Text("This file changed outside Milk. Your unsaved buffer is preserved.").foregroundStyle(.orange)
                        HStack {
                            Button("Reload Disk") { Task { do { try await doc.reloadDisk() } catch { self.error = error.localizedDescription } } }
                            Button("Keep My Buffer") { Task { do { try await doc.keepBuffer() } catch { self.error = error.localizedDescription } } }
                            if doc.externalVersion != nil { Button("Compare") { let alert = NSAlert(); alert.messageText = "Disk version"; alert.informativeText = String((doc.externalVersion ?? "").prefix(20_000)); alert.runModal() } }
                        }
                    }.padding(8)
                }
                if editor.split {
                    HSplitView {
                        CodeEditorView(document: doc).id("primary-" + doc.id.uuidString)
                        let secondary = editor.documents.first { $0.id == editor.secondary } ?? doc
                        CodeEditorView(document: secondary).id("secondary-" + secondary.id.uuidString)
                    }
                }
                else { CodeEditorView(document: doc).id(doc.id) }
            } else { ContentUnavailableView("Open a file", systemImage: "doc.text") }
            Text(editor.languageStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(4)
        }.alert("Editor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}
