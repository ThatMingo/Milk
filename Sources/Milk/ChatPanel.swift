import SwiftUI
import AppKit

struct ChatPanel: View {
    @ObservedObject var state: ShellState
    @State private var composerHeight: CGFloat = 96
    @State private var transcriptStore = ChatTranscriptStore()
    private var references: Bool {
        get { state.slashCommands.popup == .references }
        nonmutating set { if newValue { state.presentComposerPopup(.references) } else if references { state.presentComposerPopup(nil) } }
    }
    @State private var referenceQuery = ""
    @State private var referenceMatches: [URL] = []
    @State private var referenceTask: Task<Void, Never>?
    /// True when the picker was opened by typing `@` in the draft, so it follows the
    /// draft. A picker opened by the `@` button is dismissed only by the reader.
    @State private var referencesFromDraft = false
    private var draft: String {
        get { state.agent.current.draft }
        nonmutating set {
            state.updateComposerDraft(newValue)
            if let match = newValue.range(of: "(?:^|\\s)@([^\\s]*)$", options: .regularExpression) {
                referencesFromDraft = true
                referenceQuery = String(newValue[match]).trimmingCharacters(in: .whitespaces).dropFirst().description
                references = true; searchReferences()
            } else if referencesFromDraft {
                // The `@` trigger is gone from the draft; the picker must not keep
                // showing the previous query's matches.
                referencesFromDraft = false
                references = false
            }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 560
            VStack(spacing: 0) {
                ExtensionSlot(point:.chatToolbar)
                AgentConversationView(state: state, sessionID: state.selectedSession, narrow: narrow, width: geometry.size.width, rendering: transcriptStore.session(state.selectedSession))
                    .id(state.selectedSession)
                composer(narrow: narrow)
                    .disabled(state.currentSession == nil)
                    .frame(maxWidth: 760)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                    .background {
                        ComposerCommandAnchor(commands:state.slashCommands,maximumHeight:max(50,geometry.size.height-composerHeight-42),visible:state.takeover == nil && state.agent.presentedApproval == nil && !state.isEditingLayout)
                        ComposerApprovalAnchor(agent: state.agent, maximumHeight: max(70, geometry.size.height - composerHeight - 42), visible: state.takeover == nil)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, narrow ? 16 : 32).padding(.bottom, 14)
            }
        }.background(MilkTheme.canvas)
            .onChange(of: state.selectedSession) { _, _ in state.refreshSlashCommands() }
            .onChange(of: state.sessions.map(\.id)) { _, ids in transcriptStore.retain(open: Set(ids)) }
            .onChange(of: state.agent.presentedApproval?.id) { _, value in if value != nil { references = false } }
    }
    private func composer(narrow: Bool) -> some View {
        let working = state.agent.busy
        let queued = state.agent.current.queued
        let hasPrompt = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            if !state.agent.showsNeutralChat, let reason = state.agent.unavailableReason {
                HStack(alignment: .top) {
                    Text(reason).font(.system(size: 11)).foregroundStyle(MilkTheme.muted)
                    Spacer(minLength: 4)
                    Button("Agents…") { state.settingsSelection = "Agents"; state.takeover = "Settings" }.buttonStyle(SettingsButtonStyle())
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error=state.slashCommands.error { Text(error).font(.system(size:11)).foregroundStyle(MilkTheme.red).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("milk.composer.command-error") }
            VStack(alignment: .leading, spacing: 0) {
                if !state.agent.current.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.agent.current.attachments) { attachment in
                                HStack(spacing: 6) {
                                    Button { open(attachment) } label: { Label(attachment.url.lastPathComponent, systemImage: attachment.projectFile ? "doc" : "paperclip") }.buttonStyle(.plain)
                                    Button { state.agent.current.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain).help("Remove attachment")
                                }.font(.system(size: 11.5, design: .monospaced)).padding(.horizontal, 8).frame(height: 24)
                                    .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MilkTheme.line))
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 10)
                }
                if let queued {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.plus").foregroundStyle(MilkTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Queued · waiting").font(.system(size: 10, weight: .medium)).foregroundStyle(MilkTheme.muted)
                            Text(queued.text).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        Button { state.agent.cancelQueue() } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Cancel queued prompt")
                    }.padding(8).background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 12).padding(.top, 10)
                }
                ComposerInput(text: Binding(get: { draft }, set: { draft = $0 }), placeholder: state.agent.composerPlaceholder, onKeyCommand: { state.refreshSlashCommands(); return state.slashCommands.handle($0) }, focusRequest:state.slashCommands.focusRequest, accessibilityTitle: state.agent.currentAgentDisplayName.map { "Message \($0)" } ?? "Message")
                    .accessibilityLabel(state.agent.currentAgentDisplayName.map { "Message \($0)" } ?? "Message")
                HStack(spacing: 3) {
                    ExtensionSlot(point:.composerLeading)
                    Button { attachFiles() } label: { Image(systemName: "paperclip") }.buttonStyle(MilkButtonStyle()).help("Attach file")
                    Button { referenceQuery = ""; references.toggle(); searchReferences() } label: { Image(systemName: "at") }
                        .buttonStyle(MilkButtonStyle()).help("Reference project file")
                        .popover(isPresented: Binding(get: { references && state.agent.presentedApproval == nil }, set: { references = $0 }), arrowEdge: .top) { referencePicker }
                    ComposerPermissionControl(state: state).fixedSize()
                    Spacer(minLength: 6)
                    ExtensionSlot(point:.composerTrailing)
                    ComposerModelControl(state: state, width: narrow ? 118 : 180).padding(.trailing, 1)
                    HStack(spacing: 10) {
                        if working && (queued != nil || hasPrompt) {
                            composerAction(queued != nil ? "Steer" : "Queue", icon: queued != nil ? "arrow.turn.up.right" : "text.badge.plus", color: MilkTheme.muted) { state.queueOrSteerComposerPrompt() }
                        }
                        composerAction(working ? "Stop" : "Send", icon: working ? "stop.fill" : "arrow.up", color: working || hasPrompt ? MilkTheme.primaryAction : MilkTheme.primaryActionDisabled, foreground:.white) {
                            if working { state.agent.stop() } else { state.submitComposerPrompt() }
                        }.disabled(!working && (!hasPrompt || state.selectedSession < 0 || state.agent.pendingActions.contains(state.selectedSession)))
                    }.fixedSize()
                }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
            }.background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(MilkTheme.line))
                .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        }
    }
    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search project files", text: $referenceQuery).textFieldStyle(.roundedBorder).onChange(of: referenceQuery) { _, _ in searchReferences() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(referenceMatches, id: \.path) { url in
                        Button {
                            add(.init(url: url, projectFile: true))
                            if let match = draft.range(of: "(?:^|\\s)@([^\\s]*)$", options: .regularExpression) { state.agent.current.draft.removeSubrange(match) }
                            references = false
                        } label: { Text(relative(url)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(MilkButtonStyle())
                    }
                    if referenceMatches.isEmpty { Text("No matching project files").foregroundStyle(MilkTheme.muted) }
                }
            }.frame(height: 220)
        }.padding(12).frame(width: 340)
    }
    private func relative(_ url: URL) -> String {
        guard let root = state.workspace.workspace?.url else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }
    private func searchReferences() {
        referenceTask?.cancel()
        guard let root = state.workspace.workspace?.url else { referenceMatches = []; return }
        let query = referenceQuery
        referenceTask = Task {
            let matches = await state.workspace.projectFiles(matching: query)
            guard !Task.isCancelled, state.workspace.workspace?.url == root else { return }; referenceMatches = matches
        }
    }
    private func attachFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"; panel.message = "Attach UTF-8 text or images. Files stay in their original location."
        let id = state.selectedSession
        panel.begin { result in
            guard result == .OK, state.sessions.contains(where: { $0.id == id }) else { return }
            for url in panel.urls {
                let item = PromptAttachment(url: url, projectFile: false)
                if state.agent.conversations[id]?.attachments.contains(where: { $0.id == item.id }) != true { state.agent.conversations[id]?.attachments.append(item) }
            }
        }
    }
    private func add(_ attachment: PromptAttachment) {
        guard !state.agent.current.attachments.contains(where: { $0.id == attachment.id }) else { return }
        state.agent.current.attachments.append(attachment)
    }
    private func open(_ attachment: PromptAttachment) {
        if attachment.projectFile { do { try state.workspace.openFile(attachment.url, pinned: true) } catch { state.workspace.report(error) } }
        else { NSWorkspace.shared.open(attachment.url) }
    }
    private func composerAction(_ title: String, icon: String, color: Color, foreground:Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(foreground).frame(width: 32, height: 32).background(color, in: Circle()).contentShape(Circle()) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

private struct AgentConversationView: View {
    @ObservedObject var state: ShellState
    let sessionID: Int
    let narrow: Bool
    let width: CGFloat
    @ObservedObject var rendering: ChatTranscriptSession
    private var conversation: SessionConversation { state.agent.conversations[sessionID] ?? .init() }
    var body: some View {
        if state.agent.showsNeutralChat {
            MilkCartonOutline()
                .stroke(MilkTheme.muted.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 104).frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false).accessibilityHidden(true)
        } else {
            let empty = state.workspace.workspace == nil ? "Open a project to begin." : (state.currentSession == nil ? "Choose or create a session in the Sessions sidebar." : "Message \(state.agent.currentAgentDisplayName ?? "an agent") to start coding in this project.")
            NativeChatTranscript(rows: rendering.rows(conversation, empty: empty), session: rendering,
                                 conversation: conversation, narrow: narrow, sessionID: sessionID, paneWidth: width,
                                 remember: { offset, anchor, follows, scrollWidth in
                state.agent.recordScrollGeometry(sessionID, offset: offset, anchor: anchor, followsTail: follows, width: scrollWidth)
            }, content: { row in AnyView(ChatTranscriptRowView(row: row, state: state, session: rendering, narrow: narrow)) })
        }
    }
}

