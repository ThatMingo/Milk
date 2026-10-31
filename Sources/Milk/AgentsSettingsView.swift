import SwiftUI
import AppKit

struct AgentsSettingsView: View {
    @ObservedObject var state: ShellState
    @ObservedObject var agent: AgentService
    @StateObject private var model: AgentManagerModel
    init(state: ShellState) {
        self.state = state; agent = state.agent
        _model = StateObject(wrappedValue: AgentManagerModel(manager: state.agentInstallations))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            settingGroup("Pi") {
                SettingsRow(title: model.status, subtitle: model.managed != nil ? "Managed by Milk" : model.external != nil ? "Existing installation" : "Install Pi or choose an existing compatible executable.") {
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if let record = model.selectedRecord {
                    SettingsRow(title: "Selected version", subtitle: record.executable.path, subtitleLines: 2) { Text(model.selectedVersion).textSelection(.enabled) }
                }
                if !model.state.managed.isEmpty {
                    SettingsRow(title: "Installed versions") { Text(Set(model.state.managed.map { $0.release.version }).sorted().joined(separator: ", ")) }
                }
                if let running = model.runningDescription { SettingsNote(text: "Running: " + running) }
                if let pending = model.state.managed.first(where: { $0.id == model.state.pending }) {
                    SettingsNote(text: "Pi \(pending.release.version) is verified and staged. It will activate when owned Pi work has finished, or when you choose Activate Update.")
                }
                if let health = model.health { SettingsNote(text: health.detail) }
                if let issue = model.manager.store.loadProblem { SettingsNote(text: issue) }
                if model.operationFailed, let operation = model.state.operation { SettingsNote(text: operation.detail) }
                if model.managed != nil && (model.operationFailed || model.needsVerification) { SettingsNote(text: "Repair is available for Milk-managed runtime code.") }
                if model.managed != nil {
                    SettingsRow(title: "Auto Update", subtitle: "Approved Pi updates only. Active sessions keep their current runtime.") {
                        Toggle("Auto Update", isOn: Binding(get: { model.state.autoUpdate }, set: { enabled in Task { await model.setAutoUpdate(enabled) } })).labelsHidden()
                    }
                }
                if model.state.managed.count > 1 || (model.managed == nil && !model.state.managed.isEmpty) {
                    SettingsRow(title: "Retained installation") {
                        Menu("Select Version…") {
                            ForEach(model.state.managed.filter { $0.health.usable }) { version in
                                Button("Pi \(version.release.version) · \(version.installedAt.formatted(date: .abbreviated, time: .shortened))") {
                                    confirmChange("Use this retained Pi installation?") { Task { await model.selectRetained(version.id) } }
                                }.disabled(version.id == model.state.selected)
                            }
                        }
                    }
                }
                SettingsActionRow {
                    ViewThatFits(in: .horizontal) {
                        HStack { actionButtons }
                        VStack(alignment: .trailing, spacing: 8) { actionButtons }
                    }
                }
                if !model.feedback.isEmpty { SettingsNote(text: model.feedback) }
                SettingsNote(text: "Agent code is separate from Pi sessions, authentication, configuration and extensions. Removing managed Pi preserves that data.")
            }.disabled(model.busy)
            settingGroup("Agent selection") {
                SettingsRow(title: "Default for new projects") { Text(agent.globalDefaultAgentID.rawValue == "pi" ? "Pi" : agent.globalDefaultAgentID.rawValue) }
                if state.workspace.workspace != nil { SettingsRow(title: "This project", subtitle: "Existing sessions retain their owning agent.") { Text(agent.projectAgentID.rawValue == "pi" ? "Pi" : agent.projectAgentID.rawValue) } }
                if agent.globalDefaultAgentID != .pi || (state.workspace.workspace != nil && agent.projectAgentID != .pi) {
                    SettingsActionRow { Button("Use Pi for New Sessions") { try? agent.setGlobalDefaultAgent(.pi); if state.workspace.workspace != nil { try? agent.selectProjectAgent(.pi) } } }
                }
            }
            PiSettingsContent(agent: agent)
        }.task { await model.checkAutomaticUpdate() }
    }
    @ViewBuilder private var actionButtons: some View {
        ForEach(model.actions) { action in
            Button(action.title) {
                switch action {
                case .useExisting: chooseExisting()
                case .remove:
                    confirm("Remove managed Pi?", "This stops Milk-owned Pi work and removes managed runtime code. Sessions, drafts, configuration, credentials and extensions are preserved.") { Task { await model.perform(action) } }
                case .forget:
                    confirm("Forget this existing installation?", "Milk-owned Pi work will stop. The external executable and all Pi data are preserved.") { Task { await model.perform(action) } }
                case .activate, .rollback:
                    confirmChange(action == .activate ? "Activate the staged Pi update?" : "Roll back the Pi runtime?") { Task { await model.perform(action) } }
                default: Task { await model.perform(action) }
                }
            }
        }
    }
    private func chooseExisting() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "Choose a trusted Pi executable. Milk will run an isolated compatibility check before selecting it."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        confirmChange("Use the selected Pi installation?") { Task { await model.useExisting(url) } }
    }
    private func confirmChange(_ title: String, action: () -> Void) {
        if model.manager.lifecycle.hasWork(for: .pi) {
            confirm(title, "Milk will stop and await its Pi sessions and helpers before changing the selected runtime. Queued instructions are recovered to drafts. Pi user data is preserved.", action: action)
        } else { action() }
    }
    private func confirm(_ title: String, _ detail: String, action: () -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}
