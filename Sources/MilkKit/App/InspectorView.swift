import SwiftUI
import MilkCore

struct InspectorView: View {
    @Bindable var model: MilkModel
    @State private var area = "Changes"
    @State private var extensionResult = ""
    @State private var selectedChange: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Inspector", selection: $area) { ForEach(["Changes", "GitHub", "Extensions"], id: \.self) { Text($0) } }.padding([.top, .horizontal], 8)
            if area == "Changes" {
                if let snapshot = model.gitSnapshot {
                    Text("\(snapshot.branch) · \(snapshot.changes.count) changes").font(.caption).padding(.horizontal)
                    List(snapshot.changes, selection: $selectedChange) { change in
                        VStack(alignment: .leading) {
                            Button(change.path) { Task { await model.showDiff(change) } }.buttonStyle(.plain)
                            HStack {
                                Text("\(String(change.index))\(String(change.worktree))").font(.system(.caption, design: .monospaced))
                                if change.staged { Button("Staged") { Task { await model.showDiff(change, staged: true) } } }
                                if change.unstaged { Button("Working") { Task { await model.showDiff(change) } } }
                            }.font(.caption)
                        }.tag(change.path)
                    }.frame(minHeight: 100, idealHeight: 200, maxHeight: 280)
                    .onChange(of: selectedChange) {
                        if let change = snapshot.changes.first(where: { $0.path == selectedChange }) { Task { await model.showDiff(change) } }
                    }
                    if !model.patch.isEmpty {
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) { ForEach(DiffLine.parse(model.patch)) { line in Text(line.text).foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .primary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }.padding(8)
                        }
                    } else { Text("Select a change to inspect its diff").foregroundStyle(.secondary).padding() }
                } else { ContentUnavailableView("No Git repository", systemImage: "arrow.triangle.branch") }
            } else if area == "GitHub" {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.githubRepository?.slug ?? "GitHub").font(.headline)
                    Text(authDescription).font(.caption).foregroundStyle(.secondary)
                    Text(model.githubSummary).textSelection(.enabled)
                    Button("Refresh Repository") { Task { await model.inspectGitHub() } }
                    if let repo = model.githubRepository { Link("Open on GitHub", destination: URL(string: "https://github.com/" + repo.slug)!) }
                }.padding()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Isolated Extension Host").font(.headline)
                    Text("The internal sample requests UI contribution permission only. It runs in Milk’s sandboxed XPC service.").font(.caption)
                    Button("Run Internal Sample") { Task { await runSample() } }
                    Text(extensionResult).textSelection(.enabled).font(.caption)
                }.padding()
            }
            Spacer(minLength: 0)
        }
    }
    private var authDescription: String {
        switch model.githubState { case .githubCLI: "Using existing GitHub CLI authentication"; case .milkCredential: "Using Milk’s Keychain credential"; case .signedOut: "Sign in to use private repositories"; case .registrationRequired: "Native sign-in requires a configured OAuth client ID; public repository access is available" }
    }
    private func runSample() async {
        do {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Extensions/hello") else { throw MilkError.message("Sample resources unavailable") }
            let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            try await model.extensions.register(manifest, enabled: true, granted: [.ui])
            let source = try String(contentsOf: root.appendingPathComponent(manifest.entry), encoding: .utf8)
            let result = try await model.extensionHost.evaluate(manifest: manifest, source: source, registry: model.extensions)
            extensionResult = result["message"].string ?? result.description
        } catch { extensionResult = error.localizedDescription }
    }
}