private struct ChatTranscriptRowView: View {
    let row: ChatTranscriptRow
    let state: ShellState
    let session: ChatTranscriptSession
    let narrow: Bool
    var body: some View {
        Group {
            switch row.content {
            case .user(let message): AgentUserMessageView(message: message, narrow: narrow)
            case .header(let turn): AgentResponseHeader(response: turn, agentName: state.agent.currentAgentDisplayName)
            case .markdown(let block, _): AgentMarkdownPiece(block: block).font(.system(size: 14)).textSelection(.enabled)
            case .thinking(let block, let label, let expanded, let active):
                AgentThinkingContent(block: block, label: label, expanded: expanded, active: active) { session.choices[row.owner] = !expanded }
            case .activity(let steps, let expanded, let outputs, let thoughts):
                AgentActivityGroupContent(steps: steps, expanded: expanded, outputs: outputs, thoughts: thoughts,
                    toggle: { session.choices[row.owner + "/" + row.id] = !expanded },
                    toggleOutput: { id in session.choices[row.owner + "/output/" + id] = !outputs.contains(id) },
                    toggleThinking: { id in session.choices[row.owner + "/thinking/" + id] = !thoughts.contains(id) })
            case .changes(let changes):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changed files · \(changes.count)").font(.system(size: 12, weight: .semibold))
                    ForEach(changes) { file in
                        Button {
                            if let root = state.workspace.workspace?.url { state.workspace.openChangedFile(root.appendingPathComponent(file.path)) }
                        } label: {
                            HStack {
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(file.kind).foregroundStyle(MilkTheme.muted)
                                if let added = file.added { Text("+\(added)").foregroundStyle(MilkTheme.green) }
                                if let removed = file.removed { Text("−\(removed)").foregroundStyle(MilkTheme.red) }
                            }.font(.system(size: 11.5, design: .monospaced))
                        }.buttonStyle(MilkButtonStyle())
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.line))
            case .empty(let text): SelectableContent(text: text).fixedSize(horizontal: false, vertical: true).foregroundStyle(MilkTheme.muted)
            case .notice(let text): Text(text).font(.system(size: 11)).foregroundStyle(MilkTheme.muted).textSelection(.enabled)
            case .error(let text):
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).foregroundStyle(MilkTheme.red).textSelection(.enabled)
                    Button("Restart \(state.agent.currentAgentDisplayName ?? "agent")") { state.agent.restart() }.buttonStyle(MilkButtonStyle(bordered: true))
                }.font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.red.opacity(0.4)))
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentUserMessageView: View, Equatable {
    let message: AgentMessage
    let narrow: Bool
    var body: some View {
        HStack {
            Spacer(minLength: narrow ? 20 : 100)
            SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 568, alignment: .leading)
                .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct AgentResponseHeader: View {
    @Environment(\.milkExtensionActionContext) private var extensionContext
    let response: AgentResponseTurn
    /// The turn's owning agent, supplied by the session's adapter. Milk core must not
    /// bake a provider-specific name into generic transcript chrome.
    var agentName: String? = nil
    static func title(for displayName: String?) -> String { displayName ?? "Assistant" }
    var body: some View {
HStack(spacing: 8) {
                Image(systemName: "drop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(MilkTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                Text(Self.title(for: agentName)).fontWeight(.semibold)
                ExtensionSlot(point:.chatMessageActions)
                    .environment(\.milkExtensionActionContext,.init(workspaceURL:extensionContext.workspaceURL,text:response.blocks.filter { $0.kind == .text }.map(\.text).joined(separator:"\n")))
                if response.streaming && !response.thinkingActive { ProgressView().controlSize(.mini) }
            }.accessibilityIdentifier("milk.pi.turn.header")
    }
}

struct AgentResponseTurnView: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.response == rhs.response && lhs.readingOrder == rhs.readingOrder }
    @Environment(\.milkExtensionActionContext) private var extensionContext
    let response: AgentResponseTurn
    var readingOrder: [Int] = []
    @State private var thinkingExpanded = false
    private var firstThinkingID: String? {
        response.presentationGroups.filter { !$0.isActivity }.flatMap(\.blocks).first(where: \.visibleThinking)?.id
    }
    private var visibleBlocks: [AgentContentBlock] {
        let known = Set(response.activities.map(\.id))
        return response.blocks.filter { block in
            switch block.kind {
            case .text: return !block.text.isEmpty
            case .thinking: return block.visibleThinking && (thinkingExpanded || block.id == firstThinkingID)
            case .activity: return block.activityID.map { known.contains($0) } == true
            }
        }
    }
    var body: some View {
        let _ = ChatRenderMetrics.enabled ? ChatRenderMetrics.shared.record("response.body", milliseconds: 0) : ()
        let blocks = visibleBlocks
        VStack(alignment: .leading, spacing: 12) {
            AgentResponseHeader(response: response)
            ForEach(response.presentationGroups) { group in
                if group.isActivity {
                    AgentActivityGroupView(steps: response.activitySteps(in: group))
                        .chatReadingTarget(group.id, order: readingOrder + [response.blocks.firstIndex(where: { $0.id == group.blocks[0].id }) ?? 0])
                } else {
                    content(group.blocks.filter { block in blocks.contains { $0.id == block.id } })
                }
            }
        }
    }
    private func content(_ blocks: [AgentContentBlock]) -> some View {
        ForEach(blocks) { block in render(block) }
    }
    @ViewBuilder private func render(_ block: AgentContentBlock) -> some View {
        switch block.kind {
        case .text: AgentMarkdown(text: block.text, readingID: block.id, readingOrder: readingOrder + [response.blocks.firstIndex(where: { $0.id == block.id }) ?? 0]).equatable()
        case .thinking:
            AgentThinkingContent(block: block, label: block.id == firstThinkingID, expanded: thinkingExpanded, active: response.thinkingActive) { thinkingExpanded.toggle() }
                .chatReadingTarget(block.id, order: readingOrder + [response.blocks.firstIndex(where: { $0.id == block.id }) ?? 0])
        case .activity: EmptyView()
        }
    }
}
struct AgentThinkingContent: View {
    let block: AgentContentBlock
    let label: Bool
    let expanded: Bool
    let active: Bool
    let toggle: () -> Void
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if label {
                    Button(action: toggle) {
                        HStack(spacing: 7) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                            Text("Thinking").font(.system(size: 12, weight: .medium))
                            if active { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                        }.foregroundStyle(MilkTheme.muted).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel("Thinking")
                        .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"), \(active ? "Running" : "Complete")")
                        .accessibilityIdentifier("milk.pi.turn.thinking")
                }
                if expanded && !block.text.isEmpty {
                    SelectableContent(text: block.text, size: 12).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(MilkTheme.muted).padding(.leading, 12)
                        .overlay(alignment: .leading) { MilkTheme.line.frame(width: 2) }
                }
            }
    }
}

