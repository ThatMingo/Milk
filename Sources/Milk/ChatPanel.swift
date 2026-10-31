import SwiftUI
import AppKit

struct ChatPanel: View {
    @ObservedObject var state: ShellState
    @State private var composerHeight: CGFloat = 96
    private var references: Bool {
        get { state.slashCommands.popup == .references }
        nonmutating set { if newValue { state.presentComposerPopup(.references) } else if references { state.presentComposerPopup(nil) } }
    }
    @State private var referenceQuery = ""
    @State private var referenceMatches: [URL] = []
    @State private var referenceTask: Task<Void, Never>?
    private var draft: String {
        get { state.agent.current.draft }
        nonmutating set {
            state.updateComposerDraft(newValue)
            if let match = newValue.range(of: "(?:^|\\s)@([^\\s]*)$", options: .regularExpression) {
                referenceQuery = String(newValue[match]).trimmingCharacters(in: .whitespaces).dropFirst().description
                references = true; searchReferences()
            }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 560
            VStack(spacing: 0) {
                ExtensionSlot(point:.chatToolbar)
                AgentConversationView(state: state, sessionID: state.selectedSession, narrow: narrow)
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
    private var conversation: SessionConversation { state.agent.conversations[sessionID] ?? .init() }
    var body: some View {
        if state.agent.showsNeutralChat {
            MilkCartonOutline()
                .stroke(MilkTheme.muted.opacity(0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 104)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            transcript
        }
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if conversation.messages.isEmpty {
                        SelectableContent(text: state.workspace.workspace == nil ? "Open a project to begin." : (state.currentSession == nil ? "Choose or create a session in the Sessions sidebar." : "Message \(state.agent.currentAgentDisplayName ?? "an agent") to start coding in this project.")).fixedSize(horizontal: false, vertical: true).foregroundStyle(MilkTheme.muted)
                    }
                    ForEach(AgentTranscript.items(messages: conversation.messages, activities: conversation.activities)) { item in
                        if let message = item.user {
                            HStack {
                                Spacer(minLength: narrow ? 20 : 100)
                                SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 568, alignment: .leading)
                                    .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            }.id(item.id)
                        } else if let response = item.response {
                            AgentResponseTurnView(response: response).id(item.id)
                        }
                    }
                    if !conversation.changes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Changed files · \(conversation.changes.count)").font(.system(size: 12, weight: .semibold))
                            ForEach(conversation.changes) { file in
                                Button {
                                    if let root = state.workspace.workspace?.url {
                                        state.workspace.openChangedFile(root.appendingPathComponent(file.path))
                                    }
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
                    }
                    if let notice = conversation.notice { Text(notice).font(.system(size: 11)).foregroundStyle(MilkTheme.muted).textSelection(.enabled) }
                    if let error = conversation.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(MilkTheme.red).textSelection(.enabled)
                            Button("Restart \(state.agent.currentAgentDisplayName ?? "agent")") { state.agent.restart() }.buttonStyle(MilkButtonStyle(bordered: true))
                        }.font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.red.opacity(0.4)))
                    }
                    Color.clear.frame(height: 1).id("tail")
                }.scrollTargetLayout().frame(maxWidth: 720).frame(maxWidth: .infinity)
                    .padding(.horizontal, narrow ? 20 : 32).padding(.top, 28).padding(.bottom, 16)
            }
            .scrollPosition(id: Binding(get: { conversation.scrollAnchor }, set: { state.agent.conversations[sessionID]?.scrollAnchor = $0 }), anchor: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atBottom in state.agent.conversations[sessionID]?.followsTail = atBottom }
            .onChange(of: conversation.messages.last) { _, _ in if conversation.followsTail { proxy.scrollTo("tail", anchor: .bottom) } }
            .onChange(of: conversation.activities.last) { _, _ in if conversation.followsTail { proxy.scrollTo("tail", anchor: .bottom) } }
            .onAppear { if conversation.followsTail { proxy.scrollTo("tail", anchor: .bottom) } }
        }
    }
}

