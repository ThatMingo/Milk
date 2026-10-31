import SwiftUI

struct GitDiffView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var git: GitStore
    let pane: EditorPane
    let path: String
    let staged: Bool
    @State private var diff: GitDiff?
    @State private var error: String?
    @State private var loading = true
    private var file: GitFile? { store.gitFile(for: path) }
    private var relative: String {
        guard let root = git.repository?.root, path.hasPrefix(root.path + "/") else { return path }
        return String(path.dropFirst(root.path.count + 1))
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            GitFeedbackView(git: git)
            if git.sideBySide {
                HStack {
                    Text(staged ? "HEAD" : "Index").frame(maxWidth:.infinity,alignment:.leading)
                    Text(staged ? "Index" : "Working Tree").frame(maxWidth:.infinity,alignment:.leading)
                }.font(.system(size:10.5,weight:.medium)).foregroundStyle(MilkTheme.muted).padding(.horizontal,10).frame(height:24).background(MilkTheme.surface)
            }
            if let file, file.conflict {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(MilkTheme.red)
                    Text("Merge conflict. Edit the file, resolve markers, save, then stage the resolution.")
                    Spacer(minLength: 0)
                    Button("Edit File") { store.setDiffMode(false, pane: pane.id) }.buttonStyle(.plain)
                }.font(.system(size: 11)).padding(8).background(MilkTheme.amber.opacity(0.08))
            }
            if store.buffers[path]?.isModified == true {
                Text("Unsaved editor changes are preserved. This diff shows disk contents; save the file to include your edits.")
                    .font(.system(size: 11)).foregroundStyle(MilkTheme.amber).padding(8)
            }
            if let error { message(error) }
            else if loading && diff == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let diff, let displayMessage=diff.displayMessage { message(displayMessage) }
            else if let diff, !diff.hunks.isEmpty {
                diffContent(diff).id("\(git.sideBySide):\(path):\(staged):\(diff.fingerprint)")
            } else if let diff, diff.binary { message("Binary file changed. Use file actions or open the file externally to inspect it.") }
            else if let diff, !diff.raw.isEmpty { ScrollView { Text(diff.raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) } }
            else { message(staged ? "No staged changes for this file." : "No working-tree changes for this file.") }
        }.background(MilkTheme.elevatedSurface)
            .task(id: "\(path):\(staged):\(git.revision)") {
                loading = true
                do {
                    let value = try await git.diff(path: relative, staged: staged)
                    guard !Task.isCancelled else { return }
                    diff = value; error = nil
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                if !Task.isCancelled { loading = false }
            }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { modeControls; Spacer(minLength: 0); fileActions }
            VStack(alignment: .leading, spacing: 6) { modeControls; fileActions }
        }.font(.system(size: 11)).padding(8).frame(maxWidth:.infinity,alignment:.leading).background(MilkTheme.surface)
    }
    private var modeControls: some View {
        HStack(spacing: 7) {
            Button("Editor") { store.setDiffMode(false, pane: pane.id) }.buttonStyle(MilkButtonStyle(bordered: true))
            Picker("Diff source", selection: Binding(get: { staged }, set: { store.setDiffMode(true, staged: $0, pane: pane.id) })) {
                Text("Changes").tag(false); Text("Staged").tag(true)
            }.labelsHidden().pickerStyle(.menu).fixedSize().background(MilkTheme.modeSelectionSurface,in:RoundedRectangle(cornerRadius:5))
            Menu {
                Button("Unified") { git.sideBySide = false }
                Button("Side-by-Side") { git.sideBySide = true }
            } label: { Text(git.sideBySide ? "Side-by-Side" : "Unified") }.menuStyle(.borderlessButton).fixedSize().background(MilkTheme.modeSelectionSurface,in:RoundedRectangle(cornerRadius:5))
        }.fixedSize()
    }
    private var fileActions: some View {
        HStack(spacing: 5) {
            if let file {
                Button(staged ? "Unstage File" : "Stage File") { git.run(staged ? "Unstaging…" : "Staging…", staged ? .unstage(file) : .stage(file)) }
                    .buttonStyle(MilkButtonStyle(bordered: true)).disabled(git.busy != nil || (staged ? !file.staged : !(file.untracked || file.unstaged || file.conflict)))
                if !staged {
                    Button("Revert File…", role: .destructive) { git.discard(file, store: store, snapshot: diff) }
                        .buttonStyle(MilkButtonStyle(bordered: true)).disabled(git.busy != nil || loading || !(file.untracked || file.unstaged || file.conflict))
                }
            }
        }.fixedSize()
    }
    private func diffContent(_ diff: GitDiff) -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(diff.hunks) { hunk in
                        hunkHeader(hunk,diff:diff)
                        if git.sideBySide {
                            let pairs = hunk.pairs
                            let width = max(100,(geometry.size.width-1)/2)
                            HStack(spacing:0) {
                                ScrollView(.horizontal) {
                                    VStack(alignment:.leading,spacing:0) {
                                        ForEach(pairs) { pair in cell(pair.old,number:pair.old?.oldLine).frame(height:21) }
                                    }.frame(minWidth:width,alignment:.leading)
                                }.frame(width:width)
                                MilkTheme.line.frame(width:1)
                                ScrollView(.horizontal) {
                                    VStack(alignment:.leading,spacing:0) {
                                        ForEach(pairs) { pair in cell(pair.new,number:pair.new?.newLine).frame(height:21) }
                                    }.frame(minWidth:width,alignment:.leading)
                                }.frame(width:width)
                            }.frame(height:CGFloat(pairs.count)*21+12)
                        } else {
                            ScrollView(.horizontal) {
                                VStack(alignment:.leading,spacing:0) {
                                    ForEach(hunk.lines) { line in
                                        HStack(spacing:0) {
                                            Text(line.oldLine.map(String.init) ?? "").foregroundStyle(MilkTheme.muted).frame(width:38,alignment:.trailing)
                                            Text(line.newLine.map(String.init) ?? "").foregroundStyle(MilkTheme.muted).frame(width:38,alignment:.trailing)
                                            Text(String(line.kind)).frame(width:22)
                                            Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal:true,vertical:false).textSelection(.enabled).padding(.trailing,20)
                                            Spacer(minLength:0)
                                        }.font(.system(size:store.preferences.fontSize,design:.monospaced)).frame(height:21).background(background(line.kind))
                                    }
                                }.frame(minWidth:geometry.size.width,alignment:.leading)
                            }.frame(height:CGFloat(hunk.lines.count)*21+12)
                        }
                    }
                }.frame(width:geometry.size.width,alignment:.topLeading)
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }
    }
    private func hunkHeader(_ hunk: GitHunk, diff: GitDiff) -> some View {
        HStack(spacing:8) {
            Text(hunk.header).font(.system(size:11,design:.monospaced)).foregroundStyle(MilkTheme.muted).lineLimit(1)
            Spacer(minLength:0)
            if diff.hunkActionsAvailable, file?.conflict != true {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:4) { hunkActions(hunk,diff:diff) }.fixedSize()
                    Menu("Hunk") { hunkActions(hunk,diff:diff) }.menuStyle(.borderlessButton).fixedSize()
                }.fixedSize(horizontal:true,vertical:false)
            }
        }.font(.system(size:10.5)).padding(.horizontal,8).frame(height:34).background(MilkTheme.surface)
            .disabled(git.busy != nil || loading)
    }
    @ViewBuilder private func hunkActions(_ hunk:GitHunk,diff:GitDiff) -> some View {
        Button(staged ? "Unstage Hunk" : "Stage Hunk") { git.run(staged ? "Unstaging hunk…" : "Staging hunk…",.hunk(diff,hunk.id,staged ? .unstage:.stage)) }.buttonStyle(MilkButtonStyle(bordered:true))
        if !staged,let file {
            Button("Revert Hunk…",role:.destructive) { git.discard(file,store:store,snapshot:diff,hunk:hunk.id) }.buttonStyle(MilkButtonStyle(bordered:true))
        }
    }
    private func cell(_ line: GitDiffLine?, number: Int?) -> some View {
        HStack(spacing: 8) {
            Text(number.map(String.init) ?? "").foregroundStyle(MilkTheme.muted).frame(width: 42, alignment: .trailing)
            Text(line?.text.isEmpty == false ? line!.text : " ").fixedSize(horizontal:true,vertical:false).textSelection(.enabled).padding(.trailing, 16)
            Spacer(minLength: 0)
        }.font(.system(size: store.preferences.fontSize, design: .monospaced)).frame(minHeight: 21)
            .background(background(line?.kind ?? " "))
    }
    private func background(_ kind: Character) -> Color { kind == "+" ? MilkTheme.diffAdded : kind == "-" ? MilkTheme.diffRemoved : Color.clear }
    private func message(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(MilkTheme.muted).multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
