import SwiftUI

struct GitSidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var git: GitStore
    var body: some View {
        VStack(spacing: 0) {
            if let repo = git.repository {
                HStack { repositoryHeader(repo); ExtensionSlot(point:.gitToolbar) }
                Hairline()
                GitFeedbackView(git: git)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if repo.merging { Label("Merge in progress", systemImage: "arrow.triangle.merge").foregroundStyle(MilkTheme.amber).padding(8) }
                        section("Conflicts", files: repo.files.filter(\.conflict), staged: false)
                        section("Staged", files: repo.files.filter(\.staged), staged: true, always: true)
                        section("Changes", files: repo.files.filter(\.unstaged), staged: false, always: true)
                        section("Untracked", files: repo.files.filter(\.untracked), staged: false)
                        if !repo.dirty { Text("Working tree clean").foregroundStyle(MilkTheme.muted).padding(10) }
                    }.padding(8)
                }
                Hairline()
                commitArea
            } else {
                GitFeedbackView(git: git)
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 24)).foregroundStyle(MilkTheme.muted)
                    Text(store.workspace == nil ? "Open a workspace" : git.checked ? "No Git repository" : "Checking repository…").fontWeight(.medium)
                    Text(store.workspace == nil ? "Choose a local folder to use Git." : "This folder is not part of a Git repository.").foregroundStyle(MilkTheme.muted).multilineTextAlignment(.center)
                    if store.workspace == nil { Button("Open Folder…") { store.chooseWorkspace() }.buttonStyle(MilkButtonStyle(bordered: true)) }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.font(.system(size: 11.5))
    }
    private func repositoryHeader(_ repo: GitRepository) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Menu {
                    Text(repo.detached ? "Detached HEAD" : "Current: \(repo.branch)")
                    Menu("Switch Branch") {
                        ForEach(repo.branches, id: \.self) { branch in Button(branch) { git.run("Switching branch…", .switchBranch(branch)) }.disabled(branch == repo.branch) }
                    }
                    Button("Create Branch…") { git.createBranch(using: store) }
                    Menu("Merge Local Branch") {
                        ForEach(repo.branches.filter { $0 != repo.branch }, id: \.self) { branch in Button(branch) { git.run("Merging…", .mergeBranch(branch)) } }
                    }
                    Menu("Delete Local Branch") {
                        ForEach(repo.branches.filter { $0 != repo.branch }, id: \.self) { branch in Button(branch, role: .destructive) { git.confirmDeleteBranch(branch) } }
                    }
                } label: { Label(repo.branchLabel, systemImage: "arrow.triangle.branch").lineLimit(1) }
                    .menuStyle(.borderlessButton).disabled(git.busy != nil).help("Local branches")
                Spacer(minLength: 0)
                Text(repo.dirty ? "●" : "Clean").foregroundStyle(repo.dirty ? MilkTheme.amber : MilkTheme.muted)
            }
            if repo.ahead > 0 || repo.behind > 0 { Text("↑\(repo.ahead) ahead  ↓\(repo.behind) behind").foregroundStyle(MilkTheme.muted) }
            HStack(spacing: 3) {
                Button("Fetch") { git.run("Fetching…", .fetch) }
                Button("Pull") { git.run("Pulling…", .pull) }
                Button("Push") { git.run("Pushing…", .push) }
                Spacer(minLength: 0)
            }.buttonStyle(MilkButtonStyle(bordered: true)).disabled(git.busy != nil || repo.remotes.isEmpty)
                .help(repo.remotes.isEmpty ? "No remote configured" : repo.remotes.joined(separator: ", "))
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    @ViewBuilder private func section(_ title: String, files: [GitFile], staged: Bool, always: Bool = false) -> some View {
        if always || !files.isEmpty {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(MilkTheme.muted)
                Text("\(files.count)").foregroundStyle(MilkTheme.muted)
                Spacer()
                if title == "Changes" { Button("Stage All") { git.run("Staging all…", .stageAll) }.buttonStyle(.plain).disabled(git.busy != nil || git.repository?.dirty != true) }
            }.padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
            ForEach(files) { file in
                HStack(spacing: 4) {
                    Button { store.openGitFile(file, staged: staged) } label: {
                        HStack(spacing: 6) {
                            Text(file.code(staged: staged)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(file.conflict ? MilkTheme.red : staged ? MilkTheme.green : MilkTheme.amber).frame(width: 12)
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { git.run(staged ? "Unstaging…" : "Staging…", staged ? .unstage(file) : .stage(file)) } label: { Image(systemName: staged ? "minus" : "plus").frame(width: 20, height: 20) }
                        .buttonStyle(.plain).disabled(git.busy != nil).help(staged ? "Unstage File" : file.conflict ? "Stage resolution" : "Stage File")
                }.padding(.leading, 6).frame(height: 25)
                    .help(file.label(staged: staged) + " · " + (file.originalPath.map { $0 + " → " } ?? "") + file.path)
                    .contextMenu {
                        ExtensionMenuActions(point:.gitFileActions,fileURL:store.workspace?.url.appendingPathComponent(file.path))
                        Button("Open Diff") { store.openGitFile(file, staged: staged) }
                        Button(staged ? "Unstage File" : "Stage File") { git.run(staged ? "Unstaging…" : "Staging…", staged ? .unstage(file) : .stage(file)) }
                        if !staged { Button(file.untracked ? "Delete Untracked File…" : "Revert File…", role: .destructive) { git.discard(file, store: store) } }
                    }
            }
        }
    }
    private var commitArea: some View {
        VStack(spacing: 7) {
            TextField("Commit message", text: $git.commitMessage, axis: .vertical).lineLimit(2...4)
                .textFieldStyle(.plain).padding(8).background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MilkTheme.line))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { commitButtons }
                VStack(alignment: .leading, spacing: 4) { commitButtons }
            }.frame(maxWidth: .infinity, alignment: .leading).disabled(git.busy != nil)
        }.padding(10)
    }
    @ViewBuilder private var commitButtons: some View {
        Button("Commit") { git.commit() }.buttonStyle(MilkButtonStyle(bordered: true))
        Button("Commit & Push") { git.commit(push: true) }.buttonStyle(MilkButtonStyle(bordered: true))
            .help("Commit staged changes, then push only if the commit succeeds")
    }
}

struct GitFeedbackView: View {
    @ObservedObject var git: GitStore
    var body: some View {
        if git.busy != nil || git.failure != nil {
        VStack(alignment: .leading, spacing: 6) {
            if let busy = git.busy { HStack(spacing: 7) { ProgressView().controlSize(.mini); Text(busy) }.padding(8) }
            if let failure = git.failure {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(MilkTheme.red)
                        ScrollView { Text(failure.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 95)
                        Button { git.failure = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Dismiss Git error")
                    }
                    if failure.kind == .noStagedChanges {
                        Button("Stage All & Commit") { git.commit(stageAll: true) }.buttonStyle(MilkButtonStyle(bordered: true)).disabled(git.busy != nil)
                    }
                }.padding(8).background(MilkTheme.red.opacity(0.06))
            }
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal:false,vertical:true)
        }
    }
}