struct AgentResponseTurnView: View {
    @Environment(\.milkExtensionActionContext) private var extensionContext
    let response: AgentResponseTurn
    @State private var thinkingExpanded = false
    private var firstThinkingID: String? { response.blocks.first(where: \.visibleThinking)?.id }
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
        let blocks = visibleBlocks
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "drop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(MilkTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                Text("Pi").fontWeight(.semibold)
                ExtensionSlot(point:.chatMessageActions)
                    .environment(\.milkExtensionActionContext,.init(workspaceURL:extensionContext.workspaceURL,text:response.blocks.filter { $0.kind == .text }.map(\.text).joined(separator:"\n")))
                if response.streaming && !response.thinkingActive { ProgressView().controlSize(.mini) }
            }.accessibilityIdentifier("milk.pi.turn.header")
            ForEach(response.presentationGroups) { group in
                if group.isActivity {
                    AgentActivityGroupView(activities: group.blocks.compactMap { block in
                        response.activities.first { $0.id == block.activityID }
                    })
                } else {
                    content(group.blocks.filter { block in blocks.contains { $0.id == block.id } })
                }
            }
        }.onChange(of: response.thinkingActive) { _, active in if !active { thinkingExpanded = false } }
    }
    private func content(_ blocks: [AgentContentBlock]) -> some View {
        ForEach(blocks) { block in render(block) }
    }
    @ViewBuilder private func render(_ block: AgentContentBlock) -> some View {
        switch block.kind {
        case .text: AgentMarkdown(text: block.text)
        case .thinking:
            VStack(alignment: .leading, spacing: 8) {
                if block.id == firstThinkingID {
                    Button { thinkingExpanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                            Text("Thinking").font(.system(size: 12, weight: .medium))
                            if response.thinkingActive { ProgressView().controlSize(.mini) }
                        }.foregroundStyle(MilkTheme.muted).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("milk.pi.turn.thinking")
                }
                if thinkingExpanded && !block.text.isEmpty {
                    SelectableContent(text: block.text, size: 12).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(MilkTheme.muted).padding(.leading, 12)
                        .overlay(alignment: .leading) { MilkTheme.line.frame(width: 2) }
                }
            }
        case .activity: EmptyView()
        }
    }
}
private struct AgentActivityGroupView: View {
    let activities: [AgentActivity]
    @State private var expandedChoice: Bool?
    private var running: Bool { activities.contains { $0.status == .running || $0.status == .approval } }
    private var expanded: Bool { expandedChoice ?? running }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expandedChoice = !expanded } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text("Activity").fontWeight(.semibold)
                    Text("· \(activities.count) \(activities.count == 1 ? "step" : "steps")").foregroundStyle(MilkTheme.muted)
                    Spacer()
                    if running { ProgressView().controlSize(.mini) }
                }.padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("milk.pi.turn.activity")
            if expanded { ForEach(activities) { AgentActivityRow(activity: $0) } }
        }.background(MilkTheme.elevatedSurface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MilkTheme.line))
            .onChange(of: running) { _, active in if !active { expandedChoice = nil } }
    }
}

private struct AgentActivityRow: View {
    let activity: AgentActivity
    @State private var output = false
    var body: some View {
        VStack(spacing: 0) {
            Button { output.toggle() } label: {
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

enum AgentMarkdownBlock: Equatable {
    case paragraph(String), heading(Int, String), code(String), quote(String), list(String, String), rule
    static func parse(_ text: String) -> [Self] {
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
struct AgentMarkdown: View {
    let text: String
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value): inline(value).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let level, let value): inline(value).font(.system(size: CGFloat(max(14, 25 - level * 2)), weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                case .code(let value):
                    ScrollView(.horizontal) { Text(value).font(.system(size: 12, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                case .quote(let value): inline(value).foregroundStyle(MilkTheme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).overlay(alignment: .leading) { MilkTheme.line.frame(width: 2) }
                case .list(let marker, let value): HStack(alignment: .top, spacing: 8) { Text(marker); inline(value).frame(maxWidth: .infinity, alignment: .leading) }
                case .rule: Hairline()
                }
            }
        }.font(.system(size: 14)).textSelection(.enabled)
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
