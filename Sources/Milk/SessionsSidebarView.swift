import SwiftUI
import UniformTypeIdentifiers

enum SessionBrowserScope: String, CaseIterable { case currentProject = "Current Project", allProjects = "All Projects" }

struct SessionsSidebarView: View {
    @ObservedObject var state: ShellState
    @State private var deletion: SavedAgentSession?
    @State private var failure: String?
    @State private var scope: SessionBrowserScope = .currentProject
    @State private var inspecting: IndexedAgentSession?
    private static let dragType = "dev.milk.open-session"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SESSIONS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(MilkTheme.muted)
                Spacer()
                Button { state.agent.refreshHistory() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(MilkButtonStyle()).accessibilityLabel("Refresh session history")
            }.padding(.horizontal, 12)
            Picker("Session projects", selection: $scope) {
                ForEach(SessionBrowserScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 8)
            Button { state.newSession() } label: {
                Label("New Session", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(MilkButtonStyle()).disabled(state.workspace.workspace == nil || state.agent.deletingSessionPath != nil)
                .accessibilityLabel("New Session").padding(.horizontal, 10).padding(.bottom, 10)
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(MilkTheme.red).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if scope == .allProjects {
                        if state.agent.sessionsForBrowsing(scope).isEmpty { hint("No retained sessions") }
                        ForEach(state.agent.sessionsForBrowsing(scope)) { record in retainedRow(record) }
                    } else {
                    section("OPEN")
                    if state.sessions.isEmpty { hint("No open sessions") }
                    ForEach(state.sessions) { session in
                        SessionSidebarRow(state: state, session: session, saved: state.agent.savedReference(session), delete: { deletion = $0 })
                            .onDrag {
                                let item = NSItemProvider()
                                item.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .ownProcess) { completion in
                                    completion(Data(String(session.id).utf8), nil); return nil
                                }
                                return item
                            }
                            .onDrop(of: [Self.dragType], isTargeted: nil) { providers in
                                guard let provider = providers.first else { return false }
                                let workspace = state.workspace.workspace?.url
                                provider.loadDataRepresentation(forTypeIdentifier: Self.dragType) { data, _ in
                                    guard let data, let id = Int(String(decoding: data, as: UTF8.self)) else { return }
                                    Task { @MainActor in
                                        guard state.workspace.workspace?.url == workspace else { return }
                                        state.agent.reorderSession(id, to: session.id)
                                    }
                                }
                                return true
                            }
                    }
                    section("RECENT").padding(.top, 14)
                    if state.agent.recentHistory.isEmpty { hint("No other saved sessions") }
                    ForEach(state.agent.recentHistory) { saved in
                        SessionSidebarRow(state: state, session: nil, saved: saved, delete: { deletion = $0 })
                    }
                    ForEach(state.agent.sessionsForBrowsing(scope).filter { !$0.isOpen && $0.nativeFile == nil }) { record in retainedRow(record) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            if state.workspace.workspace == nil {
                hint("Open a workspace to resume sessions. All Projects shows retained history.").padding(.horizontal, 10).padding(.bottom, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { state.agent.refreshHistory() }
            .sheet(item: $inspecting) { record in RetainedSessionInspector(agent: state.agent, record: record) }
            .alert(deletion.map { "Delete “\($0.title)”?" } ?? "Delete session?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("Cancel", role: .cancel) { deletion = nil }
                if let saved = deletion {
                    Button("Delete", role: .destructive) {
                        deletion = nil; failure = nil
                        Task {
                            do { try await state.agent.deleteSavedSession(saved) }
                            catch { failure = error.localizedDescription }
                        }
                    }
                }
            } message: {
                Text("This permanently deletes this saved Pi session and its conversation history.")
            }
    }
    private func retainedRow(_ record: IndexedAgentSession) -> some View {
        let availability = state.agent.retainedAvailability(record)
        return Button { inspecting = record } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).lineLimit(1)
                Text("\(record.metadata.agentID.rawValue == "pi" ? "Pi" : record.metadata.agentID.rawValue) · \(record.metadata.workspace?.url.lastPathComponent ?? "Unknown project")")
                    .font(.system(size: 10)).foregroundStyle(MilkTheme.muted)
                if !availability.canAttemptResume { Text(availability.detail).font(.system(size: 10)).foregroundStyle(MilkTheme.muted).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        }.buttonStyle(MilkButtonStyle(height: nil)).contextMenu {
            if record.metadata.workspace == state.workspace.workspace.map({ SessionWorkspace($0.url) }) {
                Button("Open Cached Session") { state.agent.openRetainedForBrowsing(record) }
            }
        }
    }
    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(MilkTheme.muted)
            .padding(.horizontal, 6).padding(.bottom, 5)
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(MilkTheme.muted).padding(.horizontal, 6).padding(.vertical, 4)
    }
}

private struct SessionSidebarRow: View {
    @ObservedObject var state: ShellState
    let session: AgentSession?
    let saved: SavedAgentSession?
    let delete: (SavedAgentSession) -> Void
    @State private var renaming = false
    @State private var title = ""
    private var name: String { session?.title ?? saved?.title ?? "Session" }
    private var selected: Bool { session.map { $0.id == state.selectedSession } ?? false }
    private var deleteReason: String? { state.agent.sessionDeletionUnavailableReason(saved) }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let session { state.agent.selectForBrowsing(session.id) }
                else if let saved {
                    if let record = state.agent.retainedSessions().first(where: { $0.savedReference?.id == saved.id }) { state.agent.openRetainedForBrowsing(record) }
                    else { state.agent.reopenForBrowsing(saved) }
                }
            } label: {
                HStack(spacing: 7) {
                    if let session { StateDot(state: session.state) }
                    else { Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(MilkTheme.muted).frame(width: 12) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(1).truncationMode(.tail)
                        if let ownerLabel { Text(ownerLabel).font(.system(size: 10)).foregroundStyle(MilkTheme.muted).lineLimit(1) }
                        if let unavailable { Text(unavailable).font(.system(size: 10)).foregroundStyle(MilkTheme.muted).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(MilkButtonStyle(selected: selected, height: nil))
                .accessibilityLabel("\(session == nil ? "Reopen" : "Select") session \(name)")
                .accessibilityValue(selected ? "Current session" : (session?.state.rawValue ?? "Saved session"))
            Menu {
                actions
            } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 16, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(name)").padding(.trailing, 5)
        }.background(selected ? MilkTheme.selectionSurface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .disabled(state.agent.deletingSessionPath != nil)
            .contextMenu { actions }
            .help(name)
            .alert("Rename session", isPresented: $renaming) {
                TextField("Session name", text: $title)
                Button("Save") {
                    if let session { state.agent.rename(session.id, title: title) }
                    else if let saved {
                        state.agent.reopen(saved)
                        state.agent.rename(state.selectedSession, title: title)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
    }
    private var ownerLabel: String? {
        if let session { return state.agent.agentDisplayName(session) }
        let owner = session?.agentID ?? saved?.agentID ?? .pi
        return owner == .pi ? "Pi" : owner.rawValue
    }
    private var unavailable: String? {
        let availability: SessionAvailability
        if let session {
            guard state.agent.hasAgentContext(session) else { return nil }
            availability = state.agent.availability(session)
        }
        else if let saved, let record = state.agent.retainedSessions().first(where: { $0.savedReference?.id == saved.id }) { availability = state.agent.retainedAvailability(record) }
        else { return nil }
        return availability.canAttemptResume ? nil : availability.detail
    }
    @ViewBuilder private var actions: some View {
        Button("Rename…") { title = name; renaming = true }
        if let session { Button("Close Session") { state.closeSession(session.id) } }
        Divider()
        Button("Delete Session…", role: .destructive) { if let saved { delete(saved) } }
            .disabled(deleteReason != nil).help(deleteReason ?? "Permanently delete saved Pi history")
        if let deleteReason { Text(deleteReason) }
    }
}

private struct RetainedSessionInspector: View {
    @ObservedObject var agent: AgentService
    let record: IndexedAgentSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.title).font(.title2)
            Text("\(record.metadata.agentID.rawValue == "pi" ? "Pi" : record.metadata.agentID.rawValue) · \(record.metadata.workspace?.url.path ?? "Unknown project")").font(.caption).textSelection(.enabled)
            Text(agent.retainedAvailability(record).detail).font(.caption).foregroundStyle(MilkTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let cached = agent.retainedConversation(record) {
                        ForEach(cached.messages) { message in
                            VStack(alignment: .leading, spacing: 4) { Text(message.role.capitalized).font(.caption.bold()); Text(message.text).textSelection(.enabled) }
                        }
                        if !cached.draft.isEmpty { Text("Saved draft").font(.caption.bold()); Text(cached.draft).textSelection(.enabled) }
                        if cached.messages.isEmpty && cached.draft.isEmpty { Text("No cached conversation. Native history remains at its original location.").foregroundStyle(MilkTheme.muted) }
                    } else { Text("No Milk conversation cache is available. Open the owning project to inspect or resume its native session.").foregroundStyle(MilkTheme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 600, height: 500).background(MilkTheme.canvas)
    }
}
