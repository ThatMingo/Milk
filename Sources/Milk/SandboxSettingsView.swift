import SwiftUI
import UniformTypeIdentifiers

struct SandboxSettingsView: View {
    @ObservedObject var store: SandboxSettingsStore
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var grants: SandboxGrantStore
    @State private var feedback = ""
    @State private var editor: SandboxLocationDraft?
    @State private var unit = SandboxTimeoutUnit.seconds
    private var project: URL? { workspace.workspace?.url }
    private var projectConfiguration: SandboxProjectConfiguration {
        project.flatMap { try? store.projectConfiguration(for: $0) } ?? .init()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            settingGroup("Sandbox") {
                SettingsNote(text: "Policy configuration only. Agent execution is not sandboxed by these settings yet.")
                SettingsRow(title: "Sandbox", subtitle: "Independent from Ask for approval and Autonomous.") {
                    Toggle("Sandbox", isOn: Binding(get: { store.configuration.enabled }, set: { value in change { try store.setEnabled(value) } })).labelsHidden()
                }
                SettingsRow(title: "Autonomous permission timeout", subtitle: "Default: 30 seconds. Ask mode waits for you.") {
                    HStack {
                        TextField("Timeout", value: Binding(get: { store.configuration.autonomousTimeoutSeconds / unit.seconds }, set: { value in change { try store.setTimeout(seconds: value * unit.seconds) } }), format: .number).frame(width: 65)
                        Picker("Unit", selection: $unit) { ForEach(SandboxTimeoutUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
                    }
                }
            }
            settingGroup("Current Project") {
                if let project {
                    SettingsRow(title: "Agent Project Access", subtitle: project.path) {
                        Picker("Agent Project Access", selection: Binding(get: { projectConfiguration.access }, set: { value in change { try store.setProjectAccess(value, project: project) } })) {
                            ForEach(SandboxFolderAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    SettingsNote(text: "Controls agent access. Milk's Editor, Git and other workspace features remain independent.")
                } else { SettingsNote(text: "Open a project to configure its sandbox access and allowed folders.") }
            }
            folders("Global Allowed Folders", entries: store.configuration.globalAllowedFolders, project: nil)
            if let project { folders("Project Allowed Folders", entries: projectConfiguration.allowedFolders, project: project) }
            settingGroup("Protected Locations") {
                ForEach(store.configuration.protectedLocations) { entry in
                    SettingsRow(title: entry.url.lastPathComponent, subtitle: entry.url.path, subtitleLines: 2) {
                        HStack {
                            Button("Edit…") { editor = .init(kind: .protectedLocation, entryID: entry.id, path: entry.url.path) }
                            Button("Remove") { change { try store.removeProtectedLocation(entry.id) } }
                        }
                    }
                }
                SettingsNote(text: "Protected Locations take precedence over broader folder grants. Every entry can be edited or removed.")
                SettingsActionRow {
                    Button("Add…") { editor = .init(kind: .protectedLocation) }
                    Button("Restore Recommended Defaults") { change { try store.restoreRecommendedDefaults() } }
                }
            }
            settingGroup("Temporary Permissions") {
                if grants.grants.isEmpty { SettingsNote(text: "No active temporary permissions. Once and Session permissions are never saved.") }
                ForEach(grants.grants) { grant in
                    SettingsRow(title: grant.lifetime == .once ? "Allow Once" : "Allow for Session",
                                subtitle: "\(grant.path.canonicalURL.path) · \(grant.access.title) · \(grant.activation.agentID.rawValue) session \(grant.activation.sessionID)", subtitleLines: 2) {
                        if grant.lifetime == .session { Button("Revoke") { grants.revokeSessionGrant(grant.id) } }
                        else { Text("Current operation").foregroundStyle(MilkTheme.muted) }
                    }
                }
                SettingsNote(text: "Expiry or revocation stops future use. Detached surviving processes may retain permissions they already inherited.")
            }
            if let problem = store.problem { SettingsNote(text: problem) }
            if !feedback.isEmpty { Text(feedback).foregroundStyle(MilkTheme.muted).textSelection(.enabled) }
        }
        .sheet(item: $editor) { draft in
            SandboxLocationEditor(draft: draft) { value in
                let expanded = (value.path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { throw SandboxSettingsError.message("Enter an absolute local path.") }
                let url = URL(fileURLWithPath: expanded)
                if value.kind == .protectedLocation { try store.putProtectedLocation(url, id: value.entryID) }
                else { try store.putFolder(url, access: value.access, id: value.entryID, project: value.project) }
            }
        }
    }
    private func folders(_ title: String, entries: [SandboxFolderGrant], project: URL?) -> some View {
        settingGroup(title) {
            ForEach(entries) { entry in
                SettingsRow(title: entry.url.lastPathComponent, subtitle: entry.url.path, subtitleLines: 2) {
                    HStack {
                        Picker("Folder access", selection: Binding(get: { entry.access }, set: { value in change { try store.putFolder(entry.url, access: value, id: entry.id, project: project) } })) {
                            ForEach(SandboxFolderAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 105)
                        Button("Edit…") { editor = .init(kind: project == nil ? .globalFolder : .projectFolder, entryID: entry.id, path: entry.url.path, access: entry.access, project: project) }
                        Button("Remove") { change { try store.removeFolder(entry.id, project: project) } }
                    }
                }
            }
            if entries.isEmpty { SettingsNote(text: "No allowed folders.") }
            SettingsActionRow { Button("Add Folder…") { editor = .init(kind: project == nil ? .globalFolder : .projectFolder, project: project) } }
        }
    }
    private func change(_ body: () throws -> Void) {
        do { try body(); feedback = "" } catch { feedback = error.localizedDescription }
    }
}
private enum SandboxTimeoutUnit: String, CaseIterable {
    case seconds, minutes, hours
    var seconds: Double { switch self { case .seconds: return 1; case .minutes: return 60; case .hours: return 3600 } }
}
private struct SandboxLocationDraft: Identifiable {
    enum Kind { case globalFolder, projectFolder, protectedLocation }
    let id = UUID()
    var kind: Kind
    var entryID: String? = nil
    var path = ""
    var access: SandboxFolderAccess = .readOnly
    var project: URL? = nil
}
private struct SandboxLocationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SandboxLocationDraft
    let save: (SandboxLocationDraft) throws -> Void
    @State private var browsing = false
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.kind == .protectedLocation ? "Protected Location" : "Allowed Folder").font(.headline)
            TextField("Absolute path", text: $draft.path).textFieldStyle(.roundedBorder)
            HStack {
                Button("Choose…") { browsing = true }
                if draft.kind != .protectedLocation {
                    Picker("Access", selection: $draft.access) { ForEach(SandboxFolderAccess.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 220)
                }
            }
            if !feedback.isEmpty { Text(feedback).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { do { try save(draft); dismiss() } catch { feedback = error.localizedDescription } }.keyboardShortcut(.defaultAction).disabled(draft.path.isEmpty)
            }
        }.padding(24).frame(width: 510)
            .fileImporter(isPresented: $browsing, allowedContentTypes: draft.kind == .protectedLocation ? [.folder, .item] : [.folder]) { result in
                switch result { case .success(let url): draft.path = url.path; case .failure(let error): feedback = error.localizedDescription }
            }
    }
}