private struct AgentActivityGroupView: View {
    let steps: [ChatActivityStep]
    @State private var expandedChoice: Bool?
    @State private var outputs: Set<String> = []
    @State private var thoughts: Set<String> = []
    private var running: Bool { steps.contains { $0.running } }
    private var expanded: Bool { expandedChoice ?? running }
    var body: some View {
        AgentActivityGroupContent(steps: steps, expanded: expanded, outputs: outputs, thoughts: thoughts,
            toggle: { expandedChoice = !expanded },
            toggleOutput: { id in if !outputs.insert(id).inserted { outputs.remove(id) } },
            toggleThinking: { id in if !thoughts.insert(id).inserted { thoughts.remove(id) } })
    }
}
struct AgentActivityGroupContent: View {
    let steps: [ChatActivityStep]
    let expanded: Bool
    let outputs: Set<String>
    let thoughts: Set<String>
    let toggle: () -> Void
    let toggleOutput: (String) -> Void
    let toggleThinking: (String) -> Void
    private var running: Bool { steps.contains { $0.running } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text("Activity").fontWeight(.semibold)
                    Text("· \(steps.count) \(steps.count == 1 ? "step" : "steps")").foregroundStyle(MilkTheme.muted)
                    Spacer()
                    if running { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                }.padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel("Activity")
                .accessibilityValue("\(steps.count) steps, \(expanded ? "Expanded" : "Collapsed"), \(running ? "Running" : "Complete")")
                .accessibilityIdentifier("milk.pi.turn.activity")
            if expanded {
                ForEach(steps) { step in
                    switch step {
                    case .tool(let activity):
                        AgentActivityRowContent(activity: activity, output: outputs.contains(activity.id), toggle: { toggleOutput(activity.id) })
                    case .thinking(let block):
                        AgentActivityThinkingRowContent(block: block, expanded: thoughts.contains(block.id), toggle: { toggleThinking(block.id) })
                    }
                }
            }
        }.background(MilkTheme.elevatedSurface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.line))
    }
}

private struct AgentActivityThinkingRowContent: View {
    let block: AgentContentBlock
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "brain").foregroundStyle(MilkTheme.muted).frame(width: 12)
                    Text("Thinking").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    if block.streaming { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }.padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel("Thinking").accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("milk.pi.activity.thinking." + block.id)
            if expanded && !block.text.isEmpty {
                SelectableContent(text: block.text, size: 12).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(MilkTheme.muted).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(MilkTheme.canvas)
            }
        }
    }
}
struct AgentActivityRowContent: View {
    let activity: AgentActivity
    let output: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: activity.status == .running ? "circle.dotted" : activity.status == .error ? "exclamationmark.circle" : activity.status == .approval ? "hand.raised" : activity.status == .cancelled ? "stop.circle" : "checkmark")
                        .foregroundStyle(activity.status == .error ? MilkTheme.red : activity.status == .approval ? MilkTheme.amber : activity.status == .running ? MilkTheme.accent : MilkTheme.green).frame(width: 12)
                    Text(activity.kind).font(.system(size: 13, weight: .medium)).frame(width: 64, alignment: .leading)
                    Text(activity.detail).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let duration = activity.duration { Text(String(format: "%.1fs", duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(MilkTheme.muted) }
                    else if activity.status == .running { TimelineView(.periodic(from: .now, by: 1)) { context in Text("\(Int(context.date.timeIntervalSince(activity.started)))s").font(.system(size: 11, design: .monospaced)).foregroundStyle(MilkTheme.muted) } }
                    Image(systemName: output ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }.padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("milk.pi.activity." + activity.id)
            if output { SelectableContent(text: activity.detail + "\n\n" + activity.output, size: 11.5, monospaced: true).fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(MilkTheme.canvas) }
        }
    }
}

enum AgentMarkdownBlock: Equatable, Hashable {
    case paragraph(String), heading(Int, String), code(String), quote(String), list(String, String), rule
    /// Size of the text this piece retains, used to bound measurement caches.
    var utf8Count: Int {
        switch self {
        case .paragraph(let text), .code(let text), .quote(let text): return text.utf8.count
        case .heading(_, let text): return text.utf8.count
        case .list(let marker, let text): return marker.utf8.count + text.utf8.count
        case .rule: return 0
        }
    }
    static func parse(_ text: String) -> [Self] {
        let metric = ChatRenderMetrics.begin()
        defer { ChatRenderMetrics.end("markdown.parse", metric, units: text.utf8.count) }
        var result: [Self] = [], paragraph: [String] = [], code: [String]? = nil
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                if let source = code { result.append(.code(source.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            let headings = line.prefix { $0 == "#" }.count
            if (1...6).contains(headings), line.dropFirst(headings).first == " " {
                flush(); result.append(.heading(headings, String(line.dropFirst(headings + 1)))); continue
            }
            if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) { flush(); result.append(.rule); continue }
            if line.hasPrefix(">") { flush(); result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if let range = line.range(of: "^\\s*(?:[-+*]|[0-9]+[.)])\\s+", options: .regularExpression) {
                flush(); let marker = String(line[range]).trimmingCharacters(in: .whitespaces)
                result.append(.list(["-", "+", "*"].contains(marker) ? "•" : marker, String(line[range.upperBound...]))); continue
            }
            paragraph.append(line)
        }
        flush(); if let source = code { result.append(.code(source.joined(separator: "\n"))) }
        return result
    }
}
struct AgentMarkdown: View, Equatable {
    let text: String
    var readingID = "markdown"
    var readingOrder: [Int] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentMarkdownBlock.parse(text).enumerated()), id: \.offset) { index, block in
                AgentMarkdownPiece(block: block).equatable()
                    .chatReadingTarget("\(readingID)-markdown-\(index)", order: readingOrder + [index])
            }
        }.scrollTargetLayout().font(.system(size: 14)).textSelection(.enabled)
    }
}
struct AgentMarkdownPiece: View, Equatable {
    let block: AgentMarkdownBlock
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
    var body: some View {
        switch block {
        case .paragraph(let value): inline(value).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let value): inline(value).font(.system(size: CGFloat(max(14, 25 - level * 2)), weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
        case .code(let value):
            // Wrapped native selectable text, not a SwiftUI horizontal ScrollView: a
            // nested scroll view would own its own visible horizontal indicator and
            // swallow wheel events over the block, so the transcript could not be
            // scrolled while the pointer was on the code. Wrapping removes the need
            // for horizontal scrolling entirely.
            SelectableContent(text: value, size: 12, monospaced: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        case .quote(let value): inline(value).foregroundStyle(MilkTheme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).overlay(alignment: .leading) { MilkTheme.line.frame(width: 2) }
        case .list(let marker, let value): HStack(alignment: .top, spacing: 8) { Text(marker); inline(value).frame(maxWidth: .infinity, alignment: .leading) }
        case .rule: Hairline()
        }
    }
}

/// Native glyph layout shares one inset for text, caret and placeholder.
struct ComposerInput: NSViewRepresentable {
    @Binding var text:String
    let placeholder:String
    var onKeyCommand: ((ComposerKeyCommand) -> Bool)? = nil
    var focusRequest: UUID? = nil
    var accessibilityTitle = "Message"
    private static let contentInset=NSSize(width:14,height:12)
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView()
        scroll.drawsBackground=false
        scroll.identifier = NSUserInterfaceItemIdentifier("milk.composer.input")
        scroll.hasVerticalScroller=false
        scroll.autohidesScrollers=true
        let view=InputView()
        view.isRichText=false
        view.drawsBackground=false
        view.font=NSFont.systemFont(ofSize:14)
        view.textColor=NSColor(MilkTheme.ink)
        view.textContainerInset=Self.contentInset
        view.textContainer?.lineFragmentPadding=0
        view.isHorizontallyResizable=false
        view.isVerticallyResizable=true
        view.autoresizingMask=[.width]
        view.textContainer?.widthTracksTextView=true
        view.delegate=context.coordinator
        view.handleCommand=onKeyCommand
        view.setAccessibilityLabel(accessibilityTitle)
        scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent=self
        guard let view=scroll.documentView as? InputView else { return }
        if view.string != text { view.string=text; view.setSelectedRange(NSRange(location:(text as NSString).length,length:0)) }
        view.handleCommand=onKeyCommand
        view.setAccessibilityLabel(accessibilityTitle)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest=focusRequest
            if focusRequest != nil {
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }; view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location:(view.string as NSString).length,length:0))
                }
            }
        }
        view.placeholder=placeholder
        view.needsDisplay=true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 360)
        let height = ComposerInputMetrics.height(text: text, width: width)
        scroll.hasVerticalScroller = height >= ComposerInputMetrics.maximumHeight - 0.5
        return CGSize(width: width, height: height)
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:ComposerInput
        var lastFocusRequest: UUID?
        init(_ parent:ComposerInput) { self.parent=parent; lastFocusRequest=parent.focusRequest }
        func textDidChange(_ notification:Notification) {
            guard let view=notification.object as? NSTextView else { return }
            parent.text=view.string
            view.needsDisplay=true
        }
    }
    final class InputView:NSTextView {
        var placeholder=""
        var handleCommand: ((ComposerKeyCommand) -> Bool)?
        override func keyDown(with event: NSEvent) {
            let modifiers=event.modifierFlags.intersection([.shift,.control,.option,.command])
            if !hasMarkedText(), modifiers.isEmpty {
                let key: ComposerKeyCommand?
                switch event.keyCode { case 126:key = .up; case 125:key = .down; case 48:key = .tab; case 36,76:key = .enter; case 53:key = .escape; default:key=nil }
                if let key, handleCommand?(key) == true { return }
            }
            super.keyDown(with:event)
        }
        override func draw(_ dirtyRect:NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty,let container=textContainer else { return }
            let storage=NSTextStorage(string:placeholder,attributes:[.font:font ?? NSFont.systemFont(ofSize:14),.foregroundColor:NSColor(MilkTheme.muted)])
            let layout=NSLayoutManager()
            let placeholderContainer=NSTextContainer(size:container.size)
            placeholderContainer.lineFragmentPadding=container.lineFragmentPadding
            storage.addLayoutManager(layout)
            layout.addTextContainer(placeholderContainer)
            layout.drawGlyphs(forGlyphRange:layout.glyphRange(for:placeholderContainer),at:textContainerOrigin)
        }
    }
}

/// Native TextKit measurement accounts for wrapping and trailing empty lines at the actual width.
@MainActor enum ComposerInputMetrics {
    static let maximumHeight: CGFloat = 126
    static func height(text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: max(1, width - 28), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let line = layout.defaultLineHeight(for: font)
        return min(maximumHeight, max(line, ceil(used)) + 24)
    }
}

/// Developer-only appearance reference: the previous eager layout, never used in
/// the live transcript. Native verification overlays it for screenshot comparison.
@MainActor enum ChatAppearanceReference {
    static func view(_ conversation: SessionConversation, narrow: Bool) -> AnyView {
        let items = AgentTranscript.items(messages: conversation.messages, activities: conversation.activities)
        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    if let user = item.user { AgentUserMessageView(message: user, narrow: narrow) }
                    else if let response = item.response { AgentResponseTurnView(response: response) }
                }
                Color.clear.frame(height: 17)
            }.frame(maxWidth: 720).frame(maxWidth: .infinity)
                .padding(.horizontal, narrow ? 20 : 32).padding(.top, 28)
        }.font(.system(size: 13)).foregroundStyle(MilkTheme.ink).background(MilkTheme.canvas))
    }
}
